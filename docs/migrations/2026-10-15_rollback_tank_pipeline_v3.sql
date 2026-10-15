-- ============================================================================
-- ROLLBACK of 2026-10-16 tank sensor pipeline v3 + water balance
-- The v2 measuring rules come back as version 4 (so every v3 row is re-measured), the F9 arm, the two water views
-- and the ghost functions go, and fn_stop_facts_checks returns to its v2 body. Run only while the v3 objects are as
-- v3 installed them (md5 guard).
-- LEFT IN PLACE (by design):
--   - the six columns on public.vehicle_stop_tank_levels (peak_fill_fraction, low_fill_fraction, departure_basis +
--     its CHECK, late_change_fill_fraction, late_change_measured_at, ghost_measurement_count): version 4 rows
--     leave them NULL; the superseded v3 rows keep theirs (append-only history);
--   - the columns appended to public.v_vehicle_stop_tank_changes (9) and public.v_visit_tank_service (7):
--     CREATE OR REPLACE VIEW cannot drop a column; they read NULL on version 4 rows.
-- A later re-apply of v3 must use c_version 5 or more: rows at version 4 are not re-measured by version 3.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));
DO $g$ BEGIN
  -- only roll back what v3 installed: if any of these changed since, merge by hand instead
  IF md5(pg_get_functiondef('public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)'::regprocedure)) IS DISTINCT FROM '7ce24a7b28cfa2dd0952720dcfb1d7e6'
     OR md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) IS DISTINCT FROM '2d8720d7875029f3fc64a890ddda0b9e'
     OR md5(pg_get_functiondef('public.fn_tank_reading_ghosts(bigint)'::regprocedure)) IS DISTINCT FROM 'ce31c5fc6e2e6d44df8c55b8399fa1b3'
     OR md5(pg_get_functiondef('public.fn_tank_ghost_distance_listed(text,numeric)'::regprocedure)) IS DISTINCT FROM '5cdfedae5911e7e4eff71d74fcf7e1c8'
     OR md5(pg_get_viewdef('public.v_vehicle_stop_tank_changes'::regclass)) IS DISTINCT FROM '2ba05a04624ba602481a7477a29e6011'
     OR md5(pg_get_viewdef('public.v_visit_tank_service'::regclass)) IS DISTINCT FROM 'bbbaa38e99b2f2d46dfb787a85cf25c0'
     OR md5(pg_get_viewdef('public.v_tank_data_quality_issues'::regclass)) IS DISTINCT FROM '584386bdb96f8249f9c24a36d338cc72'
     OR md5(pg_get_viewdef('public.v_visit_water_balance'::regclass)) IS DISTINCT FROM '5d4d6e161e46ba883dd0569bc3f8a67c'
     OR md5(pg_get_viewdef('public.v_vehicle_water_ledger'::regclass)) IS DISTINCT FROM '725bc5fc5ac62b5e14dfc825a4fee78b' THEN
    RAISE EXCEPTION 'rollback: an object changed since v3 was applied; merge by hand';
  END IF;
END $g$;
CREATE TEMP TABLE rb_t0 ON COMMIT DROP AS SELECT now() AS t;
DROP VIEW public.v_visit_water_balance;
DROP VIEW public.v_vehicle_water_ledger;
-- the v2 data-quality view (no F9: it calls fn_tank_ghost_distance_listed, dropped below)
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
  WHERE (ve.grease_tank_capacity_gallons IS DISTINCT FROM c.capacity_gallons);
CREATE OR REPLACE FUNCTION public.fn_measure_vehicle_stop_tank_levels(p_from timestamp with time zone, p_execute boolean, p_spike_agree_m numeric DEFAULT 0.05, p_spike_jump_m numeric DEFAULT 0.15, p_hyst_sludge numeric DEFAULT 0.01, p_hyst_water numeric DEFAULT 0.05, p_period interval DEFAULT '00:10:00'::interval, p_lookahead interval DEFAULT '03:00:00'::interval)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_version constant smallint := 4;   -- ROLLBACK of v3 (2026-10-16): the v2 rules as version 4, so every v3 row is re-measured
                                      -- (a later re-apply of v3 must use c_version 5 or more)
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

  -- 2026-10-14_1110: the time on site checks T1..T6 (fn_time_on_site_checks) ride in the integrity set
  return jsonb_build_object('integrity', z || public.fn_time_on_site_checks(), 'feed', t, 'flags', f, 'checked_at', now());
end $function$;
DROP FUNCTION public.fn_tank_reading_ghosts(bigint);
DROP FUNCTION public.fn_tank_ghost_distance_listed(text, numeric);
CREATE TEMP TABLE rb_remeasure ON COMMIT DROP AS SELECT public.fn_measure_vehicle_stop_tank_levels(now() - interval '35 days', true) AS r;
DO $v$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id
   WHERE l.superseded_at IS NULL AND s.superseded_at IS NULL AND l.algorithm_version <> 4
     AND s.departed_at + interval '3 hours' <= now();
  IF n <> 0 THEN RAISE EXCEPTION 'rollback: % ready live rows not re-measured', n; END IF;
  IF md5(pg_get_viewdef('public.v_tank_data_quality_issues'::regclass)) <> '8baceaa2b7707d9ecd62cfebba026bd5'
     OR md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) <> '893fa0d2d60d3a895c5e0d67021a8290' THEN
    RAISE EXCEPTION 'rollback: the data-quality view or the checks are not the v2 ones';
  END IF;
  -- version 4 is v2: every stop it re-measured that v2 had measured reads exactly what the last v2 row read
  SELECT count(*) INTO n
    FROM public.vehicle_stop_tank_levels l4
    JOIN LATERAL (SELECT * FROM public.vehicle_stop_tank_levels l2
                   WHERE l2.vehicle_stop_id = l4.vehicle_stop_id AND l2.vehicle_tank_id = l4.vehicle_tank_id
                     AND l2.algorithm_version = 2
                   ORDER BY l2.id DESC LIMIT 1) l2 ON true
   WHERE l4.superseded_at IS NULL AND l4.algorithm_version = 4
     AND (l4.arrival_measured_at IS DISTINCT FROM l2.arrival_measured_at
          OR l4.departure_measured_at IS DISTINCT FROM l2.departure_measured_at
          OR l4.arrival_fill_fraction IS DISTINCT FROM l2.arrival_fill_fraction
          OR l4.departure_fill_fraction IS DISTINCT FROM l2.departure_fill_fraction
          OR l4.fill_fraction_risen IS DISTINCT FROM l2.fill_fraction_risen
          OR l4.fill_fraction_fallen IS DISTINCT FROM l2.fill_fraction_fallen
          OR l4.measurement_count IS DISTINCT FROM l2.measurement_count);
  IF n <> 0 THEN RAISE EXCEPTION 'rollback: % stops read differently under version 4 than under v2', n; END IF;
  SELECT count(*) INTO n FROM public.vehicle_stop_tank_levels l4
   WHERE l4.superseded_at IS NULL AND l4.algorithm_version = 4
     AND EXISTS (SELECT 1 FROM public.vehicle_stop_tank_levels l2 WHERE l2.vehicle_stop_id = l4.vehicle_stop_id AND l2.algorithm_version = 2);
  IF n < 400 THEN RAISE EXCEPTION 'rollback: only % stops compared with v2: the check proves little', n; END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
