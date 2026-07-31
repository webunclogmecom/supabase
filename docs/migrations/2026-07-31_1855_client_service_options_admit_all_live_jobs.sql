-- 2026-07-31_1855  ops.client_service_options: stop dropping live jobs on their TITLE TEXT
--
-- Fred: "I can't see the client A La Carte Bay Harbour - 293-ALC on the calendar app, why?"
--
-- -- ROOT CAUSE ---------------------------------------------------------------
-- The Calendar's "New Visit" CLIENT PICKER is built exclusively from
-- ops.client_service_options (bundle: `.from("client_service_options")
-- .select("client_id, client_code, client_name")`, on the ops-schema client). That view
-- carried a hard-coded job-TITLE whitelist:
--     AND (j.title ILIKE 'Service Agreement%' OR lower(btrim(j.title)) = 'service call')
-- 293-ALC's only job (id 1771, Jobber #99901015) is titled plain 'Service', which matches
-- neither branch, so the client had ZERO rows in the view and could not be selected or
-- searched for when scheduling. Its VISITS were never missing: all 4 are in
-- ops.v_calendar_visit and render on the grid, and the header search finds the client.
-- This is a picker-only failure.
--
-- -- WHY THE TITLE TEST IS THE CULPRIT AND NOT THE OTHER ANOMALIES ------------
-- The client has several unusual attributes; only one of them singles it out. Measured:
--     jobs failing on TITLE alone ....  4     <-- and only 1 has a future visit: 293-ALC
--     clients with zone IS NULL ......  57
--     clients with property_id NULL ... 208
--     visits with source='jobber' ..... 224 clients
-- A cause shared by 57-224 clients cannot explain ONE missing client. (I initially
-- suspected zone IS NULL, 4-of-144 among actively-scheduled clients; an adversarial
-- re-measure refuted it. Correlation, not mechanism.)
--
-- -- THIRD OCCURRENCE OF THE SAME DEFECT --------------------------------------
--   2026-07-02  245-MAYU  title 'Service call' (lowercase) -> patched with lower(btrim())
--   2026-07-17  000-DH    title NULL                       -> docs/audits/2026-07-17_calendar_picker_missing_dump_client.md
--   2026-07-31  293-ALC   title 'Service'
-- The 07-17 audit named this exact hardening and recorded it as deferred. Each prior fix
-- widened the whitelist by one more spelling; the whitelist itself is the bug. Job titles
-- are JOBBER-MASTERED free text, so any new spelling silently removes a client from the
-- picker with no error -- the app's only empty state is "No client found.", which reads as
-- "this client does not exist".
--
-- -- THE CHANGE ---------------------------------------------------------------
-- Drop the title whitelist. `archived` and `[OLD]` remain the only exclusions, and they are
-- the meaningful ones. job_kind still keys off the title (Service Agreement% -> SA, else
-- SC), so classification is unchanged for every row that already qualified.
--
-- `j.title IS NULL OR` is LOAD-BEARING: `NULL !~~* '%[OLD]%'` evaluates to NULL, not true,
-- which would silently re-create the 000-DH bug. (0 non-archived jobs have a NULL title
-- today, so it costs nothing now and prevents a regression later.)
--
-- PROBED rolled back before applying:
--     rows      439 -> 443        clients   266 -> 269
--     293-ALC   0   -> 1 row (job 1771, job_kind 'SC')
--     control 106-ALC unchanged at 2
--     newly admitted: 275-MLP (2nd job), 296-KAT, 297-MAR
--     grants intact: authenticated, service_role, yannick_readonly, postgres
-- Additive only: no client or job that qualified before loses a row.
--
-- NOT added by this change (correctly): 174 clients absent for real reasons -- 24 have no
-- jobs at all, 147 have only archived jobs.
--
-- ADR 010 rule 8: view only. No table or column change, so no audit-trigger opt-in decision.
-- CREATE OR REPLACE preserves grants; column list/order/types are byte-identical to the
-- previous definition (verified against pg_get_viewdef before writing this).
--
-- ⚠ SEPARATE, OPS-SIDE: job 1771's title 'Service' is still non-standard. jobs is
-- Jobber-mastered (app_source='jobber', it re-synced during this very investigation --
-- job_status flipped action_required -> upcoming at 22:45 UTC), so a DB-only rename would
-- be reverted by the next sync. Renaming it to 'Service Call' in JOBBER is the tidy-up;
-- this migration means the picker no longer DEPENDS on that rename happening.

BEGIN;

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
          WHERE li.job_id = j.id AND sli.schedulable = true) svc ON true
  WHERE j.job_status <> 'archived'::text
    AND (j.title IS NULL OR j.title !~~* '%[OLD]%'::text);

COMMIT;
