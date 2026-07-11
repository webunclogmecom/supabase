-- 2026-07-11_phase3_visit_lifecycle_lock.sql
-- VISIT-LIFECYCLE AUTH — PHASE 3 (final DB lock). Plan: docs/handoffs/2026-07-09_visit_lifecycle_rpc_and_auth_PLAN.md (Part C).
-- Gated on Phase 2 (login gate + Calendar RPC migration) live-verified on all 4 staff apps — Building Apps
-- posted the GO + Fred green-lit both gates 2026-07-11 (WORKING-NOW.md). This is the security close: the
-- public anon key (extractable from any app bundle) can no longer drive a Jobber-visit delete/complete.
--
-- WHAT THIS DOES:
--  (1) Revokes direct UPDATE(visit_status, completed_at) on public.visits from anon + authenticated
--      → lifecycle is RPC-only (set_visit_status SECDEF, authenticated-only, runs as owner).
--      service_role KEEPS table-level write (crons/edge). manhole_count + derm_required grants are LEFT
--      as-is (Building Apps: not Jobber-delete vectors; anon-write accepted for now).
--  (2) Revokes anon (and the PUBLIC default-privilege grant) EXECUTE on the 6 Calendar lifecycle RPCs,
--      keeping authenticated + service_role. ⚠ TWO nuances the plan text under-specified, both verified
--      live before writing this migration (backups/2026-07-11_phase3_grants_before.json):
--        - Each RPC exists in BOTH schemas: public.* AND ops.* (the Calendar client defaults to schema
--          `ops`, calling ops.edit_calendar_visit etc.). Revoking only public.* would leave ops.* open to
--          anon → the loop below covers BOTH schemas.
--        - Several are granted to PUBLIC (`=X`), which auto-grants anon/authenticated/service_role
--          (Supabase default-privileges trap, ADR/plan note). REVOKE FROM anon alone is NOT enough;
--          we REVOKE FROM PUBLIC, anon then GRANT TO authenticated, service_role explicitly.
--
-- NOT audited-table changes (grant-only) → ADR 010 opt-out N/A. Rollback = re-GRANT (before-state in
-- backups/2026-07-11_phase3_*.json). set_visit_status + ops.set_visit_status already authenticated-only
-- (untouched). Idempotent + atomic (single DO block).

DO $$
DECLARE r record;
BEGIN
  -- (1) Columns: lifecycle write becomes RPC-only for anon + authenticated.
  EXECUTE 'REVOKE UPDATE (visit_status, completed_at) ON public.visits FROM anon, authenticated';

  -- (2) Lifecycle RPCs in BOTH public.* and ops.*: strip PUBLIC + anon; keep authenticated + service_role.
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','ops')
      AND p.proname IN ('skip_visit','unskip_visit','delete_calendar_visit',
                        'edit_calendar_visit','ripple_reschedule_visit','create_calendar_visit')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon', r.nspname, r.proname, r.args);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %I.%I(%s) TO authenticated, service_role', r.nspname, r.proname, r.args);
  END LOOP;
END $$;
