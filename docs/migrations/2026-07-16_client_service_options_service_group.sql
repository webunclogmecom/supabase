-- 2026-07-16_client_service_options_service_group.sql
-- Add service_kind + a derived service_group to ops.client_service_options so the Visit Calendar can
-- COLOUR its Service-Agreement chips instead of rendering every SA as an identical bare "SA".
--
-- WHY: the search/create surfaces show job_kind ('SA' | 'SC'), which is derived from the job title.
-- A client with two Service Agreements therefore shows two indistinguishable "SA" chips. Real case
-- (Fred, 2026-07-16) — 195-MYK "Myka Lincoln LLC":
--   job 1586 #99900853 "Service Agreement - Grease Trap Pumping & Tank Cleaning" -> line item 01
--   job 1585 #99900854 "Service Agreement - Auxiliary Line Cleaning"             -> line item 06
-- Both render "SA". Yannick colour-coded the service taxonomy in the "Service list Unclogme" sheet
-- (19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE) so the two are distinguishable at a glance.
--
-- THE GROUPS (read from Yannick's sheet, column B, by sampling the rendered cell fills — the text
-- export drops cell colours). Only the SA rows (01-07) carry a fill; the SC rows do not:
--   01, 02  Pumping · Grease Trap            -> dark red berry  #5B0F00
--   03, 04  Pumping · Grey Water/Lift Stn    -> grey            #B7B7B7
--   05, 06, 07  Cleaning                     -> cornflower blue #4A86E8
--   08      Warranty of Drainage             -> no fill (billing-only, generates no visits)
-- Pixel counts self-validated the mapping: 900/900/1350 px = 2/2/3 rows at 450px per row.
--
-- WHY NO COLOUR COLUMN IN THE DB: the hex is PRESENTATION and belongs to the app (schema-per-app
-- rule); the DB owns the TAXONOMY. The group is fully derivable from columns service_line_items
-- already has (reason + service_kind + service_type), so storing a colour would be both a
-- presentation leak into canonical data AND redundant with the taxonomy (3NF: no derived storage).
-- The view hands the app a stable GROUP KEY; the app maps group -> hex.
--
-- WHY service_kind IS REQUIRED (service_type alone is not enough): service_type is GT | CL | NULL.
-- Codes 03/04 (grey) and code 08 (no colour) are BOTH service_type NULL — only service_kind
-- ('Pumping' vs 'Warranty of Drainage') separates them.
--
-- SAFE / ADDITIVE: CREATE OR REPLACE VIEW may only append columns. All 10 existing columns keep
-- their exact names, types and ORDER; job_service_group is appended LAST. The services JSON gains
-- two keys (service_kind, service_group) — additive, existing keys untouched, so the live Calendar
-- keeps working unchanged until it opts in.
-- AUDIT (ADR 010): view-only change, no DML on business tables => no audit trigger applies.
-- REVERSIBLE: backups/2026-07-16_ops_client_service_options_before.sql

-- One definition of the group rule, so the view can't drift between its two call sites (the per-
-- service JSON key and the job-level primary group), and so any future consumer derives it the same
-- way. IMMUTABLE: pure function of its args.
CREATE OR REPLACE FUNCTION ops.fn_service_group(p_reason text, p_kind text, p_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    -- Service Agreements only — Yannick colour-coded the SA rows (01-07); SC rows carry no fill.
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Pumping'  AND p_type = 'GT' THEN 'PUMPING_GT'     -- 01, 02
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Pumping'                    THEN 'PUMPING_OTHER'  -- 03, 04 (Grey Water, Lift Station)
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Cleaning'                   THEN 'CLEANING'       -- 05, 06, 07
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Warranty of Drainage'       THEN 'WARRANTY_OF_DRAINAGE' -- 08, uncoloured
    ELSE NULL  -- every Service Call, and anything unmapped: the app renders its existing plain chip
  END
$$;

COMMENT ON FUNCTION ops.fn_service_group(text, text, text) IS
  'Service-Agreement colour/grouping key for the Visit Calendar chips, derived from the service_line_items taxonomy (reason + service_kind + service_type). Mirrors Yannick''s "Service list Unclogme" sheet. Returns NULL for Service Calls. The HEX lives in the app, not here — this returns a stable group key only.';

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
    -- The chip's colour key: the group of the job's PRIMARY (lowest-code) schedulable service.
    -- A job with 01 + 06 is coloured by 01 — deterministic, and matches how the office reads the
    -- lowest code as the headline service.
    svc.primary_group AS job_service_group
   FROM jobs j
     JOIN clients c ON c.id = j.client_id
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object(
                'service_line_item_id', sli.id,
                'code', sli.code,
                'title', sli.title,
                'requires_derm', sli.requires_derm,
                'service_type', sli.service_type,
                'service_kind', sli.service_kind,
                'service_group', ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type),
                'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (ARRAY_AGG(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type)
                       ORDER BY sli.code))[1] AS primary_group
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.job_id = j.id AND sli.schedulable = true) svc ON true
  WHERE j.job_status <> 'archived'::text AND (j.title ~~* 'Service Agreement%'::text OR lower(btrim(j.title)) = 'service call'::text) AND j.title !~~* '%[OLD]%'::text;
