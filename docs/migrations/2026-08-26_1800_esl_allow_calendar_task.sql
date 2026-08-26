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
-- AUDIT (ADR 010): entity_source_links is a sync-linkage table and is NOT audited. This migration
--      does not change that, and deliberately does not opt it in: the table is machine-written by
--      the sync/push paths at high volume, and its rows are derivable from the remote systems they
--      point at. This is the DECISION rule 8 asks for, not an observation.
--      🛑 CONSEQUENCE, because it is a trap: there are ZERO triggers on this table (verified
--      2026-08-26 against pg_trigger, including internal ones, with positive controls -- zones
--      returned 2 and visits returned 14 on the same query -- and audit.logs has never held a
--      single row for it). Per Supabase/CLAUDE.md rule 6, a DELETE here therefore leaves NO record
--      of any kind and the only recovery is a file you wrote beforehand. Do not expect
--      audit.logs.old_row to save you.
--
-- LIVE LIST: the 15 values below are the 14 read from pg_get_constraintdef() immediately before
--      writing this file (2026-08-26), NOT copied from the spec, plus 'calendar_task'. The live 14
--      matched the spec's expected list exactly.
--      entity_source_links_entity_type_chk is the ONLY check constraint on this table.
--      'calendar_day_marker' is retained even though it currently has 0 rows: an allowed value is
--      part of a contract, and dropping one silently breaks whichever integration writes it next.
--
-- WHY NOT "NOT VALID": ADD CONSTRAINT without NOT VALID makes Postgres scan every existing row at
--      ALTER time, which on ~27,868 rows is sub-second and, for a pure widening, cannot fail. That
--      scan is free proof no existing row violates the new list -- a violation would abort this
--      migration loudly. NOT VALID would skip the scan and buy nothing but a silent unverified
--      constraint. (The 2026-08-06 precedent stated this; it is restated rather than dropped.)
--
-- VERIFICATION: scripts/probes/calendar_task_esl.mjs. It inserts inside begin/rollback so nothing
--      is written, and carries a POSITIVE CONTROL ('visit') that must pass -- a target rejection
--      is only meaningful if the control was accepted, since that is what shows the path, creds
--      and table were all working when the target was refused. (Each sql() call is its own HTTPS
--      request, so this is emphatically NOT one shared connection; the control establishes that
--      the route works, not that a session was held open.)
--      Before this migration: control pass, target 23514.  After: control pass, target allowed.
--
-- 🛑 DO NOT VERIFY THIS BY FREEZING THE ROW COUNT. It was 27868 immediately before and after the
--      ALTER, but this table is machine-written by the Jobber sync continuously: 11 rows landed in
--      the following 3 hours (5 invoice, 4 job, 1 note, 1 photo) and the count read 27870 shortly
--      after. That is healthy sync traffic, not leakage. A moving count here is EXPECTED, and
--      treating it as an invariant would manufacture a false alarm (workspace CLAUDE.md 5.2b: a
--      live object changes between your two reads).
--      The real assurances are: (1) the ALTER validated every existing row at apply time, so a
--      violation would have aborted it, and (2) the probe's inserts are inside begin/rollback --
--      confirmed by `source_id like 'PROBE%' or entity_id = -999 or entity_type = 'calendar_task'`
--      returning 0, which is the leak check that actually discriminates.

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
