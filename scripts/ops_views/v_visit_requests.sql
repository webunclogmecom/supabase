-- ============================================================================
-- ops.v_visit_requests — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

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
    CURRENT_DATE - r.created_at::date AS age_days,
    ( SELECT count(*) AS count
           FROM ops.visit_request_services s
          WHERE s.request_id = r.id) AS service_count,
    ( SELECT string_agg(sli.title, ', '::text ORDER BY s.seq_no) AS string_agg
           FROM ops.visit_request_services s
             JOIN service_line_items sli ON sli.id = s.service_line_item_id
          WHERE s.request_id = r.id) AS service_summary,
    ( SELECT COALESCE(bool_or(sli.requires_derm), false) AS "coalesce"
           FROM ops.visit_request_services s
             JOIN service_line_items sli ON sli.id = s.service_line_item_id
          WHERE s.request_id = r.id) AS requires_derm,
    r.vehicle_id,
    veh.name AS truck_name,
    ( SELECT COALESCE(array_agg(t.employee_id ORDER BY t.seq_no, t.employee_id), '{}'::bigint[]) AS "coalesce"
           FROM ops.visit_request_team t
          WHERE t.request_id = r.id) AS team_ids,
    ( SELECT string_agg(e.full_name, ', '::text ORDER BY t.seq_no, t.employee_id) AS string_agg
           FROM ops.visit_request_team t
             JOIN employees e ON e.id = t.employee_id
          WHERE t.request_id = r.id) AS team_names
   FROM ops.visit_requests r
     JOIN clients c ON c.id = r.client_id
     JOIN jobs j ON j.id = r.job_id
     LEFT JOIN vehicles veh ON veh.id = r.vehicle_id
  WHERE r.deleted_at IS NULL AND r.status = 'open'::text;
