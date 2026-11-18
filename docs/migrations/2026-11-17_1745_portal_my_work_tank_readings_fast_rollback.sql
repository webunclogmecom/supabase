-- =============================================================================
-- 2026-11-17_1745_portal_my_work_tank_readings_fast_rollback.sql
--
-- Undoes 2026-11-17_1745_portal_my_work_tank_readings_fast.sql: puts back ops.portal_my_work() exactly as
-- 2026-11-17_1615_portal_home_crew_assigned_truck.sql left it (md5 1f6f9ed21ecfa5600571e2bd27e644ed), with the tank
-- readings read over public.v_tank_levels again, which takes over 20 s for any truck (Trello #226).
-- The body below is the live pg_get_functiondef text saved on 2026-11-17 at 5:40 PM ET, verbatim (not retyped).
-- GUARD: refuses unless the live body is the 1745 one (md5 0d2f8eff1b8c8a9af76526ac03a154a6), so it cannot undo a
--   later change by mistake. VERIFY: the installed md5 is 1f6f9ed..., and the grants did not move.
-- REHEARSED, rolled back on Prod on 2026-11-17: run in one transaction right after the 1745
--   migration: its guard passed, its VERIFY passed, the body ended on md5 1f6f9ed... Run alone against the live (old) body:
--   its guard refused, as it must.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '0d2f8eff1b8c8a9af76526ac03a154a6' THEN
    RAISE EXCEPTION 'guard: ops.portal_my_work() is not the 2026-11-17_1745 body (md5 %)', md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure));
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
BEGIN
  IF has_function_privilege('anon', 'ops.portal_my_work()', 'execute')
     OR NOT has_function_privilege('authenticated', 'ops.portal_my_work()', 'execute') THEN
    RAISE EXCEPTION 'verify_fail: the grants on ops.portal_my_work() moved';
  END IF;
  IF md5(pg_get_functiondef('ops.portal_my_work()'::regprocedure)) <> '1f6f9ed21ecfa5600571e2bd27e644ed' THEN
    RAISE EXCEPTION 'verify_fail: the installed body is not the 2026-11-17_1615 one';
  END IF;
END $verify$;

COMMIT;
