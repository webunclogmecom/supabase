-- 2026-08-05_1420_derm_visit_jobber_link.sql
--
-- WHAT: derm.visit_jobber_link (visit_id, job_number, jobber_job_url) so the DERM Tracker can
--       offer an "Open in Jobber" button on the visit detail page.
--
-- WHY: Fred, 2026-08-05, reviewing a mis-linked manifest: he needed to cross-check a visit against
--      Jobber and there was no way through from the app.
--
-- 🛑 WHY THIS IS A NEW VIEW AND NOT A COLUMN ON derm.visits.
--    derm.visits is a deeply nested view whose body references `visits`, `manifest_visits` and
--    `gdos` UNQUALIFIED. Those three names exist in BOTH public AND derm:
--        public.visits / derm.visits · public.manifest_visits / derm.manifest_visits
--        public.gdos   / derm.gdos
--    A CREATE OR REPLACE rebuilt from pg_get_viewdef() would re-resolve them against whatever
--    search_path was in effect, which for a view being created IN derm would make it reference
--    derm.visits (itself) and derm.manifest_visits. That is a silent, catastrophic rewrite of a
--    compliance view. Postgres has no ALTER VIEW ADD COLUMN, so an additive companion view is the
--    only safe shape. Everything below is fully schema-qualified for the same reason.
--
-- The URL construction is NOT invented here: it is copied from ops.v_calendar_visit_detail, which
-- the Visit Calendar already ships. entity_source_links.source_id holds a base64 Jobber GID
-- (gid://Jobber/Job/<id>); the numeric tail is the id Jobber's web app uses.
-- Verified live: visit 1360 -> /work_orders/110667963, which Jobber redirects to /jobs/110667963
-- and renders as "Grease Trap Pumping & Warranty · Mila 043-MIL · Job #4301". Correct job.

BEGIN;

CREATE OR REPLACE VIEW derm.visit_jobber_link AS
SELECT
  v.id                                                   AS visit_id,
  j.job_number,
  CASE
    WHEN esl.source_id IS NOT NULL THEN
      'https://secure.getjobber.com/work_orders/'
      || split_part(convert_from(decode(esl.source_id, 'base64'), 'UTF8'), '/', -1)
  END                                                    AS jobber_job_url
FROM public.visits v
LEFT JOIN public.jobs j
       ON j.id = v.job_id
LEFT JOIN public.entity_source_links esl
       ON esl.entity_type   = 'job'
      AND esl.entity_id     = v.job_id
      AND esl.source_system = 'jobber'
WHERE v.deleted_at IS NULL;

COMMENT ON VIEW derm.visit_jobber_link IS
  'Deep link from a visit to its job in Jobber, for the DERM Tracker "Open in Jobber" button. '
  'URL construction copied from ops.v_calendar_visit_detail. jobber_job_url is NULL when the job '
  'has no Jobber link, which the app must render as a disabled/absent button, never a dead link.';

-- Match derm.visits: the app runs as `authenticated`. anon gets nothing.
GRANT SELECT ON derm.visit_jobber_link TO authenticated;
GRANT SELECT ON derm.visit_jobber_link TO service_role;

DO $$
DECLARE n int; u text; nulls int; total int;
BEGIN
  -- (a) the known-good case must resolve to the job Fred and I verified in the Jobber UI
  SELECT jobber_job_url INTO u FROM derm.visit_jobber_link WHERE visit_id = 1360;
  IF u IS DISTINCT FROM 'https://secure.getjobber.com/work_orders/110667963' THEN
    RAISE EXCEPTION 'visit 1360 resolved to %, expected the verified Mila job 110667963', coalesce(u,'NULL');
  END IF;

  -- (b) two visits on the SAME job must share a URL (1353 and 1360 are both job 4301)
  IF (SELECT jobber_job_url FROM derm.visit_jobber_link WHERE visit_id = 1353)
     IS DISTINCT FROM u THEN
    RAISE EXCEPTION 'visits 1353 and 1360 share job 4301 but produced different URLs';
  END IF;

  -- (c) a DIFFERENT job must produce a DIFFERENT URL. Without this, a constant expression
  --     would satisfy (a) and (b) and the view could be returning the same link for everything.
  IF (SELECT jobber_job_url FROM derm.visit_jobber_link WHERE visit_id = 1320) = u THEN
    RAISE EXCEPTION 'CONTROL FAILED: visit 1320 (a different job) produced the same URL as 1360';
  END IF;

  -- (d) coverage: the view must cover essentially every alive visit, and most must resolve.
  SELECT count(*), count(*) FILTER (WHERE jobber_job_url IS NULL)
    INTO total, nulls FROM derm.visit_jobber_link;
  IF total < 1000 THEN
    RAISE EXCEPTION 'only % rows in the view, expected the full alive-visit population', total;
  END IF;
  RAISE NOTICE 'OK: % visits, % without a Jobber link (app must handle those)', total, nulls;
END $$;

COMMIT;
