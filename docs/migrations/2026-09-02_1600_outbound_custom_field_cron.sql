-- 2026-09-02_1600_outbound_custom_field_cron.sql
--
-- Half three of AUTOMATIC OUTBOUND: schedule the drain. Queue + trigger landed in _1400, the
-- PostgREST wrappers in _1500, and jobber-push-custom-field is deployed with verify_jwt=true.
--
-- Rollout order matters and this is deliberately last. Until this migration runs, an app edit
-- records its intent in sync.outbound_queue and nothing reaches Jobber; every intermediate state
-- so far has been safe to sit in indefinitely. This is the step that makes the loop live, and it
-- is one line to undo (`select cron.unschedule('outbound-custom-field-push')`).
--
-- 🛑 pg_cron REPORTING 'succeeded' PROVES NOTHING ABOUT THE PUSH. net.http_post only ENQUEUES a
-- request and returns an id; the cron job succeeds the moment the row is queued, whether or not
-- the edge function ran, authenticated, or reached Jobber. So the cron log is NOT the health
-- signal. sync.outbound_queue is: a row that stays 'pending' with a rising oldest_minutes is the
-- only thing that shows the drain has stopped, which is exactly why the queue records intent
-- durably instead of the trigger firing and forgetting.
--   select * from sync.v_outbound_queue_health;
-- 'pending' with oldest_minutes climbing past a few = the drain is not running.
-- 'failed'  = five attempts exhausted; last_error says why.
-- 'skipped' = deliberately not pushed (frozen row, source moved, or a clear); read last_error.
--
-- Cadence: */2. The queue collapses repeat edits on the same field via a partial unique index, so
-- a burst of saves costs one push, and an empty run is a single cheap RPC that returns no rows.

begin;

create or replace function public.fn_request_outbound_custom_field_push()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_key text;
begin
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping outbound custom-field push';
    return;
  end if;
  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-custom-field',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := jsonb_build_object('source','cron'),
    timeout_milliseconds := 120000);
end;
$function$;

revoke all on function public.fn_request_outbound_custom_field_push() from public, anon, authenticated;

select cron.unschedule('outbound-custom-field-push')
 where exists (select 1 from cron.job where jobname = 'outbound-custom-field-push');

select cron.schedule('outbound-custom-field-push', '*/2 * * * *',
                     $$select public.fn_request_outbound_custom_field_push()$$);

do $verify$
declare v_n integer;
begin
  select count(*) into v_n from cron.job
   where jobname = 'outbound-custom-field-push' and active and schedule = '*/2 * * * *';
  if v_n <> 1 then raise exception 'VERIFY FAILED: cron job not scheduled or inactive (%)', v_n; end if;

  -- The vault secret every other edge-invoking cron depends on. Missing it makes this job succeed
  -- forever while pushing nothing, which is the precise failure this file warns about above.
  select count(*) into v_n from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_n <> 1 then raise exception 'VERIFY FAILED: edge_invoke_service_key vault secret missing'; end if;

  if has_function_privilege('anon', 'public.fn_request_outbound_custom_field_push()', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can invoke the outbound push';
  end if;

  raise notice 'VERIFY OK: outbound-custom-field-push scheduled */2, vault secret present, anon refused';
end
$verify$;

commit;
