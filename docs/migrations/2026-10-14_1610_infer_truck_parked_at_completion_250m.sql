-- ============================================================================
-- 2026-10-14_1610 Time on site: the overnight truck correction trusts the truck parked within 250 m at completion
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "yes do both" (close the gap where the wrong truck is on the visit and the right truck parked
--   150 to 250 m away: the time stays blank because the stop fill only reads the visit's own truck).
-- WHAT CHANGES
--   public.fn_infer_visit_vehicle (cron 27, 03:05 ET, last 10 days). Same signature and counters.
--   Before: a truck on the visit was replaced only when the longest GPS stay within 150 m was decisive (2x and 10 min
--   over the runner-up) AND that truck's stop held the completion within 250 m. A truck parked 150 to 250 m away never
--   won the 150 m test (6498: Moises 181 m for 34 min, 1.5 min within 150 m), so nothing changed and the time stayed
--   blank.
--   Now: the evidence is the ONE truck whose stay (fn_gps_stays, 3 min or more) within 250 m holds the completion time
--   (-5 / +15 min, the stop rule). It replaces another truck on the visit (never on a visit filed on a DERM manifest,
--   unchanged), and fills an empty truck first; an empty truck with no such stay still takes the decisive longest stay.
--   Two trucks parked there at completion decide nothing. Stays are read around the COMPLETION date, so a visit marked
--   complete days later is judged on where the truck was then (8017: visit Sep 4, completed Sep 7, Moises 17 m away).
--   One-time run over the stop era (2026-08-19 to today), measured in a rolled-back A/B against the old body:
--   old 1 change (8778); new 10: 7840 7986 7995 8170 8744 8778 Moises -> Cloggy, 7987 7988 7989 David -> Cloggy,
--   8017 empty -> Moises. 8744 is the visit the step 2 comment names (Cloggy was there 64 min at completion).
--   4 visits are refused because they are on a DERM manifest (Fred decides those). After the truck changes, the hourly
--   link (:35) links their stops and the 03:20 fill saves a blank time; an older saved time is left for the Samsara
--   recheck (2026-10-14_1630).
-- ROLLBACK: restore the body from docs/migrations/2026-10-13_2025_time_on_site_writers_labelled.sql; the truck
--   changes are in audit.logs (x-app-source truck-from-gps) with their old rows.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_infer_visit_vehicle'::regproc))) IS DISTINCT FROM '195a6534e9872aa121dd0f05bce9eca4' THEN
    RAISE EXCEPTION 'fn_infer_visit_vehicle changed since this file was written: splice again'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_infer_visit_vehicle(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3, p_margin_ratio numeric DEFAULT 2.0, p_margin_minutes integer DEFAULT 10)
 RETURNS TABLE(considered integer, evidence integer, already_correct integer, filled_null integer, corrected integer, ambiguous integer, refused_no_evidence integer, refused_filed integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_considered integer; v_evidence integer; v_ok integer;
  v_fill integer; v_fix integer; v_amb integer;
  v_ref_ev integer; v_ref_filed integer; v_hdr text;
begin
  drop table if exists _veh_infer;

  create temp table _veh_infer on commit drop as
  with v as (
    select vi.id, vi.vehicle_id as stored_vehicle, vi.visit_date,
           p.latitude::float8 as plat, p.longitude::float8 as plon
      from public.visits vi
      join public.properties p on p.id = vi.property_id
     where vi.visit_status = 'completed'
       and vi.deleted_at is null
       and vi.visit_date >= p_from and vi.visit_date < p_to
       and p.latitude is not null and p.longitude is not null
  ),
  pings as (
    select v.id, t.vehicle_id, t.recorded_at
      from v
      join public.vehicle_telemetry_readings t
        on t.recorded_at >= (v.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and t.recorded_at <  (v.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
     where sqrt(power((t.latitude  - v.plat) * 111320, 2) +
                power((t.longitude - v.plon) * 111320 * cos(radians(v.plat)), 2)) <= p_radius_m
  ),
  marked as (
    select id, vehicle_id, recorded_at,
           case when lag(recorded_at) over (partition by id, vehicle_id order by recorded_at) is null
                  or recorded_at - lag(recorded_at) over (partition by id, vehicle_id order by recorded_at)
                     > make_interval(mins => p_gap_minutes)
                then 1 else 0 end as nc
      from pings
  ),
  clustered as (
    select id, vehicle_id, recorded_at,
           sum(nc) over (partition by id, vehicle_id order by recorded_at) as cn
      from marked
  ),
  spans as (
    select id, vehicle_id, cn,
           extract(epoch from (max(recorded_at) - min(recorded_at)))/60 as mins
      from clustered group by id, vehicle_id, cn
  ),
  per_vehicle as (
    select distinct on (id, vehicle_id) id, vehicle_id, mins
      from spans where mins >= p_min_minutes
     order by id, vehicle_id, mins desc
  ),
  ranked as (
    select id, vehicle_id, mins,
           row_number() over (partition by id order by mins desc) as rk,
           lead(mins) over (partition by id order by mins desc)   as runner_up_mins
      from per_vehicle
  )
  select v.id                                as visit_id,
         v.stored_vehicle,
         r.vehicle_id                        as gps_vehicle,
         round(r.mins)::integer              as gps_minutes,
         round(coalesce(r.runner_up_mins, 0))::integer as runner_up_minutes,
         -- decisive only when it beats the runner-up on BOTH tests
         (r.runner_up_mins is null
           or (r.mins >= r.runner_up_mins * p_margin_ratio
               and r.mins - r.runner_up_mins >= p_margin_minutes)) as decisive
    from ranked r
    join v on v.id = r.id
   where r.rk = 1;

  select count(*) into v_considered
    from public.visits vi join public.properties p on p.id = vi.property_id
   where vi.visit_status='completed' and vi.deleted_at is null
     and vi.visit_date >= p_from and vi.visit_date < p_to and p.latitude is not null;

  select count(*) into v_evidence from _veh_infer;
  select count(*) into v_ok   from _veh_infer where stored_vehicle = gps_vehicle;
  -- 2026-10-13_2025 (time on site plan, step 2, Fred's default): a truck already on the visit is replaced only when
  -- the GPS truck has a stop (3 min or more, within 250 m) that holds the completion time and the truck on the visit
  -- has none, and never on a visit filed on a DERM manifest (its truck decal prints on the LWT report: Fred decides).
  -- 2026-10-14_1610 (Fred: "yes do both"): that stop is now the evidence on its own. The 150 m longest-stay test above
  -- no longer gates a replacement: a truck parked 150 to 250 m away (visit 6498: Moises 181 m, 34 min, inside its
  -- Samsara place, only 1.5 min within 150 m) never won it, so the wrong truck stayed and the time stayed blank. The
  -- evidence is the ONE truck whose stay (fn_gps_stays, 3 min or more) within 250 m holds the completion time (-5 / +15
  -- min, the stop rule); two such trucks decide nothing. Stays are read around the COMPLETION date, not the visit date
  -- (8017: visit Sep 4, marked complete Sep 7 while Moises was parked 17 m away). An empty truck takes that truck
  -- first, else the longest stay as before.
  drop table if exists _veh_evidence;
  create temp table _veh_evidence on commit drop as
  with c as (
    select vi.id as visit_id, vi.vehicle_id as stored_vehicle, vi.completed_at,
           (vi.completed_at at time zone 'America/New_York')::date as cdate,
           p.latitude as plat, p.longitude as plon,
           exists (select 1 from public.manifest_visits mv join public.derm_manifests dm on dm.id = mv.manifest_id
                    where mv.visit_id = vi.id and dm.deleted_at is null) as filed
      from public.visits vi
      join public.properties p on p.id = vi.property_id
     where vi.visit_status = 'completed' and vi.deleted_at is null
       and vi.visit_date >= p_from and vi.visit_date < p_to
       and p.latitude is not null and p.longitude is not null
  ), trucks as (
    select distinct s.vehicle_id from public.vehicle_stops s
  ), st as (
    select d.cdate, d.vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from (select distinct c.cdate, t.vehicle_id from c cross join trucks t where c.cdate is not null) d
      cross join lateral public.fn_gps_stays(d.vehicle_id,
                   (d.cdate::timestamp at time zone 'America/New_York') - interval '4 hours',
                   ((d.cdate + 1) + time '10:00') at time zone 'America/New_York') s
  ), h as (
    select c.visit_id, array_agg(distinct st.vehicle_id) as holders
      from c join st on st.cdate = c.cdate
       and c.completed_at between st.arrived_at - interval '5 minutes' and st.departed_at + interval '15 minutes'
       and ops.fn_haversine_km(c.plat, c.plon, st.latitude, st.longitude) * 1000 <= 250
     group by c.visit_id
  )
  select c.visit_id, c.stored_vehicle, c.filed, coalesce(h.holders, '{}'::bigint[]) as holders,
         case when cardinality(h.holders) = 1 then h.holders[1] end as holder
    from c left join h using (visit_id);

  select count(*) into v_fix       from _veh_evidence
   where stored_vehicle is not null and holder is not null and holder <> stored_vehicle and not filed;
  select count(*) into v_ref_filed from _veh_evidence
   where stored_vehicle is not null and holder is not null and holder <> stored_vehicle and filed;
  select count(*) into v_fill      from _veh_evidence e left join _veh_infer r using (visit_id)
   where e.stored_vehicle is null and (e.holder is not null or r.decisive);
  select count(*) into v_ref_ev    from _veh_infer r join _veh_evidence e using (visit_id)
   where r.decisive and r.stored_vehicle is not null and r.stored_vehicle <> r.gps_vehicle
     and not (e.holder is not null and e.holder <> e.stored_vehicle);
  select count(*) into v_amb  from _veh_infer where not decisive
                                                and stored_vehicle is distinct from gps_vehicle;

  if p_execute then
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'truck-from-gps',
           'x-change-reason', 'Truck set from GPS: it was the only truck parked within 250 m when the job was marked complete (an empty truck with no such stop takes the truck that stayed there longest).'))::text, true);
    update public.visits v
       set vehicle_id = coalesce(e.holder, r.gps_vehicle)
      from _veh_evidence e
      left join _veh_infer r on r.visit_id = e.visit_id
     where v.id = e.visit_id
       and v.visit_status = 'completed'          -- re-asserted: never touch a plan
       and v.deleted_at is null
       and ((v.vehicle_id is null and (e.holder is not null or r.decisive))
            or (v.vehicle_id is not null and e.holder is not null and e.holder <> v.vehicle_id and not e.filed))
       and v.vehicle_id is distinct from coalesce(e.holder, r.gps_vehicle);
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  considered      := v_considered;
  evidence        := v_evidence;
  already_correct := v_ok;
  filled_null     := v_fill;
  corrected       := v_fix;
  ambiguous       := v_amb;
  refused_no_evidence := v_ref_ev;
  refused_filed   := v_ref_filed;
  return next;
end
$function$
;

CREATE TEMP TABLE _snap ON COMMIT DROP AS SELECT id, vehicle_id FROM public.visits;
SELECT * FROM public.fn_infer_visit_vehicle(date '2026-08-19', current_date + 1, true);

-- VERIFY
DO $v$ DECLARE ch jsonb; BEGIN
  SELECT jsonb_agg(v.id ORDER BY v.id) INTO ch FROM public.visits v JOIN _snap s USING (id) WHERE v.vehicle_id IS DISTINCT FROM s.vehicle_id;
  IF ch IS DISTINCT FROM '[7840, 7986, 7987, 7988, 7989, 7995, 8017, 8170, 8744, 8778]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY: changed set is %', ch; END IF;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 8744) <> (SELECT id FROM public.vehicles WHERE name = 'Cloggy') THEN
    RAISE EXCEPTION 'VERIFY: 8744 not Cloggy'; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v JOIN _snap s USING (id) JOIN public.manifest_visits mv ON mv.visit_id = v.id
              WHERE v.vehicle_id IS DISTINCT FROM s.vehicle_id AND s.vehicle_id IS NOT NULL) THEN
    RAISE EXCEPTION 'VERIFY: a filed visit''s truck moved'; END IF;
END $v$;
COMMIT;
