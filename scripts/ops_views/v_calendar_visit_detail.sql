-- ============================================================================
-- ops.v_calendar_visit_detail — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_calendar_visit_detail AS
SELECT v.id AS visit_id,
    v.job_id,
    v.client_id,
    v.title,
    v.visit_date,
    v.visit_status,
    v.derm_required,
        CASE
            WHEN j.title ~~* 'Service Agreement%'::text THEN 'service_agreement'::text
            WHEN j.title ~~* 'Service Call%'::text THEN 'service_call'::text
            ELSE NULL::text
        END AS service_kind,
    j.frequency_days AS agreement_frequency_days,
        CASE
            WHEN esl.source_id IS NOT NULL THEN 'https://secure.getjobber.com/work_orders/'::text || split_part(convert_from(decode(esl.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
            ELSE NULL::text
        END AS jobber_job_url,
    COALESCE(jli.items, '[]'::json) AS line_items,
    j.job_number AS jobber_job_number
   FROM visits v
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN entity_source_links esl ON esl.entity_type = 'job'::text AND esl.source_system = 'jobber'::text AND esl.entity_id = v.job_id
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity) ORDER BY li.name) AS items
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.invoice_id IS NULL) jli ON true
  WHERE v.deleted_at IS NULL;
