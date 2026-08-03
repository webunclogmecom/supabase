-- ============================================================================
-- ops.client_service_options — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.client_service_options AS
SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    j.id AS job_id,
    j.job_number,
        CASE
            WHEN j.title ~~* 'Service Agreement%'::text THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    j.title AS job_title,
    j.frequency_days,
    j.property_id,
    COALESCE(svc.services, '[]'::json) AS services,
    svc.primary_group AS job_service_group
   FROM jobs j
     JOIN clients c ON c.id = j.client_id
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_kind', sli.service_type, 'service_group', ops.fn_service_group(sli.reason, sli.service_type, sli.location_target), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code))[1] AS primary_group
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.job_id = j.id AND sli.schedulable = true) svc ON true
  WHERE j.job_status <> 'archived'::text AND (j.title IS NULL OR j.title !~~* '%[OLD]%'::text);
