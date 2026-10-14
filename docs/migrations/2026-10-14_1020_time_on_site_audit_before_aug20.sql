-- ============================================================================
-- 2026-10-14_1020 Time on site, step 6a: audit the saved values before Aug 20 from the raw GPS
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "go ahead with step 6" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos): the 976 client values saved before Aug 20, when the stop table did not exist yet, get the step 5 audit.
--
-- WHAT CHANGES (read-only objects; nothing is written to visits here)
--   1. public.fn_time_on_site_verdicts: the verdict rules, moved out of fn_time_on_site_audit unchanged (the body is the
--      live block with the column names renamed to parameters), so both audits share ONE copy.
--   2. fn_time_on_site_audit calls it. Proven: identical output before and after (V1).
--   3. public.fn_time_on_site_audit_gps(p_date): the same audit for one date with the reference rebuilt from the raw GPS
--      (fn_gps_stays) with algorithm 2's matching. Validated on Aug 20 to Oct 13, where both exist: 243 of 264 equal,
--      3 within 2 min (seconds of walk edge); the other 18 are stays shared by several visits (kept whole here, review
--      only). 25 ms a day.
--   scripts/checks/time_on_site_audit.mjs then reads it per date before Aug 20, adds Samsara and the same gate.
-- ROLLBACK: drop fn_time_on_site_audit_gps and fn_time_on_site_verdicts after restoring fn_time_on_site_audit from
--   2026-10-13_2350.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_time_on_site_audit'::regproc))) IS DISTINCT FROM '3af59d39a780e7c6a039a85726e5f8b1' THEN
    RAISE EXCEPTION 'fn_time_on_site_audit changed since this file was written: splice from the live body again'; END IF;
END $g$;
CREATE TEMP TABLE _before6 ON COMMIT DROP AS SELECT * FROM public.fn_time_on_site_audit();

CREATE FUNCTION public.fn_time_on_site_verdicts(p_visit_date date, p_completed_at timestamptz,
    p_saved_arrival timestamptz, p_saved_departure timestamptz, p_saved_minutes integer,
    p_ra timestamptz, p_rd timestamptz, p_rm integer, p_sharing integer, p_truck_question text, p_stale boolean)
RETURNS text[] LANGUAGE sql STABLE SET search_path TO ''
AS $f$
  -- the verdict rules of the time on site audit, ONE copy (2026-10-14_1020): fn_time_on_site_audit (stop table, since
  -- Aug 20) and fn_time_on_site_audit_gps (raw GPS walk, any date) both call it
  SELECT array_remove(ARRAY[
           CASE WHEN p_ra IS NULL THEN 'no_reference' END,
           CASE WHEN p_ra IS NOT NULL AND (p_saved_departure <= p_ra OR p_saved_arrival >= p_rd) THEN 'wrong_stay' END,
           CASE WHEN p_ra IS NOT NULL AND p_saved_minutes < 0.7 * p_rm AND p_rm - p_saved_minutes >= 5 THEN 'too_short' END,
           CASE WHEN p_ra IS NOT NULL AND p_saved_minutes >= p_rm + 15 THEN 'too_long' END,
           CASE WHEN p_saved_arrival > p_completed_at + interval '15 minutes' THEN 'closed_before_arrival' END,
           CASE WHEN p_rd IS NOT NULL AND p_rd > p_saved_departure + interval '1 minute'
                 AND (abs(extract(epoch FROM p_saved_departure
                       - (((p_visit_date + 1)::timestamp + interval '4 hours') AT TIME ZONE 'America/New_York'))) <= 60
                  OR abs(extract(epoch FROM p_saved_departure
                       - (((p_visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York'))) <= 60)
                THEN 'window_cut' END,
           CASE WHEN p_sharing > 1 THEN 'shared_stop' END,
           CASE WHEN p_truck_question IS NOT NULL THEN 'truck_question' END,
           CASE WHEN p_stale THEN 'stale' END,
           CASE WHEN p_saved_minutes > 180 OR p_saved_minutes < 5 THEN 'extreme' END], NULL)
$f$;
REVOKE ALL ON FUNCTION public.fn_time_on_site_verdicts(date, timestamptz, timestamptz, timestamptz, integer, timestamptz, timestamptz, integer, integer, text, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_verdicts(date, timestamptz, timestamptz, timestamptz, integer, timestamptz, timestamptz, integer, integer, text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_time_on_site_audit(p_from date DEFAULT '2026-08-20'::date)
 RETURNS TABLE(visit_id bigint, visit_date date, vehicle_id bigint, completed_at timestamp with time zone, saved_arrival timestamp with time zone, saved_departure timestamp with time zone, saved_minutes integer, saved_source text, ref_arrival timestamp with time zone, ref_departure timestamp with time zone, ref_minutes integer, ref_sharing integer, ref_split_ok boolean, other_completion_inside boolean, truck_question text, stale boolean, verdicts text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
         public.fn_time_on_site_verdicts(y.visit_date, y.completed_at, y.actual_arrival_at, y.actual_departure_at,
           y.duration_minutes, y.ra, y.rd, y.rm, y.sharing, y.truck_q, y.stale_)
    FROM y
   ORDER BY y.visit_date, y.id;
$function$
;

CREATE FUNCTION public.fn_time_on_site_audit_gps(p_date date)
RETURNS TABLE(visit_id bigint, visit_date date, vehicle_id bigint, completed_at timestamptz,
              saved_arrival timestamptz, saved_departure timestamptz, saved_minutes integer, saved_source text,
              ref_arrival timestamptz, ref_departure timestamptz, ref_minutes integer, ref_sharing integer, ref_split_ok boolean,
              other_completion_inside boolean, truck_question text, stale boolean, verdicts text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $f$
  -- 2026-10-14_1020 (time on site plan step 6): fn_time_on_site_audit for ONE date, with the reference rebuilt from the
  -- raw GPS (public.fn_gps_stays, the stop builder's own walk) instead of the stop table, so it works before Aug 20.
  -- Same matching as fn_link_visit_vehicle_stops algorithm 2: the visit's truck's stay holding the completion within
  -- 250 m (150 m first), its earlier adjacent stays (gap <= 15 min, within 250 m) joined, never past another visit's
  -- completion stay, a tap more than 2 min after leaving on a stay holding another completion claims nothing. A shared
  -- stay is reported whole with ref_sharing > 1 (never split here: it only goes to review). Read-only.
  WITH RECURSIVE tr AS (
    SELECT DISTINCT e.entity_id AS vehicle_id FROM public.entity_source_links e
     WHERE e.entity_type = 'vehicle' AND e.source_system = 'samsara'),
  st AS (
    SELECT tr.vehicle_id, g.arrived_at, g.departed_at, g.latitude, g.longitude,
           row_number() OVER (PARTITION BY tr.vehicle_id ORDER BY g.arrived_at) AS rn
      FROM tr, LATERAL public.fn_gps_stays(tr.vehicle_id,
             (p_date::timestamp AT TIME ZONE 'America/New_York') - interval '4 hours',
             ((p_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York', 100, 3) g),
  allv AS (
    SELECT vi.id, vi.client_id, vi.vehicle_id, vi.completed_at, vi.visit_date, vi.property_id, vi.actual_arrival_at,
           vi.actual_departure_at, vi.duration_minutes, vi.time_on_site_source, p.latitude AS plat, p.longitude AS plng,
           public.fn_is_non_customer(vi.client_id) AS non_customer
      FROM public.visits vi LEFT JOIN public.properties p ON p.id = vi.property_id
     WHERE vi.visit_status = 'completed' AND vi.deleted_at IS NULL AND vi.visit_date = p_date AND vi.vehicle_id IS NOT NULL),
  near AS (
    SELECT a.id, s.vehicle_id, s.rn, s.arrived_at, s.departed_at,
           ops.fn_haversine_km(a.plat, a.plng, s.latitude, s.longitude) * 1000 AS m
      FROM allv a JOIN st s ON s.vehicle_id = a.vehicle_id
     WHERE a.plat IS NOT NULL AND NOT a.non_customer
       AND ops.fn_haversine_km(a.plat, a.plng, s.latitude, s.longitude) * 1000 <= 250),
  c0 AS (
    SELECT DISTINCT ON (a.id) a.id, n.vehicle_id, n.rn, n.arrived_at, n.departed_at,
           (a.completed_at <= n.departed_at + interval '2 minutes') AS inside
      FROM allv a JOIN near n ON n.id = a.id
     WHERE a.completed_at BETWEEN n.arrived_at - interval '5 minutes' AND n.departed_at + interval '15 minutes'
     ORDER BY a.id, (n.m > 150), abs(extract(epoch FROM n.departed_at - a.completed_at)), n.rn),
  c AS (
    SELECT c0.* FROM c0
     WHERE c0.inside OR NOT EXISTS (SELECT 1 FROM c0 o WHERE o.vehicle_id = c0.vehicle_id AND o.rn = c0.rn
                                     AND o.id <> c0.id AND o.inside)),
  ch AS (
    SELECT c.id, c.vehicle_id, c.rn, 0 AS depth FROM c
    UNION ALL
    SELECT ch.id, p.vehicle_id, p.rn, ch.depth + 1
      FROM ch
      JOIN st cur ON cur.vehicle_id = ch.vehicle_id AND cur.rn = ch.rn
      JOIN near p ON p.id = ch.id AND p.vehicle_id = ch.vehicle_id AND p.rn = ch.rn - 1
     WHERE cur.arrived_at - p.departed_at <= interval '15 minutes'
       AND NOT EXISTS (SELECT 1 FROM c0 o WHERE o.vehicle_id = p.vehicle_id AND o.rn = p.rn AND o.id <> ch.id)
       AND ch.depth < 20),
  ref AS (
    SELECT c.id, min(s.arrived_at) AS ra, c.departed_at AS rd,
           (SELECT count(*) FROM c c2 WHERE c2.vehicle_id = c.vehicle_id AND c2.rn = c.rn)::integer AS sharing
      FROM c JOIN ch ON ch.id = c.id JOIN st s ON s.vehicle_id = ch.vehicle_id AND s.rn = ch.rn
     GROUP BY c.id, c.vehicle_id, c.rn, c.departed_at),
  y AS (
    SELECT a.*, r.ra, r.rd, r.sharing, round(extract(epoch FROM r.rd - r.ra) / 60)::integer AS rm,
           EXISTS (SELECT 1 FROM allv o WHERE o.id <> a.id AND o.vehicle_id = a.vehicle_id
                     AND o.completed_at BETWEEN coalesce(r.ra, a.actual_arrival_at) - interval '5 minutes'
                                            AND coalesce(r.rd, a.actual_departure_at)) AS other_inside,
           CASE
             WHEN EXISTS (SELECT 1 FROM st s WHERE s.vehicle_id <> a.vehicle_id AND a.plat IS NOT NULL
                             AND ops.fn_haversine_km(a.plat, a.plng, s.latitude, s.longitude) * 1000 <= 250
                             AND a.completed_at BETWEEN s.arrived_at - interval '5 minutes' AND s.departed_at + interval '2 minutes')
               THEN 'another truck was stopped there at the completion'
             WHEN EXISTS (SELECT 1 FROM audit.logs l WHERE l.table_name = 'visits' AND l.record_pk->>'id' = a.id::text
                           AND l.app_source IN ('sql', 'truck-from-gps') AND l.changed_at > a.completed_at
                           AND l.old_row->>'vehicle_id' IS NOT NULL
                           AND l.new_row->>'vehicle_id' IS DISTINCT FROM l.old_row->>'vehicle_id')
               THEN 'the truck was changed automatically after the completion' END AS truck_q,
           (SELECT max(l.changed_at) FROM audit.logs l WHERE l.table_name = 'visits' AND l.record_pk->>'id' = a.id::text
               AND l.new_row->>'duration_minutes' IS DISTINCT FROM l.old_row->>'duration_minutes') AS written_at
      FROM allv a LEFT JOIN ref r ON r.id = a.id
     WHERE a.duration_minutes IS NOT NULL AND NOT a.non_customer)
  SELECT y.id, y.visit_date, y.vehicle_id, y.completed_at, y.actual_arrival_at, y.actual_departure_at, y.duration_minutes,
         y.time_on_site_source, y.ra, y.rd, y.rm, y.sharing, (y.sharing IS NULL OR y.sharing = 1), y.other_inside, y.truck_q,
         s.stale,
         public.fn_time_on_site_verdicts(y.visit_date, y.completed_at, y.actual_arrival_at, y.actual_departure_at,
           y.duration_minutes, y.ra, y.rd, y.rm, y.sharing, y.truck_q, s.stale)
    FROM y
    CROSS JOIN LATERAL (SELECT (y.written_at IS NOT NULL AND EXISTS (
              SELECT 1 FROM audit.logs l WHERE l.table_name = 'properties' AND l.record_pk->>'id' = y.property_id::text
                AND l.changed_at > y.written_at
                AND (l.new_row->>'latitude' IS DISTINCT FROM l.old_row->>'latitude'
                     OR l.new_row->>'longitude' IS DISTINCT FROM l.old_row->>'longitude'))) AS stale) s
   ORDER BY y.id;
$f$;
REVOKE ALL ON FUNCTION public.fn_time_on_site_audit_gps(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_audit_gps(date) TO service_role;
COMMENT ON FUNCTION public.fn_time_on_site_audit_gps(date) IS 'fn_time_on_site_audit for one date with the reference rebuilt from the raw GPS (fn_gps_stays), same matching as the stop linker algorithm 2; works before the stop table (2026-08-20). Read-only, service_role only. 2026-10-14_1020.';


DO $v$
DECLARE n int; m int;
BEGIN
  -- V1 the audit is unchanged by the refactor
  IF (SELECT count(*) FROM (SELECT * FROM _before6 EXCEPT SELECT * FROM public.fn_time_on_site_audit()) z) <> 0
     OR (SELECT count(*) FROM _before6) <> (SELECT count(*) FROM public.fn_time_on_site_audit()) THEN
    RAISE EXCEPTION 'V1: the audit changed'; END IF;
  -- V2 the GPS reference agrees with the stop table where both exist and the stay is not shared
  CREATE TEMP TABLE _g6 ON COMMIT DROP AS SELECT g.* FROM generate_series(date '2026-08-20', date '2026-10-13', interval '1 day') d,
    LATERAL public.fn_time_on_site_audit_gps(d::date) g;
  SELECT count(*), count(*) FILTER (WHERE abs(extract(epoch FROM g.ref_arrival - a.ref_arrival)) <= 300
                                       AND abs(extract(epoch FROM g.ref_departure - a.ref_departure)) <= 300)
    INTO n, m FROM _g6 g JOIN _before6 a USING (visit_id)
   WHERE g.ref_arrival IS NOT NULL AND a.ref_arrival IS NOT NULL AND g.ref_sharing = 1 AND a.ref_sharing = 1;
  IF n < 200 OR m < n THEN RAISE EXCEPTION 'V2: GPS reference agrees within 5 min on % of % unshared visits', m, n; END IF;
  -- V3 the controls before Aug 20 (step 4 filled them from this same walk)
  IF (SELECT ref_minutes FROM public.fn_time_on_site_audit_gps(date '2026-06-11') WHERE visit_id = 4794) IS DISTINCT FROM 85 THEN
    RAISE EXCEPTION 'V3: 4794 reference'; END IF;
  IF has_function_privilege('authenticated', 'public.fn_time_on_site_audit_gps(date)', 'EXECUTE') THEN RAISE EXCEPTION 'V4: grants'; END IF;
END $v$;

COMMIT;
