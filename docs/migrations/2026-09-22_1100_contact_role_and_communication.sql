-- 2026-09-22_1100_contact_role_and_communication.sql
--
-- Step 2 of the Contacts Role + Communication build.
-- Plan: Building Apps/Client App/docs/2026-09-22_contacts-implementation-plan.md §2.3, §2.6, §2.7.
--
-- WHY. Fred, 2026-09-22, describing the contact modal he wants: a Role dropdown
-- ("Store Manager, Accounting, Owner, or Other"), then a Communication section with
-- checkboxes "Invoice, Quote Approval, Service Report, City Report". Invoice is one per
-- client; Service Report may go to several people; City Report is one per LOCATION
-- ("when we send an email to the city we need to send a notification to the person letting
-- them know we did so"). Reporting Issue and Emergency contact are deliberately out for now.
-- Fred also fixed who owns the configuration: *"we want the configuration for that to be our
-- part, like we select the data (emails/phones) that will get all that even if it's sent by
-- jobber or by our own emailing system"*.
--
-- 🛑 WHAT THIS IS NOT. Ticking a box writes NOTHING to Jobber. Measured 2026-09-22 on 112-YA:
-- starring fred@ayache.com via clientEdit left the Send window still prefilling
-- serena@unclogme.com, and adding an isBillingContact changed nothing either. `Client.defaultEmails`
-- is Jobber's memory of previous sends and only a real send rewrites it. So for OUR senders
-- (Service Report, the city manifest, the city photos email) this table IS the rule; for Jobber's
-- own quote and invoice originals it is a RECORD plus a drift check. Any UI copy stronger than
-- that is a promise Jobber cannot keep.
--
-- ============================================================================================
-- 🛑 WHY A JUNCTION TABLE AND NOT text[] COLUMNS, because this is the decision to not re-litigate
--
--   * The two cardinality rules become PARTIAL UNIQUE INDEXES, which are correct under
--     concurrency. A BEFORE trigger doing `count(*) > 0` lets two concurrent transactions each
--     see zero and both commit.
--   * Invoice must be one per client ACROSS BOTH contact tables (ours and the Jobber mirror).
--     One table holding both foreign keys makes "across both" STRUCTURAL rather than a trigger
--     that races. A per-table trigger would pass the obvious test and fail the real one - see
--     control B in the VERIFY block, which is the whole reason that control exists.
--   * City Report's property scope is independent of the contact's own `property_id`, which a
--     column on the contact cannot express at all.
--
-- 🛑 WHY `person_role` AND NOT `role` OR `contact_role`
--   `contact_role` is the ON CONFLICT target of webhook-jobber's mirror upsert
--   (`(client_id, property_id, contact_role)`), so reusing it would mint a second mirror row on
--   the next poll - measured reaction ~20 seconds. `jobber_role` is Jobber's own free string on
--   ContactModel. `person_role` collides with neither.
--
-- 🛑 WHY THE NEW TABLE IS REVOKED FROM authenticated AND WHAT THAT COSTS LATER
--   A SECURITY INVOKER function called INSIDE A VIEW BODY is privilege-checked against the
--   CALLER, not the view owner. Proven on a throwaway _probe schema, both directions. So when
--   `client.fn_derm_recipient(s)` starts reading this table (migration 2026-09-22_1200) it MUST
--   become SECURITY DEFINER with a pinned search_path, or every authenticated SELECT on
--   `derm.visits` and `derm.manifest_recipients` raises 42501 and the DERM Tracker goes dark
--   estate-wide WHILE SENDS KEEP WORKING (service_role has rolbypassrls). Mail fine, app dead.
--   That is a note for the NEXT migration; this one only creates the revoked table.
--
-- RULE 8 (audit-trail standing check): `client_communication_prefs` OPTS IN. It is a
-- human-editable configuration table that decides who receives compliance email, so it is
-- exactly the class the rule says must not skip audit.
--
-- ADDITIVE ONLY. No existing column, view or app read changes, which is why this goes first:
-- `/clients/381` must render identically after it. The two RPC edits at the end are a narrowing
-- of a vocabulary whose third value no longer exists in the data (step 1 deleted all 21 rows).
-- ============================================================================================

begin;

-- ---------------------------------------------------------------- 1. person role
alter table public.client_contacts
  add column person_role       text,
  add column person_role_other text;
alter table public.client_jobber_contacts
  add column person_role       text,
  add column person_role_other text;

comment on column public.client_contacts.person_role is
  'What this person DOES (store_manager|accounting|owner|other). NULL = nobody has set it. '
  'Not contact_role, which is the poll''s ON CONFLICT target and must never be repurposed.';
comment on column public.client_jobber_contacts.person_role is
  'What this person DOES (store_manager|accounting|owner|other). NULL = nobody has set it. '
  'Not jobber_role, which is Jobber''s own free string on ContactModel.';

alter table public.client_contacts
  add constraint client_contacts_person_role_chk check (
    (person_role is null and person_role_other is null)
    or (person_role in ('store_manager','accounting','owner') and person_role_other is null)
    or (person_role = 'other' and nullif(btrim(person_role_other),'') is not null));
alter table public.client_jobber_contacts
  add constraint client_jobber_contacts_person_role_chk check (
    (person_role is null and person_role_other is null)
    or (person_role in ('store_manager','accounting','owner') and person_role_other is null)
    or (person_role = 'other' and nullif(btrim(person_role_other),'') is not null));
-- NULL means "nobody has set it", which is exactly what the dropdown placeholder shows.
-- NO DEFAULT: a default would be a lie on the 586 existing rows.
-- The CHECK is duplicated per table on purpose. Two tables, two CHECKs, no shared domain type
-- for somebody to change on one side only.

-- ------------------------------------------------------- 2. communication prefs
create table public.client_communication_prefs (
  id                bigint generated always as identity primary key,
  client_id         bigint not null references public.clients(id)               on delete cascade,
  comm_type         text   not null,
  contact_id        bigint references public.client_contacts(id)                on delete cascade,
  jobber_contact_id bigint references public.client_jobber_contacts(id)         on delete cascade,
  property_id       bigint references public.properties(id)                     on delete cascade,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint client_comm_type_chk
    check (comm_type in ('invoice','quote_approval','service_report','city_report')),
  -- exactly one contact, from exactly one of the two tables
  constraint client_comm_one_target_chk
    check (num_nonnulls(contact_id, jobber_contact_id) = 1),
  -- City Report is per location; the other three are per client. Both directions, so neither
  -- "a city_report with no location" nor "an invoice pinned to one location" can be stored.
  constraint client_comm_scope_chk
    check ((comm_type = 'city_report') = (property_id is not null))
);

comment on table public.client_communication_prefs is
  'WHO receives WHAT, configured by us. One row per (contact, communication) and, for '
  'city_report, per location. Written ONLY by client.save_contact_settings. Revoked from '
  'anon and authenticated: the app reads it through the owner-run client.* views and the DERM '
  'path through a SECURITY DEFINER function. Ticking a box writes nothing to Jobber.';

-- ponytail: client_id is denormalised and the single SECDEF writer derives it from the contact
-- row. If a second writer ever appears, add composite FKs (contact_id, client_id) ->
-- client_contacts(id, client_id) so the denormalised column cannot drift.

-- 🛑 INVOICE: ONE PER CLIENT, ACROSS BOTH CONTACT TABLES. The index does not care which table
-- the contact came from, which is what makes "across both" structural instead of a trigger.
create unique index client_comm_one_invoice_per_client
  on public.client_communication_prefs (client_id) where comm_type = 'invoice';

-- 🛑 CITY REPORT: ONE PER LOCATION. property_id is NOT NULL for this type by
-- client_comm_scope_chk, so no NULLS clause is needed here.
create unique index client_comm_one_city_report_per_property
  on public.client_communication_prefs (property_id) where comm_type = 'city_report';

-- the same person cannot hold the same communication twice
create unique index client_comm_no_dup_ours
  on public.client_communication_prefs (comm_type, property_id, contact_id)
  nulls not distinct where contact_id is not null;
create unique index client_comm_no_dup_jobber
  on public.client_communication_prefs (comm_type, property_id, jobber_contact_id)
  nulls not distinct where jobber_contact_id is not null;

create index client_comm_client_type_idx
  on public.client_communication_prefs (client_id, comm_type);

-- Quote Approval and Service Report get NO cardinality index. Fred: several people allowed.

create trigger set_updated_at before update on public.client_communication_prefs
  for each row execute function public.set_updated_at();
create trigger audit_client_communication_prefs
  after insert or delete or update on public.client_communication_prefs
  for each row execute function audit.log_change();

alter table public.client_communication_prefs enable row level security;   -- no policies
revoke all on public.client_communication_prefs from anon, authenticated;

-- ----------------------------------------------- 3. seed for NEW mirror rows only
create or replace function public.fn_seed_client_communication()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  -- 🛑 THE TRIGGER PREDICATE IS THE POINT. Only the client-record mirror row that
  -- webhook-jobber synthesises gets the default set. A column DEFAULT would tick these boxes
  -- on every accounting row client.create_client_contact inserts, which is why the VERIFY
  -- below asserts the accounting case produces ZERO prefs - without that second assertion the
  -- first one passes under either design.
  insert into public.client_communication_prefs (client_id, comm_type, contact_id)
  select new.client_id, t, new.id
    from unnest(array['invoice','quote_approval','service_report']) t
  on conflict do nothing;   -- a client that already has an Invoice contact keeps it
  return null;
end $$;

create trigger trg_seed_client_communication
  after insert on public.client_contacts
  for each row
  when (new.property_id is null and new.contact_role = 'primary')
  execute function public.fn_seed_client_communication();
-- AFTER INSERT, not BEFORE: Postgres fires BEFORE INSERT even when an upsert ends up UPDATING,
-- so a BEFORE trigger would re-seed on every poll replay. AFTER INSERT fires only for rows
-- actually inserted, so webhook-jobber's upsert on an existing client fires nothing.
-- City Report is deliberately NOT seeded: nobody has ever configured one.

-- ------------------------------------------------------------ 4. the writer
create or replace function client.save_contact_settings(
  p_source     text,    -- 'ours' | 'jobber'
  p_contact_id bigint,
  p_patch      jsonb    -- {person_role, person_role_other, communication:[{type, property_id}]}
) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  v_allowed text[] := array['person_role','person_role_other','communication'];
  v_types   text[] := array['invoice','quote_approval','service_report','city_report'];
  v_bad text[]; v_client bigint; v_email text; v_label text; v_deleted timestamptz;
  v_role text; v_other text; v_comm jsonb; v_item jsonb; v_t text;
  v_prop bigint; v_prop_txt text; v_holder text; v_out jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_source is null or p_source <> all (array['ours','jobber']) then
    raise exception 'p_source must be ''ours'' or ''jobber''.' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object.' using errcode = '22023';
  end if;
  select array_agg(k) into v_bad from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s): %. Allowed: %', v_bad, v_allowed using errcode = '22023';
  end if;

  if p_source = 'ours' then
    select cc.client_id, cc.email,
           coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name, 'This contact'),
           cc.person_role, cc.person_role_other
      into v_client, v_email, v_label, v_role, v_other
      from public.client_contacts cc where cc.id = p_contact_id;
  else
    select jc.client_id, jc.email,
           coalesce(nullif(btrim(jc.name),''),
                    nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),''), 'This contact'),
           jc.person_role, jc.person_role_other, jc.deleted_at
      into v_client, v_email, v_label, v_role, v_other, v_deleted
      from public.client_jobber_contacts jc where jc.id = p_contact_id;
  end if;
  if v_client is null then
    raise exception 'That contact no longer exists.' using errcode = 'P0002';
  end if;
  if v_deleted is not null then
    raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023';
  end if;

  ---- role ------------------------------------------------------------------------------
  if p_patch ? 'person_role' then
    v_role := lower(nullif(btrim(coalesce(p_patch->>'person_role','')),''));
  end if;
  if p_patch ? 'person_role_other' then
    v_other := nullif(btrim(coalesce(p_patch->>'person_role_other','')),'');
  end if;
  if v_role is not null and v_role <> all (array['store_manager','accounting','owner','other']) then
    raise exception 'Unknown role "%".', v_role using errcode = '22023';
  end if;
  if v_role = 'other' and v_other is null then
    raise exception 'Say what the role is, or pick one from the list.' using errcode = '22023';
  end if;
  if v_role is distinct from 'other' then v_other := null; end if;   -- never keep stale free text

  if p_patch ? 'person_role' or p_patch ? 'person_role_other' then
    if p_source = 'ours' then
      update public.client_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    else
      update public.client_jobber_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    end if;
  end if;

  ---- communication ---------------------------------------------------------------------
  if p_patch ? 'communication' then
    v_comm := p_patch->'communication';
    if jsonb_typeof(v_comm) <> 'array' then
      raise exception 'communication must be a list.' using errcode = '22023';
    end if;

    -- replace-the-set: unticking is a delete that leaves no row behind
    delete from public.client_communication_prefs
     where (p_source = 'ours'   and contact_id        = p_contact_id)
        or (p_source = 'jobber' and jobber_contact_id = p_contact_id);

    -- 🛑 AN EMPTY EMAIL CLEARS THE SET, IT DOES NOT RAISE. The modal lets you remove an address
    -- from a contact that holds boxes, and warns that the boxes go with it. If this raised, that
    -- save would be impossible and the warning would be a lie. So the guard sits AFTER the
    -- delete and only fires when something is being TICKED.
    if coalesce(btrim(v_email),'') = '' and jsonb_array_length(v_comm) > 0 then
      raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023';
    end if;

    for v_item in select * from jsonb_array_elements(v_comm) loop
      v_t := lower(nullif(btrim(coalesce(v_item->>'type','')),''));
      if v_t is null or v_t <> all (v_types) then
        raise exception 'Unknown communication type "%".', coalesce(v_t,'') using errcode = '22023';
      end if;
      -- 🛑 the comma-bag guard, in the DATABASE and not only in the UI. Rows holding several
      -- addresses in one field exist; Resend would send to a single malformed address and
      -- report success.
      if v_email like '%,%' then
        raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023';
      end if;

      v_prop_txt := nullif(btrim(coalesce(v_item->>'property_id','')),'');
      if v_prop_txt is not null then
        if v_prop_txt !~ '^[0-9]+$' then   -- a bare ::bigint on junk raises an unreadable 22P02
          raise exception 'property_id must be a positive integer, got %', v_prop_txt using errcode = '22023';
        end if;
        v_prop := v_prop_txt::bigint;
      else
        v_prop := null;
      end if;

      if v_t = 'city_report' then
        if v_prop is null then
          raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023';
        end if;
        if not exists (select 1 from public.properties p
                        where p.id = v_prop and p.client_id = v_client and p.deleted_at is null) then
          raise exception 'That location does not belong to this client.' using errcode = '22023';
        end if;
      elsif v_prop is not null then
        raise exception 'That communication covers the whole client, not one location.' using errcode = '22023';
      end if;

      begin
        insert into public.client_communication_prefs
          (client_id, comm_type, contact_id, jobber_contact_id, property_id)
        values (v_client, v_t,
                case when p_source = 'ours'   then p_contact_id end,
                case when p_source = 'jobber' then p_contact_id end,
                v_prop);
      exception when unique_violation then
        -- 🛑 name the holder. A raw 23505 in front of a person is the error this catch exists
        -- to stop, and the sentence is the operator-message rule: plain language in MESSAGE.
        select coalesce(
          (select coalesce(nullif(btrim(concat_ws(' ', c2.first_name, c2.last_name)),''), c2.name)
             from public.client_communication_prefs q
             join public.client_contacts c2 on c2.id = q.contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          (select coalesce(nullif(btrim(j2.name),''),
                           nullif(btrim(concat_ws(' ', j2.first_name, j2.last_name)),''))
             from public.client_communication_prefs q
             join public.client_jobber_contacts j2 on j2.id = q.jobber_contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          'Another contact') into v_holder;
        if v_t = 'invoice' then
          -- 🛑 OUR RULE, NOT JOBBER'S. Never "receives", never "only one person can receive".
          raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505';
        elsif v_t = 'city_report' then
          raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505';
        else
          raise exception '% already has that ticked.', v_holder using errcode = '23505';
        end if;
      end;
    end loop;
  end if;

  if p_source = 'ours' then
    select to_jsonb(v) into v_out from client.client_contacts v where v.id = p_contact_id;
  else
    select to_jsonb(v) into v_out from client.jobber_contacts  v where v.id = p_contact_id;
  end if;
  return v_out;
end $$;

revoke all on function client.save_contact_settings(text,bigint,jsonb) from public, anon;
grant execute on function client.save_contact_settings(text,bigint,jsonb) to authenticated, service_role;

-- --------------------------------- 5. narrow the two existing RPCs, and reword the message
-- 🛑 SPLICED FROM THE LIVE DEFINITIONS, NEVER RETYPED. CREATE OR REPLACE takes the ENTIRE body,
-- so "I changed one clause" and "I rewrote it from memory" produce identical-looking migrations
-- and everything not reproduced is silently deleted. Each anchor is asserted to occur EXACTLY
-- ONCE before the substitution, so a body that has moved under us fails loudly here instead of
-- being quietly rewritten. Measured before writing this: one 'city' literal in each function,
-- one copy of the message in update_client_contact.
do $splice$
declare
  v_src text; v_new text; v_n int;
  r record;
begin
  for r in
    select oid, proname from pg_proc
     where pronamespace = 'client'::regnamespace
       and proname in ('create_client_contact','update_client_contact')
  loop
    v_src := pg_get_functiondef(r.oid);

    -- (a) the vocabulary: 'city' is retired as a contact type (step 1 deleted all 21 rows),
    --     so a human must not be able to mint a new one.
    select count(*) into v_n from regexp_matches(
      v_src, 'array\[''primary'',''accounting'',''city''\]', 'g');
    if v_n <> 1 then
      raise exception 'splice anchor (a) matched % times in client.%, expected 1', v_n, r.proname;
    end if;
    v_new := replace(v_src, 'array[''primary'',''accounting'',''city'']',
                            'array[''primary'',''accounting'']');

    -- (b) the live string that tells the user to do exactly what (a) now refuses. Only
    --     update_client_contact carries it; create_client_contact must match ZERO times, and
    --     that asymmetry is asserted rather than assumed.
    select count(*) into v_n from regexp_matches(
      v_new, 'Pick a property, or use the accounting or city role\.', 'g');
    if r.proname = 'update_client_contact' then
      if v_n <> 1 then
        raise exception 'splice anchor (b) matched % times in client.update_client_contact, expected 1', v_n;
      end if;
      v_new := replace(v_new, 'Pick a property, or use the accounting or city role.',
                              'Pick a location, or use the accounting role.');
    elsif v_n <> 0 then
      raise exception 'splice anchor (b) unexpectedly matched % times in client.%', v_n, r.proname;
    end if;

    if v_new = v_src then
      raise exception 'splice produced no change for client.%', r.proname;
    end if;
    execute v_new;
  end loop;
end $splice$;

-- Deliberately NOT done: a CHECK on client_contacts.contact_role. Five ops views join on that
-- literal and webhook-jobber writes it, so a table constraint would put a poll failure on the
-- critical path. The vocabulary is held at the RPC, which is the only human entry point.

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22 — rehearsed inside begin/rollback BEFORE applying, then re-run after)
--
-- Every constraint is paired with a case that must RAISE and a control that must SUCCEED. A
-- probe suite with only failing cases cannot tell a real constraint from one that rejects
-- everything, and one with only passing cases cannot tell a real constraint from no constraint.
--
--   constraint                              must RAISE                        control that SUCCEEDS
--   person_role vocabulary                  'ceo'                    23514    'owner'
--   person_role pairing                     'other' + null           23514    'other' + 'Head chef'
--                                           'owner' + 'x'            23514
--   client_comm_type_chk                    'reporting_issue'        23514    'service_report'
--   client_comm_one_target_chk              both null / both set     23514    exactly one set
--   client_comm_scope_chk                   city_report + no prop    23514    city_report + prop 162
--                                           invoice + a property     23514
--   client_comm_one_invoice_per_client  A   2nd invoice, other ours  23505    1st invoice on a clean client
--                                       B   2nd invoice, JOBBER side 23505
--   client_comm_one_city_report_per_property two city_report, 1 prop 23505    two on props 162 and 1164
--
-- 🛑 CONTROL B IS NON-NEGOTIABLE. Control A alone passes under a naive per-table trigger, so A
-- on its own does not test the "across both tables" claim at all. B is the one that does.
-- The two-property city control is what proves that rule is per LOCATION and not per client.
--
-- Seed trigger, on a throwaway client inside a rolled-back transaction:
--   insert (property_id null, contact_role 'primary')      -> EXACTLY 3 prefs
--   insert (property_id 162,  contact_role 'accounting')   -> 0 NEW prefs
-- 🛑 The second assertion is the one that proves a column DEFAULT was avoided. Without it the
-- first passes under either design.
--
-- Splice: client.create_client_contact and client.update_client_contact must each contain
--   array['primary','accounting']   exactly once
--   'city'                          zero times
--   'accounting or city role'       zero times
--   'Pick a location, or use the accounting role.'   once (update only)
-- and their length must have shrunk by exactly the substituted bytes, never more.
--
-- Additive check: /clients/381 renders identically; no existing column ordinal moved.
-- ============================================================================================
