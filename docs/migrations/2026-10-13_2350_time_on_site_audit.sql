-- ============================================================================
-- 2026-10-13_2350 Time on site, step 5a: one stop reference, and a read-only audit of the saved values
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 5" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos): audit the time on site saved since Aug 20 against the truck stops and Samsara, correct automatically only
--   under the strict gate, and put the rest on a review list.
--
-- WHAT CHANGES
--   1. public.v_visit_stop_reference: the time the truck stops give a visit (completion stop + completion_chain, a
--      shared stop split at the completion times with split_ok, or a dump visit's dump link). It is the body of
--      fn_fill_time_on_site_from_stops' candidate list, moved out unchanged so the fill and the audit cannot disagree.
--   2. fn_fill_time_on_site_from_stops reads it (split_ok rows). Proven unchanged below: same candidates, same values.
--   3. public.fn_time_on_site_audit(p_from): read-only, every saved time on site of a completed client visit since
--      p_from with the reference and verdicts (no_reference, wrong_stay, too_short, too_long, closed_before_arrival,
--      window_cut, shared_stop, truck_question, stale, extreme). scripts/checks/time_on_site_audit.mjs adds
--      Samsara's trip gap and builds the review list. Both service_role only. Writes nothing.
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse.
-- ROLLBACK: drop the function and the view after restoring fn_fill_time_on_site_from_stops from 2026-10-13_2210.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops'::regproc))) IS DISTINCT FROM '77e8e51a01c6ad02056da8fdabb16f27' THEN
    RAISE EXCEPTION 'fn_fill_time_on_site_from_stops changed since this file was written: splice from the live body again'; END IF;
END $g$;

-- the old fill's candidates, to prove the new one is the same
SELECT public.fn_fill_time_on_site_from_stops(false);
CREATE TEMP TABLE _old_fill ON COMMIT DROP AS SELECT * FROM _fill_stops;

CREATE VIEW public.v_visit_stop_reference AS
WITH a AS (
  SELECT l.visit_id, s.id AS stop_id, s.vehicle_id, s.arrived_at, s.departed_at, v.completed_at,
         (SELECT min(s2.arrived_at) FROM public.visit_vehicle_stops l2
            JOIN public.vehicle_stops s2 ON s2.id = l2.vehicle_stop_id AND s2.superseded_at IS NULL
           WHERE l2.visit_id = l.visit_id AND l2.deleted_at IS NULL AND l2.match_basis = 'completion_chain') AS chain_arrived
    FROM public.visit_vehicle_stops l
    JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
    JOIN public.visits v ON v.id = l.visit_id
   WHERE l.deleted_at IS NULL AND l.match_basis = 'completion'),
sp0 AS (
  SELECT a.visit_id, a.stop_id, a.vehicle_id, count(*) OVER (PARTITION BY a.stop_id) AS sharing,
         CASE WHEN lag(a.completed_at) OVER w IS NULL THEN least(a.arrived_at, coalesce(a.chain_arrived, a.arrived_at))
              ELSE greatest(least(a.arrived_at, coalesce(a.chain_arrived, a.arrived_at)),
                            least(lag(a.completed_at) OVER w, a.departed_at)) END AS arrival,
         CASE WHEN lead(a.visit_id) OVER w IS NULL THEN a.departed_at
              ELSE least(a.completed_at, a.departed_at) END AS departure
    FROM a
  WINDOW w AS (PARTITION BY a.stop_id ORDER BY a.completed_at, a.visit_id))
SELECT sp0.visit_id, sp0.stop_id, sp0.vehicle_id, sp0.arrival, sp0.departure, 'completion'::text AS basis,
       sp0.sharing::integer AS sharing,
       -- a shared stop is split only when every piece is 10 min or more; completions tapped minutes apart say nothing
       -- about who took how long, so a person decides
       (sp0.sharing = 1 OR NOT EXISTS (SELECT 1 FROM sp0 o WHERE o.stop_id = sp0.stop_id
                                         AND o.departure - o.arrival < interval '10 minutes')) AS split_ok
  FROM sp0
UNION ALL
SELECT l.visit_id, min(l.vehicle_stop_id), min(s.vehicle_id), min(s.arrived_at), max(s.departed_at), min(l.match_basis), 1, true
  FROM public.visit_vehicle_stops l
  JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
 WHERE l.deleted_at IS NULL
 GROUP BY l.visit_id
HAVING count(*) = 1 AND bool_and(l.match_basis IN ('dump_completion', 'dump_window'));
REVOKE ALL ON public.v_visit_stop_reference FROM public, anon, authenticated;
GRANT SELECT ON public.v_visit_stop_reference TO service_role;
COMMENT ON VIEW public.v_visit_stop_reference IS 'The time on site the truck stops give a visit (2026-10-13_2350): its completion stop plus completion_chain stops, a shared stop split at the completion times (split_ok false when a piece is under 10 min), or a dump visit''s single dump link. Read by fn_fill_time_on_site_from_stops (split_ok only) and fn_time_on_site_audit. service_role only.';

CREATE FUNCTION public.fn_time_on_site_audit(p_from date DEFAULT date '2026-08-20')
RETURNS TABLE(visit_id bigint, visit_date date, vehicle_id bigint, completed_at timestamptz,
              saved_arrival timestamptz, saved_departure timestamptz, saved_minutes integer, saved_source text,
              ref_arrival timestamptz, ref_departure timestamptz, ref_minutes integer, ref_sharing integer, ref_split_ok boolean,
              other_completion_inside boolean, truck_question text, stale boolean, verdicts text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $f$
  -- 2026-10-13_2350 (time on site plan step 5): read-only. Every saved time on site of a completed client visit since
  -- p_from, against the truck-stop reference. scripts/checks/time_on_site_audit.mjs adds Samsara's trip gap.
  WITH v AS (
    SELECT vi.id, vi.visit_date, vi.vehicle_id, vi.completed_at, vi.property_id, vi.actual_arrival_at, vi.actual_departure_at,
           vi.duration_minutes, vi.time_on_site_source, p.latitude AS plat, p.longitude AS plng
      FROM public.visits vi LEFT JOIN public.properties p ON p.id = vi.property_id
     WHERE vi.visit_status = 'completed' AND vi.deleted_at IS NULL AND vi.duration_minutes IS NOT NULL
       AND vi.visit_date >= p_from AND NOT public.fn_is_non_customer(vi.client_id)),
  x AS (
    SELECT v.*, r.arrival AS ra, r.departure AS rd, r.sharing, r.split_ok,
           round(extract(epoch FROM r.departure - r.arrival) / 60)::integer AS rm,
           (SELECT max(a.changed_at) FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = v.id::text
               AND a.new_row->>'duration_minutes' IS DISTINCT FROM a.old_row->>'duration_minutes') AS written_at
      FROM v LEFT JOIN public.v_visit_stop_reference r ON r.visit_id = v.id AND r.basis = 'completion'),
  y AS (
    SELECT x.*,
           EXISTS (SELECT 1 FROM public.visits o WHERE o.id <> x.id AND o.vehicle_id = x.vehicle_id
                     AND o.visit_status = 'completed' AND o.deleted_at IS NULL
                     AND o.completed_at BETWEEN coalesce(x.ra, x.actual_arrival_at) - interval '5 minutes'
                                            AND coalesce(x.rd, x.actual_departure_at)) AS other_inside,
           CASE
             WHEN EXISTS (SELECT 1 FROM public.vehicle_stops s
                           WHERE s.superseded_at IS NULL AND s.site_property_id IS NULL AND s.vehicle_id <> x.vehicle_id
                             AND x.plat IS NOT NULL
                             AND ops.fn_haversine_km(x.plat, x.plng, s.latitude, s.longitude) * 1000 <= 250
                             AND x.completed_at BETWEEN s.arrived_at - interval '5 minutes' AND s.departed_at + interval '2 minutes')
               THEN 'another truck was stopped there at the completion'
             WHEN EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = x.id::text
                           AND a.app_source IN ('sql', 'truck-from-gps') AND a.changed_at > x.completed_at
                           AND a.old_row->>'vehicle_id' IS NOT NULL AND a.new_row->>'vehicle_id' IS DISTINCT FROM a.old_row->>'vehicle_id')
               THEN 'the truck was changed automatically after the completion' END AS truck_q,
           (x.written_at IS NOT NULL AND EXISTS (
              SELECT 1 FROM audit.logs a WHERE a.table_name = 'properties' AND a.record_pk->>'id' = x.property_id::text
                AND a.changed_at > x.written_at
                AND (a.new_row->>'latitude' IS DISTINCT FROM a.old_row->>'latitude'
                     OR a.new_row->>'longitude' IS DISTINCT FROM a.old_row->>'longitude'))) AS stale_
      FROM x)
  SELECT y.id, y.visit_date, y.vehicle_id, y.completed_at, y.actual_arrival_at, y.actual_departure_at, y.duration_minutes,
         y.time_on_site_source, y.ra, y.rd, y.rm, y.sharing, y.split_ok, y.other_inside, y.truck_q, y.stale_,
         array_remove(ARRAY[
           CASE WHEN y.ra IS NULL THEN 'no_reference' END,
           CASE WHEN y.ra IS NOT NULL AND (y.actual_departure_at <= y.ra OR y.actual_arrival_at >= y.rd) THEN 'wrong_stay' END,
           CASE WHEN y.ra IS NOT NULL AND y.duration_minutes < 0.7 * y.rm AND y.rm - y.duration_minutes >= 5 THEN 'too_short' END,
           CASE WHEN y.ra IS NOT NULL AND y.duration_minutes >= y.rm + 15 THEN 'too_long' END,
           CASE WHEN y.actual_arrival_at > y.completed_at + interval '15 minutes' THEN 'closed_before_arrival' END,
           CASE WHEN y.rd IS NOT NULL AND y.rd > y.actual_departure_at + interval '1 minute'
                 AND (abs(extract(epoch FROM y.actual_departure_at
                       - (((y.visit_date + 1)::timestamp + interval '4 hours') AT TIME ZONE 'America/New_York'))) <= 60
                  OR abs(extract(epoch FROM y.actual_departure_at
                       - (((y.visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York'))) <= 60)
                THEN 'window_cut' END,
           CASE WHEN y.sharing > 1 THEN 'shared_stop' END,
           CASE WHEN y.truck_q IS NOT NULL THEN 'truck_question' END,
           CASE WHEN y.stale_ THEN 'stale' END,
           CASE WHEN y.duration_minutes > 180 OR y.duration_minutes < 5 THEN 'extreme' END], NULL)
    FROM y
   ORDER BY y.visit_date, y.id;
$f$;
REVOKE ALL ON FUNCTION public.fn_time_on_site_audit(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_audit(date) TO service_role;
COMMENT ON FUNCTION public.fn_time_on_site_audit(date) IS 'Read-only audit of saved time on site (time on site plan step 5, 2026-10-13_2350): saved vs the truck-stop reference (v_visit_stop_reference), with verdicts no_reference, wrong_stay, too_short, too_long, closed_before_arrival, window_cut, shared_stop, truck_question, stale, extreme. Samsara is added by scripts/checks/time_on_site_audit.mjs.';

CREATE OR REPLACE FUNCTION public.fn_fill_time_on_site_from_stops(p_execute boolean DEFAULT false)
 RETURNS TABLE(candidates integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cand integer := 0;
  v_filled integer := 0;
  v_hdr text;
begin
  drop table if exists _fill_stops;
  -- 2026-10-13 step 3: a customer visit's time on site is its completion stop plus the earlier adjacent stops joined to
  -- it (completion_chain); a stop holding several completions is split at the completion times. A dump site visit keeps
  -- its single dump link. Other links (window, same_site_earlier) are tank volume links and never set the time.
  create temp table _fill_stops on commit drop as
  with cand as (   -- 2026-10-13_2350: the rule lives in public.v_visit_stop_reference (shared with the audit)
    select r.visit_id, r.arrival, r.departure, r.basis from public.v_visit_stop_reference r where r.split_ok)
  select f.visit_id, f.arrival, f.departure, f.basis
    from cand f
    join public.visits v on v.id = f.visit_id
   where v.visit_status = 'completed' and v.deleted_at is null and f.departure > f.arrival
     -- a blank, or (step 3) a value the labelled GPS measurement wrote inside its own 10-day window (it ran before the
     -- stop existed): the stop is better. Values from before 2026-10-13 (source NULL) wait for the step 5 audit.
     and (v.duration_minutes is null
          or (v.time_on_site_source = 'gps_150m_cluster'
              and v.visit_date >= (now() at time zone 'America/New_York')::date - 10))
     and (v.actual_arrival_at is distinct from f.arrival or v.actual_departure_at is distinct from f.departure
          or v.duration_minutes is distinct from round(extract(epoch from f.departure - f.arrival) / 60)::integer
          or v.time_on_site_source is distinct from
             case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end);

  select count(*) into v_cand from _fill_stops;

  if p_execute then
    -- 2026-10-13_2025: labelled, and the source recorded (a completion link, or a dump site visit)
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-from-stops',
           'x-change-reason', 'Time on site copied from the truck stop that holds the completion time (with the truck''s earlier stops there, split when several visits share it), or from the dump site visit.'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer,
           time_on_site_source = case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end
      from _fill_stops f
     where v.id = f.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and (v.duration_minutes is null
            or (v.time_on_site_source = 'gps_150m_cluster'
                and v.visit_date >= (now() at time zone 'America/New_York')::date - 10));
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  return query select v_cand, v_filled;
end
$function$
;

DO $v$
DECLARE n int; r record;
BEGIN
  PERFORM public.fn_fill_time_on_site_from_stops(false);
  SELECT count(*) INTO n FROM (
    (SELECT visit_id, arrival, departure, basis FROM _old_fill EXCEPT SELECT visit_id, arrival, departure, basis FROM _fill_stops)
    UNION ALL
    (SELECT visit_id, arrival, departure, basis FROM _fill_stops EXCEPT SELECT visit_id, arrival, departure, basis FROM _old_fill)) d;
  IF n <> 0 THEN RAISE EXCEPTION 'V1: the fill changed (% rows differ)', n; END IF;
  -- a positive control for V1: the view itself holds the 6509 reference the fill wrote
  IF NOT EXISTS (SELECT 1 FROM public.v_visit_stop_reference WHERE visit_id = 6509 AND split_ok
                  AND arrival = '2026-09-25 14:29:11+00' AND departure = '2026-09-25 15:02:59+00') THEN
    RAISE EXCEPTION 'V1: the reference lost 6509'; END IF;
  -- V2 the audit's controls
  FOR r IN SELECT * FROM (VALUES (6507, 'too_short'), (6106, 'too_short'), (8145, 'too_long'), (8000, 'too_long'),
                                 (7060, 'too_long'), (7018, 'too_long'), (8010, 'wrong_stay'), (8744, 'no_reference'),
                                 (6087, 'shared_stop')) t(v, k) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.fn_time_on_site_audit() a WHERE a.visit_id = r.v AND r.k = ANY (a.verdicts)) THEN
      RAISE EXCEPTION 'V2: visit % is not flagged %', r.v, r.k; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.fn_time_on_site_audit() a WHERE a.visit_id = 6509 AND cardinality(a.verdicts) > 0) THEN
    RAISE EXCEPTION 'V2: 6509 (right) is flagged'; END IF;
  IF has_function_privilege('authenticated', 'public.fn_time_on_site_audit(date)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'public.v_visit_stop_reference', 'SELECT')
     OR has_table_privilege('anon', 'public.v_visit_stop_reference', 'SELECT') THEN RAISE EXCEPTION 'V3: grants'; END IF;
END $v$;

COMMIT;
