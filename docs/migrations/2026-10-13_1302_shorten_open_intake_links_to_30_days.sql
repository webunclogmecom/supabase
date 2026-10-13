-- ============================================================================
-- 2026-10-13_1302 The five intake links already out now also last 30 days
-- ============================================================================
-- THE ASK: 2026-10-13_1250 made NEW links last 30 days and left the five open ones on their 60-day date. Asked whether
-- to shorten those too, Fred: "yes shorten them to 30 days".
--
-- WHAT CHANGES: expires_at = created_at + 30 days on the open (never submitted, never cancelled) intakes 1062 to 1066.
--   1062 to 1065 (sent to Grecia 2026-10-01): 2026-11-30 -> 2026-10-31
--   1066 (2026-10-12): 2026-12-11 -> 2026-11-11
--   Each is still in the future, so no link closes and no task is queued today. On those dates, if still unfilled, the
--   link shows "This link has expired" and intake-task-sync deletes its Jobber + Calendar task (2026-10-13_1250).
--   property_intakes is audited, so the old dates stay in audit.logs; re-extending is the same UPDATE with 60 days.
-- ============================================================================
BEGIN;

UPDATE public.property_intakes
   SET expires_at = created_at + interval '30 days'
 WHERE id IN (1062, 1063, 1064, 1065, 1066)
   AND submitted_at IS NULL AND cancelled_at IS NULL
   AND expires_at = created_at + interval '60 days';

DO $v$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.property_intakes
   WHERE id IN (1062, 1063, 1064, 1065, 1066) AND expires_at = created_at + interval '30 days' AND expires_at > now();
  IF n <> 5 THEN RAISE EXCEPTION 'V1 expected 5 links at 30 days and still valid, found %', n; END IF;
  SELECT count(*) INTO n FROM public.property_intakes
   WHERE submitted_at IS NULL AND cancelled_at IS NULL AND expires_at > created_at + interval '30 days';
  IF n <> 0 THEN RAISE EXCEPTION 'V2 % open link(s) still last more than 30 days', n; END IF;
  IF EXISTS (SELECT 1 FROM public.v_intake_task_actions) THEN RAISE EXCEPTION 'V3 something was queued'; END IF;
END $v$;

COMMIT;
