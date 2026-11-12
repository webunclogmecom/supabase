-- ============================================================================
-- 2026-11-12_rollback_time_on_site_recheck_read_taps  Undo 2026-11-12_1330_time_on_site_recheck_read_taps.sql
-- ============================================================================
-- Puts back the body of public.fn_time_on_site_recheck_visits without the 'taps' key (md5 76824f8e41f71cade4bb625625622762), verbatim.
-- ORDER: roll the edge function back FIRST (its reader falls back to 'visits' when 'taps' is missing, so either order is
--   safe, but the edge change is pointless without this key).
-- PIN: the body is the 2026-11-12_1330_time_on_site_recheck_read_taps one (md5 874251cc8ba0783597b675aa2fa9cb2c). VERIFY: md5 back to 76824f8e41f71cade4bb625625622762; grants equal; no 'taps' key.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_recheck_visits(date,date)'::regprocedure)) <> '874251cc8ba0783597b675aa2fa9cb2c' THEN
    RAISE EXCEPTION 'read taps rollback: the body is not the 2026-11-12_1330_time_on_site_recheck_read_taps one'; END IF;
END $pin$;

CREATE OR REPLACE FUNCTION public.fn_time_on_site_recheck_visits(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
WITH v AS (
  SELECT vi.id, vi.visit_date, vi.client_id, vi.property_id, vi.vehicle_id, vi.completed_at,
         vi.duration_minutes, vi.actual_arrival_at, vi.actual_departure_at, vi.time_on_site_source,
         (vi.visit_date BETWEEN p_from AND p_to) AS in_range
    FROM public.visits vi LEFT JOIN public.clients cl ON cl.id = vi.client_id
   WHERE vi.visit_status = 'completed' AND vi.deleted_at IS NULL
     AND vi.visit_date BETWEEN p_from - 1 AND p_to + 1
     AND coalesce(cl.client_code, '') NOT LIKE '000-%'
     AND NOT coalesce(public.fn_is_non_customer(vi.client_id), false)
), c AS (SELECT DISTINCT client_id FROM v WHERE client_id IS NOT NULL)
SELECT jsonb_build_object(
  'read_at_ms', round(extract(epoch FROM now()) * 1000)::bigint,
  'from', p_from, 'to', p_to,
  -- 'infinity' while the GPS feed is live (fn_samsara_data_complete_through): then gps_live and no watermark
  'gps_live', (SELECT g.t = 'infinity'::timestamptz FROM (SELECT public.fn_samsara_data_complete_through('gps') t) g),
  'gps_complete_through_ms', (SELECT CASE WHEN isfinite(g.t) THEN round(extract(epoch FROM g.t) * 1000)::bigint END
                                FROM (SELECT public.fn_samsara_data_complete_through('gps') t) g),
  'visits', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'id', v.id, 'visit_date', v.visit_date, 'client_id', v.client_id, 'property_id', v.property_id, 'vehicle_id', v.vehicle_id,
      'truck_samsara_id', (SELECT e.source_id FROM public.entity_source_links e WHERE e.entity_type = 'vehicle' AND e.entity_id = v.vehicle_id AND e.source_system = 'samsara' LIMIT 1),
      'completed_ms', round(extract(epoch FROM v.completed_at) * 1000)::bigint,
      'window', jsonb_build_array(
         round(extract(epoch FROM ((v.visit_date::timestamp - interval '4 hours') AT TIME ZONE 'America/New_York')) * 1000)::bigint,
         round(extract(epoch FROM (((v.visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York')) * 1000)::bigint),
      'saved', jsonb_build_object('minutes', v.duration_minutes,
         'arrival_ms', round(extract(epoch FROM v.actual_arrival_at) * 1000)::bigint,
         'departure_ms', round(extract(epoch FROM v.actual_departure_at) * 1000)::bigint, 'source', v.time_on_site_source),
      'locked', public.fn_time_on_site_is_locked(v.id),
      'in_range', v.in_range,
      -- close-out test 4 (plan 5.5 b): our stops within 500 m of the site point in the window, for a blank visit only
      -- (the point is the override spot when there is one, else the map point)
      'stops_500m', CASE WHEN v.in_range AND v.duration_minutes IS NULL THEN coalesce((
         SELECT jsonb_agg(jsonb_build_object('vehicle_id', s.vehicle_id, 'arr_ms', round(extract(epoch FROM s.arrived_at) * 1000)::bigint,
                  'dep_ms', round(extract(epoch FROM s.departed_at) * 1000)::bigint, 'm', round(pt.m)) ORDER BY s.arrived_at)
           FROM (SELECT coalesce(sp.latitude::float8, p.latitude::float8) la, coalesce(sp.longitude::float8, p.longitude::float8) lo
                   FROM public.properties p
                   LEFT JOIN public.time_on_site_site_overrides o ON o.property_id = p.id
                   LEFT JOIN public.vehicle_telemetry_readings sp ON sp.id = o.spot_fix_id
                  WHERE p.id = v.property_id) c0
           JOIN public.vehicle_stops s ON s.superseded_at IS NULL
                AND s.arrived_at < (((v.visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York')
                AND s.departed_at > ((v.visit_date::timestamp - interval '4 hours') AT TIME ZONE 'America/New_York')
           CROSS JOIN LATERAL (SELECT 6371008.8 * 2 * asin(sqrt(power(sin(radians(s.latitude::float8 - c0.la) / 2), 2)
                  + cos(radians(c0.la)) * cos(radians(s.latitude::float8)) * power(sin(radians(s.longitude::float8 - c0.lo) / 2), 2))) AS m) pt
          WHERE c0.la IS NOT NULL AND pt.m <= 500), '[]'::jsonb) END) ORDER BY v.id) FROM v), '[]'::jsonb),
  'properties', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'client_id', p.client_id, 'lat', p.latitude::float8,
      'lng', p.longitude::float8, 'is_billing', coalesce(p.is_billing, false)) ORDER BY p.id)
     FROM public.properties p WHERE p.deleted_at IS NULL AND p.client_id IN (SELECT client_id FROM c)), '[]'::jsonb),
  'place_links', coalesce((SELECT jsonb_agg(jsonb_build_object('entity_type', l.entity_type, 'entity_id', l.entity_id, 'place_id', l.source_id) ORDER BY l.entity_type, l.entity_id, l.source_id)
     FROM public.entity_source_links l
    WHERE l.source_system = 'samsara' AND ((l.entity_type = 'client' AND l.entity_id IN (SELECT client_id FROM c))
       OR (l.entity_type = 'property' AND l.entity_id IN (SELECT p.id FROM public.properties p WHERE p.client_id IN (SELECT client_id FROM c))))), '[]'::jsonb),
  'overrides', coalesce((SELECT jsonb_agg(jsonb_build_object('property_id', o.property_id,
      'spot', CASE WHEN o.spot_fix_id IS NULL THEN NULL ELSE (SELECT jsonb_build_object('lat', r.latitude::float8, 'lng', r.longitude::float8) FROM public.vehicle_telemetry_readings r WHERE r.id = o.spot_fix_id) END,
      'place_id', o.place_id, 'place_unlink', o.place_unlink, 'extra_place_id', o.extra_place_id, 'decision_ref', o.decision_ref) ORDER BY o.property_id)
     FROM public.time_on_site_site_overrides o), '[]'::jsonb),
  'trucks', coalesce((SELECT jsonb_agg(jsonb_build_object('vehicle_id', e.entity_id, 'samsara_id', e.source_id) ORDER BY e.entity_id)
     FROM public.entity_source_links e JOIN public.vehicles vh ON vh.id = e.entity_id
    WHERE e.entity_type = 'vehicle' AND e.source_system = 'samsara' AND vh.status = 'ACTIVE'), '[]'::jsonb),
  'place_verdicts', coalesce((SELECT jsonb_agg(jsonb_build_object('place_id', r.samsara_address_id, 'verdict', r.verdict, 'distance_m', r.distance_m) ORDER BY r.samsara_address_id)
     FROM public.v_samsara_place_review r), '[]'::jsonb),
  'timers', coalesce((SELECT jsonb_agg(jsonb_build_object('visit_id', t.visit_id, 'started_ms', round(extract(epoch FROM t.started_at) * 1000)::bigint) ORDER BY t.visit_id, t.started_at)
     FROM hr.time_entries t WHERE t.removed_at IS NULL AND t.timer_target = 'visit' AND t.visit_id IN (SELECT id FROM v WHERE in_range)), '[]'::jsonb))
$function$;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_recheck_visits(date,date)'::regprocedure)) <> '76824f8e41f71cade4bb625625622762' THEN
    RAISE EXCEPTION 'VERIFY read taps rollback: the body md5 is not 76824f8e41f71cade4bb625625622762'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_recheck_visits(date,date)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY read taps rollback: the grants moved'; END IF;
  IF public.fn_time_on_site_recheck_visits('2026-10-19', '2026-10-19') ? 'taps' THEN RAISE EXCEPTION 'VERIFY read taps rollback: taps still there'; END IF;
END $v$;

COMMIT;
