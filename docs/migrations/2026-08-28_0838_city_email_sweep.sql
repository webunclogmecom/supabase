-- 2026-08-28_0838_city_email_sweep.sql
--
-- PHASE 3, the last piece: the driver for the automatic city email.
--
-- 🛑 IT SHIPS LIVE BUT INERT. The cron runs hourly from the moment this applies, and does
-- NOTHING, because public.app_config.city_email_start_from is 'infinity' so the queue is empty.
-- That is deliberate: a cron that has been running harmlessly for days is a far better thing to
-- switch on than one whose first ever execution is also its first real send.
--
-- FRED, 2026-08-28, on how he wants to test this:
--   *"we could change the times of the cron jobs, so we don't need to do the tests by days, but
--    for dozens of minutes or hours instead. Once that the cronjobs and all the tests are done we
--    can just change the numbers to the real times."*
-- That requires the 24 hours to be DATA, not a literal. PART 1 moves it into app_config next to
-- the switch. Nothing else in this migration would work for testing without that.
--
-- CADENCE: hourly. Measured cost of one queue check is 24ms execution + 24ms planning, 447 shared
-- blocks, 0 disk reads => about 1.2 seconds of database time per day. The sweep only makes an HTTP
-- call when the queue is NON-EMPTY, so the edge function is invoked roughly 17 times a month
-- rather than 720. The 24h is a settling period, not a deadline, so being up to an hour late is
-- immaterial; hourly also caps a mistake at one batch per hour instead of one per five minutes.
--
-- RULE 8 (ADR 010): app_config is already audited (2026-08-28_0605). The rest here is a function,
-- a view replacement and a cron entry, none of which hold rows.
--
begin;

-- ---------------------------------------------------------------------------
-- PART 1 — the delay becomes configuration
--
-- 🛑 FAIL-SAFE DIRECTION MATTERS. A missing or unparseable value falls back to 24 hours, never
-- to zero. Zero would make every past manifest instantly due, which is the one outcome the
-- go-live cutoff exists to prevent.
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value) values
  ('city_email_delay', '24 hours'),
  -- Empty = send to the real municipal recipients. Set to a staff address to route the whole
  -- sweep to a person instead. send-derm-email refuses anything off @ayache.com / @unclogme.com,
  -- so a typo here cannot silently become a live regulator send.
  ('city_email_test_recipient', ''),
  -- Cap per run. The edge function loops and renders a PDF per manifest, so this bounds both the
  -- worst-case blast radius of a mistake and the function's CPU budget.
  ('city_email_batch_limit', '5')
on conflict (key) do nothing;

create or replace function public.fn_city_email_delay()
returns interval
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select nullif(btrim(value), '')::interval from public.app_config where key = 'city_email_delay'),
    interval '24 hours')
$$;

comment on function public.fn_city_email_delay() is
  'How long after blackout the automatic city email is due. Data, not a literal, so a test can '
  'shorten it to minutes. Falls back to 24 hours when missing or unparseable - never to zero.';

-- ---------------------------------------------------------------------------
-- PART 2 — the candidates view reads the configured delay, and gains an error cap
--
-- Rewritten in full (CREATE OR REPLACE takes the whole body). Changes against 2026-08-28_0605:
--   * interval '24 hours' -> public.fn_city_email_delay()
--   * status 'waiting_24h' -> 'waiting', because the wait is no longer necessarily 24 hours
--   * NEW status 'too_many_errors': 3+ error rows for this (manifest, client). Without it a
--     manifest that fails for a structural reason is retried every hour for ever.
-- Everything else is byte-identical to the previous body.
-- ---------------------------------------------------------------------------
create or replace view derm.v_city_email_candidates as
with cfg as (
  select coalesce(
           (select nullif(btrim(value), '')::timestamptz
              from public.app_config where key = 'city_email_start_from'),
           'infinity'::timestamptz) as start_from,
         public.fn_city_email_delay() as delay
),
docs as (
  select r.manifest_id,
         r.client_id,
         max(r.generated_at) as blacked_at,
         count(*)            as pages
    from derm.redacted_manifest_docs r
    join public.derm_manifests dm on dm.id = r.manifest_id and dm.deleted_at is null
   group by 1, 2
),
resolved as (
  select d.manifest_id,
         d.client_id,
         d.blacked_at,
         d.pages,
         count(distinct v.property_id) as properties,
         count(distinct p.id)          as city_properties,
         min(p.id)                     as property_id
    from docs d
    left join public.manifest_visits mv on mv.manifest_id = d.manifest_id
    left join public.visits v
           on v.id = mv.visit_id and v.deleted_at is null and v.client_id = d.client_id
    left join public.properties p
           on p.id = v.property_id
          and p.deleted_at is null
          and p.city_emails is not null
          and cardinality(p.city_emails) > 0
   group by 1, 2, 3, 4
),
sent as (
  select manifest_id, client_id, min(sent_at) as first_sent_at
    from public.derm_email_sends
   where recipient_type = 'city' and status = 'sent' and coalesce(is_test, false) = false
   group by 1, 2
),
errored as (
  select manifest_id, client_id, count(*) as error_count
    from public.derm_email_sends
   where recipient_type = 'city' and status = 'error'
   group by 1, 2
),
suppressed as (
  select mv.manifest_id, v.client_id, min(s.sent_at) as suppressed_at
    from public.visit_photo_email_sends s
    join public.visits v          on v.id = s.visit_id and v.deleted_at is null
    join public.manifest_visits mv on mv.visit_id = v.id
   where s.status = 'sent'
     and coalesce(s.is_test, false) = false
     and s.include_manifest is true
   group by 1, 2
)
select r.manifest_id,
       r.client_id,
       r.property_id,
       r.blacked_at,
       r.blacked_at + (select delay from cfg) as due_at,
       r.pages,
       r.properties,
       r.city_properties,
       s.first_sent_at,
       sup.suppressed_at,
       (select start_from from cfg) as start_from,
       case
         when s.manifest_id   is not null then 'already_sent'
         when sup.manifest_id is not null then 'suppressed_manual'
         when coalesce(e.error_count, 0) >= 3 then 'too_many_errors'
         when r.properties = 0            then 'no_property'
         when r.city_properties > 1       then 'ambiguous_property'
         when r.city_properties = 0       then 'no_city_email'
         when r.blacked_at + (select delay from cfg) > now() then 'waiting'
         when r.blacked_at <= (select start_from from cfg) then 'before_go_live'
         else 'ready'
       end as status,
       -- 🛑 APPENDED, NOT INSERTED. CREATE OR REPLACE VIEW can only add columns at the END;
       -- putting these next to their siblings raises 42P16 and would force a DROP, which
       -- discards the grants. Column order here is a compatibility constraint, not a style.
       coalesce(e.error_count, 0)   as error_count,
       (select delay from cfg)      as delay
  from resolved r
  left join sent       s   on s.manifest_id   = r.manifest_id and s.client_id   = r.client_id
  left join errored    e   on e.manifest_id   = r.manifest_id and e.client_id   = r.client_id
  left join suppressed sup on sup.manifest_id = r.manifest_id and sup.client_id = r.client_id;

comment on view derm.v_city_email_candidates is
  'Every blacked-out DERM manifest with an explicit status for the automatic city email. '
  'status=ready means due now. Never filters a row away: no_city_email, ambiguous_property, '
  'too_many_errors and before_go_live are visible states, not silent absences. '
  'The wait comes from public.fn_city_email_delay(), so a test can shorten it.';

-- ---------------------------------------------------------------------------
-- PART 3 — the sweep
--
-- 🛑 NO QUEUE, NO HTTP CALL. The early return is what makes hourly cheap: 23 of every 24 runs
-- cost one indexed read and nothing else. It is also why this reads the queue itself rather than
-- letting the edge function do it - an empty sweep must not wake a function up.
--
-- 🛑 IT DOES NOT DEQUEUE. There is no state to clear: send-derm-email writes a derm_email_sends
-- row per manifest, and the 'already_sent' gate above excludes it on the next pass. So a crash
-- mid-batch loses nothing and retries only what did not get logged.
-- ---------------------------------------------------------------------------
create or replace function public.fn_request_city_email_sweep()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_key   text;
  v_limit int;
  v_test  text;
  v_recipients jsonb;
  v_body  jsonb;
begin
  select coalesce(nullif(btrim(value), '')::int, 5) into v_limit
    from public.app_config where key = 'city_email_batch_limit';
  v_limit := coalesce(v_limit, 5);

  select jsonb_agg(jsonb_build_object(
           'manifest_id', q.manifest_id,
           'client_id',   q.client_id,
           -- 🛑 property_id is what keeps the email to the municipality that actually covers this
           -- visit. Without it send-derm-email unions city_emails across every property the
           -- client owns, which over-sends on 38 of the 107 sendable manifests.
           'property_id', q.property_id))
    into v_recipients
    from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;

  if v_recipients is null then
    return;  -- nothing due. No HTTP call, no edge invocation, no log noise.
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping city email sweep';
    return;
  end if;

  v_body := jsonb_build_object('target', 'city', 'recipients', v_recipients);

  select nullif(btrim(value), '') into v_test
    from public.app_config where key = 'city_email_test_recipient';
  if v_test is not null then
    v_body := v_body || jsonb_build_object('test_recipient', v_test);
  end if;

  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := v_body,
    timeout_milliseconds := 60000);
end $$;

comment on function public.fn_request_city_email_sweep() is
  'Hourly driver for the automatic city email. Reads derm.v_city_email_queue and POSTs the due '
  'manifests to send-derm-email. Returns without any HTTP call when nothing is due, which is what '
  'makes hourly cost ~1.2s of DB time a day. Does not dequeue: derm_email_sends is the record.';

revoke all on function public.fn_request_city_email_sweep() from public, anon, authenticated;
revoke all on function public.fn_city_email_delay() from public, anon, authenticated;
grant execute on function public.fn_request_city_email_sweep() to service_role;
grant execute on function public.fn_city_email_delay() to service_role;

-- ---------------------------------------------------------------------------
-- PART 4 — the cron. Live, hourly, and inert while the switch is 'infinity'.
-- ---------------------------------------------------------------------------
select cron.unschedule('city-email-sweep')
 where exists (select 1 from cron.job where jobname = 'city-email-sweep');

select cron.schedule('city-email-sweep', '7 * * * *',
                     $$select public.fn_request_city_email_sweep()$$);

commit;
