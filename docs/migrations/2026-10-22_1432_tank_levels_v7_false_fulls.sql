-- 2026-10-22_1432_tank_levels_v7_false_fulls · fn_measure_vehicle_stop_tank_levels v7: false-full sludge readings judged over the whole stream; the
-- carried-in level must be read standing still (water audit 2, G1-G3; Fred: "Grease readings at the edges")
--
-- Audit: Building Apps/Visit Calendar/docs/specs/2026-10-22-water-audit-since-oct-19.md section 2 (G1, G2) and the
-- 148-MOR case. Designed with a full replay of the v5 function (632/632 live rows reproduced on all 16 fields), three
-- candidate rules judged on every stop since Aug 20, and a rolled-back rehearsal whose change list matched the replay's
-- prediction exactly (session scratchpad audit/fix2/measure/).
-- G1: after the Oct 19 dump (stop 1841) the sludge sensor alternated between a false full (0.10 m) and the real empty;
--   the false full became 067-TCE's arrival edge (6139: -3,561, hidden; true about 214) and dump 8858's departure
--   (offload -380; true about 3,394). G2: step 5c took a sludge reading taken while DRIVING as 001-VIN's carried-in level
--   (6564: 68; true about 182). G3: a false full at 148-MOR on Aug 31 was stop 940's departure and 941's arrival (6347 low,
--   so the Calendar estimate for 6348 on Oct 29 was 'unknown').
-- WHAT (see the comments in the body):
--   3b+ a whole-stream false-full judge for each sludge installation: a run of 0.11 m or less is false when the level
--       "rose" to it with no client or yard stop in between, or "fell" from it with no dump or yard stop in between
--       (sludge only enters at a client or the yard and only leaves at a dump or the yard); it joins the ghost intervals
--       (code 3). An empty neighbour gives no verdict.
--   5c  the carried-in level must be a reading taken standing still (5b's GPS stillness test).
--   7c  a dump or yard stop whose departure fell back to a false full takes the first accepted reading before the next
--       stop.
-- c_version 5 -> 7 (6 is the v5 rollback's), so every live row is re-decided. Measured in the rehearsal: 15 (stop, tank)
-- rows change, all sludge, no water row; visits: 6139 213.6 (was hidden), 6564 175.4 (its trap-size share of 182.4 on
-- stop 1858, shared with 6096 since 2026-10-22_1345), 6347 3,765.1 (two trips; was low tank_at_ceiling); dumps 1841
-- 3,394.1 (was -380), 1147 3,075.7 (was 3,115.3). Frozen Calendar days do not move (ops.visit_grease_frozen).
-- Known limits (unchanged, listed in the 3b+ comment): Oct 1 false fulls at 0.16 / 0.19 m (6174, 1202/1203), 1148, the
-- Aug 25 setup-day readings (892/893, 6252), 1249's arrival, a false low at the end of a client stop (1012 / 6737).
-- RULE 8: no table created or changed (vehicle_stop_tank_levels rows are superseded and inserted by the function).
-- ROLLBACK: docs/migrations/2026-10-22_rollback_tank_levels_v7.sql (v5 body as c_version 8, then a re-measure).

BEGIN;

DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p WHERE p.proname = 'fn_measure_vehicle_stop_tank_levels') <> 'fe826b4b46a8559fa7fc136dfd02adfa' THEN
    RAISE EXCEPTION 'fn_measure_vehicle_stop_tank_levels changed since this migration was written';
  END IF;
END $g$;

-- bring the v5 rows up to date first (readings that arrived since the last hourly run), so the comparison below sees
-- only what v7 changes
SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '400 days', true);
CREATE TEMP TABLE pre_lv ON COMMIT DROP AS
  SELECT vehicle_stop_id, vehicle_tank_id, tank_sensor_installation_id, vehicle_tank_configuration_id, arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at, fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, peak_fill_fraction, low_fill_fraction, departure_basis, late_change_fill_fraction, late_change_measured_at, ghost_measurement_count FROM public.vehicle_stop_tank_levels WHERE superseded_at IS NULL;
CREATE TEMP TABLE pre_vts ON COMMIT DROP AS
  SELECT visit_id, sludge_collected_gallons, sludge_confidence, sludge_reason, water_refilled_gallons, water_used_gallons
    FROM public.v_visit_tank_service;

CREATE OR REPLACE FUNCTION public.fn_measure_vehicle_stop_tank_levels(p_from timestamp with time zone, p_execute boolean, p_spike_agree_m numeric DEFAULT 0.05, p_spike_jump_m numeric DEFAULT 0.15, p_hyst_sludge numeric DEFAULT 0.01, p_hyst_water numeric DEFAULT 0.05, p_period interval DEFAULT '00:10:00'::interval, p_lookahead interval DEFAULT '03:00:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_version constant smallint := 7;   -- v7 2026-10-22 ("Grease readings at the edges", Fred): false fulls judged over the
                                      -- whole sludge stream (3b+), a carried-in level read while driving is not carried in
                                      -- (5c), a dump or yard departure hidden by a false full (7c). 6 is reserved for the v5
                                      -- rollback; a rollback of v7 must re-apply v5 as 8 or more. A change to the false-full
                                      -- judge below must bump this, like a change to the ghost functions.
                                      -- v5 2026-10-16: sludge cannot drop before a client's pumping (5c, 6c). 4 is taken by
                                      -- the v3 rollback; a rollback of v5 must re-apply v3 as 6 or more.
                                      -- v3 2026-10-16: ghost readings, stale arrival edges, the change after leaving, peak and low
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
  v_c int;  v_off timestamptz;  v_carried boolean;                                                         -- v5
  ff record;  f_t timestamptz[];  f_l timestamptz[];  f_u timestamptz[];  f_d float8[];  f_f float8[];      -- v7
  f_gh boolean[];  f_n int;  f_q int;  f_rise boolean;  f_fall boolean;                                     -- v7
  x_s bigint[] := '{}';  x_f timestamptz[] := '{}';  x_u timestamptz[] := '{}';  x_d float8[] := '{}';      -- v7
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

  -- 3b+ (v7, 2026-10-22, "Grease readings at the edges"). FALSE FULLS. Sludge only ENTERS the truck at a client stop, or
  --   at the yard from truck David, and only LEAVES at a dump or the yard; nothing changes on the road (Fred / Yan). A
  --   reading of 0.11 m or less (about 98%) is what a full tank and the false-full echo both read, so the value decides
  --   nothing; the sequence does. Judged ONCE per run over each sludge sensor's whole stream (value changes with their
  --   first- and last-seen times; listed ghosts skipped) and appended to the ghost intervals (sensor, first seen, until =
  --   next value change, distance), so 3b rejects them as ghosts (code 3, counted in ghost_measurement_count) identically
  --   in every pair's window. Judging per window failed: a window that starts inside the echo cannot see the level before
  --   it (6139's window opened at 19:54 on the 0.10 m first seen at 19:42).
  --   A run C of consecutive values at 0.11 m or less is false when either real neighbour proves it:
  --     rise: P = the value before the run is more than p_spike_jump_m (0.15 m) further, and no client or yard stop of
  --           the vehicle overlaps [P last seen, C first seen]: the sludge would have entered on the road or at a dump
  --           (dump 8858, Oct 19: 1.14 m at 19:32 to 0.10 m at 19:42, inside the dump);
  --     fall: N = the value after the run is more than 0.15 m further, and no dump or yard stop overlaps [C's last value
  --           last seen, N first seen]: the sludge would have left at a client or on the road.
  --   An EMPTY neighbour (fraction 0.005 or less) gives no verdict for its side: it may itself be a false empty, step 5's
  --   case. Since false fulls are ghosts, step 4 already skips them as neighbours, so an echo alternating with the real
  --   level resolves to the real level, and a real reading between two echoes is no longer a spike (1147).
  --   Cases: G1, 067-TCE 6139 (stop 1844) and dump 8858 (stop 1841): the 19:42 false full was 1844's arrival edge (net
  --     -3,561) and 8858's departure (offload -380). Now 0.5 to 214.1 gal, and 7c below gives the offload 3,394.1.
  --   G3, 148-MOR 6347 (stops 940 / 941, Aug 31): the yard read 2.07-2.13 m until 22:24:10; 0.10 m was first seen at
  --     22:25 (yard, 2 min before leaving) and again 23:01-00:43 at the client, then 1.11 / 1.12 m at the same client,
  --     2 h 19 min later, with no dump in between. That proves both 0.10 m runs false: a full tank cannot lose 1,950 gal
  --     at a client. (The mechanism: 22:25 falls to the 1.37 m weak echo at 22:40, outside any dump or yard; with it set
  --     aside 1.37 m is a spike between 2.13 m and 2.13 m.) True values: 940 is 0 to 0, 941 is 0 to 1,797.7, so 6347 =
  --     1,967.4 + 0 + 1,797.7 = 3,765.1 gal, no stop at the ceiling, and 6348's estimate is no longer 'unknown'.
  --   Known limits (same physics, left as v5 had them; Fred decides a v8 in Supabase/docs/decisions-to-build.md):
  --     the Oct 1 false fulls read at 0.16 / 0.19 m, above 0.11 m (6174 reads 0, truth about 804; dump 1202's offload
  --     37.7; yard 1203 shows a phantom 1,147); a near-full run whose neighbour is an empty (false or real) is not
  --     judged (1148's phantom 3,762 gal yard offload, 892 / 6252 at the ceiling, 1249's arrival, truth about 3,324);
  --     a false LOW is only judged by steps 4, 5 and 5c (1012 / 6737, truth about +421); an echo / real alternation with
  --     empty neighbours on both sides is settled by spike-pass order (yard 1843's edges sit at 20:02:13, 0 gal either way).
  for ff in
    select i.tank_sensor_id, i.vehicle_tank_id, i.installed_at, i.removed_at, t.vehicle_id
      from public.tank_sensor_installations i
      join public.vehicle_tanks t on t.id = i.vehicle_tank_id
     where i.superseded_at is null and t.contents = 'sludge'
  loop
    select array_agg(z.t order by z.t), array_agg(z.l order by z.t), array_agg(z.u order by z.t),
           array_agg(z.d::float8 order by z.t),
           array_agg(public.fn_tank_fill_fraction(z.d, c.diameter_meters, c.sensor_offset_meters)::float8 order by z.t),
           array_agg(exists (select 1 from unnest(v_g_s, v_g_f, v_g_u, v_g_d) g(s, f, u, d)
                              where g.s = ff.tank_sensor_id and g.f <= z.t and z.t < g.u and g.d = z.d::float8) order by z.t)
      into f_t, f_l, f_u, f_d, f_f, f_gh
      from (select y.t, y.l, y.d, coalesce(lead(y.t) over (order by y.t), 'infinity') as u
              from (select min(w.recorded_at) as t, max(w.recorded_at) as l, min(w.distance_meters) as d
                      from (select v.recorded_at, v.distance_meters, sum(v.chg) over (order by v.recorded_at) as grp
                              from (select r.recorded_at, r.distance_meters,
                                           case when lag(r.distance_meters) over (order by r.recorded_at)
                                                     is distinct from r.distance_meters then 1 else 0 end as chg
                                      from public.tank_sensor_distance_readings r
                                     where r.tank_sensor_id = ff.tank_sensor_id and r.recorded_at >= ff.installed_at
                                       and r.recorded_at < coalesce(ff.removed_at, 'infinity') and r.distance_meters > 0) v) w
                     group by w.grp) y) z
      left join lateral (select c.diameter_meters, c.sensor_offset_meters from public.vehicle_tank_configurations c
                          where c.vehicle_tank_id = ff.vehicle_tank_id and c.superseded_at is null and c.effective_from <= z.t
                          order by c.effective_from desc limit 1) c on true;
    f_n := coalesce(cardinality(f_t), 0);
    k := 1;
    while k <= f_n loop
      if f_gh[k] or not (f_d[k] <= 0.11) then k := k + 1; continue; end if;
      j := k;  m := k + 1;
      while m <= f_n loop                                        -- the run: values of 0.11 m or less, ghosts skipped
        if f_gh[m] then m := m + 1; continue; end if;
        exit when not (f_d[m] <= 0.11);
        j := m;  m := m + 1;
      end loop;
      f_q := k - 1;
      while f_q >= 1 and f_gh[f_q] loop f_q := f_q - 1; end loop;
      f_rise := false;  f_fall := false;
      if f_q >= 1 and f_f[f_q] > 0.005 and f_d[f_q] - f_d[k] > p_spike_jump_m then
        f_rise := not exists (select 1 from public.vehicle_stops s
                               where s.vehicle_id = ff.vehicle_id and s.superseded_at is null
                                 and s.arrived_at <= f_t[k] and s.departed_at >= f_l[f_q]
                                 and (s.site_property_id is null
                                      or exists (select 1 from public.properties sp
                                                   join public.non_customer_clients nc on nc.client_id = sp.client_id
                                                  where sp.id = s.site_property_id and nc.kind = 'yard')));
      end if;
      if m <= f_n and f_f[m] > 0.005 and f_d[m] - f_d[j] > p_spike_jump_m then
        f_fall := not exists (select 1 from public.vehicle_stops s
                               where s.vehicle_id = ff.vehicle_id and s.superseded_at is null
                                 and s.arrived_at <= f_t[m] and s.departed_at >= f_l[j]
                                 and exists (select 1 from public.properties sp
                                               join public.non_customer_clients nc on nc.client_id = sp.client_id
                                              where sp.id = s.site_property_id and nc.kind in ('dump_site', 'yard')));
      end if;
      if f_rise or f_fall then
        for f_i in k .. j loop
          if not f_gh[f_i] then
            x_s := x_s || ff.tank_sensor_id::bigint;  x_f := x_f || f_t[f_i];  x_u := x_u || f_u[f_i];  x_d := x_d || f_d[f_i];
          end if;
        end loop;
      end if;
      k := m;
    end loop;
  end loop;
  v_g_s := v_g_s || x_s;  v_g_f := v_g_f || x_f;  v_g_u := v_g_u || x_u;  v_g_d := v_g_d || x_d;

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

    -- 5c (v5, 2026-10-16). Sludge only leaves the truck at a dump or the yard (Fred / Yan 2026-10-16), so on the way to
    --   a client and at the client before its pumping starts the level cannot be lower than the level carried in.
    --   v_c = the last accepted level before arrival (within c_back, after the last dump or yard stop). From there, the
    --   accepted measurements up to the first one back within 100 gal of it are impossible and rejected (code 4); when
    --   any was, the arrival edge is the carried-in level (6c). Visit 6008 (034-LG, stop 1144): 1.37 m (32%) read 35 s
    --   after parking, the truck had left the previous client at 71%; it was the arrival edge and gave 1,861 gal for
    --   about 375. No list of false values needed: any value that would make sludge vanish on the road is caught.
    --   Water is not covered: Moises pushes water back at a client, so water can go either way. Client stops only.
    v_c := null;  v_carried := false;
    if p.contents = 'sludge' and p.stop_site is null and p.cfg_cap is not null then
      select max(dd.b) into v_off from unnest(v_dump_a, v_dump_b) dd(a, b) where dd.a <= p.arrived_at;
      for k in reverse n .. 1 loop
        -- never a false-full value (0.11 m or less, about 98%): it is also a ghost, and as the level carried in it would
        -- reject a whole real visit (168-AVA 8041 and 148-MOR 6347 in the rehearsal)
        if v_rej[k] = 0 and v_mt[k] <= p.arrived_at and v_mt[k] >= p.arrived_at - c_back and v_md[k] > 0.11
           and v_mt[k] > coalesce(v_off, '-infinity') then v_c := k; exit; end if;
      end loop;
      -- 5c (v7, 2026-10-22). The level carried in is used only if it was read with the truck stationary (5b's test,
      --   at any place: every GPS fix from the last one c_settle or more before it to the first one at or after it
      --   within c_still_m of that first fix). A level read while driving sloshes, so there is NO carry-in. G2, 001-VIN
      --   6564 (stop 1858, Oct 22): 0.95 m read at 05:02:14, 209 m from the stop and moving, rejected the three parked
      --   1.00-1.01 m readings and was the arrival edge (68 gal); now 2,073 at 05:12:14 to 2,255.3, 182.4 gal. Also stop
      --   958 (0.56 m read on the road; net still 0). Not instead an earlier stationary reading (it took mid-stop levels
      --   of the previous stop: 1227, 1718, 1794), not "parked at this or the previous stop" (6174's 0.16 m was read two
      --   stops back, and its 0 would return to -2,898), not the previous stop's departure edge (no stop needs it, and one
      --   row would depend on another's result). 6b stays unguarded: it takes the level reported at arrival by design
      --   (guarding it moves 6008 / stop 1144 and stop 1220).
      if v_c is not null and not coalesce((
           select sp.spread_m <= c_still_m
             from (select g.recorded_at, g.latitude, g.longitude from public.vehicle_telemetry_readings g
                    where g.vehicle_id = p.vehicle_id and g.latitude is not null and g.recorded_at >= v_mt[v_c]
                    order by g.recorded_at limit 1) ga
             join lateral (select g.recorded_at from public.vehicle_telemetry_readings g
                            where g.vehicle_id = p.vehicle_id and g.latitude is not null and g.recorded_at <= v_mt[v_c] - c_settle
                            order by g.recorded_at desc limit 1) gb on true
             join lateral (select max(ops.fn_haversine_km(g.latitude, g.longitude, ga.latitude, ga.longitude)) * 1000 as spread_m
                             from public.vehicle_telemetry_readings g
                            where g.vehicle_id = p.vehicle_id and g.latitude is not null
                              and g.recorded_at between gb.recorded_at and ga.recorded_at) sp on true), false) then
        v_c := null;
      end if;
      if v_c is not null then
        for k in v_c + 1 .. n loop
          exit when v_mt[k] > p.departed_at;
          continue when v_rej[k] <> 0;
          exit when v_mf[k] >= v_mf[v_c] - 100.0 / p.cfg_cap::float8;
          v_rej[k] := 4;  v_carried := true;
        end loop;
      end if;
    end if;

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
    -- 6c (v5). 5c rejected an impossible drop: the arrival level is the level carried in.
    if v_carried then v_ai := v_c; end if;
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
    -- 7c (v7, 2026-10-22). A dump or yard stop whose measurement in force at departure (the last one at or before it) is
    --   a rejected reading of 0.11 m or less, and whose departure edge came from the fallback (none accepted in
    --   (departure, v_dend]), takes the first accepted measurement after it and before the next stop's arrival. Nothing
    --   changes on the road. G1, dump 8858 (stop 1841): the 0.10 m false full at 19:42 hid the empty; 2.13 m at 20:02:13,
    --   offload 3,394.1 (was -380.3).
    if p.stop_site is not null and (v_di is null or v_mt[v_di] <= p.departed_at) then
      v_q := null;
      for k in reverse n .. 1 loop
        if v_mt[k] <= p.departed_at then v_q := k; exit; end if;
      end loop;
      if v_q is not null and v_rej[v_q] <> 0 and v_md[v_q] <= 0.11 then
        for k in v_q + 1 .. n loop
          exit when v_mt[k] >= coalesce(p.next_arrived, 'infinity');
          if v_rej[k] = 0 then v_di := k; exit; end if;
        end loop;
      end if;
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

DO $m$ BEGIN
  IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p WHERE p.proname = 'fn_measure_vehicle_stop_tank_levels') <> '5337abcf7f0cb6defb07be0b4abba37c' THEN
    RAISE EXCEPTION 'v7 body is not the rehearsed one';
  END IF;
END $m$;

SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '400 days', true);

-- VERIFY
DO $v$
DECLARE s text; n int; r record;
BEGIN
  -- 1. every live row is v7, none lost or added
  IF EXISTS (SELECT 1 FROM public.vehicle_stop_tank_levels WHERE superseded_at IS NULL AND algorithm_version <> 7) THEN
    RAISE EXCEPTION 'VERIFY 1: rows not at v7';
  END IF;
  IF (SELECT count(*) FROM public.vehicle_stop_tank_levels WHERE superseded_at IS NULL) <> (SELECT count(*) FROM pre_lv) THEN
    RAISE EXCEPTION 'VERIFY 1b: row count moved';
  END IF;
  -- 2. exactly the rehearsed stops change, all on the sludge tank
  SELECT string_agg(DISTINCT x.vehicle_stop_id::text, ',' ORDER BY x.vehicle_stop_id::text) INTO s FROM (
    SELECT vehicle_stop_id, vehicle_tank_id, tank_sensor_installation_id, vehicle_tank_configuration_id, arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at, fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, peak_fill_fraction, low_fill_fraction, departure_basis, late_change_fill_fraction, late_change_measured_at, ghost_measurement_count FROM public.vehicle_stop_tank_levels WHERE superseded_at IS NULL
    EXCEPT SELECT * FROM pre_lv) x;
  IF (SELECT string_agg(v, ',' ORDER BY v) FROM unnest(string_to_array(s, ',')) v)
     IS DISTINCT FROM (SELECT string_agg(v, ',' ORDER BY v) FROM unnest(string_to_array('893,896,939,940,941,958,959,1124,1147,1249,1841,1843,1844,1846,1858', ',')) v) THEN
    RAISE EXCEPTION 'VERIFY 2: changed stops %', s;
  END IF;
  IF EXISTS (SELECT 1 FROM (SELECT vehicle_stop_id, vehicle_tank_id, tank_sensor_installation_id, vehicle_tank_configuration_id, arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at, fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, peak_fill_fraction, low_fill_fraction, departure_basis, late_change_fill_fraction, late_change_measured_at, ghost_measurement_count FROM public.vehicle_stop_tank_levels WHERE superseded_at IS NULL
                            EXCEPT SELECT * FROM pre_lv) x JOIN public.vehicle_tanks vt ON vt.id = x.vehicle_tank_id WHERE vt.contents <> 'sludge') THEN
    RAISE EXCEPTION 'VERIFY 2b: a water row changed';
  END IF;
  -- 3. the three visits read their true figures
  SELECT sludge_collected_gallons INTO r FROM public.v_visit_tank_service WHERE visit_id = 6139;
  IF r.sludge_collected_gallons IS NULL OR abs(r.sludge_collected_gallons - 213.6) > 1 THEN RAISE EXCEPTION 'VERIFY 3 6139: %', r; END IF;
  SELECT sludge_collected_gallons INTO r FROM public.v_visit_tank_service WHERE visit_id = 6564;
  IF abs(r.sludge_collected_gallons - 175.4) > 1 THEN RAISE EXCEPTION 'VERIFY 3 6564: %', r; END IF;
  SELECT sludge_collected_gallons INTO r FROM public.v_visit_tank_service WHERE visit_id = 6347;
  IF abs(r.sludge_collected_gallons - 3765.1) > 1 THEN RAISE EXCEPTION 'VERIFY 3 6347: %', r; END IF;
  -- 4. no visit's water figure moved
  SELECT count(*) INTO n FROM public.v_visit_tank_service t JOIN pre_vts p USING (visit_id)
   WHERE t.water_refilled_gallons IS DISTINCT FROM p.water_refilled_gallons OR t.water_used_gallons IS DISTINCT FROM p.water_used_gallons;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % visits'' water moved', n; END IF;
END $v$;

COMMIT;
