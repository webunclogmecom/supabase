-- Migration: 2026-07-03g_skip_roundB_fixes.sql
-- Author: Claude (Supabase session)
-- Round-B adversarial smoke test fixes (see WORKING-NOW.md / round-B verdict):
--   #3 push_health not_in_jobber arm gated on fn_visit_in_jobber_scope (was 512 rows of
--      beyond-horizon noise burying the skip_removal_failed alarm)
--   #4a skip_visit gap-fill dedup via sync_state='pending' (concurrent sibling skips no longer
--      double-enqueue the same unlinked candidate; resolve-stale cron becomes the retry driver)
--   trigger hardening: guard also fires on completed_at/completed_by writes
-- Companion edge-fn fixes deployed same cycle: jobber-push-visit CREATE race guard + compensation;
-- sync-jobber-upcoming-visits heartbeat + chunking (fix #2). UI drag fix in the Lovable app (fix #1).
BEGIN;
-- Round-B fix #3: gate the not_in_jobber arm on the Jobber horizon. Since the 60d-Jobber/6mo-DB
-- split, beyond-horizon cron visits are INTENTIONALLY DB-only — they flooded this view (512/517
-- rows tonight), drowning the skip_removal_failed alarm. Only in-horizon unlinked visits are a
-- real problem.
CREATE OR REPLACE VIEW ops.v_calendar_push_health AS SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'push_failed'::text AS issue,
    f.reason,
    f.detail,
    f.created_at AS since
   FROM visit_sync_flags f
     JOIN visits v ON v.id = f.visit_id
     JOIN clients c ON c.id = v.client_id
  WHERE f.resolved_at IS NULL AND v.deleted_at IS NULL
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'not_in_jobber'::text AS issue,
    NULL::text AS reason,
    NULL::text AS detail,
    v.created_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE (v.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])) AND v.visit_status = 'scheduled'::text AND v.deleted_at IS NULL AND v.created_at < (now() - '00:15:00'::interval) AND public.fn_visit_in_jobber_scope(v.id) AND NOT (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'skip_removal_failed'::text AS issue,
    'skipped visit still linked to Jobber (removal did not complete)'::text AS reason,
    v.sync_state AS detail,
    v.updated_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE v.visit_status = 'skipped'::text AND v.deleted_at IS NULL AND (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id));

-- Round-B fix #4a: gap-fill dedup. Marking the candidate 'pending' up-front (a) dedups concurrent
-- gap-fills (a sibling skip in the pg_net dispatch window no longer re-enqueues the same candidate)
-- and (b) enrolls the resolve-stale cron as the retry driver if the push dies.
CREATE OR REPLACE FUNCTION public.skip_visit(p_visit_id bigint, p_reason text DEFAULT NULL)
 RETURNS public.visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE v_row public.visits; v_next bigint;
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
  WITH cand AS (
    SELECT vx.id FROM public.visits vx
    WHERE vx.job_id = v_row.job_id AND vx.visit_status='scheduled' AND vx.deleted_at IS NULL
      AND vx.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
      AND vx.sync_state IS DISTINCT FROM 'pending'
      AND public.fn_visit_in_jobber_scope(vx.id)
      AND NOT EXISTS(SELECT 1 FROM public.entity_source_links e WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id=vx.id)
    ORDER BY vx.visit_date LIMIT 1)
  UPDATE public.visits u SET sync_state='pending' FROM cand WHERE u.id=cand.id
  RETURNING u.id INTO v_next;
  IF v_next IS NOT NULL THEN
    PERFORM public.fn_request_jobber_push(v_next, 'upsert');
  END IF;
  RETURN v_row;
END; $fn$;

-- Round-B trigger hardening: also fire on completed_at/completed_by so a raw-SQL repair write
-- cannot stamp a completion timestamp onto a skipped row without the guard clearing it.
DROP TRIGGER IF EXISTS trg_visits_skip_transition_guard ON public.visits;
CREATE TRIGGER trg_visits_skip_transition_guard
  BEFORE INSERT OR UPDATE OF visit_status, skip_reason, completed_at, completed_by ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.fn_visits_skip_transition_guard();
COMMIT;