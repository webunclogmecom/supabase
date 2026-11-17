-- =============================================================================
-- 2026-11-17_1615_portal_home_crew_assigned_truck_rollback.sql
--
-- Undoes 2026-11-17_1615_portal_home_crew_assigned_truck.sql: puts back the previous bodies of ops.portal_home() and ops.portal_my_work(), verbatim.
-- Guarded: it refuses unless both live bodies are exactly the ones that migration wrote. VERIFY: both bodies are
-- byte for byte the ones before it (md5 a12a47cc1fcf0954c520149b4459a382 and 6f41d9a9f6a9c09a65a9a7c4662ad7f0).
-- After it, the Home names a visit's people on the truck the Calendar guesses again, and a driver's "my truck" can be
-- a guess again (the B3 bug comes back).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_home()'::regprocedure)) <> 'ada1c7badf33392f40fb7efe5d401a4e' THEN RAISE EXCEPTION 'guard: ops.portal_home() is not the 2026-11-17_1615 body'; END IF;
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '1f6f9ed21ecfa5600571e2bd27e644ed' THEN RAISE EXCEPTION 'guard: ops.portal_my_work() is not the 2026-11-17_1615 body'; END IF;
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
    WITH d AS MATERIALIZED (
      SELECT v.vehicle_id, v.truck_name, v.truck_color, v.visit_status, v.late_status, v.start_at, v.driver_name, v.driver_color
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
                                       FROM d c WHERE c.vehicle_id IS NOT DISTINCT FROM d.vehicle_id AND c.driver_name IS NOT NULL), '[]'::jsonb)) AS j
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
    (SELECT m2.vehicle_id FROM mine m2 WHERE m2.vehicle_id IS NOT NULL ORDER BY m2.start_at NULLS LAST, m2.id LIMIT 1)
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
BEGIN
  IF md5(pg_get_functiondef('ops.portal_home()'::regprocedure)) <> 'a12a47cc1fcf0954c520149b4459a382' THEN RAISE EXCEPTION 'verify_fail: ops.portal_home() is not the previous body'; END IF;
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '6f41d9a9f6a9c09a65a9a7c4662ad7f0' THEN RAISE EXCEPTION 'verify_fail: ops.portal_my_work() is not the previous body'; END IF;
END $verify$;

COMMIT;
