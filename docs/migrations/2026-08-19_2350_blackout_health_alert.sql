-- 2026-08-19_2350_blackout_health_alert.sql
--
-- WHAT: a daily health check over derm.v_blackout_blocked_sheets, so a stamped-but-unmeasured
--       address sheet raises `attention` in public.sync_log instead of waiting for a client to
--       report a blank Field Portal card.
--
-- WHY:  Fred, after the 306-16 incident: "add the detection check ... wire the detector to an
--       alert." That incident sat unnoticed across 34 clients because the only thing watching was
--       redact-manifest-sweep, and it logs `succeeded` every five minutes regardless: an EMPTY WORK
--       QUEUE IS A SUCCESSFUL RUN. Nothing in the estate distinguished "nothing to do" from
--       "nothing can be done".
--
-- PATTERN: deliberately identical to public.log_rpa_derm_health() and log_calendar_push_health() --
--       read a health view, build a `reasons` jsonb, write one public.sync_log row with
--       status 'attention' or 'ok'. Same shape means whatever already watches sync_log for
--       attention rows picks this up with no extra wiring, and one idiom stays one idiom.
--
-- ⚠ IT REPORTS SHEETS, AND SEPARATELY THE CLIENT BLAST RADIUS. A single unmeasured sheet can hide
--    dozens of clients' documents (ticket-311780 alone held 5). Reporting only a sheet count would
--    make a real outage read as a small number.
--
-- ⚠ THE THRESHOLD IS ZERO, ON PURPOSE. There is no acceptable steady-state level of this: a
--    stamped sheet with no measurement can never produce a customer document. Any row is a fault.
--    Two sheets are blocked as of today (ticket-832996, window5-sheet3), both scanned sheets
--    awaiting a real vision measurement, so this WILL fire until they are done. That is correct --
--    those clients genuinely cannot see their manifest.
--
-- AUDIT (rule 8): no table changed. One function, one cron entry.

begin;

create or replace function public.log_blackout_health()
returns integer
language plpgsql
security definer
set search_path to 'public', 'derm', 'pg_temp'
as $$
declare
  v_sheets   int  := 0;
  v_clients  int  := 0;
  v_manifests int := 0;
  v_oldest   interval;
  v_detail   jsonb;
  v_attn     boolean := false;
begin
  select count(*),
         coalesce(sum(clients_blocked), 0),
         coalesce(sum(manifests_blocked), 0),
         max(blocked_for)
    into v_sheets, v_clients, v_manifests, v_oldest
    from derm.v_blackout_blocked_sheets;

  v_attn := v_sheets > 0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'dump_folder',       b.dump_folder,
           'stamped_rows',      b.stamped_rows,
           'stamped_pages',     b.stamped_pages,
           'clients_blocked',   b.clients_blocked,
           'manifests_blocked', b.manifests_blocked,
           'blocked_for',       b.blocked_for::text) order by b.last_stamp_at), '[]'::jsonb)
    into v_detail
    from derm.v_blackout_blocked_sheets b;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('blackout-health', now(), now(), v_sheets,
          case when v_attn then 'attention' else 'ok' end,
          jsonb_build_object(
            'blocked_sheets',    v_sheets,
            'clients_blocked',   v_clients,
            'manifests_blocked', v_manifests,
            'oldest_blocked_for', v_oldest::text,
            'sheets',            v_detail,
            'what_it_means',     case when v_attn
              then 'These address sheets are stamped but carry no page_block_extents row for a stamped page, so derm.fn_blackout_targets yields nothing, no redacted sheet is produced, and those clients see an EMPTY DERM FOG eManifest card in the Field Portal. Run a measurement pass. Generated sheets (#1000+) can be templated at 25.8/64.4; scanned sheets need a real vision measurement.'
              else 'Every stamped address-sheet page has a measured extent.' end));

  return v_sheets;
end $$;

revoke all on function public.log_blackout_health() from public, anon, authenticated;
grant execute on function public.log_blackout_health() to service_role;

comment on function public.log_blackout_health() is
  'Daily check for stamped-but-unmeasured address sheets. Writes one public.sync_log row, status attention when any sheet is blocked. Exists because redact-manifest-sweep cannot report this: an empty work queue is a successful run.';

-- ---- schedule: daily at 08:00 ET ---------------------------------------------------------------
-- ⚠ pg_cron runs in UTC. 12:00 UTC is 08:00 EDT / 07:00 EST; the neighbouring checks
--    (calendar-push-health 07:30 UTC, rpa-derm-health 09:00 UTC) are staggered the same way, so
--    this sits after them rather than contending.
select cron.unschedule('blackout-health-check')
 where exists (select 1 from cron.job where jobname = 'blackout-health-check');

select cron.schedule('blackout-health-check', '0 12 * * *', $cron$ SELECT public.log_blackout_health(); $cron$);

-- ---- VERIFY ------------------------------------------------------------------------------------
do $verify$
declare v_n int; v_row record; v_sched int;
begin
  -- EXERCISE the function, do not merely create it: PL/pgSQL is not parsed at creation time.
  v_n := public.log_blackout_health();

  select * into v_row from public.sync_log
   where sync_source = 'blackout-health' order by started_at desc limit 1;
  if v_row is null then raise exception 'VERIFY: the function wrote no sync_log row'; end if;

  -- Two sheets are blocked today, so this MUST report attention. A green result here would mean
  -- the detector cannot see a state we know exists, which is the failure this whole thing exists
  -- to prevent.
  if v_row.status <> 'attention' then
    raise exception 'VERIFY: expected status=attention (2 sheets are blocked), got %', v_row.status;
  end if;
  if (v_row.details->>'blocked_sheets')::int <> 2 then
    raise exception 'VERIFY: expected 2 blocked sheets, details says %', v_row.details->>'blocked_sheets';
  end if;
  if (v_row.details->>'clients_blocked')::int < 1 then
    raise exception 'VERIFY: blocked sheets reported but no client blast radius, so the alert would understate a real outage';
  end if;

  select count(*) into v_sched from cron.job where jobname = 'blackout-health-check' and active;
  if v_sched <> 1 then raise exception 'VERIFY: cron job not scheduled (found %)', v_sched; end if;

  raise notice 'VERIFY ok: fired attention on % blocked sheets covering % clients, cron scheduled',
    v_row.details->>'blocked_sheets', v_row.details->>'clients_blocked';
end $verify$;

commit;
