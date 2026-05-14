# Lovable rewrite spec — Customer Portal → personal Supabase via `customer` schema

> **Paste this into Lovable as the rewrite instruction.** Architecture: instead
> of porting the 8 denormalized Lovable Cloud tables verbatim, we built a
> dedicated `customer` schema in the personal Supabase with 8 views shaped
> column-for-column like the existing tables. Frontend code is unchanged.

---

Customer DB is ready in the personal Supabase. Architecture flipped: instead of porting your 8 table shapes verbatim, we built a dedicated `customer` schema with 8 views matching your existing table shapes column-for-column. Frontend code is unchanged. Data flows from canonical (`public.*`) through these views to your app.

## The single change you need to make

In your `src/integrations/personal-supabase/` client setup, add `db: { schema: 'customer' }` to `createClient`:

```ts
import { createClient } from '@supabase/supabase-js';

export const personalSupabase = createClient(
  import.meta.env.VITE_PERSONAL_SUPABASE_URL!,
  import.meta.env.VITE_PERSONAL_SUPABASE_ANON_KEY!,
  { db: { schema: 'customer' } }      // ← this line
);
```

That's it. Every `from('clients')`, `from('permits')`, `from('work_orders')`, etc. resolves to the matching `customer.*` view. All 13 queries in `src/lib/portal.ts` will work as-is.

## Server-side `loginWithCode` (same shape, same column names)

Use the same `customer` schema for server functions too:

```ts
const personalAdmin = createClient(URL, SERVICE_KEY, {
  db: { schema: 'customer' }
});

const { data } = await personalAdmin
  .from('clients')
  .select('id, slug, client_code')
  .ilike('client_code', code)
  .maybeSingle();
```

`data.id` is a `string` (synthetic UUID derived from canonical BIGINT). Cookie payload stays UUID. No type changes.

## Env vars

```
VITE_PERSONAL_SUPABASE_URL=https://klgtrdwrasrlxbmfyvdh.supabase.co
VITE_PERSONAL_SUPABASE_ANON_KEY=<value Fred sent>
```

Plus the service role key in server-only secrets, same as before.

## Regenerate types (optional but recommended)

```bash
supabase gen types typescript \
  --project-id klgtrdwrasrlxbmfyvdh \
  --schema customer \
  > src/integrations/personal-supabase/types.ts
```

## What's seeded today in `customer.*`

| View | Rows | Status |
|---|---|---|
| `customer.clients` | 44 | ✅ full data |
| `customer.permits` | 31 | ✅ full data |
| `customer.scheduled_visits` | 121 | ✅ full data |
| `customer.work_orders` | 128 | ✅ full data |
| `customer.wo_photos` | 0 | ⚠️ empty (no photos in sandbox yet) |
| `customer.client_access_photos` | 0 | ⚠️ empty |
| `customer.inspection_items` | 0 | ⚠️ empty (no inspections in sandbox yet; canonical schema also limits depth) |
| `customer.recommendations` | 0 | ⚠️ empty (admin-authored, no seeded recs) |

Empty views render empty UI sections — not a bug, just no test data for those sections yet. The four populated views cover the bulk of the portal (header, location info, permits, scheduled visits, service history list).

## Test plan (do this in your branch before flipping `VITE_PORTAL_DATA_SOURCE=personal`)

1. Hit `loginWithCode('168-AVA')` — should resolve to "168-AVA AVA" (9 completed work orders, 5 scheduled, 1 permit). Sets cookie.
2. `fetchClientBySlug('168-ava')` should populate header, location info, permits (if Vincenzo's has a GT permit set), scheduled visits, work orders.
3. Open a work order from the history → header + visit details should render. Photos / inspection-items / recommendations grids will be empty (expected).
4. Print sign at `/168-ava/print` → uses the same 5-query path.
5. Slug guard: while logged in as `168-ava`, attempt `/083-shul` → should redirect back to `/168-ava`.

Once all five pass, flip `VITE_PORTAL_DATA_SOURCE=personal`.

## What we'll deliver next (no action on your side)

- Photos + inspections backfill so those UI sections render with real data
- Canonical inspection columns expansion so `inspection_items` shows the full UnclogMe checklist

These don't block the rewrite — you can test the working sections first.
