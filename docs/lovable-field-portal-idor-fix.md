# Field Portal — IDOR fix paste-ready Lovable prompt

Generated 2026-05-25. Send this to Lovable for the Field Portal project. Two-part change.

---

## Context (paste this verbatim)

> The Supabase backend just landed three migrations (`2026-05-25e/f/g`) that change how visit URLs work in Field Portal, to close an IDOR (Insecure Direct Object Reference) vulnerability.
>
> **Before**: visit URLs were `/092-tce/visit/00000000-0000-0000-0000-000000003915` — the "UUID" was actually the BIGINT visit id padded into UUID shape, so sequential and easy to enumerate.
>
> **After**: visit URLs are `/092-tce/visit/Kj9aP2w8Xr` — a 10-character random base62 token, stored in `visits.public_id`. Already populated for every visit in the DB.
>
> The `customer.work_orders.id` column is now `TEXT` (was `UUID`). Same for `wo_photos.work_order_id`, `inspection_items.work_order_id`, `recommendations.work_order_id`, `scheduled_visits.id`. The URL routing should now expect a 10-char string, not a UUID. React-router accepts any string for `:visitId` so this should just work, but please confirm.
>
> One thing still broken: the **visit detail page** currently does a direct `supabase.from('work_orders').select().eq('id', token)`. This is IDOR-vulnerable: someone could take a token from `/092-tce/visit/Kj9aP2w8Xr` and try it under `/001-vin/visit/Kj9aP2w8Xr` — the SELECT doesn't check that the visit belongs to the slug's client. Need to switch this to a Postgres RPC that enforces ownership server-side.

## Concrete code changes

### 1. Find every place that fetches a single work_order by id

Look in `src/integrations/personal-supabase/client.ts` first for the configured client (probably `customerDb` or similar). Then grep the project for usages that look like:

```ts
.from('work_orders')
.select(...)
.eq('id', someVisitToken)
```

The visit detail page is the primary case — usually in a route like `src/routes/[slug]/visit/[id]/page.tsx` or `src/app/[slug]/visit/[id]/...`.

### 2. Replace that call with an RPC call

```ts
// BEFORE
const { data, error } = await customerDb
  .from('work_orders')
  .select('*')
  .eq('id', token)
  .single();

// AFTER
const { data, error } = await customerDb
  .rpc('get_visit_by_slug_and_token', {
    p_slug: slug,    // the [slug] route param (e.g. '092-tce')
    p_token: token,  // the [id] route param (10-char base62)
  })
  .single();
```

Notes:
- The RPC is in the `customer` schema. The `customerDb` client is already configured with `db: { schema: 'customer' }`, so plain `.rpc(...)` is enough.
- The RPC returns `SETOF customer.work_orders` so the response shape is identical to the previous SELECT — same column names, same types.
- `.single()` returns the row or sets `error.code = 'PGRST116'` (not found / wrong slug / both).

### 3. Handle the "wrong slug" case the same way as "not found"

If the slug in the URL doesn't match the visit's client, the RPC returns 0 rows. From the user's perspective this is indistinguishable from "visit doesn't exist" — show whatever 404 / empty-state component you'd show for a missing visit. **Do not** leak the difference (e.g. don't render "this visit belongs to another customer") — that would re-introduce the information disclosure.

### 4. Verify each related fetch on the detail page

Check whether the page also fetches:
- `customer.wo_photos` filtered by `work_order_id` — fine to keep as direct SELECT (the work_order_id is already the public_id, and if attacker passed a wrong slug they didn't get a valid work_order to derive photos for)
- `customer.inspection_items` filtered by `work_order_id` — same
- `customer.recommendations` filtered by `work_order_id` — same

Those secondary fetches stay as direct SELECTs; the RPC gates the primary lookup. If the primary lookup returns empty, the page short-circuits before issuing the secondary fetches.

## Acceptance checks

After the change, when I test on Prod I should be able to verify:

1. **Normal flow works**: navigate to `/092-tce`, click any visit card, see the detail page render with manholes / driver / etc.
2. **IDOR is blocked**: manually open `/001-vin/visit/{token-belonging-to-092-tce}` — should show the 404 / "visit not found" state. NOT the 092-tce visit's data.
3. **Old URLs degrade gracefully**: navigating to `/092-tce/visit/00000000-0000-0000-0000-000000003915` (the old UUID-shaped format) should also show the 404 state — that token doesn't match anything in the new system.

## What does NOT change

- The slug-based login flow stays exactly the same.
- The Service History list page (`/[slug]`) keeps its current direct SELECT on `work_orders` filtered by `client_id` — that's not IDOR-vulnerable since the `client_id` filter is derived from the slug lookup.
- The `/print` route, the location-info tab, scheduled visits — none of those need to change.
- `customer.work_orders` still exists and anon can still SELECT from it directly (needed for the list page). The RPC is just the *enforced-ownership* path for the single-visit detail view.

---

Once you ship this, ping me and I'll verify on Prod that the IDOR is closed end-to-end via the same browser test I used to find it.
