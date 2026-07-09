-- 2026-07-09_visits_rls_lockdown.sql
-- Push-safety audit finding (b), Fred-authorized: public.visits had UPDATE policies
-- visits_anon_update_manhole (anon) + _authn (authenticated), both USING(true)/CHECK(true)
-- with UPDATE granted on ALL columns. PROVEN exploitable: the Prod anon key ships in every
-- public Lovable bundle; with it, a bare PATCH set visit_status='cancelled' AND deleted_at on
-- any visit (verified live 2026-07-09 on throwaway visit 7078) -> trg_push_visit_update fires
-- op='delete' for ANY source -> a REAL Jobber visitDelete + unlink.
--
-- FIX MECHANISM: Postgres RLS cannot compare OLD vs NEW columns, so column scoping is done via
-- column-level UPDATE GRANTS. PostgREST puts PATCH-body columns straight into the UPDATE target
-- list; Postgres rejects any non-granted column with SQLSTATE 42501 -> PostgREST HTTP 403 — a
-- hard, atomic failure (the whole statement writes nothing; never a silent strip).
--
-- EVIDENCE (5 live app bundles + 30-day audit census): the ONLY columns any anon/authenticated
-- app writes DIRECTLY to public.visits are:
--   visit_status, completed_at  (Visit Calendar: mark complete/incomplete, edit-dialog status)
--   manhole_count               (Admin Review: manhole editor + legacy Prod-mirror double-write)
--   derm_required               (DERM Tracker: bulk + single 'DERM not required' toggle)
-- NOTHING else — deleted_at (0 anon writes/30d), visit_date, start_at/end_at, source, sync_state,
-- job_id, client_id, vehicle_id, title, notes, completed_by, derm_required_locked — all go via
-- SECURITY DEFINER RPCs (owner postgres, BYPASSRLS) or service_role, unaffected by this change.
-- derm_required_locked is set by BEFORE trigger trg_derm_required_lock (trigger assignments are
-- NOT privilege-checked), and the DERM bundle sends only {derm_required} — both verified live.
--
-- ADR-010: no audit change (visits stays audited). Backup: backups/2026-07-09_visits_rls_before.json.
-- @Supabase (1) + @Building Apps: apps write visits via RPCs + these 4 columns only — do NOT add a
-- new direct anon/authenticated visits column-write without adding it to the GRANT below.

BEGIN;

-- 1) drop the wide-open UPDATE pair + the dormant anon INSERT path (1 anon INSERT ever, 2026-06-10;
--    current Calendar creates via create_calendar_visit RPC)
DROP POLICY IF EXISTS "visits_anon_update_manhole" ON public.visits;
DROP POLICY IF EXISTS "visits_anon_update_manhole_authn" ON public.visits;
DROP POLICY IF EXISTS "visits_calendar_insert" ON public.visits;

-- 2) scoped replacement ROW policies (live rows only). Both role twins load-bearing: Calendar
--    (sb-remember) + Admin Review (persistSession) can carry real auth JWTs; DERM Tracker always anon.
--    Column scope is the grant in step 3; the row scope forbids acting on already-soft-deleted rows.
--    NO visit_status-value WITH CHECK (would break the Calendar cancel transition + a value constraint
--    would reject an app's derm_required write on an already-skipped row — see residual note).
CREATE POLICY "visits_app_update_anon" ON public.visits
  FOR UPDATE TO anon
  USING (deleted_at IS NULL) WITH CHECK (deleted_at IS NULL);
CREATE POLICY "visits_app_update_authn" ON public.visits
  FOR UPDATE TO authenticated
  USING (deleted_at IS NULL) WITH CHECK (deleted_at IS NULL);
COMMENT ON POLICY "visits_app_update_anon" ON public.visits IS
  'App direct-PATCH row scope (live rows). Columns limited by column-level UPDATE grant: visit_status, completed_at, manhole_count, derm_required. 2026-07-09 RLS lockdown.';

-- 3) column-scope the UPDATE privilege = the exact bundle-verified set, nothing else.
REVOKE UPDATE ON public.visits FROM anon, authenticated;
GRANT UPDATE (visit_status, completed_at, manhole_count, derm_required)
  ON public.visits TO anon, authenticated;

-- 4) retire the dormant direct-INSERT privilege (all real inserters are service_role/postgres)
REVOKE INSERT ON public.visits FROM anon, authenticated;

COMMIT;

-- LEFT INTACT: SELECT policies (needed for .update().select() return=representation + .eq filters);
--   the redundant anon_update_visit_derm_required + visits_calendar_update policies (now column-subsumed
--   by the grant — they can only ever permit the 4 granted columns); all SECDEF RPCs.
--
-- ACCEPTED RESIDUAL (flagged to Fred, needs a bigger follow-up — NOT closed here): an anon-key holder can
-- still (a) PATCH visit_status='cancelled' on a live visit -> Jobber visitDelete (visit_status must stay
-- grantable for the Calendar cancel/complete flow, and a value-WITH-CHECK risks breaking cross-app writes),
-- and (b) call the intentionally-anon SECDEF RPCs (delete_calendar_visit soft-delete -> push, edit/ripple/
-- skip). Both are inherent to UNAUTHENTICATED Lovable apps. The lockdown strictly shrinks the surface
-- (deleted_at + all schedule/date/attribution/source/sync columns closed). FULL close = migrate Calendar's
-- 3 direct status writes into a guarded SECDEF set_visit_status RPC, REVOKE UPDATE(visit_status,completed_at),
-- then put the apps behind Supabase Auth. FUTURE-COLUMN RULE: any new app-writable visits column must be
-- explicitly GRANT UPDATE(col)'d to anon/authenticated.
