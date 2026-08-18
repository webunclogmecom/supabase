-- ============================================================================
-- 2026-08-18_0210 — one guarded writer for custom-field adoption, callable by the poll
-- ============================================================================
-- Fred, 2026-08-18: *"wire it to the poll. We need to test, to make sure it works, and
-- check, maybe even force the cron jobs."*
--
-- Until now adoption lived only in scripts/sync/adopt_jobber_custom_fields.js, as a SQL
-- string that script composed itself. Wiring the live sync means a SECOND caller
-- (webhook-jobber's handleProperty, driven by sync-jobber-poll), and a second caller is
-- exactly how two implementations of one rule get born. Every defect found on 2026-08-17
-- was a COMPOSITION defect: pieces individually correct, the assembled statement never
-- exercised. Shipping a second assembly would reproduce that class by construction.
--
-- ⇒ THE COMPOSED STATEMENT NOW LIVES HERE, ONCE. The edge function calls it, and the
-- script is repointed at it in the same commit. One body, one set of guards, one thing to
-- test. Neither caller may write public.properties.grease_trap_size_gallons directly.
--
-- ============================================================================
-- WHAT IT GUARANTEES, AND WHY EACH GUARD EXISTS (all six earned the hard way)
-- ============================================================================
--  1. NO ANSWER IS NOT AN EMPTY FIELD. If Jobber's payload did not carry the target
--     configuration, that is a failed read, not a value. Returns NO_ANSWER and writes
--     nothing, ever, regardless of p_allow_clear.
--  2. UNCHANGED IS NOT AN EDIT. The decision comes from sync.fn_shadow_decision against
--     the stored last-seen value, so the 419 never-touched zeros can never be copied.
--  3. OUR SIDE IS READ LIVE, INSIDE THIS FUNCTION, and the UPDATE is pinned to that value.
--     A caller's idea of what we hold may be minutes old. If it moved, we return RACE and
--     write nothing rather than overwriting a person's edit.
--  4. A FROZEN ROW IS UNTOUCHABLE. An open conflict is a question for a human; every
--     decision except IN_SYNC returns FROZEN. Checked here so the automated path returns
--     a status instead of tripping fn_record_shadow's exception, which would fail the
--     whole property replay and leave needs_populate set forever.
--  5. CLEARING NEEDS INTENT. An adopt to 0 or null is a legitimate human action and also
--     the most destructive write this sync can make: 69 properties and 47,732 gallons sit
--     one careless clear away. p_allow_clear defaults FALSE and the poll never passes true.
--  6. RANGE AND TYPE ARE CHECKED BEFORE THE WRITE, not left to the CHECK constraint, so a
--     bad value is a reported refusal rather than an exception that aborts a replay.
--
-- Refusals deliberately do NOT re-baseline the shadow. The edit stays pending and is
-- re-offered next pass, which is what makes a refusal recoverable instead of silently
-- swallowed. Same reasoning as the --limit deferral fix (1f169fa).
--
-- ============================================================================
-- ATTRIBUTION. Sets request.headers locally so audit.logs records adoptions as
-- 'jobber-custom-field-sync' rather than the 'jobber' label the rest of the poll writes
-- under. Without it an adoption is indistinguishable from an ordinary poll write, and the
-- conflict rule depends on being able to tell later who moved a value.
-- ⚠ is_local = true: it must not outlive this transaction and leak onto the caller's
-- other writes in the same request.
--
-- ============================================================================
-- GRANTS. Supabase's ALTER DEFAULT PRIVILEGES hands out EXECUTE nobody wrote: a new
-- function in `public` comes out authenticated-EXECUTABLE. This one writes a
-- compliance-adjacent column and bypasses RLS as SECURITY DEFINER, so PUBLIC, anon and
-- authenticated are revoked explicitly and only service_role keeps it. Asserted below with
-- has_function_privilege, which does not depend on who is asking.
--
-- AUDIT (rule 8): writes land on public.properties, which already carries the audit
-- trigger, so every adoption is captured with old_row/new_row. sync.source_field_shadow
-- stays opt-OUT as established in 2026-08-17_1636. Nothing added, nothing removed.
-- ============================================================================

do $guard$
begin
  if to_regprocedure('sync.fn_shadow_decision(boolean,jsonb,jsonb,jsonb,jsonb)') is null
     or to_regprocedure('sync.fn_record_shadow(text,bigint,text,text,text,jsonb,jsonb,jsonb)') is null then
    raise exception 'apply 2026-08-17_1636 and 2026-08-18_0120 first';
  end if;
  if pg_get_functiondef('sync.fn_record_shadow(text,bigint,text,text,text,jsonb,jsonb,jsonb)'::regprocedure)
       not like '%CONFLICT_FROZEN%' then
    raise exception '2026-08-18_0120 is not applied; the freeze this function relies on is absent';
  end if;
end
$guard$;

create or replace function public.fn_sync_property_custom_field(
  p_property_id    bigint,
  p_field_key      text,
  p_field_label    text,
  p_source_now     jsonb,
  p_source_present boolean,
  p_allow_clear    boolean default false
) returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_column      text;
  v_our_live    jsonb;
  v_our_int     integer;
  v_exists      boolean;
  v_source_seen jsonb;
  v_our_seen    jsonb;
  v_conflict_at timestamptz;
  v_decision    text;
  v_new_int     integer;
  v_updated     integer;
begin
  if p_property_id is null then return 'REFUSED:no property id'; end if;

  -- Resolve the target column from the CONFIGURATION GID, never from a label. Four numeric
  -- grease-trap fields exist in the account, two differ only by a capital S and one of those
  -- is archived, and "GT size" appears twice. An explicit CASE, no dynamic SQL: adding a
  -- second field means adding a branch here, which is reviewable, rather than letting a
  -- caller name any column it likes.
  v_column := case p_field_key
    when 'gid://Jobber/CustomFieldConfigurationNumeric/3061111' then 'grease_trap_size_gallons'
    else null end;
  if v_column is null then
    raise exception 'unsupported field_key %: add an explicit branch rather than widening this', p_field_key;
  end if;

  -- GUARD 1. A missing configuration in the payload is a failed read, not an empty field.
  if not coalesce(p_source_present, false) then
    return 'NO_ANSWER';
  end if;

  -- GUARD 3a. Our side, read HERE, not taken from the caller.
  select to_jsonb(p.grease_trap_size_gallons), p.grease_trap_size_gallons
    into v_our_live, v_our_int
    from public.properties p where p.id = p_property_id;
  if v_our_live is null and not exists (select 1 from public.properties where id = p_property_id) then
    return 'REFUSED:no such property';
  end if;

  select true, s.source_value, s.our_value, s.conflict_at
    into v_exists, v_source_seen, v_our_seen, v_conflict_at
    from sync.source_field_shadow s
   where s.entity_type = 'property' and s.entity_id = p_property_id
     and s.source_system = 'jobber' and s.field_key = p_field_key;

  v_decision := sync.fn_shadow_decision(
    coalesce(v_exists, false), p_source_now, v_source_seen, v_our_live, v_our_seen);

  -- GUARD 4. Frozen rows are a human's business. Returned, not raised, so one frozen
  -- property cannot fail its replay forever and pin needs_populate on.
  if v_conflict_at is not null and v_decision <> 'IN_SYNC' then
    return 'FROZEN';
  end if;

  if v_decision = 'ADOPT' then
    -- GUARD 5 + 6, before any write.
    if p_source_now is null or jsonb_typeof(p_source_now) = 'null' then
      if not p_allow_clear then return 'REFUSED:would clear (null)'; end if;
      v_new_int := null;
    else
      if jsonb_typeof(p_source_now) <> 'number' then
        return 'REFUSED:not a number: ' || p_source_now::text;
      end if;
      if (p_source_now #>> '{}')::numeric <> trunc((p_source_now #>> '{}')::numeric) then
        return 'REFUSED:not an integer: ' || p_source_now::text;
      end if;
      v_new_int := (p_source_now #>> '{}')::numeric::integer;
      if v_new_int < 0 or v_new_int > 20000 then
        return 'REFUSED:outside 0..20000: ' || v_new_int::text;
      end if;
      if v_new_int = 0 and not p_allow_clear then return 'REFUSED:would clear (0)'; end if;
    end if;

    perform set_config('request.headers', '{"x-app-source":"jobber-custom-field-sync"}', true);

    -- GUARD 3b. Pinned to the value decided against. A write landing between the read above
    -- and this UPDATE matches zero rows instead of clobbering whoever got there first.
    update public.properties
       set grease_trap_size_gallons = v_new_int
     where id = p_property_id
       and grease_trap_size_gallons is not distinct from v_our_int;
    get diagnostics v_updated = row_count;
    if v_updated <> 1 then return 'RACE'; end if;

    -- p_our_now is our PRE-adopt value. fn_record_shadow does the post-adopt substitution
    -- itself and stores adopted_from from this argument; passing the adopted value instead
    -- both destroys that provenance and makes the decision come back IN_SYNC.
    perform sync.fn_record_shadow('property', p_property_id, 'jobber', p_field_key,
                                  p_field_label, p_source_now, v_our_live, p_source_now);
    return 'ADOPT';
  end if;

  perform sync.fn_record_shadow('property', p_property_id, 'jobber', p_field_key,
                                p_field_label, p_source_now, v_our_live, null);
  return v_decision;
end
$function$;

revoke all on function public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean) from public;
revoke all on function public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean) from anon;
revoke all on function public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean) from authenticated;
grant execute on function public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean) to service_role;

comment on function public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean) is
  'The ONLY sanctioned writer of a Jobber custom field into public.properties. Adopts only a real change against sync.source_field_shadow. Returns SEED|IN_SYNC|IGNORE|ADOPT|CONFLICT|FROZEN|NO_ANSWER|RACE|REFUSED:<why>. service_role only.';

-- ============================================================================
-- VERIFY — grants, then every guard, on a sentinel property, rolled back at the end.
-- ============================================================================
do $verify$
declare
  k_key text := 'gid://Jobber/CustomFieldConfigurationNumeric/3061111';
  sig   text := 'public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean)';
  v_pid bigint;
  v_cid bigint;
  v_r   text;
  v_col integer;
  fail  text := '';
begin
  -- grants, via has_function_privilege so it does not depend on a role switch behaving
  if has_function_privilege('anon', sig, 'EXECUTE')          then fail := fail || 'anon holds EXECUTE; '; end if;
  if has_function_privilege('authenticated', sig, 'EXECUTE') then fail := fail || 'authenticated holds EXECUTE; '; end if;
  if not has_function_privilege('service_role', sig, 'EXECUTE') then fail := fail || 'service_role LACKS EXECUTE; '; end if;
  -- CONTROL: the privilege reader is alive (it says true for something)
  if not has_function_privilege('service_role', 'sync.fn_shadow_decision(boolean,jsonb,jsonb,jsonb,jsonb)', 'EXECUTE')
     then fail := fail || 'privilege reader looks dead; '; end if;
  if fail <> '' then raise exception 'GRANTS: %', fail; end if;

  select id into v_cid from public.clients order by id limit 1;
  insert into public.properties (client_id, address, city, state, is_primary, grease_trap_size_gallons)
  values (v_cid, 'PROBE 2026-08-18_0210', 'Miami', 'FL', false, 1500)
  returning id into v_pid;

  -- 1. no shadow row yet => SEED, adopt nothing
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'SEED' or v_col <> 1500 then fail := fail || format('1 SEED: got %s col %s; ', v_r, v_col); end if;

  -- 2. THE 69. Jobber still reads 0, we hold 1500 => IGNORE, and the 1500 survives.
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'IGNORE' or v_col <> 1500 then fail := fail || format('2 IGNORE: got %s col %s; ', v_r, v_col); end if;

  -- 3. a human types a value => ADOPT, our column moves, provenance kept
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '750'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'ADOPT' or v_col <> 750 then fail := fail || format('3 ADOPT: got %s col %s; ', v_r, v_col); end if;
  if (select adopted_from from sync.source_field_shadow
       where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key)
     <> '1500'::jsonb then fail := fail || '3 adopted_from lost the overwritten value; '; end if;

  -- 4. a missing configuration is NOT an empty field, even with clearing allowed
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', null, false, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'NO_ANSWER' or v_col <> 750 then fail := fail || format('4 NO_ANSWER: got %s col %s; ', v_r, v_col); end if;

  -- 5. clearing needs intent, and a refusal must NOT re-baseline
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r not like 'REFUSED:would clear%' or v_col <> 750 then fail := fail || format('5 clear-refusal: got %s col %s; ', v_r, v_col); end if;
  if (select source_value from sync.source_field_shadow
       where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key)
     <> '750'::jsonb then fail := fail || '5 a refusal re-baselined the shadow; '; end if;

  -- 5b. with intent, it clears
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'ADOPT' or v_col <> 0 then fail := fail || format('5b allow-clear: got %s col %s; ', v_r, v_col); end if;

  -- 6. out of range is a refusal, not an exception that would abort a replay
  update public.properties set grease_trap_size_gallons = 900 where id = v_pid;
  update sync.source_field_shadow set source_value = '0'::jsonb, our_value = '900'::jsonb
   where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key;
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '99999'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r not like 'REFUSED:outside%' or v_col <> 900 then fail := fail || format('6 range: got %s col %s; ', v_r, v_col); end if;

  -- 7. a frozen row is untouchable, and is RETURNED not raised
  update sync.source_field_shadow set conflict_at = now(), conflict_count = 1
   where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key;
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '1200'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'FROZEN' or v_col <> 900 then fail := fail || format('7 FROZEN: got %s col %s; ', v_r, v_col); end if;
  update sync.source_field_shadow set conflict_at = null, conflict_count = 0
   where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key;

  -- 8. CONTROL: unfrozen, the very same call adopts. Without this, step 7 would also pass
  --    on a function that refused everything.
  v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '1200'::jsonb, true);
  select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
  if v_r <> 'ADOPT' or v_col <> 1200 then fail := fail || format('8 control: got %s col %s; ', v_r, v_col); end if;

  -- 9. attribution actually lands on the audit row
  if not exists (select 1 from audit.logs
                  where table_name = 'properties' and app_source = 'jobber-custom-field-sync'
                    and (new_row->>'id')::bigint = v_pid)
     then fail := fail || '9 no audit row attributed to jobber-custom-field-sync; '; end if;

  -- 10. an unknown field_key raises rather than guessing a column
  begin
    v_r := public.fn_sync_property_custom_field(v_pid, 'gid://Jobber/Nope/1', 'probe', '1'::jsonb, true);
    fail := fail || '10 unknown field_key did not raise; ';
  exception when others then null;
  end;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise exception 'VERIFY_OK_ROLLBACK';
exception
  when others then
    if sqlerrm = 'VERIFY_OK_ROLLBACK' then
      raise notice 'all 10 checks passed; sentinel rolled back';
    else
      raise;
    end if;
end
$verify$;

-- The sentinel must not exist, and no real property may have moved.
select (select count(*) from public.properties where address = 'PROBE 2026-08-18_0210')          as sentinel_must_be_0,
       (select count(*) from sync.source_field_shadow)                                            as shadow_rows,
       (select count(*) from sync.source_field_shadow where conflict_at is not null)               as open_conflicts,
       (select count(*) from public.properties where grease_trap_size_gallons is not null)         as sized,
       (select coalesce(sum(grease_trap_size_gallons),0) from public.properties)                   as gallons,
       has_function_privilege('authenticated','public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean)','EXECUTE') as authenticated_execute_must_be_false,
       has_function_privilege('service_role','public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean)','EXECUTE')  as service_role_execute_must_be_true;
