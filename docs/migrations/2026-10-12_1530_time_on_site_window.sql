-- ============================================================================
-- 2026-10-12_1530 - time on site: the overnight window ends 10:00 ET next morning (plan step M8)
-- APPLIED to Prod 2026-10-12 ~18:20 ET (69 rows backfilled from 2026-08-01, as measured); webhook-samsara v40 deployed with it.
-- ============================================================================
-- WHAT. public.fn_compute_time_on_site reads the truck's GPS from 20:00 ET the evening before
-- visit_date to 04:00 ET the morning after (-4 h / +28 h). The end moves to 10:00 ET the morning
-- after, with one guard: when the same truck has a completed, live visit at the same property
-- dated visit_date + 1, the old 04:00 ET end stays (that morning belongs to the next visit).
-- It still writes only visits.actual_arrival_at, actual_departure_at and duration_minutes
-- (never is_gps_confirmed), and still never clears a value.
--
-- WHY. Owner reply, 2026-10-12, to "Extend the time-on-site window to 10:00 ET the next morning,
-- so late-night routes stop coming out blank": Fred, "Extend it, Good." (The ask came out of his
-- voice note of the same day on the Samsara tank sensors: "how long they stayed on that client".)
-- The discovery found 9 Pumping visits finished the next morning, 05:39 to 08:32 ET, 9 to 62 m
-- from the property, that the database left blank (docs/reference/samsara-tank-sensors-2026-10-12.md
-- 1.2). Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md, N2, D4, M8.
-- The same owner decision neutralises the dormant visit writer in webhook-samsara
-- (handleGeofenceAlert), a separate code change that ships with this file.
--
-- REPLACED BODY. Live pg_get_functiondef read 2026-10-12, md5 979731d3518671fe0c5d1f51c53f4067
-- (step 0 refuses to run if it moved). The body below is that text with two anchors edited by a
-- script, each asserted to match exactly once; new md5 c5b552f43f802c401257e100e65ef833. Diff:
--   target CTE  + next_day_same_site = exists(same vehicle_id, same property_id,
--                 visit_date + 1, visit_status 'completed', deleted_at is null)
--   pings CTE   upper bound  +28 h  ->  case when next_day_same_site then +28 h
--                                       else ((visit_date + 1) + 10:00) at time zone ET end
-- 10:00 is written as wall-clock time, so a DST night still ends at 10:00 ET (a fixed +34 h would
-- not). Every other byte is unchanged: grants, SECURITY DEFINER and search_path '' are kept by
-- CREATE OR REPLACE and asserted in VERIFY.
--
-- CALLERS, measured 2026-10-12. One: pg_cron job 26 'time-on-site-nightly', '20 7 * * *' (03:20 EDT),
-- select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true). No function,
-- view or edge function calls it. A night still in progress at 03:20 ET is completed by the next
-- night's run (10-day lookback), as today.
-- READERS of the three columns: public.v_visits_live, visits_with_status, visits_with_review,
-- visits_recent, v_visit_shared_time; client.visits, client.v_visits_live; ops.visits,
-- ops.v_calendar_visit, ops.v_route_today. Apps: Visit Calendar (hover card, drawer, and the day-header
-- "clock" figure, which sums ops.v_calendar_visit.duration_minutes = measured if present, else scheduled,
-- excluding values of 720 or more, so it moves for every newly resolved or extended visit), Admin Review
-- (Time on site, shared-time icon), Client App.
-- APP DOCS ARE STILL PENDING (not written with this staged file): Visit Calendar, Admin Review and Client
-- App 08-changelog.md entries with the step-4 numbers below (2026-08-01 onward), and Admin Review
-- docs/09-known-issues.md row b, which still names webhook-samsara handleGeofenceAlert as the writer.
-- Write them in the apply cycle (root CLAUDE.md 4b).
-- Triggers on the write: audit_visits, set_updated_at, the statement broadcast. Neither the
-- sync_pending trigger nor the Jobber push trigger lists these columns: nothing goes to Jobber.
--
-- DRY RUN, rolled back, 2026-10-12, with the old live body as control in the same transaction:
--   visit_date 2026-08-01 .. 2026-10-12: 445 considered | old 365 resolved | new 406 (+41) | lost 0
--     41 newly resolved: all Pumping, all on vehicle 1, all leaving after 04:00 ET next day;
--        37 have the driver's completion inside the stay (or within 15 min after it).
--     23 changed: every one had its stay cut at 03:52 to 03:59 by the old 04:00 end; for 18 the
--        new departure is within 15 min of the completion. No visit got shorter.
--     10 new overlapping pairs (same truck):
--        5 same-night neighbours 15 to 106 m apart (the accepted shared stop, 2026-08-19_0410);
--        2 touch at one ping (2 min or less);
--        2 a next-day visit at a DIFFERENT property (98 m and 176 m away) already held the stop
--          under the old body; the new value belongs to the overnight visit (completion inside);
--        1 real overlap: visit 6412 now reads 03:48 to 07:35 (226 min) and covers visit 6106's
--          stop at a property 258 m away; 6412 was completed at 05:40, so 226 min overstates it.
--     The guard: 20 visits have a next-day same-site visit; it changes the answer for 7 (emulated with
--        and without it). Right for 4: 7770, 7796, 8170, 8176 (completed on their own day or evening,
--        so the morning stop is the next-day visit's). Wrong for 3: 8013, 8051, 8175 stay blank or cut
--        at 04:00 although their completion is inside the morning stop (the next-day visit is all-day,
--        office-completed, or Labor/Parts work).
--     Ceiling: 2 newly resolved stays end at 09:59 (visits 5900, 6975), cut by the new 10:00 end.
--   visit_date 2026-01-01 .. 2026-07-31 (measured, NOT backfilled, see step 4): old 816 | new 867 (+51) |
--     changed 80 | lost 0 | shorter 0. But 20 of the 80 move to a DIFFERENT stop, and 6 are wrong after the
--     change: the old stay held the completion and the new one does not (1322, 1345, 1347, 1348, 1538,
--     1741). The guard there is wrong for 1355, 1495, 1497 and right for 1507. 10 new same-truck overlap
--     pairs appear and 7 go away.
--   KNOWN LIMITATION (open with Fred, also affects nightly runs): the stay picked is the LONGEST cluster
--     ("distinct on (id) ... order by minutes desc"). A longer next-morning stop at a NEIGHBOURING property
--     (within 150 m) can now beat the visit's own stay that holds its completion; the guard only covers the
--     same truck at the same property. Properties 106, 48, 58, 86, 126 and 201 sit 30 to 138 m apart and
--     are served as one block (01-27, 02-03, 08-24); 4 of the 6 Jan-Jul regressions are that block. The
--     August window has no such case, but the nightly 10-day lookback can produce one. Options: prefer the
--     cluster containing completed_at (when completed_at is within 24 h of visit_date) before the longest;
--     or link visits to stops from visit_vehicle_stops (plan M4/M5). Same "measures the truck" family as 6412.
--   Spot checks against raw GPS (vehicle_telemetry_readings), visits 6619, 7866, 6773: entry ping
--   156 to 198 m out, 255 to 565 pings inside (median 21 to 36 m from the property, no gap over
--   3 min), exit ping 157 to 167 m out, completion 0 to 2 min before departure.
--
-- BACKFILL (step 4). The nightly job only re-reads 10 days, so step 4 re-runs the function from
-- 2026-08-01, the range characterised above, and NOT over all of 2026: before August the wider window
-- moves 20 visits to another stop and makes 6 wrong (see the dry run). Measured: 69 rows differ from what
-- is stored in 08-01 .. 10-12 (rolled-back run of this whole file, 2026-10-12: 69 expected, 69 written, 0
-- before 08-01, 0 still differing). 6 visits since 08-01 already differ from what the CURRENT body computes
-- (stored values gone stale); they are rewritten too. Delete step 4 for forward-only; nothing else depends on it.
--
-- VERIFY. Step 1 keeps the OLD body's answer over all of 2026 (dry run) as the control. Step 3, all
--   dry runs: nothing written; no visit the old body resolved is blank now and none is shorter;
--   more visits resolve; NO REGRESSION in the backfill range: no visit dated 2026-08-01 or later whose
--   old stay held its completed_at (within 15 min) gets a new stay that does not (must be 0);
--   POSITIVE CONTROL for that check: over 01-01 .. 07-31, where the regressions are known, it finds
--   visit 1322 (so a 0 above is a measurement, not a blind instrument);
--   POSITIVE CONTROL (window): visit 6619, a route that ended 07:08 ET next morning, resolves after
--   04:00 ET; POSITIVE CONTROL (guard): visit 7770 keeps its own-day stay, which, with the window
--   proven wider, only the guard can do (unguarded it takes the next-day visit's 06:33 ET stop);
--   ACL, SECURITY DEFINER and search_path unchanged; the stored body has the edited md5. Step 4
--   (from 2026-08-01): the rows written equal the rows that differed (count via updated_at = now(),
--   the trigger's transaction time), nothing differs afterwards, and nothing before 08-01 was written.
--
-- ROLLBACK. The old body is at the bottom of this file, commented. Remove the leading "-- " from
-- each line between the markers: the text has md5 979731d3518671fe0c5d1f51c53f4067; append ";" and
-- run it. Re-running the old body does NOT restore backfilled values (it never clears a value);
-- restore those from audit.logs old_row for public.visits rows written by this transaction.
--
-- AUDIT (rule 8): no table, column or trigger created or altered. public.visits is audited, so
-- every backfilled row carries old_row/new_row. 3NF: no column added.
-- ============================================================================

begin;
set local lock_timeout = '3s';

-- 0. PIN: refuse if the live body moved since it was copied.
do $pin$
declare v_md5 text := md5(pg_get_functiondef(
  'public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure));
begin
  if v_md5 <> '979731d3518671fe0c5d1f51c53f4067' then
    raise exception 'fn_compute_time_on_site changed since 2026-10-12 (md5 %): re-copy the live body', v_md5;
  end if;
end
$pin$;

-- 1. CONTROL: the old body's answer over all of 2026 (dry run), kept for VERIFY.
select * from public.fn_compute_time_on_site('2026-01-01', current_date + 1, false);
create temp table _m8_old on commit drop as select * from _tos_result;

-- 2. THE CHANGE (live body, two anchors edited).
CREATE OR REPLACE FUNCTION public.fn_compute_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3)
 RETURNS TABLE(visits_considered integer, visits_resolved integer, visits_blank integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_considered integer := 0;
  v_resolved   integer := 0;
begin
  -- 🛑 DROP FIRST. `on commit drop` fires at COMMIT, not at return, so two calls inside one
  -- transaction (which is exactly what the VERIFY block below does) hit 42P07 on the second.
  drop table if exists _tos_result;

  create temp table _tos_result on commit drop as
  with target as (
    select v.id, v.vehicle_id, v.visit_date,
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
   order by id, minutes desc;

  select count(*) into v_considered
    from public.visits v
    join public.properties p on p.id = v.property_id
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.vehicle_id is not null and p.latitude is not null;

  select count(*) into v_resolved from _tos_result;

  if p_execute then
    update public.visits v
       set actual_arrival_at   = r.arrival,
           actual_departure_at = r.departure,
           duration_minutes    = r.minutes
      from _tos_result r
     where v.id = r.visit_id
       and (v.actual_arrival_at   is distinct from r.arrival
         or v.actual_departure_at is distinct from r.departure
         or v.duration_minutes    is distinct from r.minutes);
  end if;

  visits_considered := v_considered;
  visits_resolved   := v_resolved;
  visits_blank      := v_considered - v_resolved;
  return next;
end
$function$;

-- 3. VERIFY (dry run, old body as control).
do $verify$
declare
  r     record;
  n     integer;
  fail  text := '';
  f     record;
begin
  select * into r from public.fn_compute_time_on_site('2026-01-01', current_date + 1, false);

  if exists (select 1 from public.visits where updated_at = now()) then
    fail := fail || 'the dry run wrote visits; ';
  end if;

  select count(*) into n from _m8_old o
   where not exists (select 1 from _tos_result t where t.visit_id = o.visit_id);
  if n > 0 then fail := fail || format('%s visits the old body resolved are blank now; ', n); end if;

  select count(*) into n from _m8_old o join _tos_result t using (visit_id) where t.minutes < o.minutes;
  if n > 0 then fail := fail || format('%s visits got shorter; ', n); end if;

  if r.visits_resolved <= (select count(*) from _m8_old) then
    fail := fail || format('the window did not widen: %s resolved, old %s; ', r.visits_resolved, (select count(*) from _m8_old));
  end if;

  -- POSITIVE CONTROL, window: a route that ended 07:08 ET next morning now resolves past 04:00 ET.
  if not exists (select 1 from _tos_result t join public.visits v on v.id = t.visit_id
                  where t.visit_id = 6619
                    and t.departure > (v.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours') then
    fail := fail || 'visit 6619 did not resolve past 04:00 ET; ';
  end if;

  -- POSITIVE CONTROL, guard: with the window proven wider, only the guard keeps 7770 on its own day.
  if not exists (select 1 from _tos_result t
                  where t.visit_id = 7770 and t.departure < timestamptz '2026-08-18 04:00:00-04') then
    fail := fail || 'visit 7770 lost its own-day stay: the next-day guard does not bite; ';
  end if;

  -- NO REGRESSION in the backfill range: the old stay held completed_at (15 min slack), the new one does not.
  create temp table _m8_regress on commit drop as
    select v.id, v.visit_date
      from _m8_old o
      join public.visits v on v.id = o.visit_id
      left join _tos_result t on t.visit_id = o.visit_id
     where v.completed_at between o.arrival - interval '15 minutes' and o.departure + interval '15 minutes'
       and (t.visit_id is null
            or v.completed_at not between t.arrival - interval '15 minutes' and t.departure + interval '15 minutes');
  select count(*) into n from _m8_regress where visit_date >= date '2026-08-01';
  if n > 0 then
    fail := fail || format('%s visits from 2026-08-01 lose the stay that held their completion (%s); ', n,
      (select string_agg(id::text, ',' order by id) from _m8_regress where visit_date >= date '2026-08-01'));
  end if;
  -- POSITIVE CONTROL for that check: before August the regressions are known (1322, 1345, 1347, 1348, 1538, 1741).
  if not exists (select 1 from _m8_regress where id = 1322 and visit_date < date '2026-08-01') then
    fail := fail || 'the regression check did not find visit 1322 before August: the instrument is blind; ';
  end if;

  select pr.proacl::text as acl, pr.prosecdef as definer, pr.proconfig = array['search_path=""'] as cfg_ok into f
    from pg_proc pr where pr.oid = 'public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure;
  if f.acl <> '{postgres=X/postgres,service_role=X/postgres}' or not f.definer or not f.cfg_ok then
    fail := fail || format('privileges moved: acl %s, definer %s, search_path pinned %s; ', f.acl, f.definer, f.cfg_ok);
  end if;

  -- the stored body is the edited copy, byte for byte (header claim)
  if md5(pg_get_functiondef('public.fn_compute_time_on_site(date,date,boolean,integer,integer,integer)'::regprocedure))
     <> 'c5b552f43f802c401257e100e65ef833' then
    fail := fail || 'the stored body is not the edited copy (md5); ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'M8 verified: % resolved of % (old body %), none lost, none shorter, both controls hold',
    r.visits_resolved, r.visits_considered, (select count(*) from _m8_old);
end
$verify$;

-- 4. BACKFILL FROM 2026-08-01 (the characterised range; delete this step for forward-only).
create temp table _m8_expect on commit drop as
  select count(*)::integer as n
    from _tos_result t join public.visits v on v.id = t.visit_id
   where v.visit_date >= date '2026-08-01'
     and (t.arrival, t.departure, t.minutes)
         is distinct from (v.actual_arrival_at, v.actual_departure_at, v.duration_minutes);

select * from public.fn_compute_time_on_site('2026-08-01', current_date + 1, true);

do $after$
declare
  n_written integer;
  n_expect  integer := (select n from _m8_expect);
  n_diff    integer;
begin
  select count(*) into n_written from public.visits where updated_at = now();
  if exists (select 1 from public.visits where updated_at = now() and visit_date < date '2026-08-01') then
    raise exception 'backfill wrote a visit dated before 2026-08-01';
  end if;
  select count(*) into n_diff
    from _tos_result t join public.visits v on v.id = t.visit_id
   where (t.arrival, t.departure, t.minutes)
         is distinct from (v.actual_arrival_at, v.actual_departure_at, v.duration_minutes);
  if n_expect = 0 then raise exception 'backfill had nothing to write: the window or the instrument is wrong'; end if;
  if n_written <> n_expect then raise exception 'backfill wrote % rows, expected %', n_written, n_expect; end if;
  if n_diff <> 0 then raise exception '% visits still differ after the backfill', n_diff; end if;
  raise notice 'M8 backfill: % visits written', n_written;
end
$after$;

commit;

-- ============================================================================
-- ROLLBACK: the replaced body, verbatim (pg_get_functiondef, md5 979731d3518671fe0c5d1f51c53f4067).
-- ---- BEGIN OLD BODY ----
-- CREATE OR REPLACE FUNCTION public.fn_compute_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3)
--  RETURNS TABLE(visits_considered integer, visits_resolved integer, visits_blank integer)
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO ''
-- AS $function$
-- declare
--   v_considered integer := 0;
--   v_resolved   integer := 0;
-- begin
--   -- 🛑 DROP FIRST. `on commit drop` fires at COMMIT, not at return, so two calls inside one
--   -- transaction (which is exactly what the VERIFY block below does) hit 42P07 on the second.
--   drop table if exists _tos_result;
-- 
--   create temp table _tos_result on commit drop as
--   with target as (
--     select v.id, v.vehicle_id, v.visit_date,
--            p.latitude::float8  as plat,
--            p.longitude::float8 as plon
--       from public.visits v
--       join public.properties p on p.id = v.property_id
--      where v.visit_status = 'completed'
--        and v.deleted_at is null
--        and v.visit_date >= p_from and v.visit_date < p_to
--        and v.vehicle_id is not null
--        and p.latitude is not null and p.longitude is not null
--   ),
--   pings as (
--     select t.id, r.recorded_at
--       from target t
--       join public.vehicle_telemetry_readings r
--         on r.vehicle_id = t.vehicle_id
--        -- the whole ET operating day plus the overnight tail
--        and r.recorded_at >= (t.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
--        and r.recorded_at <  (t.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
--      where sqrt(power((r.latitude  - t.plat) * 111320, 2) +
--                 power((r.longitude - t.plon) * 111320 * cos(radians(t.plat)), 2)) <= p_radius_m
--   ),
--   marked as (
--     select id, recorded_at,
--            case when lag(recorded_at) over (partition by id order by recorded_at) is null
--                   or recorded_at - lag(recorded_at) over (partition by id order by recorded_at)
--                      > make_interval(mins => p_gap_minutes)
--                 then 1 else 0 end as new_cluster
--       from pings
--   ),
--   clustered as (
--     select id, recorded_at,
--            sum(new_cluster) over (partition by id order by recorded_at) as cluster_no
--       from marked
--   ),
--   spans as (
--     select id, cluster_no, min(recorded_at) as arrival, max(recorded_at) as departure,
--            extract(epoch from (max(recorded_at) - min(recorded_at)))/60 as minutes
--       from clustered
--      group by id, cluster_no
--   )
--   select distinct on (id) id as visit_id, arrival, departure, round(minutes)::integer as minutes
--     from spans
--    where minutes >= p_min_minutes
--    order by id, minutes desc;
-- 
--   select count(*) into v_considered
--     from public.visits v
--     join public.properties p on p.id = v.property_id
--    where v.visit_status = 'completed' and v.deleted_at is null
--      and v.visit_date >= p_from and v.visit_date < p_to
--      and v.vehicle_id is not null and p.latitude is not null;
-- 
--   select count(*) into v_resolved from _tos_result;
-- 
--   if p_execute then
--     update public.visits v
--        set actual_arrival_at   = r.arrival,
--            actual_departure_at = r.departure,
--            duration_minutes    = r.minutes
--       from _tos_result r
--      where v.id = r.visit_id
--        and (v.actual_arrival_at   is distinct from r.arrival
--          or v.actual_departure_at is distinct from r.departure
--          or v.duration_minutes    is distinct from r.minutes);
--   end if;
-- 
--   visits_considered := v_considered;
--   visits_resolved   := v_resolved;
--   visits_blank      := v_considered - v_resolved;
--   return next;
-- end
-- $function$
-- 
-- ---- END OLD BODY ----
