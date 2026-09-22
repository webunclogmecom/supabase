-- 2026-09-22_1204_client_contact_views_append.sql
--
-- Step 4 of the Contacts Role + Communication build (the views half).
-- Plan: Building Apps/Client App/docs/2026-09-22_contacts-implementation-plan.md §2.4.
--
-- Exposes the two new columns and the configured communication set to the app, so one
-- `select *` per table gives the whole Contacts list with role, role_other and the full checkbox
-- state per card, including which location a City Report is scoped to.
--
-- 🛑 APPEND ONLY, AND THAT IS WHAT MAKES IT SAFE TO SHIP AHEAD OF THE APP. `is_primary` is the
-- LAST column on both views today (ordinal 13 on client.client_contacts, 14 on
-- client.jobber_contacts, measured), so the three new columns land after every column the live
-- bundle reads and no existing ordinal moves. The published app selects named columns, so the
-- additions are inert to it.
--
-- 🛑 THE BODIES BELOW ARE COPIED FROM `pg_get_viewdef`, NOT RETYPED. `CREATE OR REPLACE VIEW`
-- takes the ENTIRE definition, so "I appended three columns" and "I rewrote the view from memory"
-- produce migrations that look identical and everything not reproduced is silently deleted. The
-- md5 of each pre-change body is pinned in the guard below and asserted before anything is
-- replaced, so a body that has moved under us fails loudly here instead of being overwritten.
--   client.client_contacts  md5 0124723a998093cd07e52fbd488bf2a0  (652 bytes)
--   client.jobber_contacts  md5 ce6e6f5f7ea606101084e7be9a390835  (550 bytes)
--
-- 🛑 WHY A LATERAL OVER THE TABLE IS SAFE HERE, WHEN A FUNCTION WOULD NOT BE.
-- `public.client_communication_prefs` is revoked from anon and authenticated. These two views are
-- owned by postgres with `reloptions = NULL`, i.e. NOT security_invoker, so they run with the
-- OWNER's privileges and the table grant is laundered exactly as it already is for
-- `public.client_contacts` itself. That laundering applies to a TABLE read. It does NOT apply to a
-- SECURITY INVOKER FUNCTION called inside a view body, which is privilege-checked against the
-- CALLER - the trap that `client.fn_derm_recipient(s)` has to be made SECURITY DEFINER for in
-- 2026-09-22_1200. A LATERAL over the table is the safe shape; a helper function would not be.
--
-- `communication` is `[]` rather than NULL for a contact with nothing ticked, so the app can
-- render the "Receives nothing" placeholder from a shape that is always an array.

begin;

do $guard$
declare
  v_md5 text;
begin
  select md5(pg_get_viewdef('client.client_contacts'::regclass, true)) into v_md5;
  if v_md5 <> '0124723a998093cd07e52fbd488bf2a0' then
    raise exception 'client.client_contacts has changed since this migration was written (md5 %). Re-derive the body from pg_get_viewdef instead of applying this.', v_md5;
  end if;
  select md5(pg_get_viewdef('client.jobber_contacts'::regclass, true)) into v_md5;
  if v_md5 <> 'ce6e6f5f7ea606101084e7be9a390835' then
    raise exception 'client.jobber_contacts has changed since this migration was written (md5 %). Re-derive the body from pg_get_viewdef instead of applying this.', v_md5;
  end if;
end $guard$;

create or replace view client.client_contacts as
 SELECT cc.id,
    cc.client_id,
    cc.property_id,
    cc.contact_role,
    cc.name,
    cc.first_name,
    cc.last_name,
    COALESCE(NULLIF(btrim(concat_ws(' '::text, cc.first_name, cc.last_name)), ''::text), cc.name) AS display_name,
    cc.email,
    cc.phone,
    cc.created_at,
    cc.updated_at,
        CASE
            WHEN COALESCE(cl.primary_contact_ref, 'client_record'::text) = 'client_record'::text THEN cc.property_id IS NULL AND cc.contact_role = 'primary'::text
            ELSE cl.primary_contact_ref = ('ours:'::text || cc.id::text)
        END AS is_primary,
    cc.person_role,
    cc.person_role_other,
    COALESCE(cp.types, '[]'::jsonb) AS communication
   FROM client_contacts cc
     JOIN clients cl ON cl.id = cc.client_id
     LEFT JOIN LATERAL (
       SELECT jsonb_agg(jsonb_build_object('type', p.comm_type, 'property_id', p.property_id)
                        ORDER BY p.comm_type, p.property_id) AS types
         FROM public.client_communication_prefs p
        WHERE p.contact_id = cc.id) cp ON true;

create or replace view client.jobber_contacts as
 SELECT jc.id,
    jc.client_id,
    jc.jobber_contact_id,
    jc.first_name,
    jc.last_name,
    COALESCE(NULLIF(btrim(jc.name), ''::text), NULLIF(btrim(concat_ws(' '::text, jc.first_name, jc.last_name)), ''::text)) AS display_name,
    jc.jobber_role,
    jc.title,
    jc.is_billing_contact,
    jc.email,
    jc.phone,
    jc.property_gids,
    jc.synced_at,
    cl.primary_contact_ref = ('jobber:'::text || jc.id::text) AS is_primary,
    jc.person_role,
    jc.person_role_other,
    COALESCE(cp.types, '[]'::jsonb) AS communication
   FROM client_jobber_contacts jc
     JOIN clients cl ON cl.id = jc.client_id
     LEFT JOIN LATERAL (
       SELECT jsonb_agg(jsonb_build_object('type', p.comm_type, 'property_id', p.property_id)
                        ORDER BY p.comm_type, p.property_id) AS types
         FROM public.client_communication_prefs p
        WHERE p.jobber_contact_id = jc.id) cp ON true
  WHERE jc.deleted_at IS NULL;

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; rehearsed rolled-back first, then re-run against the applied views)
--
-- 1. ORDINALS. is_primary must still be 13 / 14, with the three new columns AFTER it. A
--    CREATE OR REPLACE that silently rebuilt the select list shows here and nowhere else.
--
-- 2. 🛑 RE-RUN THE PRIMARY-POINTER INVARIANT FROM 2026-09-21_1830, because that expression was
--    retyped into this file and a typo in it would be invisible to an ordinal check:
--      a. is_primary must be unchanged on ALL clients (compare against a snapshot taken in the
--         same transaction from the pre-change definition)
--      b. no client may hold two primaries across the two views
--
-- 3. TRANSPORT. The catalogue cannot see PostgREST. With a staff session on a client pinned to
--    the `client` schema:
--      GET /rest/v1/client_contacts?client_id=eq.381&select=id,communication,person_role,is_primary
--      -> 200, two rows, communication = []
--    MUTATION: point the same read at schema 'public' -> must fail PGRST106/205.
--
-- 4. PRIVILEGE. The prefs table stays unreachable directly while the view reads it:
--      set local role authenticated;
--      select count(*) from client.client_contacts;              -- must succeed
--      select count(*) from public.client_communication_prefs;   -- must raise 42501
--    🛑 Run it as `authenticated`, not as postgres: this migration runs as the owner and will
--    look clean either way.
-- ============================================================================================
