-- 2026-10-08 10:48 ET · Samsara GPS cut-over: log_jobber_sync_health watches the Railway job
--
-- Timed-jobs move, step 3 (TIMED_JOBS_PLAN.md 4, T1). Record: docs/audits/2026-10-07_timed_jobs_move.md.
-- The Railway service samsara-gps (UnclogMe Timed Jobs) has run every 5 minutes since 2026-10-07 12:15 ET
-- beside GitHub's samsara-locations-history.yml: 271 of 271 runs successful, never more than 6 minutes
-- apart, and GPS rows per truck per ET day within each truck's normal range. In the same change the GitHub
-- schedule is removed (its manual button stays until 2026-10-22 as the rollback).
--
-- This adds ('railway_samsara_gps', 30 minutes) to the watched list, so a stopped or failing Railway job
-- reaches the daily health email. 30 minutes = 6 missed 5-minute runs. The runner (scripts/sync/run_logged.js)
-- writes 'success' / 'error', both already understood by the check. Spliced from the live body, md5-pinned.
-- Rule 8: no table change.

begin;

do $mig$
declare
  v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  v_old text := E'      (''jobber_note_photo_sync'',        null::interval)\n  ),';
  v_new text := E'      (''jobber_note_photo_sync'',        null::interval),\n'
             || E'      -- Railway cron service (UnclogMe Timed Jobs), every 5 minutes; 30 minutes = 6 missed runs.\n'
             || E'      (''railway_samsara_gps'',           interval ''30 minutes'')\n  ),';
begin
  if md5(v_def) <> '107a5df0b6309cf771da72337724b907' then
    raise exception 'log_jobber_sync_health changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor not found exactly once';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;

-- VERIFY
do $v$
declare v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
begin
  if position('''railway_samsara_gps''' in v_def) = 0 then raise exception 'railway_samsara_gps not watched'; end if;
  if position('''jobber_note_photo_sync''' in v_def) = 0 then raise exception 'note photo entry lost'; end if;
  perform public.log_jobber_sync_health();
end
$v$;

commit;
