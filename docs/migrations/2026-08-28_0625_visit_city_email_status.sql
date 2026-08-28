-- 2026-08-28_0625_visit_city_email_status.sql
--
-- PHASE 4 (DB half) of the automatic city email: the REVERSE guard.
--
-- Fred, 2026-08-27: if the automatic email already went, the Admin Review confirmation dialog
-- must say so with the timestamp - *"it should say 'This email was already sent on
-- dd/MM/yyyy hh:mm' something semantic."* Phase 1 built the forward direction (a manual send
-- cancels the timer). This is the half everybody forgets, because the other one is the one
-- people think of first.
--
-- 🛑 WHY A NEW VIEW RATHER THAN EXTENDING public.v_visit_photo_email_status.
-- That view's FROM is an aggregate over visit_photo_email_sends, so it has a row ONLY for
-- visits that already have a PHOTO email. The dialog needs the city-email answer even when no
-- photo email was ever sent, which would mean widening its row set. Admin Review reads that
-- view today and nothing here can prove what it keys on, so adding rows to it is a change with
-- an unknown blast radius. A separate view cannot regress an existing reader.
--
-- GRAIN. derm_email_sends is per (manifest_id, client_id); the dialog is per VISIT. The join is
-- visit -> manifest_visits -> derm_email_sends, matched on the visit's own client so a shared
-- ticket cannot leak another client's send onto this visit.
--
-- RULE 8 (ADR 010): this is a VIEW and holds no rows, so audit does not apply. Its source
-- table public.derm_email_sends is already audited.
--
begin;

create or replace view public.v_visit_city_email_status as
select mv.visit_id,
       max(s.sent_at) filter (
         where s.status = 'sent' and coalesce(s.is_test, false) = false
       )                                                                   as city_email_sent_at,
       count(*) filter (
         where s.status = 'sent' and coalesce(s.is_test, false) = false
       )                                                                   as city_email_sent_count,
       -- The most recent real recipient list, for the dialog to name who received it.
       (array_agg(s.recipient_email order by s.sent_at desc) filter (
         where s.status = 'sent' and coalesce(s.is_test, false) = false
       ))[1]                                                               as city_email_recipient,
       -- Why the last attempt did NOT send, when it did not. 'no_city_email' is the common one
       -- and is the honest answer to "when is the city getting this?": never, by Fred's rule.
       (array_agg(s.reason order by s.sent_at desc) filter (
         where s.status = 'skipped'
       ))[1]                                                               as last_skip_reason
  from public.manifest_visits mv
  join public.visits v          on v.id = mv.visit_id and v.deleted_at is null
  join public.derm_email_sends s on s.manifest_id = mv.manifest_id
                               and s.recipient_type = 'city'
                               and s.client_id = v.client_id
 group by mv.visit_id;

comment on view public.v_visit_city_email_status is
  'Per-visit city-email (email 2) status for the Admin Review confirmation dialog. '
  'city_email_sent_at NOT NULL means the city already has the manifest for this visit and the '
  'dialog must say so rather than silently sending a second copy. Test sends never count. '
  'Deliberately separate from v_visit_photo_email_status, whose row set must not widen.';

-- Admin Review reads Prod as `authenticated`. anon must not: this names municipal recipients.
revoke all on public.v_visit_city_email_status from public, anon;
grant select on public.v_visit_city_email_status to authenticated, service_role;

commit;
