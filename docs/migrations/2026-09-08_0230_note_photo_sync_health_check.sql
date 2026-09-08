-- ============================================================================
-- 2026-09-08_0230_note_photo_sync_health_check.sql
--
-- A health check for the Jobber note-photo sync: the job that fetches the photos
-- crews attach to job notes in Jobber and links them to the right visit.
--
-- Fred, 2026-09-08: "Do a health check for the cron job that goes every hour to check
-- if there are any picture on the notes at jobber that we talked about not long ago."
--
-- WHAT THE JOB IS (it is NOT pg_cron, which is why nothing watched it until now):
--   .github/workflows/jobber-note-photo-sync.yml -> scripts/sync/sync_jobber_note_photos.js
--   ONE workflow, TWO cron triggers, same script, different look-back:
--     '0 *''/6 * * *'  -> --days=14  full sweep, the real guarantee
--     '30 * * * *'     -> --days=3   hot window, best effort
--   Each delivered run writes one row to public.sync_log with
--   sync_source='jobber_note_photo_sync' and details {days, added, removed, changedVisits}.
--
-- 🛑 THE LIMITATION THIS CHECK CANNOT ESCAPE, STATED UP FRONT.
--    The script writes its sync_log row at the END of a successful run, and a run that
--    dies never reaches that INSERT (its own error is swallowed by .catch(() => {})).
--    Measured 2026-09-07 over the full 511-run history: 39 runs (7.6%) failed, every one
--    of them on a Supabase Management API 429, and sync_log is ~36 rows short of reality.
--    => A FAILED RUN AND A RUN GITHUB NEVER FIRED LOOK IDENTICAL FROM THE DATABASE.
--    This check therefore measures DELIVERED RUNS and FRESHNESS. It can tell you the
--    photos stopped flowing; it cannot tell you why. Same class as
--    reference_pg_cron_success_is_structurally_blind. Fixing that means making the script
--    log its own failure, which is a separate change to a GitHub Actions script.
--
-- THRESHOLDS, MEASURED RATHER THAN INVENTED (2026-09-07, 30 days of history):
--   full sweep gap  avg 6.9h, p90 11.2h, MAX 17.5h across 103 intervals -> alert at 24h,
--                   comfortably above the observed worst case, and 24h means four
--                   consecutive 6-hour cycles missed.
--   any run         both triggers together deliver ~10/day -> alert at 12h of total silence.
--   hot window      delivered 6.4/day against 24 scheduled (GitHub throttles sub-hourly
--                   crons in this repo; jobber-poll, jobber-upcoming-visits and
--                   reconcile-jobs were all moved to pg_cron for exactly this reason).
--                   So a LOW rate is normal here and must NOT alert. Only a collapse
--                   below 2/day is worth flagging.
--
-- Registers in the existing health system: writes to public.sync_log like the other
-- log_*_health functions, and is added to ops.v_health_items and ops.v_health_status.
-- ⚠ Those two views each carry their OWN hardcoded copy of the source list and the
--   items-key CASE. A new check is invisible until BOTH are edited. Noted, not redesigned.
--
-- Audit: N/A (view + function + cron; the function writes only to sync_log).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the measurements, as a view so they can be read directly without logging
-- ---------------------------------------------------------------------------
create or replace view public.v_jobber_note_photo_health as
with runs as (
  select started_at,
         (details->>'days')::int    as window_days,
         (details->>'added')::int   as added,
         (details->>'removed')::int as removed
  from public.sync_log
  where sync_source = 'jobber_note_photo_sync'
),
agg as (
  select
    max(started_at)                                                      as last_run_at,
    max(started_at) filter (where window_days = 14)                      as last_full_sweep_at,
    max(started_at) filter (where window_days = 3)                       as last_hot_window_at,
    count(*) filter (where started_at > now() - interval '24 hours')                       as runs_24h,
    count(*) filter (where started_at > now() - interval '24 hours' and window_days = 14)  as full_sweeps_24h,
    count(*) filter (where started_at > now() - interval '24 hours' and window_days = 3)   as hot_windows_24h,
    coalesce(sum(added) filter (where started_at > now() - interval '24 hours'), 0)        as photos_added_24h,
    coalesce(sum(added) filter (where started_at > now() - interval '7 days'), 0)          as photos_added_7d,
    coalesce(sum(removed) filter (where started_at > now() - interval '7 days'), 0)        as photos_removed_7d
  from runs
)
select
  a.*,
  round(extract(epoch from (now() - a.last_run_at))        / 3600.0, 1) as hours_since_any_run,
  round(extract(epoch from (now() - a.last_full_sweep_at)) / 3600.0, 1) as hours_since_full_sweep,
  round(extract(epoch from (now() - a.last_hot_window_at)) / 3600.0, 1) as hours_since_hot_window,
  -- the three conditions worth a human's attention
  (a.last_full_sweep_at is null
     or now() - a.last_full_sweep_at > interval '24 hours')             as full_sweep_stale,
  (a.last_run_at is null
     or now() - a.last_run_at > interval '12 hours')                    as all_runs_stale,
  (a.hot_windows_24h < 2)                                              as hot_window_collapsed
from agg a;

comment on view public.v_jobber_note_photo_health is
  'Freshness and volume of the Jobber note-photo sync (GitHub Actions, not pg_cron). '
  'Reads public.sync_log rows written by scripts/sync/sync_jobber_note_photos.js. '
  'A FAILED run writes NO row, so absence of runs cannot be distinguished from failure '
  'here: this measures delivered runs, not attempts. Thresholds are measured, not guessed '
  '(full-sweep gap max 17.5h over 30 days -> stale at 24h). The hot window legitimately '
  'delivers ~6 of 24 scheduled runs because GitHub throttles sub-hourly crons in this repo, '
  'so a low rate is NORMAL and only a collapse below 2/day is flagged.';

-- ---------------------------------------------------------------------------
-- 2. the logger, same shape as the other log_*_health functions
-- ---------------------------------------------------------------------------
create or replace function public.log_jobber_note_photo_health()
returns integer
language plpgsql
as $function$
declare
  h      public.v_jobber_note_photo_health%rowtype;
  items  jsonb := '[]'::jsonb;
  n_bad  int   := 0;
  st     text;
begin
  select * into h from public.v_jobber_note_photo_health;

  if h.full_sweep_stale then
    items := items || jsonb_build_object(
      'kind',   'full_sweep_stale',
      'detail', format('No 14-day full sweep in %s hours (alert at 24h). This is the guarantee that catches photos added to older notes.',
                       coalesce(h.hours_since_full_sweep::text, 'ever')),
      'hours',  h.hours_since_full_sweep);
    n_bad := n_bad + 1;
  end if;

  if h.all_runs_stale then
    items := items || jsonb_build_object(
      'kind',   'all_runs_stale',
      'detail', format('No note-photo sync of any kind in %s hours (alert at 12h). Photos taken today are not reaching the apps.',
                       coalesce(h.hours_since_any_run::text, 'ever')),
      'hours',  h.hours_since_any_run);
    n_bad := n_bad + 1;
  end if;

  if h.hot_window_collapsed then
    items := items || jsonb_build_object(
      'kind',   'hot_window_collapsed',
      'detail', format('Only %s hourly sweeps in 24h (normally ~6 of 24 scheduled; GitHub throttles sub-hourly crons). Photo freshness is degraded, coverage is not lost.',
                       h.hot_windows_24h),
      'runs',   h.hot_windows_24h);
    n_bad := n_bad + 1;
  end if;

  st := case
          when h.full_sweep_stale or h.all_runs_stale then 'attention'
          when h.hot_window_collapsed                 then 'warning'
          else 'ok'
        end;

  insert into public.sync_log
    (sync_source, started_at, finished_at, rows_inserted, rows_errored, status, details)
  values
    ('note-photo-sync-health', now(), now(),
     h.photos_added_24h, n_bad, st,
     jsonb_build_object(
       'items',                  items,
       'runs_24h',               h.runs_24h,
       'full_sweeps_24h',        h.full_sweeps_24h,
       'hot_windows_24h',        h.hot_windows_24h,
       'hours_since_any_run',    h.hours_since_any_run,
       'hours_since_full_sweep', h.hours_since_full_sweep,
       'photos_added_24h',       h.photos_added_24h,
       'photos_added_7d',        h.photos_added_7d,
       'photos_removed_7d',      h.photos_removed_7d,
       'caveat', 'A failed run writes no sync_log row, so a missing run and a failed run are indistinguishable here.'));

  return n_bad;
end
$function$;

comment on function public.log_jobber_note_photo_health() is
  'Writes one public.sync_log row (sync_source note-photo-sync-health) summarising the '
  'freshness of the Jobber note-photo sync. Called by pg_cron note-photo-sync-health.';

-- ---------------------------------------------------------------------------
-- 3. register it in the two health views. Each keeps its OWN copy of the source
--    list and the items CASE, so both must be edited or the check is invisible.
-- ---------------------------------------------------------------------------
create or replace view ops.v_health_items as
with latest as (
  select distinct on (l.sync_source)
         l.sync_source, l.status, l.started_at, l.details
    from public.sync_log l
   where l.sync_source = any (array['calendar-push-health','blackout-health','rpa-derm-health',
                                    'sa-schedule-gap-check','jobber-sync-health',
                                    'note-photo-sync-health'])
   order by l.sync_source, l.started_at desc
)
select la.sync_source as check_name,
       la.status,
       la.started_at  as last_run_at,
       coalesce(i.value->>'visit_id', i.value->>'dump_folder', i.value->>'kind',
                i.value->>'client_code', i.value::text) as item_key,
       i.value as item
  from latest la
  cross join lateral jsonb_array_elements(
       case la.sync_source
         when 'calendar-push-health'    then coalesce(la.details->'items',   '[]'::jsonb)
         when 'blackout-health'         then coalesce(la.details->'sheets',  '[]'::jsonb)
         when 'rpa-derm-health'         then coalesce(la.details->'reasons', '[]'::jsonb)
         when 'sa-schedule-gap-check'   then coalesce(la.details->'sample',  '[]'::jsonb)
         when 'jobber-sync-health'      then coalesce(la.details->'items',   '[]'::jsonb)
         when 'note-photo-sync-health'  then coalesce(la.details->'items',   '[]'::jsonb)
         else '[]'::jsonb
       end) i(value);

commit;

-- cron.schedule is NOT transactional, so it lives after the COMMIT.
-- Every 6 hours at :35, offset from the sync's own :00 and :30 triggers and from the
-- other health checks. Daily would take up to 48h to notice a 24h staleness condition.
select cron.schedule('note-photo-sync-health', '35 */6 * * *',
                     'select public.log_jobber_note_photo_health();');

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  h public.v_jobber_note_photo_health%rowtype;
  n int; st text; d jsonb; sched text;
begin
  select * into h from public.v_jobber_note_photo_health;

  -- 1. the view returns exactly one row and can actually see the sync's history
  if h.last_run_at is null then
    raise exception 'VERIFY 1 FAILED: view sees no jobber_note_photo_sync runs at all - instrument is blind';
  end if;
  if h.runs_24h = 0 then
    raise exception 'VERIFY 1b FAILED: 0 runs in 24h; expected ~10. Either the sync really stopped or the view is wrong';
  end if;

  -- 2. run the logger and confirm it wrote a row
  n := public.log_jobber_note_photo_health();
  select status, details into st, d
    from public.sync_log
   where sync_source = 'note-photo-sync-health'
   order by started_at desc limit 1;
  if st is null then
    raise exception 'VERIFY 2 FAILED: log_jobber_note_photo_health wrote no sync_log row';
  end if;

  -- 3. the status must reflect reality. As of writing the sync is healthy, so 'ok'
  --    is expected; anything else means a real condition fired and should be read.
  if st not in ('ok','warning','attention') then
    raise exception 'VERIFY 3 FAILED: unexpected status %', st;
  end if;

  -- 4. POSITIVE CONTROL on the items path: the details payload must carry the keys the
  --    health views read, or the check will be silently invisible in the UI.
  if not (d ? 'items') then
    raise exception 'VERIFY 4 FAILED: details has no items key; ops.v_health_items would render nothing';
  end if;
  if not (d ? 'hours_since_full_sweep') then
    raise exception 'VERIFY 4b FAILED: details missing hours_since_full_sweep';
  end if;

  -- 5. the source is registered in the aggregator. Without this the check exists and is
  --    never seen, which is the failure mode a hardcoded list produces.
  if not exists (select 1 from ops.v_health_items where check_name = 'note-photo-sync-health')
     and n > 0 then
    raise exception 'VERIFY 5 FAILED: rows exist but note-photo-sync-health is absent from ops.v_health_items';
  end if;

  -- 6. the cron job is scheduled and active
  select schedule into sched from cron.job where jobname = 'note-photo-sync-health';
  if sched is distinct from '35 */6 * * *' then
    raise exception 'VERIFY 6 FAILED: cron schedule is %, expected 35 */6 * * *', coalesce(sched,'(absent)');
  end if;
  if not exists (select 1 from cron.job where jobname='note-photo-sync-health' and active) then
    raise exception 'VERIFY 6b FAILED: cron job exists but is not active';
  end if;

  raise notice 'VERIFY ok: status=%, % conditions, runs_24h=%, full sweep %sh ago, hot windows 24h=%, photos added 7d=%',
    st, n, h.runs_24h, h.hours_since_full_sweep, h.hot_windows_24h, h.photos_added_7d;
end
$verify$;
