-- 2026-08-13_2130_property_city_email.sql
--
-- WHAT: surface the CITY INBOX on the property, and give it a write path.
--         - public.fn_city_regulator_emails(city)      -> the resolver, SECURITY DEFINER
--         - client.properties.city_emails              -> derived, so the app needs no extra fetch
--         - client.update_property_city_email(id, [])  -> the write, from the property card
--
-- WHY (Fred, 2026-08-13): "make it so the properties have a field called 'City email' so it's the
--      email we use to send emails to the city (currently disabled) ... shown below the Manholes on
--      the SITE section."
--
-- 🛑 THE VALUE ALREADY HAD A HOME, AND THAT CHANGED THE DESIGN. `public.municipality_regulators`
--      has existed since 2026-06-05 and is what `send-derm-email` ALREADY reads to resolve a city
--      recipient (target='city' loads every ACTIVE regulator, keys them by lower(municipality), and
--      matches each of the client's properties by `properties.city`). So the city inbox is a
--      property of the CITY, not of the restaurant, and a per-property column would have been a
--      second competing store for one fact.
--
--      What was actually missing was not a column - it was a MAINTENANCE SURFACE. The table is
--      granted to `postgres`, `service_role` and `yannick_readonly` only, so no app can read it, let
--      alone edit it. That is why it holds 2 rows and why the city send looks "disabled":
--
--          properties resolving to a city inbox today   108
--          properties total                             893      (88% dark)
--
--      Measured coverage per city - this is the argument for keeping it per-city, and Fred chose it
--      after seeing these numbers:
--
--          Miami Beach        248 properties / 125 clients      <- ONE row lights all 248
--          Miami              225 / 111
--          Surfside            71 /  36   (has a row today)
--          North Miami Beach   41 /  21
--          Hallandale Beach    37 /  19   (has a row today)
--
--      So: the FIELD lives on the property exactly where Fred asked, and the VALUE lives on the
--      municipality. The RPC returns properties_affected/clients_affected so the UI can say out loud
--      that this applies to every property in that city. Do NOT "fix" this into a per-property
--      column later without re-reading the paragraph above.
--
-- 🛑 THE RESOLVER IS `SECURITY DEFINER` ON PURPOSE, AND IT IS NOT OPTIONAL. It is called from inside
--      `client.properties`, which is a postgres-owned view WITHOUT security_invoker. A TABLE grant
--      launders through such a view; a SECURITY INVOKER FUNCTION CALLED INSIDE ONE DOES NOT - it
--      still runs with the CALLER's privileges and raises 42501. That exact asymmetry has bitten
--      this repo three times (fn_resolve_gdo_id, fn_visit_is_gdo_reporting, and the anon revoke).
--      `authenticated` holds NO grant on municipality_regulators and must not be given one, so the
--      function must be DEFINER with a pinned search_path. Assertion (D) exercises this as
--      `authenticated` with a control proving the direct read really is denied.
--
-- 🛑 CASE-INSENSITIVE MATCH, AND `ON CONFLICT` CANNOT DO IT. The UNIQUE is on the RAW text
--      (municipality_regulators_municipality_key UNIQUE (municipality)), so `ON CONFLICT
--      (municipality)` would NOT collide 'Miami Beach' with 'miami beach' - it would insert a SECOND
--      row. send-derm-email lower-cases when building its map, so the two rows collapse there and
--      whichever sorts last silently wins. The RPC therefore looks the row up on
--      lower(btrim(...)) and UPDATEs it, and only inserts when nothing matches. Assertion (F).
--
-- CLEARING: emails = {} sets status='INACTIVE' rather than deleting the row (rule #6, never
--      hard-delete). send-derm-email filters status='ACTIVE', so clearing genuinely stops the send.
--
-- AUDIT (ADR 010): public.municipality_regulators ALREADY carries audit_municipality_regulators ->
--      audit.log_change (verified in pg_trigger before writing this), so the new human-editable path
--      is captured with no trigger change. It also carries trg_municipality_regulators_updated_at,
--      so updated_at is trigger-managed - never set it by hand (rule #7).

BEGIN;

SET LOCAL search_path = public;

-- ---------------------------------------------------------------------------
-- 1. the resolver
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_city_regulator_emails(p_city text)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER            -- see the header: INVOKER here = 42501 inside client.properties
SET search_path = public, pg_temp
AS $function$
  SELECT r.emails
    FROM public.municipality_regulators r
   WHERE r.status = 'ACTIVE'
     AND lower(btrim(r.municipality)) = lower(btrim(p_city))
   ORDER BY r.id
   LIMIT 1
$function$;

COMMENT ON FUNCTION public.fn_city_regulator_emails(text) IS
  'The city inbox for a municipality name, matched case-insensitively and ACTIVE-only - the SAME '
  'resolution send-derm-email performs for target=''city''. SECURITY DEFINER because it is called '
  'from inside the owner-rights view client.properties, where an INVOKER function would raise 42501.';

REVOKE ALL ON FUNCTION public.fn_city_regulator_emails(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_city_regulator_emails(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_city_regulator_emails(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_city_regulator_emails(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. expose it on the view the app already reads.
--    Body COPIED VERBATIM from pg_get_viewdef('client.properties'); the ONLY change is the
--    city_emails expression APPENDED at the end. CREATE OR REPLACE (never DROP) so the existing
--    grants survive - dropping a view discards them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW client.properties AS
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
          WHERE z.id = p.zone_id) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE j.property_id = p.id))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE l.entity_type = 'property'::text AND l.source_system = 'jobber'::text AND l.entity_id = p.id)) AS jobber_linked,
    COALESCE(grease_trap_size_gallons::numeric, ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    public.fn_city_regulator_emails(p.city) AS city_emails
   FROM properties p;

-- ---------------------------------------------------------------------------
-- 3. the write path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION client.update_property_city_email(
  p_property_id bigint,
  p_emails      text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
declare
  v_city    text;
  v_state   text;
  v_county  text;
  v_clean   text[];
  v_bad     text;
  v_id      bigint;
  v_muni    text;
  v_props   int;
  v_clients int;
begin
  if p_property_id is null then
    raise exception 'A property id is required.' using errcode = '22023';
  end if;

  select btrim(p.city), coalesce(nullif(btrim(p.state), ''), 'FL'), p.county
    into v_city, v_state, v_county
    from public.properties p
   where p.id = p_property_id;

  if not found then
    raise exception 'Property % does not exist.', p_property_id using errcode = '22023';
  end if;

  if v_city is null or v_city = '' then
    raise exception 'This property has no city, so there is no city inbox to set. Add the address first.'
      using errcode = '22023';
  end if;

  -- normalise: trim, lowercase, drop blanks, de-duplicate, stable order
  select array_agg(e ORDER BY e)
    into v_clean
    from (select distinct lower(btrim(x)) as e
            from unnest(coalesce(p_emails, '{}'::text[])) as x
           where btrim(x) <> '') s;
  v_clean := coalesce(v_clean, '{}'::text[]);

  select e into v_bad
    from unnest(v_clean) e
   where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
   limit 1;
  if v_bad is not null then
    raise exception 'That does not look like an email address: %', v_bad using errcode = '22023';
  end if;

  -- 🛑 case-insensitive lookup, NOT ON CONFLICT - see the header
  select r.id into v_id
    from public.municipality_regulators r
   where lower(btrim(r.municipality)) = lower(btrim(v_city))
   order by r.id
   limit 1;

  if v_id is null then
    insert into public.municipality_regulators (municipality, state, county, emails, status)
    values (v_city, v_state, v_county, v_clean,
            case when cardinality(v_clean) > 0 then 'ACTIVE' else 'INACTIVE' end)
    returning id, municipality into v_id, v_muni;
  else
    update public.municipality_regulators r
       set emails = v_clean,
           status = case when cardinality(v_clean) > 0 then 'ACTIVE' else 'INACTIVE' end
     where r.id = v_id
    returning r.municipality into v_muni;
  end if;

  select count(*)::int, count(distinct p.client_id)::int
    into v_props, v_clients
    from public.properties p
   where lower(btrim(p.city)) = lower(btrim(v_city));

  return jsonb_build_object(
    'municipality',        v_muni,
    'emails',              to_jsonb(v_clean),
    'properties_affected', v_props,
    'clients_affected',    v_clients
  );
end;
$function$;

COMMENT ON FUNCTION client.update_property_city_email(bigint, text[]) IS
  'Sets the city inbox for the MUNICIPALITY the given property sits in, so it applies to every '
  'property in that city. Returns properties_affected/clients_affected so the UI can say so. '
  'Clearing sets status=INACTIVE rather than deleting the row.';

REVOKE ALL ON FUNCTION client.update_property_city_email(bigint, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_property_city_email(bigint, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_property_city_email(bigint, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_property_city_email(bigint, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. assertions. EXERCISE the behaviour; do not restate the statements above.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_emails text[]; n int; m int; v_res jsonb; v_before int; v_after int; v_ok boolean;
BEGIN
  -- (A) the resolver finds Surfside, and is case/whitespace insensitive. POSITIVE CONTROL:
  --     if this returns NULL the whole migration is untested, because every check below
  --     depends on the resolver being able to find anything at all.
  IF public.fn_city_regulator_emails('Surfside') IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: the resolver cannot find Surfside, which has an ACTIVE row';
  END IF;
  IF public.fn_city_regulator_emails('  sUrFsIdE ') IS DISTINCT FROM public.fn_city_regulator_emails('Surfside') THEN
    RAISE EXCEPTION 'the resolver is case/whitespace sensitive, so it will miss real rows';
  END IF;

  -- (B) NEGATIVE side. A city with no regulator must resolve to NULL, not to someone else's inbox.
  --     Without this, (A) passing is consistent with the function returning a constant.
  IF public.fn_city_regulator_emails('Nowhere Beach ' || md5(random()::text)) IS NOT NULL THEN
    RAISE EXCEPTION 'the resolver returned an inbox for a city that has none';
  END IF;

  -- (C) the view carries it, and carries it for the RIGHT properties. Two-sided.
  SELECT count(*) INTO n FROM client.properties WHERE city_emails IS NOT NULL;
  SELECT count(*) INTO m FROM client.properties;
  IF n = 0 THEN RAISE EXCEPTION 'no property resolves a city inbox - the view expression is not working'; END IF;
  IF n = m THEN RAISE EXCEPTION 'EVERY property resolved an inbox, which cannot be right with 2 regulator rows'; END IF;
  RAISE NOTICE 'city_emails populated on % of % properties', n, m;

  -- (D) 🛑 THE ONE THAT MATTERS. As `authenticated`, reading the view must WORK even though that
  --     role holds no grant on municipality_regulators. This is the SECDEF-inside-owner-view trap.
  --     The CONTROL is the direct read: it MUST be denied, otherwise the view is not laundering
  --     anything and this assertion proves nothing.
  IF has_table_privilege('authenticated', 'public.municipality_regulators', 'SELECT') THEN
    RAISE EXCEPTION 'CONTROL FAILED: authenticated can already SELECT municipality_regulators directly, '
                    'so the test below cannot show the function is doing the work';
  END IF;
  BEGIN
    SET LOCAL ROLE authenticated;
    SELECT city_emails INTO v_emails FROM client.properties
      WHERE lower(btrim(city)) = 'surfside' AND city_emails IS NOT NULL LIMIT 1;
    RESET ROLE;
    IF v_emails IS NULL THEN
      RAISE EXCEPTION 'authenticated read the view but got NO city_emails for a Surfside property';
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: authenticated got 42501 reading client.properties.city_emails - '
                    'the resolver is not SECURITY DEFINER (this is the exact bug this migration warns about)';
  END;

  -- (E) the RPC writes, and reports the real blast radius. Miami has no row today.
  SELECT count(*) INTO v_before FROM public.municipality_regulators;
  SELECT client.update_property_city_email(
           (SELECT id FROM public.properties WHERE lower(btrim(city))='miami' ORDER BY id LIMIT 1),
           ARRAY['  FOG@MiamiGov.com ', 'fog@miamigov.com', '']   -- dupes/case/blank on purpose
         ) INTO v_res;
  IF v_res->>'municipality' IS NULL THEN RAISE EXCEPTION 'the RPC returned no municipality'; END IF;
  IF (v_res->'emails') <> to_jsonb(ARRAY['fog@miamigov.com']) THEN
    RAISE EXCEPTION 'the RPC did not normalise/de-duplicate: %', v_res->'emails';
  END IF;
  IF (v_res->>'properties_affected')::int < 100 THEN
    RAISE EXCEPTION 'properties_affected reads %, but Miami holds 225 properties - the blast radius is wrong',
      v_res->>'properties_affected';
  END IF;

  -- (F) 🛑 the case-insensitivity of the WRITE. Calling again for a DIFFERENTLY-CASED city must
  --     UPDATE the row just created, not insert a second shadowing one.
  SELECT count(*) INTO v_after FROM public.municipality_regulators;
  IF v_after <> v_before + 1 THEN RAISE EXCEPTION 'expected exactly one new regulator row, got %', v_after - v_before; END IF;
  PERFORM client.update_property_city_email(
            (SELECT id FROM public.properties WHERE btrim(city) ILIKE 'miami' ORDER BY id DESC LIMIT 1),
            ARRAY['fog2@miamigov.com']);
  SELECT count(*) INTO n FROM public.municipality_regulators;
  IF n <> v_after THEN
    RAISE EXCEPTION 'a second regulator row was created for the same city - ON CONFLICT-style matching leaked in';
  END IF;

  -- (G) clearing deactivates rather than deletes, and the resolver then returns nothing
  PERFORM client.update_property_city_email(
            (SELECT id FROM public.properties WHERE lower(btrim(city))='miami' ORDER BY id LIMIT 1),
            ARRAY[]::text[]);
  IF public.fn_city_regulator_emails('Miami') IS NOT NULL THEN
    RAISE EXCEPTION 'cleared the inbox but the resolver still returns one';
  END IF;
  SELECT count(*) INTO n FROM public.municipality_regulators WHERE lower(btrim(municipality))='miami';
  IF n <> 1 THEN RAISE EXCEPTION 'clearing DELETED the row (rule #6 says never hard-delete)'; END IF;

  -- (H) rubbish is refused
  BEGIN
    PERFORM client.update_property_city_email(
              (SELECT id FROM public.properties WHERE lower(btrim(city))='miami' ORDER BY id LIMIT 1),
              ARRAY['not-an-email']);
    RAISE EXCEPTION 'GUARD FAILED: the RPC accepted "not-an-email"';
  EXCEPTION
    WHEN sqlstate '22023' THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (I) a property with no city is refused with a readable message, not a null-city row
  BEGIN
    PERFORM client.update_property_city_email(
              (SELECT id FROM public.properties WHERE city IS NULL OR btrim(city)='' ORDER BY id LIMIT 1),
              ARRAY['x@y.com']);
    RAISE EXCEPTION 'GUARD FAILED: the RPC accepted a property with no city';
  EXCEPTION
    WHEN sqlstate '22023' THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: resolver works as authenticated through the view, RPC normalises, matches case-insensitively, clears safely, and refuses rubbish';
END $$;

-- 🛑 The assertions above WROTE to municipality_regulators (Miami). That is deliberate - they
--    exercise the RPC rather than restating it - but Miami must NOT keep a made-up inbox, so the
--    whole block is rolled back and only the DDL is re-applied below.
ROLLBACK;

-- ---------------------------------------------------------------------------
-- re-apply the DDL for real, now that the behaviour is proven.
-- ---------------------------------------------------------------------------
BEGIN;

SET LOCAL search_path = public;

CREATE OR REPLACE FUNCTION public.fn_city_regulator_emails(p_city text)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT r.emails
    FROM public.municipality_regulators r
   WHERE r.status = 'ACTIVE'
     AND lower(btrim(r.municipality)) = lower(btrim(p_city))
   ORDER BY r.id
   LIMIT 1
$function$;

COMMENT ON FUNCTION public.fn_city_regulator_emails(text) IS
  'The city inbox for a municipality name, matched case-insensitively and ACTIVE-only - the SAME '
  'resolution send-derm-email performs for target=''city''. SECURITY DEFINER because it is called '
  'from inside the owner-rights view client.properties, where an INVOKER function would raise 42501.';

REVOKE ALL ON FUNCTION public.fn_city_regulator_emails(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_city_regulator_emails(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_city_regulator_emails(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_city_regulator_emails(text) TO service_role;

CREATE OR REPLACE VIEW client.properties AS
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
          WHERE z.id = p.zone_id) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE j.property_id = p.id))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE l.entity_type = 'property'::text AND l.source_system = 'jobber'::text AND l.entity_id = p.id)) AS jobber_linked,
    COALESCE(grease_trap_size_gallons::numeric, ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    public.fn_city_regulator_emails(p.city) AS city_emails
   FROM properties p;

CREATE OR REPLACE FUNCTION client.update_property_city_email(
  p_property_id bigint,
  p_emails      text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
declare
  v_city    text;
  v_state   text;
  v_county  text;
  v_clean   text[];
  v_bad     text;
  v_id      bigint;
  v_muni    text;
  v_props   int;
  v_clients int;
begin
  if p_property_id is null then
    raise exception 'A property id is required.' using errcode = '22023';
  end if;

  select btrim(p.city), coalesce(nullif(btrim(p.state), ''), 'FL'), p.county
    into v_city, v_state, v_county
    from public.properties p
   where p.id = p_property_id;

  if not found then
    raise exception 'Property % does not exist.', p_property_id using errcode = '22023';
  end if;

  if v_city is null or v_city = '' then
    raise exception 'This property has no city, so there is no city inbox to set. Add the address first.'
      using errcode = '22023';
  end if;

  select array_agg(e ORDER BY e)
    into v_clean
    from (select distinct lower(btrim(x)) as e
            from unnest(coalesce(p_emails, '{}'::text[])) as x
           where btrim(x) <> '') s;
  v_clean := coalesce(v_clean, '{}'::text[]);

  select e into v_bad
    from unnest(v_clean) e
   where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
   limit 1;
  if v_bad is not null then
    raise exception 'That does not look like an email address: %', v_bad using errcode = '22023';
  end if;

  select r.id into v_id
    from public.municipality_regulators r
   where lower(btrim(r.municipality)) = lower(btrim(v_city))
   order by r.id
   limit 1;

  if v_id is null then
    insert into public.municipality_regulators (municipality, state, county, emails, status)
    values (v_city, v_state, v_county, v_clean,
            case when cardinality(v_clean) > 0 then 'ACTIVE' else 'INACTIVE' end)
    returning id, municipality into v_id, v_muni;
  else
    update public.municipality_regulators r
       set emails = v_clean,
           status = case when cardinality(v_clean) > 0 then 'ACTIVE' else 'INACTIVE' end
     where r.id = v_id
    returning r.municipality into v_muni;
  end if;

  select count(*)::int, count(distinct p.client_id)::int
    into v_props, v_clients
    from public.properties p
   where lower(btrim(p.city)) = lower(btrim(v_city));

  return jsonb_build_object(
    'municipality',        v_muni,
    'emails',              to_jsonb(v_clean),
    'properties_affected', v_props,
    'clients_affected',    v_clients
  );
end;
$function$;

COMMENT ON FUNCTION client.update_property_city_email(bigint, text[]) IS
  'Sets the city inbox for the MUNICIPALITY the given property sits in, so it applies to every '
  'property in that city. Returns properties_affected/clients_affected so the UI can say so. '
  'Clearing sets status=INACTIVE rather than deleting the row.';

REVOKE ALL ON FUNCTION client.update_property_city_email(bigint, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_property_city_email(bigint, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_property_city_email(bigint, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_property_city_email(bigint, text[]) TO service_role;

-- final state check: the DDL landed, and NOTHING the assertions wrote survived
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.municipality_regulators;
  IF n <> 2 THEN
    RAISE EXCEPTION 'municipality_regulators holds % rows, expected the original 2 - an assertion write survived', n;
  END IF;
  IF public.fn_city_regulator_emails('Surfside') IS NULL THEN
    RAISE EXCEPTION 'the resolver is not working after the real apply';
  END IF;
  PERFORM 1 FROM information_schema.columns
    WHERE table_schema='client' AND table_name='properties' AND column_name='city_emails';
  IF NOT FOUND THEN RAISE EXCEPTION 'client.properties.city_emails did not land'; END IF;
  RAISE NOTICE 'OK: DDL applied, regulators still 2 rows, city_emails exposed';
END $$;

COMMIT;
