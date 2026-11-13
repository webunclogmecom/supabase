-- Standing check for the Calendar "Supposed to be" date (ops.v_calendar_visit.expected_date), Trello #190 3O7jidnM,
-- migration 2026-11-13_1115_calendar_expected_date_same_job.sql (applied 11:19 ET).
-- Run as postgres (Management API). Healthy = ONE row: problem = 'ok'. Any other row names what broke.
-- The rule, recomputed here on its own:
--   anchor = the previous completed-or-scheduled, not deleted visit of the SAME JOB and the same service type;
--            only when the job has none (its first visit, or no job), the client's previous such visit of that service.
--   expected_date = anchor + the job's frequency (else the client's agreement frequency for that service);
--            NULL for our disposal sites (000-*), with no anchor, or with no declared frequency.
--   late_status must agree with expected_date wherever both exist (the drawer tooltip and the red Late chip).
-- Fred, 2026-11-13: "the last visit of that Job ... was done on Oct, and it has a frequency of 30 days, meaning the
-- next visit should be on Nov not Dec." A Service Call of the same service on another job must not move it.
-- Control: run with ops.v_calendar_visit swapped for the pre-#190 body and it reports the 034-LG visit 6010 (and 67
-- others), so the check can see the old defect.
WITH recount AS (
  SELECT v.id, v.visit_date, c.client_code,
         COALESCE(
           (SELECT max(p.visit_date) FROM public.visits p
             WHERE p.job_id = v.job_id AND p.service_type = v.service_type
               AND p.visit_status IN ('completed', 'scheduled') AND p.deleted_at IS NULL AND p.visit_date < v.visit_date),
           (SELECT max(p.visit_date) FROM public.visits p
             WHERE p.client_id = v.client_id AND p.service_type = v.service_type
               AND p.visit_status IN ('completed', 'scheduled') AND p.deleted_at IS NULL AND p.visit_date < v.visit_date)
         ) AS anchor,
         COALESCE(NULLIF(j.frequency_days, 0), a.frequency_days) AS freq
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    LEFT JOIN public.jobs j ON j.id = v.job_id
    LEFT JOIN public.v_client_agreement_services a ON a.client_id = v.client_id AND a.service_type = v.service_type
   WHERE v.deleted_at IS NULL),
want AS (
  SELECT id, visit_date,
         CASE WHEN client_code LIKE '000-%' OR anchor IS NULL OR freq IS NULL THEN NULL ELSE anchor + freq END AS expected
    FROM recount),
cv AS (SELECT c.id, c.visit_date, c.expected_date, c.late_status, w.expected
         FROM ops.v_calendar_visit c LEFT JOIN want w ON w.id = c.id),
fails AS (
  SELECT 'expected_date differs from the recount' AS problem,
         id::text || ' ' || coalesce(expected_date::text, 'null') || ' want ' || coalesce(expected::text, 'null') AS detail
    FROM cv WHERE expected_date IS DISTINCT FROM expected
  UNION ALL
  SELECT 'late_status and expected_date disagree', id::text || ' ' || late_status || ' ' || expected_date::text
    FROM cv WHERE expected_date IS NOT NULL AND late_status IS NOT NULL
     AND late_status <> CASE WHEN expected_date < CURRENT_DATE THEN 'late'
                             WHEN expected_date < visit_date THEN 'will_be_late' ELSE 'on_time' END
  UNION ALL
  -- positive control: the check must see rows at all
  SELECT 'no expected_date anywhere (the check sees nothing)', NULL
   WHERE NOT EXISTS (SELECT 1 FROM cv WHERE expected_date IS NOT NULL)
)
SELECT problem, count(*) AS n, (array_agg(detail ORDER BY detail))[1:10] AS sample FROM fails GROUP BY problem
UNION ALL
SELECT 'ok', (SELECT count(*) FROM cv WHERE expected_date IS NOT NULL), NULL WHERE NOT EXISTS (SELECT 1 FROM fails);
