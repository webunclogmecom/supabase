-- =============================================================================
-- 2026-11-17_1745_portal_my_work_tank_readings_fast.sql
--
-- WHAT: ops.portal_my_work() reads a truck's last tank readings (the Ops Portal Home's My truck card) in a few
--   milliseconds instead of over 20 seconds. One read in the body changes: the newest reading of each of the truck's
--   live tanks comes straight from the tables by index (vehicle_tanks -> tank_sensor_installations -> the newest
--   tank_sensor_distance_readings row inside the installation's window -> the configuration in force at that reading ->
--   public.fn_tank_fill_fraction), where it used DISTINCT ON over public.v_tank_levels. Same answer, same JSON.
--   No index, no view change, no grant change. Nothing else in the body moved (diff it against the rollback file).
--
-- WHY: Trello #226, "Ops Portal My work: the My truck card's tank readings take over 20 seconds". Found 2026-11-17
--   while rehearsing 2026-11-17_1615_portal_home_crew_assigned_truck.sql: for a person with a truck the call could
--   not finish in time, and app calls stop at 8 s, so a driver's Home (My truck card: last tank readings, Book a dump)
--   could never load.
--
-- HOW MEASURED, on Prod 2026-11-17 between 5:30 and 5:45 PM ET (read only, as postgres):
--   EXPLAIN (ANALYZE, BUFFERS) of the old read for Moises (vehicle 1): Execution Time 20,812 ms. The plan:
--     Seq Scan on tank_sensor_distance_readings, 299,460 rows (54 ms)
--     -> per row: the installation lookup (Memoize, 0 hits of 299,460) and the configuration lookup (index, 299,062
--        loops): 1,976 ms for the joins
--     -> per row: public.fn_tank_fill_fraction twice (fill_percent and gallons): about 18,000 ms. The function is SQL
--        with SET search_path, so Postgres cannot inline it and pays a full function call each time
--     -> Subquery Scan, "Filter: (l.vehicle_id = 1)" only AFTER all of that, 298,433 rows kept
--     -> Sort, external merge on disk 13 MB, then DISTINCT ON keeps 2 rows.
--   The old read per truck, timed on one snapshot: Moises 20,499 ms (2 tanks), Cloggy 19,549, David 19,402,
--   Goliath 22,270, a vehicle id that does not exist 20,065 (all three: no tanks, answer []). The cost is the same for
--   every truck because the view works out every reading before the truck filter applies.
--
-- CAUSE: the view's column is_new_measurement is a window, lag() OVER (PARTITION BY tank_sensor_id ORDER BY
--   recorded_at). Postgres may push a filter into a view with a window only when it is on the window's partition column,
--   so "vehicle_id = X" (and any time filter) stays outside and the view computes all ~300,000 readings (both sensors are
--   on Moises; about 4,600 more a day, so the read got slower every day) before DISTINCT ON keeps the newest per tank.
--   Most of the time is the fill formula per row (above). Not a missing index: the readings already have the index this
--   needs (primary key tank_sensor_id, recorded_at), and an index cannot help a filter that never reaches the table.
--   So there is no CREATE INDEX here. The view is left as it is: its other readers (v_tank_data_quality_issues,
--   fn_measure_vehicle_stop_tank_levels, fn_stop_facts_checks, fn_tank_reading_ghosts) read whole histories, and even a
--   pushable view would still work out every Moises reading for this question.
--
-- THE NEW READ, and why it is the same answer: per live tank of the truck (vehicle_tanks_one_live: one per contents),
--   per live installation on that tank, the newest reading of its sensor inside [installed_at, removed_at) (the primary
--   key read backwards, one row), the newest of those, then the configuration in force at that reading (newest
--   effective_from at or before it, not superseded), then fill_percent and gallons with the view's own expressions and
--   rounding. It equals the view's DISTINCT ON because the exclusion constraints tsi_no_overlap_per_sensor and
--   tsi_no_overlap_per_tank allow one live installation per sensor and per tank at any instant (so the view's
--   "ORDER BY installed_at DESC LIMIT 1" never chooses), and because configurations are ordered by effective_from: if
--   the newest reading has no configuration in force, no older reading has one either, and both reads drop the tank.
--   ⚠ This repeats the view's join in a second place. Change them together: the header comment in the body says so,
--   and this VERIFY compares the two answers.
--
-- BEFORE / AFTER, the same snapshot per truck (REPEATABLE READ, read only): old 19,402 to 22,270 ms; new 3.8 to 5.6 ms;
--   the JSON equal for all five ids. Moises: [{"at": "2026-11-17T22:34:58+00:00", "gallons": 417, "percent": 35,
--   "contents": "fresh_water"}, {"at": "2026-11-17T22:35:00+00:00", "gallons": 400, "percent": 10, "contents": "sludge"}]
--   from both. EXPLAIN (ANALYZE, BUFFERS) of the new read for Moises: Execution Time 2.3 ms, shared hit 424 buffers (the
--   old: 1,199,040 and a 13 MB sort on disk); index scans only: vehicle_tanks_one_live, tsi_no_overlap_per_tank, the
--   readings' primary key backwards (1 row per installation), vtc_live_effective backwards (1 row per tank).
--   Edge cases, rolled back (fixture on Moises: installation 2 ended 1 hour before its newest reading, sensor 2
--   re-installed on the same tank for a 10-minute window, a superseded installation and a superseded configuration that
--   must be ignored, a new live sludge configuration 2 hours back, a fresh_water configuration starting tomorrow): the
--   answer changed (fresh_water 22:39:57 -> 22:19:41 from the second installation, sludge 400 -> 296 gallons under the
--   new configuration) and old = new (new 1.6 ms, old 20,303 ms). Afterwards: installation 2 removed_at still NULL, 0
--   fixture rows (ids 900001 to 900005, written with OVERRIDING SYSTEM VALUE so no identity value was used).
--
-- REHEARSED, rolled back on Prod on 2026-11-17 (this whole file with COMMIT replaced by a statement that raises):
--   apply: this file as written, COMMIT replaced by a statement that raises (so the whole transaction is undone).
--     VERIFY passed: person 59 (the one field sign-in, no stop of their own) on probe stop 6169 (Moises, scheduled);
--     the whole call as authenticated 100.0 ms; truck Moises; tanks equal to the view's (fresh_water 417 gallons 35 %
--     at 5:44:45 PM ET, sludge 400 gallons 10 % at 5:45:00 PM ET); the view read 20,081 ms; installed md5 0d2f8eff...;
--     isolation repeatable read.
--   control, the OLD body: the same file with the CREATE OR REPLACE taken out FAILS, as it must: "verify_fail: my work
--     for a driver with a truck took 20294.9 ms (limit 2,000; the app stops at 8,000)".
--   rollback: this file, then the rollback file, in one transaction: VERIFY passed (call 128.3 ms), then the rollback's
--     VERIFY passed and the body ended on md5 1f6f9ed21ecfa5600571e2bd27e644ed.
--   rollback control: the rollback file alone against the live body: its guard refuses ("is not the 2026-11-17_1745
--     body (md5 1f6f9ed...)").
--   Afterwards: live md5 still 1f6f9ed...; visit 6169's crew still 40 and 43; person 59 still only on visit 9080
--     (2026-11-05); 0 audit rows on visit_team or visit_assignments in the 30 minutes around the runs.
--
-- MD5: ops.portal_my_work 1f6f9ed21ecfa5600571e2bd27e644ed (2026-11-17_1615) -> 0d2f8eff1b8c8a9af76526ac03a154a6.
--   The body is the LIVE pg_get_functiondef text with two anchored edits made by a script (each anchor found exactly
--   once): a dated comment after the #224 comment, and the tank read (the FROM of the 'tanks' subquery).
-- ACCESS: unchanged. SECURITY DEFINER, empty search_path; CREATE OR REPLACE keeps the grants (authenticated and
--   service_role; VERIFY checks anon still cannot run it). The My work door in public.fn_request_gate is untouched.
-- RULE 8, AUDIT: no table written by the function. The VERIFY's probe writes one public.visit_team row (audited) and
--   undoes it in the same breath (below), so no audit row survives.
-- LOCKS: no table or view DDL. CREATE OR REPLACE FUNCTION takes no lock that a caller of the function waits on (a call
--   in flight keeps the old body). The VERIFY reads the view once (about 20 s) holding only ACCESS SHARE, which blocks
--   no app read and does not conflict with the HH:17 UTC backup dump. lock_timeout 3 s: if it times out, run it again.
-- ISOLATION: REPEATABLE READ, so the VERIFY's call and its view read see the same readings (new readings arrive about
--   every 5 minutes, and the view read takes 20 s).
-- VERIFY: puts a SCHEDULED stop of the day on a truck with tanks (Moises) on the one field person with a sign-in and no
--   stop of their own, calls the whole new body as that person (authenticated, request.jwt.claims), then RAISES inside
--   its own block, which undoes that stop (a subtransaction; the visit and its crew are as before). It needs such a stop
--   and such a person: if either is missing it refuses with a sentence, so apply while Moises has a scheduled stop that
--   day (most evenings; on 2026-11-17 at 5:45 PM ET it had 6). It checks: the call took under 2,000 ms, named the stop's
--   truck, its tanks equal the old read over the view (verbatim) for that truck and are not empty, the probe stop is
--   gone, the grants, and last the installed md5.
-- ON APPLY, in the same cycle: claim ops.portal_my_work in WORKING-NOW.md first. Afterwards: the Supabase CLAUDE.md
--   "THE MY WORK DOOR" (portal_my_work bullet: the tank read and the warning to change it with the view),
--   docs/04-backend.md of the portal and Building Apps/Ops Portal/docs/08-changelog.md, memory, Trello #226. The 1615
--   migration's sentences about the 20 s read stay as they are: that file is history.
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-17_1745_portal_my_work_tank_readings_fast_rollback.sql (puts back the 1f6f9ed body verbatim).
-- =============================================================================

BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '1f6f9ed21ecfa5600571e2bd27e644ed' THEN
    RAISE EXCEPTION 'guard: ops.portal_my_work() changed since this was written (md5 %)', md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure));
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION ops.portal_my_work()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-16 (Trello #210, Fred's pick HF1, default "fieldread"): the signed-in person's OWN day for the Ops Portal's
-- Home: their visits (the Calendar's crew rule: the visit's driver or a member of its team), the truck of those visits
-- with its last tank readings, the forms assigned to them (client.fn_intake_assigned_to_me, the one rule), and how many
-- visits they finished in the last 7 days. Never another person's work, never money, never notes or access codes.
-- The Field group opens no app, so public.fn_request_gate lets exactly this function through for them (the My work door).
-- A night truck works one visit date from about 9 PM to 5 AM, so until 6 AM ET the day is still the evening's date.
-- 2026-11-17 (Trello #224): "my truck" is the truck of the first visit whose truck is ASSIGNED, never the Calendar's
-- guess for a visit with no truck (Grecia's day read "on Moises" from visit 8597 while her assigned visits were on Cloggy).
-- 2026-11-17 (Trello #226): the tank readings read the newest reading of each of the truck's live tanks straight from the
-- tables (a few index lookups): the same join and the same numbers as public.v_tank_levels gives for that truck. Through
-- the view this read took over 20 s for any truck, because the view's lag() window keeps the truck filter out, so it
-- worked out every reading ever taken (about 300,000 on 2026-11-17, about 4,600 more a day) before keeping two.
-- Change this read together with the view's join (installation, tank, configuration, fill formula).
DECLARE
  v_emp bigint := hr.fn_access_caller();
  v_day date := ((now() AT TIME ZONE 'America/New_York') - interval '6 hours')::date;
  v_out jsonb;
  v_vehicle bigint;
BEGIN
  IF v_emp IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  WITH mine AS MATERIALIZED (
    SELECT v.*
      FROM ops.v_calendar_visit v
     WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
       AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp))
  )
  SELECT jsonb_build_object(
      'date', v_day,
      'stops', coalesce(jsonb_agg(jsonb_build_object(
          'id', m.id, 'at', m.start_at, 'all_day', coalesce(m.is_all_day, false), 'status', m.visit_status,
          'late', coalesce(m.late_status = 'late', false), 'code', m.client_code, 'client', m.client_name,
          'address', m.address, 'city', m.city, 'zone', m.zone, 'lat', m.latitude, 'lng', m.longitude,
          'work', m.service_label, 'manholes', m.manholes, 'trap', m.equipment_size_gallons, 'derm', m.derm_required,
          'open_from', m.access_hours_start, 'open_to', m.access_hours_end, 'truck', m.truck_name,
          'site_file', (SELECT l.public_id FROM public.property_page_links l
                         WHERE l.property_id = m.property_id
                           AND EXISTS (SELECT 1 FROM public.property_pages p WHERE p.property_id = m.property_id AND p.approved_at IS NOT NULL)))
        ORDER BY m.start_at NULLS LAST, m.id), '[]'::jsonb)),
    (SELECT m2.vehicle_id FROM mine m2 WHERE m2.vehicle_source = 'assigned' ORDER BY m2.start_at NULLS LAST, m2.id LIMIT 1)
    INTO v_out, v_vehicle
    FROM mine m;

  v_out := v_out || jsonb_build_object(
    'truck', CASE WHEN v_vehicle IS NULL THEN NULL ELSE jsonb_build_object(
      'name', (SELECT vh.name FROM public.vehicles vh WHERE vh.id = v_vehicle),
      'tanks', coalesce((SELECT jsonb_agg(jsonb_build_object('contents', t.contents, 'percent', round(t.fill_percent::numeric),
                                                             'gallons', round(t.gallons::numeric), 'at', t.recorded_at) ORDER BY t.contents)
                           FROM (SELECT vt.contents, round(100::numeric * f.fill_fraction, 3) AS fill_percent,
                                        round(f.fill_fraction * c.capacity_gallons, 1) AS gallons, r.recorded_at
                                   FROM public.vehicle_tanks vt
                                   CROSS JOIN LATERAL (SELECT d.recorded_at, d.distance_meters
                                                         FROM public.tank_sensor_installations i
                                                         CROSS JOIN LATERAL (SELECT d1.recorded_at, d1.distance_meters
                                                                               FROM public.tank_sensor_distance_readings d1
                                                                              WHERE d1.tank_sensor_id = i.tank_sensor_id AND d1.recorded_at >= i.installed_at
                                                                                AND d1.recorded_at < coalesce(i.removed_at, 'infinity'::timestamptz)
                                                                              ORDER BY d1.recorded_at DESC LIMIT 1) d
                                                        WHERE i.vehicle_tank_id = vt.id AND i.superseded_at IS NULL
                                                        ORDER BY d.recorded_at DESC LIMIT 1) r
                                   CROSS JOIN LATERAL (SELECT c1.diameter_meters, c1.sensor_offset_meters, c1.capacity_gallons
                                                         FROM public.vehicle_tank_configurations c1
                                                        WHERE c1.vehicle_tank_id = vt.id AND c1.superseded_at IS NULL AND c1.effective_from <= r.recorded_at
                                                        ORDER BY c1.effective_from DESC LIMIT 1) c
                                   CROSS JOIN LATERAL (SELECT public.fn_tank_fill_fraction(r.distance_meters, c.diameter_meters, c.sensor_offset_meters) AS fill_fraction) f
                                  WHERE vt.vehicle_id = v_vehicle AND vt.deleted_at IS NULL) t), '[]'::jsonb)) END,
    'forms', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'code', c.client_code, 'client', c.name, 'expires_at', i.expires_at)
                                        ORDER BY i.requested_at)
                         FROM public.property_intakes i
                         JOIN public.properties p ON p.id = i.property_id
                         JOIN public.clients c ON c.id = p.client_id
                        WHERE i.submitted_at IS NULL AND i.cancelled_at IS NULL AND (i.expires_at IS NULL OR i.expires_at > now())
                          AND client.fn_intake_assigned_to_me(i.id)), '[]'::jsonb),
    'done_7d', (SELECT count(*) FROM ops.v_calendar_visit v
                 WHERE v.visit_status = 'completed' AND v.visit_date BETWEEN v_day - 6 AND v_day
                   AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp))));

  RETURN v_out;
END;
$function$
;

DO $verify$
DECLARE
  v_day date := ((now() AT TIME ZONE 'America/New_York') - interval '6 hours')::date;
  v_uid uuid; v_email text; v_emp bigint; v_visit bigint; v_vehicle bigint;
  v_mine jsonb; v_want jsonb; v_t0 timestamptz; v_ms numeric; v_want_ms numeric;
BEGIN
  -- Grants did not move: signed-in staff and the server, never anon.
  IF has_function_privilege('anon', 'ops.portal_my_work()', 'execute')
     OR NOT has_function_privilege('authenticated', 'ops.portal_my_work()', 'execute') THEN
    RAISE EXCEPTION 'verify_fail: the grants on ops.portal_my_work() moved';
  END IF;

  -- The one field person with a working sign-in and NO stop of the day, so the probe stop below is their only one and
  -- "my truck" must be its truck.
  SELECT u.id, u.email, e.id INTO v_uid, v_email, v_emp
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field'
     AND u.email_confirmed_at IS NOT NULL AND (u.banned_until IS NULL OR u.banned_until <= now())
     AND NOT EXISTS (SELECT 1 FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
                       AND (v.driver_id = e.id OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = e.id)))
   ORDER BY e.id LIMIT 1;
  -- A SCHEDULED stop of the day whose truck is ASSIGNED and has a live tank (only Moises has tank sensors).
  SELECT v.id, v.vehicle_id INTO v_visit, v_vehicle
    FROM ops.v_calendar_visit v
   WHERE v.visit_date = v_day AND v.visit_status = 'scheduled' AND v.vehicle_source = 'assigned'
     AND EXISTS (SELECT 1 FROM public.vehicle_tanks vt WHERE vt.vehicle_id = v.vehicle_id AND vt.deleted_at IS NULL)
   ORDER BY v.start_at NULLS LAST, v.id LIMIT 1;
  IF v_uid IS NULL OR v_visit IS NULL THEN
    RAISE EXCEPTION 'verify_fail: nothing to test with (field person with a sign-in and no stop: %, scheduled stop on a truck with tanks: %). Apply while Moises has a scheduled stop that day.', v_emp, v_visit;
  END IF;

  -- The whole new body as that person, with the stop put on them inside a block that always raises, which undoes the
  -- stop (and its audit and visit_assignments rows). Only the variables survive the block.
  BEGIN
    INSERT INTO public.visit_team (visit_id, employee_id) VALUES (v_visit, v_emp);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    v_t0 := clock_timestamp();
    v_mine := ops.portal_my_work();
    v_ms := round(extract(epoch FROM clock_timestamp() - v_t0) * 1000, 1);
    RESET ROLE;
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'undo the probe stop';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN
    NULL;
  END;

  -- The answer the old body gave for that truck: its tank read over the view, verbatim (about 20 s, ACCESS SHARE only).
  v_t0 := clock_timestamp();
  v_want := coalesce((SELECT jsonb_agg(jsonb_build_object('contents', t.contents, 'percent', round(t.fill_percent::numeric),
                                                          'gallons', round(t.gallons::numeric), 'at', t.recorded_at) ORDER BY t.contents)
                        FROM (SELECT DISTINCT ON (l.contents) l.contents, l.fill_percent, l.gallons, l.recorded_at
                                FROM public.v_tank_levels l WHERE l.vehicle_id = v_vehicle
                               ORDER BY l.contents, l.recorded_at DESC) t), '[]'::jsonb);
  v_want_ms := round(extract(epoch FROM clock_timestamp() - v_t0) * 1000, 1);

  IF EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v_visit AND t.employee_id = v_emp) THEN
    RAISE EXCEPTION 'verify_fail: the probe stop (visit %, person %) was not undone', v_visit, v_emp;
  END IF;
  IF (v_mine->'truck'->>'name') IS DISTINCT FROM (SELECT vh.name FROM public.vehicles vh WHERE vh.id = v_vehicle) THEN
    RAISE EXCEPTION 'verify_fail: my work did not name the probe stop''s truck (got %)', v_mine->'truck';
  END IF;
  IF v_ms > 2000 THEN
    RAISE EXCEPTION 'verify_fail: my work for a driver with a truck took % ms (limit 2,000; the app stops at 8,000)', v_ms;
  END IF;
  IF jsonb_array_length(v_want) = 0 THEN
    RAISE EXCEPTION 'verify_fail: the view has no tank reading for vehicle %, so nothing was compared', v_vehicle;
  END IF;
  IF v_mine->'truck'->'tanks' IS DISTINCT FROM v_want THEN
    RAISE EXCEPTION 'verify_fail: the tank readings differ from the view''s: % against %', v_mine->'truck'->'tanks', v_want;
  END IF;

  -- Last: the installed body is exactly the reviewed one.
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '0d2f8eff1b8c8a9af76526ac03a154a6' THEN
    RAISE EXCEPTION 'verify_fail: the installed body is not the reviewed one';
  END IF;

  PERFORM set_config('verify.summary', jsonb_build_object('day', v_day, 'field_emp', v_emp, 'probe_visit', v_visit,
    'vehicle', v_vehicle, 'call_ms', v_ms, 'view_read_ms', v_want_ms, 'stops', jsonb_array_length(v_mine->'stops'),
    'truck', v_mine->'truck')::text, true);
END $verify$;

COMMIT;
