-- =============================================================================
-- 2026-11-17_1615_portal_home_crew_assigned_truck.sql
--
-- WHAT: the Ops Portal's Home stops naming a person on a truck they were not put on (Trello #224, data check B3).
--   1. ops.portal_home(): a truck's crew never names the people of a visit whose truck is only the Calendar's GUESS
--      (ops.v_calendar_visit vehicle_source 'default': visits.vehicle_id is empty and the view fills in the usual
--      truck). That visit still counts on the guessed truck (its visits, done, left and first start are unchanged).
--      The "No truck" row (vehicle_source 'none': no truck and no guess) keeps naming its people: it puts nobody on a
--      truck.
--   2. ops.portal_my_work(): "my truck" (the driver's Home: "N stops on <truck>" and the My truck card with its tank
--      readings and Book a dump) is the truck of the first ASSIGNED stop, never a guessed one. The same flaw and the
--      same one-line rule. So a person whose stops are ALL on guessed trucks has no truck: their Home reads "N stops"
--      with no truck name, and the My truck card, Book a dump included, is not shown (DUMP Schedule stays under Other
--      apps). Whether such a driver should keep Book a dump is a question for Fred, and a portal change, not this one.
--   ops.portal_waiting() is NOT changed: it reads no truck (late_today counts visits by date and late mark only).
--   NOT in this migration, the same flaw in a sibling: ops.portal_search() returns truck_name and driver_name with no
--   vehicle_source, so Search reads "Moises with Grecia" for visit 8597 (4 visits from 2026-10-18 to 11-24: 8597, 9080,
--   9213, 9220). Outside this card's scope; it needs its own card (the function and the portal's search.tsx).
--
-- WHY: Fred, 2026-11-17, round B of Yan's review: "go with all recommended and all defaults", which includes HC1, one new
--   card for the Home with the crew bug. The bug, proven on Prod: visit 8597 (320-MGF) has no truck; ops.v_calendar_visit
--   fills vehicle_id with a guess (Moises, from its line items; vehicle_source 'default'), and the Home listed Grecia on
--   Moises as well as on Cloggy, where her assigned visits are. GPS puts the truck David at the site (a stop 104 m away,
--   11:29 to 11:43 ET); the nearest Moises reading was 2.7 km away. Grecia's own My work read "on Moises" for the same
--   reason (8597 is her first stop by time).
--
-- HOW: both bodies are the LIVE pg_get_functiondef text with anchored edits (each anchor found exactly once, by a
--   script), md5-guarded: portal_home a12a47cc1fcf0954c520149b4459a382 -> ada1c7badf33392f40fb7efe5d401a4e,
--   portal_my_work 6f41d9a9f6a9c09a65a9a7c4662ad7f0 -> 1f6f9ed21ecfa5600571e2bd27e644ed.
--   portal_home: vehicle_source added to the day's one read, and "AND c.vehicle_source <> 'default'" on the crew;
--   my_work: "WHERE m2.vehicle_id IS NOT NULL" became "WHERE m2.vehicle_source = 'assigned'" ('assigned' means
--   visits.vehicle_id is set, so the truck is never null). Plus a dated comment in each. Nothing else in either body
--   moved: diff each body here against the same function in the rollback file, which holds the previous bodies verbatim.
--
-- REACH, 2026-10-18 to 11-24, measured before writing this: the Home changes only where a driver was named on a truck
--   by a guess alone: 2 visits, 8597 today (Grecia off Moises) and 9080 on 11-05 (112-YA, the test client, Fred Driver
--   off Moises). The 3 days with a visit on no truck at all (11-07, 11-10, 11-14, Mark each) keep his name on the
--   "No truck" row. My work changes on 2 person-days: Grecia today (Moises to Cloggy) and Fred Driver on 11-05 (Moises
--   to no truck, so no My truck card that day).
--
-- ACCESS: unchanged. Both stay SECURITY DEFINER with an empty search_path; CREATE OR REPLACE keeps the grants
--   (authenticated and service_role; VERIFY checks anon still cannot run them).
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- REHEARSED, rolled back on Prod on 2026-11-17:
--   Home: this file's VERIFY passes, and today's whole Home answer differs from the old one ONLY in Moises' crew losing
--   Grecia; the old bodies as a control FAIL the same VERIFY. The crew statement was also replayed verbatim, from the
--   old body and from this one, for every day of the window with a visit on a guessed truck or on no truck: the answer
--   changes on 11-05 and 11-17 only, the two visits above.
--   My work: the VERIFY calls the whole new body as a field person with no assigned stop. It tests the rule only when
--   that person has a guessed stop (summary my_work_rule_tested). On 2026-11-17 nobody had one (the only field person
--   with a sign-in had no stop), so there it proves only that the body runs. The rule itself is proven by replaying My
--   work's changed first statement verbatim from both bodies for everyone with stops today: with this body only
--   Grecia's truck moves (Moises to Cloggy) and every stop list is identical; with the old body she stays on Moises.
--   A whole call for a person with a truck cannot be rehearsed: its tank readings read takes over 20 s for any truck
--   (a separate defect for its own card).
-- ON APPLY, in the same cycle: claim ops.portal_home and ops.portal_my_work in WORKING-NOW.md first. Afterwards update
--   Supabase CLAUDE.md "THE MY WORK DOOR" (its portal_home and portal_my_work bullets), the portal manual
--   docs/02-architecture.md (the Home row: today's trucks and crews, and the Field "my truck") and docs/04-backend.md,
--   Building Apps/Ops Portal/docs/08-changelog.md and memory, and run the standing check
--   scripts/checks/portal_home_crew_assigned.sql (it fails before this is applied whenever a guess names a driver).
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-17_1615_portal_home_crew_assigned_truck_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_home()'::regprocedure)) <> 'a12a47cc1fcf0954c520149b4459a382' THEN
    RAISE EXCEPTION 'guard: ops.portal_home() changed since this was written (md5 %)', md5(pg_get_functiondef('ops.portal_home()'::regprocedure));
  END IF;
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '6f41d9a9f6a9c09a65a9a7c4662ad7f0' THEN
    RAISE EXCEPTION 'guard: ops.portal_my_work() changed since this was written (md5 %)', md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.v_calendar_visit'::regclass AND attname = 'vehicle_source' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'guard: ops.v_calendar_visit has no vehicle_source';
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION ops.portal_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-16 (Trello #210, Fred's picks HO1 and HA1): what the Ops Portal's Home shows beside "Needs you", which is
-- ops.portal_waiting(), the bell's own answer. Counts and totals only, by the bell's access rule (v_closed):
--   today, trucks, week: for a person who can open the Visit Calendar. No money (Fred: "it doesn't needs to see the
--                        like revenue and stuff like that, for the Day value").
--   business:            the Admin group only, each part by the app that holds it (invoices and past due: Client App;
--                        pumped gallons: Admin Review). Invoices count by the date Jobber SENT them (our copy's
--                        created_at is the day the copy was made), voided and destroyed ones left out.
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_now timestamp := now() AT TIME ZONE 'America/New_York';
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_month date := date_trunc('month', now() AT TIME ZONE 'America/New_York')::date;
  v_prev date := (date_trunc('month', now() AT TIME ZONE 'America/New_York') - interval '1 month')::date;
  v_prev_end date := ((now() AT TIME ZONE 'America/New_York') - interval '1 month')::date;  -- the same day of last month
  v_out jsonb;
  v_biz jsonb := '{}'::jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;
  v_out := jsonb_build_object('date', v_today, 'month_start', v_month, 'prev_start', v_prev, 'prev_end', v_prev_end);

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    -- Today and its trucks, from one read of the day. "late" is the same predicate as portal_waiting's late_today.
    -- 2026-11-17 (Trello #224): a truck's crew never names the people of a visit whose truck is only the Calendar's GUESS
    -- (vehicle_source 'default': the visit has no truck and the view fills in the usual one). Such a visit still counts in
    -- that truck's visits, but its people are not named on a truck nobody put them on (visit 8597: Grecia on Moises).
    -- The "No truck" row (vehicle_source 'none') names its people as before.
    WITH d AS MATERIALIZED (
      SELECT v.vehicle_id, v.truck_name, v.truck_color, v.visit_status, v.late_status, v.start_at, v.driver_name, v.driver_color, v.vehicle_source
        FROM ops.v_calendar_visit v
       WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled'
    )
    SELECT v_out || jsonb_build_object(
      'today', (SELECT jsonb_build_object(
          'visits', count(*),
          'done', count(*) FILTER (WHERE d.visit_status = 'completed'),
          'skipped', count(*) FILTER (WHERE d.visit_status = 'skipped'),
          'left', count(*) FILTER (WHERE d.visit_status = 'scheduled'),
          'late', count(*) FILTER (WHERE d.late_status = 'late'))
          FROM d),
      'trucks', coalesce((SELECT jsonb_agg(t.j ORDER BY t.name) FROM (
          SELECT coalesce(d.truck_name, 'No truck') AS name,
                 jsonb_build_object(
                   'name', coalesce(d.truck_name, 'No truck'),
                   'color', d.truck_color,
                   'visits', count(*),
                   'done', count(*) FILTER (WHERE d.visit_status = 'completed'),
                   'left', count(*) FILTER (WHERE d.visit_status = 'scheduled'),
                   'first_at', min(d.start_at) FILTER (WHERE d.visit_status = 'scheduled'),
                   'crew', coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('name', c.driver_name, 'color', c.driver_color))
                                       FROM d c WHERE c.vehicle_id IS NOT DISTINCT FROM d.vehicle_id AND c.driver_name IS NOT NULL AND c.vehicle_source <> 'default'), '[]'::jsonb)) AS j
            FROM d GROUP BY d.vehicle_id, d.truck_name, d.truck_color) t), '[]'::jsonb))
      INTO v_out;

    v_out := v_out || jsonb_build_object('week', (
      SELECT jsonb_agg(jsonb_build_object('date', s.day, 'visits', coalesce(c.n, 0)) ORDER BY s.day)
        FROM (SELECT v_today + i AS day FROM generate_series(0, 6) i) s
        LEFT JOIN (SELECT v.visit_date, count(*) AS n FROM ops.v_calendar_visit v
                    WHERE v.visit_date BETWEEN v_today AND v_today + 6 AND v.visit_status <> 'cancelled'
                    GROUP BY 1) c ON c.visit_date = s.day));
  END IF;

  IF v_access->>'group' = 'admin' THEN
    IF NOT 'client_app' = ANY (v_closed) THEN
      v_biz := v_biz || jsonb_build_object(
        'invoices', (SELECT jsonb_build_object(
            'count', count(*) FILTER (WHERE x.day >= v_month),
            'total', coalesce(sum(x.total) FILTER (WHERE x.day >= v_month), 0),
            'prev_count', count(*) FILTER (WHERE x.day BETWEEN v_prev AND v_prev_end),
            'prev_total', coalesce(sum(x.total) FILTER (WHERE x.day BETWEEN v_prev AND v_prev_end), 0))
            FROM (SELECT i.total, (i.sent_at AT TIME ZONE 'America/New_York')::date AS day
                    FROM client.invoices i
                   WHERE i.sent_at >= (v_prev::timestamp AT TIME ZONE 'America/New_York')
                     AND coalesce(i.invoice_status, '') NOT IN ('voided', 'destroyed')) x),
        'past_due', (SELECT jsonb_build_object(
            'amount', coalesce(sum(p.past_due_amount), 0),
            'clients', count(*),
            'top', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.client_id, 'code', t.client_code, 'amount', t.past_due_amount)
                                              ORDER BY t.past_due_amount DESC)
                               FROM (SELECT q.client_id, q.client_code, q.past_due_amount FROM ops.v_client_past_due q
                                      WHERE q.past_due_amount > 0 ORDER BY q.past_due_amount DESC LIMIT 3) t), '[]'::jsonb))
            FROM ops.v_client_past_due p WHERE p.past_due_amount > 0));
    END IF;
    IF NOT 'admin_review' = ANY (v_closed) THEN
      -- Gallons measured by the tank sensors, and which trucks were measured at all this month (only Moises has sensors
      -- today, so the card must say which trucks its number covers).
      WITH g AS MATERIALIZED (
        SELECT t.vehicle_id, t.visit_date, t.sludge_collected_gallons
          FROM public.v_visit_tank_service t
         WHERE t.visit_date >= v_prev AND t.visit_date <= v_today
      )
      SELECT v_biz || jsonb_build_object('pumped', jsonb_build_object(
          'gallons', round(coalesce((SELECT sum(g.sludge_collected_gallons) FROM g WHERE g.visit_date >= v_month), 0)),
          'prev_gallons', round(coalesce((SELECT sum(g.sludge_collected_gallons) FROM g WHERE g.visit_date BETWEEN v_prev AND v_prev_end), 0)),
          'trucks', coalesce((SELECT jsonb_agg(jsonb_build_object('name', coalesce(vh.name, 'No truck'), 'visits', x.visits, 'measured', x.measured)
                                               ORDER BY x.measured DESC, vh.name)
                                FROM (SELECT g.vehicle_id, count(*) AS visits, count(g.sludge_collected_gallons) AS measured
                                        FROM g WHERE g.visit_date >= v_month GROUP BY 1) x
                                LEFT JOIN public.vehicles vh ON vh.id = x.vehicle_id), '[]'::jsonb)))
        INTO v_biz;
    END IF;
    v_out := v_out || jsonb_build_object('business', v_biz);
  END IF;

  RETURN v_out;
END;
$function$
;

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
                           FROM (SELECT DISTINCT ON (l.contents) l.contents, l.fill_percent, l.gallons, l.recorded_at
                                   FROM public.v_tank_levels l WHERE l.vehicle_id = v_vehicle
                                  ORDER BY l.contents, l.recorded_at DESC) t), '[]'::jsonb)) END,
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
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_day date := ((now() AT TIME ZONE 'America/New_York') - interval '6 hours')::date;
  v_uid uuid; v_email text; v_emp bigint; v_home jsonb; v_mine jsonb; v_bad jsonb; v_n numeric; v_guessed bigint;
BEGIN
  -- Grants did not move: signed-in staff and the server, never anon.
  IF has_function_privilege('anon', 'ops.portal_home()', 'execute') OR has_function_privilege('anon', 'ops.portal_my_work()', 'execute')
     OR NOT has_function_privilege('authenticated', 'ops.portal_home()', 'execute') OR NOT has_function_privilege('authenticated', 'ops.portal_my_work()', 'execute') THEN
    RAISE EXCEPTION 'verify_fail: the grants on the two reads moved';
  END IF;

  -- The rule leans on what vehicle_source means: 'assigned' = the visit's own truck, 'default' = no truck and the
  -- Calendar's guess, 'none' = no truck and no guess.
  IF EXISTS (SELECT 1 FROM ops.v_calendar_visit v WHERE v.visit_date = v_today
                AND v.vehicle_source IS DISTINCT FROM CASE WHEN v.assigned_vehicle_id IS NOT NULL THEN 'assigned'
                                                           WHEN v.vehicle_id IS NOT NULL THEN 'default' ELSE 'none' END) THEN
    RAISE EXCEPTION 'verify_fail: ops.v_calendar_visit vehicle_source no longer means assigned / default (a guess) / none';
  END IF;

  -- The Home, read as the first active admin with a confirmed sign-in.
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no admin with a sign-in to read the Home as'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_home := ops.portal_home();
  RESET ROLE;

  -- Every visit of today still counts on a truck (a guessed truck keeps its visits).
  SELECT count(*) INTO v_n FROM ops.v_calendar_visit v WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled';
  IF (SELECT coalesce(sum((t->>'visits')::int), 0) FROM jsonb_array_elements(v_home->'trucks') t) IS DISTINCT FROM v_n THEN
    RAISE EXCEPTION 'verify_fail: the trucks do not add up to today''s % visits', v_n;
  END IF;
  -- Each truck's crew is exactly the people of its visits today that are NOT on a guessed truck (the "No truck" row
  -- keeps the people of visits with no truck at all).
  WITH want AS (
    SELECT coalesce(v.truck_name, 'No truck') AS truck,
           coalesce(jsonb_agg(DISTINCT v.driver_name) FILTER (WHERE v.vehicle_source <> 'default' AND v.driver_name IS NOT NULL), '[]'::jsonb) AS crew
      FROM ops.v_calendar_visit v WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled' GROUP BY 1),
  got AS (
    SELECT t->>'name' AS truck, coalesce((SELECT jsonb_agg(DISTINCT c->>'name') FROM jsonb_array_elements(t->'crew') c), '[]'::jsonb) AS crew
      FROM jsonb_array_elements(v_home->'trucks') t)
  SELECT jsonb_agg(jsonb_build_object('truck', coalesce(w.truck, g.truck), 'want', w.crew, 'got', g.crew)) INTO v_bad
    FROM want w FULL JOIN got g ON g.truck = w.truck
   WHERE w.crew IS DISTINCT FROM g.crew;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'verify_fail: a truck''s crew is not the people of its visits that are not a guess: %', v_bad; END IF;

  -- My work, read as a field person with a working sign-in and NO assigned stop today, the one with the most GUESSED
  -- stops first (then the most stops). When that person has a guessed stop this tests the rule: the old body names the
  -- guessed truck and fails here. When nobody has one (2026-11-17: the only field person with a sign-in had no stop at
  -- all) it proves only that the whole new body runs, and the summary says my_work_rule_tested false. (Nobody with an
  -- assigned stop is used: My work's tank readings read takes over 20 s for any truck today, a separate defect.)
  SELECT u.id, u.email, e.id INTO v_uid, v_email, v_emp
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field'
     AND u.email_confirmed_at IS NOT NULL AND (u.banned_until IS NULL OR u.banned_until <= now())
     AND (SELECT count(*) FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled' AND v.vehicle_source = 'assigned'
               AND (v.driver_id = e.id OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = e.id))) = 0
   ORDER BY (SELECT count(*) FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled' AND v.vehicle_source = 'default'
               AND (v.driver_id = e.id OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = e.id))) DESC,
            (SELECT count(*) FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
               AND (v.driver_id = e.id OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = e.id))) DESC, e.id
   LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no field person with a sign-in to read My work as'; END IF;
  v_guessed := (SELECT count(*) FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled' AND v.vehicle_source = 'default'
               AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp)));
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_mine := ops.portal_my_work();
  RESET ROLE;
  IF NOT (v_mine ? 'stops') OR coalesce(jsonb_typeof(v_mine->'truck'), 'null') <> 'null' THEN
    RAISE EXCEPTION 'verify_fail: my work names truck % for a person with no assigned stop (% guessed stops)', v_mine->'truck'->>'name', v_guessed;
  END IF;

  -- Last: the installed bodies are exactly the reviewed ones.
  IF md5(pg_get_functiondef('ops.portal_home()'::regprocedure)) <> 'ada1c7badf33392f40fb7efe5d401a4e'
     OR md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '1f6f9ed21ecfa5600571e2bd27e644ed' THEN
    RAISE EXCEPTION 'verify_fail: the installed bodies are not the reviewed ones';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('verify.summary', jsonb_build_object('today_visits', v_n, 'trucks', v_home->'trucks',
    'field_emp', v_emp, 'field_stops', jsonb_array_length(v_mine->'stops'), 'field_guessed_stops', v_guessed,
    'my_work_rule_tested', v_guessed > 0, 'field_truck', v_mine->'truck')::text, true);
END $verify$;

COMMIT;
