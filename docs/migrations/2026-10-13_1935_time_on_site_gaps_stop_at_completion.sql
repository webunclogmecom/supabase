-- ============================================================================
-- 2026-10-13_1935 The time on site alert names the truck stop that holds the completion time
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13, on visit 6509 (214-MYK, Sep 25): the report said "A truck only passed by (under 3 min)" while
--   Samsara shows David parked at the client for 31m38s, and "this has happened to other ones". Plan
--   samsara-checks/time_on_site_fix_plan_2026-10-13.md (outside the repos, it names clients), step 1: "make the alert
--   and the report tell the truth". Fred: "go with your defaults, start with step 1".
--
-- WHY IT SAID "PASSED BY"
--   Every time-on-site path asks "was the truck within 150 m of our map point". For 214-MYK our point is the 777
--   Brickell Ave building geocode and the food trucks park in a lot about 160 m west of it. David parked 10:29 to 11:03
--   ET, 150 to 197 m from our point (inside the client's 100 m Samsara Place), and Grecia completed the job at 10:54.
--   fn_time_on_site_gaps only saw the 1-minute drive-in inside 150 m. 16 blank 2026 visits have this pattern
--   (214-MYK 7, 062-TCE 6, 099-PV 2, 1 test).
--
-- WHAT CHANGES (describing only; nothing here writes a visit)
--   1. NEW public.fn_gps_stays(vehicle, from, to): the stop builder's GPS walk (fn_build_vehicle_stops v1 step 6,
--      100 m from an anchor point, 3 minutes minimum), read-only, for ANY window: no site-dwell breaks, no resume
--      point, no 2026-08-20 era clamp, nothing written. So the alert and the report are honest for all of 2026, not
--      only since the stop table exists. service_role only (revoked by name: Supabase's default privileges grant
--      EXECUTE on every new public function).
--   2. public.fn_time_on_site_gaps (spliced from the live body, md5-pinned): every listed visit gains
--      `stop_at_completion` = the stop (any truck) that holds completed_at, with the stop matcher's tolerance (5 min
--      before arrival to 15 min after departure), within 250 m of our map point (Fred's default cap, plan decision 1);
--      the visit's own truck first, then the nearest. {truck, truck_samsara_id, assigned, arrived, departed, minutes,
--      meters, lat, lng}, or null. Every existing key is unchanged.
--   3. The Samsara Place ids it returns lose the `addr_` prefix some links carry (214-MYK's is stored as
--      addr_4000001823124), so the reminder's Place lookup finds them.
--   The reminder edge function (time-on-site-reminder) turns stop_at_completion into the new first reason; that is
--   a code change in the same commit.
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse.
-- ROLLBACK: 2026-10-13_rollback_time_on_site_gaps_stop_at_completion.sql (restores the 2026-10-13_0130 body, drops
--   the helper). Roll the edge function back first: the new reasons read stop_at_completion.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_gaps(date)'::regprocedure)) <> '7f19c163de572fb902bf2299a10485ff' THEN
    RAISE EXCEPTION 'fn_time_on_site_gaps changed since 2026-10-13_0130: splice from the live body again'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_gps_stays(p_vehicle_id bigint, p_from timestamptz, p_to timestamptz,
                                              p_radius_m integer DEFAULT 100, p_min_minutes integer DEFAULT 3)
 RETURNS TABLE(arrived_at timestamptz, departed_at timestamptz, gps_fix_count integer, latitude numeric, longitude numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- The stop builder's GPS walk (public.fn_build_vehicle_stops v1, step 6), copied, read-only, for an explicit window.
-- A stop is consecutive GPS points within p_radius_m of the first one (the anchor), at least p_min_minutes long; no
-- time-gap break, so a parked truck with its engine off is one stop. Differences from the builder, all deliberate:
-- no site-dwell breaks (it is not given site events), no resume point and no 2026-08-20 clamp, nothing written, and a
-- stop still open at the end of the window is returned (the window is in the past, so there is no doubt to wait out).
declare
  v_t   timestamptz[];  v_lat float8[];  v_lng float8[];  v_n int := 0;
  v_ga  int[] := '{}';  v_gb  int[] := '{}';
  i int;  v_anchor int;  v_last int;  v_dist float8;
  v_min interval := make_interval(mins => p_min_minutes);
begin
  select array_agg(t.recorded_at order by t.recorded_at),
         array_agg(t.latitude::float8 order by t.recorded_at),
         array_agg(t.longitude::float8 order by t.recorded_at)
    into v_t, v_lat, v_lng
    from public.vehicle_telemetry_readings t
   where t.vehicle_id = p_vehicle_id and t.latitude is not null and t.longitude is not null
     and t.recorded_at >= p_from and t.recorded_at < p_to;
  v_n := coalesce(cardinality(v_t), 0);

  for i in 1 .. v_n loop
    if v_anchor is null then v_anchor := i; v_last := i; continue; end if;
    v_dist := 2 * 6371008.8 * asin(sqrt(
                power(sin(radians(v_lat[i] - v_lat[v_anchor]) / 2), 2)
              + cos(radians(v_lat[v_anchor])) * cos(radians(v_lat[i]))
              * power(sin(radians(v_lng[i] - v_lng[v_anchor]) / 2), 2)));
    if v_dist <= p_radius_m then v_last := i; continue; end if;
    if v_t[v_last] - v_t[v_anchor] >= v_min then v_ga := v_ga || v_anchor; v_gb := v_gb || v_last; end if;
    v_anchor := i; v_last := i;
  end loop;
  if v_anchor is not null and v_t[v_last] - v_t[v_anchor] >= v_min then
    v_ga := v_ga || v_anchor; v_gb := v_gb || v_last;
  end if;

  return query
    select v_t[x.a], v_t[x.b], (x.b - x.a + 1)::int,
           round((select percentile_cont(0.5) within group (order by y) from unnest(v_lat[x.a:x.b]) y)::numeric, 6),
           round((select percentile_cont(0.5) within group (order by y) from unnest(v_lng[x.a:x.b]) y)::numeric, 6)
      from unnest(v_ga, v_gb) x(a, b);
end $function$;

REVOKE ALL ON FUNCTION public.fn_gps_stays(bigint, timestamptz, timestamptz, integer, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_gps_stays(bigint, timestamptz, timestamptz, integer, integer) TO service_role;
COMMENT ON FUNCTION public.fn_gps_stays(bigint, timestamptz, timestamptz, integer, integer) IS 'A truck''s stops in a window, from raw GPS: the fn_build_vehicle_stops v1 walk (100 m from an anchor, 3 min), read-only, any date, no site-dwell breaks. Read by fn_time_on_site_gaps. 2026-10-13_1935.';

CREATE OR REPLACE FUNCTION public.fn_time_on_site_gaps(p_date date DEFAULT (((now() AT TIME ZONE 'America/New_York'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with gap as (
    select v.id, v.visit_date, v.vehicle_id, v.service_type, v.completed_at, v.client_id, v.property_id,
           c.client_code, c.name as client_name,
           p.latitude::float8 as plat, p.longitude::float8 as plon
      from public.visits v
      join public.clients c on c.id = v.client_id
      left join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date = p_date
       and v.duration_minutes is null
       and not coalesce(public.fn_is_non_customer(v.client_id), false)
  ), pings as (
    -- every GPS point of every truck in the window (not only the near ones): a point elsewhere is what ends a stay
    select g.id, r.vehicle_id, r.recorded_at,
           sqrt(power((r.latitude - g.plat) * 111320, 2) +
                power((r.longitude - g.plon) * 111320 * cos(radians(g.plat)), 2)) as d
      from gap g
      join public.vehicle_telemetry_readings r
        on g.plat is not null
       and r.recorded_at >= (g.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  ((g.visit_date + 1) + time '10:00') at time zone 'America/New_York'
  ), closest as (
    select distinct on (id) id, vehicle_id, recorded_at, d from pings order by id, d
  ), marked as (
    -- A STAY is consecutive points within 150 m, however long the silence between them (a parked truck with its
    -- engine off can send no GPS), ended by a point outside 150 m or a silence over 4 hours. So two drive-bys are two
    -- passes, never one stay: visit 8765 (2026-10-09), David passed Casa Neos at 13:53 and 14:38 ET and was 500 m to
    -- 1.3 km away in between. Taking a truck's first and last near point as one stay (a report of 2026-10-12 did)
    -- reads that as "there 45 minutes". This list only describes; it fills nothing.
    select id, vehicle_id, recorded_at, d,
           case when lag(d) over w is null or lag(d) over w > 150 or d > 150
                  or recorded_at - lag(recorded_at) over w > interval '4 hours' then 1 else 0 end as n
      from pings
    window w as (partition by id, vehicle_id order by recorded_at)
  ), cl as (
    select id, vehicle_id, recorded_at, d, sum(n) over (partition by id, vehicle_id order by recorded_at) as c from marked
  ), stays as (
    select id, vehicle_id, min(recorded_at) as first_at, max(recorded_at) as last_at,
           round(extract(epoch from max(recorded_at) - min(recorded_at)) / 60)::int as minutes
      from cl where d <= 150 group by id, vehicle_id, c
  ), day_stops as (
    -- every truck's stops in the window (public.fn_gps_stays: the stop builder's 100 m walk, any date), computed only
    -- on a day that lists something. Visit 6509 (2026-09-25): David parked 164 m from our map point 10:29 to 11:03
    -- while the job was marked complete at 10:54, which the 150 m stays above see as a 1-minute drive-by.
    select vh.id as vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from public.vehicles vh
      cross join lateral public.fn_gps_stays(vh.id,
                   (p_date::timestamp at time zone 'America/New_York') - interval '4 hours',
                   ((p_date + 1) + time '10:00') at time zone 'America/New_York') s
     where exists (select 1 from gap)
  ), at_completion as (
    -- the stop that holds completed_at (the stop matcher's tolerance: 5 min before arrival to 15 min after departure),
    -- within 250 m of our map point; the visit's own truck first, then the nearest
    select distinct on (g.id) g.id, ds.vehicle_id, ds.arrived_at, ds.departed_at, ds.latitude, ds.longitude,
           ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude) * 1000 as m
      from gap g
      join day_stops ds
        on g.completed_at between ds.arrived_at - interval '5 minutes' and ds.departed_at + interval '15 minutes'
     where g.plat is not null
       and ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude) * 1000 <= 250
     order by g.id, (ds.vehicle_id is not distinct from g.vehicle_id) desc,
              ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude)
  ), truck as (
    select vh.id, vh.name,
           (select e.source_id from public.entity_source_links e
             where e.entity_type = 'vehicle' and e.entity_id = vh.id and e.source_system = 'samsara' limit 1) as samsara_id
      from public.vehicles vh
  )
  select jsonb_build_object(
    'date', p_date,
    'older_count', (select count(*) from public.visits v
                     where v.visit_status = 'completed' and v.deleted_at is null and v.duration_minutes is null
                       and v.visit_date >= p_date - 30 and v.visit_date < p_date
                       and not coalesce(public.fn_is_non_customer(v.client_id), false)),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'visit_id', g.id, 'visit_date', g.visit_date, 'client_code', g.client_code, 'client_name', g.client_name,
               'service', g.service_type, 'completed_at', g.completed_at,
               'lat', g.plat, 'lng', g.plon,
               'truck', t.name, 'truck_samsara_id', t.samsara_id,
               'property_place_id', (select regexp_replace(e.source_id, '^addr_', '') from public.entity_source_links e
                                      where e.entity_type = 'property' and e.entity_id = g.property_id
                                        and e.source_system = 'samsara' limit 1),
               'client_place_ids', coalesce((select jsonb_agg(regexp_replace(e.source_id, '^addr_', '')) from public.entity_source_links e
                                              where e.entity_type = 'client' and e.entity_id = g.client_id
                                                and e.source_system = 'samsara'), '[]'::jsonb),
               'closest', (select jsonb_build_object('truck', ct.name, 'truck_samsara_id', ct.samsara_id,
                                                     'meters', round(c.d), 'at', c.recorded_at)
                             from closest c join truck ct on ct.id = c.vehicle_id where c.id = g.id),
               'stays', coalesce((select jsonb_agg(jsonb_build_object('truck', st.name, 'truck_samsara_id', st.samsara_id,
                                                                    'first', s.first_at, 'last', s.last_at, 'minutes', s.minutes)
                                                 order by s.minutes desc)
                                    from stays s join truck st on st.id = s.vehicle_id where s.id = g.id), '[]'::jsonb),
               'stop_at_completion', (select jsonb_build_object('truck', tr.name, 'truck_samsara_id', tr.samsara_id,
                                                                'assigned', ac.vehicle_id is not distinct from g.vehicle_id,
                                                                'arrived', ac.arrived_at, 'departed', ac.departed_at,
                                                                'minutes', round(extract(epoch from ac.departed_at - ac.arrived_at) / 60)::int,
                                                                'meters', round(ac.m), 'lat', ac.latitude, 'lng', ac.longitude)
                                        from at_completion ac join truck tr on tr.id = ac.vehicle_id where ac.id = g.id))
             order by g.client_code, g.id)
        from gap g left join truck t on t.id = g.vehicle_id), '[]'::jsonb));
$function$;

COMMENT ON FUNCTION public.fn_time_on_site_gaps(date) IS 'Client visits dated p_date (default yesterday ET) with no time on site, with the GPS facts behind each, for the daily Slack alert time-on-site-reminder and the visits-missing-time-on-site report: closest point, 150 m stays, and stop_at_completion (the truck stop that holds the completion time, within 250 m, from fn_gps_stays). Samsara Place ids without the addr_ prefix. 2026-10-13_0130, 2026-10-13_1935.';

DO $v$
DECLARE r jsonb; e jsonb; s jsonb; n int; d record; old_keys text[] := array['visit_id','visit_date','client_code','client_name',
  'service','completed_at','lat','lng','truck','truck_samsara_id','property_place_id','client_place_ids','closest','stays'];
BEGIN
  -- V1 the helper reproduces the stop builder's stop for 6509 (vehicle_stops 1682: 10:29:11 to 11:02:59 ET, 187 fixes)
  SELECT count(*) INTO n FROM public.fn_gps_stays(3, '2026-09-24 20:00-04', '2026-09-26 10:00-04') x
   WHERE x.arrived_at = '2026-09-25 10:29:11-04' AND x.departed_at = '2026-09-25 11:02:59-04' AND x.gps_fix_count = 187
     AND x.latitude = 25.766279 AND x.longitude = -80.190609;
  IF n <> 1 THEN RAISE EXCEPTION 'V1: fn_gps_stays does not reproduce stop 1682'; END IF;

  -- V2 the positive control: 6509 now carries its stop, with the Place id unprefixed and every old key kept
  r := public.fn_time_on_site_gaps('2026-09-25');
  IF NOT (r ? 'date' AND r ? 'older_count' AND r ? 'visits') THEN RAISE EXCEPTION 'V2: top-level keys changed'; END IF;
  SELECT v INTO e FROM jsonb_array_elements(r->'visits') v WHERE (v->>'visit_id')::int = 6509;
  IF e IS NULL THEN RAISE EXCEPTION 'V2: 6509 not listed for 2026-09-25'; END IF;
  IF NOT (e ?& old_keys) THEN RAISE EXCEPTION 'V2: a 2026-10-13_0130 key is missing'; END IF;
  s := e->'stop_at_completion';
  IF s IS NULL OR jsonb_typeof(s) <> 'object' OR s->>'truck' <> 'David' OR (s->>'assigned')::boolean IS NOT TRUE
     OR (s->>'minutes')::int NOT BETWEEN 33 AND 35 OR (s->>'meters')::numeric NOT BETWEEN 158 AND 170 THEN
    RAISE EXCEPTION 'V2: 6509 stop_at_completion wrong: %', s; END IF;
  IF e->>'property_place_id' <> '4000001823124' THEN RAISE EXCEPTION 'V2: addr_ prefix not stripped: %', e->>'property_place_id'; END IF;

  -- V3 every client visit of the 6509 pattern (the 2026-10-13 blank sweep) gets a stop 150 to 250 m away
  FOR d IN SELECT v.id, v.visit_date FROM public.visits v
            WHERE v.id IN (6509,6505,6508,6271,7991,1256,1359,1801,4794,5061,5157,5788,5822,6496,7790) LOOP
    SELECT v->'stop_at_completion' INTO s FROM jsonb_array_elements(public.fn_time_on_site_gaps(d.visit_date)->'visits') v
     WHERE (v->>'visit_id')::int = d.id;
    IF s IS NULL OR jsonb_typeof(s) <> 'object' OR (s->>'meters')::numeric NOT BETWEEN 150 AND 250 THEN
      RAISE EXCEPTION 'V3: visit % (%): stop_at_completion %', d.id, d.visit_date, s; END IF;
  END LOOP;

  -- V4 a visit with no stop near its completion still reads null (8752 Granada Condo, 2026-10-09: no truck within 290 m)
  SELECT v->'stop_at_completion' INTO s FROM jsonb_array_elements(public.fn_time_on_site_gaps('2026-10-09')->'visits') v
   WHERE (v->>'visit_id')::int = 8752;
  IF s IS NULL OR jsonb_typeof(s) <> 'null' THEN RAISE EXCEPTION 'V4: 8752 should carry a null stop, got %', s; END IF;

  -- V5 grants: the alert function unchanged; the helper is service_role only
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_gaps(date)'::regprocedure)
     IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V5: gaps ACL changed'; END IF;
  IF has_function_privilege('anon', 'public.fn_gps_stays(bigint,timestamptz,timestamptz,integer,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_gps_stays(bigint,timestamptz,timestamptz,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V5: fn_gps_stays is executable by an app role'; END IF;
END $v$;

COMMIT;
