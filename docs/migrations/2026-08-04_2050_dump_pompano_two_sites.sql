-- =====================================================================
-- 2026-08-04_2050  DUMP Pompano has TWO sites: detect at either
-- =====================================================================
-- WHY (Fred, 2026-08-04)
--   "Pompano Dump have 2 locations, so what i gave you today address for it was the
--    2nd location, which is the one we frequent instead of the other one at 2401"
--
--   So the two addresses that looked like a service/billing duplicate are TWO REAL
--   PHYSICAL SITES, ~726 m apart on N Powerline Road:
--     3100 n Powerline Road, Oakland Park   26.2683192,-80.1506092  <- FREQUENTED
--     2401 N Powerline Road, Pompano Beach  26.2632563,-80.1552085  <- the other one
--
--   This is why the geofence question could not be settled from our own data earlier:
--   I was asking "which of these two points is the real one" when the answer is BOTH.
--
-- WHAT CHANGES
--   public.dump_investigate hardcoded ONE point (the 2401 one) with a 250 m radius.
--   Since the sites are 726 m apart, that radius around either point EXCLUDES the
--   other, so a truck tipping at the frequented site scored as "not present".
--   It now measures to BOTH and takes the nearer, via a new helper.
--
-- ⚠ NAVIGATION AND DETECTION ARE DIFFERENT PROBLEMS, SOLVED DIFFERENTLY.
--   Navigation needs ONE target: dump-visit-create's lat/lng now points at the
--   FREQUENTED site (3100), because sending a driver to the site we rarely use is the
--   real regression. Detection must accept EITHER. Do not "unify" these.
--
-- ⚠ THE HELPER KEEPS THE ORIGINAL PLANAR APPROXIMATION (111000 / 100000 metres per
--   degree), deliberately, so distances stay comparable with everything already
--   reported by this function. It is NOT a haversine and should not be "upgraded" to
--   one without re-reading whatever consumes min_m.
--
-- ⚠ THIS DOES NOT MAKE POMPANO DETECTION START WORKING BY ITSELF. Measured before the
--   change: 4 Pompano dump visits exist in total and, across 6,861 telemetry pings in
--   their +/-3h windows, ZERO fell within 250 m of EITHER site (closest 1,925 m). So
--   the geofence was wrong AND the GPS coverage for those particular visits is absent.
--   This fixes the first; it says nothing about the second.
--
-- HOW THE BODY WAS PRODUCED: generated from the LIVE definition with three targeted
--   replacements, each asserted by count (1 spaced form, 2 tight forms) so a silent
--   partial rewrite is impossible. Homestead's site 2 is set equal to its site 1, so
--   LEAST() is a no-op there and its numbers cannot move.
--
-- AUDIT (rule #8): functions only, no table. N/A.
-- REVERSIBLE: yes - re-create from this file's git parent and drop the helper.
-- =====================================================================

begin;

-- Nearer of two sites, in metres. Pure arithmetic, IMMUTABLE, no table access, so being
-- called from a SECURITY DEFINER function raises no privilege question.
create or replace function public.fn_dump_site_dist_m(
  p_lat float, p_lng float,
  p_lat1 float, p_lng1 float,
  p_lat2 float, p_lng2 float
) returns float
language sql
immutable
set search_path = ''
as $fn$
  select least(
    sqrt(power((p_lat - p_lat1)*111000, 2) + power((p_lng - p_lng1)*100000, 2)),
    sqrt(power((p_lat - p_lat2)*111000, 2) + power((p_lng - p_lng2)*100000, 2))
  )
$fn$;

comment on function public.fn_dump_site_dist_m(float,float,float,float,float,float) is
  'Distance in metres to the NEARER of two dump-site points. DUMP Pompano is two physical sites '
  '~726 m apart (3100 Oakland Park, frequented; 2401 Pompano Beach), and a 250 m geofence around '
  'either excludes the other. Keeps the original planar approximation (111000/100000 m per degree) '
  'so values stay comparable with previously reported distances - it is not a haversine.';

revoke all on function public.fn_dump_site_dist_m(float,float,float,float,float,float) from public;
grant execute on function public.fn_dump_site_dist_m(float,float,float,float,float,float) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.dump_investigate(p_dump_visit_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_visit    public.visits%ROWTYPE;
  v_site_lat float; v_site_lng float; v_site text;
  v_site2_lat float; v_site2_lng float;
  v_claimed_name text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_gps jsonb; v_phys_vehicle bigint; v_phys_truck text; v_phys_min_m int;
  v_truck_drivers jsonb; v_claimed_drives_truck boolean;
  v_day_crew jsonb; v_day_crew_ids bigint[]; v_worked_ids bigint[];
  v_claimed_on_day_crew boolean; v_claimed_worked boolean; v_solo_name text;
  v_device jsonb;
  v_recorded_truck text;
  v_verdict text; v_confidence text; v_likely text;
BEGIN
  SELECT * INTO v_visit FROM public.visits WHERE id = p_dump_visit_id;
  IF v_visit.id IS NULL THEN
    RETURN jsonb_build_object('error', format('dump visit %s not found', p_dump_visit_id));
  END IF;
  IF v_visit.client_id NOT IN (365, 76) THEN
    RETURN jsonb_build_object('error', format('visit %s is not a dump visit (client %s)', p_dump_visit_id, v_visit.client_id));
  END IF;

  -- DUMP POMPANO HAS TWO PHYSICAL SITES ~726 m apart on N Powerline Road (Fred, 2026-08-04):
  --   3100 n Powerline Road, Oakland Park  26.2683192,-80.1506092  <- the one we FREQUENT
  --   2401 N Powerline Road, Pompano Beach 26.2632563,-80.1552085  <- the other one
  -- Detection must accept EITHER: a truck that tips at 2401 is still at Pompano, and a 250 m
  -- radius around one point EXCLUDES the other. So we measure to both and take the nearer.
  -- Homestead has a single site, so site 2 is set equal to site 1 and the LEAST() is a no-op.
  IF v_visit.client_id = 365 THEN
    v_site_lat := 25.5517444; v_site_lng := -80.3368324;
    v_site2_lat := 25.5517444; v_site2_lng := -80.3368324; v_site := 'Homestead';
  ELSE
    v_site_lat := 26.2683192; v_site_lng := -80.1506092;   -- 3100 Oakland Park (frequented)
    v_site2_lat := 26.2632563; v_site2_lng := -80.1552085; -- 2401 Pompano Beach
    v_site := 'Pompano';
  END IF;

  SELECT full_name INTO v_claimed_name FROM public.employees WHERE id = v_visit.assigned_driver_id;
  SELECT name INTO v_recorded_truck FROM public.vehicles WHERE id = v_visit.vehicle_id;

  v_win_start := COALESCE(v_visit.start_at, (v_visit.visit_date::timestamp AT TIME ZONE 'America/New_York')) - interval '18 hours';
  v_win_end   := COALESCE(v_visit.start_at, (v_visit.visit_date::timestamp AT TIME ZONE 'America/New_York')) + interval '18 hours';

  -- GPS: trucks in the window + the physically-present one
  WITH pings AS (
    SELECT t.vehicle_id,
           public.fn_dump_site_dist_m(t.latitude::float, t.longitude::float, v_site_lat, v_site_lng, v_site2_lat, v_site2_lng) AS dist_m,
           t.recorded_at
    FROM public.vehicle_telemetry_readings t
    WHERE t.recorded_at BETWEEN v_win_start AND v_win_end
  ),
  per_truck AS (
    SELECT p.vehicle_id, round(min(p.dist_m))::int min_m,
           count(*) FILTER (WHERE p.dist_m < 250)::int pings_at_site,
           (array_agg(p.recorded_at ORDER BY p.dist_m))[1] AS closest_at
    FROM pings p GROUP BY p.vehicle_id
  )
  SELECT jsonb_agg(jsonb_build_object('vehicle_id', pt.vehicle_id, 'truck', veh.name, 'min_m', pt.min_m,
           'pings_within_250m', pt.pings_at_site, 'present', (pt.pings_at_site > 0), 'closest_at', pt.closest_at) ORDER BY pt.min_m)
    INTO v_gps
  FROM per_truck pt LEFT JOIN public.vehicles veh ON veh.id = pt.vehicle_id;

  SELECT pt.vehicle_id, veh.name, pt.min_m INTO v_phys_vehicle, v_phys_truck, v_phys_min_m
  FROM (
    SELECT p.vehicle_id,
           round(min(public.fn_dump_site_dist_m(p.latitude::float, p.longitude::float, v_site_lat, v_site_lng, v_site2_lat, v_site2_lng)))::int min_m,
           count(*) FILTER (WHERE public.fn_dump_site_dist_m(p.latitude::float, p.longitude::float, v_site_lat, v_site_lng, v_site2_lat, v_site2_lng) < 250)::int atsite
    FROM public.vehicle_telemetry_readings p WHERE p.recorded_at BETWEEN v_win_start AND v_win_end
    GROUP BY p.vehicle_id
  ) pt LEFT JOIN public.vehicles veh ON veh.id = pt.vehicle_id
  WHERE pt.atsite > 0 ORDER BY pt.atsite DESC, pt.min_m ASC LIMIT 1;

  -- 30-day truck driver SET (fallback / context)
  v_truck_drivers := '[]'::jsonb; v_claimed_drives_truck := false;
  IF v_phys_vehicle IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('id', d.id, 'name', d.full_name, 'visits', d.n) ORDER BY d.n DESC),
           bool_or(d.id = v_visit.assigned_driver_id)
      INTO v_truck_drivers, v_claimed_drives_truck
    FROM (SELECT e.id, e.full_name, count(*)::int n
          FROM public.visits vv JOIN public.employees e ON e.id = vv.assigned_driver_id
          WHERE vv.vehicle_id = v_phys_vehicle AND vv.client_id NOT IN (365,76) AND vv.deleted_at IS NULL
            AND vv.visit_date BETWEEN v_visit.visit_date - 30 AND v_visit.visit_date + 30
          GROUP BY e.id, e.full_name) d;
    v_truck_drivers := COALESCE(v_truck_drivers, '[]'::jsonb);
  END IF;

  -- DAY-SPECIFIC crew on the GPS truck (assigned_driver + visit_team on that vehicle, that date).
  -- ⚠ NON-DUMP visits only: the dump visit's own driver IS the claim we are checking, so including it
  -- would let a false claim vote itself onto the crew (verified: it did). Regular client visits'
  -- driver + team are the independent "who was on that truck that day" signal.
  IF v_phys_vehicle IS NOT NULL THEN
    SELECT array_agg(DISTINCT eid) INTO v_day_crew_ids FROM (
      SELECT v2.assigned_driver_id eid FROM public.visits v2
        WHERE v2.vehicle_id = v_phys_vehicle AND v2.visit_date = v_visit.visit_date AND v2.deleted_at IS NULL
          AND v2.client_id NOT IN (365, 76) AND v2.assigned_driver_id IS NOT NULL
      UNION
      SELECT vt.employee_id FROM public.visits v2 JOIN public.visit_team vt ON vt.visit_id = v2.id
        WHERE v2.vehicle_id = v_phys_vehicle AND v2.visit_date = v_visit.visit_date AND v2.deleted_at IS NULL
          AND v2.client_id NOT IN (365, 76)
    ) x;
    SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name) ORDER BY e.full_name)
      INTO v_day_crew FROM public.employees e WHERE e.id = ANY (v_day_crew_ids);
  END IF;
  v_day_crew := COALESCE(v_day_crew, '[]'::jsonb);

  -- everyone who worked at all that day (non-dump visits, same independence reason)
  SELECT array_agg(DISTINCT eid) INTO v_worked_ids FROM (
    SELECT v2.assigned_driver_id eid FROM public.visits v2 WHERE v2.visit_date = v_visit.visit_date AND v2.deleted_at IS NULL AND v2.client_id NOT IN (365,76) AND v2.assigned_driver_id IS NOT NULL
    UNION
    SELECT vt.employee_id FROM public.visits v2 JOIN public.visit_team vt ON vt.visit_id = v2.id WHERE v2.visit_date = v_visit.visit_date AND v2.deleted_at IS NULL AND v2.client_id NOT IN (365,76)
  ) x;

  v_claimed_on_day_crew := v_visit.assigned_driver_id = ANY (COALESCE(v_day_crew_ids, '{}'::bigint[]));
  v_claimed_worked      := v_visit.assigned_driver_id = ANY (COALESCE(v_worked_ids, '{}'::bigint[]));

  -- ---- DEVICE (sparse until the frontend trail fills in) ----
  SELECT jsonb_build_object('device_token', a.device_token, 'ip', a.ip, 'platform', a.platform, 'screen', a.screen,
           'looks_like', CASE WHEN a.platform ILIKE '%ipad%' OR a.user_agent ILIKE '%ipad%' THEN 'truck iPad (shared)'
                              WHEN a.platform IS NOT NULL OR a.user_agent IS NOT NULL THEN 'personal phone' ELSE 'unknown' END,
           'device_claimed_as', (SELECT jsonb_agg(DISTINCT e2.full_name) FROM public.dump_activity a3 JOIN public.employees e2 ON e2.id=a3.driver_id WHERE a3.device_token=a.device_token))
    INTO v_device FROM public.dump_activity a WHERE a.dump_visit_id = p_dump_visit_id AND a.device_token IS NOT NULL ORDER BY a.at DESC LIMIT 1;

  -- ---- VERDICT: day-crew first, 30-day set as fallback ----
  IF v_phys_vehicle IS NULL THEN
    v_verdict := 'no_gps_anchor'; v_confidence := 'low'; v_likely := NULL;
  ELSIF COALESCE(array_length(v_day_crew_ids, 1), 0) >= 1 THEN
    IF v_claimed_on_day_crew THEN
      -- claimed driver WAS on that truck's crew that day
      IF array_length(v_day_crew_ids, 1) = 1 THEN v_verdict := 'consistent'; v_confidence := 'high';
      ELSE v_verdict := 'consistent_cannot_refute'; v_confidence := 'medium'; END IF;
      v_likely := v_claimed_name;
    ELSE
      -- claimed driver was NOT on that truck's crew that day
      IF array_length(v_day_crew_ids, 1) = 1 THEN
        SELECT full_name INTO v_solo_name FROM public.employees WHERE id = v_day_crew_ids[1];
        v_verdict := 'MISMATCH'; v_likely := v_solo_name;   -- sole crew on the truck that was there → strong lead
        v_confidence := CASE WHEN NOT v_claimed_worked THEN 'high' ELSE 'medium' END;
      ELSE
        v_verdict := 'suspicious_claimed_driver_not_on_this_truck'; v_likely := NULL;  -- several possible; device pins it
        v_confidence := CASE WHEN NOT v_claimed_worked THEN 'high' ELSE 'medium' END;
      END IF;
    END IF;
  ELSE
    -- no day-crew data for that truck/date → fall back to the 30-day truck-driver set
    IF NOT v_claimed_drives_truck THEN v_verdict := 'suspicious_claimed_driver_not_on_this_truck'; v_confidence := 'medium'; v_likely := NULL;
    ELSE v_verdict := 'consistent_cannot_refute'; v_confidence := 'low'; v_likely := v_claimed_name; END IF;
  END IF;

  RETURN jsonb_build_object(
    'dump_visit_id', p_dump_visit_id, 'site', v_site, 'visit_date', v_visit.visit_date,
    'nominal_start_at', v_visit.start_at,
    'claimed_driver', jsonb_build_object('id', v_visit.assigned_driver_id, 'name', v_claimed_name),
    'recorded_truck', v_recorded_truck,
    'gps', jsonb_build_object('window', jsonb_build_object('from', v_win_start, 'to', v_win_end),
      'trucks', COALESCE(v_gps, '[]'::jsonb), 'physically_present_truck', v_phys_truck,
      'physically_present_min_m', v_phys_min_m,
      'recorded_truck_matches_gps', (v_recorded_truck IS NOT DISTINCT FROM v_phys_truck)),
    'crew_on_gps_truck_that_day', v_day_crew,
    'claimed_driver_on_that_crew', v_claimed_on_day_crew,
    'claimed_driver_worked_that_day', v_claimed_worked,
    'truck_is_shared_by_30d', COALESCE(v_truck_drivers, '[]'::jsonb),
    'device', COALESCE(v_device, jsonb_build_object('note', 'no device signals on this dump yet (older dump / frontend just shipped)')),
    'verdict', v_verdict, 'confidence', v_confidence, 'likely_real_driver', v_likely,
    'note', 'Investigative lead, not proof. GPS pins the truck; the day-crew (driver+team on that truck that date) narrows the person; a name in likely_real_driver appears only when the day-crew is one person or the device pins it.'
  );
END;
$function$
;

-- ---------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------
do $$
declare d1 float; d2 float; d3 float; n int;
begin
  -- (a) the helper returns the NEARER of the two, in both directions
  -- a point sitting exactly on site 2 must read ~0 even though site 1 is 726 m away
  d1 := public.fn_dump_site_dist_m(26.2632563, -80.1552085, 26.2683192, -80.1506092, 26.2632563, -80.1552085);
  if d1 > 1 then raise exception 'a point ON site 2 reported % m, expected ~0', d1; end if;
  d2 := public.fn_dump_site_dist_m(26.2683192, -80.1506092, 26.2683192, -80.1506092, 26.2632563, -80.1552085);
  if d2 > 1 then raise exception 'a point ON site 1 reported % m, expected ~0', d2; end if;

  -- (b) CONTROL: the two sites really are ~726 m apart, so this is not a no-op test
  d3 := public.fn_dump_site_dist_m(26.2632563, -80.1552085, 26.2683192, -80.1506092, 26.2683192, -80.1506092);
  if d3 < 500 or d3 > 1000 then
    raise exception 'CONTROL FAILED: the two sites measure % m apart, expected ~726', d3;
  end if;

  -- (c) NEGATIVE CONTROL: a far-away point must NOT be swallowed by the two-site logic
  d1 := public.fn_dump_site_dist_m(25.7617, -80.1918, 26.2683192, -80.1506092, 26.2632563, -80.1552085);
  if d1 < 10000 then raise exception 'downtown Miami scored % m from Pompano', d1; end if;

  -- (d) dump_investigate now references the helper 3 times and holds no raw sqrt distance
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='dump_investigate'
     and pg_get_functiondef(p.oid) like '%fn_dump_site_dist_m%';
  if n <> 1 then raise exception 'dump_investigate does not call the helper'; end if;

  -- (e) and it ASSIGNS both Pompano points to different variables.
  --     ⚠ Asserting merely that both numbers APPEAR is not enough: this function's own
  --     comment block lists both coordinates, so a body that assigned the same point twice
  --     still "contained" both strings and the check passed. Caught by mutation-testing
  --     (duplicate the two assignments -> the weak version passed). Match the ASSIGNMENTS.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='dump_investigate'
     and pg_get_functiondef(p.oid) like '%v_site_lat := 26.2683192%'
     and pg_get_functiondef(p.oid) like '%v_site2_lat := 26.2632563%';
  if n <> 1 then
    raise exception 'dump_investigate does not assign the two DISTINCT Pompano sites';
  end if;

  raise notice 'DUMP TWO-SITE GEOFENCE OK - nearer-of-two works both ways, 726 m control fires, far point rejected';
end $$;

commit;
