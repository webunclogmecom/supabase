-- ============================================================================
-- 2026-07-27c — Wave A1b: narrow the zones WRITE policies to authenticated-only
-- ============================================================================
-- FOUND BY: the Building Apps session, while documenting the Calendar zone
-- editor (the feature I nearly revoked — see 2026-07-27b's header).
--
-- THE SHAPE (verified independently before acting):
--   policies  zones_anon_insert / zones_anon_update  are  TO {anon, authenticated}
--   grants    anon = SELECT only; authenticated = SELECT, INSERT, UPDATE
-- So anon genuinely CANNOT write today — verified with a rolled-back probe as
-- `anon`: "permission denied for table zones". But the POLICY is pre-armed: the
-- instant anyone grants INSERT/UPDATE to anon, the table opens with **no policy
-- change to review**. That is the identical latent shape as the gdos column
-- grants dropped in 2026-07-27b — the grant and the policy disagreeing, with only
-- the grant holding the line ([[feedback_permission_audit_column_grants_and_truncate]]).
--
-- FIX: recreate the two WRITE policies TO authenticated only, preserving their
-- predicates EXACTLY (INSERT: WITH CHECK true; UPDATE: USING true, WITH CHECK
-- true). The SELECT policy KEEPS {anon, authenticated} — anon read is intended
-- (the apps read zones for display).
--
-- ⚠ NON-BREAKING, AND THIS IS THE FEATURE I ALMOST BROKE: public.zones is written
-- by the LIVE Visit Calendar zone editor (audit.logs: app_source='visit-calendar',
-- 31 UPDATE + 1 INSERT), which runs as `authenticated` and is unaffected — it
-- keeps exactly the access it has today. This narrows only a role that already
-- has no grant. Post-apply probes assert BOTH: authenticated can still write,
-- anon still cannot.
--
-- NOT DONE HERE (deliberate): actually narrowing WHO among staff may edit zones.
-- zones.code is the single source of truth for zone display app-wide, so edit
-- rights arguably belong to admins only — but that is the planned role-gating
-- work (Building Apps CLAUDE.md rule #7), not a permission sweep, and doing it
-- here would break the shipped Calendar feature.
--
-- Rollback: recreate the two policies with roles {anon, authenticated} and the
-- same predicates. Reversible, no data touched.
-- AUDIT (ADR 010): policy change only; zones keeps audit_zones.
-- ============================================================================

begin;

drop policy if exists "zones_anon_insert" on public.zones;
create policy "zones_authenticated_insert" on public.zones
  as permissive for insert to authenticated
  with check (true);

drop policy if exists "zones_anon_update" on public.zones;
create policy "zones_authenticated_update" on public.zones
  as permissive for update to authenticated
  using (true) with check (true);

-- zones_anon_select_all intentionally UNCHANGED (anon read is intended).

commit;
