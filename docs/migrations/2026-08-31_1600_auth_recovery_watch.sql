-- 2026-08-31_1600_auth_recovery_watch.sql
--
-- Automated "Supabase Auth is back" watcher, so we know when to revert the temporary
-- no-auth "Default" mode (2026-08-31 GoTrue outage) to normal login without babysitting it.
--
-- Fred, 2026-08-31: "set up the automated email alert."
--
-- The smart part lives in the edge function `auth-recovery-watch` (it can fetch the
-- /auth/v1/* endpoints synchronously and reason about the result, which Postgres cannot
-- do cleanly). This migration provides:
--   1. public.auth_recovery_state  - a singleton row the edge fn reads/writes to email
--      exactly once on a down -> up transition.
--   2. public.fn_request_auth_recovery_watch() - the cron trigger, copying the exact
--      vault + net.http_post pattern of fn_request_health_escalation (2026-08-24_1840):
--      Postgres cannot reach Resend, so it posts to the edge fn with edge_invoke_service_key.
--   3. an hourly pg_cron job (scheduled after COMMIT).
--
-- RULE 8 (ADR 010): opt-OUT of audit triggers. auth_recovery_state has NO human-editable
-- fields - only the edge function writes it, once an hour, as pure monitoring state. An
-- audit trail of "the watcher checked and auth was still down" is noise, not a compliance
-- record. Documented here per the rule.
--
begin;

create table if not exists public.auth_recovery_state (
  id               integer primary key default 1 check (id = 1),  -- singleton
  status           text not null default 'unknown' check (status in ('unknown','down','recovered')),
  last_checked_at  timestamptz,
  recovered_at     timestamptz,
  alerted_at       timestamptz,
  detail           jsonb
);

comment on table public.auth_recovery_state is
  'Singleton state for the auth-recovery-watch edge function. status flips down->recovered '
  'and emails Fred ONCE on that transition; while down it stays down silently. Re-arms if auth '
  'flaps. Written only by the edge function (service_role). Delete this table + the cron + the '
  'edge function when the no-auth Default mode is reverted.';

-- seed the singleton as "down" (auth IS down right now), so the first real recovery is a
-- down->up transition and emails. If it is somehow already up, the first run records
-- recovered silently (no spurious email) per the edge fn logic.
insert into public.auth_recovery_state (id, status, last_checked_at)
values (1, 'down', now())
on conflict (id) do nothing;

revoke all on public.auth_recovery_state from public, anon, authenticated;
grant select, insert, update on public.auth_recovery_state to service_role;

create or replace function public.fn_request_auth_recovery_watch()
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping auth-recovery-watch';
    return;
  end if;
  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/auth-recovery-watch',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000);
end $fn$;

comment on function public.fn_request_auth_recovery_watch() is
  'Hourly trigger for the auth-recovery-watch edge function. Posts with edge_invoke_service_key '
  '(RESEND_API_KEY is an edge secret; Postgres cannot email). The edge fn emails ONLY on a '
  'down->up transition; silence is the normal outcome. Retire with the no-auth Default mode.';

revoke all on function public.fn_request_auth_recovery_watch() from public;
grant execute on function public.fn_request_auth_recovery_watch() to service_role;

commit;

-- cron.schedule is NOT transactional; run it after the COMMIT.
-- ⚠ Plain single-quoted command, NOT dollar-quoting (a shell/JS template mangles $$).
-- Hourly at minute 17 (offset from the other :00/:30 jobs so it does not pile onto a worker burst).
select cron.schedule('auth-recovery-watch', '17 * * * *', 'select public.fn_request_auth_recovery_watch();');

-- VERIFY (run after applying):
--   select jobname, schedule, active from cron.job where jobname='auth-recovery-watch';
--   select status, last_checked_at, recovered_at from public.auth_recovery_state where id=1;
