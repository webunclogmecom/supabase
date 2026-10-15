-- ============================================================================
-- 2026-10-15_1300 Tank read model: edges taken parked at the stop, short stops, impossible gains first
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15: "Go ahead ... 9", on the tank findings of the read-only audit of 2026-10-15 (the audit files
--   name clients, so they stay outside the repos: samsara-checks/audit_2026-10-15/tanks/; its JS port of
--   fn_measure_vehicle_stop_tank_levels v1 reproduced our 50 stop rows of 2026-10-12..14 exactly).
--
-- WHAT WAS WRONG (Moises, the only truck with level sensors)
--   1. fn_measure_vehicle_stop_tank_levels v1 used edge readings taken while the truck was MOVING: across 13 visits,
--      5 sludge arrival and 6 departure edges, up to 48 mph (6419's water arrival at 64.6 mph). Visit 7019 read net 0
--      from a departure taken at 10.6 mph while its parked readings rose about 183 gal. Discovery trap 8: only parked
--      readings are levels (the tank sloshes).
--   2. A reading taken parked at the NEXT client leaked into the previous stop's departure edge: 6261 / 7873, the
--      04:23:12Z reading, 3 s after the truck stopped at the next client, 195 m from 6261's stop, fell inside v1's
--      11-minute departure window because our next stop only starts 62 s later. About 112 gal moved from 7873 to 6261.
--   3. v_visit_tank_service: a completion_chain stop under 10 min (links shipped 2026-10-13_2210) made the whole visit
--      too_short and blanked its water (7873, 6666, 6721), although the stop-level rows were right. All 13 too_short
--      Moises visits since 08-20 had a chain link.
--   4. v_visit_tank_service checked below_resolution (trap 75 gal or less) before exceeds_trap_size: 12 visits read
--      below_resolution while net > 1.5 x trap + 40 (6252: 2,819.5 gal on a 30 gal trap).
--
-- WHAT CHANGES
--   A. fn_measure_vehicle_stop_tank_levels v2. Same signature and parameters (the cron's call is unchanged); c_version
--      2, so every live v1 row becomes a Z3 pair whatever its age, and part C re-measures Moises's whole era. A
--      measurement can be an EDGE of a client stop only when
--        (i) the truck was stationary at it: every GPS fix from the last one 10 s or more before the reading to the
--            first one at or after it lies within 15 m of that first one (about 3 mph or more is moving; the GPS writer
--            stores no speed, 0 of 156,649 Moises fixes), and that fix is within 100 m of the stop's centre, so a
--            reading taken at the previous or the next stop never counts; or
--        (ii) its value was held, up to the next accepted measurement, for a full period (11 min) inside the stop
--            window, so the sensor re-measured it parked there. A flat level first seen on the road keeps its
--            first-seen time: 6419's water arrival stays 02:33:13Z (64.6 mph) because the same value held to 02:53:13Z,
--            11.4 min into the stop.
--      The arrival edge's fallback window now also ends at the next stop's arrival (the departure window already did).
--      Dump and yard stops (site_property_id set) keep the v1 edges: their extent is a geofence up to 1.4 km across,
--      and the level before tipping is only seen on the way in. Measured in a rolled-back run: the rule applied to
--      them turned 10 of the 26 Moises dumps edge_missing or implausible.
--      Why 10 s / 15 m: over Moises readings since 08-20, 97.5% of those taken 5+ min inside a client stop pass and
--      11% of those taken between stops do (traffic lights). Against Samsara's own GPS speed on the 143 audited
--      readings, 135 agree with "under 2 mph"; 7 more are excluded (the truck had moved in the 10 s before), 1 passes
--      at 8.7 mph after a 34 s GPS gap (it is 1.4 km from that stop, so the 100 m rule drops it).
--      Thresholds are constants in the body (c_settle, c_still_m, c_at_m), not parameters, to keep the signature.
--   B. v_visit_tank_service. A linked stop under 10 minutes (one sensor period) is left out of the visit's sludge and
--      water when another stop linked to the visit lasts 10 minutes or more (stop_minutes still counts it); appended
--      column short_stops_left_out counts them. Not only completion_chain: under v2 a short stop rarely has a parked
--      reading at all, so a short same_site_earlier stop would otherwise turn its visit edge_missing (4 visits in the
--      rehearsal). exceeds_trap_size is now checked right after edge_missing, so too_short, below_resolution and
--      tank_at_ceiling can no longer hide an impossible gain. Existing columns unchanged, one appended.
--
-- A/B (rolled-back run 2026-10-15 ~00:57 ET; the apply re-runs it, VERIFY below asserts the specific changes)
--   whole era, Moises: 534 pairs, 528 rows re-measured + 2 new, 2.1 s; dumps 26 of 26 unchanged; visit reasons:
--   too_short -> ok 12, too_short -> pumped_no_rise 1, below_resolution -> exceeds_trap_size 12 (see below),
--   exceeds_trap_size -> ok 1, ok -> pumped_no_rise 5, pumped_no_rise -> ok 3, no visit newly edge_missing; water:
--   measurement_missing -> unvalidated 3. Level rows with a NULL edge: 0 -> 65, on stops of about 10 min or less
--   except two unlinked parks (24 and 49 min); none on a linked client stop of 10 min or more (VERIFY 7).
--   visit  date   trap | sludge gal, reason (before)        | sludge gal, reason (after)        | water used/refilled gal
--   6002  10-12   375 | 343.4 ok                           | 251.8 ok (arrival 05:22:00Z at 42 mph -> first parked 05:32:08Z)
--   6261  10-12    30 | 133.8 below_resolution             |  22.2 below_resolution (next-client reading gone)
--   6419  10-12   600 | 796.1 ok                           | 796.1 ok                          | 785.6/444.4 -> 777.5/444.4
--   7873  10-12   300 | 409.3 too_short                    | 452.9 ok (chain stop 1717 left out) | NULL -> 608/616.5
--   5918  10-13   402 | 346.8 ok                           | 325.7 ok
--   6406  10-13    75 |  89.2 below_resolution             |  66.7 below_resolution
--   6589  10-13   150 | 174.0 ok                           | 163.9 ok
--   6666  10-13   125 |  58.6 too_short                    |  58.6 ok (chain stop left out)     | NULL -> 0/0
--   6721  10-13  1275 | 733.6 too_short                    | 754.7 ok (chain stop left out)     | NULL -> 519/764.5
--   5889  10-11  1500 | 1500.8 ok                          | 1513.5 ok
--   6033  10-11    75 |  65.4 below_resolution             |  88.8 below_resolution
--   6576  10-11   130 |  48.7 ok                           |  68.7 ok                          | 87.5/0 -> 113.7/0
--   7019  10-11    65 |   0.0 below_resolution             | 182.9 exceeds_trap_size (departure at 10.6 mph gone)
--   the 12 hidden impossible gains: 8 now read exceeds_trap_size (6252 2,819.5 on 30; 6299 407.7 -> 363.0 on 30;
--   6259 91.6 on 30; 7018 250.0 on 65; 6094 202.8 on 10; 6237 134.7 on 50; 6300 309.9 -> 396.1 on 30; 6773
--   159.5 -> 136.7 on 30); 4 fell under their limit with parked edges and stay below_resolution (6261 above; 7060
--   112.2 -> 89.7 on 48; 8000 116.8 -> 93.5 on 50; 6523 153.2 -> 112.9 on 60). 4 more newly exceed: 7019 above,
--   6041 0 -> 190.3 on 50, 6218 42.3 -> 88.1 on 20, 6236 -1,390.5 -> 134.6 on 50.
--
-- KNOWN LIMITS (not fixed here)
--   - An isolated sensor excursion INSIDE a stop can still be an edge (the spike rule needs both neighbours to agree).
--     6008 (dated 2026-09-22, trap 1,250) moves from 411.1 to 1,861.3 "ok": its first parked reading, 07:11:46Z, reads
--     1,234.7 gal between 2,743.7 and 3,154.8 near full. v1 dodged it by taking a reading from the road. Edges on such
--     excursions: 35 stops under v1, 33 under v2. A same-side excursion filter for the sludge sensor is a follow-up.
--   - A last in-stop reading taken while the truck already moved 15+ m in 10 s no longer counts: 6488 (545.7 -> 22.4)
--     and 7872 (250.3 -> 0) now read pumped_no_rise (low), which says what we know: no parked reading saw the rise.
-- NOT TOUCHED (another session is changing them): public.visits, public.visit_vehicle_stops, fn_build_vehicle_stops,
--   fn_link_visit_vehicle_stops, v_visit_stop_reference, time-on-site-samsara-recheck. The re-measure calls
--   fn_measure_vehicle_stop_tank_levels directly (not fn_refresh_stop_facts, which would also build and link) under
--   the refresh's advisory lock. Everything stays service_role only; nothing in derm, customer or client reads these.
-- ROLLBACK: forward fix only. CREATE OR REPLACE VIEW cannot drop the appended column; the v1 bodies are in git
--   (2026-10-12_2200 / 2026-10-12_2300) and the md5 guard below names the exact live v1 bodies this replaces.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
-- the hourly refresh (cron vehicle-stop-facts, :35) measures under this lock: never interleave with it
SELECT pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));

DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure))) IS DISTINCT FROM '97f7b25ea321e9dc3a40018d1b117cc1'
     OR (SELECT md5(pg_get_viewdef('public.v_visit_tank_service'::regclass))) IS DISTINCT FROM '7fb18a5b0e4a27b54c5afd684bfbcc64' THEN
    RAISE EXCEPTION 'fn_measure_vehicle_stop_tank_levels or v_visit_tank_service changed since this file was written: splice again';
  END IF;
END $g$;

-- before: figures, dumps, integrity and privileges, to compare inside VERIFY
CREATE TEMP TABLE ab_before ON COMMIT DROP AS SELECT * FROM public.v_visit_tank_service WHERE vehicle_id = 1;
CREATE TEMP TABLE dump_before ON COMMIT DROP AS SELECT * FROM public.v_vehicle_dumps WHERE vehicle_id = 1;
CREATE TEMP TABLE chk_before ON COMMIT DROP AS
  SELECT public.fn_stop_facts_checks()->'integrity' AS integrity,
         (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure) AS fn_acl,
         (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_visit_tank_service'::regclass) AS view_acl;

-- ---------------------------------------------------------------------------------------------------------------
-- A. fn_measure_vehicle_stop_tank_levels v2: the live body, spliced (every edit an anchor matched exactly once; the
--    diff against the live body: the v1 lines it touches are the version, the pair columns, the raw series (+ its
--    last row), step 5b (new) and the four edge loops)
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_measure_vehicle_stop_tank_levels(p_from timestamp with time zone, p_execute boolean, p_spike_agree_m numeric DEFAULT 0.05, p_spike_jump_m numeric DEFAULT 0.15, p_hyst_sludge numeric DEFAULT 0.01, p_hyst_water numeric DEFAULT 0.05, p_period interval DEFAULT '00:10:00'::interval, p_lookahead interval DEFAULT '03:00:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_version constant smallint := 2;   -- v2 2026-10-15: a client stop's edge must be a reading taken parked AT the stop
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
begin
  if p_from is null or p_execute is null then
    raise exception 'fn_measure_vehicle_stop_tank_levels: from and execute are required' using errcode = '22023';
  end if;
  if p_execute and (p_spike_agree_m <> 0.05 or p_spike_jump_m <> 0.15 or p_hyst_sludge <> 0.01 or p_hyst_water <> 0.05
                    or p_period <> interval '10 minutes' or p_lookahead <> interval '3 hours') then
    raise exception 'thresholds differ from algorithm version %; bump the version', c_version using errcode = '22023';
  end if;

  for p in
    with pairs as (
      select s.id as stop_id, s.vehicle_id, s.arrived_at, s.departed_at, t.id as tank_id, t.contents,
             s.latitude as stop_lat, s.longitude as stop_lng, s.site_property_id as stop_site,
             t.deleted_at as tank_deleted_at,
             (select min(s2.arrived_at) from public.vehicle_stops s2
               where s2.vehicle_id = s.vehicle_id and s2.superseded_at is null and s2.arrived_at > s.arrived_at) as next_arrived
        from public.vehicle_stops s
        join public.vehicle_tanks t on t.vehicle_id = s.vehicle_id
       where s.superseded_at is null),
    prov as (
      select pr.*, i.id as inst_id, i.tank_sensor_id, i.installed_at, i.removed_at,
             c.id as cfg_id, c.diameter_meters, c.sensor_offset_meters,
             l.id as live_id, l.tank_sensor_installation_id as l_inst, l.vehicle_tank_configuration_id as l_cfg,
             l.algorithm_version as l_ver, l.arrival_fill_fraction as l_af, l.arrival_measured_at as l_at,
             l.departure_fill_fraction as l_df, l.departure_measured_at as l_dt, l.fill_fraction_risen as l_ri,
             l.fill_fraction_fallen as l_fa, l.measurement_count as l_cnt, l.rejected_measurement_count as l_rcnt
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

    -- 4. spike: neighbours agree, this one jumps away from both
    for k in 2 .. n - 1 loop
      if abs(v_md[k-1] - v_md[k+1]) <= p_spike_agree_m
         and abs(v_md[k] - v_md[k-1]) > p_spike_jump_m and abs(v_md[k] - v_md[k+1]) > p_spike_jump_m then
        v_rej[k] := 1;
      end if;
    end loop;

    -- 5. false empty with look-ahead (a real post-dump empty survives)
    select coalesce(array_agg(s.arrived_at), '{}'), coalesce(array_agg(s.departed_at), '{}')
      into v_dump_a, v_dump_b
      from public.vehicle_stops s
      join public.properties sp on sp.id = s.site_property_id
      join public.non_customer_clients nc on nc.client_id = sp.client_id and nc.kind = 'dump_site'
     where s.vehicle_id = p.vehicle_id and s.superseded_at is null
       and s.departed_at >= p.arrived_at - c_back and s.arrived_at <= p.departed_at + 2 * p_lookahead;
    v_last := null;  k := 1;
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
        if v_rec is not null and not exists (select 1 from unnest(v_dump_a, v_dump_b) dd(a, b)
                                              where dd.a <= v_rec and dd.b >= v_mt[k]) then
          for m in k .. j loop if v_rej[m] = 0 then v_rej[m] := 2; end if; end loop;
        else
          v_last := v_mf[j];
        end if;
        k := j + 1;
      else
        v_last := v_mf[k];  k := k + 1;
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
      if v_rej[k] = 0 then v_hold := v_mt[k]; end if;
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
    v_ai := null;
    for k in reverse n .. 1 loop
      if v_rej[k] = 0 and v_ok[k] and v_mt[k] <= p.arrived_at and v_mt[k] >= p.arrived_at - c_back then v_ai := k; exit; end if;
    end loop;
    if v_ai is null then
      for k in 1 .. n loop
        if v_rej[k] = 0 and v_ok[k] and v_mt[k] > p.arrived_at
           and v_mt[k] <= least(p.arrived_at + v_edge, coalesce(p.next_arrived, 'infinity')) then v_ai := k; exit; end if;
      end loop;
    end if;
    -- 7. departure edge (v2: an edge measurement)
    v_dend := least(p.departed_at + v_edge, coalesce(p.next_arrived, 'infinity'));
    v_di := null;
    for k in 1 .. n loop
      if v_rej[k] = 0 and v_ok[k] and v_mt[k] > p.departed_at and v_mt[k] <= v_dend then v_di := k; exit; end if;
    end loop;
    if v_di is null then
      for k in reverse n .. 1 loop
        if v_rej[k] = 0 and v_ok[k] and v_mt[k] <= p.departed_at then v_di := k; exit; end if;
      end loop;
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

    -- 10. counts between the edges (inclusive), rounding, diff, write
    v_lo := coalesce(v_mt[v_ai], p.arrived_at);  v_hi := coalesce(v_mt[v_di], p.departed_at);
    if v_lo > v_hi then v_lo := v_hi; v_hi := coalesce(v_mt[v_ai], p.arrived_at); end if;
    v_cnt := 0;  v_rcnt := 0;
    for k in 1 .. n loop
      if v_mt[k] between v_lo and v_hi then
        if v_rej[k] = 0 then v_cnt := v_cnt + 1; else v_rcnt := v_rcnt + 1; end if;
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
       and p.l_cnt = v_cnt and p.l_rcnt = v_rcnt then
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
         fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, algorithm_version)
      values (p.stop_id, p.vehicle_id, p.tank_id, p.inst_id, p.cfg_id, d_af, d_at, d_df, d_dt, d_ri, d_fa,
              v_cnt, v_rcnt, c_version);
    end if;
    if p.live_id is not null then v_sup := v_sup + 1; end if;
    v_ins := v_ins + 1;
  end loop;

  return jsonb_build_object('execute', p_execute, 'from', p_from, 'pairs', v_pairs, 'not_ready', v_not_ready,
                            'unchanged', v_same, 'inserted', v_ins, 'superseded_and_replaced', v_sup,
                            'superseded_no_provenance', v_drop);
end $function$;

COMMENT ON FUNCTION public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval) IS
'Tank sensors plan 5.3: recompute-and-diff of (live stop, tank) level rows for stops arrived since p_from plus every Z2 (missing) and Z3 (provenance changed or older algorithm) pair. Measurements are value changes; spike and look-ahead false-empty filters; arrival/departure edges; zig-zag risen/fallen with end flush. Identical results write nothing. v2 (2026-10-15_1300): an edge of a client stop is a measurement taken parked AT the stop (GPS fixes from 10 s before the reading to the first fix after it within 15 m, that fix within 100 m of the stop centre) or a value held a full period inside the stop; no edge after the next stop arrival; dump and yard stops keep the v1 edges.';

-- ---------------------------------------------------------------------------------------------------------------
-- B. v_visit_tank_service: the live body, spliced (short stops left out, exceeds_trap_size earlier, one appended column)
-- ---------------------------------------------------------------------------------------------------------------
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
            pp.grease_trap_size_gallons AS trap
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
            pp.grease_trap_size_gallons AS trap
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
            (count(*) FILTER (WHERE COALESCE(sk.skip_short, false)))::integer AS short_stops_left_out
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
    short_stops_left_out
   FROM r;

COMMENT ON VIEW public.v_visit_tank_service IS
'Per completed live visit since 2026-08-20: linked stops, stop and pump minutes, sludge collected and gross intake with confidence and reason (plan 5.7, first failing check wins; since 2026-10-15 exceeds_trap_size is checked right after edge_missing, so no later reason hides an impossible gain), water used/refilled (pp and gallons, confidence low in v1), time-on-site disagreement (F7). A linked stop under 10 minutes (one sensor period) is left out of the sludge and water figures when another stop linked to the visit lasts 10 minutes or more; short_stops_left_out counts them (stop_minutes still includes them). Not for regulator filings (N1, D8).';

-- ---------------------------------------------------------------------------------------------------------------
-- C. Re-measure. c_version 2 makes every live v1 level row a Z3 pair, whatever its age, so this one call re-measures
--    Moises's whole sensor era (the only truck with tanks). It writes only vehicle_stop_tank_levels (supersede +
--    insert, never an UPDATE of values). Pairs whose look-ahead has not passed (departed under 3 h ago) stay v1 until
--    the next hourly run.
-- ---------------------------------------------------------------------------------------------------------------
CREATE TEMP TABLE remeasure ON COMMIT DROP AS
  SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '35 days', true) AS r;
CREATE TEMP TABLE ab_after ON COMMIT DROP AS SELECT * FROM public.v_visit_tank_service WHERE vehicle_id = 1;
CREATE TEMP TABLE dump_after ON COMMIT DROP AS SELECT * FROM public.v_vehicle_dumps WHERE vehicle_id = 1;

-- ---------------------------------------------------------------------------------------------------------------
-- VERIFY (inside the transaction; these objects are service_role only and read by no app)
-- ---------------------------------------------------------------------------------------------------------------
DO $v$
DECLARE
  r jsonb := (SELECT r FROM remeasure);
  z jsonb := public.fn_stop_facts_checks()->'integrity';
  zb jsonb := (SELECT integrity FROM chk_before);
  n int;  k text;
  -- readings the audit found used as edges although taken moving or at another stop (sludge sensor, UTC)
  bad timestamptz[] := array['2026-10-13 05:12:08+00',   -- 7873 departure, 48 mph
                             '2026-10-13 05:22:00+00',   -- 6002 arrival, 42 mph
                             '2026-10-12 09:12:23+00',   -- 7019 departure, 10.6 mph (its net 0)
                             '2026-10-13 04:32:08+00',   -- 7873 arrival, re-parking at 3 mph
                             '2026-10-13 04:23:12+00']::timestamptz[];  -- 6261 departure, taken at the next client
BEGIN
  -- 1. the re-measure ran and nothing older than v2 is left except pairs not ready yet
  IF coalesce((r->>'inserted')::int, 0) = 0 THEN RAISE EXCEPTION 'VERIFY 1: re-measure inserted nothing: %', r; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND s.superseded_at IS NULL AND l.algorithm_version < 2 AND s.departed_at + interval '3 hours' <= now();
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % ready live level rows still v1', n; END IF;

  -- 2. integrity: Z1 Z2 Z3 Z6 Z7 Z8 Z9 stay 0, the Z8 control is found, Z4 (links, another session's area) does not grow
  FOREACH k IN ARRAY array['Z1','Z2','Z3','Z6','Z7','Z8','Z9'] LOOP
    IF (z->>k)::int <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % = % (was %)', k, z->>k, zb->>k; END IF;
  END LOOP;
  IF (z->>'Z8_control_found')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'VERIFY 2: Z8 control not found'; END IF;
  IF (z->>'Z4')::int > (zb->>'Z4')::int THEN RAISE EXCEPTION 'VERIFY 2: Z4 grew % -> %', zb->>'Z4', z->>'Z4'; END IF;

  -- 3. privileges unchanged: the writer is executable by its owner only, the view readable by service_role only
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure) IS DISTINCT FROM (SELECT fn_acl FROM chk_before)
     OR (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'public.v_visit_tank_service'::regclass) IS DISTINCT FROM (SELECT view_acl FROM chk_before)
  THEN RAISE EXCEPTION 'VERIFY 3: an ACL changed'; END IF;
  IF has_function_privilege('anon', 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)', 'EXECUTE') OR has_function_privilege('authenticated', 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)', 'EXECUTE')
     OR has_table_privilege('anon', 'public.v_visit_tank_service', 'SELECT') OR has_table_privilege('authenticated', 'public.v_visit_tank_service', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_visit_tank_service', 'SELECT')
  THEN RAISE EXCEPTION 'VERIFY 3: a privilege is not what it was'; END IF;

  -- 4. finding 1 + 2: none of the audited moving / next-stop readings is an edge any more
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l
   WHERE l.superseded_at IS NULL AND l.vehicle_id = 1 AND (l.arrival_measured_at = ANY (bad) OR l.departure_measured_at = ANY (bad));
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % live level rows still use an audited moving or next-stop reading', n; END IF;
  -- 6261 no longer carries the 112 gal from the next client: under its trap limit (1.5 x 30 + 40)
  IF (SELECT sludge_collected_gallons FROM ab_after WHERE visit_id = 6261) IS NULL
     OR (SELECT sludge_collected_gallons FROM ab_after WHERE visit_id = 6261) > 85
  THEN RAISE EXCEPTION 'VERIFY 4: 6261 still reads % gal', (SELECT sludge_collected_gallons FROM ab_after WHERE visit_id = 6261); END IF;
  -- 7019: the parked rise shows (was net 0 on the 10.6 mph departure) and is flagged against its 65 gal trap
  IF (SELECT sludge_reason FROM ab_after WHERE visit_id = 7019) IS DISTINCT FROM 'exceeds_trap_size'
     OR (SELECT sludge_collected_gallons FROM ab_after WHERE visit_id = 7019) < 137.5
  THEN RAISE EXCEPTION 'VERIFY 4: 7019 reads % / %', (SELECT sludge_collected_gallons FROM ab_after WHERE visit_id = 7019),
                                                      (SELECT sludge_reason FROM ab_after WHERE visit_id = 7019); END IF;

  -- 5. finding 3: the short chain stop no longer makes 7873 / 6666 / 6721 too_short or blanks their water
  SELECT count(*) INTO n FROM ab_after a JOIN ab_before b USING (visit_id)
   WHERE a.visit_id IN (7873, 6666, 6721)
     AND b.sludge_reason = 'too_short' AND b.water_used_gallons IS NULL
     AND a.sludge_reason <> 'too_short' AND a.water_used_gallons IS NOT NULL AND a.short_stops_left_out >= 1;
  IF n <> 3 THEN RAISE EXCEPTION 'VERIFY 5: only % of 7873/6666/6721 fixed', n; END IF;
  -- a visit is never too_short because of a short stop it also has a long stop for
  SELECT count(*) INTO n FROM ab_after WHERE sludge_reason = 'too_short' AND short_stops_left_out > 0;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: % visits too_short with a short stop left out', n; END IF;

  -- 6. finding 4: no impossible gain hides behind a later reason; 6252 (2,819.5 gal on a 30 gal trap) is flagged
  IF (SELECT sludge_reason FROM ab_after WHERE visit_id = 6252) IS DISTINCT FROM 'exceeds_trap_size'
  THEN RAISE EXCEPTION 'VERIFY 6: 6252 reads %', (SELECT sludge_reason FROM ab_after WHERE visit_id = 6252); END IF;
  SELECT count(*) INTO n FROM public.v_visit_tank_service t JOIN public.properties pp ON pp.id = t.property_id
   WHERE pp.grease_trap_size_gallons IS NOT NULL AND t.sludge_collected_gallons > 1.5 * pp.grease_trap_size_gallons + 40
     AND t.sludge_reason IN ('too_short', 'below_resolution', 'tank_at_ceiling');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 6: % impossible gains still hidden', n; END IF;

  -- 7. no regression into "unknown": no visit newly edge_missing, and no linked client stop of 10 min or more with a
  --    NULL edge (short stops may have none; the view leaves them out when the visit has a long stop)
  SELECT count(*) INTO n FROM ab_after a JOIN ab_before b USING (visit_id)
   WHERE a.sludge_reason = 'edge_missing' AND b.sludge_reason IS DISTINCT FROM 'edge_missing';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 7: % visits newly edge_missing', n; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND s.superseded_at IS NULL AND s.site_property_id IS NULL
     AND s.departed_at - s.arrived_at >= interval '10 minutes'
     AND (l.arrival_fill_fraction IS NULL OR l.departure_fill_fraction IS NULL)
     AND EXISTS (SELECT 1 FROM public.visit_vehicle_stops vs WHERE vs.vehicle_stop_id = s.id AND vs.deleted_at IS NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 7: % linked client stops of 10 min or more lost an edge', n; END IF;

  -- 8. dump and yard stops keep the v1 edges: every Moises dump reads exactly as before
  SELECT count(*) INTO n FROM dump_before b FULL JOIN dump_after a USING (vehicle_stop_id)
   WHERE a.vehicle_stop_id IS NULL OR b.vehicle_stop_id IS NULL
      OR a.offload_gallons IS DISTINCT FROM b.offload_gallons OR a.offload_reason IS DISTINCT FROM b.offload_reason;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 8: % dumps changed', n; END IF;
END $v$;

COMMIT;
