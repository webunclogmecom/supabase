-- =====================================================================================
-- 2026-09-09_1610  public.visit_last_office_schedule_edit  (new, inert)
--   "When did WE last decide this visit's schedule?" -- the OTHER half of last-writer-wins.
-- =====================================================================================
-- WHY A NEW FUNCTION RATHER THAN A FIX TO visit_last_schedule_edit -------------------
-- visit_last_schedule_edit is read by the LIVE drift reconciler on three of its four branches
-- (HEAL, ADOPT-never-edited, ADOPT-refinement). Correcting its writer filter in place would change
-- the reconciler's behaviour the moment it landed: a visit whose only non-'jobber' schedule write
-- was an adopt currently reads as "the office edited it" and would start reading as "we never
-- edited it", which routes it into the unguarded auto-adopt branch. That is a real behaviour change
-- and it must not ride in ahead of the decision rule it belongs to.
--
-- So this is a SECOND function, used only by the new rule while it runs in SHADOW MODE. At
-- promotion the old branches move over to it and visit_last_schedule_edit is retired in one step,
-- with the change visible in one migration instead of leaking in early.
--
-- WHAT IS DIFFERENT ------------------------------------------------------------------
-- visit_last_schedule_edit excludes exactly one value: app_source = 'jobber'. This one delegates to
-- public.fn_is_office_schedule_write (2026-09-09_1520), which also excludes:
--   * the manual "Sync from Jobber" button -- audits as app_source='sql' with a NULL origin,
--     because adopt-visit-from-jobber constructs its client with no x-app-source header despite its
--     own file header claiming app_source='jobber'. 9 writes over 8 visits in 30 days.
--   * jobber-daily-completion-reconcile (67 writes / 64 visits in 45 days)
--   * jobber-daily-anomaly-reconcile (8 / 6)
--   * drift-adopt-diego-2026-07-29 (2 / 2), a one-off adopt backfill
-- Measured over 45 days of real schedule writes: 398 rows are excluded by the new predicate and
-- 0 genuine visit-calendar office edits are misclassified.
--
-- ⚠ IT RETURNS THE ROW, NOT A VERDICT. The caller decides. In particular `changed_at` is the T in
--   the interval comparison  T <= lo -> ADOPT / T > hi -> PUSH / otherwise -> undecidable, and a
--   NULL row means "we have never decided this visit's schedule", which is a different statement
--   from "our edit is old" and must not be collapsed into one.
--
-- ⚠ NO TIME FLOOR, DELIBERATELY, AND IT IS A KNOWN SHARP EDGE. Like the function it mirrors, this
--   returns the most recent office edit however old it is: measured across the drift backlog, the
--   deciding edit averaged 9.7 hours old and reached 94.3 hours. That is CORRECT for a
--   last-writer-wins comparison (an old edit is still the last thing we decided) and it is exactly
--   why the Jobber-side clock had to be built: the old code compared our stale edit against a proxy
--   instead of against a Jobber timestamp.
--
-- AUDIT (rule 8): no table changed. One new function.
-- REVERSIBLE: yes, drop it. Nothing calls it until the shadow rule deploys.
-- =====================================================================================

begin;

create or replace function public.visit_last_office_schedule_edit(p_visit_id bigint)
returns table (
  old_date      text,
  new_date      text,
  old_start_at  text,
  new_start_at  text,
  changed_at    timestamptz,
  app_source    text,
  req_path      text
)
language sql
stable
security definer
set search_path to 'public', 'audit', 'pg_temp'
as $function$
  SELECT l.old_row->>'visit_date', l.new_row->>'visit_date',
         l.old_row->>'start_at',   l.new_row->>'start_at',
         l.changed_at, l.app_source, l.request_context->>'path'
  FROM audit.logs l
  WHERE l.table_name='visits' AND (l.record_pk->>'id')=p_visit_id::text AND l.operation='UPDATE'
    AND public.fn_is_office_schedule_write(l.app_source, l.request_context->>'path')
    AND ( (l.new_row->>'visit_date') IS DISTINCT FROM (l.old_row->>'visit_date')
       OR (l.new_row->>'start_at')   IS DISTINCT FROM (l.old_row->>'start_at')
       OR (l.new_row->>'end_at')     IS DISTINCT FROM (l.old_row->>'end_at') )
  ORDER BY l.changed_at DESC LIMIT 1;
$function$;

comment on function public.visit_last_office_schedule_edit(bigint) is
  'The most recent schedule write on this visit that expresses OUR intent (see fn_is_office_schedule_write). changed_at is the T in the last-writer-wins interval comparison. See migration 2026-09-09_1610.';

-- By name: public''s default ACLs for functions grant EXECUTE to anon/authenticated/service_role,
-- and REVOKE FROM PUBLIC leaves a named grant untouched (this bit 2026-09-09_1520 on its first run).
revoke all on function public.visit_last_office_schedule_edit(bigint) from public, anon, authenticated;
grant execute on function public.visit_last_office_schedule_edit(bigint) to service_role;

commit;
