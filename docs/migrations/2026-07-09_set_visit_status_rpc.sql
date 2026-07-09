-- 2026-07-09_set_visit_status_rpc.sql
-- PHASE 1 of the visit-lifecycle close (plan docs/handoffs/2026-07-09_visit_lifecycle_rpc_and_auth_PLAN.md,
-- commit 8c5a60e). Adds ONE authenticated-only SECURITY DEFINER RPC that owns every visit_status
-- transition the staff apps perform:
--   complete  (scheduled  -> completed)   completed_at = now()
--   uncomplete(completed  -> scheduled)   completed_at = NULL
--   skip      (scheduled  -> skipped)     stores skip_reason  + promotes next SA occurrence
--   cancel    (scheduled  -> cancelled)   NO reason column    + promotes next SA occurrence
--
-- WHY: the 2026-07-09 RLS lockdown (159e1c6) had to keep visit_status directly GRANTable to
-- anon/authenticated because the Calendar writes it directly, and visit_status='cancelled' fires
-- trg_push_visit_update -> jobber-push-visit -> a REAL Jobber visitDelete. So a holder of the public
-- anon key can still delete visits from Jobber. This RPC is the single guarded entry point that lets
-- Phase 3 REVOKE the direct visit_status/completed_at grants and make lifecycle changes RPC-only.
--
-- cancel == skip IN JOBBER (Fred 2026-07-09): both delete THIS one occurrence (via the AFTER push
-- trigger, op='delete') and PRESERVE the SA series by promoting the next scheduled occurrence. They
-- differ ONLY by the visit_status value the apps render as a label. The cancel reason is NOT persisted
-- in Phase 1 (visits_skip_reason_chk + fn_visits_skip_transition_guard both forbid skip_reason on a
-- non-skipped row, and there is no cancel_reason column) -- the label lives entirely in the status.
--
-- AUTH: authenticated staff only, email @ayache.com or @unclogme.com (the staff domain allowlist -- any
-- address at those two domains is staff; 4 have logged in so far). The domain check is defense-in-depth
-- ON TOP of the authenticated-only EXECUTE grant, so even a future mis-grant cannot let a stranger
-- with only the public anon key delete a visit.
--
-- PHASE 1 IS ADDITIVE + NON-BREAKING: all current grants stay intact (visit_status/completed_at remain
-- directly GRANTed to anon/authenticated) so no app breaks today. The direct-write REVOKE is Phase 3,
-- AFTER the apps migrate onto this RPC and go behind Supabase Auth. No cron/edge-fn calls this RPC.
--
-- ADR-010: visits stays audited (audit_visits trigger unchanged). No schema/column change.
-- Reuses the PROVEN skip_visit SA-promotion block, refactored into fn_promote_next_sa_occurrence and
-- called by BOTH skip_visit and set_visit_status (single source of truth; behavior-preserving).
-- Backup of the prior skip_visit body: backups/2026-07-09_skip_visit_before_refactor.sql.
-- Re-runnable: CREATE OR REPLACE + idempotent REVOKE/GRANT.

BEGIN;

-- 1) Shared SA-series gap-fill. Extracted VERBATIM from skip_visit (behavior-preserving): promote the
--    next scheduled, unlinked, in-Jobber-scope occurrence of a job so removing one occurrence never
--    truncates the series in Jobber. SECDEF (owner postgres) so it can UPDATE + call fn_request_jobber_push
--    (which is postgres/service_role-only). p_job_id NULL -> no-op (returns NULL).
CREATE OR REPLACE FUNCTION public.fn_promote_next_sa_occurrence(p_job_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_next bigint;
BEGIN
  IF p_job_id IS NULL THEN RETURN NULL; END IF;
  WITH cand AS (
    SELECT vx.id FROM public.visits vx
    WHERE vx.job_id = p_job_id AND vx.visit_status='scheduled' AND vx.deleted_at IS NULL
      AND vx.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
      AND vx.sync_state IS DISTINCT FROM 'pending'
      AND public.fn_visit_in_jobber_scope(vx.id)
      AND NOT EXISTS(SELECT 1 FROM public.entity_source_links e
                     WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id=vx.id)
    ORDER BY vx.visit_date, vx.id LIMIT 1)  -- vx.id = stable tie-breaker on equal visit_date
  UPDATE public.visits u SET sync_state='pending' FROM cand WHERE u.id=cand.id
  RETURNING u.id INTO v_next;
  IF v_next IS NOT NULL THEN
    PERFORM public.fn_request_jobber_push(v_next, 'upsert');
  END IF;
  RETURN v_next;
END; $fn$;
-- Supabase ALTER DEFAULT PRIVILEGES auto-grants EXECUTE to anon/authenticated/service_role on EVERY new
-- public function, so REVOKE FROM PUBLIC is NOT enough -- must revoke those roles explicitly.
REVOKE ALL ON FUNCTION public.fn_promote_next_sa_occurrence(bigint) FROM PUBLIC, anon, authenticated, service_role;
-- internal helper: ONLY the SECDEF RPCs (owner postgres) call it -> no role grant at all.

-- 2) Refactor skip_visit to call the shared helper. IDENTICAL behavior to the backed-up version
--    (same status/reason/source writes, same promotion query) -> single source of truth with cancel.
CREATE OR REPLACE FUNCTION public.skip_visit(p_visit_id bigint, p_reason text DEFAULT NULL::text)
RETURNS visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_row public.visits;
BEGIN
  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;
  IF v_row.visit_status <> 'scheduled' THEN
    RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status;
  END IF;
  UPDATE public.visits
     SET visit_status='skipped',
         skip_reason=NULLIF(btrim(coalesce(p_reason,'')),''),
         source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
   WHERE id=p_visit_id RETURNING * INTO v_row;
  PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);
  RETURN v_row;
END; $fn$;
-- skip_visit grants unchanged (keeps existing anon/authenticated/service_role EXECUTE for Phase 1).

-- 3) The guarded lifecycle RPC.
CREATE OR REPLACE FUNCTION public.set_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL::text)
RETURNS visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_row public.visits; v_email text;
BEGIN
  -- AUTH: logged-in staff only (@ayache.com / @unclogme.com). Defense-in-depth over the
  -- authenticated-only EXECUTE grant so even a mis-grant can't let the public anon key through.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'set_visit_status requires a logged-in staff user' USING ERRCODE='insufficient_privilege';
  END IF;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF v_email NOT LIKE '%@ayache.com' AND v_email NOT LIKE '%@unclogme.com' THEN
    RAISE EXCEPTION 'set_visit_status: % is not a staff account', v_email USING ERRCODE='insufficient_privilege';
  END IF;

  IF p_status NOT IN ('completed','scheduled','skipped','cancelled') THEN
    RAISE EXCEPTION 'set_visit_status: unsupported status %', p_status USING ERRCODE='check_violation';
  END IF;

  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;

  IF p_status = 'completed' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='completed', completed_at=now()
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'scheduled' THEN  -- uncomplete ONLY (un-skip lives in unskip_visit)
    IF v_row.visit_status = 'skipped' THEN
      RAISE EXCEPTION 'visit % is skipped; use unskip_visit to restore it', p_visit_id USING ERRCODE='check_violation';
    ELSIF v_row.visit_status <> 'completed' THEN
      RAISE EXCEPTION 'only a completed visit can be un-completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='scheduled', completed_at=NULL
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'skipped' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits
       SET visit_status='skipped',
           skip_reason=NULLIF(btrim(coalesce(p_reason,'')),''),
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);

  ELSE  -- 'cancelled'
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be cancelled (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    -- cancel == skip in Jobber: the AFTER push trigger deletes THIS occurrence (visit_status IN
    -- (cancelled,skipped) -> op='delete'); normalizing source makes that delete fire + bypass the
    -- origin gate, exactly as skip does. Reason not stored (no cancel_reason column in Phase 1).
    UPDATE public.visits
       SET visit_status='cancelled',
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);
  END IF;

  RETURN v_row;
END; $fn$;

-- Revoke anon + service_role EXPLICITLY (Supabase default privileges granted them on CREATE); keep only
-- authenticated. Without the explicit anon revoke the RPC would be anon-callable and only the in-body
-- auth.uid() guard would stop it -- the grant must be closed too (defense-in-depth).
REVOKE ALL ON FUNCTION public.set_visit_status(bigint, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_visit_status(bigint, text, text) TO authenticated;
-- authenticated ONLY: NOT anon (the whole point), NOT service_role (no server caller).

-- 4) SAFE HARDENING (review finding, zero app impact): fn_request_jobber_push is INTERNAL plumbing
--    (only SECDEF callers + crons use it) but still carried the default PUBLIC EXECUTE grant, so the
--    public anon key could POST /rpc/fn_request_jobber_push {p_op:'delete'} to force an arbitrary
--    Jobber delete -- a direct anon->Jobber-delete vector independent of any lifecycle RPC. Drop the
--    PUBLIC grant; postgres + service_role keep their EXPLICIT grants (ACL was {=X,postgres=X,
--    service_role=X}) so the SECDEF callers and the reconcile/SA crons are unaffected. Verified: no
--    app calls this directly (apps use create/edit/delete/skip/ripple RPCs).
REVOKE ALL ON FUNCTION public.fn_request_jobber_push(bigint, text) FROM PUBLIC, anon, authenticated;

COMMIT;

-- ── ADVERSARIAL REVIEW (2026-07-09, 4-lens + synthesis, wf_48ec33e6) — outcome ─────────────────────
-- RPC body verified correct on all functional lenses (transitions/CHECK/guard/SA-parity/push). Findings
-- were all on the GRANT surface. Fixed here: fn_request_jobber_push PUBLIC revoke (step 4), deterministic
-- promotion tie-breaker, clearer un-skip error. INTENTIONALLY DEFERRED / OUT OF SCOPE for Phase 1:
--   • skip_visit + unskip_visit remain anon-EXECUTE (ACL anon=X). Real hole, but PRE-EXISTING and
--     by-design for Phase 1: the apps are not behind login yet and call skip_visit with the anon key, so
--     revoking now would break the Calendar skip button. This is the documented Phase-3 action below.
--   • Domain guard trusts the JWT email claim. All 4 current staff are email-confirmed, so no unverified
--     staff account exists today, and NO app calls set_visit_status until Phase 2 -> the exposure is not
--     live yet. The robust fix is at the Supabase Auth CONFIG layer, required BEFORE Phase 2 cutover:
--     ►► PHASE 2 PREREQ: disable open email/password signup OR enforce email confirmation, so a stranger
--        cannot self-register an @unclogme.com/@ayache.com account and pass the domain guard. (A DB-layer
--        email_verified check was rejected: the email-provider staff user unclogme@unclogme.com has
--        identity_data.email_verified=false and the JWT claim location is version-dependent -> lockout risk.)
--
-- PHASE 3 (later, separate migration, ONLY after all staff apps migrate + go behind Supabase Auth):
--   REVOKE UPDATE (visit_status, completed_at) ON public.visits FROM anon, authenticated;
--   REVOKE EXECUTE ON FUNCTION public.skip_visit(bigint,text), public.unskip_visit(bigint),
--     public.delete_calendar_visit(bigint), public.edit_calendar_visit(bigint,jsonb),
--     public.ripple_reschedule_visit(...), public.create_calendar_visit(...) FROM anon;  (-> authenticated only)
-- then re-run rls_verify.js: anon cancel/skip/delete must all 42501.
