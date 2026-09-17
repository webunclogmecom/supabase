-- ============================================================================
-- 2026-09-17_1835  Calendar "Hours driven": yard -> visits -> yard, timed by Google, per truck per day (part B)
-- ============================================================================
-- Fred, 2026-09-17: "This is not working at the Calendar App, which is the Hours Driven, the logic
-- for it, is to use the Google API to have a time it takes coming out of the YARD, up to the 1st
-- visit, from the 1st visit to the 2nd visit, and so on and so forth, up to the last visit then to
-- YARD back again, all on the same day at the calendar. Check how it's built today, and fix it."
-- Then: "No need to use Samsara for that today, because Samsara only gives us the past data, data of
-- times when we went there, not for future planning, so we need to use Google API for knowing how
-- much time we will drive that day for future visits and so on." Then "GO" on the defaults below.
--
-- WHAT WAS THERE. The Calendar's day header computed "Hours driven" in the browser: the day's
-- COMPLETED visits sorted by start, summing next.start_at minus previous.completed_at capped at
-- 120 minutes per gap, every truck mixed into one chain, no yard, no map. Not driving time.
--
-- WHAT THIS IS. One chain per TRUCK per day (four trucks run in parallel): yard, the stops in
-- order, yard. Every leg is a Google Routes drive time (TRAFFIC_UNAWARE, a time-independent
-- average, the same number at 3 AM and 9 AM) cached by location pair in ops.route_leg_cache. The
-- database builds the chains LIVE from ops.v_calendar_visit on every read, so a dragged, reassigned
-- or completed visit is never served under old numbers; only the LEGS are cached. A small edge
-- function (plan-drive-fill, service_role only) buys the missing legs: a nightly warm-up (cron
-- plan-drive-warm, today -7 .. +21 ET) and a throttled, single-flight kick the Calendar sends
-- through ops.request_drive_fill when it sees a gap. The browser never calls Google, never calls
-- the edge function and never holds a key: it reads ops.calendar_drive_days and kicks
-- ops.request_drive_fill with its staff session.
--
-- THE RULES ENCODED HERE (Fred's defaults, 2026-09-17 "GO"):
--   * stops = visits with visit_status in (scheduled, completed); skipped and cancelled never drive.
--     On a PAST day a stop that was never completed is left out and counted (not_completed_stops):
--     a past-day number is what was driven. Today and future days route the plan.
--   * order = completed_at when completed, else start_at when timed; untimed (all-day) stops are
--     appended after the timed ones by nearest neighbour from the previous stop (from the yard when
--     there is none), ties by id. ordered_by = measured | scheduled | assumed says which.
--   * yard return: two consecutive COMPLETED stops more than 4 hours apart split the chain with a
--     trip back to the yard (measured 2026-09-16: Moises sat at the yard 5 hours between a dump
--     stop and the night run). yard_returns lists them for the tooltip.
--   * Dump Offload visits are ordinary stops (job -> dump -> job is real driving).
--   * truck = ops.v_calendar_visit.vehicle_id, the EFFECTIVE truck (assigned, else the service-type
--     default; vehicle_source says which; default_stops counts the defaults so the tooltip can say
--     "not assigned to a truck yet"). A visit with no truck at all is listed on a 'No truck' row
--     (grain truck, group_id NULL) and drives nothing. grain 'driver' chains the same visits per
--     driver_id for the Day view lanes.
--   * a stop without coordinates is dropped from its chain and counted (stops_without_location),
--     never estimated. A leg over 250 km by great circle is 'implausible' (7 live properties carry
--     California or Quebec coordinates): never bought, never printed.
--   * the day value is a SUM ONLY WHEN EVERY LEG IS KNOWN (bool_and guard); a plain sum(seconds)
--     would print a partial figure as X.Xh. NULL renders '-' in the app with a plain sentence.
--   * budget: a THIRD fail-closed daily bucket (ops.plan_routing_usage, cap ops.plan_routing_cap()
--     = 300 attempts per ET day), never shared with the day markers' dispatch bucket (300) or the
--     DUMP app's (500): a shared fail-closed budget lets one caller starve another.
--   * retention: a cached leg is served for 30 days (Google Maps Platform Service Specific Terms
--     allow caching Routes results for up to 30 days), then bought again once. Cells are
--     round(lat, 2) / round(lng, 2) computed in SQL only (JS toFixed and Postgres round disagree at
--     .xx5), the sibling calculate-driving-time's cell rule.
--
-- Rule 8 (audit): ops.plan_routing_usage (a spend counter), ops.route_leg_fail (a per-pair failure
-- ledger), ops.plan_fill_request (a throttle) and ops.plan_fill_run (a single-flight latch) are
-- OPT-OUT: derived, transient, safe to TRUNCATE, no human edits, same reasoning as
-- ops.dispatch_routing_usage (2026-08-05_1456). Nothing on public.visits, public.properties or
-- ops.v_calendar_visit's definition changes.
--
-- Grants: the four tables are service_role only (Supabase's default ACL on ops hands authenticated
-- SELECT to every new table, so the REVOKEs below are load-bearing and the VERIFY reads relacl
-- back). Internal functions (fn_drive_chain, fn_drive_missing_pairs, plan_routing_take_tokens,
-- plan_fill_begin, plan_fill_end) are service_role only; the browser gets exactly two:
-- ops.calendar_drive_days (SECURITY DEFINER, read) and ops.request_drive_fill (SECURITY DEFINER,
-- kick; the vault key never leaves it). fn_drive_chain is SECURITY INVOKER on purpose: a definer
-- function a role can EXECUTE is an escalation surface; its callers (postgres through the two
-- definer functions, service_role through rpc) both hold SELECT on the views it reads.
--
-- Apply: node apply.js <this file> (Management API, one transaction). The cron is scheduled in a
-- separate submission after COMMIT (see the tail). Dry run first with --dry.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- PRE
-- ---------------------------------------------------------------------------
DO $pre$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='ops' AND table_name='route_leg_cache' AND column_name='duration_seconds') THEN
    RAISE EXCEPTION 'PRE: apply 2026-09-17_1830 first (duration_seconds missing)';
  END IF;
  IF to_regclass('ops.plan_routing_usage') IS NOT NULL OR to_regprocedure('ops.calendar_drive_days(date,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'PRE: objects already exist';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.v_depot) THEN
    RAISE EXCEPTION 'PRE: ops.v_depot has no row (depot_property_id / coordinates)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key') THEN
    RAISE EXCEPTION 'PRE: vault secret edge_invoke_service_key missing';
  END IF;
END $pre$;

-- ---------------------------------------------------------------------------
-- 1. The budget: cap, counter, chunked token grant (fail closed)
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.plan_routing_cap() RETURNS integer
LANGUAGE sql IMMUTABLE AS $$ SELECT 300 $$;
COMMENT ON FUNCTION ops.plan_routing_cap() IS 'Daily cap of Google Routes attempts for the Calendar Hours-driven planner. The ONE place the number lives: the reader, the edge function and the health check all call it.';

CREATE TABLE ops.plan_routing_usage (
  day          date PRIMARY KEY,
  calls        integer NOT NULL DEFAULT 0,
  last_call_at timestamptz
);
COMMENT ON TABLE ops.plan_routing_usage IS 'Google Routes attempts per ET day by plan-drive-fill (Calendar Hours driven). Third fail-closed bucket, independent of ops.dispatch_routing_usage and public.dump_eta_usage. Audit opt-out: a spend counter.';

CREATE FUNCTION ops.plan_routing_take_tokens(p_cap integer, p_n integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public, pg_temp AS $fn$
DECLARE
  v_day     date := (now() AT TIME ZONE 'America/New_York')::date;
  v_before  integer;
  v_granted integer;
BEGIN
  IF p_n IS NULL OR p_n <= 0 OR p_cap IS NULL THEN RETURN 0; END IF;
  INSERT INTO ops.plan_routing_usage (day, calls) VALUES (v_day, 0) ON CONFLICT (day) DO NOTHING;
  SELECT u.calls INTO v_before FROM ops.plan_routing_usage u WHERE u.day = v_day FOR UPDATE;
  v_granted := LEAST(p_n, GREATEST(0, p_cap - v_before));
  IF v_granted > 0 THEN
    UPDATE ops.plan_routing_usage u SET calls = u.calls + v_granted, last_call_at = now() WHERE u.day = v_day;
  END IF;
  RETURN v_granted;   -- 0 = nothing left today: the caller must NOT route
END $fn$;
COMMENT ON FUNCTION ops.plan_routing_take_tokens(integer, integer) IS 'Grants up to p_n attempts against today''s ET budget (p_cap), counting BEFORE any fetch; returns how many were granted (0 = cap reached). Row-locked, so concurrent runs cannot over-grant.';

-- ---------------------------------------------------------------------------
-- 2. Failure ledger, throttle, latch
-- ---------------------------------------------------------------------------
CREATE TABLE ops.route_leg_fail (
  origin_lat_r   numeric(6,2) NOT NULL,
  origin_lng_r   numeric(6,2) NOT NULL,
  dest_lat_r     numeric(6,2) NOT NULL,
  dest_lng_r     numeric(6,2) NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('no_route', 'bad_request')),
  failures       integer NOT NULL DEFAULT 1,
  last_error     text NOT NULL,
  last_failed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (origin_lat_r, origin_lng_r, dest_lat_r, dest_lng_r)
);
COMMENT ON TABLE ops.route_leg_fail IS 'Pairs Google refused (no route / bad request) for the Calendar planner. A pair is BLOCKED (not retried) while failures >= 3 and last_failed_at is within 7 days (no_route) or 24 hours (bad_request). A success deletes the row. Audit opt-out: a derived ledger.';

CREATE TABLE ops.plan_fill_request (
  range_from   date NOT NULL,
  range_to     date NOT NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (range_from, range_to)
);
COMMENT ON TABLE ops.plan_fill_request IS 'Browser kicks of the planner (ops.request_drive_fill): the throttle and the stalled detector. Rows older than a day are deleted by the cron wrapper. Audit opt-out: transient.';

CREATE TABLE ops.plan_fill_run (
  id            integer PRIMARY KEY CHECK (id = 1),
  running_since timestamptz
);
INSERT INTO ops.plan_fill_run (id, running_since) VALUES (1, NULL);
COMMENT ON TABLE ops.plan_fill_run IS 'Single-flight latch for plan-drive-fill: one run at a time, a stale latch (older than 3 minutes) is taken over. Audit opt-out: transient.';

CREATE FUNCTION ops.plan_fill_begin() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public, pg_temp AS $fn$
DECLARE v_ok boolean := false;
BEGIN
  UPDATE ops.plan_fill_run SET running_since = now()
   WHERE id = 1 AND (running_since IS NULL OR running_since < now() - interval '3 minutes')
   RETURNING true INTO v_ok;
  RETURN coalesce(v_ok, false);
END $fn$;

CREATE FUNCTION ops.plan_fill_end() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public, pg_temp AS $fn$
BEGIN
  UPDATE ops.plan_fill_run SET running_since = NULL WHERE id = 1;
END $fn$;

-- ---------------------------------------------------------------------------
-- 3. Geometry helper
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.fn_haversine_km(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL
    ELSE (2 * 6371.0088 * asin(sqrt(
         power(sin(radians((lat2 - lat1)::double precision) / 2), 2)
       + cos(radians(lat1::double precision)) * cos(radians(lat2::double precision))
       * power(sin(radians((lng2 - lng1)::double precision) / 2), 2))))::numeric END
$$;

-- ---------------------------------------------------------------------------
-- 4. THE chain builder: population, grouping, ordering, legs. One implementation.
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.fn_drive_chain(p_from date, p_to date)
RETURNS TABLE (
  visit_date          date,
  grain               text,
  group_id            bigint,
  group_name          text,
  group_color         text,
  seq                 integer,        -- 0 = the chain header row (always emitted, even with no legs); 1..n = legs
  from_kind           text,           -- 'yard' | 'visit'
  from_visit_id       bigint,
  from_code           text,
  from_lat            numeric,
  from_lng            numeric,
  to_kind             text,
  to_visit_id         bigint,
  to_code             text,
  to_lat              numeric,
  to_lng              numeric,
  to_vehicle_id       bigint,
  to_truck_name       text,
  o_lat_r             numeric,
  o_lng_r             numeric,
  d_lat_r             numeric,
  d_lng_r             numeric,
  leg_reason          text,           -- NULL | 'implausible'
  ordered_by          text,           -- 'measured' | 'scheduled' | 'assumed' | NULL (no routed stop)
  default_stops       integer,
  stops               integer,
  untimed_stops       integer,
  not_completed_stops integer,
  yard_returns        jsonb,
  no_location_ids     jsonb,
  no_truck_ids        jsonb,
  depot_missing       boolean,
  chain_visit_ids     jsonb
)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ops, public, pg_temp AS $fn$
#variable_conflict use_column
DECLARE
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_dep_lat numeric; v_dep_lng numeric; v_depot_missing boolean;
  g         record;
  n         integer; i integer; j integer; k integer;
  ord       integer[]; placed boolean[]; yard_after boolean[];
  cur_lat   numeric; cur_lng numeric; best integer; best_d numeric; dd numeric;
  v_untimed integer; v_ordered_by text; v_all_completed boolean;
  v_yard    jsonb; v_seq integer; v_chain jsonb;
  prev_kind text; prev_id bigint; prev_code text; prev_lat numeric; prev_lng numeric;
  v_no_truck boolean;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'fn_drive_chain: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  SELECT d.latitude, d.longitude INTO v_dep_lat, v_dep_lng FROM ops.v_depot d LIMIT 1;
  v_depot_missing := (v_dep_lat IS NULL OR v_dep_lng IS NULL);

  FOR g IN
    WITH base AS (
      SELECT v.id, v.visit_date AS vdate, v.visit_status, v.start_at, v.completed_at,
             coalesce(v.is_all_day, false) AS is_all_day,
             v.latitude, v.longitude, v.vehicle_id, v.vehicle_source, v.driver_id, v.client_code,
             v.truck_name, v.truck_color, v.driver_name, v.driver_color,
             CASE WHEN v.visit_status = 'completed' AND v.completed_at IS NOT NULL THEN v.completed_at
                  WHEN coalesce(v.is_all_day, false) = false AND v.start_at IS NOT NULL THEN v.start_at
             END AS order_at,
             (v.visit_status = 'completed' AND v.completed_at IS NOT NULL) AS is_completed,
             (v.visit_date < v_today AND v.visit_status <> 'completed') AS not_completed_past,
             (v.latitude IS NULL OR v.longitude IS NULL) AS no_loc
      FROM ops.v_calendar_visit v
      WHERE v.visit_date BETWEEN p_from AND p_to
        AND v.visit_status IN ('scheduled', 'completed')
    ), grains AS (
      SELECT b.*, 'truck'::text AS gr, b.vehicle_id AS gid, b.truck_name AS gname, b.truck_color AS gcolor FROM base b
      UNION ALL
      SELECT b.*, 'driver'::text, b.driver_id, b.driver_name, b.driver_color FROM base b WHERE b.driver_id IS NOT NULL
    )
    SELECT x.vdate, x.gr, x.gid, min(x.gname) AS gname, min(x.gcolor) AS gcolor,
      array_agg(x.id             ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS ids,
      array_agg(x.client_code    ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS codes,
      array_agg(x.latitude       ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS lats,
      array_agg(x.longitude      ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS lngs,
      array_agg(x.order_at       ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS ords,
      array_agg(x.is_completed   ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS comps,
      array_agg(x.vehicle_id     ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS vehs,
      array_agg(x.truck_name     ORDER BY x.order_at NULLS LAST, x.id) FILTER (WHERE NOT x.not_completed_past AND NOT x.no_loc) AS trucks,
      count(*) FILTER (WHERE x.not_completed_past) AS not_completed,
      count(*) FILTER (WHERE NOT x.not_completed_past AND x.vehicle_source = 'default') AS default_stops,
      coalesce(jsonb_agg(x.id ORDER BY x.id) FILTER (WHERE NOT x.not_completed_past AND x.no_loc), '[]'::jsonb) AS no_loc_ids,
      coalesce(jsonb_agg(x.id ORDER BY x.id) FILTER (WHERE NOT x.not_completed_past), '[]'::jsonb) AS all_ids,
      count(*) FILTER (WHERE NOT x.not_completed_past) AS all_n
    FROM grains x
    GROUP BY x.vdate, x.gr, x.gid
    ORDER BY x.vdate, x.gr, x.gid NULLS LAST
  LOOP
    v_no_truck := (g.gr = 'truck' AND g.gid IS NULL);
    n := coalesce(array_length(g.ids, 1), 0);

    -- ---- order the routed stops: timed first (already sorted), then untimed by nearest neighbour
    ord := '{}'; placed := array_fill(false, ARRAY[GREATEST(n, 1)]); v_untimed := 0;
    FOR i IN 1..n LOOP
      IF g.ords[i] IS NOT NULL THEN ord := ord || i; placed[i] := true; ELSE v_untimed := v_untimed + 1; END IF;
    END LOOP;
    IF v_untimed > 0 THEN
      IF coalesce(array_length(ord, 1), 0) = 0 THEN cur_lat := v_dep_lat; cur_lng := v_dep_lng;
      ELSE cur_lat := g.lats[ord[array_length(ord, 1)]]; cur_lng := g.lngs[ord[array_length(ord, 1)]]; END IF;
      FOR k IN 1..v_untimed LOOP
        best := NULL; best_d := NULL;
        FOR i IN 1..n LOOP
          IF NOT placed[i] THEN
            dd := coalesce(ops.fn_haversine_km(cur_lat, cur_lng, g.lats[i], g.lngs[i]), 0);
            IF best IS NULL OR dd < best_d THEN best := i; best_d := dd; END IF;   -- array order = id order, so ties keep the lower id
          END IF;
        END LOOP;
        ord := ord || best; placed[best] := true; cur_lat := g.lats[best]; cur_lng := g.lngs[best];
      END LOOP;
    END IF;
    v_all_completed := (n > 0) AND (SELECT bool_and(c) FROM unnest(g.comps) c);
    v_ordered_by := CASE WHEN n = 0 OR v_no_truck THEN NULL
                         WHEN v_untimed > 0 THEN 'assumed'
                         WHEN v_all_completed THEN 'measured'
                         ELSE 'scheduled' END;

    -- ---- yard returns: consecutive COMPLETED stops more than 4 hours apart
    yard_after := array_fill(false, ARRAY[GREATEST(n, 1)]); v_yard := '[]'::jsonb;
    FOR i IN 1..(n - 1) LOOP
      IF g.comps[ord[i]] AND g.comps[ord[i + 1]] AND (g.ords[ord[i + 1]] - g.ords[ord[i]]) > interval '4 hours' THEN
        yard_after[i] := true;
        v_yard := v_yard || jsonb_build_object('from_code', g.codes[ord[i]], 'to_code', g.codes[ord[i + 1]]);
      END IF;
    END LOOP;

    v_chain := '[]'::jsonb;
    FOR i IN 1..n LOOP v_chain := v_chain || to_jsonb(g.ids[ord[i]]); END LOOP;

    -- ---- header row (seq 0)
    visit_date := g.vdate; grain := g.gr; group_id := g.gid;
    group_name := coalesce(g.gname, CASE WHEN g.gr = 'truck' THEN 'No truck' ELSE 'No driver' END);
    group_color := g.gcolor;
    seq := 0; from_kind := NULL; from_visit_id := NULL; from_code := NULL; from_lat := NULL; from_lng := NULL;
    to_kind := NULL; to_visit_id := NULL; to_code := NULL; to_lat := NULL; to_lng := NULL; to_vehicle_id := NULL; to_truck_name := NULL;
    o_lat_r := NULL; o_lng_r := NULL; d_lat_r := NULL; d_lng_r := NULL; leg_reason := NULL;
    ordered_by := v_ordered_by; default_stops := g.default_stops::integer;
    stops := CASE WHEN v_no_truck THEN g.all_n::integer ELSE n END;
    untimed_stops := v_untimed; not_completed_stops := g.not_completed::integer;
    yard_returns := v_yard; no_location_ids := g.no_loc_ids;
    no_truck_ids := CASE WHEN v_no_truck THEN g.all_ids ELSE '[]'::jsonb END;
    depot_missing := v_depot_missing;
    chain_visit_ids := CASE WHEN v_no_truck THEN g.all_ids ELSE v_chain END;
    RETURN NEXT;

    -- ---- legs
    IF n > 0 AND NOT v_depot_missing AND NOT v_no_truck THEN
      v_seq := 0;
      prev_kind := 'yard'; prev_id := NULL; prev_code := NULL; prev_lat := v_dep_lat; prev_lng := v_dep_lng;
      FOR i IN 1..n LOOP
        j := ord[i];
        v_seq := v_seq + 1; seq := v_seq;
        from_kind := prev_kind; from_visit_id := prev_id; from_code := prev_code; from_lat := prev_lat; from_lng := prev_lng;
        to_kind := 'visit'; to_visit_id := g.ids[j]; to_code := g.codes[j]; to_lat := g.lats[j]; to_lng := g.lngs[j];
        to_vehicle_id := g.vehs[j]; to_truck_name := g.trucks[j];
        o_lat_r := round(prev_lat, 2); o_lng_r := round(prev_lng, 2); d_lat_r := round(to_lat, 2); d_lng_r := round(to_lng, 2);
        leg_reason := CASE WHEN ops.fn_haversine_km(prev_lat, prev_lng, to_lat, to_lng) > 250 THEN 'implausible' END;
        RETURN NEXT;
        prev_kind := 'visit'; prev_id := g.ids[j]; prev_code := g.codes[j]; prev_lat := g.lats[j]; prev_lng := g.lngs[j];
        IF i < n AND yard_after[i] THEN
          v_seq := v_seq + 1; seq := v_seq;
          from_kind := 'visit'; from_visit_id := prev_id; from_code := prev_code; from_lat := prev_lat; from_lng := prev_lng;
          to_kind := 'yard'; to_visit_id := NULL; to_code := NULL; to_lat := v_dep_lat; to_lng := v_dep_lng; to_vehicle_id := NULL; to_truck_name := NULL;
          o_lat_r := round(prev_lat, 2); o_lng_r := round(prev_lng, 2); d_lat_r := round(v_dep_lat, 2); d_lng_r := round(v_dep_lng, 2);
          leg_reason := CASE WHEN ops.fn_haversine_km(prev_lat, prev_lng, v_dep_lat, v_dep_lng) > 250 THEN 'implausible' END;
          RETURN NEXT;
          prev_kind := 'yard'; prev_id := NULL; prev_code := NULL; prev_lat := v_dep_lat; prev_lng := v_dep_lng;
        END IF;
      END LOOP;
      -- back to the yard
      v_seq := v_seq + 1; seq := v_seq;
      from_kind := prev_kind; from_visit_id := prev_id; from_code := prev_code; from_lat := prev_lat; from_lng := prev_lng;
      to_kind := 'yard'; to_visit_id := NULL; to_code := NULL; to_lat := v_dep_lat; to_lng := v_dep_lng; to_vehicle_id := NULL; to_truck_name := NULL;
      o_lat_r := round(prev_lat, 2); o_lng_r := round(prev_lng, 2); d_lat_r := round(v_dep_lat, 2); d_lng_r := round(v_dep_lng, 2);
      leg_reason := CASE WHEN ops.fn_haversine_km(prev_lat, prev_lng, v_dep_lat, v_dep_lng) > 250 THEN 'implausible' END;
      RETURN NEXT;
    END IF;
  END LOOP;
  RETURN;
END $fn$;
COMMENT ON FUNCTION ops.fn_drive_chain(date, date) IS 'Calendar Hours driven: builds every (visit_date, grain truck|driver, group) chain yard -> stops -> yard from ops.v_calendar_visit. seq 0 = header row, seq 1..n = legs with 2-decimal cells. INVOKER, service_role only; the browser reads ops.calendar_drive_days instead. Reads columns id, visit_date, visit_status, start_at, completed_at, is_all_day, latitude, longitude, vehicle_id, vehicle_source, driver_id, client_code, truck_name, truck_color, driver_name, driver_color (plpgsql: not dependency-tracked, a rename there breaks this at call time).';

-- ---------------------------------------------------------------------------
-- 5. Missing pairs: what plan-drive-fill must buy
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.fn_drive_missing_pairs(p_from date, p_to date)
RETURNS TABLE (o_lat_r numeric, o_lng_r numeric, d_lat_r numeric, d_lng_r numeric,
               from_lat numeric, from_lng numeric, to_lat numeric, to_lng numeric, nearest_date date)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ops, public, pg_temp AS $$
  SELECT m.o_lat_r, m.o_lng_r, m.d_lat_r, m.d_lng_r, m.from_lat, m.from_lng, m.to_lat, m.to_lng, m.nearest_date
  FROM (
    SELECT DISTINCT ON (c.o_lat_r, c.o_lng_r, c.d_lat_r, c.d_lng_r)
           c.o_lat_r, c.o_lng_r, c.d_lat_r, c.d_lng_r, c.from_lat, c.from_lng, c.to_lat, c.to_lng, c.visit_date AS nearest_date
    FROM ops.fn_drive_chain(p_from, p_to) c
    WHERE c.seq > 0
      AND c.leg_reason IS NULL
      AND NOT (c.o_lat_r = c.d_lat_r AND c.o_lng_r = c.d_lng_r)
      AND NOT EXISTS (SELECT 1 FROM ops.route_leg_cache rc
                       WHERE rc.origin_lat_r = c.o_lat_r AND rc.origin_lng_r = c.o_lng_r
                         AND rc.dest_lat_r = c.d_lat_r AND rc.dest_lng_r = c.d_lng_r
                         AND rc.traffic_aware = false AND rc.computed_at > now() - interval '30 days')
      AND NOT EXISTS (SELECT 1 FROM ops.route_leg_fail rf
                       WHERE rf.origin_lat_r = c.o_lat_r AND rf.origin_lng_r = c.o_lng_r
                         AND rf.dest_lat_r = c.d_lat_r AND rf.dest_lng_r = c.d_lng_r
                         AND rf.failures >= 3
                         AND rf.last_failed_at > now() - (CASE rf.kind WHEN 'no_route' THEN interval '7 days' ELSE interval '24 hours' END))
    ORDER BY c.o_lat_r, c.o_lng_r, c.d_lat_r, c.d_lng_r,
             abs(c.visit_date - (now() AT TIME ZONE 'America/New_York')::date)
  ) m
  ORDER BY (m.nearest_date >= (now() AT TIME ZONE 'America/New_York')::date) DESC,
           abs(m.nearest_date - (now() AT TIME ZONE 'America/New_York')::date)
$$;
COMMENT ON FUNCTION ops.fn_drive_missing_pairs(date, date) IS 'Distinct cell pairs of the chains in the range with no fresh (30-day) TRAFFIC_UNAWARE cache row and no active block in ops.route_leg_fail; same-cell and implausible legs never appear. Future first, nearest to today first. service_role only.';

-- ---------------------------------------------------------------------------
-- 6. THE read the Calendar makes
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.calendar_drive_days(p_from date, p_to date)
RETURNS TABLE (
  visit_date              date,
  grain                   text,
  group_id                bigint,
  group_name              text,
  group_color             text,
  default_stops           integer,
  stops                   integer,
  untimed_stops           integer,
  not_completed_stops     integer,
  stops_without_location  integer,
  yard_returns            jsonb,
  ordered_by              text,
  legs                    integer,
  legs_known              integer,
  drive_seconds           integer,
  distance_mi             numeric,
  complete                boolean,
  pending                 boolean,
  blocked_reason          text,
  blocked_code            text,
  blocked_from_code       text,
  depot_missing           boolean,
  chain                   jsonb,
  visit_ids               jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, public, pg_temp AS $fn$
#variable_conflict use_column
DECLARE
  v_role    text := coalesce(current_setting('role', true), 'none');
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_calls   integer;
  v_cap     integer := ops.plan_routing_cap();
  v_last_status text; v_last_details jsonb;
BEGIN
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_drive_days: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_drive_days: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  SELECT u.calls INTO v_calls FROM ops.plan_routing_usage u WHERE u.day = v_today;
  SELECT l.status, l.details INTO v_last_status, v_last_details
    FROM public.sync_log l WHERE l.sync_source = 'plan-drive-fill' AND l.started_at > now() - interval '24 hours'
    ORDER BY l.started_at DESC LIMIT 1;

  RETURN QUERY
  WITH ch AS (
    SELECT * FROM ops.fn_drive_chain(p_from, p_to)
  ), legs AS (
    SELECT ch.*,
      (ch.seq > 0 AND ch.o_lat_r = ch.d_lat_r AND ch.o_lng_r = ch.d_lng_r) AS same_cell,
      c.secs, c.dist,
      coalesce(f.blocked, false) AS blocked
    FROM ch
    LEFT JOIN LATERAL (
      SELECT CASE WHEN rc.duration_seconds IS NOT NULL
                   AND (round(rc.duration_seconds / 60.0) = rc.duration_minutes OR (rc.duration_minutes = 1 AND rc.duration_seconds < 90))
                  THEN rc.duration_seconds ELSE rc.duration_minutes * 60 END AS secs,
             rc.distance_mi AS dist
      FROM ops.route_leg_cache rc
      WHERE ch.seq > 0
        AND rc.origin_lat_r = ch.o_lat_r AND rc.origin_lng_r = ch.o_lng_r
        AND rc.dest_lat_r = ch.d_lat_r AND rc.dest_lng_r = ch.d_lng_r
        AND rc.traffic_aware = false AND rc.computed_at > now() - interval '30 days'
      LIMIT 1
    ) c ON true
    LEFT JOIN LATERAL (
      SELECT true AS blocked
      FROM ops.route_leg_fail rf
      WHERE ch.seq > 0
        AND rf.origin_lat_r = ch.o_lat_r AND rf.origin_lng_r = ch.o_lng_r
        AND rf.dest_lat_r = ch.d_lat_r AND rf.dest_lng_r = ch.d_lng_r
        AND rf.failures >= 3
        AND rf.last_failed_at > now() - (CASE rf.kind WHEN 'no_route' THEN interval '7 days' ELSE interval '24 hours' END)
      LIMIT 1
    ) f ON true
  ), scored AS (
    SELECT l.*,
      CASE WHEN l.seq = 0 THEN NULL
           WHEN l.leg_reason = 'implausible' THEN NULL
           WHEN l.same_cell THEN 60
           ELSE l.secs END AS seconds,
      CASE WHEN l.seq = 0 THEN NULL WHEN l.same_cell THEN 0 ELSE l.dist END AS miles,
      CASE WHEN l.seq = 0 THEN NULL
           WHEN l.leg_reason = 'implausible' OR (l.secs IS NOT NULL AND l.secs > 300 * 60) THEN 'implausible'
           WHEN l.same_cell THEN 'same-cell'
           WHEN l.secs IS NOT NULL THEN 'cache'
           WHEN l.blocked THEN 'failed'
           ELSE 'missing' END AS src
    FROM legs l
  )
  SELECT s.visit_date, s.grain, s.group_id, s.group_name, s.group_color,
    max(s.default_stops) FILTER (WHERE s.seq = 0)        AS default_stops,
    max(s.stops) FILTER (WHERE s.seq = 0)                AS stops,
    max(s.untimed_stops) FILTER (WHERE s.seq = 0)        AS untimed_stops,
    max(s.not_completed_stops) FILTER (WHERE s.seq = 0)  AS not_completed_stops,
    max(jsonb_array_length(s.no_location_ids)) FILTER (WHERE s.seq = 0) AS stops_without_location,
    (array_agg(s.yard_returns) FILTER (WHERE s.seq = 0))[1] AS yard_returns,
    max(s.ordered_by) FILTER (WHERE s.seq = 0)           AS ordered_by,
    (count(*) FILTER (WHERE s.seq > 0))::integer         AS legs,
    (count(s.seconds))::integer                          AS legs_known,
    CASE WHEN count(*) FILTER (WHERE s.seq > 0) = count(s.seconds) AND count(*) FILTER (WHERE s.seq > 0) > 0
         THEN sum(s.seconds)::integer END                AS drive_seconds,
    CASE WHEN count(*) FILTER (WHERE s.seq > 0) = count(s.seconds) AND count(*) FILTER (WHERE s.seq > 0) > 0
         THEN round(sum(s.miles)::numeric, 1) END        AS distance_mi,
    (count(*) FILTER (WHERE s.seq > 0) = count(s.seconds)) AS complete,
    -- pending = a leg is simply not fetched yet (nothing blocks it): the ONLY condition that polls or kicks
    (bool_or(s.src = 'missing')
      AND NOT bool_or(s.depot_missing)
      AND NOT bool_or(s.src = 'implausible')
      AND NOT bool_or(s.src = 'failed')
      AND NOT (v_last_details ->> 'key_rejected' = 'true' OR v_last_details ->> 'quota' = 'true' OR v_last_details ->> 'outage' = 'true' OR v_last_details ->> 'key_missing' = 'true')
      AND NOT (coalesce(v_calls, 0) >= v_cap)
      AND NOT EXISTS (SELECT 1 FROM ops.plan_fill_request r
                       WHERE r.range_from <= s.visit_date AND r.range_to >= s.visit_date
                         AND r.requested_at < now() - interval '120 seconds'
                         AND NOT EXISTS (SELECT 1 FROM public.sync_log sl WHERE sl.sync_source = 'plan-drive-fill' AND sl.started_at > r.requested_at))
      AND NOT (v_last_status = 'error')
    ) AS pending,
    CASE
      WHEN bool_or(s.depot_missing) THEN 'no_depot'
      WHEN bool_or(s.src = 'implausible') THEN 'implausible'
      WHEN bool_or(s.src = 'failed') THEN 'failed'
      WHEN NOT bool_or(s.src = 'missing') THEN NULL
      WHEN v_last_details ->> 'key_rejected' = 'true' THEN 'key_rejected'
      WHEN v_last_details ->> 'quota' = 'true' THEN 'quota'
      WHEN v_last_details ->> 'outage' = 'true' THEN 'outage'
      WHEN v_last_details ->> 'key_missing' = 'true' THEN 'no_key'
      WHEN coalesce(v_calls, 0) >= v_cap THEN 'budget'
      WHEN EXISTS (SELECT 1 FROM ops.plan_fill_request r
                    WHERE r.range_from <= s.visit_date AND r.range_to >= s.visit_date
                      AND r.requested_at < now() - interval '120 seconds'
                      AND NOT EXISTS (SELECT 1 FROM public.sync_log sl WHERE sl.sync_source = 'plan-drive-fill' AND sl.started_at > r.requested_at))
           THEN 'stalled'
      WHEN v_last_status = 'error' THEN 'stalled'
      ELSE NULL
    END AS blocked_reason,
    (array_agg(coalesce(s.to_code, 'yard') ORDER BY s.seq) FILTER (WHERE s.src IN ('implausible', 'failed')))[1] AS blocked_code,
    (array_agg(coalesce(s.from_code, 'yard') ORDER BY s.seq) FILTER (WHERE s.src IN ('implausible', 'failed')))[1] AS blocked_from_code,
    bool_or(s.depot_missing) AS depot_missing,
    coalesce(jsonb_agg(jsonb_build_object('seq', s.seq, 'to_kind', s.to_kind, 'to_code', s.to_code, 'to_visit_id', s.to_visit_id,
                                          'to_truck_name', s.to_truck_name, 'seconds', s.seconds, 'source', s.src)
                       ORDER BY s.seq) FILTER (WHERE s.seq > 0), '[]'::jsonb) AS chain,
    (array_agg(s.chain_visit_ids) FILTER (WHERE s.seq = 0))[1] AS visit_ids
  FROM scored s
  GROUP BY s.visit_date, s.grain, s.group_id, s.group_name, s.group_color
  ORDER BY s.visit_date, s.grain, s.group_name;
END $fn$;
COMMENT ON FUNCTION ops.calendar_drive_days(date, date) IS 'Calendar Hours driven, the one thing the app reads: per (visit_date, grain, group) the chain''s drive_seconds (NULL unless every leg is known), completeness, why it is blocked, and the chain for the tooltip. authenticated + service_role. Legs come from ops.route_leg_cache (TRAFFIC_UNAWARE, 30-day retention); missing legs are bought by plan-drive-fill.';

-- ---------------------------------------------------------------------------
-- 7. The kick the Calendar sends when it sees a gap
-- ---------------------------------------------------------------------------
CREATE FUNCTION ops.request_drive_fill(p_from date, p_to date, p_retry_failed boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, public, pg_temp AS $fn$
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
  v_key  text;
  v_run  timestamptz;
  v_hit  integer;
BEGIN
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'request_drive_fill: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'bad range');
  END IF;
  IF EXISTS (SELECT 1 FROM ops.plan_fill_request r WHERE r.requested_at > now() - interval '10 seconds') THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'recent');
  END IF;
  IF EXISTS (SELECT 1 FROM ops.plan_fill_request r
              WHERE r.range_from <= p_to AND r.range_to >= p_from AND r.requested_at > now() - interval '30 seconds') THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'recent');
  END IF;
  SELECT running_since INTO v_run FROM ops.plan_fill_run WHERE id = 1;
  IF v_run IS NOT NULL AND v_run > now() - interval '3 minutes' THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'busy');
  END IF;
  IF coalesce(p_retry_failed, false) THEN
    DELETE FROM ops.route_leg_fail rf
     USING (SELECT DISTINCT c.o_lat_r, c.o_lng_r, c.d_lat_r, c.d_lng_r FROM ops.fn_drive_chain(p_from, p_to) c WHERE c.seq > 0) p
     WHERE rf.origin_lat_r = p.o_lat_r AND rf.origin_lng_r = p.o_lng_r AND rf.dest_lat_r = p.d_lat_r AND rf.dest_lng_r = p.d_lng_r;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.fn_drive_missing_pairs(p_from, p_to)) THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'nothing missing');
  END IF;
  -- the gate IS the write: two tabs kicking together cannot both post
  INSERT INTO ops.plan_fill_request (range_from, range_to, requested_at) VALUES (p_from, p_to, now())
  ON CONFLICT (range_from, range_to) DO UPDATE SET requested_at = excluded.requested_at
    WHERE ops.plan_fill_request.requested_at < now() - interval '30 seconds';
  GET DIAGNOSTICS v_hit = ROW_COUNT;
  IF v_hit = 0 THEN RETURN jsonb_build_object('queued', false, 'reason', 'recent'); END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('plan-drive-fill', now(), now(), 'error', jsonb_build_object('trigger', 'kick', 'key_missing', true));
    RETURN jsonb_build_object('queued', false, 'reason', 'not set up');
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/plan-drive-fill',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('from', p_from, 'to', p_to, 'trigger', 'kick', 'limit', 60),
    timeout_milliseconds := 120000);
  RETURN jsonb_build_object('queued', true);
END $fn$;
COMMENT ON FUNCTION ops.request_drive_fill(date, date, boolean) IS 'The Calendar''s kick: asks plan-drive-fill to buy the missing legs of a range. Throttled (10 s global, 30 s per intersecting range), single-flight aware, never raises on the browser path. p_retry_failed clears the failure ledger for the range first (the Refresh drive times control). The vault key never leaves the function.';

-- ---------------------------------------------------------------------------
-- 8. The cron wrapper (postgres only)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.fn_request_plan_drive_fill() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_key   text;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  DELETE FROM ops.plan_fill_request WHERE requested_at < now() - interval '1 day';
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('plan-drive-fill', now(), now(), 'error', jsonb_build_object('trigger', 'cron', 'key_missing', true));
    RAISE WARNING 'edge_invoke_service_key vault secret missing; plan-drive-fill not requested';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/plan-drive-fill',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('from', v_today - 7, 'to', v_today + 21, 'trigger', 'cron', 'limit', 240),
    timeout_milliseconds := 120000);
END $fn$;
COMMENT ON FUNCTION public.fn_request_plan_drive_fill() IS 'Cron plan-drive-warm: asks plan-drive-fill to warm the legs of ET today -7 .. +21 every morning. Runs after vehicle-gps-reconcile-nightly (07:05 UTC) and the SA generator (10:00 UTC is later; the warm-up at 09:15 UTC catches the SA visits the next morning), so keep the three in that order.';

-- ---------------------------------------------------------------------------
-- 9. Grants, both directions
-- ---------------------------------------------------------------------------
REVOKE ALL ON ops.plan_routing_usage, ops.route_leg_fail, ops.plan_fill_request, ops.plan_fill_run FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ops.plan_routing_usage, ops.route_leg_fail, ops.plan_fill_request, ops.plan_fill_run TO service_role;

REVOKE ALL ON FUNCTION ops.plan_routing_cap() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.plan_routing_cap() TO authenticated, service_role;

REVOKE ALL ON FUNCTION ops.fn_haversine_km(numeric, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.fn_haversine_km(numeric, numeric, numeric, numeric) TO authenticated, service_role;

REVOKE ALL ON FUNCTION ops.plan_routing_take_tokens(integer, integer), ops.plan_fill_begin(), ops.plan_fill_end(),
                       ops.fn_drive_chain(date, date), ops.fn_drive_missing_pairs(date, date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.plan_routing_take_tokens(integer, integer), ops.plan_fill_begin(), ops.plan_fill_end(),
                          ops.fn_drive_chain(date, date), ops.fn_drive_missing_pairs(date, date)
  TO service_role;

REVOKE ALL ON FUNCTION ops.calendar_drive_days(date, date), ops.request_drive_fill(date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_drive_days(date, date), ops.request_drive_fill(date, date, boolean) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.fn_request_plan_drive_fill() FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON ops.v_depot TO service_role;   -- already true; stated so fn_drive_chain (INVOKER) cannot lose it silently

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- VERIFY (raises = whole migration rolls back)
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  t text; p text; v_acl text; v_n int; v_n2 int; v_g int; v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  r record; v_json jsonb;
BEGIN
  -- tables: authenticated holds nothing, relacl is the literal we intend
  FOREACH t IN ARRAY ARRAY['ops.plan_routing_usage', 'ops.route_leg_fail', 'ops.plan_fill_request', 'ops.plan_fill_run'] LOOP
    FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
      IF has_table_privilege('authenticated', t, p) THEN RAISE EXCEPTION 'VERIFY: authenticated holds % on %', p, t; END IF;
      IF has_table_privilege('anon', t, p) THEN RAISE EXCEPTION 'VERIFY: anon holds % on %', p, t; END IF;
    END LOOP;
    SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = t::regclass;
    IF v_acl IS DISTINCT FROM '{postgres=arwdDxtm/postgres,service_role=arwd/postgres,yannick_readonly=r/postgres}' THEN
      RAISE EXCEPTION 'VERIFY: % relacl unexpected: %', t, v_acl;
    END IF;
  END LOOP;
  -- functions
  IF has_function_privilege('anon', 'ops.calendar_drive_days(date,date)', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: anon can execute calendar_drive_days'; END IF;
  IF has_function_privilege('anon', 'ops.request_drive_fill(date,date,boolean)', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: anon can execute request_drive_fill'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.calendar_drive_days(date,date)', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: authenticated cannot execute calendar_drive_days'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.request_drive_fill(date,date,boolean)', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: authenticated cannot execute request_drive_fill'; END IF;
  FOREACH t IN ARRAY ARRAY['ops.fn_drive_chain(date,date)', 'ops.fn_drive_missing_pairs(date,date)', 'ops.plan_routing_take_tokens(integer,integer)', 'ops.plan_fill_begin()', 'ops.plan_fill_end()'] LOOP
    IF has_function_privilege('authenticated', t, 'EXECUTE') OR has_function_privilege('anon', t, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: browser role can execute %', t; END IF;
    IF NOT has_function_privilege('service_role', t, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: service_role cannot execute %', t; END IF;
  END LOOP;
  IF has_function_privilege('service_role', 'public.fn_request_plan_drive_fill()', 'EXECUTE') OR has_function_privilege('authenticated', 'public.fn_request_plan_drive_fill()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: cron wrapper executable by a non-owner';
  END IF;
  -- no PUBLIC entry on any new function
  SELECT count(*) INTO v_n FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'ops' AND pr.proname IN ('plan_routing_cap','plan_routing_take_tokens','plan_fill_begin','plan_fill_end','fn_haversine_km','fn_drive_chain','fn_drive_missing_pairs','calendar_drive_days','request_drive_fill')
     AND (pr.proacl IS NULL OR EXISTS (SELECT 1 FROM unnest(pr.proacl) a WHERE a::text LIKE '=X/%'));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: % new functions still carry a PUBLIC execute entry', v_n; END IF;
  -- service_role reads what the INVOKER chain builder needs
  IF NOT (has_table_privilege('service_role', 'ops.v_calendar_visit', 'SELECT') AND has_table_privilege('service_role', 'ops.v_depot', 'SELECT')
          AND has_table_privilege('service_role', 'ops.route_leg_cache', 'SELECT') AND has_table_privilege('service_role', 'ops.route_leg_fail', 'SELECT')) THEN
    RAISE EXCEPTION 'VERIFY: service_role lacks SELECT on a view fn_drive_chain reads';
  END IF;

  -- ---- shape of the chain on real data: every header has legs = stops + 1 (+ 1 per yard return: the trip back; the trip out replaces the direct leg) or 0 when unroutable
  SELECT count(*) INTO v_n FROM (
    SELECT h.visit_date, h.grain, h.group_id, h.stops, jsonb_array_length(h.yard_returns) AS yr,
           (SELECT count(*) FROM ops.fn_drive_chain(v_today - 14, v_today + 7) l
             WHERE l.visit_date = h.visit_date AND l.grain = h.grain AND l.group_id IS NOT DISTINCT FROM h.group_id AND l.seq > 0) AS legs
    FROM ops.fn_drive_chain(v_today - 14, v_today + 7) h WHERE h.seq = 0
  ) x
  WHERE NOT ((x.group_id IS NULL AND x.grain = 'truck' AND x.legs = 0) OR (x.stops = 0 AND x.legs = 0) OR (x.legs = x.stops + 1 + x.yr));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: % chains whose leg count is not stops + 1 + yard_returns', v_n; END IF;
  -- first leg leaves the yard, last leg returns to it, on every routed chain
  SELECT count(*) INTO v_n FROM (
    SELECT l.visit_date, l.grain, l.group_id,
           bool_and(CASE WHEN l.seq = 1 THEN l.from_kind = 'yard' ELSE true END) AS starts_at_yard,
           (array_agg(l.to_kind ORDER BY l.seq DESC))[1] = 'yard' AS ends_at_yard
    FROM ops.fn_drive_chain(v_today - 14, v_today + 7) l WHERE l.seq > 0
    GROUP BY 1, 2, 3
  ) y WHERE NOT (y.starts_at_yard AND y.ends_at_yard);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: % chains do not start and end at the yard', v_n; END IF;
  -- the reader runs for the browser role and returns one row per header
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today - 7, v_today + 7);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n2 FROM ops.fn_drive_chain(v_today - 7, v_today + 7) h WHERE h.seq = 0;
  IF v_n <> v_n2 THEN RAISE EXCEPTION 'VERIFY: calendar_drive_days rows (%) <> chain headers (%)', v_n, v_n2; END IF;
  -- no partial sums: every row with drive_seconds has legs_known = legs and legs > 0
  SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today - 7, v_today + 7) d
   WHERE d.drive_seconds IS NOT NULL AND NOT (d.legs_known = d.legs AND d.legs > 0);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: a row carries drive_seconds without every leg known'; END IF;
  -- the anon role is refused by the reader
  BEGIN
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM * FROM ops.calendar_drive_days(v_today, v_today);
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'VERIFY: anon was able to run calendar_drive_days';
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;

  -- ---- probes in a savepoint (rolled back by the RAISE at the end)
  BEGIN
    -- tokens: with cap - 2 used, asking 5 grants 2, then 0
    INSERT INTO ops.plan_routing_usage (day, calls) VALUES (v_today, ops.plan_routing_cap() - 2)
      ON CONFLICT (day) DO UPDATE SET calls = ops.plan_routing_cap() - 2;
    v_g := ops.plan_routing_take_tokens(ops.plan_routing_cap(), 5);
    IF v_g <> 2 THEN RAISE EXCEPTION 'PROBE: take_tokens granted % (expected 2)', v_g; END IF;
    v_g := ops.plan_routing_take_tokens(ops.plan_routing_cap(), 5);
    IF v_g <> 0 THEN RAISE EXCEPTION 'PROBE: take_tokens granted % at the cap (expected 0)', v_g; END IF;
    -- budget shows on the reader
    SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today, v_today + 7) d WHERE d.blocked_reason = 'budget';
    SELECT count(*) INTO v_n2 FROM ops.calendar_drive_days(v_today, v_today + 7) d WHERE NOT d.complete AND d.depot_missing = false;
    IF v_n2 > 0 AND v_n = 0 THEN RAISE EXCEPTION 'PROBE: budget reached but no row reads budget'; END IF;
    -- latch
    IF NOT ops.plan_fill_begin() THEN RAISE EXCEPTION 'PROBE: latch could not be taken'; END IF;
    IF ops.plan_fill_begin() THEN RAISE EXCEPTION 'PROBE: latch taken twice'; END IF;
    PERFORM ops.plan_fill_end();
    IF NOT ops.plan_fill_begin() THEN RAISE EXCEPTION 'PROBE: latch not released'; END IF;
    -- the miss detector can see: the first missing pair disappears when a cache row is inserted for it, and reappears when it is deleted
    SELECT * INTO r FROM ops.fn_drive_missing_pairs(v_today - 7, v_today + 7) LIMIT 1;
    IF r IS NULL THEN RAISE NOTICE 'PROBE: no missing pair in the window (cache already warm), detector control skipped'; ELSE
      SELECT count(*) INTO v_n FROM ops.fn_drive_missing_pairs(v_today - 7, v_today + 7);
      INSERT INTO ops.route_leg_cache (origin_lat_r, origin_lng_r, dest_lat_r, dest_lng_r, traffic_aware, duration_minutes, duration_seconds, distance_mi, computed_at)
      VALUES (r.o_lat_r, r.o_lng_r, r.d_lat_r, r.d_lng_r, false, 7, 400, 3.1, now());
      SELECT count(*) INTO v_n2 FROM ops.fn_drive_missing_pairs(v_today - 7, v_today + 7);
      IF v_n2 <> v_n - 1 THEN RAISE EXCEPTION 'PROBE: inserting a cache row did not remove exactly one missing pair (% -> %)', v_n, v_n2; END IF;
      -- the reader now reads that leg as 400 s from duration_seconds
      SELECT count(*) INTO v_n2 FROM ops.calendar_drive_days(v_today - 7, v_today + 7) d, jsonb_array_elements(d.chain) c
       WHERE (c ->> 'seconds')::int = 400 AND c ->> 'source' = 'cache';
      IF v_n2 = 0 THEN RAISE EXCEPTION 'PROBE: the inserted leg is not read back as 400 s'; END IF;
      -- a blocked failure for the same pair: the pair leaves the missing list and the chain reads failed
      DELETE FROM ops.route_leg_cache WHERE origin_lat_r = r.o_lat_r AND origin_lng_r = r.o_lng_r AND dest_lat_r = r.d_lat_r AND dest_lng_r = r.d_lng_r AND traffic_aware = false AND duration_seconds = 400;
      INSERT INTO ops.route_leg_fail (origin_lat_r, origin_lng_r, dest_lat_r, dest_lng_r, kind, failures, last_error, last_failed_at)
      VALUES (r.o_lat_r, r.o_lng_r, r.d_lat_r, r.d_lng_r, 'no_route', 3, 'probe', now());
      SELECT count(*) INTO v_n2 FROM ops.fn_drive_missing_pairs(v_today - 7, v_today + 7);
      IF v_n2 <> v_n - 1 THEN RAISE EXCEPTION 'PROBE: a blocked pair is still offered (% -> %)', v_n, v_n2; END IF;
      SELECT count(*) INTO v_n2 FROM ops.calendar_drive_days(v_today - 7, v_today + 7) d WHERE d.blocked_reason = 'failed' AND d.blocked_code IS NOT NULL;
      IF v_n2 = 0 THEN RAISE EXCEPTION 'PROBE: no chain reads failed while its pair is blocked'; END IF;
      -- the block expires: 8 days old for no_route
      UPDATE ops.route_leg_fail SET last_failed_at = now() - interval '8 days' WHERE last_error = 'probe';
      SELECT count(*) INTO v_n2 FROM ops.fn_drive_missing_pairs(v_today - 7, v_today + 7);
      IF v_n2 <> v_n THEN RAISE EXCEPTION 'PROBE: an expired block still hides the pair (% -> %)', v_n, v_n2; END IF;
    END IF;
    -- depot missing: every row reads no_depot, nothing pending
    DELETE FROM public.app_config WHERE key = 'depot_property_id';
    SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today, v_today + 7) d WHERE NOT (d.depot_missing AND d.blocked_reason = 'no_depot' AND d.pending = false AND d.legs = 0);
    SELECT count(*) INTO v_n2 FROM ops.calendar_drive_days(v_today, v_today + 7);
    IF v_n <> 0 OR v_n2 = 0 THEN RAISE EXCEPTION 'PROBE: with no depot, % of % rows are not no_depot/unpending/legless', v_n, v_n2; END IF;
    RAISE EXCEPTION 'probe_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'probe_rollback' THEN RAISE; END IF;
  END;
  -- the savepoint really rolled back
  IF EXISTS (SELECT 1 FROM ops.route_leg_fail WHERE last_error = 'probe') OR NOT EXISTS (SELECT 1 FROM public.app_config WHERE key = 'depot_property_id') THEN
    RAISE EXCEPTION 'VERIFY: probe changes survived the savepoint';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.plan_routing_usage) THEN RAISE EXCEPTION 'VERIFY: usage row survived the savepoint'; END IF;
  RAISE NOTICE 'VERIFY ok';
END $verify$;

COMMIT;

-- ---------------------------------------------------------------------------
-- AFTER COMMIT, in a separate submission (cron.schedule is not transactional in a useful way here):
--   select cron.schedule('plan-drive-warm', '15 9 * * *', 'select public.fn_request_plan_drive_fill();');
--   -- 09:15 UTC = 05:15 EDT / 04:15 EST. After vehicle-gps-reconcile-nightly (07:05 UTC), before the
--   -- office opens. The SA generator runs at 10:00 UTC; its new visits are warmed the next morning
--   -- or by the Calendar's kick when someone opens that week.
-- ---------------------------------------------------------------------------
