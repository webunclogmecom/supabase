-- ============================================================================
-- 2026-10-18_0245_call_before_scheduling
-- Call before scheduling: a reminder to phone the clients who must approve each visit, as a DATELESS To Be
-- Scheduled item and an 11 AM Slack post. Built from the approved design of 2026-08-17.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18, "go ahead", on "build the call-first reminder that 226-JER fell through". Design and Fred's
--   decisions: docs/superpowers/specs/2026-08-17-call-before-scheduling-clients-design.md ("DESIGN APPROVED, NOT
--   BUILT"; plan docs/superpowers/plans/2026-08-17-call-before-scheduling-clients.md). Defaults taken from its open
--   questions: the policy is kept by hand; the request appears 3 days before the call is due; Slack goes to
--   #apps-notifications at 11 AM ET tagging Diego (today's reminder standard, docs/reference/slack-notifications.md).
-- WHY NOW (measured 2026-10-17): 226-JER Jerusalem Pizza, GDO-03256 max 60 days, last service 2026-08-17, nothing
--   booked, no request: 61 days. Its Service Agreement (the reminder Diego had made himself) was archived on
--   2026-10-05 with nothing in its place.
-- WHAT IS BUILT
--   ops.client_call_policy (new table, AUDITED: audit_client_call_policy; human-edited policy, rule 8 opt-in), with
--   SELECT for staff, no direct writes. ops.visit_requests + call_required, announced_at (already audited:
--   audit_visit_requests). ops.v_visit_requests + call_required (appended; the Calendar reads it).
--   ops.v_client_call_policy: the policy with the last visit, the effective due date and the permit ceiling as a
--   WARNING (it drives nothing; ops.v_service_due stays retired, Fred 2026-07-30).
--   ops.fn_file_due_call_requests: moves next_call_at to the latest live visit + cadence (however it was booked),
--   closes an open call request a later booking answered, files one request through ops.create_visit_request
--   (its own checks) 3 days before the due date. A request is not a visit: nothing reaches Jobber (VERIFY 2).
--   ops.snooze_call_request ("Not now", the date the client gave; staff EXECUTE, plain messages).
--   ops.fn_call_first_run: the filer + the list the post shows (new arrivals; every open one on Mondays) + marks them
--   announced; a dry run changes nothing. public.fn_request_call_first_reminder + cron call-first-reminder (11 AM ET).
--   Seed: 226-JER, every 60 days, job 1623 (Service Call 99900891), service 09.
-- NOT BUILT HERE: the Calendar chip and the Not now button (Lovable 6533c3ee, same day); the edge function
--   call-first-reminder (deployed with this).
-- ROLLBACK: 2026-10-18_rollback_call_before_scheduling.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_viewdef('ops.v_visit_requests'::regclass)) IS DISTINCT FROM 'bb93a2ffc2836f062b34dd9426ab44e6' THEN
    RAISE EXCEPTION 'ops.v_visit_requests changed since this file was written: splice again';
  END IF;
  IF to_regclass('ops.client_call_policy') IS NOT NULL OR EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'call-first-reminder') THEN
    RAISE EXCEPTION 'already applied';
  END IF;
END $g$;
CREATE TEMP TABLE vr_before ON COMMIT DROP AS SELECT to_jsonb(v) AS j FROM ops.v_visit_requests v;

-- 1. the policy: one row per client we must call for approval before scheduling (kept by hand: spec question 2)
CREATE TABLE ops.client_call_policy (
  client_id             bigint      PRIMARY KEY REFERENCES public.clients(id),
  job_id                bigint      NOT NULL REFERENCES public.jobs(id),
  service_line_item_ids bigint[]    NOT NULL CHECK (cardinality(service_line_item_ids) > 0),
  cadence_days          int         NOT NULL CHECK (cadence_days BETWEEN 1 AND 400),
  next_call_at          date        NOT NULL,
  paused                boolean     NOT NULL DEFAULT false,
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.client_call_policy IS 'Clients that must approve each visit by phone before we schedule (spec 2026-08-17, built 2026-10-18). ops.fn_file_due_call_requests files a DATELESS To Be Scheduled request (call_required) 3 days before the call is due; nothing here creates a visit or reaches Jobber. Kept by hand. Migration 2026-10-18_0245.';
COMMENT ON COLUMN ops.client_call_policy.next_call_at IS 'When the next call is due. Moved forward by the filer to the latest live visit + cadence_days (however that visit was booked), or to the date the client gave (ops.snooze_call_request).';
COMMENT ON COLUMN ops.client_call_policy.job_id IS 'The client''s Service Call job the request is filed on (ops.create_visit_request needs an active job).';
CREATE TRIGGER audit_client_call_policy AFTER INSERT OR UPDATE OR DELETE ON ops.client_call_policy
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER trg_client_call_policy_updated_at BEFORE UPDATE ON ops.client_call_policy
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
REVOKE ALL ON ops.client_call_policy FROM PUBLIC, anon, authenticated;
GRANT SELECT ON ops.client_call_policy TO authenticated, service_role;

-- 2. the queue item knows it needs a call, and when it was announced in Slack
ALTER TABLE ops.visit_requests
  ADD COLUMN call_required boolean NOT NULL DEFAULT false,
  ADD COLUMN announced_at  timestamptz;
COMMENT ON COLUMN ops.visit_requests.call_required IS 'TRUE when ops.fn_file_due_call_requests filed it: phone the client for approval before scheduling. Changes nothing about scheduling.';
COMMENT ON COLUMN ops.visit_requests.announced_at IS 'When the 11 AM call-first Slack post named it (new arrivals only, all open ones on Mondays).';

-- 3. the policy with what the app and the post show (the permit ceiling is a WARNING only, spec section "GDO ceiling")
CREATE VIEW ops.v_client_call_policy AS
SELECT p.client_id, c.client_code, c.name AS client_name, p.job_id, p.service_line_item_ids, p.cadence_days,
       p.next_call_at, p.paused, p.notes,
       lv.last_visit_date, lv.last_completed_date,
       greatest(p.next_call_at, lv.last_visit_date + p.cadence_days) AS call_due_at,
       g.gdo_number, g.max_frequency_days AS permit_max_days,
       (g.max_frequency_days IS NOT NULL AND p.cadence_days > g.max_frequency_days) AS cadence_exceeds_permit
  FROM ops.client_call_policy p
  JOIN public.clients c ON c.id = p.client_id
  LEFT JOIN LATERAL (
    SELECT max(v.visit_date) AS last_visit_date,
           max(v.visit_date) FILTER (WHERE v.visit_status = 'completed') AS last_completed_date
      FROM public.visits v
     WHERE v.client_id = p.client_id AND v.deleted_at IS NULL AND v.visit_status NOT IN ('cancelled', 'skipped')) lv ON true
  LEFT JOIN LATERAL (
    SELECT g2.gdo_number, g2.max_frequency_days
      FROM public.gdos g2
     WHERE g2.client_id = p.client_id AND g2.status = 'ACTIVE' AND g2.max_frequency_days IS NOT NULL
     ORDER BY g2.max_frequency_days, g2.gdo_number
     LIMIT 1) g ON true;
REVOKE ALL ON ops.v_client_call_policy FROM PUBLIC, anon;
GRANT SELECT ON ops.v_client_call_policy TO authenticated, service_role;

-- 4. the daily filer. Moves next_call_at forward when a later visit exists (however it was booked), closes an
--    open call request a booking has answered, and files one dateless request 3 days before the call is due.
CREATE FUNCTION ops.fn_file_due_call_requests()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops'
AS $function$
DECLARE
  c_lead_days CONSTANT int := 3;   -- spec question 3: file this many days before the call is due (one constant)
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  p record; q record; v_req bigint;
  v_filed jsonb := '[]'::jsonb; v_moved jsonb := '[]'::jsonb; v_closed jsonb := '[]'::jsonb; v_errors jsonb := '[]'::jsonb;
BEGIN
  FOR p IN SELECT * FROM ops.v_client_call_policy WHERE NOT paused ORDER BY client_code LOOP
    <<one_client>>
    BEGIN
      IF p.call_due_at > p.next_call_at THEN
        UPDATE ops.client_call_policy SET next_call_at = p.call_due_at WHERE client_id = p.client_id;
        v_moved := v_moved || jsonb_build_object('client', p.client_code, 'next_call_at', p.call_due_at);
      END IF;
      -- an open call request that a later booking answered leaves the queue
      FOR q IN SELECT r.id, (SELECT min(v.id) FROM public.visits v
                              WHERE v.client_id = r.client_id AND v.deleted_at IS NULL
                                AND v.visit_status NOT IN ('cancelled', 'skipped') AND v.created_at > r.created_at) AS visit_id
                 FROM ops.visit_requests r
                WHERE r.client_id = p.client_id AND r.call_required AND r.status = 'open' AND r.deleted_at IS NULL LOOP
        IF q.visit_id IS NOT NULL THEN
          PERFORM ops.cancel_visit_request(q.id, 'Booked: visit ' || q.visit_id);
          v_closed := v_closed || jsonb_build_object('client', p.client_code, 'request_id', q.id, 'visit_id', q.visit_id);
        END IF;
      END LOOP;
      IF p.call_due_at - c_lead_days <= v_today
         AND NOT EXISTS (SELECT 1 FROM ops.visit_requests r
                          WHERE r.client_id = p.client_id AND r.call_required AND r.status = 'open' AND r.deleted_at IS NULL) THEN
        v_req := ops.create_visit_request(
          p_client_id => p.client_id, p_job_id => p.job_id, p_service_line_item_ids => p.service_line_item_ids,
          p_property_id => (SELECT pr.id FROM public.properties pr
                             WHERE pr.client_id = p.client_id AND pr.deleted_at IS NULL ORDER BY pr.is_primary DESC, pr.id LIMIT 1),
          p_title => 'Call for approval',
          p_notes => 'Call the client for approval before scheduling. Call due ' || to_char(p.call_due_at, 'Mon FMDD')
                     || '. Every ' || p.cadence_days || ' days'
                     || CASE WHEN p.permit_max_days IS NOT NULL THEN ' (permit ' || p.gdo_number || ' allows ' || p.permit_max_days || ')' ELSE '' END
                     || CASE WHEN p.last_completed_date IS NOT NULL THEN '. Last service ' || to_char(p.last_completed_date, 'Mon FMDD') ELSE '' END
                     || '.' || coalesce(' ' || nullif(btrim(p.notes), ''), ''));
        UPDATE ops.visit_requests SET call_required = true WHERE id = v_req;
        v_filed := v_filed || jsonb_build_object('client', p.client_code, 'request_id', v_req, 'call_due_at', p.call_due_at);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('client', p.client_code, 'client_name', p.client_name, 'error', SQLERRM);
    END one_client;
  END LOOP;
  RETURN jsonb_build_object('filed', v_filed, 'moved', v_moved, 'closed', v_closed, 'errors', v_errors, 'lead_days', c_lead_days);
END $function$;
REVOKE ALL ON FUNCTION ops.fn_file_due_call_requests() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_file_due_call_requests() TO service_role;

-- 5. "Not now": the client named a date. The request leaves the queue and comes back 3 days before that date.
CREATE FUNCTION ops.snooze_call_request(p_request_id bigint, p_next_call_at date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops'
AS $function$
DECLARE v_client bigint; v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  IF p_next_call_at IS NULL OR p_next_call_at <= v_today THEN
    RAISE EXCEPTION 'Pick a date after today for the next call.' USING ERRCODE = '22023';
  END IF;
  IF p_next_call_at > v_today + 365 THEN
    RAISE EXCEPTION 'Pick a date within the next year for the next call.' USING ERRCODE = '22023';
  END IF;
  SELECT r.client_id INTO v_client FROM ops.visit_requests r
   WHERE r.id = p_request_id AND r.call_required AND r.status = 'open' AND r.deleted_at IS NULL;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'This call reminder is no longer waiting. Refresh the list.' USING ERRCODE = 'P0002', DETAIL = 'request=' || p_request_id;
  END IF;
  UPDATE ops.client_call_policy SET next_call_at = p_next_call_at WHERE client_id = v_client;
  PERFORM ops.cancel_visit_request(p_request_id, 'Not now: call again ' || to_char(p_next_call_at, 'Mon FMDD, YYYY'));
END $function$;
REVOKE ALL ON FUNCTION ops.snooze_call_request(bigint, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.snooze_call_request(bigint, date) TO authenticated, service_role;

-- 6. what the 11 AM post shows: runs the filer (unless a dry run), then lists the open call requests not yet announced
--    (every open one on Mondays, the weekly digest), and marks them announced. A dry run changes nothing.
CREATE FUNCTION ops.fn_call_first_run(p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops'
AS $function$
DECLARE v_filer jsonb; v_items jsonb; v_weekly boolean := extract(isodow FROM now() AT TIME ZONE 'America/New_York') = 1;
BEGIN
  <<run>>
  BEGIN
    v_filer := ops.fn_file_due_call_requests();
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'request_id', r.id, 'client_code', p.client_code, 'client_name', p.client_name,
             'call_due_at', p.call_due_at, 'last_completed_date', p.last_completed_date, 'cadence_days', p.cadence_days,
             'gdo_number', p.gdo_number, 'permit_max_days', p.permit_max_days, 'cadence_exceeds_permit', p.cadence_exceeds_permit,
             'new', r.announced_at IS NULL, 'filed_at', r.created_at) ORDER BY p.call_due_at, p.client_code), '[]'::jsonb)
      INTO v_items
      FROM ops.visit_requests r JOIN ops.v_client_call_policy p ON p.client_id = r.client_id
     WHERE r.call_required AND r.status = 'open' AND r.deleted_at IS NULL AND (r.announced_at IS NULL OR v_weekly);
    UPDATE ops.visit_requests SET announced_at = now()
     WHERE id IN (SELECT (e->>'request_id')::bigint FROM jsonb_array_elements(v_items) e) AND announced_at IS NULL;
    IF p_dry_run THEN RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'dry run'; END IF;
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;   -- a dry run: everything above is undone, the answer is kept
  END run;
  RETURN jsonb_build_object('dry_run', p_dry_run, 'weekly', v_weekly, 'filer', v_filer, 'items', v_items);
END $function$;
REVOKE ALL ON FUNCTION ops.fn_call_first_run(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_call_first_run(boolean) TO service_role;

-- 7. the 11 AM wrapper (the Stamp reminder's pattern: two UTC runs, only the one that is 11 AM in New York goes on)
CREATE FUNCTION public.fn_request_call_first_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the call-first reminder';
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('call_first_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The call-first Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/call-first-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;
REVOKE ALL ON FUNCTION public.fn_request_call_first_reminder() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_request_call_first_reminder() TO service_role;
SELECT cron.schedule('call-first-reminder', '0 15,16 * * *', $$select public.fn_request_call_first_reminder();$$);

-- 8. 226-JER Jerusalem Pizza, the client this was designed for: every 60 days (its permit GDO-03256 allows 60), on its
--    Service Call job 1623 (99900891), service 09 Service Call - Pumping. Last service 2026-08-17 (visit 7797), so the
--    call was due 2026-10-16: the first run files it at once.
INSERT INTO ops.client_call_policy (client_id, job_id, service_line_item_ids, cadence_days, next_call_at, notes)
SELECT c.id, 1623, ARRAY[9]::bigint[], 60, DATE '2026-10-16', 'The owner approves each visit by phone.'
  FROM public.clients c WHERE c.client_code = '226-JER';

CREATE OR REPLACE VIEW ops.v_visit_requests AS
 SELECT r.id,
    r.client_id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    r.job_id,
    j.job_number,
    j.title AS job_title,
    r.title,
    r.notes,
    r.created_at,
    (CURRENT_DATE - (r.created_at)::date) AS age_days,
    ( SELECT count(*) AS count
           FROM ops.visit_request_services s
          WHERE (s.request_id = r.id)) AS service_count,
    ( SELECT string_agg(sli.title, ', '::text ORDER BY s.seq_no) AS string_agg
           FROM (ops.visit_request_services s
             JOIN service_line_items sli ON ((sli.id = s.service_line_item_id)))
          WHERE (s.request_id = r.id)) AS service_summary,
    ( SELECT COALESCE(bool_or(sli.requires_derm), false) AS "coalesce"
           FROM (ops.visit_request_services s
             JOIN service_line_items sli ON ((sli.id = s.service_line_item_id)))
          WHERE (s.request_id = r.id)) AS requires_derm,
    r.vehicle_id,
    veh.name AS truck_name,
    ( SELECT COALESCE(array_agg(t.employee_id ORDER BY t.seq_no, t.employee_id), '{}'::bigint[]) AS "coalesce"
           FROM ops.visit_request_team t
          WHERE (t.request_id = r.id)) AS team_ids,
    ( SELECT string_agg(e.full_name, ', '::text ORDER BY t.seq_no, t.employee_id) AS string_agg
           FROM (ops.visit_request_team t
             JOIN employees e ON ((e.id = t.employee_id)))
          WHERE (t.request_id = r.id)) AS team_names,
        CASE
            WHEN (j.title ~~* 'Service Agreement%'::text) THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    r.unscheduled_from_visit_id,
    ( SELECT uv.visit_date
           FROM visits uv
          WHERE (uv.id = r.unscheduled_from_visit_id)) AS unscheduled_from_date,
    r.call_required
   FROM (((ops.visit_requests r
     JOIN clients c ON ((c.id = r.client_id)))
     JOIN jobs j ON ((j.id = r.job_id)))
     LEFT JOIN vehicles veh ON ((veh.id = r.vehicle_id)))
  WHERE ((r.deleted_at IS NULL) AND (r.status = 'open'::text));

DO $v$
DECLARE v_visits int; v_links int; v_r jsonb; v_req bigint; n int; v_next date; v_msg text;
BEGIN
  -- 1. the Calendar's list is unchanged except the new column (false everywhere)
  IF EXISTS ((SELECT j FROM vr_before) EXCEPT ALL (SELECT to_jsonb(v) - 'call_required' FROM ops.v_visit_requests v))
     OR EXISTS (SELECT 1 FROM ops.v_visit_requests WHERE call_required) THEN
    RAISE EXCEPTION 'VERIFY 1: the request list changed';
  END IF;
  -- 2..6 rehearsed and undone
  <<life>>
  BEGIN
    SELECT count(*) INTO v_visits FROM public.visits;
    SELECT count(*) INTO v_links FROM public.entity_source_links;
    -- 2. a dry run says 226-JER would be filed, and leaves nothing behind
    v_r := ops.fn_call_first_run(true);
    IF jsonb_array_length(v_r->'filer'->'filed') <> 1 OR v_r->'filer'->'filed'->0->>'client' <> '226-JER'
       OR jsonb_array_length(v_r->'items') <> 1 OR (v_r->'items'->0->>'new')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'VERIFY 2a: dry run %', v_r;
    END IF;
    IF EXISTS (SELECT 1 FROM ops.visit_requests WHERE call_required) THEN RAISE EXCEPTION 'VERIFY 2b: the dry run left a request'; END IF;
    -- 3. the real run files ONE dateless request and nothing schedulable
    v_r := ops.fn_call_first_run(false);
    SELECT id INTO v_req FROM ops.visit_requests WHERE call_required AND status = 'open' AND deleted_at IS NULL;
    IF v_req IS NULL OR jsonb_array_length(v_r->'items') <> 1 THEN RAISE EXCEPTION 'VERIFY 3a: %', v_r; END IF;
    IF (SELECT count(*) FROM public.visits) <> v_visits OR (SELECT count(*) FROM public.entity_source_links) <> v_links THEN
      RAISE EXCEPTION 'VERIFY 3b: the reminder created a visit or a Jobber link';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ops.v_visit_requests WHERE id = v_req AND call_required AND title = 'Call for approval'
                    AND notes LIKE 'Call the client for approval before scheduling. Call due %permit GDO-03256 allows 60%') THEN
      RAISE EXCEPTION 'VERIFY 3c: the Calendar does not see it as a call request';
    END IF;
    -- 4. idempotent, and announced only once (not a Monday: items empty; a Monday: listed again, not new)
    v_r := ops.fn_call_first_run(false);
    IF jsonb_array_length(v_r->'filer'->'filed') <> 0 THEN RAISE EXCEPTION 'VERIFY 4a: filed twice'; END IF;
    IF NOT (v_r->>'weekly')::boolean AND jsonb_array_length(v_r->'items') <> 0 THEN RAISE EXCEPTION 'VERIFY 4b: announced twice'; END IF;
    -- 5. Not now: leaves the queue, the date moves, it does not come back before (date - 3 days)
    PERFORM ops.snooze_call_request(v_req, (now() AT TIME ZONE 'America/New_York')::date + 21);
    SELECT next_call_at INTO v_next FROM ops.client_call_policy WHERE client_id = 463;
    IF v_next <> (now() AT TIME ZONE 'America/New_York')::date + 21
       OR EXISTS (SELECT 1 FROM ops.v_visit_requests WHERE id = v_req) THEN RAISE EXCEPTION 'VERIFY 5a: snooze'; END IF;
    IF jsonb_array_length(ops.fn_file_due_call_requests()->'filed') <> 0 THEN RAISE EXCEPTION 'VERIFY 5b: re-filed before the date'; END IF;
    BEGIN PERFORM ops.snooze_call_request(v_req, (now() AT TIME ZONE 'America/New_York')::date);
          RAISE EXCEPTION 'VERIFY 5c: a past date was accepted';
    EXCEPTION WHEN SQLSTATE '22023' OR SQLSTATE 'P0002' THEN NULL; END;
    -- 6. paused files nothing; a booking made after the request closes it
    UPDATE ops.client_call_policy SET next_call_at = (now() AT TIME ZONE 'America/New_York')::date, paused = true WHERE client_id = 463;
    IF jsonb_array_length(ops.fn_file_due_call_requests()->'filed') <> 0 THEN RAISE EXCEPTION 'VERIFY 6a: paused filed'; END IF;
    UPDATE ops.client_call_policy SET paused = false WHERE client_id = 463;
    v_r := ops.fn_file_due_call_requests();
    SELECT id INTO v_req FROM ops.visit_requests WHERE call_required AND status = 'open' AND deleted_at IS NULL;
    UPDATE ops.visit_requests SET created_at = '2026-08-01' WHERE id = v_req;   -- so visit 7797 is "booked after it"
    v_r := ops.fn_file_due_call_requests();
    IF jsonb_array_length(v_r->'closed') <> 1 OR EXISTS (SELECT 1 FROM ops.visit_requests WHERE id = v_req AND status = 'open') THEN
      RAISE EXCEPTION 'VERIFY 6b: a booking did not close the request: %', v_r;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'ok';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END life;
  IF EXISTS (SELECT 1 FROM ops.visit_requests WHERE call_required)
     OR (SELECT next_call_at FROM ops.client_call_policy WHERE client_id = 463) IS DISTINCT FROM DATE '2026-10-16' THEN
    RAISE EXCEPTION 'VERIFY 7: the rehearsal was not undone';
  END IF;
  -- 8. privileges and the schedule
  IF has_table_privilege('anon', 'ops.client_call_policy', 'SELECT') OR has_table_privilege('authenticated', 'ops.client_call_policy', 'INSERT')
     OR has_table_privilege('authenticated', 'ops.client_call_policy', 'UPDATE') OR NOT has_table_privilege('authenticated', 'ops.v_client_call_policy', 'SELECT')
     OR has_function_privilege('authenticated', 'ops.fn_file_due_call_requests()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_call_first_run(boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'ops.snooze_call_request(bigint,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.snooze_call_request(bigint,date)', 'EXECUTE')
     OR NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'call-first-reminder' AND active)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'ops.client_call_policy'::regclass AND tgname = 'audit_client_call_policy') THEN
    RAISE EXCEPTION 'VERIFY 8: privileges, audit or schedule';
  END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
