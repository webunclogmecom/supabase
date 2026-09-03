-- 2026-09-03_1800_stagger_cron_schedules.sql
--
-- ============================================================================
-- 🛑 CORRECTION, 2026-09-03 15:20 ET. THE ROOT CAUSE STATED BELOW IS WRONG.
-- KEEP THE CHANGE. DO NOT KEEP THE REASONING.
-- ============================================================================
-- Everything below blames background-worker starvation and minute :00. Both are false, and the
-- measurements that refute them are one query each:
--
--   cron.use_background_workers = off   (context postmaster, source DEFAULT - never set)
--     => pg_cron runs every job as a libpq CLIENT CONNECTION against cron.host = localhost.
--        Jobs consume max_connections. They do NOT draw on max_worker_processes at all; the only
--        pool slot pg_cron holds is its single launcher. The entire premise below is void.
--
--   failures at minute :00 ....... 0        job starts at minute :00 .... 12,042
--     => the minute this migration blames has a PERFECT record over 119,693 runs. The 38 failures
--        fall at minutes 9,10,15,27,33,35,36,37,50,51,55,56.
--
--   failure durations ............ 10.02 s to 19.79 s
--     => that is a connection-establishment deadline expiring. An exhausted slot pool refuses
--        INSTANTLY. The duration alone rules out the diagnosis below.
--
-- WHAT IS ACTUALLY TIGHT: connections and memory. cron.max_running_jobs = 32 against
-- max_connections = 60 (3 superuser-reserved) with PostgREST holding ~21 idle is a real and
-- dangerous pair - worst case measured at 59 against 60 - but it is a CONNECTION ceiling, not a
-- worker one.
--
-- ✅ THE STAGGER IS STILL CORRECT AND SHOULD STAY, for a reason this file did not state: spreading
-- the jobs reduces CONCURRENT CONNECTIONS, which is the resource that is genuinely scarce. It was
-- right for the wrong reason. Peak 14 -> 5 per minute still holds and is still worth having.
--
-- Credit: the adversarial workflow that refused the premise, and the Supabase 2 session which had
-- already corrected a separate overstatement in the same audit.
-- ============================================================================
--
-- Re-phase the 11 periodic cron jobs so they stop starving the background-worker pool.
-- EVERY JOB KEEPS ITS FREQUENCY. Only the offset changes.
--
-- ============================================================================
-- THE ROOT CAUSE, AND WHY THIS IS THE FIX
-- ============================================================================
-- Fred: "the data to display takes too long... from time to time", for a week or two.
--
--     max_worker_processes  = 6      <- background-worker pool for the WHOLE cluster
--     cron.max_running_jobs = 32     <- pg_cron is allowed to launch 32 at once
--
-- pg_cron runs each job as a background worker out of that pool of 6, which it shares with pg_net's
-- worker, max_parallel_workers (2) and max_logical_replication_workers (4). Measured before this
-- migration: **14 jobs fire at minute :00**, 11 at :30, 9 at :20 and :15, and **9 minutes of every
-- hour sit at or above the 6-worker pool.**
--
-- ✅ THE PROOF THAT THIS IS STARVATION AND NOT SLOWNESS: all 36 cron failures in 7 days carry the
-- message `job startup timeout` - Postgres could not even LAUNCH the worker - and every one of them
-- falls inside the observed stall windows (2026-09-03 12:50-12:56, 2026-08-31 10:15-10:37). Inside
-- those windows up to 8 unrelated jobs go from a 0.03-0.37s average to 10-20s at the same instant.
-- Statements do not slow each other down like that; a starved scheduler does.
--
-- 🛑 THE CRONS ARE NOT THE LOAD, and it matters that nobody "fixes" them by deleting work. All 25
-- jobs together cost **2,006 seconds over 7 days = 0.33% of wall clock.** The problem is that they
-- are bunched, not that they are expensive. 12 minutes of every hour currently have ZERO jobs.
--
-- ⚠ WHAT THIS DOES NOT FIX. `derm.fn_blackout_targets` is separately ~32-37% of all DB execution
-- time and returns zero rows; that is owned by the Supabase 2 session and is deliberately NOT
-- touched here. And `max_worker_processes = 6` is a restart-requiring managed parameter - raising it
-- is Fred's call and is probably the right long-term answer *alongside* staggering. Staggering is
-- what can be done today, for free, with no restart and no downtime.
--
-- ⚠ RISK. Low, and stated honestly: every job keeps its exact frequency, so nothing runs less often.
-- A job's phase shifts by at most a few minutes, which matters only if something depends on a job
-- landing on an exact wall-clock minute. None of these do - they are all "every N minutes" sweeps.
-- Reversal is one cron.alter_job per row back to the old schedule, listed beside each change.

begin;

-- job                               was              becomes
select cron.alter_job((select jobid from cron.job where jobname='outbound-custom-field-push'),       schedule => '1-59/2 * * * *');   -- */2
select cron.alter_job((select jobid from cron.job where jobname='resolve-stale-visit-sync-pending'), schedule => '1-59/3 * * * *');   -- */3
select cron.alter_job((select jobid from cron.job where jobname='jobber-poll-sync'),                 schedule => '1-59/5 * * * *');   -- */5
select cron.alter_job((select jobid from cron.job where jobname='calendar-push-auto-retry'),         schedule => '2-59/5 * * * *');   -- */5
select cron.alter_job((select jobid from cron.job where jobname='redact-manifest-sweep'),            schedule => '3-59/5 * * * *');   -- */5
select cron.alter_job((select jobid from cron.job where jobname='dump-driver-truck-refresh'),        schedule => '4-59/5 * * * *');   -- */5
select cron.alter_job((select jobid from cron.job where jobname='calendar-task-poll'),               schedule => '1-59/5 * * * *');   -- 2-57/5
select cron.alter_job((select jobid from cron.job where jobname='sheet-number-ocr-sweep'),           schedule => '2-59/10 * * * *');  -- */10
select cron.alter_job((select jobid from cron.job where jobname='sheet-row-ocr-sweep'),              schedule => '4-59/10 * * * *');  -- 5-55/10
select cron.alter_job((select jobid from cron.job where jobname='jobber-upcoming-visits-sync'),      schedule => '3-59/15 * * * *');  -- */15
select cron.alter_job((select jobid from cron.job where jobname='jobber-visit-drift-reconcile'),     schedule => '8-59/30 * * * *');  -- */30

-- ---------------------------------------------------------------------------
-- VERIFY. The concurrency is recomputed HERE, in SQL, from what is actually stored - not carried
-- over from the planning script. A plan that agrees with itself proves nothing.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_peak     integer;
  v_over     integer;
  v_inactive integer;
  v_freq     integer;
begin
  -- expand every active job's minute-of-hour set, for the forms actually in use:
  --   '*/N'  -> 0,N,2N...      'A-59/N' -> A,A+N...      'A-B/N' -> A..B step N
  --   'A' or 'A,B' -> those literal minutes      '*' -> every minute
  create temp table _sched on commit drop as
  with j as (select jobname, split_part(schedule,' ',1) as m from cron.job where active),
  expanded as (
    select j.jobname, g.minute
      from j, lateral generate_series(0,59) g(minute)
     where case
             when j.m = '*' then true
             when j.m ~ '^\*/[0-9]+$'
               then g.minute % (substring(j.m from 3))::int = 0
             when j.m ~ '^[0-9]+-[0-9]+/[0-9]+$'
               then g.minute >= split_part(j.m,'-',1)::int
                and g.minute <= split_part(split_part(j.m,'-',2),'/',1)::int
                and (g.minute - split_part(j.m,'-',1)::int) % split_part(j.m,'/',2)::int = 0
             else g.minute::text = any(string_to_array(j.m, ','))
           end
  )
  select minute, count(*)::int as jobs from expanded group by minute;

  select coalesce(max(jobs),0) into v_peak from _sched;
  select count(*)             into v_over from _sched where jobs >= 6;

  -- 🛑 THE ASSERTION THAT MATTERS: no minute may reach the 6-worker pool any more.
  if v_over <> 0 then
    raise exception 'VERIFY FAILED: % minute(s) of the hour still fire >= 6 jobs (peak %). '
                    'The whole point of this migration is that no minute reaches the worker pool.',
                    v_over, v_peak;
  end if;
  if v_peak > 5 then
    raise exception 'VERIFY FAILED: peak concurrency is % jobs per minute, expected at most 5', v_peak;
  end if;

  -- every job we touched must still be ACTIVE. An alter_job typo that disabled a sweep would be
  -- far worse than the problem being fixed, and it would be silent.
  select count(*) into v_inactive from cron.job
   where jobname in ('outbound-custom-field-push','resolve-stale-visit-sync-pending','jobber-poll-sync',
                     'calendar-push-auto-retry','redact-manifest-sweep','dump-driver-truck-refresh',
                     'calendar-task-poll','sheet-number-ocr-sweep','sheet-row-ocr-sweep',
                     'jobber-upcoming-visits-sync','jobber-visit-drift-reconcile')
     and not active;
  if v_inactive <> 0 then
    raise exception 'VERIFY FAILED: % re-phased job(s) are no longer active', v_inactive;
  end if;

  -- FREQUENCY MUST BE UNCHANGED. This is the promise of the migration: same runs per hour, later
  -- start. Checked per job against its expected count rather than in aggregate, because an
  -- aggregate total can be right while two individual jobs are wrong in opposite directions.
  select count(*) into v_freq from (
    values ('outbound-custom-field-push',30),('resolve-stale-visit-sync-pending',20),
           ('jobber-poll-sync',12),('calendar-push-auto-retry',12),('redact-manifest-sweep',12),
           ('dump-driver-truck-refresh',12),('calendar-task-poll',12),
           ('sheet-number-ocr-sweep',6),('sheet-row-ocr-sweep',6),
           ('jobber-upcoming-visits-sync',4),('jobber-visit-drift-reconcile',2)
  ) e(jobname, expect)
  where e.expect <> (
    select count(*) from generate_series(0,59) g(minute)
     join cron.job cj on cj.jobname = e.jobname and cj.active
     where case
             when split_part(cj.schedule,' ',1) ~ '^\*/[0-9]+$'
               then g.minute % (substring(split_part(cj.schedule,' ',1) from 3))::int = 0
             when split_part(cj.schedule,' ',1) ~ '^[0-9]+-[0-9]+/[0-9]+$'
               then g.minute >= split_part(split_part(cj.schedule,' ',1),'-',1)::int
                and (g.minute - split_part(split_part(cj.schedule,' ',1),'-',1)::int)
                    % split_part(split_part(cj.schedule,' ',1),'/',2)::int = 0
             else false
           end
  );
  if v_freq <> 0 then
    raise exception 'VERIFY FAILED: % job(s) changed FREQUENCY, not just phase. '
                    'This migration must only shift offsets.', v_freq;
  end if;

  raise notice 'VERIFY OK: peak % jobs/minute (was 14), % minutes at/over the 6-worker pool (was 9), '
               'all 11 jobs active, all frequencies unchanged', v_peak, v_over;
end
$verify$;

commit;
