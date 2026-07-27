-- ============================================================================
-- 2026-07-27b — Wave A1: drop the dead column-level UPDATE grants on gdos
-- ============================================================================
-- CONTEXT: 2026-07-27 dropped the permissive `anon_update_gdo_labels` policy on
-- public.gdos. Behind it sat COLUMN-level UPDATE grants to `authenticated` on
-- location_label, notes, property_id, status — invisible to a table-level grant
-- check, and the actual reason that policy existed
-- ([[feedback_permission_audit_column_grants_and_truncate]]).
--
-- They are ALREADY INERT: with RLS on and no UPDATE policy, an UPDATE as
-- `authenticated` affects 0 rows (verified with a rolled-back probe). This drops
-- the grants so the landmine cannot re-arm the moment someone adds an UPDATE
-- policy — and so the Client App phase-2 wave-1 SECDEF RPC becomes the ONLY
-- write path to gdos, which is the agreed contract.
--
-- NON-BREAKING: audit.logs shows every gdos write is db_role `postgres`
-- (sql/scripts/webhook). Zero writes from `authenticated`. postgres +
-- service_role keep full access, so the sync scripts, edge fns and the coming
-- RPCs are unaffected.
--
-- ⚠ DELIBERATELY NOT INCLUDED — public.zones. I had flagged zones as writable by
-- `authenticated` and intended to revoke it here. VERIFICATION SAYS NO: audit.logs
-- shows `app_source='visit-calendar'` performing 31 UPDATEs + 1 INSERT on zones —
-- it is a REAL shipped Calendar feature (the zone editor), backed by
-- zones_anon_insert / zones_anon_update policies and a
-- zones_cascade_code_rename_trg that handles code renames. Revoking would have
-- silently broken it. If zones write access should be narrowed, the correct move
-- is role-gating it (admin-only) as part of the planned role-based delete work,
-- NOT a blanket revoke.
--
-- Rollback: re-GRANT UPDATE (location_label, notes, property_id, status) ON
-- public.gdos TO authenticated. Reversible, no data touched.
-- AUDIT (ADR 010): grant change only; gdos keeps its audit trigger.
-- ============================================================================

begin;

revoke update (location_label, notes, property_id, status) on public.gdos from authenticated;
revoke update on public.gdos from authenticated;
revoke update on public.gdos from anon;

commit;
