-- 2026-08-26_1800_esl_allow_calendar_task.sql
--
-- WHAT: allow entity_type = 'calendar_task' on public.entity_source_links.
--
-- WHY: Calendar Tasks (spec 2026-08-25) link an ops.calendar_tasks row to its Jobber Task GID.
--      The link row is THE ONLY THING deciding create-versus-edit on the push.
--
-- 🛑 THIS MUST LAND BEFORE THE FIRST PUSH. On 2026-08-06 the same omission for
--    'calendar_day_marker' produced a real Jobber Task, a rejected link insert (23514) that was
--    swallowed, and ok:true returned to the caller. The next push would have created a SECOND
--    Task on the crew's schedule.
--
-- AUDIT (ADR 010): no new table, no trigger work. entity_source_links keeps its existing triggers.
--
-- LIVE LIST: the 14 values below were read from pg_get_constraintdef() immediately before writing
--      this file (2026-08-26), NOT copied from the spec. They matched the spec's expected list
--      exactly. entity_source_links_entity_type_chk is the ONLY check constraint on this table.
--      'calendar_day_marker' is retained even though it currently has 0 rows: an allowed value is
--      part of a contract, and dropping one silently breaks whichever integration writes it next.
--
-- VERIFICATION: scripts/probes/calendar_task_esl.mjs. It inserts inside begin/rollback so nothing
--      is written, and carries a POSITIVE CONTROL ('visit') that must pass -- a target failure is
--      only meaningful if the control succeeded on the same connection.
--      Before this migration: control pass, target 23514.  After: control pass, target allowed.
--      Row count before and after must be identical (27868).

BEGIN;

ALTER TABLE public.entity_source_links
  DROP CONSTRAINT entity_source_links_entity_type_chk;

ALTER TABLE public.entity_source_links
  ADD CONSTRAINT entity_source_links_entity_type_chk
  CHECK (entity_type IN (
    'client',
    'derm_manifest',
    'employee',
    'inspection',
    'invoice',
    'job',
    'line_item',
    'note',
    'photo',
    'property',
    'quote',
    'vehicle',
    'visit',
    'calendar_day_marker',
    'calendar_task'
  ));

COMMIT;
