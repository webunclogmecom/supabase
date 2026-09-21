-- 2026-09-21_1530_client_jobber_contacts.sql
--
-- A HOME FOR JOBBER'S REAL CONTACTS, which this estate has never read.
--
-- WHAT WAS MISSING. `public.client_contacts` holds three different kinds of row and NONE of
-- them is a Jobber contact: (a) 429 client-level `primary` rows that webhook-jobber SYNTHESISES
-- from the Jobber CLIENT record, (b) 176 accounting/city rows we invented that never reach
-- Jobber, (c) 2 property-scoped primaries. Meanwhile a Jobber Client carries a first-class
-- `contacts: ContactModelConnection` whose ContactModel has firstName, lastName, role (free
-- String), title, isBillingContact, its own emails, its own phones and its own properties -
-- a counterpart for every field the Client App could not edit. Zero code here referenced it.
-- 112-YA has held ContactModel/135562 "Mr. Yannick ayache" (role QUOTE/INVOICE) the whole time,
-- invisible in the app.
--
-- WHY A SEPARATE TABLE AND NOT MORE COLUMNS ON client_contacts. The mirror upsert in
-- webhook-jobber is a PostgREST upsert with `onConflict 'client_id,property_id,contact_role'`,
-- and PostgREST emits `ON CONFLICT (cols)` with NO predicate, which cannot match a PARTIAL
-- index. So the moment that unique constraint is narrowed to make room for several Jobber
-- contacts per client, every poll raises 42P10, forever, on a feed that replays ~400 times a
-- day. A separate table means **webhook-jobber is not edited at all**: the poll cannot see,
-- revert, duplicate or orphan a single row in here. That is structural, not careful.
--
-- SIZE. Measured across all 490 Jobber clients: 432 have ZERO contacts, 51 have one, 6 have
-- two, 1 has three. This is ~66 rows, not hundreds.
--
-- NOT DONE HERE, on purpose: no change to client_contacts, no change to its unique constraint,
-- no change to the three client.*_client_contact RPCs, no change to the five ops.* views, and
-- NO new entity type in entity_source_links - the Jobber id lives on the row itself, so the
-- link cannot orphan and the poll's hot path gains no join.

begin;

create table public.client_jobber_contacts (
  id                 bigint generated always as identity primary key,
  client_id          bigint      not null references public.clients(id) on delete cascade,

  -- Jobber's ContactModel id, base64 EncodedId. Immutable and globally unique: one
  -- ContactModel belongs to exactly one Jobber client, so this is the upsert arbiter.
  jobber_contact_id  text        not null unique,

  first_name         text,
  last_name          text,
  name               text,        -- Jobber's own rendered name, e.g. "Mr. Yannick ayache"
  jobber_role        text,        -- 🛑 a FREE STRING in Jobber ("QUOTE/INVOICE"), never an enum.
                                  -- Deliberately NOT called contact_role: it shares no
                                  -- vocabulary with client_contacts.contact_role and must never
                                  -- be fed to anything that ranks that column.
  title              text,        -- ClientTitle enum on Jobber's side
  is_billing_contact boolean,
  email              text,        -- the contact's OWN primary email, not the client's
  phone              text,        -- the contact's OWN primary phone
  property_gids      text[],      -- Jobber Property EncodedIds this contact is attached to

  -- soft delete only, per the standing rule. Set when Jobber no longer returns the contact,
  -- and cleared again on re-appearance by the upsert.
  deleted_at         timestamptz,
  synced_at          timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table  public.client_jobber_contacts is
  'Jobber ContactModel people, mirrored read-through when a client page opens. NOT the same '
  'thing as public.client_contacts, which holds the synthesised client-record mirror plus our '
  'own accounting/city rows. Nothing in the DERM or ops path reads this table: '
  'client.fn_derm_recipient cannot see it, so a Jobber contact never receives a manifest '
  'unless a human promotes them.';
comment on column public.client_jobber_contacts.jobber_contact_id is
  'Jobber ContactModel EncodedId. The upsert arbiter; immutable.';
comment on column public.client_jobber_contacts.jobber_role is
  'Jobber''s free-text role string. NOT client_contacts.contact_role and not ranked anywhere.';

create index client_jobber_contacts_client_live_idx
  on public.client_jobber_contacts (client_id)
  where deleted_at is null;

create trigger set_updated_at
  before update on public.client_jobber_contacts
  for each row execute function public.set_updated_at();

create trigger audit_client_jobber_contacts
  after insert or update or delete on public.client_jobber_contacts
  for each row execute function audit.log_change();

-- RLS: staff read only. Every write goes through save-client-contact as service_role, which
-- bypasses RLS, so there is deliberately NO insert/update/delete policy for anyone.
alter table public.client_jobber_contacts enable row level security;

create policy client_jobber_contacts_select_authenticated
  on public.client_jobber_contacts for select to authenticated using (true);

-- ⚠ do NOT copy client_contacts' dead anon policy. anon gets nothing, grant or policy.
--
-- 🛑 REVOKE FIRST, AND FROM `authenticated` TOO, NOT JUST anon. A bare
-- `grant select ... to authenticated` LOOKS like it grants only SELECT; it does not take
-- anything away. Supabase's ALTER DEFAULT PRIVILEGES hands `authenticated` the full set on a
-- newly created public table, so INSERT/UPDATE/DELETE are already there. Measured on the
-- rolled-back probe of this very migration: with only the anon revoke,
-- has_table_privilege('authenticated', ..., 'insert') came back TRUE.
-- RLS would still have refused the write (there is no insert policy), but a grant and a policy
-- disagreeing is precisely the shape this estate has been bitten by before - never let the
-- policy be the only thing holding the line.
revoke all on public.client_jobber_contacts from anon;
revoke all on public.client_jobber_contacts from authenticated;
grant select on public.client_jobber_contacts to authenticated;
grant all    on public.client_jobber_contacts to service_role;

commit;

-- ============================================================================================
-- VERIFY (catalogue assertions; the table has zero rows, zero readers and zero writers here)
--
--   select
--     (select count(*) from public.client_jobber_contacts)                                as rows_MUST_BE_0,
--     (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
--       where c.relname='client_jobber_contacts' and not t.tgisinternal)                  as triggers_MUST_BE_2,
--     (select relrowsecurity from pg_class where oid='public.client_jobber_contacts'::regclass)
--                                                                                          as rls_MUST_BE_TRUE,
--     has_table_privilege('anon','public.client_jobber_contacts','select')                 as anon_MUST_BE_FALSE,
--     has_table_privilege('authenticated','public.client_jobber_contacts','select')        as auth_MUST_BE_TRUE,
--     has_table_privilege('authenticated','public.client_jobber_contacts','insert')        as auth_insert_MUST_BE_FALSE;
--
-- POSITIVE CONTROL for the privilege probe: the same three has_table_privilege calls against
-- public.client_contacts must return true/true/true, or the instrument is not reading anything.
-- ============================================================================================
