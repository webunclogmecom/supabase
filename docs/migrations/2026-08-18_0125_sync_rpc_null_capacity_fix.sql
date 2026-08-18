-- ============================================================================
-- 2026-08-18_0125 - the RPC could not record a property whose capacity is NULL
-- ============================================================================
-- Same-night fix to 2026-08-18_0210. Found by checking, after the live cron proved the
-- happy path, whether the RPC had actually run for ALL ten replayed properties rather than
-- only for the one that adopted. It had not: six of ten recorded a shadow, and the three
-- with a shadow row that were skipped all had one thing in common.
--
-- THE DEFECT. to_jsonb(NULL::integer) is SQL NULL, **not** JSON null.
-- sync.source_field_shadow.our_value is NOT NULL. So on any property where we hold no
-- capacity the function read v_our_live = SQL NULL, passed it to fn_record_shadow, and the
-- upsert raised 23502. That is 353 of 458 linked properties, the MAJORITY of the fleet.
--
-- WHY IT LOOKED HEALTHY. handleProperty wraps the custom-field call so a failure there can
-- never fail the property sync, which is the right call and also what hid this: the replay
-- returned 200, needs_populate cleared, sync_log said success, and the shadow silently never
-- moved. The only trace was a console.error in the edge logs. The feature was inert for
-- three quarters of the fleet while every dashboard read green.
--
-- WHY MY OWN VERIFY MISSED IT. 2026-08-18_0210 ships ten assertions, and every one of them
-- ran against a sentinel property created WITH a capacity of 1500. The NULL baseline was
-- never exercised. This is exactly the trap already recorded in CLAUDE.md under "Verifying a
-- TRIGGER GUARD": a guard predicated on a value can only fire from one baseline, so test
-- every baseline, not one cell per variable. I wrote that warning down and then walked into
-- it, which is why the VERIFY below now runs the SAME sequence twice, once from each
-- baseline, and asserts the NULL one specifically.
--
-- The JS caller was never affected: jlit(null) is JSON.stringify(null) = 'null'::jsonb,
-- a JSON null, which is what the column expects. The regression was introduced by the RPC
-- and only by the RPC.
--
-- BODY BELOW IS THE LIVE pg_get_functiondef OUTPUT, patched programmatically: the dump was
-- asserted to contain its anchors, the replacement asserted to match exactly once, and the
-- diff asserted to touch exactly four lines. Nothing else moved.
--
-- AUDIT (rule 8): unchanged. Writes land on public.properties, which is audited. The shadow
-- table stays opt-OUT as set in 2026-08-17_1636.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_property_custom_field(p_property_id bigint, p_field_key text, p_field_label text, p_source_now jsonb, p_source_present boolean, p_allow_clear boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- ð to_jsonb(NULL::integer) IS SQL NULL, **NOT** JSON null. source_field_shadow.our_value
  -- is NOT NULL, so passing it straight through raised 23502 for every property where we
  -- hold no capacity: 353 of 458, the majority of the fleet. The property sync swallowed the
  -- error and carried on, so the shadow simply never recorded and the sync was inert there
  -- while looking healthy. coalesce to a JSON null, which is what the JS caller's
  -- JSON.stringify(null) has always produced and what the column expects.
  select coalesce(to_jsonb(p.grease_trap_size_gallons), 'null'::jsonb), p.grease_trap_size_gallons
    into v_our_live, v_our_int
    from public.properties p where p.id = p_property_id;
  if not found then return 'REFUSED:no such property'; end if;

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
$function$
;

-- ============================================================================
-- VERIFY - the SAME sequence from BOTH baselines. The null one is the regression.
-- ============================================================================
do $verify$
declare
  k_key text := 'gid://Jobber/CustomFieldConfigurationNumeric/3061111';
  v_cid bigint;
  v_pid bigint;
  v_r   text;
  v_col integer;
  v_our jsonb;
  fail  text := '';
  baseline integer;
begin
  select id into v_cid from public.clients order by id limit 1;

  -- run the identical script twice: capacity NULL, then capacity 1500
  foreach baseline in array array[null, 1500]::integer[]
  loop
    insert into public.properties (client_id, address, city, state, is_primary, grease_trap_size_gallons)
    values (v_cid, 'PROBE 2026-08-18_0125', 'Miami', 'FL', false, baseline)
    returning id into v_pid;

    -- 1. SEED must succeed and must RECORD, which is the whole bug: it used to raise 23502
    --    when baseline was null, so no row appeared at all.
    v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true);
    if v_r <> 'SEED' then
      fail := fail || format('[baseline %s] SEED returned %s; ', coalesce(baseline::text,'NULL'), v_r);
    end if;
    if not exists (select 1 from sync.source_field_shadow
                    where entity_type='property' and entity_id=v_pid
                      and source_system='jobber' and field_key=k_key) then
      fail := fail || format('[baseline %s] NO SHADOW ROW WAS RECORDED; ', coalesce(baseline::text,'NULL'));
    end if;

    -- our_value must be a JSON null, never SQL NULL
    select our_value into v_our from sync.source_field_shadow
     where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key;
    if baseline is null and v_our is distinct from 'null'::jsonb then
      fail := fail || format('[baseline NULL] our_value is %s, expected JSON null; ', coalesce(v_our::text,'SQL NULL'));
    end if;
    if baseline is not null and v_our <> to_jsonb(baseline) then
      fail := fail || format('[baseline %s] our_value is %s; ', baseline, coalesce(v_our::text,'SQL NULL'));
    end if;

    -- 2. the 69: jobber still 0, unchanged => IGNORE, and it must still record
    v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '0'::jsonb, true);
    if v_r <> 'IGNORE' then
      fail := fail || format('[baseline %s] IGNORE returned %s; ', coalesce(baseline::text,'NULL'), v_r);
    end if;

    -- 3. a human types a value => ADOPT. From a NULL baseline this is a pure gain.
    v_r := public.fn_sync_property_custom_field(v_pid, k_key, 'probe', '900'::jsonb, true);
    select grease_trap_size_gallons into v_col from public.properties where id = v_pid;
    if v_r <> 'ADOPT' or v_col <> 900 then
      fail := fail || format('[baseline %s] ADOPT returned %s col %s; ', coalesce(baseline::text,'NULL'), v_r, v_col);
    end if;
    -- provenance must record what we actually held, including "nothing"
    select adopted_from into v_our from sync.source_field_shadow
     where entity_type='property' and entity_id=v_pid and source_system='jobber' and field_key=k_key;
    if baseline is null and v_our is distinct from 'null'::jsonb then
      fail := fail || format('[baseline NULL] adopted_from is %s, expected JSON null; ', coalesce(v_our::text,'SQL NULL'));
    end if;
    if baseline is not null and v_our <> to_jsonb(baseline) then
      fail := fail || format('[baseline %s] adopted_from is %s; ', baseline, coalesce(v_our::text,'SQL NULL'));
    end if;
  end loop;

  -- 4. a property that does not exist is still refused cleanly (the `if not found` path)
  v_r := public.fn_sync_property_custom_field(-987654321, k_key, 'probe', '5'::jsonb, true);
  if v_r <> 'REFUSED:no such property' then
    fail := fail || format('missing property returned %s; ', v_r);
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise exception 'VERIFY_OK_ROLLBACK';
exception
  when others then
    if sqlerrm = 'VERIFY_OK_ROLLBACK' then
      raise notice 'both baselines pass, including capacity NULL';
    else
      raise;
    end if;
end
$verify$;

-- Nothing may survive, and the fleet must be untouched.
select (select count(*) from public.properties where address = 'PROBE 2026-08-18_0125')      as sentinel_must_be_0,
       (select count(*) from sync.source_field_shadow)                                        as shadow_rows,
       (select count(*) from sync.source_field_shadow where conflict_at is not null)           as open_conflicts,
       (select coalesce(sum(grease_trap_size_gallons),0) from public.properties)               as gallons,
       has_function_privilege('authenticated','public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean)','EXECUTE') as authenticated_execute_must_be_false,
       has_function_privilege('service_role','public.fn_sync_property_custom_field(bigint,text,text,jsonb,boolean,boolean)','EXECUTE')  as service_role_execute_must_be_true;
