-- ============================================================================
-- 2026-10-15_1950 Tank sensor pipeline v3 (ghost readings, stale edges, the change after leaving) + water balance
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15: "go ahead with the sensor fix and water balance", on the design note
--   docs/superpowers/specs/2026-10-15-moises-water-balance-design.md (four read-only investigations of the Moises
--   sensors, each re-measured by an adversarial reviewer). His model: water at the start + water separated from the
--   sludge = the peak; the peak - water put back into the client's trap = the end. His answers: refills "usually at the
--   office"; at the dump "we only dump the grease"; full or no-separation visits still count; and "after leaving the
--   geofencing of the client it might have a change in the water and sludge level".
--
-- WHAT WAS WRONG (fn_measure_vehicle_stop_tank_levels v2, measured)
--   1. Ghost readings were accepted: the water sensor's 1.14 m echo (about 765 gal) passes the spike rule whenever the
--      level is moving (6619: water separated 712.5 instead of 491.9); the 1.71-1.73 m near-empty sludge echo was an
--      edge (6569 read 956.9, 8134 -265.4, 5901's arrival); 14 live rows had a ghost as an edge.
--   2. An arrival edge could come from before another stop: 082-TFC (stop 1246, visit 6218) took its water arrival at
--      an earlier visit to the same place, across 182-PAL's whole stop, so PAL's 605 / 792 gal counted twice.
--   3. A real reading between two echoes was rejected as a spike (its neighbours were the echoes): 8134's true empty,
--      5901's empties after its dump, 6975's water arrival.
--   4. Nothing was read after the truck left: when pumping ends in the last minutes, the first reading that shows it is
--      the one taken just after leaving (233-AH, visit 7029: about 207 gal pumped, read 0; 7872: 273 gal read 0).
--
-- WHAT CHANGES
--   A. public.fn_tank_ghost_distance_listed (the list per tank contents: water 1.13-1.15 m and 2.40 m or more; sludge
--      1.35 m and 1.71-1.73 m) and public.fn_tank_reading_ghosts (a listed distance more than 15 cm outside its real
--      neighbours within 24 h of the end of their hold; only the ARRIVAL at a dump or yard stop is a barrier, so a
--      post-offload level takes its later neighbour). The sludge false FULL (0.11 m or less) is deliberately NOT
--      listed: a full truck reads the same, and listing it rejected real full levels at dump 1249 and visit 6737.
--   B. TRANSACTION 1: vehicle_stop_tank_levels gains peak_fill_fraction, low_fill_fraction, departure_basis,
--      late_change_fill_fraction, late_change_measured_at, ghost_measurement_count (nullable; older rows keep NULL).
--   C. fn_measure_vehicle_stop_tank_levels v3 (live body spliced at exact anchors, scratchpad v3/build_v3.py):
--      3b ghosts rejected (code 3), matched on the interval so the first row of a window is caught; a ghost ends the
--         hold of the previous value;
--      4  the spike rule compares with the nearest measurements that are not ghosts;
--      5  a false empty is real when first seen inside a dump or yard stop that ended after the last level, or within
--         two periods after it (the v2 arm, an empty followed by a dump before the level recovers, stays dumps-only);
--      6a a parked arrival reading is stale when a later accepted reading before arrival differs by more than the
--         hysteresis (client stops);
--      6b/7a no parked edge on a client stop of 10 min or more (or stale): the level the sensor reported at arrival
--         (after the previous stop's departure, or held through the drive), else the first inside the stop; departure:
--         the last accepted level in the stop, never before the arrival edge (7 too);
--      7b the first accepted reading after leaving (within one period, before the next stop): a change over 100 gal
--         sludge / 60 gal water that does not come back within 50 / 30 gal at the next reading is recorded as
--         late_change; it becomes the departure level only when confirmed (under 400 gal, a full period before the
--         next stop for sludge, the readings up to one period into the next stop within 50 / 30 gal, ghosts skipped);
--      9b peak and low between the edges. c_version 3, so every live v2 row is re-measured.
--      fn_stop_facts_checks: Z8 also watches the new objects; flags gain F9.
--   D. Columns appended (nothing else changed): v_vehicle_stop_tank_changes (peak, low, departure_basis, late change,
--      ghost count); v_visit_tank_service (water start / peak / end, the change after leaving, departure_after_leaving,
--      ghost_readings_removed; same stops as its sludge and water figures); v_tank_data_quality_issues arm F9 (a
--      distance that repeats as a one-reading jump but is not listed: a remount needs a new list).
--   E. public.v_visit_water_balance (Fred's model per visit, water_balance_closes / water_unexplained_gallons) and
--      public.v_vehicle_water_ledger (every stop: separated / put back at a client, refilled / pumped out at the yard,
--      pumped out at a dump). Service role only.
--
-- MEASURED (rolled-back rehearsal 2026-10-15 ~19:35 ET, every VERIFY passed; 558 rows re-measured in about 3 s)
--   visit  sludge before > after (reason)                 water separated / put back before > after
--   5901   2746.2 > 3286.8 (empty arrival after its dump)  unchanged 1234.6 / 1221.5
--   6569    956.9 > 1438.4 (yard echo arrival)
--   7029      0.0 >  206.9 pumped_no_rise > ok (after leaving)    0 / 563.4 > 0 / 113.7 (its arrival was the ghost)
--   7872      0.0 >  273.2 pumped_no_rise > ok (after leaving)
--   8134   -265.4 >  256.9 (true empty arrival; trap size unknown)
--   8085   -507.8 >   32.8 (echo arrival after a dump)
--   6041    190.3 >   66.5 exceeds_trap_size > below_resolution (a ghost departure, corrected after leaving)
--   6270 517.2 > 497.2; 6449 20.7 > 41.4; 6419 unchanged 796.1 (its yard-offload arrival is real: kept)
--   6619                                                   712.5 / 489.9 > 491.9 / 269.3
--   6975                                                   1911.9 / 1646.1 > 1617.5 / 1347.3 (closes exactly)
--   6218 (082-TFC)                                         605.0 / 791.8 > 0 / 0 (182-PAL's water counted once)
--   5922                                                   put back 490.9 > 748.5 (the change after leaving)
--   5936, 6523 (one shared stop)                           263.0 / 346.5 > 0 / 83.5 each; 8741 691.1 / 526.8 > 164.2 / 0
--   Dumps: 2 offloads grow, both a near-empty echo departure replaced by the empty tank (1130 2515.2 > 2977.4,
--   1253 1000.2 > 1589.8, 5901's dump); every other dump unchanged. Ghost edges 14 > 0. Integrity Z1-Z9 and T1-T6
--   unchanged. The change after leaving: 9 stops record one, 4 applied (955 7872, 1226 6041, 1238 water 5922,
--   1239 7029), 5 kept as flags. Water balance: 53 visits, every single-stop pumping visit closes; 4 do not, all
--   split or shared (5922, 5936, 6523, 6218).
--   Calendar (live, every scheduled visit with an effective truck, 792 rows): 22 estimates move, all measured
--   averages or trap size > measured; 10 client averages change. 6570 1182 > 1342 (and its later visits),
--   7874 453 > 363 (and later), 233-AH 7030 trap size 300 > measured 207 (7029 counts for the first time),
--   010-CS 5902 2746 > 3287, 6852 367 > 357. Frozen days do not move.
--
-- KNOWN LIMITS
--   - A fallback edge (6b/7a) and an after-leaving departure may be readings taken moving; they are used only when no
--     parked reading exists or the readings that follow confirm them.
--   - The near-empty echo read right after an offload sits between the full and the empty level and is not caught
--     when no empty follows it in the same stretch (dump 1091 keeps a departure about 540 gal high).
--   - A visit split by another client's stop (6218) or sharing its stop does not close start + separated - put back
--     = end; the ledger does.
--   - fn_tank_reading_ghosts reads the whole sensor history once per run (about 0.3 s today); window it to the run's
--     pairs before more sensors are installed.
--   - Transaction 2 locks the three replaced views only from the view step to COMMIT (about 0.5 s in the rehearsal):
--     the re-measure and the heavy checks run before it. Applied in the evening.
-- Rule 8: no new table; vehicle_stop_tank_levels stays a derived append-only table (audit opt-out, 2026-10-12_2200).
-- ROLLBACK: docs/migrations/2026-10-15_rollback_tank_pipeline_v3.sql (the v2 rules as version 4, re-measured; it was
--   rehearsed on top of this migration: every version 4 row equals its last v2 row).
-- ============================================================================

-- ===============================================================================================================
-- TRANSACTION 1 (milliseconds): the six columns. Committed on its own so the table's ACCESS EXCLUSIVE lock is not
-- held through the re-measure. If transaction 2 then fails, these nullable columns stay and change nothing (v2
-- writes explicit column lists); re-running this file is safe (IF NOT EXISTS).
-- ===============================================================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
-- the hourly refresh (cron vehicle-stop-facts, :35) measures under this lock: never interleave with it
SELECT pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure)) IS DISTINCT FROM '8bcd5f76ff3c9f9d295dc66da63ce412'
     OR md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) IS DISTINCT FROM '893fa0d2d60d3a895c5e0d67021a8290'
     OR md5(pg_get_viewdef('public.v_vehicle_stop_tank_changes'::regclass)) IS DISTINCT FROM 'e28f5bf8f27433d26d4e20e8e260cad6'
     OR md5(pg_get_viewdef('public.v_visit_tank_service'::regclass)) IS DISTINCT FROM '5703fa4c23bbf076198014040333a0f2'
     OR md5(pg_get_viewdef('public.v_tank_data_quality_issues'::regclass)) IS DISTINCT FROM '8baceaa2b7707d9ecd62cfebba026bd5' THEN
    RAISE EXCEPTION 'a body changed since this file was written: splice again';
  END IF;
END $g$;

-- ---------------------------------------------------------------------------------------------------------------
-- B. Five facts per stop and tank, written by the measure (append-only table: supersede + insert, never an update)
-- ---------------------------------------------------------------------------------------------------------------
ALTER TABLE public.vehicle_stop_tank_levels
  ADD COLUMN IF NOT EXISTS peak_fill_fraction numeric,
  ADD COLUMN IF NOT EXISTS low_fill_fraction numeric,
  ADD COLUMN IF NOT EXISTS departure_basis text CONSTRAINT vehicle_stop_tank_levels_departure_basis_chk
    CHECK (departure_basis IN ('at_stop', 'after_leaving')),
  ADD COLUMN IF NOT EXISTS late_change_fill_fraction numeric,
  ADD COLUMN IF NOT EXISTS late_change_measured_at timestamptz,
  ADD COLUMN IF NOT EXISTS ghost_measurement_count smallint;
COMMENT ON COLUMN public.vehicle_stop_tank_levels.peak_fill_fraction IS 'v3: highest accepted level between the edges (the water peak of Fred''s model).';
COMMENT ON COLUMN public.vehicle_stop_tank_levels.low_fill_fraction IS 'v3: lowest accepted level between the edges.';
COMMENT ON COLUMN public.vehicle_stop_tank_levels.departure_basis IS 'v3: at_stop = the departure level was read at the stop; after_leaving = the first reading after leaving, confirmed by the readings that follow (the end of the visit''s pumping showed only after the truck left). NULL on dump and yard stops, on rows with no departure level, and on rows older than v3.';
COMMENT ON COLUMN public.vehicle_stop_tank_levels.late_change_fill_fraction IS 'v3: change from the level read at the stop to the first reading after leaving, when over 100 gal (sludge) / 60 gal (water) and the next reading does not come back within 50 / 30 gal of the stop''s level; recorded whether or not it was applied (departure_basis says). Client stops only.';
COMMENT ON COLUMN public.vehicle_stop_tank_levels.late_change_measured_at IS 'v3: first-seen time of that reading after leaving.';
COMMENT ON COLUMN public.vehicle_stop_tank_levels.ghost_measurement_count IS 'v3: ghost readings rejected between the edges (fn_tank_reading_ghosts); included in rejected_measurement_count.';

COMMIT;

-- ===============================================================================================================
-- TRANSACTION 2: functions, re-measure, data checks, then the views and their checks
-- ===============================================================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
-- the hourly refresh (cron vehicle-stop-facts, :35) measures under this lock: never interleave with it
SELECT pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure)) IS DISTINCT FROM '8bcd5f76ff3c9f9d295dc66da63ce412'
     OR md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) IS DISTINCT FROM '893fa0d2d60d3a895c5e0d67021a8290'
     OR md5(pg_get_viewdef('public.v_vehicle_stop_tank_changes'::regclass)) IS DISTINCT FROM 'e28f5bf8f27433d26d4e20e8e260cad6'
     OR md5(pg_get_viewdef('public.v_visit_tank_service'::regclass)) IS DISTINCT FROM '5703fa4c23bbf076198014040333a0f2'
     OR md5(pg_get_viewdef('public.v_tank_data_quality_issues'::regclass)) IS DISTINCT FROM '8baceaa2b7707d9ecd62cfebba026bd5' THEN
    RAISE EXCEPTION 'a body changed since this file was written: splice again';
  END IF;
END $g$;

-- before, to compare inside VERIFY
CREATE TEMP TABLE clk ON COMMIT DROP AS SELECT 'start'::text AS k, clock_timestamp() AS t;
CREATE TEMP TABLE svc_before ON COMMIT DROP AS SELECT * FROM public.v_visit_tank_service WHERE vehicle_id = 1;
CREATE TEMP TABLE dump_before ON COMMIT DROP AS SELECT * FROM public.v_vehicle_dumps WHERE vehicle_id = 1;
CREATE TEMP TABLE lvl_before ON COMMIT DROP AS SELECT * FROM public.v_vehicle_stop_tank_changes WHERE vehicle_id = 1;
CREATE TEMP TABLE est_before ON COMMIT DROP AS
  SELECT g.visit_id, g.visit_date, g.basis, g.gallons, g.readings FROM ops.fn_grease_estimates_live((now() AT TIME ZONE 'America/New_York')::date, (now() AT TIME ZONE 'America/New_York')::date + 400) g;
CREATE TEMP TABLE avg_before ON COMMIT DROP AS SELECT to_jsonb(a) AS j FROM ops.v_client_sludge_average a;
CREATE TEMP TABLE chk_before ON COMMIT DROP AS
  SELECT public.fn_stop_facts_checks()->'integrity' AS integrity,
         (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure) AS fn_acl,
         (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_stop_facts_checks()'::regprocedure) AS chk_acl,
         (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_visit_tank_service'::regclass) AS svc_acl,
         (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_vehicle_stop_tank_changes'::regclass) AS chg_acl,
         (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_tank_data_quality_issues'::regclass) AS dq_acl,
         (SELECT array_agg(c.relname || '=' || coalesce(c.reloptions::text, '')) FROM pg_class c
           WHERE c.oid IN ('public.v_visit_tank_service'::regclass, 'public.v_vehicle_stop_tank_changes'::regclass,
                           'public.v_tank_data_quality_issues'::regclass)) AS relopts,
         (SELECT count(*) FROM public.v_tank_data_quality_issues) AS dq_rows;

-- ---------------------------------------------------------------------------------------------------------------
-- A. The ghost readings: one list per sensor kind, one test, one place
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_tank_ghost_distance_listed(p_contents text, p_distance_m numeric)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path TO ''
AS $f$
  -- Distances the LM11 radars on Moises read falsely (measured 2026-10-16; distances are stored to the centimetre, so a
  -- ghost is one exact value that repeats far more than its neighbours). The sludge false empty (2.09 m or more) is NOT
  -- here: many such readings are real empties after a dump, and the existing false-empty rule handles it. Nor is the
  -- false FULL (0.11 m or less): a truly full truck reads the same, and listing it rejected real full levels at dump
  -- stop 1249 and visit 6737 in the rehearsal; the existing spike rule still rejects an isolated one.
  select case p_contents
    when 'fresh_water' then p_distance_m between 1.13 and 1.15      -- the 1.14 m echo, about 765 gal (27 readings)
                          or p_distance_m >= 2.40                    -- no echo, about 0 gal (7 readings)
                          -- (2.12 to 2.14 m was a candidate: 3 readings, it does not repeat more than its neighbours,
                          --  and the one it would remove looks real (5901's water); left out)
    when 'sludge'      then p_distance_m = 1.35                     -- weak echo (17 readings, low confidence)
                          or p_distance_m between 1.71 and 1.73      -- the near-empty echo, 505 to 559 gal (118 readings)
    else false end
$f$;

COMMENT ON FUNCTION public.fn_tank_ghost_distance_listed(text, numeric) IS
'The known false-reading distances of the tank level sensors, per tank contents (Moises LM11 radars, measured 2026-10-16). A listed distance is only a SUSPECT: fn_tank_reading_ghosts rejects it when it also lies more than 15 cm outside its real neighbours. A remount or a new sensor needs a new list: v_tank_data_quality_issues F9 shows a repeating unlisted distance.';

CREATE OR REPLACE FUNCTION public.fn_tank_reading_ghosts(p_tank_sensor_id bigint DEFAULT NULL)
RETURNS TABLE(tank_sensor_id bigint, first_seen timestamptz, until timestamptz, distance_meters numeric,
              neighbour_low numeric, neighbour_high numeric)
LANGUAGE sql STABLE
SET search_path TO ''
AS $f$
  -- A measurement = a value change of a sensor's distance stream (distance > 0), from its first-seen time until the
  -- next change. It is a GHOST when its distance is listed (fn_tank_ghost_distance_listed) and lies more than 0.15 m
  -- outside the range of its nearest earlier and nearest later unlisted measurements (each within 24 h; one side when
  -- only one exists; kept when none). A neighbour is never taken across a dump or yard stop of the truck (8085: a
  -- neighbour from before a dump hid a ghost). A reading inside a dump or yard stop is judged against neighbours inside
  -- 24 h are counted from the END of the earlier neighbour's hold, so a level held over a weekend still counts. Only
  -- the ARRIVAL at a dump or yard stop is a barrier: a reading taken during or just after an offload takes its later
  -- neighbour across the departure (an offload moves one way), so the post-offload level of yard stop 1714 (1.73 m,
  -- between 1.10 before and 1.63 after) is kept while 8085's 1.71 m (next to 2.13 m empties) is not. Bars come from
  -- the vehicle the sensor was installed on, inside that installation's window. Limit: the near-empty echo read
  -- right after a dump sits between the full and empty levels and cannot be told from a real level (dumps 1091 and
  -- 1130 keep a departure about 540 gal high). Measured 2026-10-16 by a review that re-measured it: about 2 to 4
  -- possibly real readings per 168 flagged (control bands next to each listed value).
  with inst as (
    select i.tank_sensor_id, i.installed_at, i.removed_at, t.vehicle_id, t.contents
      from public.tank_sensor_installations i
      join public.vehicle_tanks t on t.id = i.vehicle_tank_id
     where i.superseded_at is null and (p_tank_sensor_id is null or i.tank_sensor_id = p_tank_sensor_id)
  ),
  raw as (
    select r.tank_sensor_id as s, inst.vehicle_id as v, inst.contents as c, r.recorded_at as t, r.distance_meters as d,
           lag(r.distance_meters) over (partition by r.tank_sensor_id order by r.recorded_at) as pd
      from public.tank_sensor_distance_readings r
      join inst on inst.tank_sensor_id = r.tank_sensor_id
               and r.recorded_at >= inst.installed_at and r.recorded_at < coalesce(inst.removed_at, 'infinity')
     where r.distance_meters > 0
  ),
  meas as (
    select s, v, c, t, d, lead(t) over (partition by s order by t) as until
      from raw where pd is distinct from d
  ),
  bars as (   -- the arrival at every dump or yard stop of the truck
    select st.vehicle_id as v, st.arrived_at as t
      from public.vehicle_stops st
      join public.properties sp on sp.id = st.site_property_id
     where st.superseded_at is null
       and st.vehicle_id in (select inst.vehicle_id from inst)
       and exists (select 1 from public.non_customer_clients nc
                    where nc.client_id = sp.client_id and nc.kind in ('dump_site', 'yard'))
  ),
  ev as (
    select s, c, t, d, until, false as is_bar from meas
    union all
    select i.tank_sensor_id, i.contents, b.t, null, null, true
      from bars b join inst i on i.vehicle_id = b.v
                             and b.t >= i.installed_at and b.t < coalesce(i.removed_at, 'infinity')
  ),
  sg as (
    select ev.*, count(*) filter (where is_bar) over (partition by s order by t, is_bar desc rows unbounded preceding) as seg
      from ev
  ),
  m as (
    select s, c, t, d, until, seg, public.fn_tank_ghost_distance_listed(c, d) as on_list,
           row_number() over (partition by s order by t) as k
      from sg where not is_bar
  ),
  nb as (
    select m.*,
           max(case when not on_list then k end) over (partition by s, seg order by k rows between unbounded preceding and 1 preceding) as kp,
           min(case when not on_list then k end) over (partition by s, seg order by k rows between 1 following and unbounded following) as kn
      from m
  ),
  j as (
    select nb.*, p.d as p_d, n.d as n_d
      from nb
      left join m p on p.s = nb.s and p.k = nb.kp and coalesce(p.until, 'infinity') >= nb.t - interval '24 hours'
      left join m n on n.s = nb.s and n.k = nb.kn and n.t <= nb.t + interval '24 hours'
     where nb.on_list
  )
  select s, t, coalesce(until, 'infinity'), d,
         least(coalesce(p_d, n_d), coalesce(n_d, p_d)), greatest(coalesce(p_d, n_d), coalesce(n_d, p_d))
    from j
   where coalesce(p_d, n_d) is not null
     and (d < least(coalesce(p_d, n_d), coalesce(n_d, p_d)) - 0.15
          or d > greatest(coalesce(p_d, n_d), coalesce(n_d, p_d)) + 0.15)
$f$;

COMMENT ON FUNCTION public.fn_tank_reading_ghosts(bigint) IS
'The ghost measurements of the tank level sensors (one row per false value, from first seen until the next value), for fn_measure_vehicle_stop_tank_levels v3 (rejection code 3). NULL = every sensor. See fn_tank_ghost_distance_listed.';

REVOKE ALL ON FUNCTION public.fn_tank_ghost_distance_listed(text, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_tank_reading_ghosts(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_tank_ghost_distance_listed(text, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_tank_reading_ghosts(bigint) TO service_role;


-- ---------------------------------------------------------------------------------------------------------------
-- C. fn_measure_vehicle_stop_tank_levels v3 and fn_stop_facts_checks: the live bodies, spliced (scratchpad
--    v3/build_v3.py; every anchor matched once)
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_measure_vehicle_stop_tank_levels(p_from timestamp with time zone, p_execute boolean, p_spike_agree_m numeric DEFAULT 0.05, p_spike_jump_m numeric DEFAULT 0.15, p_hyst_sludge numeric DEFAULT 0.01, p_hyst_water numeric DEFAULT 0.05, p_period interval DEFAULT '00:10:00'::interval, p_lookahead interval DEFAULT '03:00:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_version constant smallint := 3;   -- v3 2026-10-16: ghost readings, stale arrival edges, the change after leaving, peak and low
                                      -- (a change to fn_tank_ghost_distance_listed or fn_tank_reading_ghosts must bump this, or
                                      -- rows older than the 35-day horizon keep the old decisions; after the v3 rollback, use 5+)
                                      -- v2 2026-10-15: a client stop's edge must be a reading taken parked AT the stop
  c_back    constant interval := '3 hours';
  v_edge    interval := p_period + interval '1 minute';          -- 11 minutes with the defaults
  c_settle  constant interval := '10 seconds';   -- v2: stationary at a reading = every GPS fix from the last one 10 s
  c_still_m constant numeric  := 15;             -- v2: or more before it to the first one at or after it within 15 m
  c_at_m    constant numeric  := 100;            -- v2: and that position within 100 m of the stop's centre (the stop radius)
  v_mu timestamptz[];  v_ok boolean[];  v_tlast timestamptz;  v_hold timestamptz;
  p record;
  v_mt timestamptz[];  v_md float8[];  v_mf float8[];  v_rej int[];  n int;
  k int;  j int;  m int;  v_last float8;  v_rec timestamptz;
  v_dump_a timestamptz[];  v_dump_b timestamptz[];
  v_ai int;  v_di int;  v_dend timestamptz;  v_short boolean;
  v_h float8;  v_pivot float8;  v_ext float8;  v_dir int;  v_risen float8;  v_fallen float8;  v_v float8;
  v_lo timestamptz;  v_hi timestamptz;  v_cnt int;  v_rcnt int;
  d_af numeric;  d_at timestamptz;  d_df numeric;  d_dt timestamptz;  d_ri numeric;  d_fa numeric;
  v_pairs int := 0;  v_not_ready int := 0;  v_same int := 0;  v_ins int := 0;  v_sup int := 0;  v_drop int := 0;
  v_g_s bigint[];  v_g_f timestamptz[];  v_g_u timestamptz[];  v_g_d float8[];  v_gh boolean[];          -- v3
  v_hs float8;  v_stale boolean;  v_j int;  v_q int;  v_conf boolean;  v_dg float8;  v_tol float8;      -- v3
  v_basis text;  v_late numeric;  v_late_t timestamptz;  v_peak numeric;  v_low numeric;  v_gcnt int;     -- v3
  v_last_t timestamptz;  v_dump_y boolean[];                                                              -- v3
begin
  if p_from is null or p_execute is null then
    raise exception 'fn_measure_vehicle_stop_tank_levels: from and execute are required' using errcode = '22023';
  end if;
  if p_execute and (p_spike_agree_m <> 0.05 or p_spike_jump_m <> 0.15 or p_hyst_sludge <> 0.01 or p_hyst_water <> 0.05
                    or p_period <> interval '10 minutes' or p_lookahead <> interval '3 hours') then
    raise exception 'thresholds differ from algorithm version %; bump the version', c_version using errcode = '22023';
  end if;

  -- v3: the ghost readings of every sensor, judged once per run over its whole stream by fn_tank_reading_ghosts (a
  -- listed distance more than 15 cm outside its real neighbours). About 0.3 s on 2026-10-16 (148,000 readings).
  -- Ceiling: it reads the whole history every run; window it to the run's pairs before sensors go on another truck.
  select coalesce(array_agg(g.tank_sensor_id), '{}'), coalesce(array_agg(g.first_seen), '{}'),
         coalesce(array_agg(g.until), '{}'), coalesce(array_agg(g.distance_meters::float8), '{}')
    into v_g_s, v_g_f, v_g_u, v_g_d
    from public.fn_tank_reading_ghosts(null) g;

  for p in
    with pairs as (
      select s.id as stop_id, s.vehicle_id, s.arrived_at, s.departed_at, t.id as tank_id, t.contents,
             s.latitude as stop_lat, s.longitude as stop_lng, s.site_property_id as stop_site,
             t.deleted_at as tank_deleted_at,
             (select min(s2.arrived_at) from public.vehicle_stops s2
               where s2.vehicle_id = s.vehicle_id and s2.superseded_at is null and s2.arrived_at > s.arrived_at) as next_arrived,
             (select max(s3.departed_at) from public.vehicle_stops s3                          -- v3
               where s3.vehicle_id = s.vehicle_id and s3.superseded_at is null and s3.arrived_at < s.arrived_at) as prev_departed
        from public.vehicle_stops s
        join public.vehicle_tanks t on t.vehicle_id = s.vehicle_id
       where s.superseded_at is null),
    prov as (
      select pr.*, i.id as inst_id, i.tank_sensor_id, i.installed_at, i.removed_at,
             c.id as cfg_id, c.diameter_meters, c.sensor_offset_meters, c.capacity_gallons as cfg_cap,
             l.id as live_id, l.tank_sensor_installation_id as l_inst, l.vehicle_tank_configuration_id as l_cfg,
             l.algorithm_version as l_ver, l.arrival_fill_fraction as l_af, l.arrival_measured_at as l_at,
             l.departure_fill_fraction as l_df, l.departure_measured_at as l_dt, l.fill_fraction_risen as l_ri,
             l.fill_fraction_fallen as l_fa, l.measurement_count as l_cnt, l.rejected_measurement_count as l_rcnt,
             l.peak_fill_fraction as l_pk, l.low_fill_fraction as l_lw, l.departure_basis as l_basis,
             l.late_change_fill_fraction as l_late, l.late_change_measured_at as l_late_t,
             l.ghost_measurement_count as l_gcnt
        from pairs pr
        left join lateral (
          select i.* from public.tank_sensor_installations i
           where i.vehicle_tank_id = pr.tank_id and i.superseded_at is null and pr.tank_deleted_at is null
             and i.installed_at <= pr.arrived_at and pr.arrived_at < coalesce(i.removed_at, 'infinity')
           order by i.installed_at desc limit 1) i on true
        left join lateral (
          select c.* from public.vehicle_tank_configurations c
           where c.vehicle_tank_id = pr.tank_id and c.superseded_at is null and c.effective_from <= pr.arrived_at
           order by c.effective_from desc limit 1) c on true
        left join public.vehicle_stop_tank_levels l
          on l.vehicle_stop_id = pr.stop_id and l.vehicle_tank_id = pr.tank_id and l.superseded_at is null)
    select * from prov
     where (arrived_at >= p_from and (live_id is not null or (inst_id is not null and cfg_id is not null)))  -- (a) horizon
        or (live_id is not null and (inst_id is distinct from l_inst or cfg_id is distinct from l_cfg       -- (b) Z3
                                     or l_ver < c_version or tank_deleted_at is not null))
        or (live_id is null and inst_id is not null and cfg_id is not null                                  -- (c) Z2
            and departed_at + interval '4 hours' < now())
     order by vehicle_id, arrived_at, tank_id
  loop
    v_pairs := v_pairs + 1;

    -- no installation or configuration in force: supersede the live row, insert nothing
    if p.inst_id is null or p.cfg_id is null then
      if p.live_id is not null then
        if p_execute then
          update public.vehicle_stop_tank_levels set superseded_at = now() where id = p.live_id;
        end if;
        v_drop := v_drop + 1;
      end if;
      continue;
    end if;
    if now() < p.departed_at + p_lookahead then v_not_ready := v_not_ready + 1; continue; end if;

    -- 1-3. raw series -> measurements (value changes, first-seen time) -> fractions
    select array_agg(x.t order by x.t), array_agg(x.d::float8 order by x.t),
           array_agg(public.fn_tank_fill_fraction(x.d, p.diameter_meters, p.sensor_offset_meters)::float8 order by x.t),
           max(x.t_last)
      into v_mt, v_md, v_mf, v_tlast
      from (select r.recorded_at as t, r.distance_meters as d,
                   lag(r.distance_meters) over (order by r.recorded_at) as pd,
                   max(r.recorded_at) over () as t_last                               -- v2
              from public.tank_sensor_distance_readings r
             where r.tank_sensor_id = p.tank_sensor_id
               and r.recorded_at >= greatest(p.arrived_at - c_back, p.installed_at)
               and r.recorded_at <= p.departed_at + p_lookahead
               and r.recorded_at <  coalesce(p.removed_at, 'infinity')
               and r.distance_meters > 0) x
     where x.pd is distinct from x.d;
    n := coalesce(cardinality(v_mt), 0);
    v_rej := array_fill(0, array[greatest(n, 1)]);

    -- 3b (v3). Ghost readings (rejection code 3): a measurement whose value is a ghost interval of this sensor.
    --   Matched on the interval, so the first row of the window, whose value may have been first seen before the
    --   window (6569, 8134), is caught too.
    select array_agg(exists (select 1 from unnest(v_g_s, v_g_f, v_g_u, v_g_d) g(s, f, u, d)
                              where g.s = p.tank_sensor_id and g.f <= m.t and m.t < g.u and g.d = m.d) order by m.k)
      into v_gh
      from unnest(v_mt, v_md) with ordinality m(t, d, k);
    for k in 1 .. n loop
      if v_gh[k] then v_rej[k] := 3; end if;
    end loop;

    -- 4. spike: neighbours agree, this one jumps away from both
    --   v3: the neighbours are the nearest measurements that are not ghosts (a real reading between two echoes was
    --   rejected as a spike: 8134, 5901, 6975's water)
    for k in 2 .. n - 1 loop
      continue when v_rej[k] <> 0;
      j := k - 1;  while j >= 1 and v_rej[j] = 3 loop j := j - 1; end loop;
      m := k + 1;  while m <= n and v_rej[m] = 3 loop m := m + 1; end loop;
      if j >= 1 and m <= n and abs(v_md[j] - v_md[m]) <= p_spike_agree_m
         and abs(v_md[k] - v_md[j]) > p_spike_jump_m and abs(v_md[k] - v_md[m]) > p_spike_jump_m then
        v_rej[k] := 1;
      end if;
    end loop;

    -- 5. false empty with look-ahead (a real post-dump empty survives)
    select coalesce(array_agg(s.arrived_at), '{}'), coalesce(array_agg(s.departed_at), '{}'),
           coalesce(array_agg(nc.kind = 'yard'), '{}')                                       -- v3
      into v_dump_a, v_dump_b, v_dump_y
      from public.vehicle_stops s
      join public.properties sp on sp.id = s.site_property_id
      join public.non_customer_clients nc on nc.client_id = sp.client_id and nc.kind in ('dump_site', 'yard')   -- v3: yard offloads too
     where s.vehicle_id = p.vehicle_id and s.superseded_at is null
       and s.departed_at >= p.arrived_at - c_back and s.arrived_at <= p.departed_at + 2 * p_lookahead;
    v_last := null;  v_last_t := null;  k := 1;
    while k <= n loop
      if v_rej[k] <> 0 then k := k + 1; continue; end if;
      if v_mf[k] is not null and v_mf[k] <= 0.005 then
        j := k;
        m := k + 1;
        while m <= n loop                                      -- extend the run over accepted measurements
          if v_rej[m] <> 0 then m := m + 1; continue; end if;
          exit when v_mf[m] > 0.005;
          j := m;  m := m + 1;
        end loop;
        v_rec := null;
        if v_last is not null and v_last > 0.15 then
          for m in j + 1 .. n loop
            exit when v_mt[m] > v_mt[k] + p_lookahead;
            if v_rej[m] = 0 and v_mf[m] > 0.15 then v_rec := v_mt[m]; exit; end if;
          end loop;
        end if;
        if v_rec is not null and not exists (select 1 from unnest(v_dump_a, v_dump_b, v_dump_y) dd(a, b, y)
                                              where (not dd.y and dd.a <= v_rec and dd.b >= v_mt[k])
                                                 -- v3: or the empty is first seen inside a dump or yard stop that
                                                 -- ended after the last level, or within two periods after it (an
                                                 -- offload's empty can show only after the truck left, at the
                                                 -- sensor's pace). The v2 arm stays dumps-only: a yard stop AFTER
                                                 -- an empty explains nothing (6618's false empty at the client).
                                                 or (dd.a <= v_mt[k] and dd.b >= v_last_t and dd.b >= v_mt[k] - 2 * p_period)) then
          for m in k .. j loop if v_rej[m] = 0 then v_rej[m] := 2; end if; end loop;
        else
          v_last := v_mf[j];  v_last_t := v_mt[j];
        end if;
        k := j + 1;
      else
        v_last := v_mf[k];  v_last_t := v_mt[k];  k := k + 1;
      end if;
    end loop;

    -- 5b (v2, 2026-10-15). Which measurements may be an EDGE of a client stop: a level taken parked AT the stop
    --   (trap 8; audit 2026-10-15: edges taken at up to 48 mph, and one taken at the NEXT client, were used). Either
    --   (i) the truck was stationary: every GPS fix from the last one at least c_settle before the reading to the
    --       first one at or after it lies within c_still_m of that first one (a reading taken moving sloshes; at 6 s
    --       fixes this is about 3 mph or more), and that first fix is within c_at_m of the stop's centre (a reading
    --       taken at the previous or the next stop is never this stop's edge); or
    --   (ii) the value was held, up to the next accepted measurement, for a full period (v_edge) inside the stop
    --       window, so the sensor re-measured it there (a flat level first seen on the road keeps its first-seen time
    --       and is confirmed parked).
    --   No speed: the GPS writer stores none (0 of 156,649 Moises fixes). GPS is read only up to the edge horizon.
    --   Dump and yard stops (site_property_id set) keep the v1 edges: their extent is a geofence up to 1.4 km
    --   across, and the level before tipping is only seen on the way in.
    v_mu := array_fill(null::timestamptz, array[greatest(n, 1)]);
    v_hold := coalesce(v_tlast, p.departed_at + p_lookahead);
    for k in reverse n .. 1 loop
      v_mu[k] := v_hold;
      if v_rej[k] in (0, 3) then v_hold := v_mt[k]; end if;   -- v3: a ghost ends the hold (level unknown from then)
    end loop;
    select array_agg(coalesce(
             p.stop_site is not null
             or least(m.tu, p.departed_at) - greatest(m.t, p.arrived_at) >= v_edge
             or (gb.recorded_at is not null and sp.spread_m <= c_still_m
                 and ops.fn_haversine_km(ga.latitude, ga.longitude, p.stop_lat, p.stop_lng) * 1000 <= c_at_m),
             false) order by m.k)
      into v_ok
      from unnest(v_mt, v_mu) with ordinality as m(t, tu, k)
      left join lateral (select g.recorded_at, g.latitude, g.longitude from public.vehicle_telemetry_readings g
                          where p.stop_site is null
                            and m.t <= least(p.departed_at + v_edge, coalesce(p.next_arrived, 'infinity'))
                            and g.vehicle_id = p.vehicle_id and g.latitude is not null and g.recorded_at >= m.t
                          order by g.recorded_at limit 1) ga on true
      left join lateral (select g.recorded_at from public.vehicle_telemetry_readings g
                          where ga.recorded_at is not null
                            and g.vehicle_id = p.vehicle_id and g.latitude is not null and g.recorded_at <= m.t - c_settle
                          order by g.recorded_at desc limit 1) gb on true
      left join lateral (select max(ops.fn_haversine_km(g.latitude, g.longitude, ga.latitude, ga.longitude)) * 1000 as spread_m
                           from public.vehicle_telemetry_readings g
                          where gb.recorded_at is not null
                            and g.vehicle_id = p.vehicle_id and g.latitude is not null
                            and g.recorded_at between gb.recorded_at and ga.recorded_at) sp on true;

    -- 6. arrival edge (v2: an edge measurement, and never after the next stop's arrival)
    v_ai := null;  v_stale := false;
    for k in reverse n .. 1 loop
      if v_rej[k] = 0 and v_ok[k] and v_mt[k] <= p.arrived_at and v_mt[k] >= p.arrived_at - c_back then v_ai := k; exit; end if;
    end loop;
    -- 6a (v3). A parked reading before arrival is the arrival level only if the level did not change after it: an
    --   accepted measurement between it and the arrival that differs by more than the hysteresis means it was taken
    --   before another stop's work (082-TFC, stop 1246, took the water of 182-PAL's stop 1245). Client stops only.
    if v_ai is not null and p.stop_site is null then
      v_hs := case when p.contents = 'sludge' then p_hyst_sludge else p_hyst_water end;
      for k in v_ai + 1 .. n loop
        exit when v_mt[k] > p.arrived_at;
        if v_rej[k] = 0 and abs(v_mf[k] - v_mf[v_ai]) > v_hs then v_stale := true; exit; end if;
      end loop;
      if v_stale then v_ai := null; end if;
    end if;
    if v_ai is null then
      for k in 1 .. n loop
        if v_rej[k] = 0 and v_ok[k] and v_mt[k] > p.arrived_at
           and v_mt[k] <= least(p.arrived_at + v_edge, coalesce(p.next_arrived, 'infinity')) then v_ai := k; exit; end if;
      end loop;
    end if;
    -- 6b (v3). No parked arrival reading on a client stop that is stale or lasts a period or more (its parked
    --   candidate was another stop's level, or a ghost): the level the sensor was reporting at arrival, i.e. the last
    --   accepted measurement after the previous stop's departure, or the last measurement of all before arrival when
    --   it is accepted (a level held unchanged through the drive; stop 1220). Never an older level (8085 arrived right
    --   after a dump: the level from before it read -1,201 gal). Failing both, the first accepted level in the stop.
    if v_ai is null and (v_stale or (p.stop_site is null and p.departed_at - p.arrived_at >= p_period)) then
      v_q := null;
      for k in reverse n .. 1 loop
        if v_mt[k] <= p.arrived_at then v_q := k; exit; end if;
      end loop;
      for k in reverse n .. 1 loop
        if v_rej[k] = 0 and v_mt[k] <= p.arrived_at and v_mt[k] >= p.arrived_at - c_back
           and (v_mt[k] > coalesce(p.prev_departed, '-infinity') or k = v_q) then v_ai := k; exit; end if;
      end loop;
      if v_ai is null then
        for k in 1 .. n loop
          if v_rej[k] = 0 and v_mt[k] > p.arrived_at and v_mt[k] <= p.departed_at then v_ai := k; exit; end if;
        end loop;
      end if;
    end if;
    -- 7. departure edge (v2: an edge measurement)
    v_dend := least(p.departed_at + v_edge, coalesce(p.next_arrived, 'infinity'));
    v_di := null;
    for k in 1 .. n loop
      if v_rej[k] = 0 and v_ok[k] and v_mt[k] > p.departed_at and v_mt[k] <= v_dend then v_di := k; exit; end if;
    end loop;
    if v_di is null then
      for k in reverse n .. 1 loop
        if v_rej[k] = 0 and v_ok[k] and v_mt[k] <= p.departed_at
           and (p.stop_site is not null or v_mt[k] >= coalesce(v_mt[v_ai], '-infinity')) then v_di := k; exit; end if;   -- v3
      end loop;
    end if;
    -- 7a (v3). No parked departure reading on a client stop of a period or more (its parked candidate was a ghost):
    --   the last accepted level at or before departure, never before the arrival edge.
    if v_di is null and p.stop_site is null and p.departed_at - p.arrived_at >= p_period then
      for k in reverse n .. 1 loop
        if v_rej[k] = 0 and v_mt[k] <= p.departed_at and v_mt[k] >= coalesce(v_mt[v_ai], p.arrived_at) then v_di := k; exit; end if;
      end loop;
    end if;
    -- 7b (v3). The change after leaving (Fred, 2026-10-15: "after leaving the geofencing of the client it might have a
    --   change in the water and sludge level"). Measured 2026-10-16: nothing separates on the road; the 10-minute
    --   sensor schedule shows the end of a visit's pumping in the first reading AFTER the truck leaves, usually taken
    --   moving, which v2 never used (233-AH, visit 7029, pumped about 207 gal that read 0). Client stops only.
    --   j = the first accepted measurement after leaving, within one period and before the next stop's arrival. A change
    --   over 100 gal (sludge) / 60 gal (water: its hysteresis) is recorded as late_change unless the next accepted
    --   reading comes back within 50 / 30 gal of the stop's level (a slosh or a dip, 7 of 9 such changes in the
    --   rehearsal). It becomes the departure level when confirmed: under 400 gal, every later measurement up to one
    --   period into the next stop within 50 / 30 gal of it (ghosts skipped), and for sludge a full period before the
    --   next stop (water does not move on the road: 12.6 gal at most over 45 departures). Otherwise it stays a flag.
    --   The applied value is j itself, read moving: about one sensor step (20 gal) off the next parked level.
    v_basis := case when p.stop_site is null and v_di is not null then 'at_stop' end;
    v_late := null;  v_late_t := null;
    if p.stop_site is null and v_di is not null and v_mt[v_di] <= p.departed_at and p.cfg_cap is not null then
      v_j := null;
      for k in 1 .. n loop
        exit when v_mt[k] > least(p.departed_at + v_edge, coalesce(p.next_arrived, 'infinity'));
        if v_mt[k] > p.departed_at and v_rej[k] = 0 then v_j := k; exit; end if;
      end loop;
      if v_j is not null then
        v_dg := (v_mf[v_j] - v_mf[v_di]) * p.cfg_cap::float8;
        v_tol := case when p.contents = 'sludge' then 50 else 30 end;
        if abs(v_dg) > (case when p.contents = 'sludge' then 100 else 60 end) then
          v_q := null;
          for k in v_j + 1 .. n loop
            exit when v_mt[k] > least(coalesce(p.next_arrived + v_edge, 'infinity'), v_mt[v_j] + p_lookahead);
            if v_rej[k] = 0 then v_q := k; exit; end if;
          end loop;
          if v_q is null or abs(v_mf[v_q] - v_mf[v_di]) * p.cfg_cap::float8 > v_tol then
            v_late := round((v_mf[v_j] - v_mf[v_di])::numeric, 5);  v_late_t := v_mt[v_j];
            if abs(v_dg) < 400
               and (p.contents = 'fresh_water' or p.next_arrived is null or p.next_arrived - v_mt[v_j] >= p_period) then
              v_conf := true;
              for k in v_j + 1 .. n loop
                exit when v_mt[k] > least(coalesce(p.next_arrived + v_edge, 'infinity'), v_mt[v_j] + p_lookahead);
                continue when v_rej[k] = 3;
                if v_rej[k] <> 0 or abs(v_mf[k] - v_mf[v_j]) * p.cfg_cap::float8 > v_tol then
                  v_conf := false;  exit;
                end if;
              end loop;
              if v_conf then v_di := v_j;  v_basis := 'after_leaving'; end if;
            end if;
          end if;
        end if;
      end if;
    end if;
    -- 8. too short
    v_short := v_dend - p.arrived_at < p_period;

    -- 9. risen and fallen: zig-zag with end flush over the accepted measurements between the edges
    v_risen := null;  v_fallen := null;
    if v_ai is not null and v_di is not null and not v_short then
      v_h := case when p.contents = 'sludge' then p_hyst_sludge else p_hyst_water end;
      v_pivot := v_mf[least(v_ai, v_di)];  v_ext := v_pivot;  v_dir := 0;  v_risen := 0;  v_fallen := 0;
      for k in least(v_ai, v_di) + 1 .. greatest(v_ai, v_di) loop
        continue when v_rej[k] <> 0;
        v_v := v_mf[k];
        if v_dir = 0 then
          if v_v - v_pivot > v_h then v_dir := 1; v_ext := v_v;
          elsif v_pivot - v_v > v_h then v_dir := -1; v_ext := v_v; end if;
        elsif v_dir = 1 then
          if v_v > v_ext then v_ext := v_v;
          elsif v_ext - v_v > v_h then v_risen := v_risen + (v_ext - v_pivot); v_pivot := v_ext; v_ext := v_v; v_dir := -1; end if;
        else
          if v_v < v_ext then v_ext := v_v;
          elsif v_v - v_ext > v_h then v_fallen := v_fallen + (v_pivot - v_ext); v_pivot := v_ext; v_ext := v_v; v_dir := 1; end if;
        end if;
      end loop;
      if v_dir = 1 then v_risen := v_risen + (v_ext - v_pivot);
      elsif v_dir = -1 then v_fallen := v_fallen + (v_pivot - v_ext); end if;
    end if;

    -- 9b (v3). Peak and low: the raw highest and lowest accepted levels between the edges (not start + risen: the
    --   zig-zag ignores swings under the hysteresis, the peak does not)
    v_peak := null;  v_low := null;
    if v_ai is not null and v_di is not null then
      select round(max(x.f)::numeric, 5), round(min(x.f)::numeric, 5) into v_peak, v_low
        from unnest(v_mf, v_rej) with ordinality x(f, r, k)
       where x.k between least(v_ai, v_di) and greatest(v_ai, v_di) and x.r = 0;
    end if;

    -- 10. counts between the edges (inclusive), rounding, diff, write
    v_lo := coalesce(v_mt[v_ai], p.arrived_at);  v_hi := coalesce(v_mt[v_di], p.departed_at);
    if v_lo > v_hi then v_lo := v_hi; v_hi := coalesce(v_mt[v_ai], p.arrived_at); end if;
    v_cnt := 0;  v_rcnt := 0;  v_gcnt := 0;
    for k in 1 .. n loop
      if v_mt[k] between v_lo and v_hi then
        if v_rej[k] = 0 then v_cnt := v_cnt + 1; else v_rcnt := v_rcnt + 1; end if;
        if v_rej[k] = 3 then v_gcnt := v_gcnt + 1; end if;
      end if;
    end loop;
    d_af := round(v_mf[v_ai]::numeric, 5);  d_at := v_mt[v_ai];
    d_df := round(v_mf[v_di]::numeric, 5);  d_dt := v_mt[v_di];
    d_ri := round(v_risen::numeric, 5);     d_fa := round(v_fallen::numeric, 5);

    if p.live_id is not null
       and p.l_inst = p.inst_id and p.l_cfg = p.cfg_id and p.l_ver = c_version
       and p.l_af is not distinct from d_af and p.l_at is not distinct from d_at
       and p.l_df is not distinct from d_df and p.l_dt is not distinct from d_dt
       and p.l_ri is not distinct from d_ri and p.l_fa is not distinct from d_fa
       and p.l_cnt = v_cnt and p.l_rcnt = v_rcnt
       and p.l_pk is not distinct from v_peak and p.l_lw is not distinct from v_low
       and p.l_basis is not distinct from v_basis and p.l_late is not distinct from v_late
       and p.l_late_t is not distinct from v_late_t and p.l_gcnt is not distinct from v_gcnt then
      v_same := v_same + 1;
      continue;
    end if;
    if p_execute then
      if p.live_id is not null then
        update public.vehicle_stop_tank_levels set superseded_at = now() where id = p.live_id;
      end if;
      insert into public.vehicle_stop_tank_levels
        (vehicle_stop_id, vehicle_id, vehicle_tank_id, tank_sensor_installation_id, vehicle_tank_configuration_id,
         arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at,
         fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, algorithm_version,
         peak_fill_fraction, low_fill_fraction, departure_basis, late_change_fill_fraction, late_change_measured_at,
         ghost_measurement_count)
      values (p.stop_id, p.vehicle_id, p.tank_id, p.inst_id, p.cfg_id, d_af, d_at, d_df, d_dt, d_ri, d_fa,
              v_cnt, v_rcnt, c_version, v_peak, v_low, v_basis, v_late, v_late_t, v_gcnt);
    end if;
    if p.live_id is not null then v_sup := v_sup + 1; end if;
    v_ins := v_ins + 1;
  end loop;

  return jsonb_build_object('execute', p_execute, 'from', p_from, 'pairs', v_pairs, 'not_ready', v_not_ready,
                            'unchanged', v_same, 'inserted', v_ins, 'superseded_and_replaced', v_sup,
                            'superseded_no_provenance', v_drop);
end $function$;

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
                   || 'v_vehicle_stop_tank_changes|v_visit_tank_service|v_vehicle_dumps|v_tank_data_quality_issues|'
                   || 'v_visit_water_balance|v_vehicle_water_ledger|fn_tank_reading_ghosts|fn_tank_ghost_distance_listed';   -- v3
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
    'F9', (select count(*) from public.v_tank_data_quality_issues where issue_code = 'F9'),   -- v3: a new false-reading distance
    'F2_F4_F6', 'counted by v_tank_data_quality_issues (M6)');

  -- 2026-10-14_1110: the time on site checks T1..T6 (fn_time_on_site_checks) ride in the integrity set
  return jsonb_build_object('integrity', z || public.fn_time_on_site_checks(), 'feed', t, 'flags', f, 'checked_at', now());
end $function$;

INSERT INTO clk SELECT 'functions', clock_timestamp();

-- ---------------------------------------------------------------------------------------------------------------
-- F. Re-measure. c_version 3 makes every live v2 row a Z3 pair, so this call re-measures the whole sensor era. It
--    writes only vehicle_stop_tank_levels (supersede + insert); the read views are still v2 here and keep serving.
--    Pairs whose look-ahead has not passed stay v2 until the next hourly run.
-- ---------------------------------------------------------------------------------------------------------------
CREATE TEMP TABLE remeasure ON COMMIT DROP AS
  SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '35 days', true) AS r;
INSERT INTO clk SELECT 'remeasure', clock_timestamp();
CREATE TEMP TABLE gh ON COMMIT DROP AS SELECT * FROM public.fn_tank_reading_ghosts(null);
CREATE TEMP TABLE svc_after ON COMMIT DROP AS SELECT * FROM public.v_visit_tank_service WHERE vehicle_id = 1;
CREATE TEMP TABLE dump_after ON COMMIT DROP AS SELECT * FROM public.v_vehicle_dumps WHERE vehicle_id = 1;
-- the v2 view plus the new columns read from the table (the view is replaced only at the end)
CREATE TEMP TABLE lvl_after ON COMMIT DROP AS
  SELECT c.*, l.peak_fill_fraction, round(l.peak_fill_fraction * c.capacity_gallons, 1) AS peak_gallons,
         l.low_fill_fraction, l.departure_basis, l.late_change_measured_at, l.late_change_fill_fraction,
         round(l.late_change_fill_fraction * c.capacity_gallons, 1) AS late_change_gallons, l.ghost_measurement_count
    FROM public.v_vehicle_stop_tank_changes c
    JOIN public.vehicle_stop_tank_levels l ON l.id = c.vehicle_stop_tank_level_id
   WHERE c.vehicle_id = 1;
CREATE TEMP TABLE est_after ON COMMIT DROP AS
  SELECT g.visit_id, g.visit_date, g.basis, g.gallons, g.readings FROM ops.fn_grease_estimates_live((now() AT TIME ZONE 'America/New_York')::date, (now() AT TIME ZONE 'America/New_York')::date + 400) g;
CREATE TEMP TABLE avg_after ON COMMIT DROP AS SELECT to_jsonb(a) AS j FROM ops.v_client_sludge_average a;
INSERT INTO clk SELECT 'after_reads', clock_timestamp();

-- ---------------------------------------------------------------------------------------------------------------
-- VERIFY, part 1 (the data, before the views are touched)
-- ---------------------------------------------------------------------------------------------------------------
DO $v$
DECLARE
  r jsonb := (SELECT r FROM remeasure);
  z jsonb := public.fn_stop_facts_checks()->'integrity';
  zb jsonb := (SELECT integrity FROM chk_before);
  n int;  k text;  x numeric;  y numeric;
  fn text := 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)';
  -- v2's audited moving / next-stop readings (sludge, UTC): still never an edge
  bad timestamptz[] := array['2026-10-13 05:12:08+00', '2026-10-13 05:22:00+00', '2026-10-12 09:12:23+00',
                             '2026-10-13 04:32:08+00', '2026-10-13 04:23:12+00']::timestamptz[];
BEGIN
  -- 1. the re-measure ran, and nothing older than v3 is left except pairs not ready yet
  IF coalesce((r->>'inserted')::int, 0) = 0 THEN RAISE EXCEPTION 'VERIFY 1: re-measure inserted nothing: %', r; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND s.superseded_at IS NULL AND l.algorithm_version < 3 AND s.departed_at + interval '3 hours' <= now();
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % ready live level rows still older than v3', n; END IF;

  -- 2. integrity: every Z and T check reads what it read before, and the Z8 control is found
  FOREACH k IN ARRAY array['Z1','Z2','Z3','Z4','Z6','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6'] LOOP
    IF (z->>k) IS DISTINCT FROM (zb->>k) THEN RAISE EXCEPTION 'VERIFY 2: % = % (was %)', k, z->>k, zb->>k; END IF;
  END LOOP;
  IF (z->>'Z8_control_found')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'VERIFY 2: Z8 control not found'; END IF;

  -- 3a. privileges on the functions: the writer and the checks keep their ACLs; the ghost functions are service_role only
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = fn::regprocedure) IS DISTINCT FROM (SELECT fn_acl FROM chk_before)
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_stop_facts_checks()'::regprocedure) IS DISTINCT FROM (SELECT chk_acl FROM chk_before)
     OR has_function_privilege('anon', 'public.fn_tank_reading_ghosts(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_tank_reading_ghosts(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_tank_ghost_distance_listed(text,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_tank_ghost_distance_listed(text,numeric)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_tank_ghost_distance_listed(text,numeric)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_tank_reading_ghosts(bigint)', 'EXECUTE')
  THEN RAISE EXCEPTION 'VERIFY 3a: a function privilege is not what it should be'; END IF;

  -- 4. no live edge is a ghost any more; the same detector found some among the rows this replaced (positive control)
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l
     JOIN public.tank_sensor_installations i ON i.id = l.tank_sensor_installation_id
     JOIN public.vehicle_tank_configurations c ON c.id = l.vehicle_tank_configuration_id
     JOIN gh g ON g.tank_sensor_id = i.tank_sensor_id
      AND ((l.arrival_measured_at >= g.first_seen AND l.arrival_measured_at < g.until
            AND abs(l.arrival_fill_fraction - public.fn_tank_fill_fraction(g.distance_meters, c.diameter_meters, c.sensor_offset_meters)) < 0.00002)
        OR (l.departure_measured_at >= g.first_seen AND l.departure_measured_at < g.until
            AND abs(l.departure_fill_fraction - public.fn_tank_fill_fraction(g.distance_meters, c.diameter_meters, c.sensor_offset_meters)) < 0.00002))
    WHERE l.superseded_at IS NULL AND l.algorithm_version = 3;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % live v3 edges are ghost readings', n; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l
     JOIN public.tank_sensor_installations i ON i.id = l.tank_sensor_installation_id
     JOIN public.vehicle_tank_configurations c ON c.id = l.vehicle_tank_configuration_id
     JOIN gh g ON g.tank_sensor_id = i.tank_sensor_id
      AND ((l.arrival_measured_at >= g.first_seen AND l.arrival_measured_at < g.until
            AND abs(l.arrival_fill_fraction - public.fn_tank_fill_fraction(g.distance_meters, c.diameter_meters, c.sensor_offset_meters)) < 0.00002)
        OR (l.departure_measured_at >= g.first_seen AND l.departure_measured_at < g.until
            AND abs(l.departure_fill_fraction - public.fn_tank_fill_fraction(g.distance_meters, c.diameter_meters, c.sensor_offset_meters)) < 0.00002))
    WHERE l.id IN (SELECT vehicle_stop_tank_level_id FROM lvl_before);
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY 4: control failed: no replaced row had a ghost edge, the detector proves nothing'; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l
   WHERE l.superseded_at IS NULL AND l.vehicle_id = 1 AND (l.arrival_measured_at = ANY (bad) OR l.departure_measured_at = ANY (bad));
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % live rows use a v2-audited moving or next-stop reading', n; END IF;
  -- 4b. no departure edge before its arrival edge (the backward search is bounded by the arrival)
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l
   WHERE l.superseded_at IS NULL AND l.departure_measured_at < l.arrival_measured_at;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4b: % live rows depart before they arrive', n; END IF;
  -- 4c. departure_basis only on client stops with a departure level
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND l.algorithm_version = 3
     AND (l.departure_basis IS NOT NULL) <> (s.site_property_id IS NULL AND l.departure_fill_fraction IS NOT NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4c: % rows carry a departure_basis where they should not, or miss one', n; END IF;

  -- 5. the measured cases (2026-10-16 review traces; ranges are the trace +/- a sensor step or two)
  SELECT risen_gallons, fallen_gallons INTO x, y FROM lvl_after WHERE vehicle_stop_id = 1241 AND contents = 'fresh_water';   -- 6619
  IF x IS NULL OR x NOT BETWEEN 480 AND 505 OR y NOT BETWEEN 255 AND 285 THEN RAISE EXCEPTION 'VERIFY 5: 6619 water %/%, expected about 492/269', x, y; END IF;
  SELECT greatest(risen_gallons, fallen_gallons) INTO x FROM lvl_after WHERE vehicle_stop_id = 1246 AND contents = 'fresh_water';  -- 082-TFC
  IF x IS NULL OR x > 50 THEN RAISE EXCEPTION 'VERIFY 5: 082-TFC stop 1246 still moves % gal of 182-PAL''s water', x; END IF;
  IF (SELECT departure_basis FROM lvl_after WHERE vehicle_stop_id = 1239 AND contents = 'sludge') IS DISTINCT FROM 'after_leaving'
     OR (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 7029) NOT BETWEEN 190 AND 225
  THEN RAISE EXCEPTION 'VERIFY 5: 233-AH (7029) reads % gal', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 7029); END IF;
  FOR k IN SELECT t.k FROM (VALUES
       ('7029 water put back', (SELECT water_used_gallons FROM svc_after WHERE visit_id = 7029), 100::numeric, 130::numeric),
       ('7872 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 7872), 250, 300),
       ('8085 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 8085), -50, 100),
       ('6569 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 6569), 1350, 1500),
       ('5901 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 5901), 3200, 3380),
       ('8134 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 8134), 230, 285),
       ('6419 sludge', (SELECT sludge_collected_gallons FROM svc_after WHERE visit_id = 6419), 770, 820),
       ('6975 water separated', (SELECT water_refilled_gallons FROM svc_after WHERE visit_id = 6975), 1560, 1660),
       ('5922 water put back', (SELECT water_used_gallons FROM svc_after WHERE visit_id = 5922), 700, 800),
       ('5936 water put back', (SELECT water_used_gallons FROM svc_after WHERE visit_id = 5936), 60, 110),
       ('6523 water put back', (SELECT water_used_gallons FROM svc_after WHERE visit_id = 6523), 60, 110)) t(k, v, lo, hi)
     WHERE t.v IS NULL OR t.v NOT BETWEEN t.lo AND t.hi
  LOOP
    RAISE EXCEPTION 'VERIFY 5: % out of its expected range', k;
  END LOOP;

  -- 6. no regression into "unknown": no visit newly edge_missing, no linked client stop of 10 min or more without edges
  SELECT count(*) INTO n FROM svc_after a JOIN svc_before b USING (visit_id)
   WHERE a.sludge_reason = 'edge_missing' AND b.sludge_reason IS DISTINCT FROM 'edge_missing';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 6: % visits newly edge_missing', n; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND s.superseded_at IS NULL AND s.site_property_id IS NULL
     AND s.departed_at - s.arrived_at >= interval '10 minutes'
     AND (l.arrival_fill_fraction IS NULL OR l.departure_fill_fraction IS NULL)
     AND EXISTS (SELECT 1 FROM public.visit_vehicle_stops vs WHERE vs.vehicle_stop_id = s.id AND vs.deleted_at IS NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 6: % linked client stops of 10 min or more without an edge', n; END IF;

  -- 7. dumps: the dump and yard edge rules did not change, so a dump may change only where its departure was the
  --    near-empty echo just after the offload, now a ghost: the offload grows and the departure is an empty tank
  --    (rehearsal 2026-10-16: 1130 2515.2 > 2977.4, 1253 1000.2 > 1589.8, the latter is 5901's dump)
  SELECT count(*) INTO n FROM dump_before b FULL JOIN dump_after a USING (vehicle_stop_id)
   WHERE a.vehicle_stop_id IS NULL OR b.vehicle_stop_id IS NULL
      OR a.offload_reason IS DISTINCT FROM b.offload_reason
      OR (a.offload_gallons IS DISTINCT FROM b.offload_gallons
          AND NOT (a.offload_gallons > b.offload_gallons
                   AND (SELECT departure_gallons FROM lvl_after l WHERE l.vehicle_stop_id = a.vehicle_stop_id AND l.contents = 'sludge') < 100));
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 7: % dumps changed in a way the ghost filter cannot explain', n; END IF;
  SELECT count(*) INTO n FROM dump_before b JOIN dump_after a USING (vehicle_stop_id)
   WHERE a.offload_gallons IS DISTINCT FROM b.offload_gallons;
  IF n > 3 THEN RAISE EXCEPTION 'VERIFY 7: % dumps changed (2 expected)', n; END IF;

  -- 8. the Calendar, over every scheduled visit with an effective truck: a basis may only move from the trap size
  --    to a measured average (a reading that now counts: 233-AH's 7029), never the other way or to unknown; no row
  --    appears or vanishes (frozen past days are untouched by design)
  SELECT count(*) INTO n FROM est_after a JOIN est_before b ON b.visit_id = a.visit_id AND b.visit_date = a.visit_date
   WHERE a.basis IS DISTINCT FROM b.basis AND NOT (b.basis = 'trap_size' AND a.basis = 'measured');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 8: % Calendar estimates changed basis', n; END IF;
  SELECT count(*) INTO n FROM ((SELECT visit_id, visit_date FROM est_after EXCEPT SELECT visit_id, visit_date FROM est_before)
                              UNION ALL (SELECT visit_id, visit_date FROM est_before EXCEPT SELECT visit_id, visit_date FROM est_after)) q;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 8: % Calendar estimate rows appeared or vanished', n; END IF;
  IF (SELECT count(*) FROM est_after) < 50 THEN RAISE EXCEPTION 'VERIFY 8: only % estimate rows: the check proves little', (SELECT count(*) FROM est_after); END IF;
END $v$;
INSERT INTO clk SELECT 'verify_data', clock_timestamp();

-- ---------------------------------------------------------------------------------------------------------------
-- D. The read views, LAST: from here to COMMIT the replaced views are locked (no reader waits through the re-measure
--    or the reads above). Locked top-down first (dq reads svc, svc reads chg), the order a reader locks them in, so
--    a Calendar read cannot interleave into a deadlock. RESET of an unset option takes ACCESS EXCLUSIVE on the view
--    alone and changes nothing (LOCK TABLE on a view would also lock every base table, public.visits included).
-- ---------------------------------------------------------------------------------------------------------------
ALTER VIEW public.v_tank_data_quality_issues RESET (security_barrier);
ALTER VIEW public.v_visit_tank_service RESET (security_barrier);
ALTER VIEW public.v_vehicle_stop_tank_changes RESET (security_barrier);
INSERT INTO clk SELECT 'views_locked', clock_timestamp();
-- columns appended only; every existing column and expression is the live one
CREATE OR REPLACE VIEW public.v_vehicle_stop_tank_changes AS
 SELECT l.id AS vehicle_stop_tank_level_id,
    l.vehicle_stop_id,
    l.vehicle_id,
    l.vehicle_tank_id,
    t.contents,
    l.tank_sensor_installation_id,
    l.vehicle_tank_configuration_id,
    c.capacity_gallons,
    l.arrival_measured_at,
    l.arrival_fill_fraction,
    round(((100)::numeric * l.arrival_fill_fraction), 3) AS arrival_percent,
    round((l.arrival_fill_fraction * c.capacity_gallons), 1) AS arrival_gallons,
    l.departure_measured_at,
    l.departure_fill_fraction,
    round(((100)::numeric * l.departure_fill_fraction), 3) AS departure_percent,
    round((l.departure_fill_fraction * c.capacity_gallons), 1) AS departure_gallons,
    (l.departure_fill_fraction - l.arrival_fill_fraction) AS net_fill_fraction,
    round(((100)::numeric * (l.departure_fill_fraction - l.arrival_fill_fraction)), 3) AS net_percent_points,
    round(((l.departure_fill_fraction - l.arrival_fill_fraction) * c.capacity_gallons), 1) AS net_gallons,
    l.fill_fraction_risen,
    round(((100)::numeric * l.fill_fraction_risen), 3) AS risen_percent_points,
    round((l.fill_fraction_risen * c.capacity_gallons), 1) AS risen_gallons,
    l.fill_fraction_fallen,
    round(((100)::numeric * l.fill_fraction_fallen), 3) AS fallen_percent_points,
    round((l.fill_fraction_fallen * c.capacity_gallons), 1) AS fallen_gallons,
    ((l.fill_fraction_risen IS NULL) AND (l.arrival_fill_fraction IS NOT NULL) AND (l.departure_fill_fraction IS NOT NULL)) AS too_short,
    COALESCE((l.departure_fill_fraction >= 0.98), false) AS at_ceiling,
    l.measurement_count,
    l.rejected_measurement_count,
    l.algorithm_version,
    l.peak_fill_fraction,
    round((l.peak_fill_fraction * c.capacity_gallons), 1) AS peak_gallons,
    l.low_fill_fraction,
    round((l.low_fill_fraction * c.capacity_gallons), 1) AS low_gallons,
    l.departure_basis,
    l.late_change_measured_at,
    l.late_change_fill_fraction,
    round((l.late_change_fill_fraction * c.capacity_gallons), 1) AS late_change_gallons,
    l.ghost_measurement_count
   FROM (((vehicle_stop_tank_levels l
     JOIN vehicle_stops s ON (((s.id = l.vehicle_stop_id) AND (s.superseded_at IS NULL))))
     JOIN vehicle_tanks t ON ((t.id = l.vehicle_tank_id)))
     JOIN vehicle_tank_configurations c ON ((c.id = l.vehicle_tank_configuration_id)))
  WHERE (l.superseded_at IS NULL);

CREATE OR REPLACE VIEW public.v_visit_tank_service AS
 WITH lk AS (
         SELECT l.visit_id,
            l.vehicle_stop_id,
            l.match_basis,
            (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE ((n.client_id = vl.client_id) AND (n.kind = 'dump_site'::text)))) AS is_dump,
            ((vl.service_type = 'Pumping'::text) AND (NOT (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE ((n.client_id = vl.client_id) AND (n.kind = 'dump_site'::text)))))) AS is_volume,
            NULLIF(pp.grease_trap_size_gallons, 0) AS trap
           FROM ((visit_vehicle_stops l
             JOIN v_visits_live vl ON ((vl.id = l.visit_id)))
             LEFT JOIN properties pp ON ((pp.id = vl.property_id)))
          WHERE (l.deleted_at IS NULL)
        ), sh AS (
         SELECT lk.visit_id,
            lk.vehicle_stop_id,
            lk.match_basis,
            lk.is_dump,
            lk.is_volume,
            lk.trap,
                CASE
                    WHEN (NOT lk.is_volume) THEN (0)::numeric
                    WHEN bool_and((COALESCE(lk.trap, 0) > 0)) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id) THEN ((lk.trap)::numeric / (sum(lk.trap) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id))::numeric)
                    ELSE (1.0 / (count(*) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id))::numeric)
                END AS sludge_share,
                CASE
                    WHEN lk.is_dump THEN (0)::numeric
                    ELSE (1.0 / (count(*) FILTER (WHERE (NOT lk.is_dump)) OVER (PARTITION BY lk.vehicle_stop_id))::numeric)
                END AS water_share,
            count(*) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id) AS volume_links_on_stop,
            count(*) OVER (PARTITION BY lk.vehicle_stop_id) AS links_on_stop
           FROM lk
        ), sk AS (
         SELECT sh.visit_id AS k_visit_id,
            sh.vehicle_stop_id AS k_stop_id,
            (((s.departed_at - s.arrived_at) < '00:10:00'::interval) AND COALESCE(bool_or(((s.departed_at - s.arrived_at) >= '00:10:00'::interval)) OVER (PARTITION BY sh.visit_id), false)) AS skip_short
           FROM (sh
             JOIN vehicle_stops s ON ((s.id = sh.vehicle_stop_id)))
        ), v AS (
         SELECT vl.id AS visit_id,
            vl.vehicle_id,
            vl.client_id,
            vl.property_id,
            vl.visit_date,
            vl.completed_at,
            vl.service_type,
            vl.duration_minutes,
            (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE ((n.client_id = vl.client_id) AND (n.kind = 'dump_site'::text)))) AS is_dump,
            NULLIF(pp.grease_trap_size_gallons, 0) AS trap
           FROM (v_visits_live vl
             LEFT JOIN properties pp ON ((pp.id = vl.property_id)))
          WHERE ((vl.visit_status = 'completed'::text) AND (vl.visit_date >= '2026-08-20'::date))
        ), agg AS (
         SELECT v.visit_id AS a_visit_id,
            (count(sh.vehicle_stop_id))::integer AS link_count,
            array_agg(DISTINCT sh.match_basis) FILTER (WHERE (sh.match_basis IS NOT NULL)) AS match_bases,
            sum(f.duration_minutes) AS stop_minutes,
            sum(f.rpm_pump_minutes) AS pump_minutes,
            sum(f.pto_minutes) AS pto_minutes,
            bool_or(f.pump_signature) AS pump_signature,
            bool_or(f.engine_data_present) AS engine_data_present,
            bool_or((sh.links_on_stop > 1)) AS shared_stop,
            bool_or((sh.volume_links_on_stop > 1)) AS shared_volume_stop,
            bool_or((sh.match_basis = 'window'::text)) AS has_window_link,
            min(f.arrived_at) AS first_arrived_at,
            bool_or((ts.vehicle_stop_tank_level_id IS NULL)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_row_missing,
            bool_or(((ts.arrival_fill_fraction IS NULL) OR (ts.departure_fill_fraction IS NULL))) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_edge_missing,
            bool_or(ts.too_short) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_too_short,
            bool_or(ts.at_ceiling) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_at_ceiling,
            sum((sh.sludge_share * ts.net_gallons)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_net,
            sum((sh.sludge_share * ts.risen_gallons)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS sludge_gross,
            bool_or(((tw.vehicle_stop_tank_level_id IS NULL) OR (tw.fill_fraction_fallen IS NULL))) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_incomplete,
            bool_or((tw.capacity_gallons IS NULL)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_capacity_unknown,
            sum((sh.water_share * tw.fill_fraction_fallen)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_used_fraction,
            sum((sh.water_share * tw.fill_fraction_risen)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_refilled_fraction,
            sum((sh.water_share * tw.fallen_gallons)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_used_gal,
            sum((sh.water_share * tw.risen_gallons)) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_refilled_gal,
            (count(*) FILTER (WHERE COALESCE(sk.skip_short, false)))::integer AS short_stops_left_out,
            (array_agg(tw.arrival_gallons ORDER BY f.arrived_at NULLS LAST) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))))[1] AS water_start_gal,
            max(tw.peak_gallons) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))) AS water_peak_gal,
            (array_agg(tw.departure_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))))[1] AS water_end_gal,
            (array_agg(ts.late_change_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))))[1] AS sludge_late_gal,
            (array_agg(tw.late_change_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))))[1] AS water_late_gal,
            COALESCE(bool_or(((ts.departure_basis = 'after_leaving'::text) OR (tw.departure_basis = 'after_leaving'::text))) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))), false) AS after_leaving,
            (COALESCE(sum((COALESCE(ts.ghost_measurement_count, 0) + COALESCE(tw.ghost_measurement_count, 0))) FILTER (WHERE (NOT COALESCE(sk.skip_short, false))), (0)::bigint))::integer AS ghosts_removed
           FROM (((((v
             LEFT JOIN sh ON ((sh.visit_id = v.visit_id)))
             LEFT JOIN v_vehicle_stop_facts f ON ((f.vehicle_stop_id = sh.vehicle_stop_id)))
             LEFT JOIN v_vehicle_stop_tank_changes ts ON (((ts.vehicle_stop_id = sh.vehicle_stop_id) AND (ts.contents = 'sludge'::text))))
             LEFT JOIN v_vehicle_stop_tank_changes tw ON (((tw.vehicle_stop_id = sh.vehicle_stop_id) AND (tw.contents = 'fresh_water'::text))))
             LEFT JOIN sk ON (((sk.k_visit_id = sh.visit_id) AND (sk.k_stop_id = sh.vehicle_stop_id))))
          GROUP BY v.visit_id
        ), x AS (
         SELECT v.visit_id,
            v.vehicle_id,
            v.client_id,
            v.property_id,
            v.visit_date,
            v.completed_at,
            v.service_type,
            v.duration_minutes,
            v.is_dump,
            v.trap,
            agg.a_visit_id,
            agg.link_count,
            agg.match_bases,
            agg.stop_minutes,
            agg.pump_minutes,
            agg.pto_minutes,
            agg.pump_signature,
            agg.engine_data_present,
            agg.shared_stop,
            agg.shared_volume_stop,
            agg.has_window_link,
            agg.first_arrived_at,
            agg.sludge_row_missing,
            agg.sludge_edge_missing,
            agg.sludge_too_short,
            agg.sludge_at_ceiling,
            agg.sludge_net,
            agg.sludge_gross,
            agg.water_incomplete,
            agg.water_capacity_unknown,
            agg.water_used_fraction,
            agg.water_refilled_fraction,
            agg.water_used_gal,
            agg.water_refilled_gal,
            agg.short_stops_left_out,
            agg.water_start_gal,
            agg.water_peak_gal,
            agg.water_end_gal,
            agg.sludge_late_gal,
            agg.water_late_gal,
            agg.after_leaving,
            agg.ghosts_removed,
            ((NOT v.is_dump) AND (v.service_type = 'Pumping'::text)) AS is_volume,
            (EXISTS ( SELECT 1
                   FROM (tank_sensor_installations i
                     JOIN vehicle_tanks vt ON (((vt.id = i.vehicle_tank_id) AND (vt.deleted_at IS NULL))))
                  WHERE ((vt.vehicle_id = v.vehicle_id) AND (vt.contents = 'sludge'::text) AND (i.superseded_at IS NULL) AND (i.installed_at <= COALESCE(agg.first_arrived_at, v.completed_at)) AND (COALESCE(agg.first_arrived_at, v.completed_at) < COALESCE(i.removed_at, 'infinity'::timestamp with time zone))))) AS has_sludge_sensor,
            (EXISTS ( SELECT 1
                   FROM (tank_sensor_installations i
                     JOIN vehicle_tanks vt ON (((vt.id = i.vehicle_tank_id) AND (vt.deleted_at IS NULL))))
                  WHERE ((vt.vehicle_id = v.vehicle_id) AND (vt.contents = 'fresh_water'::text) AND (i.superseded_at IS NULL) AND (i.installed_at <= COALESCE(agg.first_arrived_at, v.completed_at)) AND (COALESCE(agg.first_arrived_at, v.completed_at) < COALESCE(i.removed_at, 'infinity'::timestamp with time zone))))) AS has_water_sensor
           FROM (v
             JOIN agg ON ((agg.a_visit_id = v.visit_id)))
        ), r AS (
         SELECT x.visit_id,
            x.vehicle_id,
            x.client_id,
            x.property_id,
            x.visit_date,
            x.completed_at,
            x.service_type,
            x.duration_minutes,
            x.is_dump,
            x.trap,
            x.a_visit_id,
            x.link_count,
            x.match_bases,
            x.stop_minutes,
            x.pump_minutes,
            x.pto_minutes,
            x.pump_signature,
            x.engine_data_present,
            x.shared_stop,
            x.shared_volume_stop,
            x.has_window_link,
            x.first_arrived_at,
            x.sludge_row_missing,
            x.sludge_edge_missing,
            x.sludge_too_short,
            x.sludge_at_ceiling,
            x.sludge_net,
            x.sludge_gross,
            x.water_incomplete,
            x.water_capacity_unknown,
            x.water_used_fraction,
            x.water_refilled_fraction,
            x.water_used_gal,
            x.water_refilled_gal,
            x.short_stops_left_out,
            x.water_start_gal,
            x.water_peak_gal,
            x.water_end_gal,
            x.sludge_late_gal,
            x.water_late_gal,
            x.after_leaving,
            x.ghosts_removed,
            x.is_volume,
            x.has_sludge_sensor,
            x.has_water_sensor,
                CASE
                    WHEN (NOT x.is_volume) THEN 'not_a_volume_visit'::text
                    WHEN (NOT x.has_sludge_sensor) THEN 'no_sensor'::text
                    WHEN (x.link_count = 0) THEN 'no_stop'::text
                    WHEN x.sludge_row_missing THEN 'no_config'::text
                    WHEN x.sludge_edge_missing THEN 'edge_missing'::text
                    WHEN ((x.trap IS NOT NULL) AND (x.sludge_net > ((1.5 * (x.trap)::numeric) + (40)::numeric))) THEN 'exceeds_trap_size'::text
                    WHEN x.sludge_too_short THEN 'too_short'::text
                    WHEN (x.trap <= 75) THEN 'below_resolution'::text
                    WHEN x.sludge_at_ceiling THEN 'tank_at_ceiling'::text
                    WHEN ((x.sludge_net < (40)::numeric) AND COALESCE(x.pump_signature, false)) THEN 'pumped_no_rise'::text
                    WHEN ((x.sludge_net >= (40)::numeric) AND x.engine_data_present AND (NOT COALESCE(x.pump_signature, false))) THEN 'rise_without_pump'::text
                    WHEN (x.trap IS NULL) THEN 'trap_size_unknown'::text
                    WHEN x.has_window_link THEN 'window_match'::text
                    WHEN x.shared_volume_stop THEN 'shared_stop_allocated'::text
                    WHEN (NOT COALESCE(x.engine_data_present, false)) THEN 'no_pump_signal'::text
                    ELSE 'ok'::text
                END AS sludge_reason
           FROM x
        )
 SELECT visit_id,
    vehicle_id,
    client_id,
    property_id,
    visit_date,
    completed_at,
    service_type,
        CASE
            WHEN is_dump THEN 'dump'::text
            WHEN is_volume THEN 'volume'::text
            ELSE 'other'::text
        END AS visit_kind,
    link_count,
    match_bases,
    shared_stop,
    stop_minutes,
    duration_minutes,
    ((stop_minutes IS NOT NULL) AND (duration_minutes IS NOT NULL) AND (abs((stop_minutes - (duration_minutes)::numeric)) > (15)::numeric)) AS time_on_site_disagreement,
    pump_minutes,
    pto_minutes,
    pump_signature,
    engine_data_present,
        CASE
            WHEN (sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text])) THEN NULL::numeric
            ELSE round(sludge_net, 1)
        END AS sludge_collected_gallons,
        CASE
            WHEN (sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text])) THEN NULL::numeric
            ELSE round(sludge_gross, 1)
        END AS sludge_gross_intake_gallons,
        CASE
            WHEN (sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text])) THEN 'none'::text
            WHEN (sludge_reason = ANY (ARRAY['too_short'::text, 'below_resolution'::text, 'tank_at_ceiling'::text, 'exceeds_trap_size'::text, 'pumped_no_rise'::text, 'rise_without_pump'::text])) THEN 'low'::text
            WHEN (sludge_reason = 'ok'::text) THEN 'high'::text
            ELSE 'medium'::text
        END AS sludge_confidence,
    sludge_reason,
        CASE
            WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete) THEN NULL::numeric
            ELSE round(((100)::numeric * water_used_fraction), 1)
        END AS water_used_percent_points,
        CASE
            WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete) THEN NULL::numeric
            ELSE round(((100)::numeric * water_refilled_fraction), 1)
        END AS water_refilled_percent_points,
        CASE
            WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric
            ELSE round(water_used_gal, 1)
        END AS water_used_gallons,
        CASE
            WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric
            ELSE round(water_refilled_gal, 1)
        END AS water_refilled_gallons,
        CASE
            WHEN ((NOT has_water_sensor) OR (link_count = 0) OR water_incomplete) THEN 'none'::text
            ELSE 'low'::text
        END AS water_confidence,
        CASE
            WHEN (NOT has_water_sensor) THEN 'no_sensor'::text
            WHEN (link_count = 0) THEN 'no_stop'::text
            WHEN water_incomplete THEN 'measurement_missing'::text
            WHEN water_capacity_unknown THEN 'percent_only'::text
            ELSE 'unvalidated'::text
        END AS water_reason,
    short_stops_left_out,
        CASE WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric ELSE round(water_start_gal, 1) END AS water_start_gallons,
        CASE WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric ELSE round(water_peak_gal, 1) END AS water_peak_gallons,
        CASE WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric ELSE round(water_end_gal, 1) END AS water_end_gallons,
        CASE WHEN ((link_count = 0) OR (NOT has_sludge_sensor)) THEN NULL::numeric ELSE round(sludge_late_gal, 1) END AS sludge_change_after_leaving_gallons,
        CASE WHEN ((link_count = 0) OR (NOT has_water_sensor) OR water_incomplete OR water_capacity_unknown) THEN NULL::numeric ELSE round(water_late_gal, 1) END AS water_change_after_leaving_gallons,
    after_leaving AS departure_after_leaving,
    ghosts_removed AS ghost_readings_removed
   FROM r;

CREATE OR REPLACE VIEW public.v_tank_data_quality_issues AS
 WITH gps_vehicle AS (
         SELECT e.entity_id AS vehicle_id
           FROM entity_source_links e
          WHERE ((e.entity_type = 'vehicle'::text) AND (e.source_system = 'samsara'::text))
        ), sv AS (
         SELECT v_visit_tank_service.visit_id,
            v_visit_tank_service.vehicle_id,
            v_visit_tank_service.client_id,
            v_visit_tank_service.property_id,
            v_visit_tank_service.visit_date,
            v_visit_tank_service.completed_at,
            v_visit_tank_service.service_type,
            v_visit_tank_service.visit_kind,
            v_visit_tank_service.link_count,
            v_visit_tank_service.match_bases,
            v_visit_tank_service.shared_stop,
            v_visit_tank_service.stop_minutes,
            v_visit_tank_service.duration_minutes,
            v_visit_tank_service.time_on_site_disagreement,
            v_visit_tank_service.pump_minutes,
            v_visit_tank_service.pto_minutes,
            v_visit_tank_service.pump_signature,
            v_visit_tank_service.engine_data_present,
            v_visit_tank_service.sludge_collected_gallons,
            v_visit_tank_service.sludge_gross_intake_gallons,
            v_visit_tank_service.sludge_confidence,
            v_visit_tank_service.sludge_reason,
            v_visit_tank_service.water_used_percent_points,
            v_visit_tank_service.water_refilled_percent_points,
            v_visit_tank_service.water_used_gallons,
            v_visit_tank_service.water_refilled_gallons,
            v_visit_tank_service.water_confidence,
            v_visit_tank_service.water_reason
           FROM v_visit_tank_service
        )
 SELECT 'F1'::text AS issue_code,
    'pumping_visit_without_stop'::text AS issue,
    'business_flag'::text AS severity,
    sv.vehicle_id,
    sv.visit_id,
    NULL::bigint AS vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    (((('completed '::text || sv.service_type) || ' visit of '::text) || sv.visit_date) || ' has no stop of its truck linked'::text) AS detail
   FROM sv
  WHERE ((sv.visit_kind = 'volume'::text) AND (sv.link_count = 0) AND (sv.vehicle_id IN ( SELECT gps_vehicle.vehicle_id
           FROM gps_vehicle)))
UNION ALL
 SELECT 'F1b'::text AS issue_code,
    'dump_visit_without_dump_stop'::text AS issue,
    'business_flag'::text AS severity,
    sv.vehicle_id,
    sv.visit_id,
    NULL::bigint AS vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
        CASE
            WHEN (( SELECT count(*) AS count
               FROM (v_vehicle_dumps dd
                 JOIN properties sp ON ((sp.id = dd.site_property_id)))
              WHERE ((dd.vehicle_id = sv.vehicle_id) AND (sp.client_id = sv.client_id) AND (dd.dump_visit_id IS NULL) AND (dd.arrived_at >= (((sv.visit_date)::timestamp without time zone AT TIME ZONE 'America/New_York'::text) - '04:00:00'::interval)) AND (dd.arrived_at < ((((sv.visit_date + 1))::timestamp without time zone + '10:00:00'::interval) AT TIME ZONE 'America/New_York'::text)))) > 1) THEN 'ambiguous: several unlinked dump stops of its site in its window'::text
            ELSE 'none: no unlinked dump stop of its site in its window'::text
        END AS detail
   FROM sv
  WHERE ((sv.visit_kind = 'dump'::text) AND (sv.vehicle_id IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM visit_vehicle_stops l
          WHERE ((l.visit_id = sv.visit_id) AND (l.deleted_at IS NULL) AND (l.match_basis = ANY (ARRAY['dump_completion'::text, 'dump_window'::text])))))))
UNION ALL
 SELECT 'F2'::text AS issue_code,
    'unlinked_work'::text AS issue,
    'business_flag'::text AS severity,
    f.vehicle_id,
    NULL::bigint AS visit_id,
    f.vehicle_stop_id,
    COALESCE(f.nearest_property_id, ( SELECT pp.id
           FROM properties pp
          WHERE ((pp.deleted_at IS NULL) AND (COALESCE(pp.is_billing, false) = false) AND ((pp.latitude >= (f.latitude - 0.003)) AND (pp.latitude <= (f.latitude + 0.003))) AND ((pp.longitude >= (f.longitude - 0.0035)) AND (pp.longitude <= (f.longitude + 0.0035))) AND (ops.fn_haversine_km(pp.latitude, pp.longitude, f.latitude, f.longitude) <= 0.3))
          ORDER BY (ops.fn_haversine_km(pp.latitude, pp.longitude, f.latitude, f.longitude)), pp.id
         LIMIT 1)) AS nearest_property_id,
    (('stop rose '::text || round(tc.net_gallons)) || ' gal with a pump signature and no Pumping visit linked'::text) AS detail
   FROM (v_vehicle_stop_facts f
     JOIN v_vehicle_stop_tank_changes tc ON (((tc.vehicle_stop_id = f.vehicle_stop_id) AND (tc.contents = 'sludge'::text))))
  WHERE ((f.kind = ANY (ARRAY['client'::text, 'other'::text])) AND (tc.net_gallons >= (40)::numeric) AND f.pump_signature AND (NOT (EXISTS ( SELECT 1
           FROM (visit_vehicle_stops l
             JOIN v_visits_live vl ON ((vl.id = l.visit_id)))
          WHERE ((l.vehicle_stop_id = f.vehicle_stop_id) AND (l.deleted_at IS NULL) AND (vl.service_type = 'Pumping'::text) AND (NOT (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE ((n.client_id = vl.client_id) AND (n.kind = 'dump_site'::text))))))))))
UNION ALL
 SELECT 'F3'::text AS issue_code,
    'dump_without_record'::text AS issue,
    'business_flag'::text AS severity,
    dd.vehicle_id,
    NULL::bigint AS visit_id,
    dd.vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    'dump stop with no Dump Offload visit linked'::text AS detail
   FROM v_vehicle_dumps dd
  WHERE (dd.dump_visit_id IS NULL)
UNION ALL
 SELECT 'F4'::text AS issue_code,
    'dump_ratio_out_of_band'::text AS issue,
    'business_flag'::text AS severity,
    dd.vehicle_id,
    dd.dump_visit_id AS visit_id,
    dd.vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    ((((('offload '::text || round(dd.offload_gallons)) || ' gal vs collected '::text) || round(dd.collected_since_previous_dump_gallons)) || ' gal since the previous dump: ratio '::text) || dd.ratio) AS detail
   FROM v_vehicle_dumps dd
  WHERE ((dd.ratio IS NOT NULL) AND ((dd.ratio < 0.75) OR (dd.ratio > 1.25)))
UNION ALL
 SELECT 'F5'::text AS issue_code,
    'large_drop_not_at_dump'::text AS issue,
    'business_flag'::text AS severity,
    f.vehicle_id,
    NULL::bigint AS visit_id,
    f.vehicle_stop_id,
    f.nearest_property_id,
    (((f.kind || ' stop fell '::text) || round((- tc.net_gallons))) || ' gal'::text) AS detail
   FROM (v_vehicle_stop_facts f
     JOIN v_vehicle_stop_tank_changes tc ON (((tc.vehicle_stop_id = f.vehicle_stop_id) AND (tc.contents = 'sludge'::text))))
  WHERE ((f.kind <> 'dump'::text) AND (tc.net_gallons <= ('-300'::integer)::numeric))
UNION ALL
 SELECT 'F6'::text AS issue_code,
    'possible_wrong_truck'::text AS issue,
    'business_flag'::text AS severity,
    sv.vehicle_id,
    sv.visit_id,
    o.vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    (((('truck '::text || o.vehicle_id) || ' stopped within 150 m at '::text) || to_char((o.arrived_at AT TIME ZONE 'America/New_York'::text), 'YYYY-MM-DD HH24:MI'::text)) || ' ET'::text) AS detail
   FROM ((sv
     JOIN properties vp ON (((vp.id = sv.property_id) AND (vp.latitude IS NOT NULL))))
     CROSS JOIN LATERAL ( SELECT f.vehicle_stop_id,
            f.vehicle_id,
            f.arrived_at
           FROM (v_vehicle_stop_facts f
             LEFT JOIN v_vehicle_stop_tank_changes tc ON (((tc.vehicle_stop_id = f.vehicle_stop_id) AND (tc.contents = 'sludge'::text))))
          WHERE ((f.vehicle_id <> sv.vehicle_id) AND (f.site_property_id IS NULL) AND (f.arrived_at >= (((sv.visit_date)::timestamp without time zone AT TIME ZONE 'America/New_York'::text) - '04:00:00'::interval)) AND (f.arrived_at < ((((sv.visit_date + 1))::timestamp without time zone + '10:00:00'::interval) AT TIME ZONE 'America/New_York'::text)) AND (ops.fn_haversine_km(vp.latitude, vp.longitude, f.latitude, f.longitude) <= 0.15) AND ((COALESCE(tc.net_gallons, (0)::numeric) >= (40)::numeric) OR f.pump_signature))
          ORDER BY f.arrived_at
         LIMIT 1) o)
  WHERE ((sv.visit_kind <> 'dump'::text) AND (sv.link_count = 0) AND (sv.vehicle_id IS NOT NULL))
UNION ALL
 SELECT 'F7'::text AS issue_code,
    'time_on_site_disagreement'::text AS issue,
    'business_flag'::text AS severity,
    sv.vehicle_id,
    sv.visit_id,
    NULL::bigint AS vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    ((('stops '::text || round(sv.stop_minutes)) || ' min vs duration_minutes '::text) || sv.duration_minutes) AS detail
   FROM sv
  WHERE sv.time_on_site_disagreement
UNION ALL
 SELECT 'F8'::text AS issue_code,
    'capacity_mismatch'::text AS issue,
    'business_flag'::text AS severity,
    ve.id AS vehicle_id,
    NULL::bigint AS visit_id,
    NULL::bigint AS vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    ((((('vehicles.grease_tank_capacity_gallons '::text || COALESCE((ve.grease_tank_capacity_gallons)::text, 'NULL'::text)) || ' vs '::text) || c.capacity_gallons) || ' in force. Editing vehicles rewrites past LWT rows '::text) || '(derm.v_lwt_monthly_rows reads it live): owner approval needed (D10)'::text) AS detail
   FROM ((vehicles ve
     JOIN vehicle_tanks vt ON (((vt.vehicle_id = ve.id) AND (vt.contents = 'sludge'::text) AND (vt.deleted_at IS NULL))))
     JOIN LATERAL ( SELECT c_1.capacity_gallons
           FROM vehicle_tank_configurations c_1
          WHERE ((c_1.vehicle_tank_id = vt.id) AND (c_1.superseded_at IS NULL) AND (c_1.effective_from <= now()))
          ORDER BY c_1.effective_from DESC
         LIMIT 1) c ON (true))
  WHERE (ve.grease_tank_capacity_gallons IS DISTINCT FROM c.capacity_gallons)
UNION ALL
 SELECT 'F9'::text AS issue_code,
    'unlisted_repeating_distance'::text AS issue,
    'sensor_flag'::text AS severity,
    x.vehicle_id,
    NULL::bigint AS visit_id,
    NULL::bigint AS vehicle_stop_id,
    NULL::bigint AS nearest_property_id,
    ((((((((x.contents || ' sensor read '::text) || x.d) || ' m as a one-reading jump '::text) || x.n) || ' times in 14 days ('::text) || x.total) || ' readings at that distance): possibly a new false reading; if it is, add it to fn_tank_ghost_distance_listed and bump the measuring version'::text)) AS detail
   FROM ( SELECT vt.vehicle_id, vt.contents, m.d,
            count(*) FILTER (WHERE m.jump) AS n, count(*) AS total
           FROM ((( SELECT r.tank_sensor_id, r.d,
                    ((abs((r.d - r.pd)) > 0.10) AND (abs((r.d - r.nd)) > 0.10) AND (abs((r.pd - r.nd)) <= 0.10)) AS jump
                   FROM ( SELECT c.tank_sensor_id, c.d,
                            lag(c.d) OVER (PARTITION BY c.tank_sensor_id ORDER BY c.recorded_at) AS pd,
                            lead(c.d) OVER (PARTITION BY c.tank_sensor_id ORDER BY c.recorded_at) AS nd
                           FROM ( SELECT q_1.tank_sensor_id, q_1.distance_meters AS d, q_1.recorded_at,
                                    lag(q_1.distance_meters) OVER (PARTITION BY q_1.tank_sensor_id ORDER BY q_1.recorded_at) AS prev
                                   FROM tank_sensor_distance_readings q_1
                                  WHERE ((q_1.recorded_at > (now() - '14 days'::interval)) AND (q_1.distance_meters > (0)::numeric))) c
                          WHERE (c.prev IS DISTINCT FROM c.d)) r) m
             JOIN tank_sensor_installations i ON (((i.tank_sensor_id = m.tank_sensor_id) AND (i.superseded_at IS NULL) AND (i.removed_at IS NULL))))
             JOIN vehicle_tanks vt ON ((vt.id = i.vehicle_tank_id)))
          WHERE ((NOT fn_tank_ghost_distance_listed(vt.contents, m.d))
                 AND (NOT ((vt.contents = 'sludge'::text) AND ((m.d >= 2.09) OR (m.d <= 0.11)))))   -- false empty / false full: deliberately not listed
          GROUP BY vt.vehicle_id, vt.contents, m.d
         HAVING ((count(*) FILTER (WHERE m.jump) >= 5) AND ((count(*) FILTER (WHERE m.jump))::numeric >= (0.25 * (count(*))::numeric)))) x;

-- ---------------------------------------------------------------------------------------------------------------
-- E. The water balance per visit (Fred's model) and the water ledger per stop
-- ---------------------------------------------------------------------------------------------------------------
CREATE VIEW public.v_visit_water_balance AS
SELECT t.visit_id, t.vehicle_id, t.client_id, t.property_id, t.visit_date, t.visit_kind, t.shared_stop, t.link_count,
       t.water_start_gallons,
       CASE WHEN t.visit_kind = 'volume' THEN t.water_refilled_gallons END AS water_separated_gallons,
       t.water_peak_gallons,
       CASE WHEN t.visit_kind = 'volume' THEN t.water_used_gallons END AS water_put_back_gallons,
       t.water_end_gallons,
       CASE WHEN t.visit_kind = 'volume' THEN greatest(t.water_used_gallons - t.water_refilled_gallons, 0) END
         AS water_brought_in_at_least_gallons,
       CASE WHEN t.visit_kind = 'volume' THEN greatest(t.water_refilled_gallons - t.water_used_gallons, 0) END
         AS water_left_in_truck_at_least_gallons,
       -- a dump stop's water is not shared out by v_visit_tank_service (its share is 0), so take the stop's own fall
       CASE WHEN t.visit_kind = 'dump' THEN
         (SELECT round(sum(c.fallen_gallons), 1) FROM public.visit_vehicle_stops l
            JOIN public.v_vehicle_stop_tank_changes c ON c.vehicle_stop_id = l.vehicle_stop_id AND c.contents = 'fresh_water'
           WHERE l.visit_id = t.visit_id AND l.deleted_at IS NULL) END AS water_pumped_out_at_dump_gallons,
       t.sludge_collected_gallons AS grease_kept_gallons,
       t.sludge_confidence AS grease_confidence,
       t.sludge_change_after_leaving_gallons,
       t.water_change_after_leaving_gallons,
       t.departure_after_leaving,
       (t.water_peak_gallons >= 0.95 * wc.capacity_gallons) AS water_tank_full,
       (t.visit_kind = 'volume' AND t.sludge_collected_gallons >= 200 AND t.water_refilled_gallons < 25)
         AS no_water_separated,
       -- start + separated - put back = end, within the water hysteresis (0.05 of 1,200 gal: the zig-zag ignores
       -- smaller swings). Pumping visits only; NULL when a figure is missing. False on a visit split by another
       -- client's stop (6218) or sharing its stop (the stop's water is shared out, its start and end are not).
       CASE WHEN t.visit_kind = 'volume' THEN
         abs(t.water_start_gallons + t.water_refilled_gallons - t.water_used_gallons - t.water_end_gallons)
           <= 0.05 * wc.capacity_gallons + 1 END AS water_balance_closes,
       CASE WHEN t.visit_kind = 'volume' THEN
         round(t.water_end_gallons - (t.water_start_gallons + t.water_refilled_gallons - t.water_used_gallons), 1) END
         AS water_unexplained_gallons,
       t.ghost_readings_removed,
       t.water_confidence,
       t.water_reason
  FROM public.v_visit_tank_service t
  LEFT JOIN LATERAL (
    SELECT c.capacity_gallons
      FROM public.vehicle_tanks vt
      JOIN public.vehicle_tank_configurations c ON c.vehicle_tank_id = vt.id AND c.superseded_at IS NULL
     WHERE vt.vehicle_id = t.vehicle_id AND vt.contents = 'fresh_water' AND vt.deleted_at IS NULL
       AND c.effective_from <= coalesce(t.completed_at, now())
     ORDER BY c.effective_from DESC NULLS LAST LIMIT 1) wc ON true
 WHERE t.water_reason <> 'no_sensor';

COMMENT ON VIEW public.v_visit_water_balance IS
'Fred''s water model per completed visit of a truck with a water sensor (Moises since 2026-10-02): start + separated = peak; peak - put back = end (water_balance_closes, water_unexplained_gallons). Separated and put back are sums of every rise and fall during the visit (several cycles are common), so they are lower bounds at the sensor''s 10-minute pace; they are given for pumping visits (visit_kind volume) only. Put-back water counts for the visit whose trap it went into; brought_in_at_least / left_in_truck_at_least are bounds that need no rule about whose water is whose. A dump visit only pumps water out. Flags only: water_tank_full (separation capped), no_water_separated (the grease number holds water), the change after leaving. Built on v_visit_tank_service (same stops). Service role only; not for filings. Design: docs/superpowers/specs/2026-10-15-moises-water-balance-design.md.';

CREATE VIEW public.v_vehicle_water_ledger AS
WITH s AS (
  SELECT c.vehicle_stop_id, c.vehicle_id, st.arrived_at, st.departed_at,
         CASE (SELECT min(nc.kind) FROM public.properties sp
                 JOIN public.non_customer_clients nc ON nc.client_id = sp.client_id AND nc.kind IN ('dump_site', 'yard')
                WHERE sp.id = st.site_property_id)
           WHEN 'dump_site' THEN 'dump'
           WHEN 'yard' THEN 'yard'
           ELSE CASE WHEN EXISTS (SELECT 1 FROM public.visit_vehicle_stops l
                                   WHERE l.vehicle_stop_id = c.vehicle_stop_id AND l.deleted_at IS NULL)
                     THEN 'client' ELSE 'other' END
         END AS stop_kind,
         c.arrival_measured_at, c.arrival_gallons, c.peak_gallons, c.low_gallons,
         c.departure_measured_at, c.departure_gallons, c.risen_gallons, c.fallen_gallons,
         c.departure_basis, c.late_change_gallons, c.ghost_measurement_count
    FROM public.v_vehicle_stop_tank_changes c
    JOIN public.vehicle_stops st ON st.id = c.vehicle_stop_id AND st.superseded_at IS NULL
   WHERE c.contents = 'fresh_water'
)
SELECT s.*,
       CASE WHEN s.stop_kind = 'client' THEN s.risen_gallons END AS separated_gallons,
       CASE WHEN s.stop_kind = 'client' THEN s.fallen_gallons END AS put_back_gallons,
       CASE WHEN s.stop_kind = 'yard' THEN s.risen_gallons END AS refilled_gallons,
       CASE WHEN s.stop_kind IN ('yard', 'dump') THEN s.fallen_gallons END AS pumped_out_gallons,
       s.arrival_gallons - lag(s.departure_gallons) OVER (PARTITION BY s.vehicle_id ORDER BY s.arrived_at)
         AS change_since_previous_stop_gallons
  FROM s;

COMMENT ON VIEW public.v_vehicle_water_ledger IS
'Every stop of a truck with a water sensor, in order: the water tank at arrival, peak, low and departure, and what the rises and falls were. At a client: separated / put back (Fred''s model). At the yard (the office): refilled / pumped out (Fred: refills are "usually at the office"). At a dump: pumped out (Fred: "we only dump the grease"; measured 2026-10-16, the water tank still fell at 4 of 9 dumps, destination unknown). change_since_previous_stop_gallons closes the ledger between stops (measured: no separation on the road). Service role only.';

-- Supabase's default privileges hand every new view full rights BY NAME (anon, authenticated AND service_role
-- arwdDxtm): revoke by name, then grant read only, matching v_visit_tank_service (postgres, db_backup_reader r,
-- service_role r).
REVOKE ALL ON public.v_visit_water_balance, public.v_vehicle_water_ledger FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.v_visit_water_balance, public.v_vehicle_water_ledger TO service_role;

INSERT INTO clk SELECT 'views', clock_timestamp();

-- ---------------------------------------------------------------------------------------------------------------
-- VERIFY, part 2 (the views; cheap reads only, the replaced views are locked until COMMIT)
-- ---------------------------------------------------------------------------------------------------------------
DO $v$
DECLARE
  n int;  x numeric;  y numeric;
BEGIN
  -- 3. privileges and options: the replaced views keep their ACLs and options; the new views copy
  --    v_visit_tank_service's ACL; nothing new is reachable by anon or authenticated
  IF (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_visit_tank_service'::regclass) IS DISTINCT FROM (SELECT svc_acl FROM chk_before)
     OR (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_vehicle_stop_tank_changes'::regclass) IS DISTINCT FROM (SELECT chg_acl FROM chk_before)
     OR (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_tank_data_quality_issues'::regclass) IS DISTINCT FROM (SELECT dq_acl FROM chk_before)
     OR (SELECT array_agg(c.relname || '=' || coalesce(c.reloptions::text, '')) FROM pg_class c
          WHERE c.oid IN ('public.v_visit_tank_service'::regclass, 'public.v_vehicle_stop_tank_changes'::regclass,
                          'public.v_tank_data_quality_issues'::regclass)) IS DISTINCT FROM (SELECT relopts FROM chk_before)
     OR (SELECT array_agg(ai::text ORDER BY ai::text) FROM pg_class c, unnest(c.relacl) ai WHERE c.oid = 'public.v_visit_water_balance'::regclass)
        IS DISTINCT FROM (SELECT array_agg(ai::text ORDER BY ai::text) FROM pg_class c, unnest(c.relacl) ai WHERE c.oid = 'public.v_visit_tank_service'::regclass)
     OR (SELECT array_agg(ai::text ORDER BY ai::text) FROM pg_class c, unnest(c.relacl) ai WHERE c.oid = 'public.v_vehicle_water_ledger'::regclass)
        IS DISTINCT FROM (SELECT array_agg(ai::text ORDER BY ai::text) FROM pg_class c, unnest(c.relacl) ai WHERE c.oid = 'public.v_visit_tank_service'::regclass)
  THEN RAISE EXCEPTION 'VERIFY 3: an ACL or a view option is not what it should be'; END IF;
  IF has_table_privilege('anon', 'public.v_visit_water_balance', 'SELECT') OR has_table_privilege('authenticated', 'public.v_visit_water_balance', 'SELECT')
     OR has_table_privilege('anon', 'public.v_vehicle_water_ledger', 'SELECT') OR has_table_privilege('authenticated', 'public.v_vehicle_water_ledger', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_visit_water_balance', 'SELECT')
     OR has_table_privilege('service_role', 'public.v_visit_water_balance', 'INSERT')
  THEN RAISE EXCEPTION 'VERIFY 3: a view privilege is not what it should be'; END IF;
  -- the data-quality view's new arm (it calls fn_tank_ghost_distance_listed) and the new views read as service_role.
  -- Kept cheap (the replaced views are locked until COMMIT): the F9 arm only, one row of each new view. A full read
  -- of every view as service_role runs right after COMMIT.
  EXECUTE 'SET LOCAL ROLE service_role';
  SELECT count(*) INTO n FROM public.v_tank_data_quality_issues WHERE issue_code = 'F9';
  PERFORM 1 FROM public.v_visit_water_balance LIMIT 1;
  PERFORM 1 FROM public.v_vehicle_water_ledger LIMIT 1;
  EXECUTE 'RESET ROLE';
  IF n <> 0 THEN RAISE NOTICE 'VERIFY 10: F9 reports % distances today', n; END IF;

  -- 3b. the replaced views show the rows the data checks read (the appended columns read the table)
  SELECT count(*) INTO n
    FROM (SELECT * FROM public.v_vehicle_stop_tank_changes WHERE vehicle_id = 1) c
    FULL JOIN lvl_after a ON a.vehicle_stop_tank_level_id = c.vehicle_stop_tank_level_id
   WHERE c.vehicle_stop_tank_level_id IS NULL OR a.vehicle_stop_tank_level_id IS NULL
      OR c.peak_gallons IS DISTINCT FROM a.peak_gallons OR c.departure_basis IS DISTINCT FROM a.departure_basis
      OR c.late_change_gallons IS DISTINCT FROM a.late_change_gallons OR c.departure_gallons IS DISTINCT FROM a.departure_gallons;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: % rows of the replaced changes view differ from the data checked', n; END IF;
  SELECT count(*) INTO n FROM public.v_visit_tank_service s JOIN svc_after a USING (visit_id)
   WHERE s.sludge_collected_gallons IS DISTINCT FROM a.sludge_collected_gallons OR s.water_used_gallons IS DISTINCT FROM a.water_used_gallons
      OR s.sludge_reason IS DISTINCT FROM a.sludge_reason OR s.visit_kind IS DISTINCT FROM a.visit_kind;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: % visits read differently through the replaced service view', n; END IF;

  -- 9. the water balance closes on every single-stop pumping visit not sharing its stop (start + separated - put
  --    back = end within the water hysteresis), and enough visits are checked for that to mean something
  SELECT count(*) INTO n FROM public.v_visit_water_balance w
   WHERE w.link_count = 1 AND NOT w.shared_stop AND w.visit_kind = 'volume' AND w.water_balance_closes IS FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 9: % single-stop visits do not close', n; END IF;
  SELECT count(*) INTO n FROM public.v_visit_water_balance w
   WHERE w.link_count = 1 AND NOT w.shared_stop AND w.visit_kind = 'volume' AND w.water_balance_closes;
  IF n < 20 THEN RAISE EXCEPTION 'VERIFY 9: only % single-stop visits with a water balance: the check proves little', n; END IF;
  -- 9b. a dump visit's water pumped out is its stop's own fall (8725, dump stop 1213: about 863 gal)
  SELECT w.water_pumped_out_at_dump_gallons, (SELECT sum(l.pumped_out_gallons) FROM public.v_vehicle_water_ledger l WHERE l.vehicle_stop_id = 1213)
    INTO x, y FROM public.v_visit_water_balance w WHERE w.visit_id = 8725;
  IF x IS NULL OR x IS DISTINCT FROM y OR x < 500 THEN RAISE EXCEPTION 'VERIFY 9b: 8725 dump water % vs ledger %', x, y; END IF;

  -- 10. F9 (a new false-reading distance): reported, not refused (a person decides whether to list it); and its
  --     counting finds the listed water echo when the list filter is lifted (positive control)
  SELECT count(*) INTO n FROM (
    SELECT m.d FROM (SELECT r.tank_sensor_id, r.d,
                            abs(r.d - r.pd) > 0.10 AND abs(r.d - r.nd) > 0.10 AND abs(r.pd - r.nd) <= 0.10 AS jump
                       FROM (SELECT c.tank_sensor_id, c.d, lag(c.d) OVER w AS pd, lead(c.d) OVER w AS nd
                               FROM (SELECT q.tank_sensor_id, q.distance_meters AS d, q.recorded_at,
                                            lag(q.distance_meters) OVER (PARTITION BY q.tank_sensor_id ORDER BY q.recorded_at) AS prev
                                       FROM public.tank_sensor_distance_readings q
                                      WHERE q.recorded_at > now() - interval '14 days' AND q.distance_meters > 0) c
                              WHERE c.prev IS DISTINCT FROM c.d
                             WINDOW w AS (PARTITION BY c.tank_sensor_id ORDER BY c.recorded_at)) r) m
     WHERE m.tank_sensor_id = 2 AND m.d BETWEEN 1.13 AND 1.15
     GROUP BY m.d HAVING count(*) FILTER (WHERE m.jump) >= 5) q;
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY 10: control failed: the F9 counting does not even find the 1.14 m water echo'; END IF;
END $v$;
INSERT INTO clk SELECT 'verify_views', clock_timestamp();

NOTIFY pgrst, 'reload schema';
COMMIT;
