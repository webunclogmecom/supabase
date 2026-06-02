-- 2026-05-28_zones_allow_crud_from_calendar.sql
--
-- Companion to 2026-05-27_zones_reference_table.sql + the lock-anon-writes
-- migration. Opens up write paths on public.zones so the Visit Calendar
-- Lovable app can offer a "Manage zones" modal (color picker, label edit,
-- sort_order, soft-delete, add zone). Writes are still audited by the
-- existing audit_zones trigger and attributed via ADR 016
-- (app_source='visit-calendar').
--
-- DECISIONS
--   - INSERT + UPDATE: allowed from anon and authenticated.
--   - DELETE: NOT allowed. Per CLAUDE.md rule 6 (never hard-delete business
--     data), the modal must use UPDATE … SET is_active = false.
--   - `code` is locked as immutable post-INSERT via BEFORE UPDATE trigger.
--     Reason: `properties.zone` (and ops views) join on this string. A
--     rename would silently orphan rows. Renames must go through a
--     deactivate-old + insert-new flow (and a manual properties.zone
--     UPDATE — out of scope here).
--   - SELECT relaxes from `is_active = true` to all rows so the modal can
--     list inactive zones for reactivation. The Calendar's main read query
--     keeps its `where is_active` filter client-side — no change there.
--
-- SAFEGUARDS
--   - Audit trigger (audit_zones) already captures every INSERT/UPDATE
--     with full-row JSONB + ADR 016 attribution. Rollback from a bad UI
--     edit is a one-row UPDATE from the audit history.
--   - `zones_with_usage` view exposes per-zone property counts so the
--     modal can warn before soft-deleting a zone that still has
--     properties assigned.
--   - Color hex CHECK constraint from the original migration stays in
--     place, so a bad hex value never lands in the DB.
--
-- IDEMPOTENT (Rule 5): DROP+CREATE policies, function CREATE OR REPLACE,
-- view CREATE OR REPLACE.

BEGIN;

-- ============================================================
-- 1. Replace the SELECT-only policy with full row visibility (active+inactive).
-- ============================================================
DROP POLICY IF EXISTS zones_anon_select_active ON public.zones;

CREATE POLICY zones_anon_select_all ON public.zones
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- ============================================================
-- 2. Allow anon INSERT + UPDATE. No DELETE policy = no DELETEs.
-- ============================================================
DROP POLICY IF EXISTS zones_anon_insert ON public.zones;
CREATE POLICY zones_anon_insert ON public.zones
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS zones_anon_update ON public.zones;
CREATE POLICY zones_anon_update ON public.zones
  FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

-- Re-grant table-level privileges (revoked in 2026-05-27 lock migration).
GRANT INSERT, UPDATE ON public.zones TO anon, authenticated;
-- DELETE intentionally NOT granted.

-- ============================================================
-- 3. Lock zones.code as immutable post-INSERT.
-- ============================================================
CREATE OR REPLACE FUNCTION public.zones_lock_code()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    RAISE EXCEPTION
      'zones.code is immutable (current: %, attempted: %). To rename a zone, soft-delete the old row (set is_active=false) then INSERT a new row with the new code, and UPDATE properties.zone to match.',
      OLD.code, NEW.code
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS zones_lock_code_trg ON public.zones;
CREATE TRIGGER zones_lock_code_trg
  BEFORE UPDATE ON public.zones
  FOR EACH ROW EXECUTE FUNCTION public.zones_lock_code();

-- ============================================================
-- 4. zones_with_usage view — for the modal's "X properties use this zone"
--    confirmation before soft-delete.
-- ============================================================
CREATE OR REPLACE VIEW public.zones_with_usage AS
  SELECT
    z.code,
    z.label,
    z.color_hex,
    z.color_token,
    z.sort_order,
    z.is_active,
    z.created_at,
    z.updated_at,
    COALESCE(p.n_properties, 0)::int AS n_properties
  FROM public.zones z
  LEFT JOIN (
    SELECT zone, COUNT(*)::int AS n_properties
    FROM public.properties
    WHERE zone IS NOT NULL
    GROUP BY zone
  ) p ON p.zone = z.code;

GRANT SELECT ON public.zones_with_usage TO anon, authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Anon can SELECT all (active + inactive), INSERT, UPDATE; cannot DELETE:
--    SELECT grantee, privilege_type
--    FROM information_schema.role_table_grants
--    WHERE table_schema='public' AND table_name='zones'
--      AND grantee IN ('anon','authenticated')
--    ORDER BY grantee, privilege_type;
--    Expected: SELECT, INSERT, UPDATE per grantee; no DELETE.
--
-- 2. Policies present:
--    SELECT policyname, cmd FROM pg_policies WHERE tablename='zones'
--    ORDER BY cmd, policyname;
--    Expected: zones_anon_insert (INSERT), zones_anon_select_all (SELECT),
--    zones_anon_update (UPDATE).
--
-- 3. code immutability:
--    UPDATE public.zones SET code='SOUTH2' WHERE code='SOUTH';
--    Expected: ERROR — zones.code is immutable.
--
-- 4. zones_with_usage view returns property counts:
--    SELECT code, label, is_active, n_properties FROM public.zones_with_usage
--    ORDER BY sort_order;
