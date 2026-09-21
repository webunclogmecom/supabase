-- 2026-09-21_1830_primary_contact_pointer.sql
--
-- MAKE "WHICH CONTACT IS PRIMARY" SOMETHING WE CAN MOVE.
--
-- Fred: *"just what we have today, but to be able to edit the primary contact, and in case we need
-- to, make another client the primary one."*
--
-- WHY IT DOES NOT WORK TODAY. The badge is derived from `contact_role = 'primary'` on the row
-- `(client_id, property_id IS NULL, 'primary')`. That row is ALSO the ON CONFLICT target of
-- webhook-jobber's mirror upsert, replayed by the */5 poll (measured: it reacts in ~20 seconds).
-- So moving the marker by editing `contact_role` makes the next poll INSERT A FRESH primary row and
-- the client ends up with two. The marker cannot live on the thing the poll owns.
--
-- THE FIX, and it is one nullable column. A pointer on the CLIENT, which nothing in the sync path
-- reads or writes:
--   NULL or 'client_record'  -> the synthesised client-record row is primary  (today's behaviour)
--   'ours:<client_contacts.id>'          -> one of our accounting/city rows is primary
--   'jobber:<client_jobber_contacts.id>' -> one of Jobber's real people is primary
--
-- Deliberately a TEXT pointer and not two FK columns: the target lives in one of two tables, so a
-- real FK cannot express it, and a fabricated one would only give false assurance. The resolution
-- is done in the views below, which simply return FALSE for a pointer that no longer resolves - so
-- a deleted contact degrades to "nobody is primary", never to a dangling badge.
--
-- NOTHING CHANGES UNTIL SOMEONE PROMOTES. Every existing client has NULL here, which resolves to
-- exactly the row that is badged today. Verified below on all 473.

begin;

alter table public.clients
  add column primary_contact_ref text;

comment on column public.clients.primary_contact_ref is
  'Which contact wears the PRIMARY badge. NULL or ''client_record'' = the synthesised '
  'client-record row (the default, and what every client had before 2026-09-21). '
  '''ours:<id>'' = a public.client_contacts row. ''jobber:<id>'' = a public.client_jobber_contacts '
  'row. Set only by save-client-contact action:''promote'', AFTER the Jobber push is verified. '
  'NOTHING in the sync path reads or writes it, which is the whole point: contact_role cannot carry '
  'this, because that row is the poll''s upsert key and moving it mints a duplicate primary.';

-- ---- the two views the Client App reads gain ONE derived flag ------------------------------
-- CREATE OR REPLACE appends columns at the end and checks TYPES, not expressions, so this is safe.

create or replace view client.client_contacts as
  select cc.id,
         cc.client_id,
         cc.property_id,
         cc.contact_role,
         cc.name,
         cc.first_name,
         cc.last_name,
         coalesce(nullif(btrim(concat_ws(' '::text, cc.first_name, cc.last_name)), ''::text), cc.name) as display_name,
         cc.email,
         cc.phone,
         cc.created_at,
         cc.updated_at,
         (case
            when coalesce(cl.primary_contact_ref, 'client_record') = 'client_record'
              then cc.property_id is null and cc.contact_role = 'primary'
            else cl.primary_contact_ref = 'ours:' || cc.id::text
          end) as is_primary
    from client_contacts cc
    join public.clients cl on cl.id = cc.client_id;

create or replace view client.jobber_contacts as
  select jc.id,
         jc.client_id,
         jc.jobber_contact_id,
         jc.first_name,
         jc.last_name,
         coalesce(nullif(btrim(jc.name), ''),
                  nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)), '')) as display_name,
         jc.jobber_role,
         jc.title,
         jc.is_billing_contact,
         jc.email,
         jc.phone,
         jc.property_gids,
         jc.synced_at,
         (cl.primary_contact_ref = 'jobber:' || jc.id::text) as is_primary
    from public.client_jobber_contacts jc
    join public.clients cl on cl.id = jc.client_id
   where jc.deleted_at is null;

comment on view client.jobber_contacts is
  'Live Jobber ContactModel people for a client, for the Client App. Refreshed read-through by '
  'save-client-contact action:''refresh'' when a client page opens. is_primary is driven by '
  'clients.primary_contact_ref. Nothing in the DERM path reads this view.';

-- CREATE OR REPLACE keeps grants, but re-assert them so this file is self-describing.
revoke all on client.client_contacts  from anon;
revoke all on client.jobber_contacts  from anon;
grant select on client.client_contacts to authenticated, service_role;
grant select on client.jobber_contacts to authenticated, service_role;

commit;

-- ============================================================================================
-- VERIFY
--
-- 1. NOTHING MOVED. With every pointer still NULL, exactly the rows badged before must be badged
--    now, on all 473 clients:
--      select count(*) from (
--        select cc.id,
--               (cc.property_id is null and cc.contact_role='primary') as before,
--               v.is_primary                                            as after
--          from public.client_contacts cc join client.client_contacts v on v.id = cc.id) s
--       where before is distinct from after;
--    EXPECT 0.
--
-- 2. EXACTLY ONE PRIMARY PER CLIENT, counting BOTH views together. This is the invariant the old
--    unique index used to give us and which the pointer now has to carry on its own:
--      select count(*) from (
--        select cl.id,
--               (select count(*) from client.client_contacts x where x.client_id=cl.id and x.is_primary)
--             + (select count(*) from client.jobber_contacts  y where y.client_id=cl.id and y.is_primary) as n
--          from public.clients cl) s
--       where n > 1;
--    EXPECT 0. (n = 0 is legitimate: 44 clients have no client-level primary.)
--
-- 3. POSITIVE CONTROL, rolled back - the flag must actually FOLLOW the pointer, or clause 1 is
--    only telling us the column exists:
--      begin;
--      update public.clients set primary_contact_ref = 'jobber:' ||
--        (select id from public.client_jobber_contacts where client_id=381)::text where id=381;
--      select (select count(*) from client.jobber_contacts  where client_id=381 and is_primary) as jobber_MUST_BE_1,
--             (select count(*) from client.client_contacts where client_id=381 and is_primary) as ours_MUST_BE_0;
--      rollback;
--
-- 4. A DANGLING POINTER MUST DEGRADE TO NOBODY, not to an error or a wrong badge:
--      begin;
--      update public.clients set primary_contact_ref='jobber:99999999' where id=381;
--      select (select count(*) from client.client_contacts where client_id=381 and is_primary)
--           + (select count(*) from client.jobber_contacts where client_id=381 and is_primary) as total_MUST_BE_0;
--      rollback;
-- ============================================================================================
