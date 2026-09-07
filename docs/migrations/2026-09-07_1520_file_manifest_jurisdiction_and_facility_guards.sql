-- 2026-09-07_1520_file_manifest_jurisdiction_and_facility_guards.sql
--
-- STEP 3 of the Broward FDEP manifest chain. Closes three silent write defects on the path every
-- manifest filing takes, and adds the read-only detector the upload UI needs for Fred's county
-- warning. NO SIGNATURE CHANGES, so no PostgREST ambiguity and no grant loss.
--
-- WHAT WAS BROKEN, all three measured live in rolled-back probes rather than read off the source:
--   1. public.file_manifest's INSERT is two CASE arms keyed on the EXACT literals 'Miami-Dade' and
--      'Broward', with NO ELSE. 7 of 9 tested jurisdiction values, including 'miami-dade' and
--      ' Miami-Dade', fell through both arms and produced a manifest with NO ticket number in
--      either column and NO error, returning an id as though it had succeeded.
--   2. Nothing cross-checks the jurisdiction against the chosen facility's county. A 'Broward'
--      filing against the Miami-Dade facility succeeds and produces a PLAUSIBLE-LOOKING row, which
--      is worse than the blank one, because nothing about it looks wrong.
--   3. disposal_facilities id 1 (Homestead Dump) has county NULL and is accepted. It is filtered out
--      of the app dropdown; the RPC accepts any id.
--
-- WARNING, AND THIS HAS ALREADY COST WEEKS. Rows on tickets 306858/306859 were filed white (the
-- Miami-Dade column) against facility 3 (Broward) on 2026-06-11, and 7 rows on ticket 308684 were
-- filed yellow against facility 2 (Miami-Dade) on 2026-07-08. Both directions of the contradiction,
-- 27 days apart, 21 manifests, all by app_source 'derm-tracker'. The first took three hand-written
-- SQL passes over six weeks to unwind.
--
-- WHY THE CROSS-CHECK IS A TABLE TRIGGER AND NOT A LINE IN file_manifest.
-- public.edit_manifest ALSO writes both number columns AND takes p_disposal_facility_id, so it can
-- create the same mismatch. It is not merely a second copy of the same rule: it decides jurisdiction
-- with a SUBSTRING test on the word dade, so it can never produce the both-NULL row but is strictly
-- more permissive about what counts as Dade. Two functions, two different notions of the same word.
-- A guard in file_manifest alone would leave edit_manifest able to write exactly what the guard
-- exists to prevent.
-- The other two writers CANNOT introduce a mismatch and are therefore not touched:
-- public.file_manifest_on_shared_ticket and derm.file_manifest_and_link both INHERIT
-- disposal_facility_id from a sibling on the ticket (verified in both bodies) rather than taking it.
--
-- THE TRIGGER IS SCOPED TO LIVE ROWS (NEW.deleted_at IS NULL), AND THAT IS THE FREEZE GUARD.
-- Measured: 0 of 712 LIVE manifests violate the row invariant, so nothing existing is refused. All
-- 8 rows that DO violate it are soft-deleted, every one at the same instant 2026-07-10 21:36:38 ET,
-- with 0 manifest_visits links and 0 UPDATEs since. edit_manifest cannot reach them anyway (its
-- UPDATE carries WHERE dm.deleted_at IS NULL), but scoping the trigger means a future soft-deleted
-- row can still be touched. This is the trap the ticket-number CHECK had in step 2: a guard placed
-- where an UPDATE reaches it FREEZES every historical row that violates it, against sent_to_client,
-- editing and soft-delete.
--
-- IT MUST SORT LAST AMONG THE BEFORE TRIGGERS, hence trg_zz_. It VALIDATES, so it has to see the
-- final values. Existing BEFORE triggers on this table, in firing order:
-- trg_aa_normalize_ticket_numbers (step 2), trg_ab_adopt_sibling_white,
-- trg_ae_dump_date_keeps_links_valid, trg_ae_ticket_key_unambiguous, trg_derm_inherit_ticket_fields,
-- trg_derm_manifests_updated_at. trg_derm_inherit_ticket_fields INHERITS ticket fields from
-- siblings, so validating before it runs would check values that are about to change. Renaming this
-- trigger is a breaking change.
--
-- NO SIGNATURE CHANGE, DELIBERATELY. Measured on Prod: each of the four functions has exactly ONE
-- pg_proc row today, so there is no ambiguity now. Adding a parameter does NOT replace a function,
-- it CREATES AN OVERLOAD, and PostgREST then answers 300 PGRST203 "Could not choose the best
-- candidate function" to every live tab. Avoiding that would need DROP + CREATE + re-GRANT, and DROP
-- discards grants. Fred's county rule is a WARNING, not a block, so nothing needs to be passed in:
-- the UI calls the detector below before filing, and the operator's own "File anyway" is the
-- acknowledgement. Who overrode it stays answerable from audit.logs (app_source and
-- jwt_claims->>'email'; note audit.logs.changed_by is NULL on every row ever written).
--
-- DO NOT REACH FOR public.fn_dump_site_accepts FOR THE COUNTY RULE. It already implements exactly
-- Fred's semantics, and it is keyed on a dump CLIENT id (76 / 365), NOT a disposal_facilities id
-- (1 / 2 / 3). "Homestead Dump" is the name of BOTH client 365 (the live Dade site that carries the
-- rule) and facility 1 (dead, county NULL). Called with a facility id it returns TRUE
-- unconditionally, so a guard built on it would silently pass everything.
--
-- RULE 8 (audit): no new table. public.derm_manifests already carries audit_derm_manifests.
--
-- THE FUNCTION BODY BELOW WAS EXTRACTED WITH pg_get_functiondef AND EDITED, NEVER RETYPED, per this
-- repo's CREATE OR REPLACE rule. The only change is the DECISION 1 block inserted immediately above
-- the existing INSERT. Asserted mechanically before writing this file: the anchor
-- "INSERT INTO public.derm_manifests" appears exactly once, and every non-blank line of the original
-- 36-line body still appears in the new 49-line body.

-- ---------------------------------------------------------------------------------------------
-- 1. A both-NULL manifest becomes impossible at the table. 730 of 730 rows already satisfy this,
--    including soft-deleted ones, so it is VALIDATED rather than NOT VALID.
-- ---------------------------------------------------------------------------------------------

alter table public.derm_manifests
  add constraint derm_manifests_has_ticket_number_chk
  check (white_manifest_number is not null or yellow_ticket_number is not null);

-- ---------------------------------------------------------------------------------------------
-- 2. The cross-check, covering every writer including edit_manifest and raw SQL.
-- ---------------------------------------------------------------------------------------------

create or replace function public.fn_ticket_column_matches_facility()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_bucket text;
  v_fac    text;
begin
  if new.deleted_at is not null then
    return new;                      -- see the header: scoping to live rows is the freeze guard
  end if;

  select coalesce(public.fn_dump_county_bucket(df.county), 'UNKNOWN'), df.name
    into v_bucket, v_fac
    from public.disposal_facilities df
   where df.id = new.disposal_facility_id;

  if v_bucket is null then
    raise exception 'Disposal facility % does not exist.', new.disposal_facility_id
      using errcode = '22023';
  end if;

  if v_bucket = 'UNKNOWN' then
    raise exception 'Disposal facility % (%) has no county on record, so we cannot tell which manifest number belongs on it. Set its county before filing against it.',
      new.disposal_facility_id, coalesce(v_fac, 'unnamed')
      using errcode = '22023';
  end if;

  if new.white_manifest_number is not null and v_bucket <> 'DADE' then
    raise exception 'A white manifest number is a Miami-Dade number, but % is a % facility. Check the disposal receipt: either the number goes in the yellow ticket field, or the facility is wrong.',
      coalesce(v_fac, new.disposal_facility_id::text), v_bucket
      using errcode = '22023';
  end if;

  if new.yellow_ticket_number is not null and v_bucket <> 'BROWARD' then
    raise exception 'A yellow ticket number is a Broward or Palm Beach number, but % is a % facility. Check the disposal receipt: either the number goes in the white manifest field, or the facility is wrong.',
      coalesce(v_fac, new.disposal_facility_id::text), v_bucket
      using errcode = '22023';
  end if;

  return new;
end;
$fn$;

comment on function public.fn_ticket_column_matches_facility() is
  'Refuses a manifest whose ticket column disagrees with its disposal facility county, and one on a '
  'facility with no county. Live rows only: soft-deleted rows are deliberately exempt so history '
  'stays editable. Must sort LAST among the BEFORE triggers, after trg_derm_inherit_ticket_fields.';

drop trigger if exists trg_zz_ticket_matches_facility on public.derm_manifests;
create trigger trg_zz_ticket_matches_facility
  before insert or update on public.derm_manifests
  for each row execute function public.fn_ticket_column_matches_facility();

-- ---------------------------------------------------------------------------------------------
-- 3. public.file_manifest, SAME SIGNATURE. Body extracted and edited, never retyped.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.file_manifest(p_client_id bigint, p_jurisdiction text, p_number text, p_disposal_facility_id bigint, p_dump_date date, p_visit_ids bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  -- A manifest is only uploaded AFTER it returns from the city, so both of these are on the sheet
  -- in front of whoever is filing it. A blank here means the form was submitted incomplete, not
  -- that the value is unknowable. Raise something Diego can read rather than letting the CHECK
  -- constraint surface a raw 23514.
  IF p_dump_date IS NULL OR p_disposal_facility_id IS NULL THEN
    RAISE EXCEPTION 'Dump date and disposal facility are both required to file a manifest (they are printed on the sheet). Got dump date %, facility %.',
      coalesce(p_dump_date::text, 'blank'), coalesce(p_disposal_facility_id::text, 'blank')
      USING ERRCODE = '22023';
  END IF;

  -- 🛑 DECISION 1, Fred 2026-09-07: an unrecognised jurisdiction must RAISE, not write NULL.
  -- The CASE below writes p_number into the white column only for the exact literal 'Miami-Dade'
  -- and into the yellow column only for the exact literal 'Broward'. Anything else, including
  -- 'miami-dade' and ' Miami-Dade', fell through BOTH arms and produced a manifest with NO ticket
  -- number in either column and NO error. Measured live in a rolled-back probe: 7 of 9 tested
  -- values did exactly that. This guard MIRRORS the CASE below rather than paraphrasing it, so the
  -- two cannot drift; if you change the CASE, change this.
  IF p_jurisdiction IS DISTINCT FROM 'Miami-Dade' AND p_jurisdiction IS DISTINCT FROM 'Broward' THEN
    RAISE EXCEPTION 'Jurisdiction must be exactly ''Miami-Dade'' or ''Broward'' (case and spacing matter). Got %.',
      coalesce(quote_literal(p_jurisdiction), 'NULL')
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.derm_manifests
    (white_manifest_number, yellow_ticket_number, dump_ticket_date, service_date,
     disposal_facility_id, client_id)
  VALUES
    (CASE WHEN p_jurisdiction = 'Miami-Dade' THEN p_number ELSE NULL END,
     CASE WHEN p_jurisdiction = 'Broward'    THEN p_number ELSE NULL END,
     p_dump_date, p_dump_date, p_disposal_facility_id, p_client_id)
  RETURNING id INTO v_id;

  IF p_visit_ids IS NOT NULL AND array_length(p_visit_ids, 1) > 0 THEN
    INSERT INTO public.manifest_visits (manifest_id, visit_id)
    SELECT DISTINCT v_id, vid FROM unnest(p_visit_ids) AS vid
    ON CONFLICT (manifest_id, visit_id) DO NOTHING;
  END IF;

  RETURN v_id;
END; $function$;

-- ---------------------------------------------------------------------------------------------
-- 4. The detector the upload UI calls BEFORE filing, to show Fred's county warning.
--    Read-only. It refuses nothing: the rule is a WARNING and the operator's "File anyway" is the
--    acknowledgement. Fred, 2026-09-07: "we need to add a leeway in case it happens, so when
--    uploading we need to add just a warning letting the person know, but as in the confirmation
--    dialog they accepts it then it can upload a miami-dade visit with broward visits."
--
--    The rule is ASYMMETRIC: a Miami-Dade dump should carry only Dade-county clients; a Broward
--    dump carries both. So this returns rows only for a DADE facility.
--
--    It resolves the client's county through the VISIT's own property, falling back to the client's
--    primary property, which is the same rule public.manifest_pickable_visits uses. 3 clients hold
--    properties in both buckets, so a client-grain answer would be genuinely ambiguous for them.
--    Comparison goes through fn_dump_county_bucket because properties.county says 'Dade' while
--    disposal_facilities.county says 'Miami-Dade' and a direct = returns an empty set.
-- ---------------------------------------------------------------------------------------------

create or replace function public.fn_dump_county_warnings(
  p_disposal_facility_id bigint,
  p_visit_ids            bigint[]
)
returns table (visit_id bigint, client_id bigint, client_code text, client_name text, client_bucket text)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select v.id, c.id, c.client_code, c.name,
         coalesce(public.fn_dump_county_bucket(coalesce(p.county, pp.county)), 'UNKNOWN')
    from unnest(coalesce(p_visit_ids, '{}'::bigint[])) as vid
    join public.visits v   on v.id = vid and v.deleted_at is null
    join public.clients c  on c.id = v.client_id
    left join public.properties p  on p.id = v.property_id
    left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true
   where coalesce((select public.fn_dump_county_bucket(df.county)
                     from public.disposal_facilities df
                    where df.id = p_disposal_facility_id), 'UNKNOWN') = 'DADE'
     and coalesce(public.fn_dump_county_bucket(coalesce(p.county, pp.county)), 'UNKNOWN') <> 'DADE'
   order by c.client_code nulls last, v.id;
$fn$;

comment on function public.fn_dump_county_warnings(bigint, bigint[]) is
  'Advisory only, never refuses. Returns the selected visits whose client is not a Dade-county '
  'client when the dump facility is Miami-Dade. A Broward dump accepts both counties, so it returns '
  'nothing for one. UNKNOWN counts as a warning: fail loud, since the operator can see the paper.';

revoke all on function public.fn_dump_county_warnings(bigint, bigint[]) from public;
revoke all on function public.fn_dump_county_warnings(bigint, bigint[]) from anon;
grant execute on function public.fn_dump_county_warnings(bigint, bigint[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- VERIFY. Every new RAISE is EXERCISED, because PL/pgSQL is not parsed until it runs and "the
-- migration applied" says nothing about whether the function works. Each probe lives inside a
-- nested BEGIN..EXCEPTION savepoint and is always rolled back; a bare DO block COMMITS.
-- Each guard also gets a MUTATION control proving it actually bites rather than passing vacuously.
-- ---------------------------------------------------------------------------------------------

do $$
declare
  v_n        int;
  v_ok       boolean;
  v_client   bigint;
  v_visit    bigint;
  v_caught   text;
begin
  -- A1. Nothing existing is refused.
  select count(*) into v_n from public.derm_manifests
   where deleted_at is null
     and (white_manifest_number is null and yellow_ticket_number is null);
  if v_n <> 0 then raise exception 'VERIFY A1 FAILED: % live manifests have no ticket number', v_n; end if;

  -- A2. The CHECK is VALIDATED, not NOT VALID.
  select convalidated into v_ok from pg_constraint where conname = 'derm_manifests_has_ticket_number_chk';
  if v_ok is not true then raise exception 'VERIFY A2 FAILED: CHECK is not validated'; end if;

  -- A3. The trigger exists and sorts last among the BEFORE triggers.
  select count(*) into v_n from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relname = 'derm_manifests' and t.tgname = 'trg_zz_ticket_matches_facility';
  if v_n <> 1 then raise exception 'VERIFY A3 FAILED: trigger missing'; end if;
  select count(*) into v_n from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relname = 'derm_manifests' and not t.tgisinternal and (t.tgtype & 2) > 0
     and t.tgname > 'trg_zz_ticket_matches_facility';
  if v_n <> 0 then raise exception 'VERIFY A3b FAILED: % BEFORE triggers sort after the validator', v_n; end if;

  -- A4. The detector is reachable by the app role and denied to anon.
  if not has_function_privilege('authenticated', 'public.fn_dump_county_warnings(bigint,bigint[])', 'EXECUTE')
    then raise exception 'VERIFY A4 FAILED: authenticated cannot execute the detector'; end if;
  if has_function_privilege('anon', 'public.fn_dump_county_warnings(bigint,bigint[])', 'EXECUTE')
    then raise exception 'VERIFY A4b FAILED: anon can execute the detector'; end if;

  -- Pick a real client and a real completed visit to build the probes from.
  select m.client_id into v_client from public.derm_manifests m
   where m.deleted_at is null and m.white_manifest_number = '834986' order by m.id limit 1;
  if v_client is null then raise exception 'VERIFY setup FAILED: no probe client'; end if;

  -- B. THE HAPPY PATH STILL WORKS. Positive control: without this, every refusal below could be
  --    a function that refuses everything, and the suite would still pass.
  begin
    perform public.file_manifest(v_client, 'Miami-Dade', 'ZZPROBE-OK', 2, current_date, null);
    raise exception 'ZZ_ROLLBACK';
  exception when others then
    if sqlerrm <> 'ZZ_ROLLBACK' then
      raise exception 'VERIFY B FAILED: a valid Miami-Dade filing was refused: %', sqlerrm;
    end if;
  end;

  -- C. DECISION 1: an unrecognised jurisdiction now RAISES instead of writing a blank manifest.
  --    'miami-dade' lowercase is the exact value measured to produce a both-NULL row before.
  v_caught := null;
  begin
    perform public.file_manifest(v_client, 'miami-dade', 'ZZPROBE-C', 2, current_date, null);
    raise exception 'ZZ_NOT_RAISED';
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught = 'ZZ_NOT_RAISED' then
    raise exception 'VERIFY C FAILED: lowercase jurisdiction was ACCEPTED, the guard does not bite';
  end if;
  if position('Jurisdiction must be exactly' in v_caught) = 0 then
    raise exception 'VERIFY C FAILED: raised, but not by the jurisdiction guard: %', v_caught;
  end if;

  -- D. DECISION 2: jurisdiction disagreeing with the facility county now RAISES.
  --    'Broward' is a VALID jurisdiction, so this proves the FACILITY check fires, not guard C.
  v_caught := null;
  begin
    perform public.file_manifest(v_client, 'Broward', 'ZZPROBE-D', 2, current_date, null);
    raise exception 'ZZ_NOT_RAISED';
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught = 'ZZ_NOT_RAISED' then
    raise exception 'VERIFY D FAILED: a Broward number on the Miami-Dade facility was ACCEPTED';
  end if;
  if position('yellow ticket number is a Broward' in v_caught) = 0 then
    raise exception 'VERIFY D FAILED: raised, but not by the facility cross-check: %', v_caught;
  end if;

  -- D2. The mirror direction, so the guard is not one-sided.
  v_caught := null;
  begin
    perform public.file_manifest(v_client, 'Miami-Dade', 'ZZPROBE-D2', 3, current_date, null);
    raise exception 'ZZ_NOT_RAISED';
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught = 'ZZ_NOT_RAISED' then
    raise exception 'VERIFY D2 FAILED: a white number on the Broward facility was ACCEPTED';
  end if;
  if position('white manifest number is a Miami-Dade' in v_caught) = 0 then
    raise exception 'VERIFY D2 FAILED: raised, but not by the facility cross-check: %', v_caught;
  end if;

  -- E. DECISION 3: a facility with no county is refused. Facility 1 is Homestead Dump, county NULL.
  v_caught := null;
  begin
    perform public.file_manifest(v_client, 'Miami-Dade', 'ZZPROBE-E', 1, current_date, null);
    raise exception 'ZZ_NOT_RAISED';
  exception when others then
    v_caught := sqlerrm;
  end;
  if v_caught = 'ZZ_NOT_RAISED' then
    raise exception 'VERIFY E FAILED: a facility with no county was ACCEPTED';
  end if;
  if position('has no county on record' in v_caught) = 0 then
    raise exception 'VERIFY E FAILED: raised, but not by the UNKNOWN-facility guard: %', v_caught;
  end if;

  -- F. The detector is ADVISORY and asymmetric. A Broward dump must warn about nothing.
  select v.id into v_visit from public.visits v
    join public.properties p on p.id = v.property_id
   where v.deleted_at is null and v.visit_status = 'completed'
     and public.fn_dump_county_bucket(p.county) = 'BROWARD'
   order by v.id desc limit 1;
  if v_visit is null then raise exception 'VERIFY F FAILED: no Broward-county visit to probe with'; end if;

  select count(*) into v_n from public.fn_dump_county_warnings(2, array[v_visit]);
  if v_n <> 1 then
    raise exception 'VERIFY F FAILED: a Broward client on the Dade facility should warn once, got %', v_n;
  end if;

  select count(*) into v_n from public.fn_dump_county_warnings(3, array[v_visit]);
  if v_n <> 0 then
    raise exception 'VERIFY F2 FAILED: a Broward dump must warn about nothing, got %', v_n;
  end if;

  -- F3. MUTATION CONTROL: a Dade client on the Dade facility must NOT warn, or F is meaningless
  --     because the function might simply return every visit it is given.
  select v.id into v_visit from public.visits v
    join public.properties p on p.id = v.property_id
   where v.deleted_at is null and v.visit_status = 'completed'
     and public.fn_dump_county_bucket(p.county) = 'DADE'
   order by v.id desc limit 1;
  if v_visit is null then raise exception 'VERIFY F3 FAILED: no Dade-county visit to probe with'; end if;
  select count(*) into v_n from public.fn_dump_county_warnings(2, array[v_visit]);
  if v_n <> 0 then
    raise exception 'VERIFY F3 FAILED: a Dade client on a Dade dump warned, so the detector warns indiscriminately';
  end if;

  -- G. Nothing was left behind by any probe.
  select count(*) into v_n from public.derm_manifests where white_manifest_number like 'ZZPROBE%'
     or yellow_ticket_number like 'ZZPROBE%';
  if v_n <> 0 then raise exception 'VERIFY G FAILED: % probe rows survived', v_n; end if;

  raise notice 'VERIFY PASSED: happy path still files; lowercase jurisdiction, both mismatch directions and the county-less facility all refused with their own messages; detector warns on a Broward client at a Dade dump, stays silent for a Broward dump and for a Dade client; 0 probe rows left behind';
end $$;
