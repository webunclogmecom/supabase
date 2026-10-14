-- ============================================================================
-- 2026-10-14_1800 Time on site: the "went there once that date" rule in the nightly Samsara recheck
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "add the went-once rule to the nightly recheck". The rule is his, from visit 8017 the same day:
--   "give 8017 the 1h 23m, because they had the same truck, and also they just went once that date", then 3942/5078
--   ("the data is in 3942"). Applied by hand to 92 + 2 visits in 2026-10-14_1700 / _1730; this makes it automatic.
-- THE RULE
--   A completed customer visit whose truck was NOT parked at the address when it was marked complete (no stay of
--   that truck, within 250 m, arriving in the visit window and holding the tap -5 / +15 min), but VISITED the address
--   exactly once in the visit window (visit date -4 h to 10 AM next day; the truck's stays there, fn_gps_stays 3 min
--   or more within 250 m, joined when less than 15 min apart, so a re-park is one visit). Two visits of one client
--   may share that visit (two services, one stop: 8013 and 8017; 3942 and 5078).
-- WHAT CHANGES
--   1. public.fn_time_on_site_went_once(p_from, p_to, p_visit_id default null): those visits, with the truck's
--      Samsara id and the visit's span. Skips review / reviewed_blank / dump_site_dwell values. service_role only.
--   2. public.fn_save_samsara_stay_went_once(visit, arrival, departure, expected_minutes, expected_source):
--      re-runs the rule for that one visit, requires the Samsara stay to overlap the span, the saved time to still be
--      what the caller read, then writes source samsara_stay (x-app-source time-on-site-samsara, with a reason).
--   3. Edge fn time-on-site-samsara-recheck v3 runs this as a second pass after the completion pass (fresh read), with
--      the same Samsara reading: one trip gap over the span, saved when blank or 2 min or more off; skipped when
--      Samsara shows the truck moving (two stays over the span) or no stay.
-- ROLLBACK: drop the two functions and redeploy time-on-site-samsara-recheck v2 (commit 3fdfd59).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION public.fn_time_on_site_went_once(p_from date, p_to date, p_visit_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $f$
  with v as (
    select vi.id, vi.visit_date, vi.vehicle_id, vi.completed_at, vi.duration_minutes, vi.time_on_site_source,
           p.latitude as plat, p.longitude as plon,
           (vi.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours' as w0,
           ((vi.visit_date + 1) + time '10:00') at time zone 'America/New_York' as w1
      from public.visits vi join public.properties p on p.id = vi.property_id
     where vi.visit_status = 'completed' and vi.deleted_at is null and vi.vehicle_id is not null
       and vi.visit_date >= p_from and vi.visit_date < p_to
       and (p_visit_id is null or vi.id = p_visit_id)
       and p.latitude is not null and p.longitude is not null
       and not public.fn_is_non_customer(vi.client_id)
       and coalesce(vi.time_on_site_source, '') not in ('review', 'reviewed_blank', 'dump_site_dwell')
  ), d as (
    select distinct vehicle_id, visit_date from v
  ), st as (
    select d.vehicle_id, d.visit_date, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from d cross join lateral public.fn_gps_stays(d.vehicle_id,
             (d.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours',
             ((d.visit_date + 1) + time '10:00') at time zone 'America/New_York') s
  ), near as (
    select v.id, st.arrived_at, st.departed_at
      from v join st on st.vehicle_id = v.vehicle_id and st.visit_date = v.visit_date
     where st.arrived_at >= v.w0 and st.arrived_at < v.w1
       and ops.fn_haversine_km(v.plat, v.plon, st.latitude, st.longitude) * 1000 <= 250
  ), brk as (      -- stays less than 15 min apart are one visit to the site (a re-park)
    select id, arrived_at, departed_at,
           case when lag(departed_at) over w is null or arrived_at - lag(departed_at) over w > interval '15 minutes'
                then 1 else 0 end as nb
      from near window w as (partition by id order by arrived_at)
  ), grp as (
    select id, arrived_at, departed_at, sum(nb) over (partition by id order by arrived_at) as g from brk
  ), visit_spans as (
    select id, g, min(arrived_at) as a, max(departed_at) as d from grp group by id, g
  ), x as (
    select v.*, (select count(*) from visit_spans s where s.id = v.id) as n_visits,
           (select s.a from visit_spans s where s.id = v.id order by s.a limit 1) as span_a,
           (select s.d from visit_spans s where s.id = v.id order by s.a limit 1) as span_d,
           exists (select 1 from near n where n.id = v.id and v.completed_at between n.arrived_at - interval '5 minutes'
                                                                        and n.departed_at + interval '15 minutes') as holds_tap
      from v
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'visit_id', x.id, 'visit_date', x.visit_date, 'truck_samsara_id', e.source_id,
           'arrived', x.span_a, 'departed', x.span_d, 'duration_minutes', x.duration_minutes,
           'source', x.time_on_site_source) order by x.id), '[]'::jsonb)
    from x join public.entity_source_links e on e.entity_type = 'vehicle' and e.source_system = 'samsara' and e.entity_id = x.vehicle_id
   where x.n_visits = 1 and not x.holds_tap
$f$;

CREATE FUNCTION public.fn_save_samsara_stay_went_once(p_visit_id bigint, p_arrival timestamptz, p_departure timestamptz,
                                                      p_expected_minutes integer, p_expected_source text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $f$
DECLARE v_hdr text; n integer; v_date date; c jsonb;
BEGIN
  IF p_arrival IS NULL OR p_departure IS NULL OR p_departure <= p_arrival OR p_departure - p_arrival > interval '12 hours' THEN
    RAISE EXCEPTION 'The Samsara stay is not a valid time span.' USING errcode = '22023',
      DETAIL = 'blocker=bad_span in public.fn_save_samsara_stay_went_once'; END IF;
  SELECT visit_date INTO v_date FROM public.visits WHERE id = p_visit_id;
  IF v_date IS NULL THEN RETURN false; END IF;
  c := public.fn_time_on_site_went_once(v_date, v_date + 1, p_visit_id) -> 0;
  IF c IS NULL OR NOT ((c->>'arrived')::timestamptz < p_departure AND (c->>'departed')::timestamptz > p_arrival) THEN
    RETURN false; END IF;
  v_hdr := current_setting('request.headers', true);
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', 'Time on site set to Samsara''s stay: the truck went to the address once on the visit''s date, and was not there when the job was marked complete (nightly recheck, Fred 2026-10-14).'))::text, true);
  UPDATE public.visits v
     SET actual_arrival_at = p_arrival, actual_departure_at = p_departure,
         duration_minutes = round(extract(epoch FROM p_departure - p_arrival) / 60)::integer,
         time_on_site_source = 'samsara_stay'
   WHERE v.id = p_visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'dump_site_dwell')
     AND v.duration_minutes IS NOT DISTINCT FROM p_expected_minutes
     AND v.time_on_site_source IS NOT DISTINCT FROM p_expected_source;
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  RETURN n = 1;
END $f$;

REVOKE ALL ON FUNCTION public.fn_time_on_site_went_once(date, date, bigint) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_save_samsara_stay_went_once(bigint, timestamptz, timestamptz, integer, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_went_once(date, date, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_save_samsara_stay_went_once(bigint, timestamptz, timestamptz, integer, text) TO service_role;

-- VERIFY: the two visits the rule came from are found with the stay Fred approved; a stale save and an off-span save refuse
DO $v$ DECLARE c jsonb; ok boolean; BEGIN
  IF has_function_privilege('authenticated', 'public.fn_save_samsara_stay_went_once(bigint, timestamptz, timestamptz, integer, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_time_on_site_went_once(date, date, bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: a staff or anon role can execute'; END IF;
  c := public.fn_time_on_site_went_once(date '2026-09-04', date '2026-09-05', 8017) -> 0;
  IF c IS NULL OR (c->>'arrived')::timestamptz > timestamptz '2026-09-05 04:05-04' OR (c->>'departed')::timestamptz < timestamptz '2026-09-05 05:20-04' THEN
    RAISE EXCEPTION 'VERIFY: 8017 not found with its Sep 5 stay: %', c; END IF;
  c := public.fn_time_on_site_went_once(date '2026-05-11', date '2026-05-12', 3942) -> 0;
  IF c IS NULL OR (c->>'departed')::timestamptz - (c->>'arrived')::timestamptz < interval '6 hours' THEN
    RAISE EXCEPTION 'VERIFY: 3942 not found as one visit (re-park joined): %', c; END IF;
  -- a visit whose truck WAS parked there when it was marked complete is not this rule's (6509)
  IF public.fn_time_on_site_went_once(date '2026-09-25', date '2026-09-26', 6509) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY: 6509 (truck there at completion) wrongly matched'; END IF;
  BEGIN
    ok := public.fn_save_samsara_stay_went_once(8017, timestamptz '2026-09-05T08:02:20Z', timestamptz '2026-09-05T09:25:50Z', 999, 'samsara_stay');
    IF ok THEN RAISE EXCEPTION 'VERIFY: a stale expected value wrote'; END IF;
    ok := public.fn_save_samsara_stay_went_once(8017, timestamptz '2026-09-07T17:00:00Z', timestamptz '2026-09-07T18:00:00Z', 84, 'samsara_stay');
    IF ok THEN RAISE EXCEPTION 'VERIFY: a stay off the span wrote'; END IF;
    ok := public.fn_save_samsara_stay_went_once(8017, timestamptz '2026-09-05T08:02:20Z', timestamptz '2026-09-05T09:25:50Z', 84, 'samsara_stay');
    IF NOT ok THEN RAISE EXCEPTION 'VERIFY: a valid save did not write'; END IF;
    RAISE EXCEPTION USING errcode = 'P0902';
  EXCEPTION WHEN sqlstate 'P0902' THEN NULL; END;
END $v$;
COMMIT;
