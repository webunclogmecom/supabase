-- 2026-10-16_1510 Tank levels v5: sludge cannot drop before a client's pumping starts
--
-- WHY (Fred, 2026-10-16: "fix it, and let's run a check"). Visit 6008 (034-LG, Sep 22 night, stop 1144) recorded
-- 1,861 gal of sludge for about 352. The truck left the previous client at 71% (0.70 m), drove 20 minutes, and 35 s
-- after parking the sludge radar read 1.37 m (32%) for 10 minutes before pumping started. v3 took that reading as the
-- arrival level: 1.37 m was not on the ghost list (1.35 m only), the spike rule needs agreeing neighbours (0.70 before,
-- 0.50 after: pumping had started) and the reading before arrival was taken moving. Seen in the Samsara dashboard
-- (Readings view: Sensor distance measurement 53.9 in at 9:19:57 AM UTC+2) and in the raw API.
--
-- WHAT
--   A. public.fn_tank_ghost_distance_listed: the sludge weak echo is 1.35 to 1.37 m (was 1.35 only).
--   B. public.fn_measure_vehicle_stop_tank_levels, c_version 3 -> 5 (4 is taken by the v3 rollback), so every live row
--      is re-measured:
--      5c sludge, client stops: the level carried in = the last accepted measurement before arrival (within 3 h, after
--         the last dump or yard stop, never a false-full 0.11 m or less). Sludge only leaves the truck at a dump or the
--         yard (Fred / Yan 2026-10-16), so the accepted measurements from there up to the first one back within 100 gal
--         of it are impossible: rejected, code 4.
--      6c when 5c rejected any, the arrival edge is the carried-in measurement.
--      Water is not covered (Moises pushes water back at a client, so water can move either way).
--
-- REHEARSED 2026-10-16 15:05 ET in a transaction rolled back by a raised exception, every live row re-measured (578):
--   visit  client   date      before     after   reason (unchanged)
--   6008   034-LG   Sep 22    1,861.3    352.3   ok
--   6174   072-TCE  Oct 1    -2,898.0      0.0   pumped_no_rise (a false low departure)
--   6544   238-PV   Aug 22     -861.2      0.0   pumped_no_rise
--   Every other visit unchanged. Dump stop 1147 (Sep 23): collected 4,653.3 -> 3,144.3 for 3,115.3 offloaded, ratio
--   0.669 -> 0.991. Visits below -40 gal 4 -> 2; exceeds_trap_size 17 -> 17.
--   A first draft without the false-full guard moved 168-AVA (8041) 39.8 -> 0 and 148-MOR (6347) 563.5 -> 2,540.1: a
--   98.3% false-full reading had become the level carried in. Hence the 0.11 m guard.
--
-- ROLLBACK: docs/migrations/2026-10-16_rollback_tank_levels_v5.sql (re-applies the v3 bodies as c_version 6). Run it
-- BEFORE 2026-10-15_rollback_tank_pipeline_v3.sql: that file's md5 guard pins the v3 body.

BEGIN;

DO $guard$
begin
  if (select md5(pg_get_functiondef('public.fn_measure_vehicle_stop_tank_levels(timestamp with time zone,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure)))
       <> '7ce24a7b28cfa2dd0952720dcfb1d7e6'
  or (select md5(pg_get_functiondef('public.fn_tank_ghost_distance_listed(text,numeric)'::regprocedure)))
       <> '5cdfedae5911e7e4eff71d74fcf7e1c8' then
    raise exception 'tank functions changed since 2026-10-16 15:00 ET; re-read the live bodies before applying v5';
  end if;
end $guard$;

CREATE OR REPLACE FUNCTION public.fn_tank_ghost_distance_listed(p_contents text, p_distance_m numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- Distances the LM11 radars on Moises read falsely (measured 2026-10-16; distances are stored to the centimetre, so a
  -- ghost is one exact value that repeats far more than its neighbours). The sludge false empty (2.09 m or more) is NOT
  -- here: many such readings are real empties after a dump, and the existing false-empty rule handles it. Nor is the
  -- false FULL (0.11 m or less): a truly full truck reads the same, and listing it rejected real full levels at dump
  -- stop 1249 and visit 6737 in the rehearsal; the existing spike rule still rejects an isolated one.
  -- v5 (2026-10-16): the sludge weak echo is 1.35 to 1.37 m, not only 1.35 m. Visit 6008 (034-LG) arrived on a 1.37 m
  -- reading (32%) between 0.70 m and 0.50 m, and 148-MOR's stop 940 on the same 1.37 m. Real levels at these distances
  -- are common; they are not rejected, because a listed value is only a ghost more than 15 cm outside its neighbours.
  -- A change here must bump c_version in fn_measure_vehicle_stop_tank_levels.
  select case p_contents
    when 'fresh_water' then p_distance_m between 1.13 and 1.15      -- the 1.14 m echo, about 765 gal (27 readings)
                          or p_distance_m >= 2.40                    -- no echo, about 0 gal (7 readings)
                          -- (2.12 to 2.14 m was a candidate: 3 readings, it does not repeat more than its neighbours,
                          --  and the one it would remove looks real (5901's water); left out)
    when 'sludge'      then p_distance_m between 1.35 and 1.37      -- weak echo, about 32 to 33% (v5: was 1.35 only)
                          or p_distance_m between 1.71 and 1.73      -- the near-empty echo, 505 to 559 gal (118 readings)
    else false end
$function$;
CREATE OR REPLACE FUNCTION public.fn_measure_vehicle_stop_tank_levels(p_from timestamp with time zone, p_execute boolean, p_spike_agree_m numeric DEFAULT 0.05, p_spike_jump_m numeric DEFAULT 0.15, p_hyst_sludge numeric DEFAULT 0.01, p_hyst_water numeric DEFAULT 0.05, p_period interval DEFAULT '00:10:00'::interval, p_lookahead interval DEFAULT '03:00:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_version constant smallint := 5;   -- v5 2026-10-16: sludge cannot drop before a client's pumping (5c, 6c). 4 is taken by
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
end $function$
;

-- Re-measure (c_version 5: every live row; the 35-day horizon is the cron's)
SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '35 days', true);

-- VERIFY: visit 6008's arrival (stop 1144) is the level carried in, and its visit reads about 352 gal
DO $verify$
declare v_af numeric; v_gal numeric;
begin
  select l.arrival_fill_fraction into v_af
    from public.vehicle_stop_tank_levels l join public.vehicle_tanks t on t.id = l.vehicle_tank_id and t.contents = 'sludge'
   where l.vehicle_stop_id = 1144 and l.superseded_at is null and l.algorithm_version = 5;
  select sludge_collected_gallons into v_gal from public.v_visit_tank_service where visit_id = 6008;
  if v_af is distinct from 0.7145 or v_gal not between 340 and 365 then
    raise exception 'v5 verify failed: stop 1144 arrival %, visit 6008 % gal', v_af, v_gal;
  end if;
  if exists (select 1 from public.vehicle_stop_tank_levels l join public.vehicle_stops s on s.id = l.vehicle_stop_id
              where l.superseded_at is null and l.algorithm_version < 5 and s.departed_at < now() - interval '3 hours') then
    raise exception 'v5 verify failed: live rows below version 5 remain';
  end if;
end $verify$;

COMMIT;
