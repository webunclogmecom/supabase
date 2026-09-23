-- =============================================================================
-- 2026-09-22_2043_property_intakes.sql
-- Section 1 of Building Apps/docs/2026-09-23_client-intake-build-plan.md
--
-- WHAT. The raw layer of the Client Intake System: one immutable submission per
-- intake round, per PROPERTY, plus the office's accept decisions and the status
-- the Clients list will show.
--
-- WHY. Fred, voice note 2026-09-22: "someone has to intake information [...] to
-- document everything about the property, where the grease traps are, how to
-- access them, where to park the truck, hours of operation, contacts, photo [...]
-- there's no standardized process. There is no way to verify the information is
-- complete." Measured the same day: 489 service properties, SIX of them carry
-- access notes.
--
-- FRED'S SETTLED DECISIONS ENCODED HERE (2026-09-22):
--   1. Keyed by PROPERTY, never by client.
--   4. The checklist is a two-level tree. The office requests L1 sections and
--      specific L2 questions; the collector sees only those. COMPLETE means every
--      REQUESTED L2 was answered, so a three-question intake can be Complete.
--   5. Verified means internal two-person approval. It is NOT in this migration:
--      it describes the published page, which does not exist yet. This migration
--      ships Nothing / Incomplete / Complete only.
--   6. The collector does not log in. Hence the token and expires_at here, and an
--      edge function later. No auth identity is available at submit, so `collector`
--      is free text that the submitter types.
--   8. Accept fills a BLANK automatically; when ours is not blank and differs, the
--      office sees a compare and decides, and an accepted change OVERWRITES with a
--      provenance record ("Accepted change from Intake Form by <person>").
--  10. No backfill, but an OLD property must be able to enter the flow at any time.
--      Nothing here assumes a new client.
--
-- WHAT THIS IS NOT. This is a helper feature, not a requirement flow (Fred). Every
-- object is additive. A property with no intake row reads 'Nothing' and behaves
-- exactly as it does today. Creating a client, a job or a visit never touches these
-- tables.
--
-- RULE 8, AUDIT: both new tables OPT IN. They carry human-editable fields
-- (`accepted`, `collector`) and decision 8 asks who accepted what, so the audit
-- trail is load-bearing rather than ceremony.
--
-- 🛑 CONSEQUENCE OF ACCEPTING A CAPACITY, READ BEFORE THE FIRST ACCEPT.
--    `properties.grease_trap_size_gallons` mirrors to Jobber both ways (about two
--    minutes, via trg_properties_enqueue_outbound) AND is the source of `gallons`
--    on the Miami-Dade LWT monthly filing, which `derm.v_lwt_monthly_rows`
--    recomputes LIVE. `public.lwt_filings` / `lwt_filing_tickets` store NO gallons,
--    so accepting a corrected capacity changes what the system says we filed for a
--    period already filed. Snapshot columns on lwt_filing_tickets are planned
--    before the first capacity is accepted. Section 1.7 of the plan.
--
-- 🛑 QUESTION KEYS ARE APPEND-ONLY. A key ('access_entry.gate') is stable text and
--    is shared by form_snapshot, requested, answers, the accept map and the photo
--    role. A changed MEANING gets a NEW key. Never reuse or rename one, or a 2026
--    submission stops being readable.
--
-- NOT IN THIS MIGRATION, deliberately (see the plan):
--   - intake_form_versions. One form_snapshot per row instead; a version table for a
--     form nobody has published once is speculative.
--   - client.edit_intake_request and a cancel RPC. Conveniences; nothing depends on
--     them. `cancelled_at` exists so cancel is one UPDATE when it is wanted.
--   - The published page, Verified, two-person approval, the client confirmation.
--   - Photos. Separate migration, and it must use entity_type 'property_intake',
--     never 'property', or customer.client_access_photos publishes them to anon.
--
-- ATOMIC: no COMMIT anywhere, so the VERIFY block at the bottom rolls the whole
-- migration back if any assertion fails.
-- =============================================================================

-- ---------------------------------------------------------------- 1. THE TABLES

create table if not exists public.property_intakes (
  id             bigint generated always as identity primary key,
  property_id    bigint      not null references public.properties(id),
  form_snapshot  jsonb       not null,   -- the L1/L2 tree as it stood when scheduled
  requested      jsonb       not null,   -- JSON array of L2 keys the office asked for
  token          text        not null unique default public.gen_short_id(16),
  expires_at     timestamptz not null default now() + interval '60 days',
  requested_by   text,
  requested_at   timestamptz not null default now(),
  collector      text,                   -- typed by the submitter; there is no login
  answers        jsonb,                  -- NULL until submit, immutable after
  submitted_at   timestamptz,
  accepted       jsonb       not null default '{}'::jsonb,
  cancelled_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint property_intakes_requested_is_array check (jsonb_typeof(requested) = 'array'),
  constraint property_intakes_snapshot_is_object  check (jsonb_typeof(form_snapshot) = 'object'),
  constraint property_intakes_answers_is_object   check (answers is null or jsonb_typeof(answers) = 'object'),
  constraint property_intakes_submitted_has_answers
    check ((submitted_at is null) = (answers is null))
);

comment on table public.property_intakes is
  'One site-visit intake round per property. answers is the IMMUTABLE raw submission '
  '(design principle 1) and is never edited after submit; the office curates into a '
  'separate published layer. Status is derived in client.v_property_intake, never stored.';

create index if not exists property_intakes_property_idx
  on public.property_intakes(property_id);
create index if not exists property_intakes_open_idx
  on public.property_intakes(property_id) where submitted_at is null and cancelled_at is null;

-- The provenance record for Fred's decision 8d. Append-only by convention and by
-- the absence of any UPDATE path. Deliberately NOT a new key inside
-- audit.log_change's request_context: that function is attached to 61 tables and is
-- the one that produced the 232-row mislabelling incident.
create table if not exists public.property_intake_accepts (
  id           bigint generated always as identity primary key,
  intake_id    bigint not null references public.property_intakes(id),
  property_id  bigint not null references public.properties(id),
  question_key text   not null,
  target_column text  not null,
  old_value    jsonb,
  new_value    jsonb,
  actor        text   not null,
  accepted_at  timestamptz not null default now()
);

comment on table public.property_intake_accepts is
  'One row per field the office accepted from an intake. This is what lets the '
  'Activity feed say "Accepted change from Intake Form by <person>" with the old and '
  'the new value, without touching audit.log_change.';

create index if not exists property_intake_accepts_property_idx
  on public.property_intake_accepts(property_id, accepted_at desc);

-- ------------------------------------------------- 2. GRANTS, RLS, AUDIT, TOUCH
-- Default privileges in this database hand `authenticated` arwdDxtm on every new
-- public table BEFORE any GRANT runs. That is how public.job_frequency_changes
-- shipped truncatable on 2026-08-07. Revoke first, assert at the bottom.

revoke all on public.property_intakes        from anon, authenticated;
revoke all on public.property_intake_accepts from anon, authenticated;

alter table public.property_intakes        enable row level security;
alter table public.property_intake_accepts enable row level security;

drop trigger if exists audit_property_intakes on public.property_intakes;
create trigger audit_property_intakes
  after insert or update or delete on public.property_intakes
  for each row execute function audit.log_change();

drop trigger if exists audit_property_intake_accepts on public.property_intake_accepts;
create trigger audit_property_intake_accepts
  after insert or update or delete on public.property_intake_accepts
  for each row execute function audit.log_change();

drop trigger if exists set_updated_at_property_intakes on public.property_intakes;
create trigger set_updated_at_property_intakes
  before update on public.property_intakes
  for each row execute function public.set_updated_at();

-- Immutability of the raw submission (design principle 1). `accepted` and
-- `cancelled_at` stay editable; everything that evidences what the field reported
-- is frozen at submit.
create or replace function public.fn_property_intake_immutable()
returns trigger language plpgsql set search_path to '' as $$
begin
  if old.submitted_at is not null then
    if new.answers is distinct from old.answers then
      raise exception 'the raw intake submission is immutable (intake %)', old.id
        using errcode = '22023';
    end if;
    if new.submitted_at is distinct from old.submitted_at then
      raise exception 'submitted_at cannot change (intake %)', old.id using errcode = '22023';
    end if;
    if new.collector is distinct from old.collector then
      raise exception 'collector is frozen at submit (intake %)', old.id using errcode = '22023';
    end if;
    if new.requested is distinct from old.requested then
      raise exception 'requested cannot change after submit (intake %)', old.id using errcode = '22023';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists property_intakes_immutable on public.property_intakes;
create trigger property_intakes_immutable
  before update on public.property_intakes
  for each row execute function public.fn_property_intake_immutable();

-- ------------------------------------------------------ 3. THE ANSWERED PREDICATE
-- ⚠ THIS IS THE ONE PREDICATE THE WHOLE STATUS COLUMN RESTS ON, and it has been
-- wrong twice. Version 1 used ->> and graded `{}` and `[]` as answered. Version 2
-- fixed that and still returned SQL NULL for an ABSENT key, which the view read as
-- answered, so an intake with zero answers scored Complete. Both fixes are here:
-- coalesce to false, and btrim the string branch.

create or replace function public.fn_intake_answered(p_answers jsonb, p_key text)
returns boolean language sql immutable set search_path to '' as $$
  select coalesce(
    p_answers is not null
    and p_answers -> p_key ? 'value'
    and jsonb_typeof(p_answers -> p_key -> 'value') <> 'null'
    and case jsonb_typeof(p_answers -> p_key -> 'value')
          when 'string' then btrim(p_answers -> p_key ->> 'value') <> ''
          when 'object' then (p_answers -> p_key -> 'value') <> '{}'::jsonb
          when 'array'  then (p_answers -> p_key -> 'value') <> '[]'::jsonb
          else true                       -- a number or a boolean is an answer, incl. 0 and false
        end,
  false);
$$;

comment on function public.fn_intake_answered(jsonb, text) is
  'True when the collector answered this question key. 0, false and "no" ARE answers; '
  'an absent key, a null, an empty string, whitespace, {} and [] are not.';

-- ------------------------------------------------------------- 4. THE STATUS VIEW
-- Status comes from the latest SUBMITTED round. Whether a round is open is a
-- SEPARATE flag, because ordering by submitted_at nulls first made scheduling a
-- follow-up flip a Complete property back to Nothing.

create or replace view client.v_property_intake as
select
  p.id                                   as property_id,
  p.client_id,
  i.id                                   as intake_id,
  i.submitted_at,
  i.collector,
  case
    when i.id is null then 'Nothing'
    when not exists (
      select 1 from jsonb_array_elements_text(i.requested) k
      where not public.fn_intake_answered(i.answers, k)
    ) then 'Complete'
    else 'Incomplete'
  end                                    as intake_status,
  exists (
    select 1 from public.property_intakes s
    where s.property_id = p.id
      and s.submitted_at is null
      and s.cancelled_at is null
      and s.expires_at > now()
  )                                      as intake_scheduled,
  coalesce((
    select array_agg(k order by k) from jsonb_array_elements_text(i.requested) k
    where not public.fn_intake_answered(i.answers, k)
  ), '{}'::text[])                       as missing_keys
from public.properties p
left join lateral (
  select x.* from public.property_intakes x
  where x.property_id = p.id and x.cancelled_at is null and x.submitted_at is not null
  order by x.submitted_at desc
  limit 1
) i on true
where p.deleted_at is null
  and coalesce(p.is_billing, false) = false;

comment on view client.v_property_intake is
  'Intake status per service property: Nothing / Incomplete / Complete. Verified is '
  'NOT here; it belongs to the published page and does not exist yet. missing_keys is '
  'the gap list that makes "fake required" workable: a partial intake is accepted and '
  'the office sees exactly what is still owed.';

-- -------------------------------------------- 5. THE KEY TO COLUMN MAP + COMPARE
-- The map lives in ONE place and both the compare and the accept read it, so the app
-- never has to know it. v1 maps only the five answers that already have a property
-- column. Everything else the checklist collects stays in the intake and is read by
-- the driver page later.

create or replace function public.fn_intake_accept_map()
returns jsonb language sql immutable set search_path to '' as $$
  select '{
    "grease_trap.manhole_count":    "grease_trap_manhole_count",
    "sample_port.count":            "sample_port_count",
    "grease_trap.capacity_gallons": "grease_trap_size_gallons",
    "access_entry.lock_box_code":   "lock_box_key",
    "access_hours.schedule":        "access_schedule"
  }'::jsonb;
$$;

comment on function public.fn_intake_accept_map() is
  'Intake question key -> public.properties column, for the five answers that have a '
  'column today. Append-only, same rule as the question keys themselves.';

create or replace function client.get_intake_compare(p_intake_id bigint)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_i public.property_intakes;
  v_p public.properties;
  v_map jsonb := public.fn_intake_accept_map();
  v_out jsonb := '[]'::jsonb;
  v_key text;
  v_col text;
  v_ours jsonb;
  v_theirs jsonb;
  v_state text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  select * into v_p from public.properties where id = v_i.property_id;

  for v_key in select k from jsonb_array_elements_text(v_i.requested) k loop
    v_col := v_map ->> v_key;
    continue when v_col is null;                       -- intake-only answer, nothing to compare

    v_theirs := v_i.answers -> v_key -> 'value';
    v_ours := case v_col
      when 'grease_trap_manhole_count' then to_jsonb(nullif(v_p.grease_trap_manhole_count, 0))
      when 'sample_port_count'         then to_jsonb(v_p.sample_port_count)
      when 'grease_trap_size_gallons'  then to_jsonb(v_p.grease_trap_size_gallons)
      when 'lock_box_key'              then to_jsonb(nullif(btrim(coalesce(v_p.lock_box_key,'')), ''))
      when 'access_schedule'           then v_p.access_schedule
    end;

    v_state := case
      when not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = v_theirs                                  then 'same'
      else 'differs'
    end;

    v_out := v_out || jsonb_build_object(
      'key', v_key, 'column', v_col, 'ours', v_ours, 'theirs', v_theirs, 'state', v_state);
  end loop;

  return jsonb_build_object('intake_id', v_i.id, 'property_id', v_i.property_id, 'fields', v_out);
end $$;

comment on function client.get_intake_compare(bigint) is
  'What the office accept screen renders. state is blank (accept auto-fills), same '
  '(no-op), differs (show both values, a human decides, Fred 2026-09-22) or unanswered. '
  'A stored manhole count of 0 reads as BLANK on purpose: 370 of 506 rows are 0 and the '
  'column is NOT NULL DEFAULT 0, so zero and unknown are the same value.';

-- ------------------------------------------------------------------ 6. THE RPCs

create or replace function client.schedule_property_intake(
  p_property_id bigint, p_requested text[], p_form_snapshot jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_id bigint;
  v_token text;
  v_bad text[];
  v_valid text[];
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  if p_requested is null or array_length(p_requested, 1) is null then
    raise exception 'pick at least one question to collect' using errcode = '22023';
  end if;
  if p_form_snapshot is null or jsonb_typeof(p_form_snapshot) <> 'object' then
    raise exception 'p_form_snapshot must be the form definition object' using errcode = '22023';
  end if;

  perform 1 from public.properties
   where id = p_property_id and deleted_at is null and coalesce(is_billing, false) = false;
  if not found then
    raise exception 'property % is not a live service property', p_property_id using errcode = 'P0002';
  end if;

  -- Every requested key must exist in the snapshot as an L2 question. A typo'd key
  -- can never be answered, so the intake would sit at Incomplete forever with no way
  -- to tell a typo from a lazy collector.
  select array_agg(q) into v_valid
  from jsonb_array_elements(p_form_snapshot -> 'sections') s,
       jsonb_array_elements_text(s -> 'questions') q;

  select array_agg(k) into v_bad
  from unnest(p_requested) k
  where v_valid is null or k <> all (v_valid);
  if v_bad is not null then
    raise exception 'unknown question key(s) for this form: %', v_bad using errcode = '22023';
  end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, p_form_snapshot, to_jsonb(p_requested), auth.jwt() ->> 'email')
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(p_requested), 'note', p_note);
end $$;

create or replace function client.accept_intake_answers(p_intake_id bigint, p_keys text[])
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_i public.property_intakes;
  v_map jsonb := public.fn_intake_accept_map();
  v_actor text := auth.jwt() ->> 'email';
  v_patch jsonb := '{}'::jsonb;
  v_key text;
  v_col text;
  v_new jsonb;
  v_old jsonb;
  v_gallons integer;
  v_written text[] := array[]::text[];
  v_cmp jsonb;
  v_field jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(v_actor,'')) not like '%@ayache.com'
     and lower(coalesce(v_actor,'')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_keys is null or array_length(p_keys, 1) is null then
    raise exception 'no keys were accepted' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  if v_i.submitted_at is null then
    raise exception 'intake % has not been submitted yet', p_intake_id using errcode = '22023';
  end if;

  v_cmp := client.get_intake_compare(p_intake_id);

  foreach v_key in array p_keys loop
    v_col := v_map ->> v_key;
    if v_col is null then
      raise exception 'question % does not map to a property field', v_key using errcode = '22023';
    end if;
    if not public.fn_intake_answered(v_i.answers, v_key) then
      raise exception 'question % was not answered, nothing to accept', v_key using errcode = '22023';
    end if;

    select f into v_field from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
    v_old := v_field -> 'ours';
    v_new := v_i.answers -> v_key -> 'value';

    if v_col = 'grease_trap_size_gallons' then
      v_gallons := (v_new #>> '{}')::integer;          -- capacity has its own RPC
    else
      v_patch := v_patch || jsonb_build_object(v_col, v_new);
    end if;

    insert into public.property_intake_accepts
      (intake_id, property_id, question_key, target_column, old_value, new_value, actor)
    values (p_intake_id, v_i.property_id, v_key, v_col, v_old, v_new, v_actor);
    v_written := v_written || v_key;
  end loop;

  -- Reuse the gated writers rather than touching public.properties directly. They
  -- carry the allowlist, the staff gate, the error vocabulary and, for gallons and
  -- the lock box, the outbound Jobber push (which only fires because auth.uid() is
  -- not null here, i.e. because a real person clicked Accept).
  if v_patch <> '{}'::jsonb then
    perform client.update_property_operational(v_i.property_id, v_patch);
  end if;
  if v_gallons is not null then
    perform client.update_property_capacity(v_i.property_id, v_gallons);
  end if;

  update public.property_intakes
     set accepted = accepted || jsonb_build_object(
           'at', to_jsonb(now()), 'by', to_jsonb(v_actor), 'keys', to_jsonb(v_written))
   where id = p_intake_id;

  return jsonb_build_object('ok', true, 'intake_id', p_intake_id,
                            'accepted', to_jsonb(v_written), 'by', v_actor);
end $$;

-- ------------------------------------------------------------------- 7. GRANTS
-- New functions get EXECUTE to PUBLIC by default in Postgres, so revoke first.

revoke all on function public.fn_intake_answered(jsonb, text)               from public, anon;
revoke all on function public.fn_intake_accept_map()                        from public, anon;
revoke all on function client.get_intake_compare(bigint)                    from public, anon;
revoke all on function client.schedule_property_intake(bigint, text[], jsonb, text) from public, anon;
revoke all on function client.accept_intake_answers(bigint, text[])         from public, anon;

grant execute on function public.fn_intake_answered(jsonb, text)            to authenticated;
grant execute on function client.get_intake_compare(bigint)                 to authenticated;
grant execute on function client.schedule_property_intake(bigint, text[], jsonb, text) to authenticated;
grant execute on function client.accept_intake_answers(bigint, text[])      to authenticated;
grant select on client.v_property_intake                                    to authenticated;

-- ------------------------------------------------------------------- 8. VERIFY
-- Fails the whole migration (no COMMIT above, so a raise rolls everything back).
-- Mutation cases first: an assertion with no failing case is an untested instrument.

do $verify$
declare
  v_prop bigint;
  v_id1 bigint; v_id2 bigint;
  v_snapshot jsonb := '{"sections":[{"id":"access_entry","questions":["access_entry.gate","access_entry.lock_box_code"]}]}'::jsonb;
  v_status text; v_missing text[]; v_sched boolean;
  v_raised boolean;
  v_n int;
begin
  -- 8.1 the predicate, including the two shapes that broke it before
  if      public.fn_intake_answered('{"a":{"value":"yes"}}'::jsonb,'a') is not true then raise exception 'VERIFY 8.1a: a string answer must count'; end if;
  if      public.fn_intake_answered('{"a":{"value":0}}'::jsonb,'a')     is not true then raise exception 'VERIFY 8.1b: 0 must count as an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":false}}'::jsonb,'a') is not true then raise exception 'VERIFY 8.1c: false must count as an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":""}}'::jsonb,'a')    is not false then raise exception 'VERIFY 8.1d: empty string is not an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":"   "}}'::jsonb,'a') is not false then raise exception 'VERIFY 8.1e: whitespace is not an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":null}}'::jsonb,'a')  is not false then raise exception 'VERIFY 8.1f: json null is not an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":{}}}'::jsonb,'a')    is not false then raise exception 'VERIFY 8.1g: {} is not an answer'; end if;
  if      public.fn_intake_answered('{"a":{"value":[]}}'::jsonb,'a')    is not false then raise exception 'VERIFY 8.1h: [] is not an answer'; end if;
  if      public.fn_intake_answered('{}'::jsonb,'a')                    is not false then raise exception 'VERIFY 8.1i: an ABSENT KEY must not read as answered'; end if;
  if      public.fn_intake_answered(null,'a')                           is not false then raise exception 'VERIFY 8.1j: null answers must not read as answered'; end if;

  select id into v_prop from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false
   order by p.id limit 1;
  if v_prop is null then raise exception 'VERIFY: no 112-YA service property to test against'; end if;

  -- 8.2 a property with no intake reads Nothing
  select intake_status into v_status from client.v_property_intake where property_id = v_prop;
  if v_status <> 'Nothing' then raise exception 'VERIFY 8.2: expected Nothing, got %', v_status; end if;

  -- 8.3 THE ONE THAT CAUGHT THE BUG: two requested keys, ZERO answers, must be Incomplete
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_prop, v_snapshot, '["access_entry.gate","access_entry.lock_box_code"]'::jsonb,
          '[TEST] migration verify', '{}'::jsonb, now() - interval '1 hour')
  returning id into v_id1;

  select intake_status, missing_keys into v_status, v_missing
    from client.v_property_intake where property_id = v_prop;
  if v_status <> 'Incomplete' then
    raise exception 'VERIFY 8.3: an empty submission must be Incomplete, got %', v_status;
  end if;
  if array_length(v_missing,1) <> 2 then
    raise exception 'VERIFY 8.3: expected 2 missing keys, got %', v_missing;
  end if;

  -- 8.4 a LATER submitted round with every requested key answered -> Complete.
  -- A second row rather than an UPDATE, because 8.6 proves answers are immutable:
  -- updating v_id1 here would (correctly) raise, which is how this assertion was
  -- caught before it ever ran. This also proves the lateral takes the LATEST
  -- submitted round, and that an answer to an unrequested key is ignored.
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_prop, v_snapshot, '["access_entry.gate","access_entry.lock_box_code"]'::jsonb,
          '[TEST] migration verify', '{"access_entry.gate":{"value":"yes"},"access_entry.lock_box_code":{"value":"2707"},"access_entry.unrequested":{"value":""}}'::jsonb, now())
  returning id into v_id1;

  select intake_status, missing_keys into v_status, v_missing
    from client.v_property_intake where property_id = v_prop;
  if v_status <> 'Complete' then raise exception 'VERIFY 8.4: expected Complete, got % (missing %)', v_status, v_missing; end if;

  -- 8.5 scheduling a follow-up must NOT flip Complete back to Nothing
  insert into public.property_intakes (property_id, form_snapshot, requested)
  values (v_prop, v_snapshot, '["access_entry.gate"]'::jsonb) returning id into v_id2;
  select intake_status, intake_scheduled into v_status, v_sched
    from client.v_property_intake where property_id = v_prop;
  if v_status <> 'Complete' then raise exception 'VERIFY 8.5: a new round must not change status, got %', v_status; end if;
  if v_sched is not true then raise exception 'VERIFY 8.5: intake_scheduled must be true'; end if;

  -- 8.6 immutability actually raises
  v_raised := false;
  begin
    update public.property_intakes set answers = '{"x":{"value":1}}'::jsonb where id = v_id1;
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 8.6: the raw submission must be immutable'; end if;

  -- 8.7 the staff gate refuses an unauthenticated caller
  v_raised := false;
  begin
    perform client.schedule_property_intake(v_prop, array['access_entry.gate'], v_snapshot);
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 8.7: schedule must refuse with no JWT'; end if;

  -- 8.8 with a staff JWT it works, and an unknown key is refused
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","email":"fred@ayache.com"}', true);
  v_raised := false;
  begin
    perform client.schedule_property_intake(v_prop, array['access_entry.typo'], v_snapshot);
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 8.8: an unknown question key must be refused'; end if;
  perform client.schedule_property_intake(v_prop, array['access_entry.gate'], v_snapshot);

  -- 8.9 the compare classifies blank vs differs (lock box is empty on 112-YA)
  select count(*) into v_n from jsonb_array_elements(client.get_intake_compare(v_id1) -> 'fields') f
   where f ->> 'key' = 'access_entry.lock_box_code' and f ->> 'state' in ('blank','differs','same');
  if v_n <> 1 then raise exception 'VERIFY 8.9: the lock box field must appear exactly once in the compare, got %', v_n; end if;
  perform set_config('request.jwt.claims', '', true);

  -- 8.10 grants: authenticated must NOT be able to delete either table
  if has_table_privilege('authenticated','public.property_intakes','DELETE')        then raise exception 'VERIFY 8.10a: authenticated can DELETE property_intakes'; end if;
  if has_table_privilege('authenticated','public.property_intakes','INSERT')        then raise exception 'VERIFY 8.10b: authenticated can INSERT property_intakes'; end if;
  if has_table_privilege('authenticated','public.property_intake_accepts','DELETE') then raise exception 'VERIFY 8.10c: authenticated can DELETE property_intake_accepts'; end if;
  if has_function_privilege('anon','client.accept_intake_answers(bigint, text[])','EXECUTE') then raise exception 'VERIFY 8.10d: anon can execute accept'; end if;

  -- 8.11 audit triggers are really attached
  select count(*) into v_n from pg_trigger
   where tgname in ('audit_property_intakes','audit_property_intake_accepts') and not tgisinternal;
  if v_n <> 2 then raise exception 'VERIFY 8.11: expected 2 audit triggers, found %', v_n; end if;

  -- clean up the fixtures
  delete from public.property_intakes where property_id = v_prop;

  raise notice 'VERIFY: all assertions passed';
end $verify$;

notify pgrst, 'reload schema';
