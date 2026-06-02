-- 2026-05-23f_properties_single_primary.sql
--
-- 41 clients currently have TWO `properties.is_primary = true` rows.
-- The `customer.clients` view does `LEFT JOIN properties ON client_id
-- AND is_primary = true`, so duplicates produce duplicate rows per
-- slug — which breaks the Field Portal slug-based login (returns
-- "Something went wrong" on POST). Discovered today via FP login test
-- on /042-mt (Miami twist).
--
-- Root cause: when properties were backfilled (likely the 2026-05-20
-- backfill_properties_from_at.js sync), the script created new
-- property rows for each client and marked them `is_primary=true`
-- without flipping the pre-existing Jobber-sourced primary to false.
-- For most clients the newer + older rows have the same address but
-- different lat/long precision; for some (like Miami twist) the older
-- row has a more complete address string. Per CLAUDE.md rule 4
-- (Jobber + Samsara = 100% source of truth), the OLDER row (typically
-- from initial Jobber sync) is canonical. We flip the NEWER row
-- (higher id) to `is_primary=false`.
--
-- This migration:
--   1. UPDATE: for each client with >1 is_primary=true, set
--      is_primary=false on all but the lowest id (deterministic and
--      Jobber-aligned).
--   2. CREATE UNIQUE INDEX so future inserts can't break this
--      invariant — a single primary per client_id, enforced by Postgres.
--
-- Audit (Rule 8): properties is audited (per ADR-010). Each UPDATE
-- creates an audit.logs row with full old/new diff. With ADR-016 now
-- live, the row will show `app_source = 'sql'` (this is a Management
-- API call). Expected ~41 audit rows.
--
-- Idempotent (Rule 5): the UPDATE clause filters to rows that are
-- still duplicates; if re-run after the index exists, the WHERE
-- already-clean condition is a no-op.
--
-- Verification:
--   - After apply: 0 clients should have >1 is_primary=true row.
--   - customer.clients should return 1 row per slug.
--   - FP login for /042-mt should succeed.

BEGIN;

-- ============================================================
-- 1. DATA FIX — flip newer duplicate primaries to false
-- ============================================================
WITH ranked AS (
  SELECT id, client_id,
         ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY id ASC) AS rn
  FROM public.properties
  WHERE is_primary = true
),
to_demote AS (
  SELECT id FROM ranked WHERE rn > 1
)
UPDATE public.properties
   SET is_primary = false
 WHERE id IN (SELECT id FROM to_demote);

-- ============================================================
-- 2. UNIQUE INDEX — enforce single primary per client_id
-- ============================================================
-- Partial unique index: only enforces uniqueness on rows where
-- is_primary = true. Non-primary rows are unconstrained.
CREATE UNIQUE INDEX IF NOT EXISTS uq_properties_one_primary_per_client
  ON public.properties (client_id)
  WHERE is_primary = true;

COMMENT ON INDEX public.uq_properties_one_primary_per_client IS
  'Each client_id may have at most one is_primary=true property row. Added 2026-05-23f after a 41-client duplicate-primary cleanup. Prevents recurrence from future sync/backfill scripts.';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. No more duplicate primaries:
--    SELECT client_id, COUNT(*)::int
--    FROM properties
--    WHERE is_primary = true
--    GROUP BY client_id HAVING COUNT(*) > 1;
--    Expected: 0 rows.
--
-- 2. customer.clients returns unique slugs:
--    SELECT slug, COUNT(*)::int
--    FROM customer.clients
--    GROUP BY slug HAVING COUNT(*) > 1;
--    Expected: 0 rows.
--
-- 3. FP login: navigate to fp.unclogme.app, sign in with "042-mt"
--    (or any of the 41 affected client_codes), should reach Service
--    History page successfully.
--
-- 4. Audit log shows the 41 demotions with app_source='sql':
--    SELECT COUNT(*)::int
--    FROM audit.logs
--    WHERE table_name = 'properties'
--      AND operation = 'UPDATE'
--      AND app_source = 'sql'
--      AND changed_at > NOW() - INTERVAL '5 minutes';
--    Expected: 41.
