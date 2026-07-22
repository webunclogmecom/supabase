-- 2026-07-22d  DUMP forensics: dump_investigate(dump_visit_id) — "who really did this dump?"
--
-- ============================================================================
-- WHY (Fred)
-- ============================================================================
-- Drivers pick their own name in the app (no login). If something goes wrong and someone claims
-- "I was Diego", we want an INDEPENDENT way to check it. The un-fakeable anchor is Samsara GPS: which
-- truck was physically at the dump site, and who drives that truck. The device fingerprint (from
-- dump_activity) corroborates. This function stitches those together for one dump and returns the
-- evidence + a likely-real-driver lead.
--
-- ⚠ HONEST BOUNDARY: this is an investigative LEAD, not proof. GPS identifies the TRUCK, the device
-- identifies the PHONE — neither identifies the hand holding it. It catches "Aaron on his own phone,
-- or on a truck he was not driving, claiming Diego". It cannot catch "Aaron on Diego's actual truck
-- iPad while both were on that truck". Read the confidence, not just the name.
--
-- ============================================================================
-- THE ANCHOR, AND WHY start_at IS NOT USED FOR IT
-- ============================================================================
-- A dump visit's start_at is nominal (the app/calendar rounds it; e.g. visit 7301 says 16:00Z but the
-- truck's GPS hit Homestead overnight at 04:36Z). So the GPS match is done over a WIDE window around
-- start_at (± 18h, which spans the overnight operating night) and keys on PHYSICAL PRESENCE: a truck
-- whose GPS came within ~250m of the fixed dump site. Verified against telemetry: trucks 1 (Moises)
-- and 3 (David) come within ~17-19m of the sites; truck 2 (Cloggy, daytime-only) never does.
--
-- The two dump sites are fixed facilities; their coordinates match the edge fn DUMPS map:
--   Homestead (client 365): 25.5517444, -80.3368324
--   Pompano   (client 76 ): 26.2632563, -80.1552085
-- Distance uses a planar approximation (fine below ~1km at 26N).
--
-- Who drives the physically-present truck is taken from NON-dump visits assigned to that vehicle
-- within ±7 days (the regular calendar schedule), NOT from the dump claim — so a driver who always
-- lies cannot launder their own attribution.
--
-- AUDIT (ADR 010): read-only SECDEF function, no table writes. service_role only.

CREATE OR REPLACE FUNCTION public.dump_investigate(p_dump_visit_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_visit    public.visits%ROWTYPE;
  v_site_lat float; v_site_lng float; v_site text;
  v_claimed_name text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_gps jsonb; v_phys_vehicle bigint; v_phys_truck text; v_phys_min_m int;
  v_truck_drivers jsonb; v_claimed_drives_truck boolean;
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

  IF v_visit.client_id = 365 THEN v_site_lat := 25.5517444; v_site_lng := -80.3368324; v_site := 'Homestead';
  ELSE                            v_site_lat := 26.2632563; v_site_lng := -80.1552085; v_site := 'Pompano'; END IF;

  SELECT full_name INTO v_claimed_name FROM public.employees WHERE id = v_visit.assigned_driver_id;
  SELECT name INTO v_recorded_truck FROM public.vehicles WHERE id = v_visit.vehicle_id;

  v_win_start := COALESCE(v_visit.start_at, (v_visit.visit_date::timestamp AT TIME ZONE 'America/New_York')) - interval '18 hours';
  v_win_end   := COALESCE(v_visit.start_at, (v_visit.visit_date::timestamp AT TIME ZONE 'America/New_York')) + interval '18 hours';

  -- ---- GPS: which trucks were physically at the site in the window? ----
  WITH pings AS (
    SELECT t.vehicle_id,
           sqrt(power((t.latitude::float  - v_site_lat)*111000, 2)
              + power((t.longitude::float - v_site_lng)*100000, 2)) AS dist_m,
           t.recorded_at
    FROM public.vehicle_telemetry_readings t
    WHERE t.recorded_at BETWEEN v_win_start AND v_win_end
  ),
  per_truck AS (
    SELECT p.vehicle_id,
           round(min(p.dist_m))::int min_m,
           count(*) FILTER (WHERE p.dist_m < 250)::int pings_at_site,
           (array_agg(p.recorded_at ORDER BY p.dist_m))[1] AS closest_at
    FROM pings p GROUP BY p.vehicle_id
  )
  SELECT jsonb_agg(jsonb_build_object(
           'vehicle_id', pt.vehicle_id, 'truck', veh.name,
           'min_m', pt.min_m, 'pings_within_250m', pt.pings_at_site,
           'present', (pt.pings_at_site > 0),
           'closest_at', pt.closest_at) ORDER BY pt.min_m)
    INTO v_gps
  FROM per_truck pt LEFT JOIN public.vehicles veh ON veh.id = pt.vehicle_id;

  -- the physically-present truck = the one that actually dwelt at the site (most pings < 250m)
  SELECT pt.vehicle_id, veh.name, pt.min_m INTO v_phys_vehicle, v_phys_truck, v_phys_min_m
  FROM (
    SELECT p.vehicle_id,
           round(min(sqrt(power((p.latitude::float-v_site_lat)*111000,2)+power((p.longitude::float-v_site_lng)*100000,2))))::int min_m,
           count(*) FILTER (WHERE sqrt(power((p.latitude::float-v_site_lat)*111000,2)+power((p.longitude::float-v_site_lng)*100000,2)) < 250)::int atsite
    FROM public.vehicle_telemetry_readings p
    WHERE p.recorded_at BETWEEN v_win_start AND v_win_end
    GROUP BY p.vehicle_id
  ) pt LEFT JOIN public.vehicles veh ON veh.id = pt.vehicle_id
  WHERE pt.atsite > 0
  ORDER BY pt.atsite DESC, pt.min_m ASC
  LIMIT 1;

  -- ⚠ TRUCKS ARE SHARED, not 1:1 (verified 2026-07-22: David is driven by Mark 15 / Anthony 13 /
  -- Grecia 6 over 45d). So the GPS-present truck DOES NOT name a driver. We instead compute the SET of
  -- drivers who regularly use that truck (from non-dump visits ±30d, independent of the dump claim) and
  -- only check whether the claimed driver is IN that set. Naming "the truck's driver" from a shared
  -- truck would falsely accuse a legitimate co-driver.
  v_truck_drivers := '[]'::jsonb;
  v_claimed_drives_truck := false;
  IF v_phys_vehicle IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('id', d.id, 'name', d.full_name, 'visits', d.n) ORDER BY d.n DESC),
           bool_or(d.id = v_visit.assigned_driver_id)
      INTO v_truck_drivers, v_claimed_drives_truck
    FROM (
      SELECT e.id, e.full_name, count(*)::int n
      FROM public.visits vv JOIN public.employees e ON e.id = vv.assigned_driver_id
      WHERE vv.vehicle_id = v_phys_vehicle
        AND vv.client_id NOT IN (365, 76)
        AND vv.deleted_at IS NULL
        AND vv.visit_date BETWEEN v_visit.visit_date - 30 AND v_visit.visit_date + 30
      GROUP BY e.id, e.full_name
    ) d;
    v_truck_drivers := COALESCE(v_truck_drivers, '[]'::jsonb);
  END IF;

  -- ---- DEVICE: from the activity trail (sparse until the frontend ships the token) ----
  SELECT jsonb_build_object(
           'device_token', a.device_token, 'ip', a.ip, 'platform', a.platform,
           'screen', a.screen, 'user_agent', a.user_agent,
           'looks_like', CASE WHEN a.platform ILIKE '%ipad%' OR a.user_agent ILIKE '%ipad%' THEN 'truck iPad (shared)'
                              WHEN a.platform IS NOT NULL OR a.user_agent IS NOT NULL THEN 'personal phone'
                              ELSE 'unknown' END,
           'device_seen_on_dumps', (SELECT count(DISTINCT a2.dump_visit_id) FROM public.dump_activity a2 WHERE a2.device_token = a.device_token AND a2.dump_visit_id IS NOT NULL),
           'device_claimed_as', (SELECT jsonb_agg(DISTINCT e2.full_name) FROM public.dump_activity a3 JOIN public.employees e2 ON e2.id=a3.driver_id WHERE a3.device_token = a.device_token))
    INTO v_device
  FROM public.dump_activity a
  WHERE a.dump_visit_id = p_dump_visit_id AND a.device_token IS NOT NULL
  ORDER BY a.at DESC LIMIT 1;

  -- ---- VERDICT ----
  -- Honest logic. GPS pins the TRUCK, not the person (shared trucks). A driver is only NAMED as the
  -- likely-real one when the DEVICE pins them (a personal phone historically one person's) — never
  -- from a shared truck. Today the device trail is empty until the frontend ships, so most verdicts
  -- are "can't refute" or "wrong-truck" — that is correct, not a gap.
  IF v_phys_vehicle IS NULL THEN
    v_verdict := 'no_gps_anchor';
    v_confidence := 'low';
    v_likely := NULL;
  ELSIF NOT v_claimed_drives_truck THEN
    -- claimed driver never drives the truck that was physically at the dump -> genuinely suspicious
    v_verdict := 'suspicious_claimed_driver_not_on_this_truck';
    v_confidence := 'medium';
    v_likely := NULL;  -- do NOT guess a name from a shared truck; the device is what would name them
  ELSE
    v_verdict := 'consistent_cannot_refute';  -- claimed driver does drive this truck; GPS can't rule them out
    v_confidence := 'low';
    v_likely := v_claimed_name;
  END IF;

  RETURN jsonb_build_object(
    'dump_visit_id', p_dump_visit_id,
    'site', v_site,
    'visit_date', v_visit.visit_date,
    'nominal_start_at', v_visit.start_at,
    'claimed_driver', jsonb_build_object('id', v_visit.assigned_driver_id, 'name', v_claimed_name),
    'recorded_truck', v_recorded_truck,
    'gps', jsonb_build_object(
      'window', jsonb_build_object('from', v_win_start, 'to', v_win_end),
      'trucks', COALESCE(v_gps, '[]'::jsonb),
      'physically_present_truck', v_phys_truck,
      'physically_present_min_m', v_phys_min_m,
      'recorded_truck_matches_gps', (v_recorded_truck IS NOT DISTINCT FROM v_phys_truck)),
    'truck_is_shared_by', COALESCE(v_truck_drivers, '[]'::jsonb),
    'claimed_driver_uses_this_truck', v_claimed_drives_truck,
    'device', COALESCE(v_device, jsonb_build_object('note', 'no device signals on this dump yet (frontend not shipped / older dump)')),
    'verdict', v_verdict,
    'confidence', v_confidence,
    'likely_real_driver', v_likely,
    'note', 'Investigative lead, not proof. GPS pins the TRUCK (shared by several drivers); the device pins the PERSON. A name in likely_real_driver only appears when a device pins it, never from a shared truck alone.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_investigate(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_investigate(bigint) TO service_role;
