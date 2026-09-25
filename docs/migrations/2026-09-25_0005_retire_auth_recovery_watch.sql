-- =====================================================================================================
-- 2026-09-25_0005  Retire the auth recovery watcher
-- =====================================================================================================
-- Fred: "retire the auth recovery watcher."
--
-- 2026-08-31_1600 built it during the Supabase Auth (GoTrue) outage, to email Fred once when login came
-- back so the apps' temporary no-login "Default" mode could be reverted. Its own table comment says to
-- delete the table, the cron and the edge function "when the no-auth Default mode is reverted". That
-- happened on 2026-09-01: auth verified back at 10:58 ET, the emergency window closed at 10:11 ET (Supabase
-- a4c2a21). The watcher never fired: its cron was not armed then and does not exist now (no row in
-- cron.job), so public.auth_recovery_state has read 'down' since 2026-09-01 13:17 UTC, a stale answer.
--
-- Removed here: public.fn_request_auth_recovery_watch() (already service_role only since 2026-09-24_1045)
-- and public.auth_recovery_state (monitoring state, not business data; its one row is backed up to
-- backups/auth_recovery_state_final_2026-09-25.json with a restore hint). Measured before: no view, no
-- other function, no cron job and no health check reads either object. The edge fn auth-recovery-watch is
-- deleted with the CLI in the same change, and its source and config.toml entry leave the repo.
-- Kept on purpose: scripts/probes/auth_recovery_check.js, the manual check of the same signals, for the
-- next outage (run by hand, writes nothing).
-- Rule 8: the table was audit opt-out; no business history is lost.
-- ROLLBACK: re-apply 2026-08-31_1600 (then restore the row from the backup) and redeploy the edge fn from
-- git history (commit 9744603).
-- =====================================================================================================

begin;

do $$
begin
  if exists (select 1 from cron.job where command ~* 'auth_recovery|auth-recovery') then
    raise exception 'a cron job still calls the watcher: unschedule it first';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where p.prosrc ~* 'auth_recovery_state' and p.proname <> 'fn_request_auth_recovery_watch'
                and n.nspname not in ('pg_catalog', 'information_schema'))
     or exists (select 1 from pg_views where definition ~* 'auth_recovery') then
    raise exception 'something else reads the watcher''s objects';
  end if;
end $$;

drop function public.fn_request_auth_recovery_watch();
drop table public.auth_recovery_state;

do $verify$
begin
  if to_regclass('public.auth_recovery_state') is not null
     or exists (select 1 from pg_proc where proname = 'fn_request_auth_recovery_watch') then
    raise exception 'VERIFY: the watcher''s objects are still there';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where p.prosrc ~* 'auth_recovery' and n.nspname not in ('pg_catalog', 'information_schema')) then
    raise exception 'VERIFY: a function still mentions the watcher';
  end if;
end
$verify$;

commit;
