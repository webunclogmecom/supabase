-- ============================================================================
-- 2026-09-17_1850  ops.calendar_drive_days: pending must never be NULL (Hours driven, follow-up to _1835)
-- ============================================================================
-- Measured minutes after _1835 applied: every row read pending = NULL, because before the first
-- plan-drive-fill run there is no sync_log row, so v_last_details ->> 'key_rejected' is NULL,
-- NULL = 'true' is NULL, NOT NULL is NULL, and the whole AND chain collapses to NULL. The app's rule
-- is "pending is the ONLY condition that polls or kicks", and a NULL there would mean it never polls
-- a cold window. The two run-level tests are now coalesced to false, and so is bool_or(src = 'missing'),
-- which is NULL on a chain with no legs (header row only: the No-truck row, a legless day). Body copied from _1835 (this
-- function is minutes old and has one source); only those two expressions changed.
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION ops.calendar_drive_days(p_from date, p_to date)
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
    (coalesce(bool_or(s.src = 'missing'), false)
      AND NOT bool_or(s.depot_missing)
      AND NOT bool_or(s.src = 'implausible')
      AND NOT bool_or(s.src = 'failed')
      AND NOT coalesce(v_last_details ->> 'key_rejected' = 'true' OR v_last_details ->> 'quota' = 'true' OR v_last_details ->> 'outage' = 'true' OR v_last_details ->> 'key_missing' = 'true', false)
      AND NOT (coalesce(v_calls, 0) >= v_cap)
      AND NOT EXISTS (SELECT 1 FROM ops.plan_fill_request r
                       WHERE r.range_from <= s.visit_date AND r.range_to >= s.visit_date
                         AND r.requested_at < now() - interval '120 seconds'
                         AND NOT EXISTS (SELECT 1 FROM public.sync_log sl WHERE sl.sync_source = 'plan-drive-fill' AND sl.started_at > r.requested_at))
      AND NOT coalesce(v_last_status = 'error', false)
    ) AS pending,
    CASE
      WHEN bool_or(s.depot_missing) THEN 'no_depot'
      WHEN bool_or(s.src = 'implausible') THEN 'implausible'
      WHEN bool_or(s.src = 'failed') THEN 'failed'
      WHEN NOT coalesce(bool_or(s.src = 'missing'), false) THEN NULL
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

DO $verify$
DECLARE v_today date := (now() AT TIME ZONE 'America/New_York')::date; v_null int; v_n int;
BEGIN
  SELECT count(*) FILTER (WHERE d.pending IS NULL), count(*) INTO v_null, v_n FROM ops.calendar_drive_days(v_today - 7, v_today + 21) d;
  IF v_n = 0 THEN RAISE EXCEPTION 'VERIFY: reader returned no rows'; END IF;
  IF v_null <> 0 THEN RAISE EXCEPTION 'VERIFY: % of % rows still read pending NULL', v_null, v_n; END IF;
  -- a cold chain with a missing leg is pending; a complete or legless chain is not
  SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today - 7, v_today + 21) d WHERE d.pending AND d.legs_known < d.legs AND d.blocked_reason IS NULL;
  IF v_n = 0 THEN RAISE NOTICE 'VERIFY: no pending chain in the window (cache warm), positive control skipped'; END IF;
  SELECT count(*) INTO v_n FROM ops.calendar_drive_days(v_today - 7, v_today + 21) d WHERE d.pending AND (d.complete OR d.legs = 0);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY: % complete or legless chains read pending', v_n; END IF;
  RAISE NOTICE 'VERIFY ok';
END $verify$;

COMMIT;
