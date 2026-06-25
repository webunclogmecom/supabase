-- 2026-06-25_fix_visit_detail_lineitems.sql
-- Fix the Calendar drawer's "current line items" display + enable price pre-fill.
--
-- Bug: ops.v_calendar_visit_detail.line_items was built from line_items WHERE
-- li.job_id = v.job_id (JOB-scoped) and omitted unit_price. A Service-Call visit's
-- line items are stored VISIT-scoped (visit_id set, job_id null), so the view
-- returned [] for them — the drawer never saw the visit's own services, so it
-- couldn't pre-check them on open (data-loss risk: editing services dropped the
-- unseen existing ones) and couldn't pre-fill saved prices.
--
-- Fix: return the VISIT's own line items (visit_id = v.id) WITH unit_price, falling
-- back to the JOB's line items (for Service-Agreement visits whose priced items live
-- on the job). Additive unit_price key; all other columns unchanged.

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
    COALESCE(
        ( SELECT json_agg(json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity, 'unit_price', li.unit_price) ORDER BY li.name)
          FROM line_items li WHERE li.visit_id = v.id ),
        ( SELECT json_agg(json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity, 'unit_price', li.unit_price) ORDER BY li.name)
          FROM line_items li WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL ),
        '[]'::json
    ) AS line_items,
    j.job_number AS jobber_job_number
   FROM visits v
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN entity_source_links esl ON esl.entity_type = 'job'::text AND esl.source_system = 'jobber'::text AND esl.entity_id = v.job_id
  WHERE v.deleted_at IS NULL;

NOTIFY pgrst, 'reload schema';
