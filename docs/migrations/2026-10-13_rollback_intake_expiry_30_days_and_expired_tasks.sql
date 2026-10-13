-- ============================================================================
-- ROLLBACK of 2026-10-13_1250_intake_expiry_30_days_and_expired_tasks
-- ============================================================================
-- Puts the 60-day default and the 1235 view back. Links made while the default was 30 days keep their 30-day date,
-- and tasks already deleted for an expired form stay deleted (old rows in audit.logs, app_source intake-task-sync).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

ALTER TABLE public.property_intakes ALTER COLUMN expires_at SET DEFAULT (now() + interval '60 days');

CREATE OR REPLACE VIEW public.v_intake_task_actions AS
SELECT pi.id AS intake_id,
       CASE WHEN pi.cancelled_at IS NOT NULL THEN 'delete' ELSE 'complete' END AS action,
       t.id AS task_id,
       l.source_id AS jobber_gid,
       COALESCE(pi.cancelled_at, pi.submitted_at) AS since,
       c.attempts, c.last_error, c.last_attempt_at
  FROM public.property_intakes pi
  JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
  LEFT JOIN public.entity_source_links l
         ON l.entity_type = 'calendar_task' AND l.source_system = 'jobber' AND l.entity_id = t.id
  LEFT JOIN public.intake_task_closures c ON c.intake_id = pi.id
 WHERE NOT t.is_complete
   AND (pi.cancelled_at IS NOT NULL OR pi.submitted_at IS NOT NULL)
   AND c.done_at IS NULL;

NOTIFY pgrst, 'reload schema';
COMMIT;
