-- 2026-10-07 11:38 ET · Daily cleanup moves from GitHub into pg_cron (replaces job 2)
--
-- Timed-jobs move, step 1 (system-audit-2026-10-05/TIMED_JOBS_PLAN.md 2.8; Fred, 2026-10-07: "yes to all
-- defaults", so webhook log retention = 30 days). Record: docs/audits/2026-10-07_timed_jobs_move.md.
--
-- Before: GitHub daily-cleanup.yml (scripts/sync/daily_cleanup.js) deleted webhook_events_log rows older than
-- 30 days and cleared needs_populate on raw.jobber_pull_* rows whose Jobber entity answered "not found" in
-- the last 7 days; GitHub ran it at random hours, not 09:00 UTC. pg_cron job 2 separately deleted rows older
-- than 90 days, so the effective retention was "30 days, whenever GitHub got round to it".
--
-- After: public.fn_daily_cleanup() does both, and a new pg_cron job daily-cleanup (same 03:00 UTC slot) calls it and job 2 is removed.
-- The six patterns are the script's, with the visit one widened to the handler's other wording
-- ("Visit N not found in Jobber", webhook-jobber/index.ts:768). A stuck flag makes every poll run "partial"
-- (2 visits right now, failing since 2026-10-07 01:41 UTC), so clearing it is what keeps the poll's
-- status meaningful. The weekly dedup findings also live in webhook_events_log, so 30 days is their life too.
-- Rule 8: no table change. Grants: postgres only (pg_cron runs as postgres).

begin;

create or replace function public.fn_daily_cleanup()
returns jsonb
language plpgsql
set search_path = public, raw
as $fn$
declare
  v_deleted int;
  v_out jsonb := '{}'::jsonb;
  v_n int;
  r record;
begin
  delete from public.webhook_events_log where created_at < now() - interval '30 days';
  get diagnostics v_deleted = row_count;
  v_out := jsonb_build_object('log_rows_deleted', v_deleted);

  for r in
    select * from (values
      ('visits',     'jobber_pull_visits',     array['Jobber GraphQL error%Visit not found%', 'Visit % not found in Jobber%',
                                                   'Visit insert failed: null value in column "visit_date"%',
                                                   'Visit update failed: null value in column "visit_date"%']),
      ('clients',    'jobber_pull_clients',    array['Client%not found in Jobber%']),
      ('properties', 'jobber_pull_properties', array['Property%not found in Jobber%']),
      ('jobs',       'jobber_pull_jobs',       array['Job%not found in Jobber%']),
      ('invoices',   'jobber_pull_invoices',   array['Invoice%not found in Jobber%']),
      ('quotes',     'jobber_pull_quotes',     array['Quote%not found in Jobber%'])
    ) t(name, tbl, patterns)
  loop
    execute format($q$
      update raw.%I set needs_populate = false
       where needs_populate
         and data->>'id' in (
           select distinct payload->'webHookEvent'->>'itemId'
             from public.webhook_events_log
            where source_system = 'jobber' and status = 'failed'
              and error_message like any ($1)
              and created_at > now() - interval '7 days')$q$, r.tbl)
    using r.patterns;
    get diagnostics v_n = row_count;
    v_out := v_out || jsonb_build_object(r.name || '_flags_cleared', v_n);
  end loop;

  return v_out;
end
$fn$;

revoke all on function public.fn_daily_cleanup() from public, anon, authenticated, service_role;

-- job 2 (webhook-events-log-retention, 90 days) is replaced by a job named for what it now does, same slot.
-- (cron.job cannot be renamed in place: postgres has no UPDATE on it here.)
select cron.unschedule(2);
select cron.schedule('daily-cleanup', '0 3 * * *', 'select public.fn_daily_cleanup()');

-- VERIFY
do $v$
begin
  if has_function_privilege('authenticated', 'public.fn_daily_cleanup()', 'execute')
     or has_function_privilege('anon', 'public.fn_daily_cleanup()', 'execute') then
    raise exception 'fn_daily_cleanup is callable by an app role';
  end if;
  if exists (select 1 from cron.job where jobid = 2) then raise exception 'job 2 still scheduled'; end if;
  if (select count(*) from cron.job where jobname = 'daily-cleanup' and schedule = '0 3 * * *'
        and command = 'select public.fn_daily_cleanup()' and active) <> 1 then
    raise exception 'daily-cleanup job missing';
  end if;
end
$v$;

commit;
