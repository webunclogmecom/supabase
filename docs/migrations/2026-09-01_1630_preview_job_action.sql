-- 2026-09-01_1630_preview_job_action.sql
--
-- WHAT: client.preview_job_action(p_client_id, p_job_id, p_action) -> jsonb. A READ-ONLY describer
--   that returns exactly what each Client-App job-action confirmation dialog needs to render: the
--   acted job, the client status transition (if any), the jobs that will close, the upcoming visits
--   that will be removed, and whether the client will be archived/un-archived in Jobber.
--   Phase B of the client job-status lifecycle plan
--   (docs/superpowers/plans/2026-09-01-client-job-status-lifecycle.md,
--    spec docs/superpowers/specs/2026-09-01-client-job-status-lifecycle-design.md).
--
-- WHY A SECDEF DESCRIBER: the app must show a truthful, single-source preview before it fires
--   save-client-job / update_client_status / archive-client / unarchive-client. Computing the
--   transition in one place (here) stops the dialog text and the actual write from disagreeing.
--   It performs NO writes; it only SELECTs, so it cannot corrupt anything and needs no rollback to test.
--
-- STATUS RULES (mirror the spec + Supabase/CLAUDE.md "clients.status"):
--   create  (any job)  + ACTIVE   -> RECURRING        (creating an SA makes an active client recurrent)
--   reopen  SA         + ACTIVE   -> RECURRING
--   reopen  SC         + INACTIVE -> ACTIVE  (+ will_unarchive_client) -- the reactivation entry
--   close   SA (last)  (no other non-archived SA) -> ACTIVE
--   close   SC                    -> INACTIVE (+ will_archive_client), lists EVERY open job to close
--   anything else                 -> status_change null (a plain confirm; no status move)
--
-- Job kind is TITLE-ONLY, matching the whole estate: SA = title ILIKE 'Service Agreement%',
--   SC = lower(btrim(title)) = 'service call', else legacy. "Open" job = job_status <> 'archived'
--   (our sync maps Jobber closed/destroyed to 'archived'; there is no 'closed'/'destroyed' in
--    public.jobs.job_status, measured 2026-09-01: archived/action_required/upcoming/today/
--    requires_invoicing/active/late).
--
-- AUDIT: read-only function, nothing to audit.
-- GRANTS: authenticated + service_role EXECUTE (the app calls it as the signed-in user; edge fns as
--   service_role). REVOKE from PUBLIC + anon (anon is read-only on business data and must not reach it).

BEGIN;

CREATE OR REPLACE FUNCTION client.preview_job_action(p_client_id bigint, p_job_id bigint, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_status        text;
  v_job           jsonb;
  v_kind          text;
  v_jobs_to_close jsonb := '[]'::jsonb;
  v_upcoming      int   := 0;
  v_other_sa      int   := 0;
  v_from          text;
  v_to            text  := null;
  v_arch          bool  := false;
  v_unarch        bool  := false;
BEGIN
  SELECT status INTO v_status FROM public.clients WHERE id = p_client_id;
  v_from := v_status;

  -- classify the acted job (title-only). p_job_id NULL (the 'create' case) leaves v_job/v_kind NULL.
  SELECT jsonb_build_object(
           'job_number', j.job_number,
           'title', j.title,
           'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                        WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                        ELSE 'legacy' END,
           'frequency_days', j.frequency_days,
           'job_status', j.job_status),
         (CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
               WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
               ELSE 'legacy' END)
    INTO v_job, v_kind
    FROM public.jobs j
   WHERE j.id = p_job_id;

  IF p_action = 'create' THEN
    IF v_status = 'ACTIVE' THEN v_to := 'RECURRING'; END IF;

  ELSIF p_action = 'reopen' AND v_kind = 'SA' AND v_status = 'ACTIVE' THEN
    v_to := 'RECURRING';

  ELSIF p_action = 'reopen' AND v_kind = 'SC' AND v_status = 'INACTIVE' THEN
    v_to := 'ACTIVE';
    v_unarch := true;

  ELSIF p_action = 'close' AND v_kind = 'SA' THEN
    SELECT count(*) INTO v_other_sa
      FROM public.jobs
     WHERE client_id = p_client_id AND id <> p_job_id
       AND title ILIKE 'Service Agreement%' AND job_status <> 'archived';
    IF v_other_sa = 0 THEN v_to := 'ACTIVE'; END IF;
    v_jobs_to_close := (SELECT jsonb_agg(x) FROM (SELECT v_job AS x) t);
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live
     WHERE job_id = p_job_id AND visit_status = 'scheduled'
       AND deleted_at IS NULL AND start_at >= now();

  ELSIF p_action = 'close' AND v_kind = 'SC' THEN
    v_to := 'INACTIVE';
    v_arch := true;
    SELECT jsonb_agg(jsonb_build_object(
             'job_number', j.job_number,
             'title', j.title,
             'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                          WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                          ELSE 'legacy' END,
             'upcoming_visits', (SELECT count(*) FROM client.v_visits_live vv
                                   WHERE vv.job_id = j.id AND vv.visit_status = 'scheduled'
                                     AND vv.deleted_at IS NULL AND vv.start_at >= now())))
      INTO v_jobs_to_close
      FROM public.jobs j
     WHERE j.client_id = p_client_id AND j.job_status <> 'archived';
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live vv
      JOIN public.jobs j ON j.id = vv.job_id
     WHERE j.client_id = p_client_id AND j.job_status <> 'archived'
       AND vv.visit_status = 'scheduled' AND vv.deleted_at IS NULL AND vv.start_at >= now();
  END IF;

  RETURN jsonb_build_object(
    'job', v_job,
    'action', p_action,
    'status_change', CASE WHEN v_to IS NULL THEN null
                          ELSE jsonb_build_object('from', v_from, 'to', v_to) END,
    'jobs_to_close', COALESCE(v_jobs_to_close, '[]'::jsonb),
    'upcoming_visits_removed', v_upcoming,
    'other_open_sa_count', v_other_sa,
    'will_archive_client', v_arch,
    'will_unarchive_client', v_unarch);
END
$fn$;

REVOKE ALL ON FUNCTION client.preview_job_action(bigint, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.preview_job_action(bigint, bigint, text) FROM anon;
GRANT EXECUTE ON FUNCTION client.preview_job_action(bigint, bigint, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
