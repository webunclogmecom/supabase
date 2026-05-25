# Fixes Applied During the Test Run

## Fix 1 — `customer.work_orders` primary-property fallback (migration 2026-05-25b)

**Surfaced by**: A1 cross-app propagation test for client 290 (Yann Couvreur)

**Symptom**: Only 1 of 9 111-YC visits had `manholes` populated in FP, despite property 66 being set to 9.

**Diagnosis**: 8/9 visits had `visits.property_id IS NULL`. The earlier view fallback only reaches `properties.grease_trap_manhole_count` if `v.property_id` is set. For null-property visits, the COALESCE bottoms out at NULL.

**Scope**:
- 424 total eligible visits (completed + derm_required + has client_id)
- 324 (76%) have `property_id IS NULL`
- 214 of those 324 could be resolved by falling back to the client's `is_primary = true` property
- 110 still NULL (their client either has no primary, or the primary's gtmc = 0)

**Fix**: Extend the COALESCE in `customer.work_orders.manholes` to fall back to the client's primary property:

```sql
COALESCE(
  v.manhole_count,
  NULLIF(prop.grease_trap_manhole_count, 0),
  NULLIF((SELECT grease_trap_manhole_count FROM properties
           WHERE client_id = v.client_id AND is_primary = true LIMIT 1), 0)
) AS manholes
```

**Migration**: `docs/migrations/2026-05-25b_customer_work_orders_primary_property_fallback.sql`

**Impact before/after**:
- Before: 57 visits showed manholes in FP (13% of 425 eligible)
- After: ~271 visits should show manholes (64% of eligible)

## Followup (NOT in this commit) — Backfill `visits.property_id`

324 visits have NULL property_id but their client has properties available. The Jobber-sync code path that populates `visits.property_id` apparently missed historic visits. A separate one-shot backfill could set `v.property_id = (SELECT id FROM properties WHERE client_id = v.client_id AND is_primary = true LIMIT 1)` for the affected rows.

Scope: 324 UPDATE rows on Prod, generates 324 audit entries, would lift FP coverage to ~85%. Flagged as ops follow-up — not safe to do silently in a fix loop without confirmation.
