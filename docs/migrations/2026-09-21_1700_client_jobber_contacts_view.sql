-- 2026-09-21_1700_client_jobber_contacts_view.sql
--
-- Expose public.client_jobber_contacts to the Client App the way the app can actually reach it.
--
-- WHY. Measured on the live bundle rather than assumed: the Client App's Supabase client is built
-- with `db: { schema: 'client' }` and every call it makes is `.schema('client')`. It has no path
-- to a table in `public`. Every other thing it reads is a `client.*` mirror-parity view, so this
-- follows that pattern instead of changing how the app is wired.
--
-- LIVE ROWS ONLY. The view filters `deleted_at is null`, so a contact removed in Jobber simply
-- disappears from the app while the row stays for the audit trail. The app never needs to know
-- the soft-delete exists.

begin;

create or replace view client.jobber_contacts as
  select jc.id,
         jc.client_id,
         jc.jobber_contact_id,
         jc.first_name,
         jc.last_name,
         -- what to show on the card: Jobber's own rendered name when it has one ("Mr. Yannick
         -- ayache"), otherwise the halves joined. Never blank.
         coalesce(nullif(btrim(jc.name), ''),
                  nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)), '')) as display_name,
         jc.jobber_role,
         jc.title,
         jc.is_billing_contact,
         jc.email,
         jc.phone,
         jc.property_gids,
         jc.synced_at
    from public.client_jobber_contacts jc
   where jc.deleted_at is null;

comment on view client.jobber_contacts is
  'Live Jobber ContactModel people for a client, for the Client App. Refreshed read-through by '
  'save-client-contact action:''refresh'' when a client page opens. NOT the same as '
  'client.client_contacts, which carries the synthesised client-record mirror plus our own '
  'accounting/city rows. Nothing in the DERM path reads this.';

revoke all on client.jobber_contacts from anon;
revoke all on client.jobber_contacts from authenticated;
grant select on client.jobber_contacts to authenticated;
grant select on client.jobber_contacts to service_role;

commit;

-- ============================================================================================
-- VERIFY
--   select (select count(*) from client.jobber_contacts)                          as live_rows,
--          (select count(*) from public.client_jobber_contacts)                   as all_rows,
--          has_table_privilege('anon','client.jobber_contacts','select')          as anon_MUST_BE_FALSE,
--          has_table_privilege('authenticated','client.jobber_contacts','select') as auth_MUST_BE_TRUE,
--          has_table_privilege('authenticated','client.client_contacts','select') as control_MUST_BE_TRUE;
--
--   POSITIVE CONTROL that the soft-delete filter actually filters: soft-delete a row in a
--   rolled-back transaction and confirm live_rows drops by one. A view that returns the same
--   count either way has not been shown to filter anything.
-- ============================================================================================
