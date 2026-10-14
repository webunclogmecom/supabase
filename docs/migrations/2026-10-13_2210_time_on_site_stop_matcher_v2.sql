-- ============================================================================
-- 2026-10-13_2210 Time on site, step 3: the truck stop that holds the completion time decides the time on site
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 3" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos; defaults approved). Visit 6509: the truck parked 164 m from our map point for 34 min, inside its Samsara
--   Place, and every writer measured 150 m from the map point, so the visit had no time on site. Needs 2026-10-13_2020
--   and _2025 first.
--
-- WHAT CHANGES (bodies spliced from the live definitions, md5-pinned)
--   1. fn_link_visit_vehicle_stops, algorithm 2 (version guard bumped):
--      - the completion match reaches 250 m (a stop within 150 m still wins). The window and same-site-earlier matches
--        stay at 150 m: the tank volumes depend on them.
--      - the truck's earlier adjacent stops (gap <= 15 min, within 250 m) join the completion stop as the new link type
--        completion_chain, walking back only, never past a stop that is another visit's completion stop.
--      - a completion tapped more than 2 min after the truck left, on a stop that holds another visit's completion,
--        claims nothing (a person decides). A tap within 2 min of rolling off is the same stay (two visits at one
--        address tapped 7 s apart, 3 s after the truck left).
--      - test and fixture clients never claim a stop (0 do today).
--      - the dry run lists every link it would add or retire ('changes').
--   2. visit_vehicle_stops CHECK gains 'completion_chain'.
--   3. fn_fill_time_on_site_from_stops v2: the completion stop plus its chain; a stop holding several completions is
--      split at the completion times, only when every piece is 10 min or more (else a person decides); dump visits keep
--      their single dump link. Fills blanks, and replaces a value the labelled 150 m measurement wrote inside its own
--      10-day window (it ran before the stop existed). Values from before 2026-10-13 (source NULL) wait for step 5.
--   4. fn_compute_time_on_site: a 150 m stay that starts more than 15 min after the completion is a later trip, not
--      the visit.
--   5. Order: the completion stop first, then the 150 m measurement, then the any-truck fill, in cron 26
--      (time-on-site-nightly), fn_request_time_on_site_reminder and viktor_set_visit_truck. Viktor also relinks the
--      new truck's stops first (under the hourly refresh's lock), and his reply text no longer says "150 m" only.
--   6. fn_stop_facts_checks Z4: a completion or completion_chain link may sit up to 250 m from the property.
--   Then the links are rebuilt and the blanks filled, inside this transaction.
--
-- MEASURED BEFORE APPLY (rolled-back probe of these exact bodies, 2026-10-13 22:00 ET)
--   Links over the whole era: 81 changes. 9 new completion matches, all parked 150 to 250 m away; 41 completion_chain
--   links (30 of them the same visit and stop that was same_site_earlier); 1 window link becomes a chain link (6106).
--   No existing completion match moves or disappears. Integrity Z1..Z9 all 0.
--   Time on site: 8 blank visits filled, each equal to the raw-GPS stop from fn_time_on_site_gaps (step 1):
--   6509 34, 6271 91, 7991 75, 6505 21, 6508 22, 8587 21, 8761 94 (+ dump visit 8777 30). No saved value changes.
--   Link-derived minutes for the controls: 6509 34, 6507 41 (Samsara 40; saved 6, step 5), 8139 54, 8145 16 (saved
--   220, step 5), 6106 101 (saved 8, step 5), 7843 61.
--   Tank volumes: 16 visits change their links (stops gained); sludge changes on 2 (6106 -22.8 -> 22.9 gal, both below
--   resolution; 7873 653.1 -> 409.3, exceeds_trap_size -> too_short).
--   Nothing reaches Jobber: the time columns and time_on_site_source are outside both push triggers.
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse.
-- ROLLBACK: 2026-10-13_rollback_time_on_site_stop_matcher_v2.sql (the 2026-10-13_2025 bodies; chain links retired).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('fn_link_visit_vehicle_stops', 'ea7e3bb2c2389c54373fb59ea45beab0'),
      ('fn_fill_time_on_site_from_stops', 'c27466589f519630e0504ae66d8350bd'),
      ('fn_compute_time_on_site', '6bc5c7d7bce5630e1e8ee2095acffd32'),
      ('fn_request_time_on_site_reminder', '0f3e52bc919a06b2972393604340a433'),
      ('fn_stop_facts_checks', 'd432821d8c3e24c519d1e6e6bc0eab7e'),
      ('viktor_set_visit_truck', 'fdc1791e9cadecb75578e8fd0f2a0c15')) t(f, m) LOOP
    IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = r.f) IS DISTINCT FROM r.m THEN
      RAISE EXCEPTION '% changed since this file was written: splice from the live body again', r.f; END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'visits'
                  AND column_name = 'time_on_site_source') THEN
    RAISE EXCEPTION 'apply 2026-10-13_2020 first (time_on_site_source)'; END IF;
END $g$;

-- the state this migration must not disturb
CREATE TEMP TABLE _pre_completion ON COMMIT DROP AS
  SELECT visit_id, vehicle_stop_id FROM public.visit_vehicle_stops WHERE deleted_at IS NULL AND match_basis = 'completion';
CREATE TEMP TABLE _pre_visits ON COMMIT DROP AS
  SELECT id, duration_minutes, actual_arrival_at, actual_departure_at, time_on_site_source, sync_state, vehicle_id
    FROM public.visits;

ALTER TABLE public.visit_vehicle_stops DROP CONSTRAINT visit_vehicle_stops_match_basis_check;
ALTER TABLE public.visit_vehicle_stops ADD CONSTRAINT visit_vehicle_stops_match_basis_check CHECK (match_basis = ANY
  (ARRAY['completion', 'completion_chain', 'same_site_earlier', 'window', 'dump_completion', 'dump_window']));

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
        or not exists (select 1 from c0 o where o.stop_id = c0.stop_id and o.visit_id <> c0.visit_id and o.inside)),
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
       and ch.depth < 20),
  w as (          -- 4. window fallback: volume visits only, unanchored, never by scheduled start
    select vv.visit_id, l.stop_id
      from vv join l using (visit_id)
     where vv.is_volume and vv.visit_id not in (select visit_id from c)
       and l.arrived_at >= vv.w0 and l.arrived_at < vv.w1
       and not exists (select 1 from ch where ch.stop_id = l.stop_id and ch.visit_id <> vv.visit_id)),
  e0 as (         -- 5. earlier same-site stops: volume visits with a completion anchor
    select vv.visit_id, l.stop_id, c.arrived_at - l.arrived_at as gap
      from vv join c using (visit_id) join l on l.visit_id = vv.visit_id
     where vv.is_volume
       and l.arrived_at >= c.arrived_at - make_interval(hours => p_earlier_hours) and l.arrived_at < c.arrived_at
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
end $function$
;

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
  with a as (
    select l.visit_id, s.id as stop_id, s.arrived_at, s.departed_at, v.completed_at,
           (select min(s2.arrived_at) from public.visit_vehicle_stops l2
              join public.vehicle_stops s2 on s2.id = l2.vehicle_stop_id and s2.superseded_at is null
             where l2.visit_id = l.visit_id and l2.deleted_at is null and l2.match_basis = 'completion_chain') as chain_arrived
      from public.visit_vehicle_stops l
      join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
      join public.visits v on v.id = l.visit_id
     where l.deleted_at is null and l.match_basis = 'completion'),
  sp0 as (
    select a.visit_id, a.stop_id, count(*) over (partition by a.stop_id) as sharing,
           case when lag(a.completed_at) over w is null then least(a.arrived_at, coalesce(a.chain_arrived, a.arrived_at))
                else greatest(least(a.arrived_at, coalesce(a.chain_arrived, a.arrived_at)),
                              least(lag(a.completed_at) over w, a.departed_at)) end as arrival,
           case when lead(a.visit_id) over w is null then a.departed_at
                else least(a.completed_at, a.departed_at) end as departure
      from a
    window w as (partition by a.stop_id order by a.completed_at, a.visit_id)),
  sp as (         -- a shared stop is split only when every piece is 10 min or more; completions tapped minutes apart
                  -- (two visits at one address tapped minutes apart: 64 + 3 min) say nothing about who took how long, so a person decides
    select sp0.visit_id, sp0.arrival, sp0.departure from sp0
     where sp0.sharing = 1
        or not exists (select 1 from sp0 o where o.stop_id = sp0.stop_id and o.departure - o.arrival < interval '10 minutes')),
  cand as (
    select sp.visit_id, sp.arrival, sp.departure, 'completion'::text as basis from sp
    union all
    select l.visit_id, min(s.arrived_at), max(s.departed_at), min(l.match_basis)
      from public.visit_vehicle_stops l
      join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
     where l.deleted_at is null
     group by l.visit_id
    having count(*) = 1 and bool_and(l.match_basis in ('dump_completion', 'dump_window')))
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

CREATE OR REPLACE FUNCTION public.fn_compute_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3)
 RETURNS TABLE(visits_considered integer, visits_resolved integer, visits_blank integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_considered integer := 0;
  v_resolved   integer := 0;
  v_hdr        text;
begin
  -- 🛑 DROP FIRST. `on commit drop` fires at COMMIT, not at return, so two calls inside one
  -- transaction (which is exactly what the VERIFY block below does) hit 42P07 on the second.
  drop table if exists _tos_result;

  create temp table _tos_result on commit drop as
  with target as (
    select v.id, v.vehicle_id, v.visit_date, v.completed_at,
           p.latitude::float8  as plat,
           p.longitude::float8 as plon,
           -- 2026-10-12 guard: the same truck completed a visit at the same property the next day,
           -- so the next morning is that visit's and this one keeps the old +28 h tail
           exists (select 1 from public.visits n
                     where n.vehicle_id = v.vehicle_id and n.property_id = v.property_id
                       and n.visit_date = v.visit_date + 1
                       and n.visit_status = 'completed' and n.deleted_at is null) as next_day_same_site
      from public.visits v
      join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
       and p.latitude is not null and p.longitude is not null
  ),
  pings as (
    select t.id, r.recorded_at
      from target t
      join public.vehicle_telemetry_readings r
        on r.vehicle_id = t.vehicle_id
       -- the whole ET operating day plus the overnight tail, to 10:00 ET next morning (2026-10-12,
       -- Fred: "Extend it, Good."; routes that finished after 04:00 ET came out blank), except when
       -- the guard above says the next morning belongs to the same truck's next-day visit here
       and r.recorded_at >= (t.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  case when t.next_day_same_site
                                 then (t.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
                                 else ((t.visit_date + 1) + time '10:00') at time zone 'America/New_York' end
     where sqrt(power((r.latitude  - t.plat) * 111320, 2) +
                power((r.longitude - t.plon) * 111320 * cos(radians(t.plat)), 2)) <= p_radius_m
  ),
  marked as (
    select id, recorded_at,
           case when lag(recorded_at) over (partition by id order by recorded_at) is null
                  or recorded_at - lag(recorded_at) over (partition by id order by recorded_at)
                     > make_interval(mins => p_gap_minutes)
                then 1 else 0 end as new_cluster
      from pings
  ),
  clustered as (
    select id, recorded_at,
           sum(new_cluster) over (partition by id order by recorded_at) as cluster_no
      from marked
  ),
  spans as (
    select id, cluster_no, min(recorded_at) as arrival, max(recorded_at) as departure,
           extract(epoch from (max(recorded_at) - min(recorded_at)))/60 as minutes
      from clustered
     group by id, cluster_no
  )
  select distinct on (id) id as visit_id, arrival, departure, round(minutes)::integer as minutes
    from spans
   where minutes >= p_min_minutes
     -- 2026-10-13 step 3: a stay that starts more than 15 min after the visit was marked complete is a later trip
     and not exists (select 1 from target t where t.id = spans.id and spans.arrival > t.completed_at + interval '15 minutes')
   order by id, minutes desc;

  select count(*) into v_considered
    from public.visits v
    join public.properties p on p.id = v.property_id
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.vehicle_id is not null and p.latitude is not null;

  select count(*) into v_resolved from _tos_result;

  if p_execute then
    -- 2026-10-13_2025 (time on site plan, step 2): the write is labelled, and it only replaces its OWN values (or
    -- values from before time_on_site_source existed), never a stop-based, any-truck or reviewed one. Until then it
    -- rewrote any differing value of the last 10 days (8744: 68 -> 216 after the truck guesser changed the truck).
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-measure',
           'x-change-reason', 'Time on site measured from the visit''s truck GPS within 150 m of the property.'))::text, true);
    update public.visits v
       set actual_arrival_at   = r.arrival,
           actual_departure_at = r.departure,
           duration_minutes    = r.minutes,
           time_on_site_source = 'gps_150m_cluster'
      from _tos_result r
     where v.id = r.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and (v.actual_arrival_at   is distinct from r.arrival
         or v.actual_departure_at is distinct from r.departure
         or v.duration_minutes    is distinct from r.minutes);
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  visits_considered := v_considered;
  visits_resolved   := v_resolved;
  visits_blank      := v_considered - v_resolved;
  return next;
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_request_time_on_site_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; v_today date := (now() at time zone 'America/New_York')::date;
begin
  -- 11 AM Eastern whatever the season (Fred, 2026-10-07: every scheduled notification at 11): the job runs at 15:00
  -- and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  -- measure first, so a route that ended this morning is not listed as missing; a failure here never skips the alert.
  -- The window ends at YESTERDAY (2026-10-13_2025): measuring today at 11 AM caught trucks still working and froze
  -- cut-short values (the fills write once). Today's visits are measured by the 03:20 nightly run tomorrow.
  begin
    perform public.fn_fill_time_on_site_from_stops(true);   -- 2026-10-13 step 3: the completion stop first
    perform public.fn_compute_time_on_site(v_today - 3, v_today, true);
    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today, true);
  exception when others then
    raise warning 'time on site refresh before the reminder failed: %', sqlerrm;
  end;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the time on site reminder';
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('time_on_site_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The time on site Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/time-on-site-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$
;

CREATE OR REPLACE FUNCTION public.viktor_set_visit_truck(p_visit_id bigint, p_truck text, p_requested_by text, p_reason text, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v record; t record; v_hdr text; v_who text := pg_catalog.btrim(coalesce(p_requested_by, ''));
  v_why text := pg_catalog.btrim(coalesce(p_reason, '')); v_label text; v_trucks text; v_after record;
begin
  select string_agg(name, ', ' order by name) into v_trucks from public.vehicles where status = 'ACTIVE';
  if length(v_who) < 2 then
    return jsonb_build_object('ok', false, 'message', 'I need the name of the person who asked for this change.');
  end if;
  if length(v_why) < 3 then
    return jsonb_build_object('ok', false, 'message', 'I need the reason for this change (the request as it was written).');
  end if;

  select vi.id, vi.visit_status, vi.visit_date, vi.vehicle_id, vi.deleted_at, c.client_code, c.name as client_name,
         (select name from public.vehicles where id = vi.vehicle_id) as old_truck
    into v from public.visits vi join public.clients c on c.id = vi.client_id where vi.id = p_visit_id;
  if v.id is null or v.deleted_at is not null then
    return jsonb_build_object('ok', false, 'message', format('I can''t find visit %s.', p_visit_id));
  end if;
  v_label := format('visit %s (%s %s, %s)', v.id, coalesce(v.client_code, ''), coalesce(v.client_name, ''),
                    to_char(v.visit_date, 'Dy, Mon FMDD'));
  -- Fred, 2026-10-12: "if the visit isn't complete then don't"
  if v.visit_status <> 'completed' then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('I didn''t change %s: it is %s, not completed, and I only change completed visits.', v_label, v.visit_status));
  end if;

  select id, name into t from public.vehicles
   where status = 'ACTIVE' and pg_catalog.lower(name) = pg_catalog.lower(pg_catalog.btrim(coalesce(p_truck, '')));
  if t.id is null then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('There is no truck called "%s". The trucks are %s.', pg_catalog.btrim(coalesce(p_truck, '')), v_trucks));
  end if;
  if v.vehicle_id = t.id then
    return jsonb_build_object('ok', true, 'changed', false, 'visit_id', v.id,
      'message', format('%s already has %s as its truck. Nothing changed.', pg_catalog.initcap(v_label), t.name));
  end if;
  if p_dry_run then
    return jsonb_build_object('ok', true, 'changed', false, 'dry_run', true, 'visit_id', v.id,
      'message', format('I would set %s as the truck on %s (now: %s).', t.name, v_label, coalesce(v.old_truck, 'no truck')));
  end if;

  -- attribution for the audit row, set here so no caller can leave it out; put back right after the write
  v_hdr := pg_catalog.current_setting('request.headers', true);
  perform pg_catalog.set_config('request.headers',
    (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
       || jsonb_build_object('x-app-source', 'viktor', 'x-actor-name', pg_catalog.left(v_who, 120),
                             'x-change-reason', pg_catalog.left(v_why, 500)))::text, true);
  update public.visits set vehicle_id = t.id where id = v.id and visit_status = 'completed' and deleted_at is null;
  perform pg_catalog.set_config('request.headers', coalesce(v_hdr, ''), true);

  -- measure it now, the same way the nightly job does (never clears a value): the stops of the new truck are linked
  -- first (the hourly refresh does the same; its lock keeps the two from running at once), then the completion stop,
  -- then the GPS measurements (2026-10-13 step 3)
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.fn_refresh_stop_facts'));
  perform pg_catalog.set_config('request.headers', '{"x-app-source":"stop-facts"}', true);
  perform public.fn_link_visit_vehicle_stops(true);
  perform pg_catalog.set_config('request.headers', coalesce(v_hdr, ''), true);
  perform public.fn_fill_time_on_site_from_stops(true);
  perform public.fn_compute_time_on_site(v.visit_date, v.visit_date + 1, true);
  perform public.fn_fill_blank_time_on_site(v.visit_date, v.visit_date + 1, true);
  select actual_arrival_at, actual_departure_at, duration_minutes into v_after from public.visits where id = v.id;

  return jsonb_build_object('ok', true, 'changed', true, 'visit_id', v.id, 'truck', t.name,
    'previous_truck', v.old_truck, 'duration_minutes', v_after.duration_minutes,
    'message', format('%s is now the truck on %s%s. ', t.name, v_label,
                      case when v.old_truck is null then '' else ' (it was ' || v.old_truck || ')' end)
      || case when v_after.duration_minutes is not null
              then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              else format('Time on site is still empty: %s''s GPS shows no stop near the property when the visit was marked complete, nor a stay within 150 m of it that day.', t.name) end);
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_stop_facts_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_yard bigint := (select property_id from ops.v_depot limit 1);
  v_new_names text := 'vehicle_tanks|vehicle_tank_configurations|tank_sensors|tank_sensor_installations|'
                   || 'tank_sensor_distance_readings|tank_sensor_fill_percent_readings|vehicle_engine_rpm_readings|'
                   || 'vehicle_pto_readings|vehicle_site_events|vehicle_stops|vehicle_stop_tank_levels|'
                   || 'visit_vehicle_stops|v_vehicle_site_addresses|v_tank_levels|v_vehicle_stop_facts|'
                   || 'v_vehicle_stop_tank_changes|v_visit_tank_service|v_vehicle_dumps|v_tank_data_quality_issues';
  z jsonb;  t jsonb;  f jsonb;  v_z8_control boolean;  v_z6 jsonb;
begin
  -- Z8 positive control: the body sweep must find a known reference (public.visits in derm.audit_pack)
  select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'derm' and p.proname = 'audit_pack'
                    and p.prosrc ~ '[[:<:]]visits[[:>:]]')
    into v_z8_control;

  select jsonb_agg(jsonb_build_object('tank_sensor_id', x.tank_sensor_id, 'pairs', x.n, 'median_pp', round(x.med::numeric, 4)))
    into v_z6
    from (select pr.tank_sensor_id, count(*) as n, percentile_cont(0.5) within group (order by pr.diff) as med
            from (select d.tank_sensor_id,
                         abs(fp.fill_percent - 100 * public.fn_tank_fill_fraction(d.distance_meters, c.diameter_meters, c.sensor_offset_meters))::float8 as diff
                    from public.tank_sensor_distance_readings d
                    join public.tank_sensor_fill_percent_readings fp
                      on fp.tank_sensor_id = d.tank_sensor_id and fp.recorded_at = d.recorded_at
                    join lateral (select i.vehicle_tank_id from public.tank_sensor_installations i
                                   where i.tank_sensor_id = d.tank_sensor_id and i.superseded_at is null
                                     and i.installed_at <= d.recorded_at and d.recorded_at < coalesce(i.removed_at, 'infinity')
                                   limit 1) i on true
                    join lateral (select c.* from public.vehicle_tank_configurations c
                                   where c.vehicle_tank_id = i.vehicle_tank_id and c.superseded_at is null
                                     and c.effective_from <= d.recorded_at
                                   order by c.effective_from desc limit 1) c on true
                   where d.recorded_at > now() - interval '24 hours' and d.distance_meters > 0) pr
           group by pr.tank_sensor_id) x;

  z := jsonb_build_object(
    'Z1', (select count(*) from (
             select s.id from public.tank_sensors s
              where exists (select 1 from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
                             where i.tank_sensor_id = s.id and i.superseded_at is null and vt.deleted_at is null
                               and i.installed_at <= now() and now() < coalesce(i.removed_at, 'infinity'))
                and ((select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor'
                        and e.entity_id = s.id and e.source_system = 'samsara') <> 1
                  or (select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor'
                        and e.entity_id = s.id and e.source_system = 'samsara_gateway') <> 1)
             union all
             select e.id from public.entity_source_links e
              where e.entity_type = 'tank_sensor' and not exists (select 1 from public.tank_sensors s where s.id = e.entity_id)) x),
    'Z2', (select count(*) from public.vehicle_stops s
             join public.vehicle_tanks vt on vt.vehicle_id = s.vehicle_id and vt.deleted_at is null
            where s.superseded_at is null and s.departed_at + interval '4 hours' < now()
              and exists (select 1 from public.tank_sensor_installations i where i.vehicle_tank_id = vt.id and i.superseded_at is null
                            and i.installed_at <= s.arrived_at and s.arrived_at < coalesce(i.removed_at, 'infinity'))
              and exists (select 1 from public.vehicle_tank_configurations c where c.vehicle_tank_id = vt.id
                            and c.superseded_at is null and c.effective_from <= s.arrived_at)
              and not exists (select 1 from public.vehicle_stop_tank_levels l where l.vehicle_stop_id = s.id
                                and l.vehicle_tank_id = vt.id and l.superseded_at is null)),
    'Z3', (select count(*) from public.vehicle_stop_tank_levels l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             join public.vehicle_tanks vt on vt.id = l.vehicle_tank_id
            where l.superseded_at is null
              and (s.superseded_at is not null or vt.deleted_at is not null or l.algorithm_version < 1
                   or l.tank_sensor_installation_id is distinct from (
                        select i.id from public.tank_sensor_installations i where i.vehicle_tank_id = vt.id and i.superseded_at is null
                           and i.installed_at <= s.arrived_at and s.arrived_at < coalesce(i.removed_at, 'infinity')
                         order by i.installed_at desc limit 1)
                   or l.vehicle_tank_configuration_id is distinct from (
                        select c.id from public.vehicle_tank_configurations c where c.vehicle_tank_id = vt.id
                           and c.superseded_at is null and c.effective_from <= s.arrived_at
                         order by c.effective_from desc limit 1))),
    'Z4', (select count(*) from public.visit_vehicle_stops l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             left join public.v_visits_live vl on vl.id = l.visit_id
             left join public.properties vp on vp.id = vl.property_id
             left join public.properties sp on sp.id = s.site_property_id
            where l.deleted_at is null
              and (s.superseded_at is not null or vl.id is null or vl.visit_status <> 'completed'
                   or vl.vehicle_id is distinct from s.vehicle_id
                   or (l.match_basis not in ('dump_completion','dump_window')
                       and (s.site_property_id is not null or vp.latitude is null
                            or ops.fn_haversine_km(vp.latitude, vp.longitude, s.latitude, s.longitude) * 1000
                               > case when l.match_basis in ('completion', 'completion_chain') then 250 else 150 end))
                   or (l.match_basis in ('dump_completion','dump_window')
                       and (not public.fn_is_non_customer(vl.client_id, array['dump_site'])
                            or sp.client_id is distinct from vl.client_id
                            or not exists (select 1 from public.non_customer_clients n
                                            where n.client_id = sp.client_id and n.kind = 'dump_site')))))
        + (select count(*) from public.vehicle_stops s
             join public.properties sp on sp.id = s.site_property_id
            where s.superseded_at is null
              and s.site_property_id is distinct from v_yard
              and not exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site')),
    'Z6', (select count(*) from jsonb_array_elements(coalesce(v_z6, '[]')) x
            where (x->>'pairs')::int >= 20 and (x->>'median_pp')::numeric > 0.5),
    'Z7', (select count(*) from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
            where i.superseded_at is null and i.removed_at is null and vt.deleted_at is not null),
    'Z8', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('derm','customer','client') and p.prosrc ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))
        + (select count(distinct v.oid) from pg_class v join pg_namespace n on n.oid = v.relnamespace
             join pg_rewrite rw on rw.ev_class = v.oid
             join pg_depend dp on dp.objid = rw.oid and dp.classid = 'pg_rewrite'::regclass
             join pg_class t on t.oid = dp.refobjid
             join pg_namespace tn on tn.oid = t.relnamespace
            where n.nspname in ('derm','customer','client') and v.relkind in ('v','m')
              and tn.nspname = 'public' and t.relname ~ ('^(' || v_new_names || ')$')),
    'Z8_control_found', v_z8_control,
    'Z9', (select count(distinct l.visit_id) from public.visit_vehicle_stops l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is not null
             join public.v_visits_live vl on vl.id = l.visit_id and vl.visit_status = 'completed' and vl.vehicle_id = s.vehicle_id
            where l.deleted_at is not null
              and not exists (select 1 from public.visit_vehicle_stops l2 where l2.visit_id = l.visit_id and l2.deleted_at is null)
              and exists (select 1 from public.vehicle_stops s2
                           where s2.superseded_at is null and s2.vehicle_id = s.vehicle_id
                             and ops.fn_haversine_km(s2.latitude, s2.longitude, s.latitude, s.longitude) * 1000 <= 150
                             and s2.arrived_at >= (vl.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
                             and s2.arrived_at < ((vl.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York')),
    'Z6_detail', coalesce(v_z6, '[]'));

  t := jsonb_build_object(
    'T1', (select count(*) from public.tank_sensors s
            where exists (select 1 from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
                           where i.tank_sensor_id = s.id and i.superseded_at is null and vt.deleted_at is null
                             and i.installed_at <= now() and now() < coalesce(i.removed_at, 'infinity'))
              and coalesce((select max(r.recorded_at) from public.tank_sensor_distance_readings r where r.tank_sensor_id = s.id),
                           '-infinity') < now() - interval '2 hours'),
    'T2', (select count(*) from (
             select r.vehicle_id, date_trunc('hour', r.recorded_at) as h
               from public.vehicle_engine_rpm_readings r
              where r.recorded_at > now() - interval '48 hours' and r.engine_rpm > 0
              group by 1, 2 having count(*) >= 5) x
            where x.h + interval '1 hour' <= (select max(g.recorded_at) from public.vehicle_telemetry_readings g
                                                where g.vehicle_id = x.vehicle_id and g.latitude is not null)
              and not exists (select 1 from public.vehicle_telemetry_readings g
                               where g.vehicle_id = x.vehicle_id and g.latitude is not null
                                 and g.recorded_at >= x.h and g.recorded_at < x.h + interval '1 hour')),
    'T3', (select count(*) from (
             select sl.details->'summary'->'unlinked_level_assets' as a from public.sync_log sl
              where sl.sync_source = 'railway_samsara_readings' and sl.status = 'success'
                and sl.details->'summary'->>'deep_pass' = 'true'
              order by sl.started_at desc limit 1) r
             cross join lateral jsonb_array_elements(case when jsonb_typeof(r.a) = 'array' then r.a else '[]' end) el
            where not exists (select 1 from public.entity_source_links e where e.entity_type = 'tank_sensor'
                                and e.source_id = coalesce(el->>'id', el #>> '{}'))),
    'T4', (select count(*) from public.sync_log sl
            where sl.sync_source = 'railway_samsara_readings' and sl.started_at > now() - interval '2 hours'
              and jsonb_typeof(sl.details->'summary'->'skipped_streams') = 'array'
              and jsonb_array_length(sl.details->'summary'->'skipped_streams') > 0),
    'T5', (select case when count(distinct (sl.started_at at time zone 'America/New_York')::date) >= 2 then 1 else 0 end
             from public.sync_log sl
            where sl.sync_source = 'railway_samsara_readings' and sl.status = 'success'
              and sl.started_at > now() - interval '14 days'
              and coalesce((sl.details->'summary'->>'deep_pass_recovered')::numeric, 0) > 0));

  f := jsonb_build_object(
    'F1', (select count(*) from public.v_visits_live vl
            where vl.visit_status = 'completed' and vl.visit_date >= date '2026-08-20' and vl.service_type = 'Pumping'
              and not public.fn_is_non_customer(vl.client_id, array['dump_site'])
              and exists (select 1 from public.entity_source_links e where e.entity_type = 'vehicle'
                            and e.source_system = 'samsara' and e.entity_id = vl.vehicle_id)
              and not exists (select 1 from public.visit_vehicle_stops l where l.visit_id = vl.id and l.deleted_at is null)),
    'F1b', (select count(*) from public.v_visits_live vl
             where vl.visit_status = 'completed' and vl.visit_date >= date '2026-08-20' and vl.vehicle_id is not null
               and public.fn_is_non_customer(vl.client_id, array['dump_site'])
               and not exists (select 1 from public.visit_vehicle_stops l where l.visit_id = vl.id and l.deleted_at is null
                                 and l.match_basis in ('dump_completion','dump_window'))),
    'F3', (select count(*) from public.vehicle_stops s
             join public.properties sp on sp.id = s.site_property_id
             join public.non_customer_clients n on n.client_id = sp.client_id and n.kind = 'dump_site'
            where s.superseded_at is null
              and not exists (select 1 from public.visit_vehicle_stops l where l.vehicle_stop_id = s.id and l.deleted_at is null
                                and l.match_basis in ('dump_completion','dump_window'))),
    'F5', (select count(*) from public.vehicle_stop_tank_levels l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             join public.vehicle_tanks vt on vt.id = l.vehicle_tank_id and vt.contents = 'sludge'
             join public.vehicle_tank_configurations c on c.id = l.vehicle_tank_configuration_id
             left join public.properties sp on sp.id = s.site_property_id
            where l.superseded_at is null and s.superseded_at is null and c.capacity_gallons is not null
              and (l.arrival_fill_fraction - l.departure_fill_fraction) * c.capacity_gallons >= 300
              and not exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site')),
    'F7', (select count(*) from (
             select vl.id, vl.duration_minutes,
                    sum(extract(epoch from s.departed_at - s.arrived_at) / 60) as stop_minutes
               from public.v_visits_live vl
               join public.visit_vehicle_stops l on l.visit_id = vl.id and l.deleted_at is null
               join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
              group by vl.id, vl.duration_minutes) x
            where x.duration_minutes is not null and abs(x.stop_minutes - x.duration_minutes) > 15),
    'F8', (select count(*) from public.vehicles ve
             join public.vehicle_tanks vt on vt.vehicle_id = ve.id and vt.contents = 'sludge' and vt.deleted_at is null
             join lateral (select c.capacity_gallons from public.vehicle_tank_configurations c
                            where c.vehicle_tank_id = vt.id and c.superseded_at is null and c.effective_from <= now()
                            order by c.effective_from desc limit 1) c on true
            where ve.grease_tank_capacity_gallons is distinct from c.capacity_gallons),
    'F2_F4_F6', 'counted by v_tank_data_quality_issues (M6)');

  return jsonb_build_object('integrity', z, 'feed', t, 'flags', f, 'checked_at', now());
end $function$
;


COMMENT ON FUNCTION public.fn_link_visit_vehicle_stops(boolean, integer, integer, text[]) IS 'Links completed visits to their truck stops (whole era, every run; fn_refresh_stop_facts step 3). Algorithm 2 (2026-10-13_2210): the completion stop within 250 m (150 m first), its earlier adjacent stops as completion_chain, window and same_site_earlier at 150 m for tank volumes, dump links; test clients excluded. Dry run returns the changes.';
COMMENT ON FUNCTION public.fn_fill_time_on_site_from_stops(boolean) IS 'Time on site from the completion stop and its chain, split at completion times on a shared stop (pieces of 10 min or more), or from the dump site visit. Fills blanks and replaces the labelled 150 m measurement inside its 10-day window. Writes time_on_site_source stop_at_completion / dump_site_dwell, labelled time-on-site-from-stops. 2026-10-13_2210.';

-- the nightly run: the completion stop first (2026-10-13_2210)
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'time-on-site-nightly'),
  command := 'select public.fn_fill_time_on_site_from_stops(true); select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true)');

-- rebuild the links with algorithm 2, then fill
SELECT set_config('request.headers', '{"x-app-source":"stop-facts"}', true);
SELECT public.fn_link_visit_vehicle_stops(true);
SELECT set_config('request.headers', '', true);
SELECT public.fn_fill_time_on_site_from_stops(true);

DO $v$
DECLARE r record; n int; z jsonb; v_min int;
BEGIN
  -- V1 the visit that started this: 34 min from the stop that holds its completion
  SELECT duration_minutes, actual_arrival_at, actual_departure_at, time_on_site_source INTO r FROM public.visits WHERE id = 6509;
  IF r.duration_minutes IS DISTINCT FROM 34 OR r.time_on_site_source IS DISTINCT FROM 'stop_at_completion'
     OR r.actual_arrival_at IS DISTINCT FROM '2026-09-25 14:29:11+00' OR r.actual_departure_at IS DISTINCT FROM '2026-09-25 15:02:59+00' THEN
    RAISE EXCEPTION 'V1: visit 6509 is %', r; END IF;

  -- V2 link-derived minutes (completion stop departure minus the earliest completion or chain arrival)
  FOR r IN SELECT * FROM (VALUES (6509, 34), (6507, 41), (8139, 54), (8145, 16), (6106, 101), (7843, 61)) t(v, m) LOOP
    SELECT round(extract(epoch from max(s.departed_at) FILTER (WHERE l.match_basis = 'completion') - min(s.arrived_at)) / 60)
      INTO v_min
      FROM public.visit_vehicle_stops l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
     WHERE l.visit_id = r.v AND l.deleted_at IS NULL AND l.match_basis IN ('completion', 'completion_chain');
    IF v_min IS DISTINCT FROM r.m THEN RAISE EXCEPTION 'V2: visit % reads % min from its stops, expected %', r.v, v_min, r.m; END IF;
  END LOOP;
  IF (SELECT count(*) FROM public.visit_vehicle_stops WHERE deleted_at IS NULL AND match_basis = 'completion_chain'
        AND visit_id IN (6507, 8139)) < 2 THEN RAISE EXCEPTION 'V2: 6507 / 8139 carry no completion_chain link'; END IF;

  -- V3 no completion match moved or vanished
  SELECT count(*) INTO n FROM _pre_completion p
   WHERE NOT EXISTS (SELECT 1 FROM public.visit_vehicle_stops l WHERE l.deleted_at IS NULL AND l.match_basis = 'completion'
                       AND l.visit_id = p.visit_id AND l.vehicle_stop_id = p.vehicle_stop_id);
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % completion links moved or vanished', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_vehicle_stops WHERE visit_id = 6296 AND deleted_at IS NULL AND match_basis = 'completion') THEN
    RAISE EXCEPTION 'V3: 6296 (tapped 3 s after the truck left) lost its completion link'; END IF;

  -- V4 integrity
  z := public.fn_stop_facts_checks()->'integrity';
  IF (SELECT count(*) FROM jsonb_each(z) x WHERE x.key IN ('Z1','Z2','Z3','Z4','Z7','Z8','Z9') AND (x.value)::text::int <> 0) > 0
     OR (z->>'Z8_control_found')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'V4: integrity %', z; END IF;

  -- V5 test visits hold no stop
  IF EXISTS (SELECT 1 FROM public.visit_vehicle_stops l JOIN public.visits v ON v.id = l.visit_id
              WHERE l.deleted_at IS NULL AND public.fn_is_non_customer(v.client_id, array['test', 'fixture'])) THEN
    RAISE EXCEPTION 'V5: a test visit holds a stop'; END IF;

  -- V6 only blanks were written, labelled, with a stop source; no truck or sync_state moved
  SELECT count(*) INTO n FROM public.visits v JOIN _pre_visits p ON p.id = v.id
   WHERE (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source)
         IS DISTINCT FROM (p.duration_minutes, p.actual_arrival_at, p.actual_departure_at, p.time_on_site_source)
     AND (p.duration_minutes IS NOT NULL OR v.time_on_site_source NOT IN ('stop_at_completion', 'dump_site_dwell'));
  IF n <> 0 THEN RAISE EXCEPTION 'V6: % saved values were changed', n; END IF;
  SELECT count(*) INTO n FROM public.visits v JOIN _pre_visits p ON p.id = v.id
   WHERE v.duration_minutes IS DISTINCT FROM p.duration_minutes;
  IF n < 7 OR EXISTS (SELECT 1 FROM unnest(array[6509, 6271, 7991, 6505, 6508]) x(id)
                       JOIN public.visits v ON v.id = x.id WHERE v.time_on_site_source IS DISTINCT FROM 'stop_at_completion') THEN
    RAISE EXCEPTION 'V6: only % blanks filled', n; END IF;
  IF (SELECT count(*) FROM audit.logs a WHERE a.table_name = 'visits' AND a.txid = txid_current()
        AND a.app_source = 'time-on-site-from-stops' AND coalesce(a.request_context->>'change_reason', '') <> '') <> n THEN
    RAISE EXCEPTION 'V6: the % fills are not all labelled', n; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v JOIN _pre_visits p ON p.id = v.id
              WHERE v.sync_state IS DISTINCT FROM p.sync_state OR v.vehicle_id IS DISTINCT FROM p.vehicle_id) THEN
    RAISE EXCEPTION 'V6: a sync_state or a truck moved'; END IF;

  -- V7 the 150 m measurement no longer picks a stay that starts after the completion
  PERFORM public.fn_compute_time_on_site(date '2026-08-20', current_date, false);
  IF EXISTS (SELECT 1 FROM _tos_result t JOIN public.visits v ON v.id = t.visit_id
              WHERE t.arrival > v.completed_at + interval '15 minutes') THEN
    RAISE EXCEPTION 'V7: the measurement still picks a stay after the completion'; END IF;

  -- V8 the version guard
  BEGIN
    PERFORM public.fn_link_visit_vehicle_stops(true, 250);
    RAISE EXCEPTION 'V8: the version guard did not fire';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;

  -- V9 the order: the completion stop first, everywhere
  IF (SELECT command FROM cron.job WHERE jobname = 'time-on-site-nightly') NOT LIKE 'select public.fn_fill_time_on_site_from_stops(true);%' THEN
    RAISE EXCEPTION 'V9: cron 26'; END IF;
  IF strpos(pg_get_functiondef('public.fn_request_time_on_site_reminder()'::regprocedure), 'fn_fill_time_on_site_from_stops')
     > strpos(pg_get_functiondef('public.fn_request_time_on_site_reminder()'::regprocedure), 'fn_compute_time_on_site') THEN
    RAISE EXCEPTION 'V9: reminder order'; END IF;
  SELECT pg_get_functiondef(p.oid) AS d INTO r FROM pg_proc p WHERE p.proname = 'viktor_set_visit_truck';
  IF NOT (strpos(r.d, 'fn_link_visit_vehicle_stops(true)') BETWEEN 1 AND strpos(r.d, 'fn_fill_time_on_site_from_stops(true)'))
     OR strpos(r.d, 'fn_fill_time_on_site_from_stops(true)') > strpos(r.d, 'fn_compute_time_on_site(') THEN
    RAISE EXCEPTION 'V9: Viktor order'; END IF;

  -- V10 grants unchanged
  IF (SELECT string_agg(proname || '=' || proacl::text, ' ' ORDER BY proname) FROM pg_proc
       WHERE pronamespace = 'public'::regnamespace AND proname IN ('fn_link_visit_vehicle_stops', 'fn_fill_time_on_site_from_stops',
             'fn_compute_time_on_site', 'fn_stop_facts_checks', 'viktor_set_visit_truck', 'fn_request_time_on_site_reminder'))
     IS DISTINCT FROM 'fn_compute_time_on_site={postgres=X/postgres,service_role=X/postgres} fn_fill_time_on_site_from_stops={postgres=X/postgres,service_role=X/postgres} fn_link_visit_vehicle_stops={postgres=X/postgres} fn_request_time_on_site_reminder={postgres=X/postgres,service_role=X/postgres} fn_stop_facts_checks={postgres=X/postgres} viktor_set_visit_truck={postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'V10: grants moved'; END IF;

  -- V11 the split: a shared stop is split at the completion times only when every piece is 10 min or more
  -- (two visits at one address tapped 3 min apart stay blank; a 69 / 40 min pair is written)
  BEGIN
    UPDATE public.visits SET duration_minutes = null, actual_arrival_at = null, actual_departure_at = null
     WHERE id IN (5936, 6523, 8051, 8052);
    PERFORM public.fn_fill_time_on_site_from_stops(true);
    IF EXISTS (SELECT 1 FROM public.visits WHERE id IN (5936, 6523) AND duration_minutes IS NOT NULL) THEN
      RAISE EXCEPTION 'V11: a stop split into a 3 min piece was written'; END IF;
    IF (SELECT array_agg(duration_minutes ORDER BY id) FROM public.visits WHERE id IN (8051, 8052)) IS DISTINCT FROM array[69, 40] THEN
      RAISE EXCEPTION 'V11: the shared stop split as %',
        (SELECT array_agg(duration_minutes ORDER BY id) FROM public.visits WHERE id IN (8051, 8052)); END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;
END $v$;

COMMIT;
