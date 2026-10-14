-- ============================================================================
-- 2026-10-13_2320 Time on site, step 4: fill the blanks the GPS can prove, mark the drive-bys
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 4" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos; defaults approved). After step 3, 88 completed client visits of 2026 still had no time on site.
--
-- WHAT CHANGES
--   1. 12 visits from before the stop table (it starts 2026-08-20) get the truck's GPS stop that holds the completion time
--      (public.fn_gps_stays, the stop builder's own walk, on the visit's own truck, within 250 m), as the plan's gate
--      requires: Samsara's trip gap (the trip ending before, the trip starting after) agrees within 5 min at BOTH ends,
--      and no other visit of that truck was completed inside the stay. Measured 2026-10-13 23:00 ET: every one agrees
--      within 3 min (control 6509: ours 34 min, Samsara 32). Source stop_at_completion, labelled time-on-site-backfill.
--      Four more had a stop at the completion but Samsara's gap is 5 to 17 min longer (5061, 5157, 5788, 6496): not
--      written, they go to the review list.
--   2. 6 visits where the truck only drove past (under 3 min) are marked reviewed_blank, nothing to measure:
--      1416, 1509, 5990, 7088, 7277, 8765. Duration stays empty. Reversible: set time_on_site_source back to NULL.
--   3. fn_time_on_site_gaps (the 11 AM alert and the report) leaves reviewed_blank visits out, in both places it
--      counts blanks.
--   Not done here, on the review list (samsara-checks/time_on_site_review_2026-10-13.md): wrong truck (6194, 6498, 7319:
--   Diego confirms the truck, then step 3's rules measure it), truck there but not at the completion, done another day,
--   no truck near, no map point or a far Samsara place (step 7). Dump visits have their own fix.
--   Nothing reaches Jobber: the time columns and time_on_site_source are outside both push triggers.
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse.
-- ROLLBACK: put fn_time_on_site_gaps back from 2026-10-13_1935 (the live body this splices, md5 below) and clear the
--   rows labelled time-on-site-backfill (audit.logs keeps old_row: every one was blank before).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_time_on_site_gaps'::regproc))) IS DISTINCT FROM '36b48a3f07e0ba4f7fb69a28e6bc61ea' THEN
    RAISE EXCEPTION 'fn_time_on_site_gaps changed since this file was written: splice from the live body again'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_time_on_site_gaps(p_date date DEFAULT (((now() AT TIME ZONE 'America/New_York'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with gap as (
    select v.id, v.visit_date, v.vehicle_id, v.service_type, v.completed_at, v.client_id, v.property_id,
           c.client_code, c.name as client_name,
           p.latitude::float8 as plat, p.longitude::float8 as plon
      from public.visits v
      join public.clients c on c.id = v.client_id
      left join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date = p_date
       and v.duration_minutes is null
       and v.time_on_site_source is distinct from 'reviewed_blank'   -- 2026-10-13_2320: nothing to measure
       and not coalesce(public.fn_is_non_customer(v.client_id), false)
  ), pings as (
    -- every GPS point of every truck in the window (not only the near ones): a point elsewhere is what ends a stay
    select g.id, r.vehicle_id, r.recorded_at,
           sqrt(power((r.latitude - g.plat) * 111320, 2) +
                power((r.longitude - g.plon) * 111320 * cos(radians(g.plat)), 2)) as d
      from gap g
      join public.vehicle_telemetry_readings r
        on g.plat is not null
       and r.recorded_at >= (g.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  ((g.visit_date + 1) + time '10:00') at time zone 'America/New_York'
  ), closest as (
    select distinct on (id) id, vehicle_id, recorded_at, d from pings order by id, d
  ), marked as (
    -- A STAY is consecutive points within 150 m, however long the silence between them (a parked truck with its
    -- engine off can send no GPS), ended by a point outside 150 m or a silence over 4 hours. So two drive-bys are two
    -- passes, never one stay: visit 8765 (2026-10-09), David passed Casa Neos at 13:53 and 14:38 ET and was 500 m to
    -- 1.3 km away in between. Taking a truck's first and last near point as one stay (a report of 2026-10-12 did)
    -- reads that as "there 45 minutes". This list only describes; it fills nothing.
    select id, vehicle_id, recorded_at, d,
           case when lag(d) over w is null or lag(d) over w > 150 or d > 150
                  or recorded_at - lag(recorded_at) over w > interval '4 hours' then 1 else 0 end as n
      from pings
    window w as (partition by id, vehicle_id order by recorded_at)
  ), cl as (
    select id, vehicle_id, recorded_at, d, sum(n) over (partition by id, vehicle_id order by recorded_at) as c from marked
  ), stays as (
    select id, vehicle_id, min(recorded_at) as first_at, max(recorded_at) as last_at,
           round(extract(epoch from max(recorded_at) - min(recorded_at)) / 60)::int as minutes
      from cl where d <= 150 group by id, vehicle_id, c
  ), day_stops as (
    -- every truck's stops in the window (public.fn_gps_stays: the stop builder's 100 m walk, any date), computed only
    -- on a day that lists something. Visit 6509 (2026-09-25): David parked 164 m from our map point 10:29 to 11:03
    -- while the job was marked complete at 10:54, which the 150 m stays above see as a 1-minute drive-by.
    select vh.id as vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from public.vehicles vh
      cross join lateral public.fn_gps_stays(vh.id,
                   (p_date::timestamp at time zone 'America/New_York') - interval '4 hours',
                   ((p_date + 1) + time '10:00') at time zone 'America/New_York') s
     where exists (select 1 from gap)
  ), at_completion as (
    -- the stop that holds completed_at (the stop matcher's tolerance: 5 min before arrival to 15 min after departure),
    -- within 250 m of our map point; the visit's own truck first, then the nearest
    select distinct on (g.id) g.id, ds.vehicle_id, ds.arrived_at, ds.departed_at, ds.latitude, ds.longitude,
           ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude) * 1000 as m
      from gap g
      join day_stops ds
        on g.completed_at between ds.arrived_at - interval '5 minutes' and ds.departed_at + interval '15 minutes'
     where g.plat is not null
       and ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude) * 1000 <= 250
     order by g.id, (ds.vehicle_id is not distinct from g.vehicle_id) desc,
              ops.fn_haversine_km(g.plat::numeric, g.plon::numeric, ds.latitude, ds.longitude)
  ), truck as (
    select vh.id, vh.name,
           (select e.source_id from public.entity_source_links e
             where e.entity_type = 'vehicle' and e.entity_id = vh.id and e.source_system = 'samsara' limit 1) as samsara_id
      from public.vehicles vh
  )
  select jsonb_build_object(
    'date', p_date,
    'older_count', (select count(*) from public.visits v
                     where v.visit_status = 'completed' and v.deleted_at is null and v.duration_minutes is null
                       and v.time_on_site_source is distinct from 'reviewed_blank'
                       and v.visit_date >= p_date - 30 and v.visit_date < p_date
                       and not coalesce(public.fn_is_non_customer(v.client_id), false)),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'visit_id', g.id, 'visit_date', g.visit_date, 'client_code', g.client_code, 'client_name', g.client_name,
               'service', g.service_type, 'completed_at', g.completed_at,
               'lat', g.plat, 'lng', g.plon,
               'truck', t.name, 'truck_samsara_id', t.samsara_id,
               'property_place_id', (select regexp_replace(e.source_id, '^addr_', '') from public.entity_source_links e
                                      where e.entity_type = 'property' and e.entity_id = g.property_id
                                        and e.source_system = 'samsara' limit 1),
               'client_place_ids', coalesce((select jsonb_agg(regexp_replace(e.source_id, '^addr_', '')) from public.entity_source_links e
                                              where e.entity_type = 'client' and e.entity_id = g.client_id
                                                and e.source_system = 'samsara'), '[]'::jsonb),
               'closest', (select jsonb_build_object('truck', ct.name, 'truck_samsara_id', ct.samsara_id,
                                                     'meters', round(c.d), 'at', c.recorded_at)
                             from closest c join truck ct on ct.id = c.vehicle_id where c.id = g.id),
               'stays', coalesce((select jsonb_agg(jsonb_build_object('truck', st.name, 'truck_samsara_id', st.samsara_id,
                                                                    'first', s.first_at, 'last', s.last_at, 'minutes', s.minutes)
                                                 order by s.minutes desc)
                                    from stays s join truck st on st.id = s.vehicle_id where s.id = g.id), '[]'::jsonb),
               'stop_at_completion', (select jsonb_build_object('truck', tr.name, 'truck_samsara_id', tr.samsara_id,
                                                                'assigned', ac.vehicle_id is not distinct from g.vehicle_id,
                                                                'arrived', ac.arrived_at, 'departed', ac.departed_at,
                                                                'minutes', round(extract(epoch from ac.departed_at - ac.arrived_at) / 60)::int,
                                                                'meters', round(ac.m), 'lat', ac.latitude, 'lng', ac.longitude)
                                        from at_completion ac join truck tr on tr.id = ac.vehicle_id where ac.id = g.id))
             order by g.client_code, g.id)
        from gap g left join truck t on t.id = g.vehicle_id), '[]'::jsonb));
$function$
;

CREATE TEMP TABLE _fill4 (visit_id bigint, arrival timestamptz, departure timestamptz, samsara_minutes int) ON COMMIT DROP;
INSERT INTO _fill4 VALUES
    (1256, timestamptz '2026-01-07T07:49:06+00:00', timestamptz '2026-01-07T08:36:27.023+00:00', 45),
    (1359, timestamptz '2026-02-06T11:54:00+00:00', timestamptz '2026-02-06T12:43:01.012+00:00', 48),
    (1524, timestamptz '2026-03-23T11:54:29+00:00', timestamptz '2026-03-23T12:24:58.007+00:00', 30),
    (1801, timestamptz '2026-04-30T03:01:00+00:00', timestamptz '2026-04-30T04:56:42.141+00:00', 114),
    (5768, timestamptz '2026-06-08T19:35:21+00:00', timestamptz '2026-06-08T20:09:33+00:00', 34),
    (4794, timestamptz '2026-06-11T11:35:47+00:00', timestamptz '2026-06-11T13:01:06+00:00', 85),
    (5822, timestamptz '2026-06-22T04:38:02+00:00', timestamptz '2026-06-22T06:31:59+00:00', 116),
    (5830, timestamptz '2026-06-24T12:46:36+00:00', timestamptz '2026-06-24T13:12:25+00:00', 25),
    (6054, timestamptz '2026-06-28T08:37:57+00:00', timestamptz '2026-06-28T10:03:59+00:00', 84),
    (7050, timestamptz '2026-07-08T14:31:57+00:00', timestamptz '2026-07-08T15:18:14+00:00', 45),
    (7272, timestamptz '2026-07-20T15:27:53+00:00', timestamptz '2026-07-20T15:49:55+00:00', 21),
    (7790, timestamptz '2026-08-17T16:17:32+00:00', timestamptz '2026-08-17T16:32:47+00:00', 15);
CREATE TEMP TABLE _pre4 ON COMMIT DROP AS SELECT id, sync_state, vehicle_id FROM public.visits;

-- the proof, re-read here: the stay is the truck's own GPS walk, and no other visit of that truck closed inside it
DO $p$
DECLARE r record;
BEGIN
  FOR r IN SELECT f.*, v.vehicle_id, v.visit_date, v.completed_at, v.duration_minutes FROM _fill4 f JOIN public.visits v ON v.id = f.visit_id LOOP
    IF r.duration_minutes IS NOT NULL THEN RAISE EXCEPTION 'visit % is no longer blank', r.visit_id; END IF;
    IF r.completed_at NOT BETWEEN r.arrival - interval '5 minutes' AND r.departure + interval '15 minutes' THEN
      RAISE EXCEPTION 'visit %: the completion is not inside the stay', r.visit_id; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.fn_gps_stays(r.vehicle_id,
                     (r.visit_date::timestamp AT TIME ZONE 'America/New_York') - interval '4 hours',
                     ((r.visit_date + 1)::timestamp + interval '10 hours') AT TIME ZONE 'America/New_York', 100, 3) s
                    WHERE s.arrived_at = r.arrival AND s.departed_at = r.departure) THEN
      RAISE EXCEPTION 'visit %: the stay is not in the truck''s GPS walk', r.visit_id; END IF;
    IF EXISTS (SELECT 1 FROM public.visits o WHERE o.id <> r.visit_id AND o.vehicle_id = r.vehicle_id
                AND o.visit_status = 'completed' AND o.deleted_at IS NULL
                AND o.completed_at BETWEEN r.arrival - interval '5 minutes' AND r.departure) THEN
      RAISE EXCEPTION 'visit %: another visit of the truck was completed inside the stay', r.visit_id; END IF;
  END LOOP;
END $p$;

SELECT set_config('request.headers', jsonb_build_object('x-app-source', 'time-on-site-backfill',
  'x-change-reason', 'Time on site from the truck''s GPS stop that holds the completion time, confirmed by Samsara''s trip gap within 5 min at both ends (time on site plan step 4).')::text, true);
UPDATE public.visits v SET actual_arrival_at = f.arrival, actual_departure_at = f.departure,
       duration_minutes = round(extract(epoch from f.departure - f.arrival) / 60)::integer,
       time_on_site_source = 'stop_at_completion'
  FROM _fill4 f
 WHERE v.id = f.visit_id AND v.duration_minutes IS NULL AND v.visit_status = 'completed' AND v.deleted_at IS NULL;

SELECT set_config('request.headers', jsonb_build_object('x-app-source', 'time-on-site-backfill',
  'x-change-reason', 'Nothing to measure: the truck only drove past the property (under 3 min) that day, checked against its GPS (time on site plan step 4).')::text, true);
UPDATE public.visits SET time_on_site_source = 'reviewed_blank'
 WHERE id IN (1416, 1509, 5990, 7088, 7277, 8765) AND duration_minutes IS NULL AND visit_status = 'completed' AND deleted_at IS NULL
   AND time_on_site_source IS NULL;
SELECT set_config('request.headers', '', true);

DO $v$
DECLARE n int; m int; g jsonb;
BEGIN
  SELECT count(*) INTO n FROM public.visits v JOIN _fill4 f ON f.visit_id = v.id
   WHERE v.time_on_site_source = 'stop_at_completion' AND v.actual_arrival_at = f.arrival AND v.actual_departure_at = f.departure
     AND abs(v.duration_minutes - f.samsara_minutes) <= 5;
  IF n <> 12 THEN RAISE EXCEPTION 'V1: % of 12 filled', n; END IF;
  IF (SELECT count(*) FROM public.visits WHERE id IN (1416, 1509, 5990, 7088, 7277, 8765) AND time_on_site_source = 'reviewed_blank' AND duration_minutes IS NULL) <> 6 THEN
    RAISE EXCEPTION 'V2: drive-bys not all marked'; END IF;
  SELECT count(*) INTO m FROM audit.logs a WHERE a.table_name = 'visits' AND a.txid = txid_current()
     AND a.app_source = 'time-on-site-backfill' AND coalesce(a.request_context->>'change_reason', '') <> '';
  IF m <> 12 + 6 THEN RAISE EXCEPTION 'V3: % labelled audit rows', m; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v JOIN _pre4 p ON p.id = v.id
              WHERE v.sync_state IS DISTINCT FROM p.sync_state OR v.vehicle_id IS DISTINCT FROM p.vehicle_id) THEN
    RAISE EXCEPTION 'V4: a sync_state or a truck moved'; END IF;
  -- the alert no longer lists a marked visit (8765, Oct 9), and still lists the others of that date
  g := public.fn_time_on_site_gaps(date '2026-10-09');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(g->'visits') x WHERE (x->>'visit_id')::int = 8765) THEN
    RAISE EXCEPTION 'V5: the alert still lists 8765'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(g->'visits') x WHERE (x->>'visit_id')::int = 8752) THEN
    RAISE EXCEPTION 'V5: the alert lost 8752 (control)'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_gaps'::regproc)
     IS DISTINCT FROM (SELECT '{postgres=X/postgres,service_role=X/postgres}') THEN RAISE EXCEPTION 'V6: gaps ACL'; END IF;
END $v$;

COMMIT;
