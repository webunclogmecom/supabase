-- ============================================================================
-- 2026-07-30_0539 — Add Contact (Client App wave 2): per-property contacts
--                   + split first/last names + the create RPC
-- ============================================================================
-- ASK (Fred, 2026-07-30, verbatim): "we need to go with the `Add Contact`
-- functionality, in here we just need the Phone, Email, to select the property for
-- the contact, and the Name, Last Name, and Role, from all of these the required are:
-- Name Property Selection, and either Phone Number or Email."
--
-- That one sentence settles two schema questions that had been put to Fred as open:
-- "Name, Last Name" = two name fields, and "select the property for the contact" =
-- contacts are per-PROPERTY, not merely per-client. This migration implements both.
--
-- ---------------------------------------------------------------------------
-- 🛑 THE BLOCKER: the feature is IMPOSSIBLE on today's schema, and it fails on
--    the very first realistic use rather than in some edge case
-- ---------------------------------------------------------------------------
-- public.client_contacts carries  UNIQUE (client_id, contact_role)  and has NO
-- property_id column at all. Measured now:
--
--   573 rows · 397 distinct clients · 0 rows with neither email nor phone
--   contact_role vocabulary is exactly THREE values: primary 395, accounting 156, city 22
--   contacts per client: 1 -> 243 clients, 2 -> 132, 3 -> 22  (max 3, never 4)
--
-- The max of 3 is not a coincidence: with three roles and a UNIQUE on
-- (client_id, contact_role), the role vocabulary IS the uniqueness. 395 of 397
-- clients already hold a `primary`. So "add a contact, pick a property, pick a role"
-- 23505s the moment anyone adds a second `primary` for a different property, which
-- is precisely the multi-property case the feature exists to serve.
--
-- ---------------------------------------------------------------------------
-- WHY `UNIQUE NULLS NOT DISTINCT` AND NOT JUST DROPPING THE CONSTRAINT
-- ---------------------------------------------------------------------------
-- Postgres treats NULLs as DISTINCT in a UNIQUE index by default, so a plain
-- UNIQUE (client_id, property_id, contact_role) would allow UNLIMITED duplicate
-- client-level rows (property_id IS NULL) -- silently destroying the one-primary-per-
-- client guarantee that webhook-jobber's upsert relies on for all 573 existing rows.
-- Prod is PG 17 (server_version_num 170006), so NULLS NOT DISTINCT is available and
-- treats the NULL property as a real value. Net effect:
--   * client-level (property_id IS NULL) -> still exactly one row per role  (unchanged)
--   * per-property                       -> one row per role per property   (new)
--
-- ---------------------------------------------------------------------------
-- ⚠ CALLER THAT MUST CHANGE IN THE SAME CYCLE (else the Jobber client sync breaks)
-- ---------------------------------------------------------------------------
-- supabase/functions/webhook-jobber/index.ts:438
--     .upsert(contactRow, { onConflict: 'client_id,contact_role' })
-- PostgREST's onConflict must name a column set backed by a real unique constraint or
-- the request fails 42P10. Dropping the 2-col constraint therefore breaks EVERY Jobber
-- CLIENT_CREATE/CLIENT_UPDATE contact upsert -- and because the Jobber feed is
-- poll-replayed, it would fail repeatedly rather than once. The function is updated to
-- onConflict 'client_id,property_id,contact_role' and to send property_id: null
-- explicitly in the same commit as this migration.
--
-- ---------------------------------------------------------------------------
-- ⚠ DO NOT BACKFILL first_name/last_name BY SPLITTING `name`. IT IS NOT A PERSON.
-- ---------------------------------------------------------------------------
-- webhook-jobber:432 writes `name: name` where that variable is the CLIENT's name --
-- the BUSINESS name. So for the 395 Jobber-synced `primary` rows, client_contacts.name
-- holds values like "1100 Millecento Residences Condominium Association", not a human
-- name. Splitting those on the last space would manufacture 395 fake people
-- ("first_name = 1100 Millecento Residences Condominium", "last_name = Association").
-- first_name/last_name are therefore left NULL for existing rows and populated only for
-- contacts created through the new RPC. Display resolves with a COALESCE so both shapes
-- render correctly (see client.client_contacts view below).
--
-- ---------------------------------------------------------------------------
-- AUDIT (ADR 010): OPT-IN. This is a NEW opt-in decision, not an inherited one.
-- ---------------------------------------------------------------------------
-- public.client_contacts carries ZERO audit triggers today (measured: 0 rows from the
-- audit.log_change trigger sweep; its only trigger is trg_client_contacts_updated_at).
-- ADR 010 makes opt-in the DEFAULT for tables with human-editable fields, and this table
-- is about to get a human write path for the first time. It also holds contact PII
-- (542 emails, 301 phones), and ADR 010's hard rule is that nothing touching PII skips
-- audit. Opting in.
--
-- ---------------------------------------------------------------------------
-- ⚠ SIDE EFFECT ON A CLIENT-FACING EMAIL PATH -- read before adding contacts
-- ---------------------------------------------------------------------------
-- supabase/functions/send-derm-email/index.ts:436-443 picks the DERM recipient with:
--     .from('client_contacts').select('email').eq('client_id', clientId)
--     .not('email','is',null).neq('email','').limit(1).maybeSingle()
-- There is NO .order(), so with more than one emailed contact the choice is
-- ARBITRARY (unspecified row order), and this migration makes multi-contact clients
-- the normal case rather than the exception. Left unaddressed, adding a per-property
-- contact could silently redirect a client's DERM manifest email. That is a
-- client-facing misdelivery risk introduced BY this change, so the function is made
-- DETERMINISTIC in the same commit (prefer the client-level `primary`), which is
-- strictly a narrowing of today's arbitrary behaviour.
--
-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
--   drop function if exists client.create_client_contact(bigint, jsonb);
--   drop trigger if exists audit_client_contacts on public.client_contacts;
--   alter table public.client_contacts
--     drop constraint client_contacts_client_property_role_key,
--     add constraint client_contacts_client_id_contact_role_key unique (client_id, contact_role),
--     drop column property_id, drop column first_name, drop column last_name;
--   (then revert webhook-jobber + send-derm-email and redeploy)
-- Rollback is only safe while no per-property contact exists; once two rows share
-- (client_id, contact_role) the 2-col constraint cannot be recreated.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.client_contacts
  add column if not exists property_id bigint,
  add column if not exists first_name  text,
  add column if not exists last_name   text;

-- ON DELETE CASCADE mirrors the existing client_id FK on this same table.
-- Deliberately NOT "set null": that would silently demote a property contact to a
-- client-level one and could then collide with the existing client-level row for the
-- same role, turning a property delete into an opaque 23505.
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'client_contacts_property_id_fkey') then
    alter table public.client_contacts
      add constraint client_contacts_property_id_fkey
      foreign key (property_id) references public.properties(id) on delete cascade;
  end if;
end $$;

create index if not exists client_contacts_property_id_idx
  on public.client_contacts (property_id);

comment on column public.client_contacts.property_id is
  'Optional property this contact belongs to. NULL = client-level (all Jobber-synced '
  'rows are client-level). The Client App Add Contact form REQUIRES a property; the '
  'column stays nullable for the 573 pre-existing rows and for the Jobber sync.';
comment on column public.client_contacts.first_name is
  'Person given name. NULL on pre-2026-07-30 rows: `name` holds the BUSINESS name for '
  'Jobber-synced contacts, so it was deliberately not split. Never backfill by splitting.';
comment on column public.client_contacts.last_name is
  'Person family name. See first_name -- deliberately NULL on pre-existing rows.';

-- ---------------------------------------------------------------------------
-- 2. The unique key
-- ---------------------------------------------------------------------------
alter table public.client_contacts
  drop constraint if exists client_contacts_client_id_contact_role_key;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'client_contacts_client_property_role_key') then
    alter table public.client_contacts
      add constraint client_contacts_client_property_role_key
      unique nulls not distinct (client_id, property_id, contact_role);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Audit opt-in (ADR 010)
-- ---------------------------------------------------------------------------
drop trigger if exists audit_client_contacts on public.client_contacts;
create trigger audit_client_contacts
  after insert or update or delete on public.client_contacts
  for each row execute function audit.log_change();

-- ---------------------------------------------------------------------------
-- 4. Expose the new columns to the app + a resolved display name
-- ---------------------------------------------------------------------------
-- display_name exists so the UI never has to decide between the person-name and
-- business-name shapes. It is COMPUTED ON READ (3NF rule 2: it depends on other
-- columns in the same row, so it is not stored).
--
-- ⚠ DROP + CREATE, not CREATE OR REPLACE. `CREATE OR REPLACE VIEW` can only APPEND
-- columns; it cannot insert one mid-list, and this definition puts property_id third
-- (renaming the existing column 3 from contact_role), which errors with
-- "cannot change name of view column". Verified safe to drop: pg_depend reports ZERO
-- dependent views/functions on client.client_contacts.
--
-- ⚠ AND A DROP SILENTLY LOSES THE GRANTS. Measured before dropping, the view is
-- granted SELECT to BOTH `authenticated` AND `service_role`. Re-granting only
-- `authenticated` would quietly break any service_role reader, so both are restored
-- below. (anon holds nothing and must keep holding nothing.)
drop view if exists client.client_contacts;

create view client.client_contacts as
  select id,
         client_id,
         property_id,
         contact_role,
         name,
         first_name,
         last_name,
         coalesce(
           nullif(btrim(concat_ws(' ', first_name, last_name)), ''),
           name
         ) as display_name,
         email,
         phone,
         created_at,
         updated_at
  from public.client_contacts;

alter view client.client_contacts owner to postgres;
revoke all on client.client_contacts from anon;
grant select on client.client_contacts to authenticated;
grant select on client.client_contacts to service_role;

-- ---------------------------------------------------------------------------
-- 5. The create RPC
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER + pinned empty search_path, matching the wave-1 RPCs. The
-- client.* views are postgres-owned WITHOUT security_invoker, so they bypass RLS;
-- granting one INSERT would be an unrestricted write across all 439 clients. Standing
-- rule: no client.* view is ever granted DML.
create or replace function client.create_client_contact(
  p_client_id bigint,
  p_patch     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_allowed  text[] := array['property_id','first_name','last_name','contact_role','email','phone'];
  v_roles    text[] := array['primary','accounting','city'];
  v_bad      text[];
  v_first    text;
  v_last     text;
  v_role     text;
  v_email    text;
  v_phone    text;
  v_prop     bigint;
  v_name     text;
  v_row      public.client_contacts;
begin
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated`
  -- token with no `sub` claim would otherwise pass. Mirrors public.set_visit_status.
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % does not exist', p_client_id using errcode = '23503';
  end if;

  v_first := nullif(btrim(coalesce(p_patch->>'first_name','')), '');
  v_last  := nullif(btrim(coalesce(p_patch->>'last_name','')),  '');
  v_email := nullif(btrim(coalesce(p_patch->>'email','')),      '');
  v_phone := nullif(btrim(coalesce(p_patch->>'phone','')),      '');
  v_role  := lower(nullif(btrim(coalesce(p_patch->>'contact_role','')), ''));

  -- Guarded cast: a bare ::bigint on junk raises 22P02 ("invalid input syntax for
  -- type bigint"), which surfaces in the UI as an unreadable Postgres string. The
  -- error mapper only passes through the codes it knows, so give it a 22023.
  declare v_prop_txt text := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
  begin
    if v_prop_txt is not null then
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
    end if;
  end;

  -- Fred's required set: Name, Property, and either Phone or Email.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_prop is null then
    raise exception 'A property must be selected for the contact.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.'
      using errcode = '22023';
  end if;

  -- The property must belong to THIS client. Without this check the RPC would happily
  -- attach a contact to another client's property -- the same cross-client hole the
  -- wave-1 review caught on gdos.property_id.
  if not exists (select 1 from public.properties p
                 where p.id = v_prop and p.client_id = p_client_id) then
    raise exception 'Property % does not belong to client %', v_prop, p_client_id
      using errcode = '22023';
  end if;

  -- contact_role is NOT NULL on the table; default to the app's own default.
  v_role := coalesce(v_role, 'primary');
  if v_role <> all (v_roles) then
    raise exception 'contact_role must be one of %', v_roles using errcode = '22023';
  end if;

  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- `name` stays the display value every existing reader already uses
  -- (send-derm-email, the app list). Composed here, never stored redundantly split.
  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    insert into public.client_contacts
      (client_id, property_id, contact_role, name, first_name, last_name, email, phone)
    values
      (p_client_id, v_prop, v_role, v_name, v_first, v_last, v_email, v_phone)
    returning * into v_row;
  exception when unique_violation then
    raise exception 'This property already has a % contact. Edit that contact instead of adding a second one.',
      v_role using errcode = '23505';
  end;

  return to_jsonb(v_row);
end
$fn$;

-- New functions in `client` are born EXECUTE-to-PUBLIC (Supabase default privileges),
-- and revoking from PUBLIC alone does not strip anon/service_role. Revoke explicitly.
revoke all on function client.create_client_contact(bigint, jsonb) from public;
revoke all on function client.create_client_contact(bigint, jsonb) from anon;
grant execute on function client.create_client_contact(bigint, jsonb) to authenticated;

commit;
