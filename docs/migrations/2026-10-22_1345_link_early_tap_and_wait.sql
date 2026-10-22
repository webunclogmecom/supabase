-- 2026-10-22_1345 · fn_link_visit_vehicle_stops algorithm 5: an early tap shares the stop the truck reached; a visit
-- tapped before its stop is built waits instead of borrowing an older stop
--
-- Water audit 2 (Building Apps/Visit Calendar/docs/specs/2026-10-22-water-audit-since-oct-19.md, W1 and W2; Fred picked
-- "Linker: early tap + 1-hour race", 2026-10-22).
-- W1: 6096 (061-TCE, Oct 21) was marked done at 04:51:46 ET Oct 22 from the previous stop (3.2 km away, 44 s after
--   324-BIB's tap); the truck reached 061-TCE 12 min later (stop 1858, 42 m away), which is 001-VIN's (6564) completion
--   stop. Step c0 allows a tap at most 5 min before a stop, cl0 handles late taps only, and step w refused a stop in
--   another visit's chain, so 6096 had no link and no water row. Step w now also takes, for an unanchored volume visit,
--   the FIRST stop its truck reached after the tap when that is within 30 min and within 150 m of the property, unless
--   the stop is another visit's chain stop (a completion anchor may be shared). The stop then serves both visits.
-- W2: the hourly build (fn_refresh_stop_facts) builds stops only up to now - 30 min and never a stay in progress; the
--   linker then saw a visit tapped while its truck was still parked with no stop holding the tap, and the late-tap (cl0)
--   or window (w) step gave it an OLDER stop at the same place for one hour (8860 on Oct 20 07:35-08:35 carried the
--   previous night's 089-COW water; 10 links on 7 visits since Oct 13). Such a visit (tap after its truck's last built
--   stop, no built stop holding the tap, tap less than 3 h ago, not a dump) now waits.
-- Time on site reads completion links only (public.v_visit_stop_reference), so neither change moves a time.
-- Body copied from the live definition (md5 guard), three anchored insertions. VERIFY: today's dry run changes exactly
-- one link (add 6096 on 1858, window); then the linker runs once. Rehearsed separately: the old body gives 8860 stop 1826
-- in a simulated race, the new body gives it nothing.
-- RULE 8: no table created or changed (visit_vehicle_stops rows are written by the function itself).
-- ROLLBACK: docs/migrations/2026-10-22_rollback_link_early_tap_and_wait.sql (algorithm 4 body), then
-- select public.fn_link_visit_vehicle_stops(true);

BEGIN;

DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_link_visit_vehicle_stops(boolean,integer,integer,text[])'::regprocedure))
     <> '571f707411bdeae6376b5135f1d55125' THEN
    RAISE EXCEPTION 'fn_link_visit_vehicle_stops changed since this migration was written';
  END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_link_visit_vehicle_stops(p_execute boolean, p_radius_m integer DEFAULT 150, p_earlier_hours integer DEFAULT 12, p_volume_service_types text[] DEFAULT '{Pumping}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dv bigint[];  v_ds bigint[];  v_db text[];
  v_del int := 0;  v_ins int := 0;  v_by_basis jsonb;  v_changes jsonb;
  -- algorithm 2 (2026-10-13 time on site plan, step 3): the completion match reaches 250 m, and earlier adjacent stops
  -- join it. The window and same-site-earlier matches stay at p_radius_m (150 m): the tank volumes depend on them.
  v_completion_radius_m constant integer := 250;
  v_chain_gap constant interval := interval '15 minutes';
  -- algorithm 5 (2026-10-22, water audit 2): how long a visit tapped before its truck's stop is built waits for it (W2),
  -- and how early a tap may come before the stop the truck reached next (W1)
  v_wait  constant interval := interval '3 hours';
  v_early constant interval := interval '30 minutes';
begin
  if p_execute is null then raise exception 'fn_link_visit_vehicle_stops: execute is required' using errcode = '22023'; end if;
  if p_execute and (p_radius_m <> 150 or p_earlier_hours <> 12
                    or p_volume_service_types is distinct from '{Pumping}'::text[]) then
    raise exception 'thresholds differ from algorithm version 2; bump the version' using errcode = '22023';
  end if;

  with recursive v as (     -- candidates: the whole sensor era, every run
    select vl.id as visit_id, vl.client_id, vl.vehicle_id, vl.completed_at, vl.service_type,
           public.fn_is_non_customer(vl.client_id, array['dump_site']) as is_dump,
           pp.latitude as plat, pp.longitude as plng,
           (vl.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours' as w0,
           ((vl.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York' as w1
      from public.v_visits_live vl
      left join public.properties pp on pp.id = vl.property_id
     where vl.visit_status = 'completed' and vl.vehicle_id is not null and vl.visit_date >= date '2026-08-19'
       and not public.fn_is_non_customer(vl.client_id, array['test', 'fixture'])),   -- algorithm 2: test visits never claim a stop
  vv as (select v.*, (not v.is_dump and v.service_type = any (p_volume_service_types)) as is_volume from v),
  pend as (       -- algorithm 5 (W2, 8860 on 2026-10-20): the hourly build stops 30 min before the run and never emits a
                  --   stay still in progress, so a visit tapped after its truck's last BUILT stop, with no built stop
                  --   holding the tap, may be waiting for its own stop. It waits (no late-tap, no window link) for up to
                  --   v_wait instead of borrowing an older stop at the same place for an hour. After v_wait the late-tap
                  --   and window rules apply as before. Dump visits keep their own rules.
    select vv.visit_id from vv
     where not vv.is_dump and vv.completed_at > now() - v_wait
       and vv.completed_at > coalesce((select max(s.departed_at) from public.vehicle_stops s
                                        where s.vehicle_id = vv.vehicle_id and s.superseded_at is null), '-infinity')
       and vv.visit_id not in (select c0.visit_id from c0)),
  st as (
    select s.id as stop_id, s.vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude, s.site_property_id,
           sp.client_id as site_client_id,
           exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site') as is_dump_stop,
           lag(s.id) over (partition by s.vehicle_id order by s.arrived_at) as prev_id,
           lag(s.departed_at) over (partition by s.vehicle_id order by s.arrived_at) as prev_departed
      from public.vehicle_stops s
      left join public.properties sp on sp.id = s.site_property_id
     where s.superseded_at is null),
  l as (          -- L(V): live non-site stops of the visit's truck within p_radius_m of its property
    select vv.visit_id, st.stop_id, st.arrived_at, st.departed_at
      from vv join st on st.vehicle_id = vv.vehicle_id and st.site_property_id is null
     where not vv.is_dump and vv.plat is not null
       and ops.fn_haversine_km(vv.plat, vv.plng, st.latitude, st.longitude) * 1000 <= p_radius_m),
  l250 as (       -- algorithm 2: the same, within the completion radius, with the distance
    select vv.visit_id, st.stop_id, st.arrived_at, st.departed_at,
           ops.fn_haversine_km(vv.plat, vv.plng, st.latitude, st.longitude) * 1000 as m
      from vv join st on st.vehicle_id = vv.vehicle_id and st.site_property_id is null
     where not vv.is_dump and vv.plat is not null
       and ops.fn_haversine_km(vv.plat, vv.plng, st.latitude, st.longitude) * 1000 <= v_completion_radius_m),
  d as (          -- D(V): live dump stops of the visit's truck at the visit's own dump-site client
    select vv.visit_id, st.stop_id, st.arrived_at, st.departed_at
      from vv join st on st.vehicle_id = vv.vehicle_id and st.is_dump_stop and st.site_client_id = vv.client_id
     where vv.is_dump),
  dc0 as (        -- 1. dump completion anchor: nearest departed_at wins
    select distinct on (vv.visit_id) vv.visit_id, d.stop_id,
           abs(extract(epoch from d.departed_at - vv.completed_at)) as gap
      from vv join d using (visit_id)
     where vv.completed_at between d.arrived_at - interval '5 minutes' and d.departed_at + interval '15 minutes'
     order by vv.visit_id, abs(extract(epoch from d.departed_at - vv.completed_at)), d.stop_id),
  dc as (         -- one dump visit per dump stop (the nearest completion keeps it)
    select visit_id, stop_id from (
      select dc0.*, row_number() over (partition by stop_id order by gap, visit_id) as rn from dc0) x where rn = 1),
  dw0 as (        -- 2. dump elimination inside W(V)
    select vv.visit_id, d.stop_id
      from vv join d using (visit_id)
     where vv.visit_id not in (select visit_id from dc)
       and d.stop_id not in (select stop_id from dc)
       and d.arrived_at >= vv.w0 and d.arrived_at < vv.w1),
  dw as (         -- exactly one candidate, and no other unanchored dump visit wants it (else ambiguous: F1b)
    select x.visit_id, x.stop_id from dw0 x
     where (select count(*) from dw0 y where y.visit_id = x.visit_id) = 1
       and (select count(*) from dw0 y where y.stop_id = x.stop_id) = 1),
  c0 as (         -- 3. completion anchor: the truck's stop holding the completion time; a stop within p_radius_m wins,
                  --    then up to v_completion_radius_m (visit 6509: the truck parked 164 m from the map point)
    select distinct on (vv.visit_id) vv.visit_id, l.stop_id, l.arrived_at, (vv.completed_at <= l.departed_at + interval '2 minutes') as inside
      from vv join l250 l using (visit_id)
     where vv.completed_at between l.arrived_at - interval '5 minutes' and l.departed_at + interval '15 minutes'
     order by vv.visit_id, (l.m > p_radius_m), abs(extract(epoch from l.departed_at - vv.completed_at)), l.stop_id),
  c as (          -- a completion tapped more than 2 min after the truck left (a tap as it rolls off is the same stay),
                  --    on a stop that holds another visit's completion, claims
                  --    nothing: which visit the stop belongs to is a question for a person (the review list)
    select c0.visit_id, c0.stop_id, c0.arrived_at from c0
     where c0.inside
        or not exists (select 1 from c0 o where o.stop_id = c0.stop_id and o.visit_id <> c0.visit_id and o.inside)
    union all     -- 3c. a late tap (2026-10-14_1620)
    select cl.visit_id, cl.stop_id, cl.arrived_at from cl),
  cl0 as (        -- 3c. 2026-10-14_1620 (Fred: "yes do both"): the job was marked complete more than 15 min after the
                  --     truck left, so no stop holds the completion. The truck's LAST stop within v_completion_radius_m
                  --     that arrived inside the visit window (visit date -4 h to 10 AM next day) and left before the
                  --     tap is the anchor, unless it is another visit's completion stop or two such visits want it.
    select distinct on (vv.visit_id) vv.visit_id, l.stop_id, l.arrived_at
      from vv join l250 l using (visit_id)
     where vv.completed_at is not null
       and vv.visit_id not in (select visit_id from c0)
       and vv.visit_id not in (select visit_id from pend)
       and l.arrived_at >= vv.w0 and l.arrived_at < vv.w1
       and l.departed_at + interval '15 minutes' < vv.completed_at
       and l.stop_id not in (select stop_id from c0)
     order by vv.visit_id, l.departed_at desc, l.stop_id),
  cl as (
    select x.visit_id, x.stop_id, x.arrived_at from cl0 x
     where (select count(*) from cl0 y where y.stop_id = x.stop_id) = 1),
  ch as (         -- 3b. the completion stop, then the truck's earlier adjacent stops (gap <= v_chain_gap, within
                  --     v_completion_radius_m), never past a stop that is another visit's anchor, never forward
    select c.visit_id, c.stop_id, 0 as depth from c
    union all
    select ch.visit_id, p.stop_id, ch.depth + 1
      from ch
      join st cur on cur.stop_id = ch.stop_id
      join l250 p on p.visit_id = ch.visit_id and p.stop_id = cur.prev_id
     where cur.arrived_at - cur.prev_departed <= v_chain_gap
       and not exists (select 1 from c0 o where o.stop_id = p.stop_id and o.visit_id <> ch.visit_id)
       and not exists (select 1 from cl o where o.stop_id = p.stop_id and o.visit_id <> ch.visit_id)
       -- algorithm 4 (2026-10-21, water audit A1, visit 6243 / 089-COW): never walk back onto a stop that sits nearer
       -- (within p_radius_m) to another completed volume visit that has no completion anchor of its own and whose
       -- window holds the stop; that visit takes it in step 4 (window) instead
       and not exists (select 1 from vv o join l250 lo on lo.visit_id = o.visit_id and lo.stop_id = p.stop_id
                        where o.visit_id <> ch.visit_id and o.is_volume
                          and o.visit_id not in (select c2.visit_id from c c2)
                          and lo.m <= p_radius_m and lo.m < p.m
                          and p.arrived_at >= o.w0 and p.arrived_at < o.w1)
       and ch.depth < 20),
  w as (          -- 4. window fallback: volume visits only, unanchored, never by scheduled start
    select vv.visit_id, l.stop_id
      from vv join l using (visit_id)
     where vv.is_volume and vv.visit_id not in (select visit_id from c)
       and vv.visit_id not in (select visit_id from pend)
       and l.arrived_at >= vv.w0 and l.arrived_at < vv.w1
       and (not exists (select 1 from ch where ch.stop_id = l.stop_id and ch.visit_id <> vv.visit_id)
            -- algorithm 5 (W1, 6096 / 061-TCE on 2026-10-22): an EARLY tap. The job was marked done up to v_early
            -- before the truck reached this stop (from the previous stop), so no stop holds the tap; the first stop the
            -- truck reached after the tap, within p_radius_m of the property, is shared with the visit whose completion
            -- anchor it is (never with another visit's chain stop)
            or (vv.completed_at < l.arrived_at and l.arrived_at - vv.completed_at <= v_early
                and not exists (select 1 from st s2 where s2.vehicle_id = vv.vehicle_id
                                 and s2.arrived_at > vv.completed_at and s2.arrived_at < l.arrived_at)
                and not exists (select 1 from ch where ch.stop_id = l.stop_id and ch.visit_id <> vv.visit_id
                                 and ch.depth > 0)))),
  e0 as (         -- 5. earlier same-site stops: volume visits with a completion anchor
    select vv.visit_id, l.stop_id, c.arrived_at - l.arrived_at as gap
      from vv join c using (visit_id) join l on l.visit_id = vv.visit_id
     where vv.is_volume
       -- algorithm 3 (2026-10-21, 241-WYN two-trip job): within p_earlier_hours of the anchor OR inside the visit's own window
       and l.arrived_at >= least(c.arrived_at - make_interval(hours => p_earlier_hours), vv.w0) and l.arrived_at < c.arrived_at
       and l.stop_id not in (select stop_id from ch union select stop_id from w
                             union select stop_id from dc union select stop_id from dw)),
  e as (          -- a stop wanted by several visits goes to the nearest anchor after it (both on a tie)
    select visit_id, stop_id from (select e0.*, rank() over (partition by stop_id order by gap) as rk from e0) x where rk = 1),
  desired as (
    select visit_id, stop_id, 'dump_completion'::text as basis from dc
    union all select visit_id, stop_id, 'dump_window' from dw
    union all select visit_id, stop_id, 'completion' from c
    union all select visit_id, stop_id, 'completion_chain' from ch where depth > 0
    union all select visit_id, stop_id, 'window' from w
    union all select visit_id, stop_id, 'same_site_earlier' from e)
  select coalesce(array_agg(visit_id), '{}'), coalesce(array_agg(stop_id), '{}'), coalesce(array_agg(basis), '{}')
    into v_dv, v_ds, v_db
    from desired;

  -- 6. reconcile (whole era): soft-delete live links no longer desired, insert desired links not live
  if p_execute then
    update public.visit_vehicle_stops l set deleted_at = now()
     where l.deleted_at is null
       and not exists (select 1 from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
                        where x.visit_id = l.visit_id and x.stop_id = l.vehicle_stop_id and x.basis = l.match_basis);
    get diagnostics v_del = row_count;
    insert into public.visit_vehicle_stops (visit_id, vehicle_stop_id, match_basis)
    select x.visit_id, x.stop_id, x.basis from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
     where not exists (select 1 from public.visit_vehicle_stops l
                        where l.deleted_at is null and l.visit_id = x.visit_id and l.vehicle_stop_id = x.stop_id);
    get diagnostics v_ins = row_count;
  else
    select count(*) into v_del from public.visit_vehicle_stops l
     where l.deleted_at is null
       and not exists (select 1 from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
                        where x.visit_id = l.visit_id and x.stop_id = l.vehicle_stop_id and x.basis = l.match_basis);
    select count(*) into v_ins from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
     where not exists (select 1 from public.visit_vehicle_stops l
                        where l.deleted_at is null and l.visit_id = x.visit_id and l.vehicle_stop_id = x.stop_id
                          and l.match_basis = x.basis);
    -- the dry run also names every link it would add or retire (algorithm 2), so a change can be read visit by visit
    select coalesce(jsonb_agg(y order by y->>'visit_id', y->>'stop_id'), '[]') into v_changes from (
      select jsonb_build_object('op', 'add', 'visit_id', x.visit_id, 'stop_id', x.stop_id, 'basis', x.basis) as y
        from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
       where not exists (select 1 from public.visit_vehicle_stops l
                          where l.deleted_at is null and l.visit_id = x.visit_id and l.vehicle_stop_id = x.stop_id
                            and l.match_basis = x.basis)
      union all
      select jsonb_build_object('op', 'retire', 'visit_id', l.visit_id, 'stop_id', l.vehicle_stop_id, 'basis', l.match_basis)
        from public.visit_vehicle_stops l
       where l.deleted_at is null
         and not exists (select 1 from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
                          where x.visit_id = l.visit_id and x.stop_id = l.vehicle_stop_id and x.basis = l.match_basis)) z;
  end if;
  select coalesce(jsonb_object_agg(b, n), '{}') into v_by_basis
    from (select x.b, count(*) as n from unnest(v_db) x(b) group by x.b) y;

  return jsonb_build_object('execute', p_execute, 'desired', cardinality(v_dv), 'by_basis', v_by_basis,
                            (case when p_execute then 'inserted' else 'would_insert' end), v_ins,
                            (case when p_execute then 'deleted' else 'would_delete' end), v_del)
         || case when p_execute then '{}'::jsonb else jsonb_build_object('changes', v_changes) end;
end $function$;

-- VERIFY: the dry run changes exactly one link, nothing else in the era
DO $v$
DECLARE r jsonb; ch jsonb;
BEGIN
  r := public.fn_link_visit_vehicle_stops(false);
  ch := r->'changes';
  IF jsonb_array_length(ch) <> 1
     OR NOT ch @> '[{"op":"add","visit_id":6096,"stop_id":1858,"basis":"window"}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY dry run: %', ch;
  END IF;
END $v$;

DO $a$
DECLARE r jsonb;
BEGIN
  r := public.fn_link_visit_vehicle_stops(true);
  IF (r->>'inserted')::int <> 1 OR (r->>'deleted')::int <> 0 THEN RAISE EXCEPTION 'APPLY: %', r; END IF;
END $a$;

-- VERIFY after: 6096 has a water row (flat 315), 6564 keeps its own figures and now shares the stop
DO $w$
DECLARE a record; b record;
BEGIN
  SELECT * INTO a FROM public.get_water_visits(p_visit_id => 6096);
  SELECT * INTO b FROM public.get_water_visits(p_visit_id => 6564);
  IF a.visit_id IS NULL OR abs(a.arrived_gallons - 315) > 2 OR a.pumped_gallons <> 0 OR NOT a.shared_stop THEN
    RAISE EXCEPTION 'VERIFY 6096: %', row_to_json(a);
  END IF;
  IF abs(b.arrived_gallons - 315) > 2 OR b.pumped_gallons <> 0 OR NOT b.shared_stop THEN
    RAISE EXCEPTION 'VERIFY 6564: %', row_to_json(b);
  END IF;
END $w$;

COMMIT;
