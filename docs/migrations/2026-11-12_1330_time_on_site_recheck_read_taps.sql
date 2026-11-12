-- ============================================================================
-- 2026-11-12_1330_time_on_site_recheck_read_taps  The nightly's read gets every completed visit's tap by completion time
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-12: "do the nightly fix". Found by S6's comparison: 8853 and 8886 got applied
--   keep_verified / nightly_self close-out rows although another visit of the same truck was completed inside their stay
--   (8854, dated 10-16, completed 10-19; 8882, dated 10-23, completed 10-26). Corrected by
--   2026-11-12_1140_time_on_site_s6_shared_tap_rows.sql; this file and the edge change close the cause.
-- WHY
--   The close-out classifier (plan 5.5 b) holds a kept visit for a person (shared_tap) when another completed visit of the
--   same truck has its completion inside the stay. time-on-site-samsara-recheck took those taps only from this read's
--   'visits', which holds visits DATED p_from - 1 to p_to + 1 (and no test or yard client). A visit completed two or
--   more days after its own date was never seen.
-- WHAT CHANGES
--   One new key, 'taps': every completed, not deleted visit with a truck, ANY client, whose completed_at falls between the
--   first read window's start ((p_from - 1) 00:00 ET - 4 h) and the last one's end ((p_to + 2) 10:00 ET), as
--   {id, vehicle_id, completed_ms}. Every other key is byte for byte what it was (VERIFY compares the old body, kept as a
--   pg_temp copy, on 4 ranges). The body is the live one (md5 76824f8e41f71cade4bb625625622762) with one block inserted before 'trucks'.
--   The edge function reads 'taps' from the same day's deploy; until then nothing reads it.
-- WHAT DOES NOT CHANGE: no table, no row, no grant (CREATE OR REPLACE keeps them; VERIFY reads proacl), the language,
--   volatility, SECURITY DEFINER and search_path ''.
-- PIN: the live body md5 76824f8e41f71cade4bb625625622762; proacl {postgres=X/postgres,service_role=X/postgres}.
-- VERIFY: new md5 874251cc8ba0783597b675aa2fa9cb2c; proacl equal; positive controls: taps holds 8854 (truck 2) for 10-19 and 8882 for 10-26;
--   every other key equal to the old body's on each range (read_at_ms aside).
-- ROLLBACK: docs/migrations/2026-11-12_rollback_time_on_site_recheck_read_taps.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_recheck_visits(date,date)'::regprocedure)) <> '76824f8e41f71cade4bb625625622762' THEN
    RAISE EXCEPTION 'read taps: fn_time_on_site_recheck_visits moved (expected md5 76824f8e41f71cade4bb625625622762)'; END IF;
END $pin$;

-- the old body, kept for this transaction as the control
CREATE FUNCTION pg_temp.fn_old_recheck_visits(p_from date, p_to date)
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
  -- 2026-11-12 (Trello vpF5PLQj): every completed visit whose COMPLETION falls inside the read's visit windows, whatever
  -- its own date, for the close-out's "another visit's tap inside the stay" test. 'visits' holds only visits dated
  -- p_from - 1 to p_to + 1, so a visit completed days after its own date was invisible to it (8854, 8882 in S6).
  'taps', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'vehicle_id', t.vehicle_id,
      'completed_ms', round(extract(epoch FROM t.completed_at) * 1000)::bigint) ORDER BY t.id)
     FROM public.visits t
    WHERE t.visit_status = 'completed' AND t.deleted_at IS NULL AND t.vehicle_id IS NOT NULL AND t.completed_at IS NOT NULL
      AND t.completed_at >= (((p_from - 1)::timestamp - interval '4 hours') AT TIME ZONE 'America/New_York')
      AND t.completed_at <= (((p_to + 2)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York')), '[]'::jsonb),
  'trucks', coalesce((SELECT jsonb_agg(jsonb_build_object('vehicle_id', e.entity_id, 'samsara_id', e.source_id) ORDER BY e.entity_id)
     FROM public.entity_source_links e JOIN public.vehicles vh ON vh.id = e.entity_id
    WHERE e.entity_type = 'vehicle' AND e.source_system = 'samsara' AND vh.status = 'ACTIVE'), '[]'::jsonb),
  'place_verdicts', coalesce((SELECT jsonb_agg(jsonb_build_object('place_id', r.samsara_address_id, 'verdict', r.verdict, 'distance_m', r.distance_m) ORDER BY r.samsara_address_id)
     FROM public.v_samsara_place_review r), '[]'::jsonb),
  'timers', coalesce((SELECT jsonb_agg(jsonb_build_object('visit_id', t.visit_id, 'started_ms', round(extract(epoch FROM t.started_at) * 1000)::bigint) ORDER BY t.visit_id, t.started_at)
     FROM hr.time_entries t WHERE t.removed_at IS NULL AND t.timer_target = 'visit' AND t.visit_id IN (SELECT id FROM v WHERE in_range)), '[]'::jsonb))
$function$;

DO $v$
DECLARE r record; n int; o jsonb; w jsonb;
BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_recheck_visits(date,date)'::regprocedure)) <> '874251cc8ba0783597b675aa2fa9cb2c' THEN
    RAISE EXCEPTION 'VERIFY read taps: the new body md5 is not 874251cc8ba0783597b675aa2fa9cb2c'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_recheck_visits(date,date)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY read taps: the grants moved'; END IF;
  -- positive controls: the two late taps S6 missed
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_time_on_site_recheck_visits('2026-10-19', '2026-10-19')->'taps') e
                  WHERE (e->>'id')::bigint = 8854 AND (e->>'vehicle_id')::bigint = 2) THEN
    RAISE EXCEPTION 'VERIFY read taps: 8854 is not among the taps of 10-19'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.fn_time_on_site_recheck_visits('2026-10-26', '2026-10-26')->'taps') e
                  WHERE (e->>'id')::bigint = 8882) THEN
    RAISE EXCEPTION 'VERIFY read taps: 8882 is not among the taps of 10-26'; END IF;
  -- and the old body never had them (the control must fail the same test)
  IF pg_temp.fn_old_recheck_visits('2026-10-19', '2026-10-19') ? 'taps' THEN RAISE EXCEPTION 'VERIFY read taps: the control already has taps'; END IF;
  -- every other key unchanged
  FOR r IN SELECT * FROM (VALUES (date '2026-10-19', date '2026-10-19'), (date '2026-10-26', date '2026-10-26'), (date '2026-11-02', date '2026-11-11'), (date '2026-10-18', date '2026-10-30')) t(f, tt) LOOP
    o := pg_temp.fn_old_recheck_visits(r.f, r.tt) - 'read_at_ms';
    w := public.fn_time_on_site_recheck_visits(r.f, r.tt) - 'read_at_ms' - 'taps';
    IF o IS DISTINCT FROM w THEN RAISE EXCEPTION 'VERIFY read taps: % to % differs from the old body outside taps', r.f, r.tt; END IF;
  END LOOP;
  SELECT jsonb_array_length(public.fn_time_on_site_recheck_visits('2026-11-02', '2026-11-11')->'taps') INTO n;
  RAISE NOTICE 'read taps: new body in place; 11-02 to 11-11 reads % taps; 8854 and 8882 found; other keys equal on 4 ranges', n;
END $v$;

DROP FUNCTION pg_temp.fn_old_recheck_visits(date, date);

COMMIT;
