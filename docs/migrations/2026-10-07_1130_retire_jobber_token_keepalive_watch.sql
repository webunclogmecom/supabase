-- 2026-10-07 11:30 ET · Retire the GitHub jobber-token-keepalive: stop watching it in log_jobber_sync_health
--
-- Timed-jobs move, step 0.2 (system-audit-2026-10-05/TIMED_JOBS_PLAN.md section 2.5; Fred, 2026-10-07:
-- "yes to all defaults"). Shipped as ONE change with:
--   * edge fn sync-jobber-poll: the read token is refreshed 10 minutes before expiry (was 60 seconds), so the
--     5-minute poll is the only keeper of the read token;
--   * .github/workflows/jobber-token-keepalive.yml and scripts/sync/jobber_token_keepalive.js deleted.
-- Why: the keepalive ran about every 5 hours on GitHub instead of every 30 minutes, and its off-schedule refreshes
-- set expiry minutes the poll did not own: 28 of the 32 Jobber 401 failures in the 30 days to 2026-10-05 and the
-- recurring "sync_failed:jobber_job_drift" health item. The write token (jobber_write) needs no keeper: every
-- function that uses it refreshes it itself 2 minutes before expiry, and calendar-task-poll does so every 5 minutes.
--
-- This migration only removes ('jobber_token_keepalive', null::interval) from the watched list, so the health
-- check stops reporting a source that no longer runs. Spliced from the live body, md5-pinned; nothing else moves.
-- Rule 8: no table change. Proof it worked (check after a week): 0 jobber_job_drift rows with "HTTP 401".

begin;

do $mig$
declare
  v_def  text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  v_old  text := E',\n      (''jobber_token_keepalive'',        null::interval)\n  ),';
  v_new  text := E'\n  ),';
  v_cmt_old text := E'-- ⚠ These two run irregularly by design (max observed gap 731 and 724 minutes), so a staleness\n      --    window would be a guess.';
  v_cmt_new text := E'-- ⚠ This one runs irregularly by design (max observed gap 731 minutes), so a staleness\n      --    window would be a guess.';
begin
  if md5(v_def) <> 'ab82c2b4424b9673f57d48c8291760c4' then
    raise exception 'log_jobber_sync_health changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'keepalive entry not found exactly once';
  end if;
  if (length(v_def) - length(replace(v_def, v_cmt_old, ''))) / length(v_cmt_old) <> 1 then
    raise exception 'comment not found exactly once';
  end if;
  execute replace(replace(v_def, v_old, v_new), v_cmt_old, v_cmt_new);
end
$mig$;

-- VERIFY
do $v$
declare v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
begin
  if position('jobber_token_keepalive' in v_def) > 0 then raise exception 'keepalive still watched'; end if;
  if position('''jobber_note_photo_sync'',        null::interval)' in v_def) = 0 then raise exception 'note photo entry lost'; end if;
  if position('''calendar-task-poll''' in v_def) = 0 then raise exception 'calendar-task-poll entry lost'; end if;
  -- the grants are kept by CREATE OR REPLACE; the function must still run
  perform public.log_jobber_sync_health();
end
$v$;

commit;
