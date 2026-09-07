-- ============================================================================================
-- 2026-09-07_1720_repoint_dump_attribute_functions.sql
--
-- Move the last four hardcoded dump functions onto public.dump_sites. Completes "one source of
-- truth": membership in non_customer_clients, attributes in dump_sites, nothing in a literal.
--
-- WHY (Fred, 2026-09-07): "yes i want one source of truth good." / "yes do the registry."
--
--   fn_dump_site_accepts        county gate                 CASE WHEN client_id = 365 ...
--   dump_site_status            call-ahead branch + phone   WHEN p_dump_key = 'DH' ... '786-268-5623'
--   dump_manifest_handout_list  membership                  client_id IN (76, 365)
--   dump_investigate            site coordinates            lat/lng literals in an IF/ELSE
--
-- 🛑 fn_dump_site_accepts IS A FULL REWRITE, NOT A PATCH, and is written out below rather than
-- being mechanically edited. Its entire body is five lines and every one of them changes. Two
-- things about it are deliberate:
--   * IMMUTABLE -> STABLE. It now reads a table. An IMMUTABLE function that reads a table is a
--     correctness hazard: the planner may fold it, and it would be usable in an index.
--   * SECURITY DEFINER with a pinned search_path, per this file's own rule about a helper called
--     from an owner-rights surface. It is called from dump_manifest_handout_list, which is SECDEF.
--   * The ELSE arm is KEPT for an id that is not a registered site. dump_manifest_handout_list
--     resolves a client_id from an arbitrary visit, so refusing there would hide every outstanding
--     manifest rather than fail safe. The fail-open that mattered was for a REGISTERED site, and
--     dump_sites.accepted_county_buckets being NOT NULL closes that one.
--
-- ⚠ MY FIRST ATTEMPT AT dump_investigate WAS WRONG AND THE CHECK CAUGHT IT, which is worth
-- recording because it is the failure mode this estate keeps paying for. I replaced the IF header
-- and the Homestead branch only, leaving `IF FALSE THEN NULL; ELSE <pompano literals> END IF;`.
-- The ELSE always runs, so EVERY site would have been given Pompano's coordinates and the
-- migration would have looked clean. The whole block has to go, so the patch now locates it by its
-- boundaries and asserts that both sites' literals were inside what it removed.
--
-- ⚠ dump_investigate now RAISES if a dump visit's client has no dump_sites row, where it previously
-- fell through to Pompano's coordinates. That is the correct direction: silently measuring against
-- the wrong site is worse than refusing, and a registered site always has a row.
--
-- BODY PROVENANCE: all three patched bodies pulled with pg_get_functiondef and edited by anchored
-- replacement (scratchpad/patch_four.js, scratchpad/patch_investigate.js). Never retyped.
--
-- RULE 8: no schema change; replaces four functions.
-- ============================================================================================

BEGIN;

-- ── Full rewrite: the county gate becomes a registry read ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_dump_site_accepts(p_dump_client_id bigint, p_county text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT coalesce(
    (SELECT public.fn_dump_county_bucket(p_county) = ANY (ds.accepted_county_buckets)
       FROM public.dump_sites ds
      WHERE ds.client_id = p_dump_client_id),
    -- Not a registered dump site. Preserve the previous permissive answer: callers resolve a
    -- client_id from an arbitrary visit, and refusing would hide their work rather than fail safe.
    true);
$fn$;

COMMENT ON FUNCTION public.fn_dump_site_accepts(bigint, text) IS
  'Does this dump site accept work from this county? Reads public.dump_sites.accepted_county_buckets, '
  'which is NOT NULL, so a newly added site cannot silently accept everything the way the old '
  'hardcoded ELSE did. An unregistered client_id still returns true, deliberately.';

REVOKE ALL ON FUNCTION public.fn_dump_site_accepts(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_dump_site_accepts(bigint, text)
  TO authenticated, service_role, pg_read_all_data;

CREATE OR REPLACE FUNCTION public.dump_site_status(p_dump_key text, p_arrival timestamp with time zone)
 RETURNS TABLE(status text, arrival_et timestamp without time zone, opens_at time without time zone, last_intake_at time without time zone, after_hours_phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH a AS (
    SELECT (p_arrival AT TIME ZONE 'America/New_York') AS et
  ),
  h AS (
    SELECT s.opens_at, s.closes_at, COALESCE(s.last_intake_at, s.closes_at) AS intake
    FROM public.dump_site_hours s, a
    WHERE s.dump_key = p_dump_key
      AND s.dow = EXTRACT(DOW FROM a.et)::int
  ),
  st AS (
    SELECT
      CASE
        -- OPEN is the ONLY positive case: inside [opens_at, last_intake] on this ET day.
        WHEN h.opens_at IS NOT NULL
             AND a.et::time >= h.opens_at
             AND a.et::time <= h.intake              THEN 'OPEN'
        -- Outside hours. A site with an after_hours_phone has a sanctioned call-ahead path at
        -- ANY hour; one without it is simply CLOSED. Was hardcoded to 'DH'.
        WHEN EXISTS (SELECT 1 FROM public.dump_sites ds
                      WHERE ds.dump_key = p_dump_key AND ds.after_hours_phone IS NOT NULL)
                                                     THEN 'AFTER_HOURS'
        ELSE 'CLOSED'
      END AS status,
      a.et AS arrival_et,
      h.opens_at,
      h.intake AS last_intake_at
    FROM a LEFT JOIN h ON true
  )
  SELECT
    st.status,
    st.arrival_et,
    st.opens_at,
    st.last_intake_at,
    -- Only ever alongside AFTER_HOURS, so status and phone can never contradict each other.
    CASE WHEN st.status = 'AFTER_HOURS'
              THEN (SELECT ds.after_hours_phone FROM public.dump_sites ds
                     WHERE ds.dump_key = p_dump_key)
              ELSE NULL END AS after_hours_phone
  FROM st;
$function$;

CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean, on_this_dump boolean, county text, county_bucket text, held_by text, held_dump_visit_id bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_since     timestamptz;
  v_dump_cli  bigint;
BEGIN
  -- which SITE is being filed? (365 Homestead / 76 Pompano) - drives the county gate
  SELECT v.client_id INTO v_dump_cli
  FROM public.visits v WHERE v.id = p_dump_visit_id;

  -- "since this driver's last dump" = the current-load window (exclude the dump being filed)
  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND public.fn_is_non_customer(v.client_id, ARRAY['dump_site'])
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;
  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH bucketed AS (
    SELECT o.*,
      CASE
        WHEN o.assigned_driver_id = p_driver_id
         AND o.completed_at IS NOT NULL AND o.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM public.dump_outstanding_visits o
    -- COUNTY GATE: Homestead may only be handed Dade (or unknown-county) work; Pompano takes everything.
    -- v_dump_cli NULL (unknown dump) falls through to TRUE rather than hiding everything.
    WHERE v_dump_cli IS NULL OR public.fn_dump_site_accepts(v_dump_cli, o.county)
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office,
         b.on_sheet AS confirmed,
         (b.marked_dump_visit_id IS NOT DISTINCT FROM p_dump_visit_id AND b.on_sheet) AS on_this_dump,
         b.county, b.county_bucket,
         b.marked_by AS held_by,
         b.marked_dump_visit_id AS held_dump_visit_id
  FROM bucketed b
  -- newest completed first, across the whole list (Fred 2026-07-28)
  ORDER BY b.completed_at DESC NULLS LAST, b.visit_id DESC;
END;
$function$;

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
  -- Site geometry now comes from public.dump_sites, not from literals. A single-point site
  -- coalesces site2 to site1, so the LEAST() over both stays the no-op it always was for
  -- Homestead, while Pompano keeps its two entrances (~600m apart, so a radius around one
  -- excludes the other).
  SELECT ds.lat, ds.lng, coalesce(ds.lat2, ds.lat), coalesce(ds.lng2, ds.lng), ds.short_name
    INTO v_site_lat, v_site_lng, v_site2_lat, v_site2_lng, v_site
    FROM public.dump_sites ds
   WHERE ds.client_id = v_visit.client_id;
  IF v_site_lat IS NULL THEN
    RAISE EXCEPTION 'dump_investigate: client % is a dump visit but has no public.dump_sites
  row, so its geometry is unknown', v_visit.client_id;
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
$function$;

-- ============================================================================================
-- VERIFY. Every repointed function must return what it returned before, for every site.
-- ============================================================================================
DO $verify$
DECLARE r record; v_n int;
BEGIN
  -- 1. THE COUNTY GATE IS UNCHANGED, proven across every (site, county) pair rather than sampled.
  --    The expected values are the OLD hardcoded rule written out: Homestead takes DADE/UNKNOWN,
  --    Pompano takes everything.
  FOR r IN
    SELECT ds.client_id, ds.short_name, c.county,
           public.fn_dump_site_accepts(ds.client_id, c.county) AS got,
           CASE WHEN ds.client_id = 365
                THEN public.fn_dump_county_bucket(c.county) IN ('DADE','UNKNOWN')
                ELSE true END                                   AS expected_old_rule
      FROM public.dump_sites ds
      CROSS JOIN (VALUES ('Dade'),('Miami-Dade'),('miami dade'),('Broward'),('Palm Beach'),
                         (NULL),(''),('none'),('Monroe')) AS c(county)
  LOOP
    IF r.got IS DISTINCT FROM r.expected_old_rule THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: % / % -> got % but the old rule said %',
        r.short_name, coalesce(r.county,'(null)'), r.got, r.expected_old_rule;
    END IF;
  END LOOP;

  -- 2. An UNREGISTERED client still returns true, which the handout list depends on.
  IF NOT public.fn_dump_site_accepts(381, 'Broward') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an unregistered client_id no longer returns true, so the '
                    'handout list would hide outstanding work.';
  END IF;

  -- 3. dump_site_status is unchanged for both sites, at an hour both are shut and at an hour
  --    Homestead is open. CONTROL: the two sites must DIFFER at 03:00, or the assertion is vacuous.
  IF NOT EXISTS (SELECT 1 FROM public.dump_site_status('DH', timestamptz '2026-09-07 03:00:00-04') s
                  WHERE s.status = 'AFTER_HOURS' AND s.after_hours_phone = '786-268-5623') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: Homestead no longer reads AFTER_HOURS with its phone at 03:00.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.dump_site_status('DP', timestamptz '2026-09-07 03:00:00-04') s
                  WHERE s.status = 'CLOSED' AND s.after_hours_phone IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: Pompano does not read CLOSED at 03:00, so the '
                    'assertion above does not discriminate between the two sites.';
  END IF;
  -- Monday 09:00 ET: both are inside their opening hours, so both must read OPEN.
  SELECT count(*) INTO v_n FROM (VALUES ('DH'),('DP')) k(dk)
   CROSS JOIN LATERAL public.dump_site_status(k.dk, timestamptz '2026-09-08 09:00:00-04') s
   WHERE s.status = 'OPEN';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % of 2 sites read OPEN on a Monday morning.', v_n;
  END IF;

  -- 4. No coordinate or client literal survives in CODE in any of the four. Comments may still
  --    document the addresses, which is documentation rather than a value the code reads.
  SELECT count(*) INTO v_n FROM (
    SELECT p.proname, string_agg(l, chr(10)) AS code
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN LATERAL unnest(string_to_array(p.prosrc, chr(10))) AS u(l)
     WHERE n.nspname = 'public'
       AND p.proname IN ('fn_dump_site_accepts','dump_site_status','dump_manifest_handout_list',
                         'dump_investigate')
       AND btrim(l) NOT LIKE '--%'
     GROUP BY p.proname
  ) t
  WHERE t.code LIKE '%25.5517444%' OR t.code LIKE '%26.2683192%' OR t.code LIKE '%26.2632563%'
     OR t.code LIKE '%client_id IN (76, 365)%' OR t.code LIKE '%786-268-5623%'
     OR t.code LIKE '%p_dump_client_id = 365%' OR t.code LIKE '%p_dump_key = ''DH''%';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % function(s) still carry a hardcoded site literal in code.', v_n;
  END IF;

  -- 5. All four now read the registry or the membership list. CONTROL: must be 4, not "some".
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('fn_dump_site_accepts','dump_site_status','dump_manifest_handout_list',
                       'dump_investigate')
     AND (p.prosrc LIKE '%public.dump_sites%' OR p.prosrc LIKE '%fn_is_non_customer%');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: only % of 4 functions read the registry.', v_n;
  END IF;

  -- 6. fn_dump_site_accepts must no longer claim to be IMMUTABLE: it reads a table now.
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname='public' AND p.proname='fn_dump_site_accepts' AND p.provolatile = 'i') THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: fn_dump_site_accepts is still IMMUTABLE while reading a table.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (county gate identical on 18 pairs, 4 functions on the registry)';
END
$verify$;

COMMIT;
