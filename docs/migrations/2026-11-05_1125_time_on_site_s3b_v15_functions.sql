-- ============================================================================
-- 2026-11-05_1125_time_on_site_s3b_v15_functions  Visit duration re-check, stage S3b part 2: the v15 nightly's functions
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-03: "Build today, deploy Thu", then "document this, so we know what we need to do on
--   thursday". Runbook: docs/specs/2026-11-02-time-on-site-nightly-rule.md section 10, step 8.
-- WHAT CHANGES
--   Four new functions. Nothing calls them until time-on-site-samsara-recheck runs with rules 2, and cron 151 keeps its
--   body '{}' (rules 1) until Fred says go on Wed 11-11.
--     fn_time_on_site_recheck_visits(date, date)   the read: everything the rule needs for a range of visit dates
--     fn_time_on_site_recheck_fixes(jsonb)         stored GPS fixes on request
--     fn_save_time_on_site_stay(...)               the save, which re-checks on the server: unchanged since read, not
--                                                  locked, arrival in the window, span 0 to 12 h, our own GPS fixes at both
--                                                  ends inside the site. Answers {ok, reason}
--     fn_close_time_on_site(jsonb, date)           the close-out at day 10: one ledger row per visit, idempotent
--   All G-15 (Supabase CLAUDE.md, plan section G): SECURITY DEFINER, empty search_path, EXECUTE service_role only.
-- WHAT DOES NOT CHANGE
--   No visit and no ledger row is written. The v14 path and every existing writer are untouched.
-- VERIFY: SECURITY DEFINER with an empty search_path; EXECUTE false for anon and authenticated and true for service_role,
--   with no PUBLIC entry in the ACL; the read answers for today's window; 0 ledger rows of stage 'nightly'.
-- REHEARSED: (a) as written, rolled back; (c) a PIN altered raises; the rollback on top drops the four; the rollback alone
--   refuses. The live positive cases (step 9) ran rolled back on a real unlocked visit.
-- LOCKS: lock_timeout 3s. New objects only. Apply 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20, :30 to :45.
-- ROLLBACK: docs/migrations/2026-11-05_rollback_time_on_site_s3b_v15_functions.sql
--   Redeploy v14 first (runbook 10.4): v15 calls these functions only under rules 2, but keep the order.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['public.fn_time_on_site_recheck_visits(date,date)', 'public.fn_time_on_site_recheck_fixes(jsonb)', 'public.fn_save_time_on_site_stay(bigint,timestamptz,timestamptz,integer,text,text,jsonb)', 'public.fn_close_time_on_site(jsonb,date)'] LOOP
    IF to_regprocedure(s) IS NOT NULL THEN RAISE EXCEPTION 'S3b part 2: % already exists', s; END IF;
  END LOOP;
  IF to_regprocedure('public.fn_time_on_site_is_locked(bigint)') IS NULL THEN RAISE EXCEPTION 'S3b part 2: S3a is not applied (no lock function)'; END IF;
  IF to_regclass('public.time_on_site_site_overrides') IS NULL THEN RAISE EXCEPTION 'S3b part 2: part 1 is not applied (no overrides table)'; END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.visit_time_on_site_corrections'::regclass
       AND conname = 'visit_time_on_site_corrections_stage_check') !~ 'nightly.*person' THEN
    RAISE EXCEPTION 'S3b part 2: the ledger stage CHECK does not allow nightly and person'; END IF;
END $pin$;

-- 1. The read: everything the rule needs for visits dated p_from to p_to (and one day either side, for the guards).
--    Raw ingredients only: the edge function builds each site (it has the live Samsara Places, which the "far from this
--    property" test needs). Times are ms epochs.
CREATE OR REPLACE FUNCTION public.fn_time_on_site_recheck_visits(p_from date, p_to date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
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
$f$;

-- 2. Stored GPS fixes on request (the rule asks for the fixes inside a trip gap with one end away from the site, and
--    the save's location check). p_requests = [{"vehicle_id": n, "from_ms": n, "to_ms": n}], at most 300, each 7 days or less. Bounds are strict (recorded_at > from and < to), as D read them.
CREATE OR REPLACE FUNCTION public.fn_time_on_site_recheck_fixes(p_requests jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $f$
DECLARE out jsonb := '[]'::jsonb; r jsonb;
BEGIN
  IF jsonb_typeof(p_requests) <> 'array' OR jsonb_array_length(p_requests) > 300 THEN
    RAISE EXCEPTION 'fixes: expected an array of at most 300 requests' USING errcode = '22023'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_requests) LOOP
    IF (r->>'to_ms')::bigint - (r->>'from_ms')::bigint > 7 * 86400 * 1000 OR (r->>'to_ms')::bigint < (r->>'from_ms')::bigint THEN
      RAISE EXCEPTION 'fixes: a request spans more than 7 days or ends before it starts' USING errcode = '22023'; END IF;
    out := out || jsonb_build_array(coalesce((SELECT jsonb_agg(jsonb_build_array(round(extract(epoch FROM f.recorded_at) * 1000)::bigint, f.latitude::float8, f.longitude::float8) ORDER BY f.recorded_at)
      FROM public.vehicle_telemetry_readings f
     WHERE f.vehicle_id = (r->>'vehicle_id')::bigint AND f.latitude IS NOT NULL
       AND f.recorded_at > to_timestamp((r->>'from_ms')::bigint / 1000.0) AND f.recorded_at < to_timestamp((r->>'to_ms')::bigint / 1000.0)), '[]'::jsonb));
  END LOOP;
  RETURN out;
END $f$;

-- 3. The save (plan 5.2): re-checks on the server; never trusts the edge's reading. Returns {ok, reason}.
--    p_site = {"lat": n, "lng": n, "r_m": n, "kind": "point" | "place"}: within r_m of the centre (point: 250; place: the
--    Place's enclosing circle plus 40 m, capped at 600 here).
CREATE OR REPLACE FUNCTION public.fn_save_time_on_site_stay(p_visit_id bigint, p_arrival timestamptz, p_departure timestamptz,
  p_expected_minutes integer, p_expected_source text, p_basis text, p_site jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
DECLARE v record; v_hdr text; n int; f0 record; f1 record; v_lat float8; v_lng float8; v_r float8; w0 timestamptz; w1 timestamptz;
BEGIN
  IF p_arrival IS NULL OR p_departure IS NULL OR p_departure <= p_arrival OR p_departure - p_arrival > interval '12 hours' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_span'); END IF;
  IF p_basis IS NULL OR p_basis !~ '^[a-z_]{2,40}$' THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_basis'); END IF;
  v_lat := (p_site->>'lat')::float8; v_lng := (p_site->>'lng')::float8; v_r := (p_site->>'r_m')::float8;
  IF v_lat IS NULL OR v_lng IS NULL OR v_r IS NULL OR v_r <= 0 OR v_r > 600 OR coalesce(p_site->>'kind', '') NOT IN ('point', 'place')
     OR (p_site->>'kind' = 'point' AND v_r > 250) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_site'); END IF;
  SELECT vi.* INTO v FROM public.visits vi WHERE vi.id = p_visit_id FOR UPDATE;
  IF v.id IS NULL OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_completed'); END IF;
  IF public.fn_time_on_site_is_locked(v.id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'locked'); END IF;
  IF v.duration_minutes IS DISTINCT FROM p_expected_minutes OR v.time_on_site_source IS DISTINCT FROM p_expected_source THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'changed_since_read'); END IF;
  w0 := (v.visit_date::timestamp - interval '4 hours') AT TIME ZONE 'America/New_York';
  w1 := ((v.visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York';
  IF p_arrival < w0 OR p_arrival >= w1 THEN RETURN jsonb_build_object('ok', false, 'reason', 'arrival_outside_window'); END IF;
  IF v.vehicle_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_truck'); END IF;
  SELECT r.latitude::float8 la, r.longitude::float8 lo INTO f0 FROM public.vehicle_telemetry_readings r
   WHERE r.vehicle_id = v.vehicle_id AND r.latitude IS NOT NULL AND r.recorded_at <= p_arrival AND r.recorded_at > p_arrival - interval '30 minutes'
   ORDER BY r.recorded_at DESC LIMIT 1;
  SELECT r.latitude::float8 la, r.longitude::float8 lo INTO f1 FROM public.vehicle_telemetry_readings r
   WHERE r.vehicle_id = v.vehicle_id AND r.latitude IS NOT NULL AND r.recorded_at >= p_departure AND r.recorded_at < p_departure + interval '30 minutes'
   ORDER BY r.recorded_at LIMIT 1;
  IF f0 IS NULL OR f1 IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_stored_fix_at_an_end'); END IF;
  IF 6371008.8 * 2 * asin(sqrt(power(sin(radians(f0.la - v_lat) / 2), 2) + cos(radians(v_lat)) * cos(radians(f0.la)) * power(sin(radians(f0.lo - v_lng) / 2), 2))) > v_r
     OR 6371008.8 * 2 * asin(sqrt(power(sin(radians(f1.la - v_lat) / 2), 2) + cos(radians(v_lat)) * cos(radians(f1.la)) * power(sin(radians(f1.lo - v_lng) / 2), 2))) > v_r THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stored_fix_outside_site'); END IF;
  v_hdr := current_setting('request.headers', true);
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', format('Time on site set to Samsara''s stay (nightly rule v15, %s, %s site; plan 5.2, Fred 2026-10-27).', replace(p_basis, '_', ' '), p_site->>'kind')))::text, true);
  UPDATE public.visits SET actual_arrival_at = p_arrival, actual_departure_at = p_departure,
         duration_minutes = round(extract(epoch FROM p_departure - p_arrival) / 60)::integer, time_on_site_source = 'samsara_stay'
   WHERE id = v.id;
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  RETURN jsonb_build_object('ok', n = 1, 'reason', CASE WHEN n = 1 THEN 'saved' ELSE 'not_written' END);
END $f$;

-- 4. The close-out (plan 5.5 b): one ledger row per visit leaving the window, idempotent. p_rows = [{visit_id, status
--    ('applied' | 'proposed'), action, method, confidence, old: {minutes, arrival_ms, departure_ms, source}, evidence}].
--    applied is accepted only for keep_verified / nightly_self and blank / no_samsara_presence; the live row is read
--    here (new_*), FOR UPDATE.
CREATE OR REPLACE FUNCTION public.fn_close_time_on_site(p_rows jsonb, p_run_date date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
DECLARE r jsonb; v record; ins int := 0; skipped int := 0; refused jsonb := '[]'::jsonb; v_status text; v_action text; o jsonb;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'close-out: expected an array' USING errcode = '22023'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    SELECT vi.* INTO v FROM public.visits vi WHERE vi.id = (r->>'visit_id')::bigint FOR UPDATE;
    v_status := r->>'status'; v_action := r->>'action'; o := r->'old';
    IF v.id IS NULL OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL OR v.visit_date <> p_run_date THEN
      refused := refused || jsonb_build_array(jsonb_build_object('visit_id', r->>'visit_id', 'reason', 'not_a_completed_visit_of_the_run_date')); CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c WHERE c.visit_id = v.id AND c.superseded_at IS NULL) THEN skipped := skipped + 1; CONTINUE; END IF;
    IF v_status = 'applied' AND NOT ((v_action = 'keep_verified' AND r->>'method' = 'nightly_self' AND v.duration_minutes IS NOT NULL)
                                  OR (v_action = 'blank' AND r->>'method' = 'no_samsara_presence' AND v.duration_minutes IS NULL)) THEN
      refused := refused || jsonb_build_array(jsonb_build_object('visit_id', v.id, 'reason', 'applied_not_allowed_for_this_row')); CONTINUE; END IF;
    IF v_status NOT IN ('applied', 'proposed') THEN
      refused := refused || jsonb_build_array(jsonb_build_object('visit_id', v.id, 'reason', 'bad_status')); CONTINUE; END IF;
    IF v_status = 'applied' AND v_action = 'keep_verified'
       AND ((o->>'minutes')::int IS DISTINCT FROM v.duration_minutes OR o->>'source' IS DISTINCT FROM v.time_on_site_source) THEN
      v_action := 'change';   -- the run saved a new value before closing it (plan 5.5 b)
    END IF;
    INSERT INTO public.visit_time_on_site_corrections
      (visit_id, run_id, param_version, old_vehicle_id, new_vehicle_id, stage, action, status, old_arrival, old_departure, old_minutes, old_source,
       old_visit_date, old_completed_at, bonus_decided_at_seen, new_arrival, new_departure, new_minutes, new_source, method, confidence, evidence,
       applied_at, applied_by_migration)
    VALUES (v.id, 'nightly-' || to_char(p_run_date, 'YYYYMMDD'), 'recheck-v15-rules2', v.vehicle_id, v.vehicle_id, 'nightly', v_action, v_status,
       to_timestamp((o->>'arrival_ms')::bigint / 1000.0), to_timestamp((o->>'departure_ms')::bigint / 1000.0), (o->>'minutes')::int, o->>'source',
       v.visit_date, v.completed_at, (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = v.id),
       v.actual_arrival_at, v.actual_departure_at, v.duration_minutes, v.time_on_site_source, r->>'method', r->>'confidence',
       coalesce(r->'evidence', '{}'::jsonb), CASE WHEN v_status = 'applied' THEN now() END, NULL);
    ins := ins + 1;
  END LOOP;
  RETURN jsonb_build_object('inserted', ins, 'already_closed', skipped, 'refused', refused);
END $f$;

REVOKE ALL ON FUNCTION public.fn_time_on_site_recheck_visits(date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_time_on_site_recheck_fixes(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_save_time_on_site_stay(bigint, timestamptz, timestamptz, integer, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_close_time_on_site(jsonb, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_recheck_visits(date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_recheck_fixes(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_save_time_on_site_stay(bigint, timestamptz, timestamptz, integer, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_close_time_on_site(jsonb, date) TO service_role;

DO $verify$
DECLARE s text; d date := (now() AT TIME ZONE 'America/New_York')::date; j jsonb;
BEGIN
  FOREACH s IN ARRAY ARRAY['public.fn_time_on_site_recheck_visits(date,date)', 'public.fn_time_on_site_recheck_fixes(jsonb)', 'public.fn_save_time_on_site_stay(bigint,timestamptz,timestamptz,integer,text,text,jsonb)', 'public.fn_close_time_on_site(jsonb,date)'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(s)) THEN RAISE EXCEPTION 'VERIFY: % is not SECURITY DEFINER', s; END IF;
    IF (SELECT proconfig::text FROM pg_proc WHERE oid = to_regprocedure(s)) IS DISTINCT FROM '{"search_path=\"\""}' THEN RAISE EXCEPTION 'VERIFY: % has no empty search_path', s; END IF;
    IF has_function_privilege('anon', s, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: anon can run %', s; END IF;
    IF has_function_privilege('authenticated', s, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: authenticated can run %', s; END IF;
    IF NOT has_function_privilege('service_role', s, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: service_role cannot run %', s; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = to_regprocedure(s) AND a.grantee = 0) THEN RAISE EXCEPTION 'VERIFY: PUBLIC can run %', s; END IF;
  END LOOP;
  j := public.fn_time_on_site_recheck_visits(d - 10, d + 1);
  IF j->>'read_at_ms' IS NULL THEN RAISE EXCEPTION 'VERIFY: the read has no read_at_ms'; END IF;
  IF jsonb_array_length(j->'visits') = 0 THEN RAISE EXCEPTION 'VERIFY: the read found no visit in today''s window'; END IF;
  IF jsonb_array_length(j->'overrides') <> 5 THEN RAISE EXCEPTION 'VERIFY: the read did not return the 5 overrides'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE stage = 'nightly') <> 0 THEN RAISE EXCEPTION 'VERIFY: a nightly ledger row exists'; END IF;
END $verify$;

COMMIT;
