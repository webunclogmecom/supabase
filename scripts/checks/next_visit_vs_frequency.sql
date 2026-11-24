-- Next visit vs last completed visit + frequency, per recurring job (Trello #246 QeR7grA9, 2026-11-24).
-- Run as postgres (Management API): node scripts/q.js scripts/checks/next_visit_vs_frequency.sql <out.json>
-- Fred (Slack #new-app-issues, 11-24): "let me run again this check to make sure all the visits are correct".
-- For every job with a frequency (our disposal sites 000-* left out): its last completed visit, the first scheduled
-- visit after it, and off_by = (next - last) - frequency. A row is listed when |off_by| > 3 days.
-- A listed row is NOT automatically wrong: on 2026-11-24 all 12 were people's choices (a move in the Calendar, a
-- skip with its reason, or New Visit's SA re-anchor). Read the visit's audit.logs history before changing anything,
-- and change dates only in the Calendar (it pushes to Jobber), never with SQL.
-- The anchor is the SAME JOB only, like the Calendar's "Supposed to be" (#190). A client with several Service
-- Agreement jobs (the client of #246 has three) has one chain per job: compare a visit with its own job, never the client's.
-- Last row is a positive control: jobs_swept must be > 0, or the check saw nothing.
WITH j AS (
  SELECT j.id, j.client_id, j.frequency_days AS f
    FROM public.jobs j JOIN public.clients c ON c.id = j.client_id
   WHERE j.frequency_days > 0 AND c.client_code NOT LIKE '000-%'),
lc AS (
  SELECT DISTINCT ON (v.job_id) v.job_id, v.id, v.visit_date
    FROM public.visits v JOIN j ON j.id = v.job_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'
   ORDER BY v.job_id, v.visit_date DESC),
nx AS (
  SELECT DISTINCT ON (v.job_id) v.job_id, v.id, v.visit_date
    FROM public.visits v JOIN lc ON lc.job_id = v.job_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'scheduled' AND v.visit_date > lc.visit_date
   ORDER BY v.job_id, v.visit_date),
r AS (
  SELECT c.client_code, j.id AS job_id, j.f AS frequency_days, lc.id AS last_visit_id, lc.visit_date AS last_completed,
         nx.id AS next_visit_id, nx.visit_date AS next_visit, lc.visit_date + j.f AS expected,
         (nx.visit_date - lc.visit_date) - j.f AS off_by
    FROM j JOIN public.clients c ON c.id = j.client_id JOIN lc ON lc.job_id = j.id JOIN nx ON nx.job_id = j.id)
SELECT client_code, job_id, frequency_days, last_visit_id, last_completed, next_visit_id, next_visit, expected, off_by
  FROM r WHERE abs(off_by) > 3
UNION ALL
SELECT 'jobs_swept', count(*), NULL, NULL, NULL, NULL, NULL, NULL, count(*) FILTER (WHERE abs(off_by) <= 3) FROM r
ORDER BY off_by;
