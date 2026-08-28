-- 2026-08-28_1025_visit_report_manifest_flag.sql
--
-- The signal behind the Admin Review dialog's "the automatic email will be skipped" note.
--
-- Fred, 2026-08-28: *"we can add that message on the current confirmation dialog when trying to
-- send the email, like a blue note box, explaining it."* The reviewer currently has no idea that
-- clicking Send cancels the automatic 24-hour city email. The email BODY already handles the other
-- half correctly (it omits the "a separate email will follow" promise when the manifest is
-- attached), so the CITY is never promised a phantom email - but the STAFF MEMBER is told nothing.
--
-- 🛑 WHY A NEW VIEW RATHER THAN public.v_visit_city_email_status.
-- That view is built FROM public.derm_email_sends, so it only has a row for a visit whose manifest
-- has already had a city email attempt. **A visit that carries the manifest but has never had a
-- city email has NO ROW THERE** - and that is precisely the case the note exists for. Widening its
-- FROM would change its row set under the dialog code that already reads it. A separate view
-- cannot regress an existing reader.
--
-- 🛑 IT LIVES IN `public`, NOT `customer`, ON PURPOSE. Admin Review is `authenticated` and CAN read
-- customer.work_orders directly, so this view is not a privilege workaround. It exists so the app
-- needs no `.schema('customer')` call: forgetting that switch silently queries a non-existent
-- public table and PostgREST answers 404, which reads as "no data" rather than as an error. That
-- exact trap cost real time on the calendar task chips.
--
-- 🛑 THE FLAG MUST MIRROR send-visit-photos-email's `hasDermDocs`, NOT "a manifest_visits link
-- exists". The edge function derives it from customer.work_orders (derm_manifest_url OR
-- wwtp_receipt_url) because 53 completed visits carry a link while the blackout pipeline has not
-- published a document. Keying the note on the link would promise a suppression that will not
-- happen. Same source, same answer, so the dialog and the email cannot disagree.
--
-- RULE 8 (ADR 010): a view, holds no rows, audit does not apply.
--
begin;

create or replace view public.v_visit_report_manifest as
select v.id                                                                     as visit_id,
       v.public_id,
       (wo.derm_manifest_url is not null or wo.wwtp_receipt_url is not null)     as report_has_manifest
  from public.visits v
  left join customer.work_orders wo on wo.id = v.public_id
 where v.deleted_at is null;

comment on view public.v_visit_report_manifest is
  'Does the Field Portal Service Report for this visit already carry the DERM documents? '
  'TRUE means a manual "Send email to City" will cancel the automatic 24h city email, which is '
  'what the dialog note tells the reviewer. Mirrors send-visit-photos-email''s hasDermDocs exactly '
  '(customer.work_orders, never a manifest_visits link) so the dialog and the email cannot disagree.';

-- Admin Review reads Prod as `authenticated`. anon gets nothing.
revoke all on public.v_visit_report_manifest from public, anon;
grant select on public.v_visit_report_manifest to authenticated, service_role;

commit;
