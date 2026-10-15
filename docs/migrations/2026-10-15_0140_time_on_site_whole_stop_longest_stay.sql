-- ============================================================================
-- 2026-10-15_0140 Time on site: a shared stop counts in full for each visit; a moved truck's longest stay is saved
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15, on the Samsara audit: "For 3 that should be get the whole stop" (one truck stop serving two or
--   more visits: each visit gets the WHOLE stop, never a piece) and "For 7 the stay that most likely is the service"
--   (Samsara shows the truck moving during the job, two or more stays: save the one most likely to be the service,
--   the longest, instead of skipping the visit).
-- WHAT CHANGES
--   1. public.v_visit_stop_reference: a completion stop held by several visits is no longer split at the completion
--      times. Each visit gets arrival = its own earlier adjacent stops (completion_chain) or the stop's arrival,
--      departure = the stop's departure. split_ok stays (always true now) because its readers filter on it. Readers:
--      fn_fill_time_on_site_from_stops, fn_time_on_site_audit, fn_time_on_site_checks (T1), the recheck candidates.
--   2. public.fn_time_on_site_samsara_candidates: no longer leaves out a visit whose completion stop another visit
--      shares (the recheck now saves the whole Samsara stay to each; edge fn time-on-site-samsara-recheck drops its
--      shared_stay skip in the same change).
--   3. public.fn_save_samsara_stay: the Samsara stay may overlap ANY of the visit's job stops (the completion stop or
--      an earlier adjacent completion_chain stop), because the longest stay of a moved truck can be the earlier part.
--      The late-tap protection is unchanged: a saved time is replaced only when the completion stop holds the tap.
--   Bodies spliced from the live definitions (md5 pinned below), only the lines named here changed.
-- ROLLBACK: re-create the three objects from their md5-pinned live bodies (docs/migrations/2026-10-13_2350, _1630).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_viewdef('public.v_visit_stop_reference'::regclass, true)) <> '59837e31c62760bf57a397e99563af1b' THEN
    RAISE EXCEPTION 'v_visit_stop_reference changed since this migration was written'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_samsara_candidates'::regproc)) <> '46c59c9ba334dddede97da0bb689925c' THEN
    RAISE EXCEPTION 'fn_time_on_site_samsara_candidates changed since this migration was written'; END IF;
  IF md5(pg_get_functiondef('public.fn_save_samsara_stay'::regproc)) <> '248525999b4d8a8d6e9bd3642ceb4202' THEN
    RAISE EXCEPTION 'fn_save_samsara_stay changed since this migration was written'; END IF;
END $g$;

CREATE OR REPLACE VIEW public.v_visit_stop_reference AS
 WITH a AS (
         SELECT l.visit_id,
            s.id AS stop_id,
            s.vehicle_id,
            s.arrived_at,
            s.departed_at,
            v.completed_at,
            ( SELECT min(s2.arrived_at) AS min
                   FROM visit_vehicle_stops l2
                     JOIN vehicle_stops s2 ON s2.id = l2.vehicle_stop_id AND s2.superseded_at IS NULL
                  WHERE l2.visit_id = l.visit_id AND l2.deleted_at IS NULL AND l2.match_basis = 'completion_chain'::text) AS chain_arrived
           FROM visit_vehicle_stops l
             JOIN vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
             JOIN visits v ON v.id = l.visit_id
          WHERE l.deleted_at IS NULL AND l.match_basis = 'completion'::text
        )
 SELECT a.visit_id,
    a.stop_id,
    a.vehicle_id,
    LEAST(a.arrived_at, COALESCE(a.chain_arrived, a.arrived_at)) AS arrival,
    a.departed_at AS departure,
    'completion'::text AS basis,
    (count(*) OVER (PARTITION BY a.stop_id))::integer AS sharing,
    true AS split_ok
   FROM a
UNION ALL
 SELECT l.visit_id,
    min(l.vehicle_stop_id) AS stop_id,
    min(s.vehicle_id) AS vehicle_id,
    min(s.arrived_at) AS arrival,
    max(s.departed_at) AS departure,
    min(l.match_basis) AS basis,
    1 AS sharing,
    true AS split_ok
   FROM visit_vehicle_stops l
     JOIN vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
  WHERE l.deleted_at IS NULL
  GROUP BY l.visit_id
 HAVING count(*) = 1 AND bool_and(l.match_basis = ANY (ARRAY['dump_completion'::text, 'dump_window'::text]));

CREATE OR REPLACE FUNCTION public.fn_time_on_site_samsara_candidates(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'visit_id', v.id, 'truck_samsara_id', e.source_id, 'arrived', s.arrived_at, 'departed', s.departed_at,
           'ref_arrived', r.arrival, 'ref_departed', r.departure,
           'completed_at', v.completed_at,
           'holds_tap', v.completed_at between s.arrived_at - interval '5 minutes' and s.departed_at + interval '15 minutes',
           'duration_minutes', v.duration_minutes, 'source', v.time_on_site_source) order by v.id), '[]'::jsonb)
    from public.visits v
    join public.visit_vehicle_stops l on l.visit_id = v.id and l.deleted_at is null and l.match_basis = 'completion'
    join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
    join public.entity_source_links e on e.entity_type = 'vehicle' and e.source_system = 'samsara' and e.entity_id = s.vehicle_id
    left join public.v_visit_stop_reference r on r.visit_id = v.id and r.basis = 'completion'
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and not public.fn_is_non_customer(v.client_id)
     and coalesce(v.time_on_site_source, '') not in ('review', 'reviewed_blank', 'dump_site_dwell')
     -- 2026-10-15_0140 (Fred, decision 3): a stop several visits share is no longer left out; each gets the whole stay
$function$;

CREATE OR REPLACE FUNCTION public.fn_save_samsara_stay(p_visit_id bigint, p_arrival timestamp with time zone, p_departure timestamp with time zone, p_expected_minutes integer, p_expected_source text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_hdr text; n integer;
BEGIN
  IF p_arrival IS NULL OR p_departure IS NULL OR p_departure <= p_arrival OR p_departure - p_arrival > interval '12 hours' THEN
    RAISE EXCEPTION 'The Samsara stay is not a valid time span.' USING errcode = '22023',
      DETAIL = 'blocker=bad_span in public.fn_save_samsara_stay'; END IF;
  v_hdr := current_setting('request.headers', true);
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', 'Time on site set to Samsara''s own stay at the stop where the truck was parked when the job was marked complete (nightly recheck, Fred 2026-10-14; the whole stop when shared, the longest stay when the truck moved, Fred 2026-10-15).'))::text, true);
  UPDATE public.visits v
     SET actual_arrival_at = p_arrival, actual_departure_at = p_departure,
         duration_minutes = round(extract(epoch FROM p_departure - p_arrival) / 60)::integer,
         time_on_site_source = 'samsara_stay'
   WHERE v.id = p_visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND v.duration_minutes IS NOT DISTINCT FROM p_expected_minutes
     AND v.time_on_site_source IS NOT DISTINCT FROM p_expected_source
     -- 2026-10-15_0140: the stay overlaps one of the job's stops (the completion stop or an earlier adjacent one)...
     AND EXISTS (SELECT 1 FROM public.visit_vehicle_stops l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
                  WHERE l.visit_id = v.id AND l.deleted_at IS NULL AND l.match_basis IN ('completion', 'completion_chain')
                    AND s.superseded_at IS NULL AND s.arrived_at < p_departure AND s.departed_at > p_arrival)
     -- ...and a saved time is replaced only when the completion stop holds the tap (a late-tap anchor keeps it)
     AND (v.duration_minutes IS NULL
          OR EXISTS (SELECT 1 FROM public.visit_vehicle_stops l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
                      WHERE l.visit_id = v.id AND l.deleted_at IS NULL AND l.match_basis = 'completion' AND s.superseded_at IS NULL
                        AND v.completed_at BETWEEN s.arrived_at - interval '5 minutes' AND s.departed_at + interval '15 minutes'));
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  RETURN n = 1;
END $function$;

DO $v$
DECLARE r jsonb; n int; m int;
BEGIN
  -- every shared completion stop now gives each visit the whole stop
  SELECT count(*) INTO n FROM public.v_visit_stop_reference r JOIN public.vehicle_stops s ON s.id = r.stop_id
   WHERE r.basis = 'completion' AND r.sharing > 1 AND r.departure <> s.departed_at;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % shared references still split', n; END IF;
  SELECT count(*) INTO m FROM public.v_visit_stop_reference WHERE basis = 'completion' AND sharing > 1;
  IF m = 0 THEN RAISE EXCEPTION 'VERIFY: no shared stop to test against (control)'; END IF;
  -- shared stops now reach the recheck
  SELECT count(*) INTO n FROM jsonb_array_elements(public.fn_time_on_site_samsara_candidates('2026-08-19', '2026-10-20')) c
   WHERE (SELECT sharing FROM public.v_visit_stop_reference r WHERE r.visit_id = (c->>'visit_id')::bigint AND r.basis = 'completion') > 1;
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY: shared-stop visits still left out of the candidates'; END IF;
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T2')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
  -- the late-tap protection still holds: a saved time on a visit whose completion stop does not hold the tap is refused
  SELECT v.id INTO n FROM public.visits v
    JOIN public.visit_vehicle_stops l ON l.visit_id = v.id AND l.deleted_at IS NULL AND l.match_basis = 'completion'
    JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
   WHERE v.duration_minutes IS NOT NULL AND v.visit_status = 'completed' AND v.deleted_at IS NULL
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND v.completed_at NOT BETWEEN s.arrived_at - interval '5 minutes' AND s.departed_at + interval '15 minutes'
   LIMIT 1;
  IF n IS NOT NULL THEN
    IF public.fn_save_samsara_stay(n, (SELECT s.arrived_at FROM public.visit_vehicle_stops l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
                                         WHERE l.visit_id = n AND l.match_basis = 'completion' AND l.deleted_at IS NULL LIMIT 1),
                                      (SELECT s.departed_at FROM public.visit_vehicle_stops l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
                                         WHERE l.visit_id = n AND l.match_basis = 'completion' AND l.deleted_at IS NULL LIMIT 1),
                                      (SELECT duration_minutes FROM public.visits WHERE id = n),
                                      (SELECT time_on_site_source FROM public.visits WHERE id = n)) THEN
      RAISE EXCEPTION 'VERIFY: a late-tap visit (%) was overwritten', n; END IF;
  END IF;
END $v$;

COMMIT;
