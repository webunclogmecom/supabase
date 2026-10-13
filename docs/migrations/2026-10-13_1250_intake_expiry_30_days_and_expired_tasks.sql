-- ============================================================================
-- 2026-10-13_1250 Intake links last 30 days, and an expired form's task is deleted like a cancelled one
-- ============================================================================
-- THE ASK (Fred, 2026-10-13, after 2026-10-13_1235_intake_task_close shipped):
--   asked "Should an expired form be treated like a cancelled one?" -> "yes treat expired forms like cancelled"
--   then -> "And make it 30 days instead of 60"
--
-- WHAT CHANGES
--   1. public.property_intakes.expires_at DEFAULT now() + 60 days -> now() + 30 days. The default is the ONLY thing
--      that sets it (client.schedule_property_intake and the [TEST] fixture take it from the default; no RPC sets or
--      extends it), and no app prints "60 days" (the apps show the date). NEW links only: the 5 open links made
--      before this keep their date (1062 to 1065 expire 2026-11-30, 1066 2026-12-11) until Fred says otherwise.
--   2. public.v_intake_task_actions: a form that was never submitted and whose link has expired now reads 'delete',
--      exactly like a cancelled one. action = 'complete' when submitted, else 'delete'; since = the cancel, the
--      submit, or the expiry. Same columns, so CREATE OR REPLACE keeps the grants (asserted).
--      Measured at write time: 0 open forms are expired, so nothing moves at apply; the new arm is proven by
--      rolled-back probes below.
--
-- HOW TO RUN: one call, one transaction. Rehearse: node scripts/probes/apply_sql_file.mjs <file> rehearse
-- ROLLBACK: 2026-10-13_rollback_intake_expiry_30_days_and_expired_tasks.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(pg_get_viewdef('public.v_intake_task_actions'::regclass)) <> '73439e1ad00d7d7c56835a58f242ee51' THEN
    RAISE EXCEPTION 'v_intake_task_actions changed since 2026-10-13_1235: re-read it'; END IF;
END $g$;

CREATE TEMP TABLE _ita0 ON COMMIT DROP AS SELECT * FROM public.v_intake_task_actions;

-- 1 ---------------------------------------------------------------------------------------------------------
ALTER TABLE public.property_intakes ALTER COLUMN expires_at SET DEFAULT (now() + interval '30 days');

-- 2 ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_intake_task_actions AS
SELECT pi.id AS intake_id,
       CASE WHEN pi.submitted_at IS NOT NULL THEN 'complete' ELSE 'delete' END AS action,
       t.id AS task_id,
       l.source_id AS jobber_gid,
       COALESCE(pi.cancelled_at, pi.submitted_at, pi.expires_at) AS since,
       c.attempts, c.last_error, c.last_attempt_at
  FROM public.property_intakes pi
  JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
  LEFT JOIN public.entity_source_links l
         ON l.entity_type = 'calendar_task' AND l.source_system = 'jobber' AND l.entity_id = t.id
  LEFT JOIN public.intake_task_closures c ON c.intake_id = pi.id
 WHERE NOT t.is_complete
   AND (pi.cancelled_at IS NOT NULL OR pi.submitted_at IS NOT NULL OR pi.expires_at <= now())
   AND c.done_at IS NULL;
COMMENT ON VIEW public.v_intake_task_actions IS
  'Site survey forms whose Jobber task needs closing (2026-10-13_1235, expiry since _1250): submitted -> complete; '
  'cancelled, or never submitted and expired -> delete. Open tasks only, forms not already handled. Read by edge fn '
  'intake-task-sync.';

-- VERIFY ----------------------------------------------------------------------------------------------------
DO $v$
DECLARE n int; a text;
BEGIN
  IF pg_get_expr((SELECT adbin FROM pg_attrdef d JOIN pg_attribute t ON t.attrelid = d.adrelid AND t.attnum = d.adnum
                   WHERE d.adrelid = 'public.property_intakes'::regclass AND t.attname = 'expires_at'), 'public.property_intakes'::regclass)
     <> '(now() + ''30 days''::interval)' THEN RAISE EXCEPTION 'V1 default is not 30 days'; END IF;

  -- V2 nothing moved today (0 expired open forms): the view equals its snapshot both ways
  SELECT count(*) INTO n FROM (
    (SELECT intake_id, action, task_id FROM public.v_intake_task_actions EXCEPT SELECT intake_id, action, task_id FROM _ita0)
    UNION ALL
    (SELECT intake_id, action, task_id FROM _ita0 EXCEPT SELECT intake_id, action, task_id FROM public.v_intake_task_actions)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2 the view changed by % row(s) at apply', n; END IF;

  -- V3 an open form whose link expired is listed as 'delete' (rolled back)
  BEGIN
    UPDATE public.property_intakes SET expires_at = now() - interval '1 minute' WHERE id = 1062 AND submitted_at IS NULL AND cancelled_at IS NULL;
    SELECT action INTO a FROM public.v_intake_task_actions WHERE intake_id = 1062;
    IF a IS DISTINCT FROM 'delete' THEN RAISE EXCEPTION 'V3 expired open form 1062 reads %, expected delete', a; END IF;
    RAISE EXCEPTION 'v3_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v3_rollback' THEN RAISE; END IF;
  END;

  -- V4 a SUBMITTED form whose link has since expired still reads 'complete', never 'delete' (rolled back)
  BEGIN
    UPDATE public.property_intakes SET submitted_at = now(), answers = '{}'::jsonb, expires_at = now() - interval '1 minute' WHERE id = 1062 AND submitted_at IS NULL AND cancelled_at IS NULL;
    SELECT action INTO a FROM public.v_intake_task_actions WHERE intake_id = 1062;
    IF a IS DISTINCT FROM 'complete' THEN RAISE EXCEPTION 'V4 submitted+expired form reads %, expected complete', a; END IF;
    RAISE EXCEPTION 'v4_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v4_rollback' THEN RAISE; END IF;
  END;

  -- V5 control: 1062 unexpired and open is NOT listed (so V3 measured the expiry, not something else)
  IF EXISTS (SELECT 1 FROM public.v_intake_task_actions WHERE intake_id = 1062) THEN RAISE EXCEPTION 'V5 open form 1062 listed'; END IF;

  -- V6 grants survived the replace
  IF has_table_privilege('authenticated', 'public.v_intake_task_actions', 'SELECT')
     OR has_table_privilege('anon', 'public.v_intake_task_actions', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_intake_task_actions', 'SELECT') THEN
    RAISE EXCEPTION 'V6 v_intake_task_actions grants wrong'; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
