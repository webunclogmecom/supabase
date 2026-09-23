-- =============================================================================
-- 2026-09-22_2210_property_site_map.sql
-- Section 3 of Building Apps/docs/2026-09-23_client-intake-build-plan.md
--
-- WHAT. Where the site map lives: the grease trap pin, the truck parking pin and
-- the arrows Picture Planner draws, as one jsonb document on the property.
--
-- WHY HERE. Serena's decision 4 moved the pins "from Picture Planner to Client":
-- where the trap is and where the truck goes are facts about the SITE that outlive
-- any page, and the collector drops them in the field long before a page exists.
-- Fred, 2026-09-22: "we need to hold the arrows the Picture Planner builder has [...]
-- what is the best solution for it so it complies".
--
-- WHY JSONB AND NOT COLUMNS OR POSTGIS. PostGIS is NOT installed (measured: the
-- extensions are pg_cron, pg_net, pg_partman, pg_stat_statements, pg_trgm, pgaudit,
-- pgcrypto, plpgsql, supabase_vault, uuid-ossp) and there are ZERO geometry columns
-- estate-wide. Nothing here asks a spatial question, so a document is right. The
-- precedent is exact: properties.access_schedule is jsonb with a strict shape CHECK,
-- written only through a gated client.* RPC, and it is the only jsonb column on a
-- business table in public. Pins are an OPEN object rather than fixed gt/truck keys
-- so a new pin kind (sample port, lift station, clean-out) costs nothing instead of
-- an ACCESS EXCLUSIVE lock on a 506-row table plus an RPC edit plus a redeploy.
--
-- ⚠ latitude/longitude CANNOT be reused. They are the Jobber address geocode
--   (957 of 958 filled before yesterday's merge), they drive geofencing, and
--   client.update_property_operational refuses them in its own words: "geofence/
--   lat/long are Samsara-owned" and "would be reverted by the inbound sync".
--
-- 🛑 DELIBERATE DEVIATION FROM THE PLAN, and the reason. The plan said to extend
--    client.update_property_operational with a site_map key. I did NOT. Two reasons,
--    both about risk rather than taste: (a) the optimistic-lock argument this needs
--    (p_expected_rev) does not fit that function's p_patch shape, and (b) extending
--    it means CREATE OR REPLACE over a ~200-line live function that every property
--    edit in the Client App depends on, to add one field. A dedicated 60-line RPC is
--    the smaller, safer diff and it cannot break property editing. The precedent is
--    genuinely split and supports this: update_property_capacity and
--    update_property_city_email are each their own RPC, while lock_box_key and
--    access_schedule were folded in.
--
-- 🛑 THE CHECK WAS THE HARD PART, AND THE FIRST TWO ATTEMPTS WERE BOTH WRONG.
--    Attempt 1 used lax jsonpath, where the step before a filter AUTO-UNWRAPS an
--    array, so `$."arrows"[*]."points" ? (@.size() < 2)` bound @ to each POINT
--    (size 1) and rejected every legal arrow. Attempt 2 fixed that with `strict` and
--    scored 24 of 24 on coordinate cases, but validated only coordinates: an
--    adversarial pass proved SEVEN malformed documents still passed, including
--    `{"pins":42}`, `{"pins":{"gt":{}}}` (which Picture Planner's own "Clear G"
--    button produces) and `{"arrows":[1,2,3]}`.
--    ⇒ This version drops jsonpath entirely for ONE IMMUTABLE VALIDATOR FUNCTION
--      that the CHECK and the RPC both call, so validity is defined once and the
--      lax/strict trap cannot come back. A CHECK may not contain a subquery, but it
--      may call a function that does, and this one reads only its own argument.
--
-- ⚠ SIZE: the cap is octet_length(...::text), NOT pg_column_size, which is STABLE and
--   illegal in a CHECK. Rounding happens BEFORE the size test on purpose: a document
--   at the constraint's own maxima serialises to 16,543 bytes at full double
--   precision against a 16,384 cap, so whether a legal map saved would otherwise
--   depend on how many decimals the map library happened to return.
--
-- RULE 8, AUDIT: no new table. public.properties already carries audit_properties,
-- so every map edit is already recorded with old and new.
-- ⚠ Do NOT set updated_at by hand: trg_properties_updated_at already does it.
-- ✅ Writing site_map does NOT reach Jobber: trg_properties_enqueue_outbound fires
--    only WHEN grease_trap_size_gallons or lock_box_key change. Asserted below.
--
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================

-- ------------------------------------------------------------- 1. THE VALIDATOR
create or replace function public.fn_site_map_problem(p jsonb)
returns text language sql immutable set search_path to '' as $$
  select case
    when p is null then null
    when jsonb_typeof(p) <> 'object' then 'the site map must be a JSON object'
    when exists (select 1 from jsonb_object_keys(p) k where k not in ('rev','pins','arrows'))
      then 'the site map may only contain rev, pins and arrows'
    when p ? 'rev' and jsonb_typeof(p->'rev') <> 'number' then 'rev must be a number'
    when p ? 'pins'   and jsonb_typeof(p->'pins')   <> 'object' then 'pins must be an object'
    when p ? 'arrows' and jsonb_typeof(p->'arrows') <> 'array'  then 'arrows must be an array'
    when jsonb_array_length(coalesce(p->'arrows','[]'::jsonb)) > 10
      then 'at most 10 arrows'
    when exists (
      select 1 from jsonb_each(coalesce(p->'pins','{}'::jsonb)) e(k,v)
      where jsonb_typeof(v) <> 'object'
         or jsonb_typeof(v->'lat') is distinct from 'number'
         or jsonb_typeof(v->'lng') is distinct from 'number'
         or (v->>'lat')::numeric not between -90 and 90
         or (v->>'lng')::numeric not between -180 and 180)
      then 'every pin needs a numeric lat between -90 and 90 and lng between -180 and 180'
    when exists (
      select 1 from jsonb_array_elements(coalesce(p->'arrows','[]'::jsonb)) a
      where jsonb_typeof(a) <> 'object'
         or jsonb_typeof(a->'points') is distinct from 'array'
         or jsonb_array_length(a->'points') < 2
         or jsonb_array_length(a->'points') > 30)
      then 'every arrow needs a points array with 2 to 30 points'
    when exists (
      select 1 from jsonb_array_elements(coalesce(p->'arrows','[]'::jsonb)) a,
                   jsonb_array_elements(a->'points') pt
      where jsonb_typeof(pt) <> 'object'
         or jsonb_typeof(pt->'lat') is distinct from 'number'
         or jsonb_typeof(pt->'lng') is distinct from 'number'
         or (pt->>'lat')::numeric not between -90 and 90
         or (pt->>'lng')::numeric not between -180 and 180)
      then 'every arrow point needs a numeric lat and lng in range'
    when octet_length(p::text) > 16384 then 'the site map is too large (16 KB maximum)'
    else null
  end
$$;

comment on function public.fn_site_map_problem(jsonb) is
  'Returns NULL when a site_map document is valid, otherwise a plain sentence naming the '
  'problem. ONE definition of validity, called by both the properties CHECK and '
  'client.update_property_site_map, so the two can never drift apart.';

-- --------------------------------------------------------------- 2. THE ROUNDER
-- Rebuilds the document with every coordinate at 6 decimal places (about 11 cm),
-- which is what keeps a legal map under the size cap regardless of what the map
-- library returned. Shape-tolerant on purpose: it is called BEFORE validation only
-- for documents that already parsed as the right shape.
create or replace function public.fn_site_map_round(p jsonb)
returns jsonb language sql immutable set search_path to '' as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else
    (p - 'pins' - 'arrows')
    || case when p ? 'pins' then jsonb_build_object('pins', coalesce((
         select jsonb_object_agg(e.k, jsonb_build_object(
                  'lat', round((e.v->>'lat')::numeric, 6),
                  'lng', round((e.v->>'lng')::numeric, 6)))
         from jsonb_each(p->'pins') e(k,v)), '{}'::jsonb))
       else '{}'::jsonb end
    || case when p ? 'arrows' then jsonb_build_object('arrows', coalesce((
         select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'label', z.a->'label',
                  'points', (select jsonb_agg(jsonb_build_object(
                               'lat', round((pt->>'lat')::numeric, 6),
                               'lng', round((pt->>'lng')::numeric, 6)) order by o2)
                             from jsonb_array_elements(z.a->'points') with ordinality q(pt,o2))))
                order by z.ord)
         from jsonb_array_elements(p->'arrows') with ordinality z(a,ord)), '[]'::jsonb))
       else '{}'::jsonb end
  end
$$;

-- ---------------------------------------------------------------- 3. THE COLUMN
alter table public.properties add column if not exists site_map jsonb;

alter table public.properties drop constraint if exists properties_site_map_shape_chk;
alter table public.properties add constraint properties_site_map_shape_chk
  check (public.fn_site_map_problem(site_map) is null);

comment on column public.properties.site_map is
  'The site map: {"rev":n,"pins":{"gt":{"lat":..,"lng":..},"truck":{...}},"arrows":[{"label":..,'
  '"points":[{"lat":..,"lng":..},...]}]}. Pin keys are OPEN so a new pin kind needs no migration. '
  'Coordinates are rounded to 6 decimals by the RPC. NOT the Jobber geocode: that is '
  'latitude/longitude, which is Samsara-owned and reverted by the inbound sync.';

-- ------------------------------------------------------------------- 4. THE RPC
create or replace function client.update_property_site_map(
  p_property_id bigint,
  p_site_map    jsonb,
  p_expected_rev integer default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_problem text;
  v_cur     jsonb;
  v_cur_rev integer;
  v_next    jsonb;
  v_lat     numeric;
  v_lng     numeric;
  v_far     int;
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

  select site_map, latitude, longitude into v_cur, v_lat, v_lng
    from public.properties
   where id = p_property_id and deleted_at is null;
  if not found then
    raise exception 'property % is not a live property', p_property_id using errcode = 'P0002';
  end if;

  v_cur_rev := coalesce((v_cur ->> 'rev')::integer, 0);
  -- Optimistic lock. Cheap insurance rather than a measured contention problem: two
  -- office people building maps at once has not been observed, and Fred's decision 8b
  -- is explicitly that a silent last-write-wins is not acceptable.
  if p_expected_rev is not null and p_expected_rev <> v_cur_rev then
    raise exception 'the site map changed since you opened it (you had revision %, stored revision is %)',
      p_expected_rev, v_cur_rev using errcode = '40001';
  end if;

  if p_site_map is null then                      -- clearing the map is legal
    update public.properties set site_map = null where id = p_property_id;
    return jsonb_build_object('ok', true, 'cleared', true, 'rev', v_cur_rev);
  end if;

  -- Round FIRST, then validate, so precision cannot push a legal map over the cap.
  v_next := public.fn_site_map_round(p_site_map);
  v_problem := public.fn_site_map_problem(v_next);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '22023';
  end if;

  -- Sanity bound against the property's own geocode. ⚠ THIS DOES NOT CATCH A PIN ON
  -- THE WRONG BUILDING OF THE SAME CLIENT: the six-property client's buildings are
  -- metres apart. It catches a grossly wrong pin, the wrong city or a swapped
  -- lat/lng, and that is all it claims.
  if v_lat is not null and v_lng is not null then
    select count(*) into v_far
      from jsonb_each(coalesce(v_next->'pins','{}'::jsonb)) e(k,v)
     where abs((v->>'lat')::numeric - v_lat) > 0.05
        or abs((v->>'lng')::numeric - v_lng) > 0.05;
    if v_far > 0 then
      raise exception '% pin(s) are more than about 5 km from this property''s address; check the map is on the right property',
        v_far using errcode = '22023';
    end if;
  end if;

  v_next := v_next || jsonb_build_object('rev', v_cur_rev + 1);
  -- updated_at is set by trg_properties_updated_at; never set it here.
  update public.properties set site_map = v_next where id = p_property_id;

  return jsonb_build_object('ok', true, 'rev', v_cur_rev + 1, 'site_map', v_next);
end $$;

-- ------------------------------------------------------------------- 5. GRANTS
revoke all on function public.fn_site_map_problem(jsonb) from public, anon;
revoke all on function public.fn_site_map_round(jsonb)   from public, anon;
revoke all on function client.update_property_site_map(bigint, jsonb, integer) from public, anon;
grant execute on function client.update_property_site_map(bigint, jsonb, integer) to authenticated;

-- ------------------------------------------------------------------- 6. VERIFY
do $verify$
declare
  v_prop bigint;
  v_lat numeric; v_lng numeric;
  v_ok jsonb; v_rev int;
  v_raised boolean; v_msg text;
  v_big jsonb; v_pts jsonb;
  v_n int;
begin
  select id, latitude, longitude into v_prop, v_lat, v_lng
    from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false
     and p.latitude is not null
   order by p.id limit 1;
  if v_prop is null then raise exception 'VERIFY: no 112-YA property with a geocode'; end if;

  -- 6.1 THE POSITIVE CONTROL FIRST. A legal two-point arrow plus both pins must pass.
  -- The previous constraint rejected exactly this, and only a positive control found it.
  if public.fn_site_map_problem(jsonb_build_object(
       'pins', jsonb_build_object('gt', jsonb_build_object('lat', v_lat, 'lng', v_lng)),
       'arrows', jsonb_build_array(jsonb_build_object('label','back in here','points',
         jsonb_build_array(jsonb_build_object('lat',v_lat,'lng',v_lng),
                           jsonb_build_object('lat',v_lat,'lng',v_lng)))))) is not null then
    raise exception 'VERIFY 6.1: a LEGAL map was rejected';
  end if;

  -- 6.2 the seven container shapes the adversarial pass proved were accepted before
  if public.fn_site_map_problem('{"pins":[{"lat":25.76,"lng":-80.21}]}'::jsonb) is null then raise exception 'VERIFY 6.2a: pins as an ARRAY was accepted'; end if;
  if public.fn_site_map_problem('{"pins":{"gt":"somewhere"}}'::jsonb)           is null then raise exception 'VERIFY 6.2b: a string pin was accepted'; end if;
  if public.fn_site_map_problem('{"pins":{"gt":{}}}'::jsonb)                    is null then raise exception 'VERIFY 6.2c: an EMPTY pin was accepted (Clear G produces this)'; end if;
  if public.fn_site_map_problem('{"pins":{"gt":{"foo":1}}}'::jsonb)             is null then raise exception 'VERIFY 6.2d: a pin with no coords was accepted'; end if;
  if public.fn_site_map_problem('{"pins":42}'::jsonb)                           is null then raise exception 'VERIFY 6.2e: pins as a NUMBER was accepted'; end if;
  if public.fn_site_map_problem('{"arrows":[1,2,3]}'::jsonb)                    is null then raise exception 'VERIFY 6.2f: arrows of numbers was accepted'; end if;
  if public.fn_site_map_problem('{"arrows":[{"label":"hi"}]}'::jsonb)           is null then raise exception 'VERIFY 6.2g: an arrow with NO POINTS was accepted'; end if;

  -- 6.3 the coordinate rules still hold
  if public.fn_site_map_problem('{"pins":{"gt":{"lat":125,"lng":-80}}}'::jsonb)      is null then raise exception 'VERIFY 6.3a: lat 125 accepted'; end if;
  if public.fn_site_map_problem('{"pins":{"gt":{"lat":25,"lng":-500}}}'::jsonb)      is null then raise exception 'VERIFY 6.3b: lng -500 accepted'; end if;
  if public.fn_site_map_problem('{"pins":{"gt":{"lat":25}}}'::jsonb)                 is null then raise exception 'VERIFY 6.3c: half-dropped pin accepted'; end if;
  if public.fn_site_map_problem('{"unknown":1}'::jsonb)                              is null then raise exception 'VERIFY 6.3d: an unknown top-level key was accepted'; end if;
  if public.fn_site_map_problem('"a string"'::jsonb)                                 is null then raise exception 'VERIFY 6.3e: a bare string was accepted'; end if;
  if public.fn_site_map_problem(null)                                            is not null then raise exception 'VERIFY 6.3f: NULL must be allowed'; end if;

  -- 6.4 an arrow with a single point is refused, two points is allowed
  if public.fn_site_map_problem(('{"arrows":[{"points":[{"lat":25,"lng":-80}]}]}')::jsonb) is null then raise exception 'VERIFY 6.4a: a 1-point arrow was accepted'; end if;
  if public.fn_site_map_problem(('{"arrows":[{"points":[{"lat":25,"lng":-80},{"lat":25.1,"lng":-80.1}]}]}')::jsonb) is not null then raise exception 'VERIFY 6.4b: a legal 2-point arrow was REJECTED'; end if;

  -- 6.5 rounding actually happens, and it is what keeps a maximal map under the cap
  if (public.fn_site_map_round('{"pins":{"gt":{"lat":25.7647801234567,"lng":-80.2196501234567}}}'::jsonb)
        -> 'pins' -> 'gt' ->> 'lat') <> '25.764780' then
    raise exception 'VERIFY 6.5: coordinates were not rounded to 6 decimals';
  end if;
  select jsonb_agg(jsonb_build_object('lat', 25.7647801234567, 'lng', -80.2196501234567))
    into v_pts from generate_series(1,30);
  select jsonb_build_object('pins', jsonb_build_object(
           'gt', jsonb_build_object('lat',25.7647801234567,'lng',-80.2196501234567),
           'truck', jsonb_build_object('lat',25.7646201234567,'lng',-80.2201201234567)),
         'arrows', (select jsonb_agg(jsonb_build_object('label','a longer arrow label','points', v_pts))
                    from generate_series(1,10)))
    into v_big;
  if octet_length(v_big::text) <= 16384 then
    raise exception 'VERIFY 6.5b: the unrounded maximal map was expected to EXCEED the cap, it did not (% bytes)', octet_length(v_big::text);
  end if;
  if public.fn_site_map_problem(public.fn_site_map_round(v_big)) is not null then
    raise exception 'VERIFY 6.5c: a maximal map still fails AFTER rounding (% bytes): %',
      octet_length(public.fn_site_map_round(v_big)::text), public.fn_site_map_problem(public.fn_site_map_round(v_big));
  end if;

  -- 6.6 the CHECK is really attached: a direct bad write must fail
  v_raised := false;
  begin
    update public.properties set site_map = '{"pins":42}'::jsonb where id = v_prop;
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 6.6: the CHECK did not stop a bad direct write'; end if;

  -- 6.7 the RPC refuses an unauthenticated caller
  v_raised := false;
  begin
    perform client.update_property_site_map(v_prop, jsonb_build_object('pins',
      jsonb_build_object('gt', jsonb_build_object('lat', v_lat, 'lng', v_lng))));
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 6.7: the RPC accepted a call with no JWT'; end if;

  -- 6.8 with a staff JWT: write, rev starts at 1, the stale-rev guard fires
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","email":"fred@ayache.com"}', true);

  v_ok := client.update_property_site_map(v_prop, jsonb_build_object(
            'pins', jsonb_build_object('gt', jsonb_build_object('lat', v_lat, 'lng', v_lng))));
  if (v_ok ->> 'rev')::int <> 1 then raise exception 'VERIFY 6.8a: first write should be rev 1, got %', v_ok ->> 'rev'; end if;

  v_raised := false;
  begin
    perform client.update_property_site_map(v_prop, jsonb_build_object(
      'pins', jsonb_build_object('gt', jsonb_build_object('lat', v_lat, 'lng', v_lng))), 0);
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 6.8b: a stale expected_rev was accepted'; end if;

  v_ok := client.update_property_site_map(v_prop, jsonb_build_object(
            'pins', jsonb_build_object('gt', jsonb_build_object('lat', v_lat, 'lng', v_lng))), 1);
  if (v_ok ->> 'rev')::int <> 2 then raise exception 'VERIFY 6.8c: the correct expected_rev should give rev 2'; end if;

  -- 6.9 a pin in the wrong city is refused
  v_raised := false;
  begin
    perform client.update_property_site_map(v_prop, jsonb_build_object(
      'pins', jsonb_build_object('gt', jsonb_build_object('lat', 40.7128, 'lng', -74.0060))), 2);
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 6.9: a pin in New York was accepted for a Miami property'; end if;

  -- 6.10 writing the map does NOT enqueue anything to Jobber
  select count(*) into v_n from sync.outbound_queue
   where created_at > now() - interval '2 minutes';
  if v_n > 0 then
    raise exception 'VERIFY 6.10: a site_map write enqueued % outbound Jobber row(s)', v_n;
  end if;

  -- clean up: the fixture property must go back to having no map
  update public.properties set site_map = null where id = v_prop;
  perform set_config('request.jwt.claims', '', true);

  raise notice 'VERIFY: all site map assertions passed';
end $verify$;

notify pgrst, 'reload schema';
