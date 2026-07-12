-- 2026-07-11_anon_column_harden.sql
-- PHASE-3 FOLLOW-UP: close the last anon WRITE surface on business data (Fred-routed via Building Apps).
-- Phase 3 (2026-07-11_phase3_visit_lifecycle_lock.sql) locked the Jobber-delete vectors but deliberately
-- LEFT 4 data-integrity columns anon-writable ("not Jobber-delete vectors"). Now that all 4 staff apps run
-- `authenticated` (Phase-2 login gates live) and Field Portal is read-only, those anon grants are pure
-- legacy — no legitimate anon writer remains (crons run as service_role). This makes them authenticated-only,
-- mirroring Phase 3. Result: anon is FULLY READ-ONLY on visits + properties business data.
--
-- VERIFIED before writing (backups/2026-07-11_anon_column_harden_before.json): all 4 columns had explicit
-- column grants {anon=w, authenticated=w} — NO PUBLIC (`=w`) grant, so no default-privilege trap; service_role
-- writes via table-level (relacl arwdDxtm), so the anon column-grant REVOKE does not touch it. authenticated
-- keeps the explicit column grant (apps keep working — Building Apps independently confirmed authenticated=true
-- on all 4). Grant-only change (no audited-table schema change → ADR 010 N/A). Rollback = re-GRANT.
--
-- NOTE: the now-moot anon RLS policies (anon_update_visit_derm_required, visits_calendar_update,
-- properties_anon_update_manhole_authn) are left in place — harmless dead policies once the column grant is
-- gone (column privilege is checked before RLS → anon 42501 regardless). Optional cleanup, non-load-bearing.

REVOKE UPDATE (derm_required, manhole_count)            ON public.visits     FROM anon;
REVOKE UPDATE (grease_trap_manhole_count, sample_port_count) ON public.properties FROM anon;
