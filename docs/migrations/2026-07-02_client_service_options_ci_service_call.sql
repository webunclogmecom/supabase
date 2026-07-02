-- ============================================================================
-- 2026-07-02 — ops.client_service_options: match "Service Call" case-insensitively
-- ============================================================================
-- 245-MAYU (Diego's new client, coded via Viktor) was in the DB (client + property + SC job
-- #99900977 + a Jul-3 visit) but did NOT appear in the Calendar's New-Visit client/service
-- picker, so it couldn't be scheduled. Root cause: the view's SC filter was an EXACT,
-- case-sensitive match `j.title = 'Service Call'`, but MAYU's job is titled "Service call"
-- (lowercase c) -> excluded. Fix: match `lower(btrim(j.title)) = 'service call'` so any
-- casing/whitespace variant of the standard Service Call is picked up. (MAYU was the only
-- client uniquely blocked; the SA branch was already ILIKE, unaffected.)
-- Additive/forgiving; no columns changed. Idempotent (CREATE OR REPLACE preserves grants).
-- ============================================================================
CREATE OR REPLACE VIEW ops.client_service_options AS
 SELECT c.id AS client_id, c.client_code, c.name AS client_name, j.id AS job_id, j.job_number,
    CASE WHEN j.title ~~* 'Service Agreement%'::text THEN 'SA'::text ELSE 'SC'::text END AS job_kind,
    j.title AS job_title, j.frequency_days, j.property_id,
    COALESCE(svc.services, '[]'::json) AS services
   FROM public.jobs j
     JOIN public.clients c ON c.id = j.client_id
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'unit_price', li.unit_price) ORDER BY sli.code) AS services
           FROM public.line_items li JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.job_id = j.id AND sli.schedulable = true) svc ON true
  WHERE j.job_status <> 'archived'::text
    AND (j.title ~~* 'Service Agreement%'::text OR lower(btrim(j.title)) = 'service call')
    AND j.title !~~* '%[OLD]%'::text;
