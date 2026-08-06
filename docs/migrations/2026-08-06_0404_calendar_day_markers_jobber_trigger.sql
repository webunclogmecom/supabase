-- 2026-08-06_0404 — auto-push calendar day markers to Jobber on write
--
-- Completes the wiring Fred asked for. Until now `jobber-push-task` existed and worked but nothing
-- called it; markers only reached Jobber when I invoked the function by hand.
--
-- Mirrors the visits pattern exactly (`public.fn_request_jobber_push` + `fn_push_visit_to_jobber`):
-- a SECDEF function reads the service key from Vault and fires `net.http_post` at the edge function.
-- Deliberately the same shape so there is one idiom to learn, not two.
--
-- 🛑 THE TRIGGER LIVES ON THE TABLE, NOT IN THE APP, AND THAT IS THE POINT. The Calendar writes
-- markers directly via PostgREST, and so could a script or a future app. A push wired into one
-- client only covers that client. On the table it covers every writer.
--
-- ⚠ pg_net is FIRE-AND-FORGET. The HTTP call is queued and the transaction commits without waiting,
-- so a Jobber failure does NOT roll back the marker — the marker is the master and Jobber follows.
-- That is the same contract as visits. To see whether a push actually landed, read
-- `net._http_response`; `cron.job_run_details.status='succeeded'` proves nothing about pg_net.
--
-- ⚠ RE-DROPPING A MARKER IS A DELETE + INSERT in the app, which will fire delete-then-create here and
-- yield a NEW Jobber Task id. That is correct behaviour, not a leak: the old Task is really deleted
-- first (the edge function verifies it is gone before dropping the link). Do not "optimise" it into
-- an UPDATE without checking the app still does delete+insert.
--
-- 🛑 AUDIT: opt-out, consistent with the table's original decision. This adds no human-editable
-- field; it is a dispatch mechanism. `ops.calendar_day_markers` remains unaudited, so audit silence
-- still proves nothing about its use.

begin;

create or replace function public.fn_request_marker_push(p_marker_id bigint, p_op text default 'upsert')
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_key text;
begin
  -- An explicit suppression escape hatch, same idea as app.suppress_jobber_push for visits: lets a
  -- backfill or a test write markers without spraying Jobber. Absent/unset = push (the safe default,
  -- because forgetting to set it must not silently disable the integration).
  if coalesce(current_setting('app.suppress_marker_push', true), 'off') = 'on' then
    return;
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'jobber_push_service_key';
  if v_key is null then
    raise warning 'jobber_push_service_key vault secret missing; skipping marker push for %', p_marker_id;
    return;
  end if;

  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-task',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := jsonb_build_object('op', p_op, 'marker_id', p_marker_id));
end;
$function$;

comment on function public.fn_request_marker_push(bigint, text) is
  'Queue a Jobber Task push for one ops.calendar_day_markers row. Fire-and-forget via pg_net — read '
  'net._http_response to confirm delivery. Set app.suppress_marker_push=''on'' to silence it for a '
  'backfill.';

create or replace function public.fn_push_marker_to_jobber()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if tg_op = 'DELETE' then
    perform public.fn_request_marker_push(old.id, 'delete');
    return old;
  end if;

  -- On UPDATE, only push when something Jobber can SEE changed. Without this guard any future
  -- bookkeeping column (a touched updated_at, a backfill) would fire a Jobber round-trip for nothing.
  if tg_op = 'UPDATE'
     and new.marker_date is not distinct from old.marker_date
     and new.marker_type is not distinct from old.marker_type
     and new.minutes     is not distinct from old.minutes
     and new.vehicle_id  is not distinct from old.vehicle_id
     and new.dump_site   is not distinct from old.dump_site then
    return new;
  end if;

  perform public.fn_request_marker_push(new.id, 'upsert');
  return new;
end;
$function$;

drop trigger if exists trg_push_marker_to_jobber on ops.calendar_day_markers;
create trigger trg_push_marker_to_jobber
  after insert or update or delete on ops.calendar_day_markers
  for each row execute function public.fn_push_marker_to_jobber();

-- Locked to the trigger + service_role. The app never calls this directly; it writes the marker and
-- the table does the rest. ⚠ Supabase's ALTER DEFAULT PRIVILEGES grants EXECUTE on new public
-- functions to anon AND authenticated, so revoking from PUBLIC alone would leave both in place —
-- revoke them by name (this has bitten before).
revoke all on function public.fn_request_marker_push(bigint, text) from public, anon, authenticated;
revoke all on function public.fn_push_marker_to_jobber() from public, anon, authenticated;
grant execute on function public.fn_request_marker_push(bigint, text) to service_role;

commit;

-- Verified after apply: insert a marker as `authenticated` (the app's real role) and confirm a row
-- appears in net._http_response with 200 and an ok:true body — i.e. the push actually reached Jobber,
-- not merely that the trigger did not error.
