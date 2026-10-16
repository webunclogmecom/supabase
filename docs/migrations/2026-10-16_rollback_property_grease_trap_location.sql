-- ============================================================================
-- ROLLBACK of 2026-10-16_1530_property_grease_trap_location
-- Revert the Client App FIRST (Edit property sends grease_trap_location; without the key in the allowlist the RPC
-- refuses the whole patch, so every property save would fail).
-- The function goes back to its pre-1530 body (the live definition taken 2026-10-16, md5
-- 0ef7a1b6bce69ef74231eddb45c3cce9). A view cannot lose a column through CREATE OR REPLACE, so it is dropped and
-- recreated with its pre-1530 definition, and its grants are put back and checked.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE acl_rb ON COMMIT DROP AS
  SELECT (SELECT array_agg(x ORDER BY x) FROM unnest(relacl::text[]) x) AS v FROM pg_class WHERE oid = 'client.properties'::regclass;

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
$function$;

DROP VIEW client.properties;
create view client.properties as
SELECT id,
    client_id,
    name,
    address,
    city,
    state,
    zip,
    country,
    is_billing,
    created_at,
    updated_at,
    latitude,
    longitude,
    geofence_radius_meters,
    geofence_type,
    fn_sched_open(access_schedule) AS access_hours_start,
    fn_sched_close(access_schedule) AS access_hours_end,
    fn_sched_days(access_schedule) AS access_days,
    is_primary,
    notes,
    county,
    grease_trap_manhole_count,
    access_notes,
    default_disposal_facility_id,
    zone_id,
    sample_port_count,
    ( SELECT z.code
           FROM zones z
          WHERE (z.id = p.zone_id)) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE (j.property_id = p.id)))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE ((l.entity_type = 'property'::text) AND (l.source_system = 'jobber'::text) AND (l.entity_id = p.id)))) AS jobber_linked,
    COALESCE((grease_trap_size_gallons)::numeric, ( SELECT sc.equipment_size_gallons
           FROM v_client_agreement_services sc
          WHERE ((sc.property_id = p.id) AND (sc.service_type = 'Pumping'::text))
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    city_emails,
    lock_box_key
   FROM properties p
  WHERE (deleted_at IS NULL);
REVOKE ALL ON client.properties FROM PUBLIC;
GRANT SELECT ON client.properties TO authenticated, service_role, db_backup_reader;

ALTER TABLE public.properties DROP COLUMN grease_trap_location;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('client.update_property_operational(bigint,jsonb)'::regprocedure)) IS DISTINCT FROM '0ef7a1b6bce69ef74231eddb45c3cce9'
     OR md5(pg_get_viewdef('client.properties'::regclass)) IS DISTINCT FROM '521a860e7624a1cc94b9a0751c04c3ae' THEN
    RAISE EXCEPTION 'rollback: the function or the view is not back to its pre-1530 definition';
  END IF;
  IF (SELECT (SELECT array_agg(x ORDER BY x) FROM unnest(relacl::text[]) x) FROM pg_class WHERE oid = 'client.properties'::regclass) IS DISTINCT FROM (SELECT v FROM acl_rb) THEN
    RAISE EXCEPTION 'rollback: view grants differ: %', (SELECT relacl::text FROM pg_class WHERE oid = 'client.properties'::regclass);
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
