-- 2026-08-03d — Stop the New Visit picker listing a service twice
--
-- WHY (Fred, 2026-08-03): "check the duplicate of the line items, it's happening to a lot of
-- clients." The AGREEMENT card listed the same service twice for 15 clients.
--
-- ⚠ ROOT CAUSE IS OURS, NOT JOBBER DATA ENTRY, AND THIS MIGRATION ONLY TREATS THE SYMPTOM.
-- public.create_calendar_visit writes one visit-scoped line_items row per picked service (usually
-- $0). The INSERT trigger pushes ["schedule","title","notes","crew","lineitems"], and
-- jobber-push-visit -> syncVisitLineItems calls visitCreateLineItems, which MINTS BRAND-NEW shared
-- JobLineItem objects on the job and unlinks the inherited priced templates. Jobber has no
-- VisitLineItem type, so job.lineItems is the union of templates plus every per-visit override, and
-- an override renders quantity 0 at JOB scope while reading quantity 1 on its owning visit. When
-- that visit is later deleted / skipped / cancelled, visitDelete STRANDS its lines as permanent
-- qty-0 orphans. sync-jobber-job-drift (cron `15,45 * * * *`) then mirrors the whole collection into
-- public.line_items, and this view aggregated job-scope lines with NO quantity predicate.
--
-- Reproduced live on 137/137 eligible SA jobs in
-- docs/audits/2026-07-18_qty0_line_item_residue_audit.md, and it fired again during today's session:
-- visit 7648 created 18:21:53Z from calendar.unclogme.app -> Jobber objects 221733691/221733692
-- created 18:21:55Z -> visit soft-deleted 18:23:32Z -> drift run 18:45:00Z -> DB rows 18:46:06Z.
--
-- 🛑 DO NOT "FIX" THIS BY DELETING ROWS FROM public.line_items. sync-jobber-job-drift multiset-diffs
-- against Jobber and does delete-then-insert, so any DB-side dedup is re-inserted within 30 minutes
-- and sync_log.line_syncs would show permanent non-convergence. The rows are Jobber objects; only
-- jobDeleteLineItems removes them, and that is Fred-gated.
--
-- 🛑 AND DO NOT BULK-DELETE EVERY qty-0 LINE IN JOBBER EITHER. Measured: of the 22 qty-0 job-scope
-- lines on these 15 jobs, only some are stranded orphans; 17 are LIVE per-visit override lines still
-- linked to a real (often completed) visit. Deleting those would destroy real visit pricing. An
-- orphan is a qty-0 line referencing ZERO visits.
--
-- AUDIT: opt-out. View definition change, no table touched.
--
-- THE CHANGE: exclude visit-scoped rows and qty-0 overrides from the job's service list. A qty-0
-- job-scope line is an override belonging to a visit, never a service you can dispatch, so it has no
-- business in the picker.
--
-- SAFETY, MEASURED BEFORE APPLYING (a filter that silently empties a picker is worse than the bug):
--   jobs offering >= 1 schedulable service BEFORE : 175
--   jobs offering >= 1 schedulable service AFTER  : 175
--   jobs that regressed to an empty list          : 0
-- AFTER APPLYING:
--   duplicate picker entries across ALL jobs: 0  (was 19 groups over 15 jobs)
--   job 1629 (222-SPE) services 4 -> 2, correctly leaving codes 01 and 04

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
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_kind', sli.service_kind, 'service_group', ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) ORDER BY sli.code))[1] AS primary_group
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.job_id = j.id AND li.visit_id IS NULL AND li.quantity > 0 AND sli.schedulable = true) svc ON true
  WHERE j.job_status <> 'archived'::text AND (j.title IS NULL OR j.title !~~* '%[OLD]%'::text);

-- APPLIED to Prod 2026-08-03.
--
-- STILL OPEN, needs Fred:
--   (a) STOP THE BLEEDING at the source. Either create_calendar_visit should not write a $0
--       visit-scoped line per picked service, or jobber-push-visit should not call
--       visitCreateLineItems when the override adds nothing over the inherited template. Until one
--       of those lands, every created-then-deleted Calendar visit mints two more Jobber orphans.
--   (b) CLEAN THE RESIDUE via jobDeleteLineItems, orphans only (qty 0 AND referencing zero visits).
