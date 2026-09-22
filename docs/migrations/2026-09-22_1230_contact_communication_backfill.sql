-- 2026-09-22_1230_contact_communication_backfill.sql
--
-- Step 5 of the Contacts Role + Communication build.
-- Plan: Building Apps/Client App/docs/2026-09-22_contacts-implementation-plan.md §2.9.
--
-- Seeds public.client_communication_prefs from the estate as it stands. Runs AFTER the legacy
-- `city` deletion (2026-09-22_1120) and BEFORE the recipient rewrite (2026-09-22_1200), so it
-- reads today's answer from today's function and the rewrite is then a provable no-op.
--
-- 🛑 BEHAVIOUR-PRESERVING BY CONSTRUCTION, WHICH IS THE WHOLE POINT.
-- `service_report` is set to EXACTLY the contact `client.fn_derm_recipient` returns today, per
-- client. So when 2026-09-22_1200 repoints the senders at the prefs table, every client's DERM
-- service report goes to the same address it goes to now. The equivalence is then a test rather
-- than a hope, and that test is the gate on step 6.
--
-- MEASURED TODAY, BEFORE WRITING THIS (the plan's own counts were taken before step 1 and have
-- moved; live data moves, so these are a dated observation and the VERIFY asserts relationships
-- rather than numbers):
--   473 clients
--   395 with a recipient   -> 392 client-level `primary`, 3 `accounting`
--    78 with no emailed contact at all
--     0 recipients that are comma bags (step 1 removed the 19 that were)
--
-- 🛑 THE TWO SELECTORS WERE CHECKED AGAINST EACH OTHER BEFORE BEING TRUSTED. This migration picks
-- the service-report contact with `fn_derm_recipient` and the invoice/quote contact with its own
-- CTE. Those are two different pieces of logic and they could disagree. Measured across all 473:
--   both set 395 · both null 78 · recipient-only 0 · target-only 0 · SAME CONTACT 395 · differing 0
-- So every configured client gets all three communications on ONE contact, and nobody gets a
-- billing recipient without a service-report recipient or the reverse. Had they diverged, the
-- right answer would have been to stop and ask, not to insert both.
--
-- WHAT IT DELIBERATELY LEAVES ALONE, and each is a decision rather than an omission:
--   * 78 clients with no email      -> nothing. There is nobody to configure; the app shows the
--                                      empty state. Inventing a recipient here is how a report
--                                      starts going to an address nobody chose.
--   * accounting rows that merely duplicate their primary's address -> nothing. The same address
--                                      already holds the communications on the primary row.
--   * accounting rows that are distinct people -> nothing. Whether that person should receive the
--                                      service report is a human decision, not a migration's.
--   * city_report                    -> NO ROWS AT ALL. Nobody has ever configured it, and the
--                                      per-property scope has no defensible default.
--
-- 🛑 REJECTED, and the reason generalises: seeding every `accounting` row with `service_report`.
-- Measured, that would add ~38 new (client, address) pairs that immediately start receiving the
-- DERM service report, and `client_email_live_sends` is TRUE, so those are real sends to real
-- customers. An assertion of the form "every client must still have a recipient" is
-- ONE-DIRECTIONAL and structurally cannot see an ADDED recipient, which is exactly the direction
-- that mails a stranger.
--
-- 🛑 ONE-SHOT BY DESIGN: it refuses to run if the table already holds anything, so it can never
-- overwrite a configuration a human has made. The whole thing is one transaction, so a failure
-- leaves the table exactly as empty as it found it. To revert: `delete from
-- public.client_communication_prefs;` - the pre-state is literally zero rows, which is why there
-- is no "before" backup file to write.

begin;

do $guard$
declare v_n int;
begin
  select count(*) into v_n from public.client_communication_prefs;
  if v_n <> 0 then
    raise exception 'client_communication_prefs already holds % row(s). This migration is a one-shot seed and will not overwrite a configuration somebody has made.', v_n;
  end if;
end $guard$;

-- 1) SERVICE REPORT = exactly who receives it TODAY.
insert into public.client_communication_prefs (client_id, comm_type, contact_id)
select r.client_id, 'service_report', (r.rec->>'contact_id')::bigint
  from (select cl.id as client_id, client.fn_derm_recipient(cl.id) as rec from public.clients cl) r
 where r.rec is not null
   and coalesce(r.rec->>'email','') not like '%,%';   -- 0 today; kept as a guard, not decoration

-- 2) INVOICE + QUOTE APPROVAL = the client-level primary, whose email IS the address Jobber shows
--    on the client record. This is the only defensible seed: a migration cannot ask the API who
--    Jobber will actually prefill, because `Client.defaultEmails` is a live read and is rewritten
--    only by a real send. So this records OUR intent and the app surfaces the drift.
with target as (
  select cl.id as client_id,
         coalesce(
           (select cc.id from public.client_contacts cc
             where cc.client_id = cl.id and cc.property_id is null and cc.contact_role = 'primary'
               and coalesce(btrim(cc.email),'') <> '' and cc.email not like '%,%'),
           (select cc.id from public.client_contacts cc
             where cc.client_id = cl.id
               and coalesce(btrim(cc.email),'') <> '' and cc.email not like '%,%'
             order by cc.id limit 1)) as contact_id
    from public.clients cl)
insert into public.client_communication_prefs (client_id, comm_type, contact_id)
select t.client_id, v.ct, t.contact_id
  from target t cross join (values ('invoice'),('quote_approval')) v(ct)
 where t.contact_id is not null;

-- 3) CITY REPORT: deliberately no rows.

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; rehearsed rolled-back with a mutation control before applying)
--
-- 🛑 THE ASSERTION THAT MATTERS IS FORWARD-LOOKING, not a row count. What this migration has to
-- guarantee is that step 6 changes nobody's mail:
--
--   for every client, the contact holding `service_report` MUST equal
--   (client.fn_derm_recipient(client_id) ->> 'contact_id')::bigint,
--   and a client with no recipient MUST hold no service_report row.
--   EXPECT 0 mismatches in both directions.
--
-- MUTATION CONTROL: repoint one seeded service_report row at a different contact inside a
-- rolled-back transaction; the comparison must report exactly 1 mismatch. A comparison that
-- cannot go red is not evidence, and this one is the gate on the whole recipient rewrite.
--
-- Cardinality, which the indexes enforce but which is asserted anyway because the indexes are new:
--   select client_id, count(*) from public.client_communication_prefs
--    where comm_type = 'invoice' group by 1 having count(*) > 1;      EXPECT 0 rows
--   select count(*) from public.client_communication_prefs where comm_type = 'city_report';
--                                                                    EXPECT 0
--
-- Relationship assertions (not pinned numbers, because the client population moves):
--   * distinct clients holding service_report        = clients with a non-null fn_derm_recipient
--   * distinct clients holding invoice               = distinct clients holding quote_approval
--   * every contact_id referenced is non-null and every jobber_contact_id is NULL (this seed
--     never points at a Jobber ContactModel; only a human can do that through the RPC)
--   * no seeded contact's email contains a comma
--
-- CONTROL that the seed is not vacuous: the number of prefs rows must be > 0 and every one of the
-- three seeded types must be present. A migration that inserted nothing would satisfy every
-- "must be 0" assertion above perfectly.
-- ============================================================================================
