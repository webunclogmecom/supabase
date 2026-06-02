# Field Portal → Prod canonical switch — Lovable prompt

Paste this into the Lovable Field Portal project's chat. Self-contained.

---

## Goal

We're decommissioning the Field Portal Sandbox database (`klgtrdwrasrlxbmfyvdh`) and pointing the Field Portal app at our **Prod** canonical database (`wbasvhvvismukaqdnouk`) instead — reading through the existing `customer` schema. This makes Field Portal **real-time** with everything that happens in our ops apps (Admin Review, future DERM app, etc.).

**No code changes needed.** Only environment variables.

## Why this works without code changes

The Prod database has the **identical `customer` schema** that the Field Portal Sandbox has:
- Same 8 views: `work_orders`, `wo_photos`, `client_access_photos`, `inspection_items`, `permits`, `recommendations`, `scheduled_visits`, `clients`
- Same view column shapes (verified column-by-column — 0 diffs)
- Same 3 helper functions: `uuid_from_bigint`, `bigint_from_uuid`, `public_url`
- Same anon `SELECT` grants on all 8 views
- Same `security_invoker=false` setting (views run as owner, bypass canonical RLS — anon doesn't need access to `public.*` tables)
- The `customer` schema has been added to Prod's PostgREST exposed schemas (`db_schema = public,graphql_public,customer`)

This was validated empirically before the switch — REST `Accept-Profile: customer` returns 200 on all 8 views with the Prod anon key.

## Changes — environment variables only

In Project Settings → Environment Variables, change:

```diff
- VITE_SUPABASE_URL=https://klgtrdwrasrlxbmfyvdh.supabase.co
+ VITE_SUPABASE_URL=https://wbasvhvvismukaqdnouk.supabase.co
- VITE_SUPABASE_PUBLISHABLE_KEY=<old Field Portal Sandbox anon key>
+ VITE_SUPABASE_PUBLISHABLE_KEY=<Prod anon key — Fred is pasting the actual value>
```

Both `VITE_*` vars are build-time, so a rebuild is required after the swap.

## Code that must NOT change

- The `createClient(...)` call — **keep** `{ db: { schema: 'customer' } }`
- Every `supabase.from('work_orders')`, `from('wo_photos')`, `from('clients')`, etc. — view names are identical
- All field/column accessors — same shape
- `useVisitDetail.ts`, `useWorkOrder.ts`, `WorkOrderView.tsx`, `JobCard.tsx`, etc. — no logic changes
- The TypeScript `database.types.ts` — types are still valid (if regenerating, point codegen at the Prod ref)

## What changes for the customer experience

| | Before (FP Sandbox) | After (Prod) |
|---|---|---|
| Number of clients reachable | 44 (test subset) | 351 (all UnclogMe customers) |
| Data freshness | Stale until manually re-cloned | Real-time |
| Photo classifications from Admin Review | Visible only after a manual mirror | Visible immediately |
| New visits from Jobber webhook | Visible only after re-clone | Visible immediately on webhook fire |
| DERM manifest documents | AT-signed URLs (expired in hours) | Permanent Supabase Storage URLs |
| Driver assignments | Stale snapshot | Live from webhook |
| Image URLs | Already pointed at Prod's Storage | Same (no change) |

## Smoke test after rebuild

Run these in order. Stop and report if any step fails.

1. **Login** with an existing test slug. Auth flow should be unchanged (same `supabase.auth.*` calls hitting Prod auth instead of FP).
2. Open client **092-TCE (The carrot express Coral Gables)** — confirm **8 completed visits** show in the Service History list.
3. **Driver-backfill smoke test** — open the **2026-05-04** visit.
   - **Driver should show: Steven** (was previously blank when reading FP — this is the headline fix).
   - **Truck**: Moises
   - **Manholes**: — (not set)
   - **DERM/WWTP compliance cards**: expect them to be **empty / not rendered** for this specific visit. The DERM manifest for May 4 exists in the canonical DB but isn't linked to this visit (`manifest_visits` linkage gap — separate ops issue Fred is tracking). This is **not** a switch regression; the FP Sandbox had the same gap.
4. **DERM-render smoke test** — open the **2026-04-13** visit (also under 092-TCE; this is the known-good linked visit).
   - **Driver**: should show drivers from that visit (Grecia, Jeffry, Steven).
   - **Truck**: Moises
   - **DERM FOG eManifest**: number `821472` + "View document" link.
   - **WWTP Disposal Receipt**: number `821472` + "View document" link.
   - Both links must start with `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/...` (permanent Supabase Storage URLs — no more expiring AT URLs).
   - Click each → PDF should load. No "URL expired" errors.
5. **Photos smoke test** — still on the 2026-04-13 visit: **Before** grid = 3 photos, **After** grid = 5 photos. All thumbnail URLs on `wbasvhvvismukaqdnouk.supabase.co/storage/...`.
6. Open DevTools → Network tab. Confirm:
   - Requests go to `wbasvhvvismukaqdnouk.supabase.co` (NOT `klgtrdwrasrlxbmfyvdh`)
   - All `/rest/v1/work_orders`, `/rest/v1/wo_photos`, etc. return **200**
   - Request headers include `Accept-Profile: customer` (or the equivalent the supabase-js client sets via `db.schema='customer'`)
   - No 401/403 errors
   - No `42P01` (relation does not exist) errors
   - No `PGRST106` (schema not exposed) errors
7. **Read-only status banner** — try logging in with **`005-BUB`** (INACTIVE) and **`166-SPA`** (PAUSED). They should now resolve (the `customer.clients` view was updated 2026-05-16 to include all statuses). Expected app behavior — **see Lovable code change required below**.

## Code change required for step 7 — read-only status banner

The `customer.clients` view now exposes two new columns:

| Column | Type | Values |
|---|---|---|
| `status` | `text` | `'ACTIVE'` \| `'RECURRING'` \| `'PAUSED'` \| `'INACTIVE'` |
| `is_active` | `boolean` | `true` when status is `ACTIVE`/`RECURRING`, else `false` |

### What Lovable needs to add

After fetching the client on login, gate the UI based on `is_active`:

```ts
// In useClient.ts (or wherever client load happens)
const { data: client } = await supabase.from('clients').select('*').eq('slug', slug).single();

if (!client) {
  // existing "invalid code" path
  return;
}

// NEW
const readOnly = !client.is_active;
// pass readOnly + client.status to the layout
```

In the layout (header or top of dashboard), show a banner when `readOnly === true`:

```tsx
{!client.is_active && (
  <Banner variant="warning">
    {client.status === 'PAUSED' && 'Your account is paused. Service history below is read-only — call us to resume service.'}
    {client.status === 'INACTIVE' && 'Your account is closed. Service history below is read-only and kept for compliance reference.'}
  </Banner>
)}
```

Also gate any write/contact-form affordances behind `client.is_active`. The DB views (work_orders, wo_photos, scheduled_visits, permits, etc.) don't filter on client status — historical data is fully visible for read.

**Don't change the "Invalid code" copy** for the case where the slug truly doesn't exist (typo, residential client without a code, deleted client). That's still the correct error.

## Rollback path

If anything goes wrong, revert the two env vars to the previous Field Portal Sandbox values:

```
VITE_SUPABASE_URL=https://klgtrdwrasrlxbmfyvdh.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=<previous FP Sandbox anon key>
```

Trigger a rebuild and you're back to the previous state. The FP Sandbox database is being left online (not deleted) precisely so rollback is one env-var swap away.

## What Lovable's task is

1. Swap the two env vars as shown above.
2. Trigger a rebuild.
3. **Don't modify code.** If you find yourself wanting to "fix" something in `useVisitDetail.ts` / `WorkOrderView.tsx` / etc. — stop and ask Fred first. The whole point is that the schema is identical, so existing code keeps working.
4. After deploy, run through the smoke test above and report the result. If anything fails, paste the error and Fred can diagnose.

## What this enables going forward

- The mirror script (`mirror_prod_to_field_portal.js`) we'd been running becomes unnecessary.
- Admin Review App's dual-write to Prod is now visible to Field Portal **within milliseconds**.
- Future apps (DERM app, Sales app, etc.) follow the same pattern: per-app schema on Prod, app reads directly from Prod canonical via that schema. The "Sandbox project per app" pattern is the exception, not the rule.
- The Field Portal Sandbox project can be decommissioned at Fred's convenience (free up its Supabase Free-tier slot).

---

**Status:** schema is live on Prod, REST endpoint verified, customer.work_orders for visit 3915 returns `driver: 'Steven'` + correct PDF URLs. Ready for env-var swap.
