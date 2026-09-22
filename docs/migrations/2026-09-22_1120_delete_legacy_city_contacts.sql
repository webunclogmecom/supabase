-- 2026-09-22_1120_delete_legacy_city_contacts.sql
--
-- Step 1 of the Contacts Role + Communication build.
--
-- WHY. `contact_role = 'city'` is a leftover. City email moved to the PROPERTY on 2026-08-21
-- (`properties.city_emails`, rule 2h in the Client App's CLAUDE.md), and it is live on 109 of 958
-- properties. Fred, 2026-09-22: *"we need to delete the 21 old city email from the contacts, we use
-- now the city email field from the property."* Yannick had said the same in
-- #C0BD3VDPB9S on 2026-09-04, and Fred replied *"city email are linked to the property so im gonna
-- remove it"*.
--
-- WHAT THESE ROWS ACTUALLY ARE. Not people. 19 of the 21 hold several municipal addresses in ONE
-- comma-separated string, e.g. `jbrown@hallandalebeachfl.gov, JTuszynski@hallandalebeachfl.gov`.
-- They are FOG inboxes that predate the per-property field.
--
-- 🛑 THIS IS A HARD DELETE, and the standing rule is soft-delete only. The exception is deliberate
-- and narrow: `public.client_contacts` HAS NO `deleted_at` column, and adding one would change the
-- table that `webhook-jobber` upserts into on every CLIENT_UPDATE. Recovery is covered twice instead:
--   1. `audit.logs` holds one DELETE row per id with the full `old_row` (the table carries
--      `audit_client_contacts`; a rolled-back rehearsal confirmed 21 DELETE rows are written).
--   2. `backups/2026-09-22_client_contacts_city_rows_deleted.json` is the convenience copy.
--
-- MEASURED BEFORE APPLYING, all in rolled-back transactions:
--   * 21 rows, 21 distinct clients, 19 of them comma bags.
--   * NO client's DERM recipient is a city row (`fn_derm_recipient ->> 'contact_role' = 'city'` = 0).
--   * EVERY one of the 21 clients keeps at least one other emailed contact (0 left with none).
--   * NOTHING references `client_contacts` by foreign key.
--   * Rehearsal of this exact DELETE: clients whose recipient changes = 0, clients with a recipient
--     395 before and after, `derm.manifest_recipients.has_email` 725 before and after.
--   * 🛑 POSITIVE CONTROL, because "0 changed" from a blind comparison looks identical to "0 changed"
--     from a safe migration: the same rehearsal with ONE extra emailed contact deleted (one that IS
--     somebody's recipient) reports 1 changed. The comparison can see a loss, so the 0 is real.

begin;

delete from public.client_contacts
 where contact_role = 'city';

commit;

-- ============================================================================================
-- VERIFY
--   select jsonb_build_object(
--     'city_rows_left_MUST_BE_0',  (select count(*) from public.client_contacts where contact_role='city'),
--     'deleted_rows_in_audit',     (select count(*) from audit.logs
--                                    where table_name='client_contacts' and operation='DELETE'
--                                      and (old_row->>'contact_role') = 'city'),
--     'clients_with_a_recipient',  (select count(*) from public.clients cl
--                                    where client.fn_derm_recipient(cl.id) is not null),
--     'has_email',                 (select count(*) from derm.manifest_recipients where has_email))
--   EXPECT 0 / 21 / 395 / 725.
--
--   The audit count is the one that matters: it proves the rows are recoverable, which is what
--   makes a hard delete acceptable here at all.
-- ============================================================================================
