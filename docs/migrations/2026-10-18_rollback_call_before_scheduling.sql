-- ROLLBACK of 2026-10-18_0245_call_before_scheduling
-- Removes the reminder. The two visit_requests columns are dropped only after the view stops reading them; any
-- call request already filed is an ordinary To Be Scheduled item afterwards (cancel it in the Calendar if unwanted).
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT cron.unschedule('call-first-reminder');
DROP FUNCTION public.fn_request_call_first_reminder();
DROP FUNCTION ops.fn_call_first_run(boolean);
DROP FUNCTION ops.snooze_call_request(bigint, date);
DROP FUNCTION ops.fn_file_due_call_requests();
DROP VIEW ops.v_client_call_policy;
-- CREATE OR REPLACE cannot remove a column: drop and re-create (no view or function depends on it, checked
-- 2026-10-18) and give back its grants
DROP VIEW ops.v_visit_requests;
CREATE VIEW ops.v_visit_requests AS
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
          WHERE (uv.id = r.unscheduled_from_visit_id)) AS unscheduled_from_date
   FROM (((ops.visit_requests r
     JOIN clients c ON ((c.id = r.client_id)))
     JOIN jobs j ON ((j.id = r.job_id)))
     LEFT JOIN vehicles veh ON ((veh.id = r.vehicle_id)))
  WHERE ((r.deleted_at IS NULL) AND (r.status = 'open'::text));
GRANT SELECT ON ops.v_visit_requests TO authenticated, service_role, yannick_readonly, db_backup_reader;
ALTER TABLE ops.visit_requests DROP COLUMN call_required, DROP COLUMN announced_at;
DROP TABLE ops.client_call_policy;
DO $v$ BEGIN
  IF md5(pg_get_viewdef('ops.v_visit_requests'::regclass)) <> 'bb93a2ffc2836f062b34dd9426ab44e6' THEN
    RAISE EXCEPTION 'rollback VERIFY: the request view differs from before';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
