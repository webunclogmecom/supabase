-- 2026-09-02_1000_property_lock_box_key.sql
--
-- WHY. Fred, on the Client App property edit modal: "I need to add a property called
-- Lock Box / Key because even though you display it on the reading, at the modal where you
-- edit is none."
--
-- WHERE HE READS IT: JOBBER, not one of our apps. Measured before building anything, because
-- the premise decides the design:
--   * live bundles of the Client App and the Field Portal contain "Lock Box" / "Lockbox"
--     ZERO times (controls: 3,460 and 2,396 string literals, and the same sweep finds
--     city_emails 7x and "Grease trap size" 4x, so the instrument was not broken)
--   * no app doc mentions one
--   * Jobber DOES have it: customFieldConfigurations returns `Lock Box/Key`, TEXT,
--     ALL_PROPERTIES, not archived, config 3061112, sitting directly beside
--     `Grease Trap size` 3061111.
-- So the field exists upstream and we simply never stored it.
--
-- MEASURED ON LIVE JOBBER (490 properties swept): 46 carry a value, lengths 3 to 6, no
-- newlines, and 18 of the 46 are literally "N/A". One of the real ones is "2707", which is
-- also sitting in that property's free-text access_notes as "Lockbox code: 2707" -- the same
-- fact typed twice in two places, which is the actual problem this field solves.
--
-- FRED'S DECISION (asked, because it changes the work): mirror Jobber and stay editable here.
-- That is the Grease Trap size pattern exactly, including its accepted cost: there is no
-- outbound push, so an edit made in our app does not reach Jobber and the two diverge until
-- someone edits in Jobber, whose change then adopts. Documented at the RPC and in the app docs.
--
-- WHAT THIS MIGRATION DOES
--   1. public.properties.lock_box_key text, with a shape CHECK.
--   2. public.fn_sync_property_custom_field gains a TEXT branch and the 3061112 GID.
--   3. client.update_property_operational accepts and writes lock_box_key.
-- Both function bodies were COPIED from the live objects and edited by anchored replacement
-- (CLAUDE.md rule); the numeric grease-trap path is byte-identical, verified by diff.
--
-- NOT IN THIS MIGRATION, on purpose, because each is separately verifiable:
--   * the backfill of the 28 real values (a script run, after this lands)
--   * webhook-jobber handleProperty passing the new field on every property replay
--   * the Client App modal input
--
-- RULE 8 -- AUDIT: no decision needed. public.properties already carries an audit.log_change
-- trigger (verified: 1), and ADR 010 says a new column on an already-audited table is
-- captured automatically by the full-row JSONB. Nothing to opt in or out of.
--
-- ROLLBACK: the column is additive and nothing reads it yet outside these two functions.

alter table public.properties
  add column if not exists lock_box_key text;

comment on column public.properties.lock_box_key is
  'Lock box or key code for this property. Mirrors the Jobber ALL_PROPERTIES text custom field "Lock Box/Key" (config 3061112) through sync.source_field_shadow, the same path the grease trap size uses. Editable in the Client App (Fred, 2026-09-02); an edit here is NOT pushed to Jobber, so a later Jobber-side edit wins. "N/A" is refused by the sync rather than stored: 18 of the 46 populated Jobber values were that placeholder when this shipped.';

-- Shape only, deliberately not a format: a lock box code is whatever the site uses
-- ("2707", "4066#", "C1709x" are all real). What is NOT acceptable is an empty-but-present
-- string, a control character, or something long enough to be a paragraph of notes.
alter table public.properties
  drop constraint if exists properties_lock_box_key_shape_chk;
alter table public.properties
  add constraint properties_lock_box_key_shape_chk
  check (
    lock_box_key is null
    or (btrim(lock_box_key) <> ''
        and length(lock_box_key) <= 100
        and lock_box_key !~ '[[:cntrl:]]')
  );

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
  v_our_text    text;
  v_new_text    text;
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
    -- 2026-09-02. Lock Box/Key, ALL_PROPERTIES TEXT field, config 3061112. It sits directly
    -- beside Grease Trap size (3061111) in the same account. Bound by GID, never by label.
    when 'gid://Jobber/CustomFieldConfigurationText/3061112'    then 'lock_box_key'
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
  if v_column = 'grease_trap_size_gallons' then
    select coalesce(to_jsonb(p.grease_trap_size_gallons), 'null'::jsonb), p.grease_trap_size_gallons
      into v_our_live, v_our_int
      from public.properties p where p.id = p_property_id;
  else
    select coalesce(to_jsonb(p.lock_box_key), 'null'::jsonb), p.lock_box_key
      into v_our_live, v_our_text
      from public.properties p where p.id = p_property_id;
  end if;
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
    if v_column = 'lock_box_key' then
      -- TEXT branch, same shape as the numeric one below: refuse rather than write anything
      -- we cannot justify, and never clear unless the caller explicitly allows it.
      if p_source_now is null or jsonb_typeof(p_source_now) = 'null' then
        if not p_allow_clear then return 'REFUSED:would clear (null)'; end if;
        v_new_text := null;
      else
        if jsonb_typeof(p_source_now) <> 'string' then
          return 'REFUSED:not a string: ' || p_source_now::text;
        end if;
        v_new_text := btrim(p_source_now #>> '{}');
        if v_new_text = '' then
          if not p_allow_clear then return 'REFUSED:would clear (empty)'; end if;
          v_new_text := null;
        elsif v_new_text ~* '^n/?a$' then
          -- MEASURED 2026-09-02 against live Jobber: 18 of the 46 populated values are
          -- literally "N/A", 39% of them. That is the TEXT sentinel for "no lock box",
          -- exactly as 0 is the numeric one, and adopting it would put the string N/A in
          -- front of a driver looking for a code. Refused and deliberately NOT recorded in
          -- the shadow, so it is re-evaluated the moment somebody types a real code.
          return 'REFUSED:placeholder value: ' || v_new_text;
        elsif length(v_new_text) > 100 then
          -- Measured range of real values is 3 to 6 characters; 100 is a guard, not a fit.
          return 'REFUSED:longer than 100 chars';
        elsif v_new_text ~ '[[:cntrl:]]' then
          return 'REFUSED:contains a control character';
        end if;
      end if;

      perform set_config('request.headers', '{"x-app-source":"jobber-custom-field-sync"}', true);

      -- GUARD 3b, same as the numeric branch: pinned to the value decided against, so a
      -- write landing between the read and here matches zero rows instead of clobbering it.
      update public.properties
         set lock_box_key = v_new_text
       where id = p_property_id
         and lock_box_key is not distinct from v_our_text;
      get diagnostics v_updated = row_count;
      if v_updated <> 1 then return 'RACE'; end if;

      perform sync.fn_record_shadow('property', p_property_id, 'jobber', p_field_key,
                                    p_field_label, p_source_now, v_our_live, p_source_now);
      return 'ADOPT';
    end if;

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

CREATE OR REPLACE FUNCTION client.update_property_operational(p_property_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    -- 2026-09-02. Lock Box/Key. Jobber holds this as an ALL_PROPERTIES text custom field
    -- (config 3061112) and it is mirrored into public.lock_box_key by the same shadow sync
    -- that carries the grease trap size. EDITABLE HERE ON PURPOSE (Fred, 2026-09-02), with
    -- the same consequence the capacity field already has: outbound push to Jobber does not
    -- exist, so an edit made here stays here until somebody edits it in Jobber, which then
    -- wins. That is a known, accepted divergence, not an oversight.
    'lock_box_key',
    -- RETIRED 2026-08-07 (Fred: "remove the Default disposal facility, we don't need that").
    -- Deliberately STILL ACCEPTED so a cached bundle that keeps sending the key is not
    -- refused mid-save; it is simply no longer WRITTEN (see the UPDATE list below).
    -- Measured before removing it: 0 of 856 properties ever carried a value.
    'default_disposal_facility_id',
    'access_schedule'  -- NEW 2026-07-30_2103: per-day windows
  ];
  -- The ONLY vocabulary public.properties.access_days uses (verified: 201 rows,
  -- 0 non-conforming). Long names are accepted as ALIASES and normalised down,
  -- so a stale client cannot introduce a second vocabulary.
  v_days     text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_bad      text[];
  v_row      public.properties;
  v_in       text[];
  v_norm     text[];
  v_d        text;
  v_sched    jsonb;
  v_k        text;
  v_open     text;
  v_close    text;
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
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for properties: %. Wave 1 allows only %. Address fields are Jobber-owned and geofence/lat/long are Samsara-owned; both would be reverted by the inbound sync.',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BUG 1 FIX. Type check first, then VALUE check. The old version stopped at
  -- the type check, which is how ["Monday","Tuesday"] was accepted.
  if p_patch ? 'access_days' then
    if jsonb_typeof(p_patch->'access_days') not in ('array','null') then
      raise exception 'access_days must be a JSON array of day codes (got %)',
        jsonb_typeof(p_patch->'access_days') using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch->'access_days') = 'array' then
      select array_agg(x) into v_in from jsonb_array_elements_text(p_patch->'access_days') x;
      v_norm := array[]::text[];
      foreach v_d in array coalesce(v_in, array[]::text[]) loop
        -- ⚠ A JSON null becomes SQL NULL here, and `NULL <> all(v_days)` evaluates
        -- to NULL rather than true, so the check below would NOT fire and the NULL
        -- would land in the text[]. Caught by the fix's own test run. Reject first.
        if v_d is null then
          raise exception 'access_days cannot contain a null entry' using errcode = '22023';
        end if;
        v_d := lower(btrim(v_d));
        -- accept the long form as an alias, store the canonical short code
        v_d := case v_d
                 when 'monday' then 'mon' when 'tuesday'   then 'tue'
                 when 'wednesday' then 'wed' when 'thursday' then 'thu'
                 when 'friday' then 'fri' when 'saturday'  then 'sat'
                 when 'sunday' then 'sun' else v_d end;
        if v_d <> all (v_days) then
          raise exception 'access_days: % is not a valid day. Use %', v_d, v_days
            using errcode = '22023';
        end if;
        if v_d <> all (v_norm) then v_norm := v_norm || v_d; end if;  -- de-dup
      end loop;
    end if;
  end if;


  -- NEW: access_schedule validation. Object; keys in mon..sun; values
  -- {open:"HH:MM", close:"HH:MM"} 24h. Overnight open>close is legal (into the
  -- next morning), exactly like the legacy single window.
  if p_patch ? 'access_schedule' then
    if jsonb_typeof(p_patch->'access_schedule') = 'null' then
      v_sched := null;
    elsif jsonb_typeof(p_patch->'access_schedule') <> 'object' then
      raise exception 'access_schedule must be an object keyed by day (mon..sun)'
        using errcode = '22023';
    else
      v_sched := p_patch->'access_schedule';
      for v_k in select jsonb_object_keys(v_sched) loop
        if v_k <> all (v_days) then
          raise exception 'access_schedule: % is not a valid day key. Use %', v_k, v_days
            using errcode = '22023';
        end if;
        v_open  := v_sched->v_k->>'open';
        v_close := v_sched->v_k->>'close';
        if v_open is null or v_close is null
           or v_open  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'access_schedule.%: open/close must be 24h "HH:MM" strings', v_k
            using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- A patch that carries the legacy access keys but NO access_schedule can no
  -- longer be honoured: there is nowhere to put it. Silently ignoring it would show
  -- the user "saved" while discarding the edit, so it raises. Only reachable from a
  -- browser tab cached from before access_schedule shipped (2026-07-30); the live
  -- Client App always sends all four keys together (verified in the published bundle).
  if (p_patch ? 'access_hours_start' or p_patch ? 'access_hours_end' or p_patch ? 'access_days')
     and not (p_patch ? 'access_schedule') then
    raise exception 'access hours are now set through access_schedule -- reload the app'
      using errcode = '22023';
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    -- access_hours_start / access_hours_end / access_days were DROPPED by this
    -- migration. The keys remain ACCEPTED above (removing one makes this RPC refuse
    -- the whole patch, breaking every save from a cached bundle) and are now ignored;
    -- access_schedule is the single store. A legacy-ONLY patch is rejected loudly by
    -- the guard above rather than silently discarded.
    access_schedule = case when p_patch ? 'access_schedule' then v_sched
                           else p.access_schedule end,
    access_notes = case when p_patch ? 'access_notes'
                        then nullif(p_patch->>'access_notes','') else p.access_notes end,
    notes = case when p_patch ? 'notes'
                 then nullif(p_patch->>'notes','') else p.notes end,
    grease_trap_manhole_count = case when p_patch ? 'grease_trap_manhole_count'
                                     then (p_patch->>'grease_trap_manhole_count')::integer
                                     else p.grease_trap_manhole_count end,
    sample_port_count = case when p_patch ? 'sample_port_count'
                             then nullif(p_patch->>'sample_port_count','')::integer
                             else p.sample_port_count end,
    -- btrim then nullif: a field cleared to spaces in the UI stores NULL, not '   ',
    -- so "no lock box" has exactly one representation.
    lock_box_key = case when p_patch ? 'lock_box_key'
                        then nullif(btrim(p_patch->>'lock_box_key'),'')
                        else p.lock_box_key end
  where p.id = p_property_id
  returning p.* into v_row;

  if not found then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$function$

;

-- ---------------------------------------------------------------------------
-- VERIFY. All mutations sit inside a BEGIN..EXCEPTION block, which is a real SAVEPOINT:
-- the deliberate RAISE unwinds them while the DDL above stays committed. Findings are
-- collected OUTSIDE that block, because variable assignments are not transactional.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  fails  text := '';
  notes  text := '';
  gt_key text := 'gid://Jobber/CustomFieldConfigurationNumeric/3061111';
  lb_key text := 'gid://Jobber/CustomFieldConfigurationText/3061112';
  v_p    bigint;
  r      text;
  j      jsonb;
  v_val  text;
  v_ok   boolean;
BEGIN
  -- 1. the column exists and is text
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='properties'
                    AND column_name='lock_box_key' AND data_type='text') THEN
    fails := fails || '1: lock_box_key missing or not text; ';
  END IF;

  -- 2. the constraint is VALIDATED, not NOT VALID (the column is empty, so it must be)
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname='properties_lock_box_key_shape_chk' AND convalidated) THEN
    fails := fails || '2: shape constraint missing or NOT VALID; ';
  END IF;

  BEGIN
    SELECT p.id INTO v_p FROM public.properties p
      WHERE p.deleted_at IS NULL AND p.lock_box_key IS NULL ORDER BY p.id DESC LIMIT 1;
    IF v_p IS NULL THEN fails := fails || 'no subject property; '; END IF;
    notes := notes || format('subject=property %s | ', v_p);

    -- 3. CONSTRAINT MUTATION TABLE. A constraint nobody tried to break is untested.
    FOR v_val, v_ok IN
      SELECT * FROM (VALUES
        ('2707',            true),      -- a real code
        ('C1709x',          true),      -- a real code, letters and digits
        ('4066#',           true),      -- a real code with punctuation
        (NULL,              true),      -- absent is legal
        ('',                false),     -- present but empty is not
        ('   ',             false),     -- whitespace-only is not
        (repeat('x', 101),  false),     -- too long
        (chr(49)||chr(10)||chr(50), false)  -- control character
      ) AS t(val, should_pass)
    LOOP
      BEGIN
        UPDATE public.properties SET lock_box_key = v_val WHERE id = v_p;
        IF NOT v_ok THEN
          fails := fails || format('3: constraint ACCEPTED %L; ', v_val);
        END IF;
      EXCEPTION WHEN check_violation THEN
        IF v_ok THEN
          fails := fails || format('3: constraint REFUSED %L; ', v_val);
        END IF;
      END;
    END LOOP;
    UPDATE public.properties SET lock_box_key = NULL WHERE id = v_p;

    -- 4. an unsupported field_key still raises rather than guessing a column
    BEGIN
      PERFORM public.fn_sync_property_custom_field(v_p, 'gid://Jobber/Nope/1', 'Nope', to_jsonb('x'::text), true);
      fails := fails || '4: an unknown field_key did not raise; ';
    EXCEPTION WHEN others THEN
      IF SQLERRM NOT LIKE '%unsupported field_key%' THEN
        fails := fails || format('4: wrong error for unknown field_key: %s; ', SQLERRM);
      END IF;
    END;

    -- 5. THE POINT OF THIS MIGRATION: a real Jobber string adopts into the column.
    --    ⚠ TWO CALLS, and the first one is NOT an adoption. A (property, field) pair with no
    --    shadow row SEEDS silently and writes nothing: "unchanged" means "not an edit"
    --    whatever the value, which is the whole reason the shadow exists. An earlier draft of
    --    this block asserted ADOPT on the first call and was correctly rejected by this
    --    VERIFY. It also means the 46 values already in Jobber will NOT arrive through the
    --    ongoing sync: they need the deliberate backfill, which is a separate step.
    r := public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key', to_jsonb('2707'::text), true);
    IF r <> 'SEED' THEN fails := fails || format('5: the first call returned %s, expected SEED; ', r); END IF;
    IF (SELECT lock_box_key FROM public.properties WHERE id=v_p) IS NOT NULL THEN
      fails := fails || '5b: the seeding call WROTE, and it must not; ';
    END IF;

    r := public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key', to_jsonb('C1709x'::text), true);
    IF r <> 'ADOPT' THEN fails := fails || format('5c: a changed source returned %s; ', r); END IF;
    IF (SELECT lock_box_key FROM public.properties WHERE id=v_p) IS DISTINCT FROM 'C1709x' THEN
      fails := fails || '5d: the column did not receive the adopted value; ';
    END IF;

    -- 6. "N/A" is refused, not stored. 18 of the 46 live Jobber values are exactly this.
    --    The source is now seen as C1709x, so each of these is a genuine source-side change
    --    and does reach the adopt branch rather than being dismissed as unchanged.
    FOREACH v_val IN ARRAY ARRAY['N/A','n/a','na','NA'] LOOP
      IF public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key', to_jsonb(v_val), true)
         NOT LIKE 'REFUSED:placeholder%' THEN
        fails := fails || format('6: %L was not treated as a placeholder; ', v_val);
      END IF;
    END LOOP;
    IF (SELECT lock_box_key FROM public.properties WHERE id=v_p) IS DISTINCT FROM 'C1709x' THEN
      fails := fails || '6b: a placeholder overwrote the real value; ';
    END IF;

    -- 7. a non-string, an empty string and a control character are all refused
    IF public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key', to_jsonb(190), true)
       NOT LIKE 'REFUSED:not a string%' THEN fails := fails || '7: a number was not refused; '; END IF;
    IF public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key', to_jsonb(''::text), true)
       NOT LIKE 'REFUSED:would clear%' THEN fails := fails || '7b: an empty string was not refused; '; END IF;
    IF public.fn_sync_property_custom_field(v_p, lb_key, 'Lock Box/Key',
         to_jsonb((chr(49)||chr(10)||chr(50))::text), true)
       NOT LIKE 'REFUSED:contains a control%' THEN fails := fails || '7c: a newline was not refused; '; END IF;

    -- 8. POSITIVE CONTROL: the numeric grease-trap path still works. Without this, every
    --    assertion above could pass while the field this function already served was broken.
    UPDATE public.properties SET grease_trap_size_gallons = NULL WHERE id = v_p;
    DELETE FROM sync.source_field_shadow
      WHERE entity_type='property' AND entity_id=v_p AND field_key=gt_key;
    r := public.fn_sync_property_custom_field(v_p, gt_key, 'Grease Trap size', to_jsonb(1800), true);
    IF r <> 'SEED' THEN fails := fails || format('8: the grease-trap first call returned %s; ', r); END IF;
    r := public.fn_sync_property_custom_field(v_p, gt_key, 'Grease Trap size', to_jsonb(2500), true);
    IF r <> 'ADOPT' THEN fails := fails || format('8a: the grease-trap path returned %s; ', r); END IF;
    IF (SELECT grease_trap_size_gallons FROM public.properties WHERE id=v_p) <> 2500 THEN
      fails := fails || '8b: the grease-trap column did not receive 2500; ';
    END IF;
    IF public.fn_sync_property_custom_field(v_p, gt_key, 'Grease Trap size', to_jsonb('2707'::text), true)
       NOT LIKE 'REFUSED:not a number%' THEN
      fails := fails || '8c: the grease-trap path accepted a string; ';
    END IF;

    -- 9. the app's write path. Simulated staff JWT, because the RPC gates on auth.uid()
    --    and the email domain; as postgres without this it raises 28000.
    PERFORM set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000001","email":"verify@ayache.com"}', true);
    j := client.update_property_operational(v_p, '{"lock_box_key":"A-14"}'::jsonb);
    IF (SELECT lock_box_key FROM public.properties WHERE id=v_p) IS DISTINCT FROM 'A-14' THEN
      fails := fails || '9: the RPC did not write lock_box_key; ';
    END IF;
    IF NOT (j ? 'lock_box_key') THEN
      fails := fails || '9b: the returned row does not carry lock_box_key; ';
    END IF;
    PERFORM client.update_property_operational(v_p, '{"lock_box_key":"   "}'::jsonb);
    IF (SELECT lock_box_key FROM public.properties WHERE id=v_p) IS NOT NULL THEN
      fails := fails || '9c: a whitespace-only value was stored instead of NULL; ';
    END IF;
    BEGIN
      PERFORM client.update_property_operational(v_p, '{"latitude":1}'::jsonb);
      fails := fails || '9d: an unsupported key was accepted; ';
    EXCEPTION WHEN others THEN
      IF SQLERRM NOT LIKE '%unsupported field%' THEN
        fails := fails || format('9e: wrong error for an unsupported key: %s; ', SQLERRM);
      END IF;
    END;

    RAISE EXCEPTION 'ROLLBACK_PROBE';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ROLLBACK_PROBE' THEN
      fails := fails || format('UNEXPECTED %s: %s; ', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- 10. the probe left nothing behind
  IF EXISTS (SELECT 1 FROM public.properties WHERE lock_box_key IS NOT NULL) THEN
    fails := fails || '10: a lock_box_key survived the rollback; ';
  END IF;

  -- 11. grants unchanged
  IF NOT has_function_privilege('authenticated','client.update_property_operational(bigint, jsonb)','EXECUTE') THEN
    fails := fails || '11: authenticated lost EXECUTE on the operational RPC; ';
  END IF;
  IF has_function_privilege('anon','public.fn_sync_property_custom_field(bigint, text, text, jsonb, boolean, boolean)','EXECUTE') THEN
    fails := fails || '11b: anon can EXECUTE the sync function; ';
  END IF;

  IF fails <> '' THEN
    RAISE EXCEPTION 'VERIFY FAILED >>> % [%]', fails, notes;
  END IF;
  RAISE NOTICE 'VERIFY OK >>> %', notes;
END $verify$;
