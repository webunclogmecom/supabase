-- 2026-08-28_0916_city_email_retry_guard.sql
--
-- 🛑 THE SWEEP HAD NO RE-SEND GUARD. FOUND BY ACTUALLY RUNNING IT, NOT BY READING IT.
--
-- Fred asked for a full test cycle. With the delay at 3 minutes and the cron at every minute, the
-- 09:15 sweep correctly sent 4 manifests -- and the queue still read `ready: 4` afterwards, so the
-- 09:16 sweep would have sent the same four again, and so on every minute. The cron was paused by
-- hand at exactly 4 emails.
--
-- WHY: the `sent` CTE filters `coalesce(is_test,false) = false`, and the city gate
-- (city_email_live_sends=false) forces every send to is_test=true. So a gated send never satisfies
-- the only gate that would have stopped it. That filter is CORRECT and stays -- a test send must
-- never suppress a real regulator submission -- but it means "already sent" was the sole re-send
-- guard and it is blind by design during testing.
--
-- 🛑 AND THIS IS NOT ONLY A TESTING PROBLEM. In production nothing stopped two sweeps overlapping,
-- or a sweep running again before send-derm-email had finished writing its log rows. The window is
-- small at hourly cadence and it is not zero, and the cost of losing that race is a duplicate
-- submission to a municipal regulator.
--
-- THE FIX, and it is the shape v_derm_portal_queue already uses (its gate 2, "any non-dry-run
-- attempt in the last 20h"): exclude a (manifest, client) that has ANY city send attempt -- test or
-- real, sent or skipped or error -- inside a configurable window. That is orthogonal to
-- `already_sent`: this one asks "did we just try?", not "has the city got it?".
--
-- RULE 8 (ADR 010): a view replacement and one app_config row. app_config is already audited.
--
begin;

-- ---------------------------------------------------------------------------
-- PART 1 — the retry window becomes configuration, like the delay
--
-- 20 hours matches v_derm_portal_queue's existing gate. Shorten it for a test, exactly as the
-- delay is shortened. Falls back to 20 hours when missing or unparseable -- never to zero, which
-- would restore the loop this migration exists to stop.
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value) values ('city_email_retry_after', '20 hours')
on conflict (key) do nothing;

create or replace function public.fn_city_email_retry_after()
returns interval
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select nullif(btrim(value), '')::interval from public.app_config where key = 'city_email_retry_after'),
    interval '20 hours')
$$;

comment on function public.fn_city_email_retry_after() is
  'How long the sweep waits before touching a (manifest, client) it has already attempted, whatever '
  'the outcome. Stops a re-send loop when the send is not recorded as a real one - which is every '
  'send while the city gate is on. Falls back to 20 hours, never to zero.';

revoke all on function public.fn_city_email_retry_after() from public, anon, authenticated;
grant execute on function public.fn_city_email_retry_after() to service_role;

-- ---------------------------------------------------------------------------
-- PART 2 — the candidates view gains the guard
--
-- Rewritten in full (CREATE OR REPLACE takes the whole body). Changes against 2026-08-28_0838:
--   * NEW `attempted` CTE: the most recent city attempt of ANY status and ANY is_test.
--   * NEW status 'recently_attempted', placed directly after the two suppression states so it
--     shadows everything a fresh attempt should not race.
--   * NEW appended column `last_attempt_at`.
-- Everything else is byte-identical.
-- ---------------------------------------------------------------------------
create or replace view derm.v_city_email_candidates as
with cfg as (
  select coalesce(
           (select nullif(btrim(value), '')::timestamptz
              from public.app_config where key = 'city_email_start_from'),
           'infinity'::timestamptz) as start_from,
         public.fn_city_email_delay()       as delay,
         public.fn_city_email_retry_after() as retry_after
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
attempted as (
  -- 🛑 DELIBERATELY UNFILTERED on status and is_test. The question is "did we just try?", which is
  -- a different question from `sent`'s "has the city actually got it?". Filtering is_test here
  -- would reintroduce the loop, because the city gate makes every gated send a test send.
  select manifest_id, client_id, max(sent_at) as last_attempt_at
    from public.derm_email_sends
   where recipient_type = 'city'
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
         when a.last_attempt_at is not null
          and a.last_attempt_at > now() - (select retry_after from cfg) then 'recently_attempted'
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
       (select delay from cfg)      as delay,
       a.last_attempt_at
  from resolved r
  left join sent       s   on s.manifest_id   = r.manifest_id and s.client_id   = r.client_id
  left join attempted  a   on a.manifest_id   = r.manifest_id and a.client_id   = r.client_id
  left join errored    e   on e.manifest_id   = r.manifest_id and e.client_id   = r.client_id
  left join suppressed sup on sup.manifest_id = r.manifest_id and sup.client_id = r.client_id;

comment on view derm.v_city_email_candidates is
  'Every blacked-out DERM manifest with an explicit status for the automatic city email. '
  'status=ready means due now. Never filters a row away: no_city_email, ambiguous_property, '
  'recently_attempted, too_many_errors and before_go_live are visible states, not silent absences. '
  'The wait and the retry window both come from app_config, so a test can shorten them.';

commit;
