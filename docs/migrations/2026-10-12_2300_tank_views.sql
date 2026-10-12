-- 2026-10-12 23:00 ET · Tank sensor views: site addresses, levels, stop facts, tank changes, visit service, dumps, issues (M6)
-- APPLIED to Prod 2026-10-12 ~19:15 ET after a rolled-back run of this file.
-- Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 5.6, 5.7, 5.8, 6, 8, 10.2 M6).
-- Builds on the APPLIED 2026-10-12_2200_vehicle_stop_facts (M4) and _2250 (M5, hourly refresh).
--
-- WHAT (seven views in public, owner-rights, service_role SELECT only; nothing writes through them)
--   v_vehicle_site_addresses     property_id, site_kind (dump_site | yard), samsara_address_id: the map the Samsara
--                                readings collector (scripts/sync/cron_samsara_tank_readings.js, siteAddressMap) reads
--                                to resolve addressEntry/addressExit. Dump sites = ops.v_dump_sites properties whose
--                                client is a non_customer_clients 'dump_site'; the yard = ops.v_depot (property 1194,
--                                client 000-YD). Today: 98 (000-DH), 155 (000-DP), 1194 (yard).
--   v_tank_levels                per distance reading: tank in force, configuration in force, fraction, percent,
--                                gallons (NULL without capacity), Samsara's own percent at the same instant
--   v_vehicle_stop_facts         per live stop: duration, kind (dump, yard, client, parked, other), RPM pump minutes,
--                                PTO minutes, pump signature, engine data present, live link count, nearest live
--                                service property within 300 m for 'other' stops
--   v_vehicle_stop_tank_changes  per live level row: arrival/departure percent and gallons, net, risen, fallen,
--                                too_short, at_ceiling, configuration and installation ids
--   v_visit_tank_service         per completed live visit since 2026-08-20: links, stop and pump minutes, sludge
--                                collected and gross with confidence and reason (plan 5.7), water used and refilled
--                                (percentage points; gallons when the capacity is known), time-on-site disagreement
--   v_vehicle_dumps              per live dump stop: offload, plausibility, collected since the previous dump, ratio
--   v_tank_data_quality_issues   one row per open business flag F1, F1b, F2, F3, F4, F5, F6, F7, F8 (plan section 8)
--
-- WHY
--   Owner voice note, 2026-10-12: "how long they stayed on that client, how much water was used, how much sludge was
--   pumped out", "how much sludge did we really pump out". Owner, 2026-10-12: "Before showing it on an app, let's
--   work on it to be correct everything in the DB". These views are the SQL answer; no app reads them until D6 (M9
--   wraps them in ops.*). Gallons, percent, durations, kinds, shares and pump minutes are computed here and never
--   stored (rule 11).
--
-- OWNER DECISIONS APPLIED (2026-10-12, through the coordinator)
--   Dump offload plausibility: a dump is LOW (implausible_offload) when its offload is below 10 % of the tank capacity
--   OR its departure fill is 0.90 or more. This replaces the plan's "departure >= arrival, departure >= 0.97 or
--   offload <= 0", which it contains. The 10-01 dump (sensor stuck at 95 to 97 % through the dump, 38 gal) is LOW;
--   the rest of the rule is unchanged: edge_missing is low, arrival >= 0.97 is medium (lower_bound), else high.
--   Noise thresholds stay algorithm version 1. Visit 8759 (a second Dump Offload record with no second dump stop) is
--   flag only (F1b, D14 default). The 12-hour stale-entry limit of fn_build_vehicle_stops stays.
--   D11 defaults: sludge is shared only among the stop's Pumping (volume) links, by trap size when every such
--   property has one, else equally; water equally among the stop's non-dump links; time is not divided.
--
-- 3NF: views store nothing. RULE 8: no table created or changed; nothing to audit.
-- GRANTS: each view revoked BY NAME from public, anon, authenticated and service_role, then SELECT to service_role
--   (asserted with has_table_privilege below). Owner-rights (no security_invoker), owned by postgres, so the M9 ops
--   wrappers can select from them. Function EXECUTE inside them is checked against the CALLER: service_role holds
--   EXECUTE on public.fn_tank_fill_fraction and ops.fn_haversine_km (asserted below). They read
--   public.non_customer_clients directly rather than calling fn_is_non_customer, so no third EXECUTE dependency.
-- COMPLIANCE BOUNDARY (N1): nothing in derm.*, customer.* or client.* may read these. Asserted below with pg_depend
--   (positive control: derm.v_lwt_monthly_rows depends on public.vehicles) and with fn_stop_facts_checks' Z8 body
--   sweep (positive control found). The repo grep of supabase/functions/ for the seven names returned 0 (M6 probe).
-- LOCKS: CREATE VIEW takes no lock that blocks app reads or writes of the base tables; SET LOCAL lock_timeout '3s'.
--   NOTIFY pgrst so the collector's REST call sees v_vehicle_site_addresses at its next run.
-- VERIFY (below): ACL matrix per view; service_role EXECUTE on the two functions; 0 rows carry water gallons while
--   the configuration capacity is NULL (and the probe proved it on a NULL-capacity correction); the site address map
--   lists 98, 155 and 1194 with their Samsara ids; boundary checks. Behaviour (every view against real data, the M6
--   dump rule on 10-01 / 10-06 / 10-09, the issue rows) was proven by rolled-back probes before apply.
-- ROLLBACK: drop view public.v_tank_data_quality_issues, public.v_vehicle_dumps, public.v_visit_tank_service,
--   public.v_vehicle_stop_tank_changes, public.v_vehicle_stop_facts, public.v_tank_levels,
--   public.v_vehicle_site_addresses;  (the collector falls back to its ESL dump-site resolver on a 404)

begin;
set local lock_timeout = '3s';

-- ============================================================ 1. SITE ADDRESSES (plan 3.2, 6)
create view public.v_vehicle_site_addresses as
select e.entity_id as property_id, s.site_kind, regexp_replace(e.source_id, '^addr_', '') as samsara_address_id
  from public.entity_source_links e
  join (select d.property_id, 'dump_site'::text as site_kind
          from ops.v_dump_sites d
         where exists (select 1 from public.non_customer_clients n where n.client_id = d.client_id and n.kind = 'dump_site')
        union
        select y.property_id, 'yard'::text from ops.v_depot y) s on s.property_id = e.entity_id
 where e.entity_type = 'property' and e.source_system = 'samsara';

-- ============================================================ 2. TANK LEVELS (one row per distance reading)
create view public.v_tank_levels as
select vt.vehicle_id, vt.id as vehicle_tank_id, vt.contents, d.tank_sensor_id, d.recorded_at, d.distance_meters,
       d.distance_meters is distinct from lag(d.distance_meters) over (partition by d.tank_sensor_id order by d.recorded_at)
         as is_new_measurement,
       c.id as vehicle_tank_configuration_id, i.id as tank_sensor_installation_id,
       f.fill_fraction,
       round(100 * f.fill_fraction, 3) as fill_percent,
       round(f.fill_fraction * c.capacity_gallons, 1) as gallons,            -- NULL while the capacity is unknown
       fp.fill_percent as samsara_fill_percent
  from public.tank_sensor_distance_readings d
  join lateral (select i.* from public.tank_sensor_installations i
                 where i.tank_sensor_id = d.tank_sensor_id and i.superseded_at is null
                   and i.installed_at <= d.recorded_at and d.recorded_at < coalesce(i.removed_at, 'infinity')
                 order by i.installed_at desc limit 1) i on true
  join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id and vt.deleted_at is null
  join lateral (select c.* from public.vehicle_tank_configurations c
                 where c.vehicle_tank_id = vt.id and c.superseded_at is null and c.effective_from <= d.recorded_at
                 order by c.effective_from desc limit 1) c on true
  cross join lateral (select public.fn_tank_fill_fraction(d.distance_meters, c.diameter_meters, c.sensor_offset_meters) as fill_fraction) f
  left join public.tank_sensor_fill_percent_readings fp
    on fp.tank_sensor_id = d.tank_sensor_id and fp.recorded_at = d.recorded_at;

-- ============================================================ 3. STOP FACTS (plan 5.6, 5.7 pump signature, 5.8 kind)
create view public.v_vehicle_stop_facts as
select s.id as vehicle_stop_id, s.vehicle_id, s.arrived_at, s.departed_at,
       round(extract(epoch from s.departed_at - s.arrived_at) / 60, 1) as duration_minutes,
       s.latitude, s.longitude, s.gps_fix_count, s.site_property_id, s.formation,
       k.kind,
       e.rpm_pump_minutes, p.pto_minutes,
       (e.rpm_pump_minutes >= 5 or p.pto_minutes >= 1) as pump_signature,
       e.engine_data_present,
       lc.live_link_count,
       np.nearest_property_id
  from public.vehicle_stops s
  cross join lateral (select count(*)::int as live_link_count from public.visit_vehicle_stops l
                       where l.vehicle_stop_id = s.id and l.deleted_at is null) lc
  cross join lateral (
    select case when exists (select 1 from public.properties sp join public.non_customer_clients n on n.client_id = sp.client_id
                              where sp.id = s.site_property_id and n.kind = 'dump_site') then 'dump'
                when s.site_property_id = (select y.property_id from ops.v_depot y limit 1) then 'yard'
                when lc.live_link_count > 0 then 'client'
                when s.departed_at - s.arrived_at >= interval '4 hours' then 'parked'
                else 'other' end as kind) k
  -- RPM pump minutes: sum of min(gap to next sample, 5 min) over samples >= 900 inside the stop
  cross join lateral (
    select coalesce(round((sum(extract(epoch from least(coalesce(r.nxt, s.departed_at) - r.recorded_at, interval '5 minutes')))
                             filter (where r.engine_rpm >= 900) / 60)::numeric, 1), 0) as rpm_pump_minutes,
           count(*) > 0 as engine_data_present
      from (select r.recorded_at, r.engine_rpm, lead(r.recorded_at) over (order by r.recorded_at) as nxt
              from public.vehicle_engine_rpm_readings r
             where r.vehicle_id = s.vehicle_id and r.recorded_at between s.arrived_at and s.departed_at) r) e
  -- PTO minutes: the PTO state intervals (from the last reading at or before arrival) intersected with the stop
  cross join lateral (
    select coalesce(round((sum(extract(epoch from least(coalesce(x.nxt, s.departed_at), s.departed_at)
                                                - greatest(x.recorded_at, s.arrived_at))) filter (where x.pto_engaged) / 60)::numeric, 1), 0)
             as pto_minutes
      from (select q.recorded_at, q.pto_engaged, lead(q.recorded_at) over (order by q.recorded_at) as nxt
              from public.vehicle_pto_readings q
             where q.vehicle_id = s.vehicle_id and q.recorded_at <= s.departed_at
               and q.recorded_at >= coalesce((select max(q2.recorded_at) from public.vehicle_pto_readings q2
                                               where q2.vehicle_id = s.vehicle_id and q2.recorded_at <= s.arrived_at), s.arrived_at)) x
     where coalesce(x.nxt, s.departed_at) > s.arrived_at) p
  -- nearest live service property within 300 m, for 'other' stops only (plan 6)
  left join lateral (
    select pp.id as nearest_property_id from public.properties pp
     where k.kind = 'other' and pp.deleted_at is null and coalesce(pp.is_billing, false) = false
       and pp.latitude between s.latitude - 0.003 and s.latitude + 0.003
       and pp.longitude between s.longitude - 0.0035 and s.longitude + 0.0035
       and ops.fn_haversine_km(pp.latitude, pp.longitude, s.latitude, s.longitude) <= 0.3
     order by ops.fn_haversine_km(pp.latitude, pp.longitude, s.latitude, s.longitude), pp.id limit 1) np on true
 where s.superseded_at is null;

-- ============================================================ 4. TANK CHANGES PER STOP
create view public.v_vehicle_stop_tank_changes as
select l.id as vehicle_stop_tank_level_id, l.vehicle_stop_id, l.vehicle_id, l.vehicle_tank_id, t.contents,
       l.tank_sensor_installation_id, l.vehicle_tank_configuration_id, c.capacity_gallons,
       l.arrival_measured_at, l.arrival_fill_fraction,
       round(100 * l.arrival_fill_fraction, 3) as arrival_percent,
       round(l.arrival_fill_fraction * c.capacity_gallons, 1) as arrival_gallons,
       l.departure_measured_at, l.departure_fill_fraction,
       round(100 * l.departure_fill_fraction, 3) as departure_percent,
       round(l.departure_fill_fraction * c.capacity_gallons, 1) as departure_gallons,
       l.departure_fill_fraction - l.arrival_fill_fraction as net_fill_fraction,
       round(100 * (l.departure_fill_fraction - l.arrival_fill_fraction), 3) as net_percent_points,
       round((l.departure_fill_fraction - l.arrival_fill_fraction) * c.capacity_gallons, 1) as net_gallons,
       l.fill_fraction_risen, round(100 * l.fill_fraction_risen, 3) as risen_percent_points,
       round(l.fill_fraction_risen * c.capacity_gallons, 1) as risen_gallons,
       l.fill_fraction_fallen, round(100 * l.fill_fraction_fallen, 3) as fallen_percent_points,
       round(l.fill_fraction_fallen * c.capacity_gallons, 1) as fallen_gallons,
       (l.fill_fraction_risen is null and l.arrival_fill_fraction is not null and l.departure_fill_fraction is not null) as too_short,
       coalesce(l.departure_fill_fraction >= 0.98, false) as at_ceiling,
       l.measurement_count, l.rejected_measurement_count, l.algorithm_version
  from public.vehicle_stop_tank_levels l
  join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
  join public.vehicle_tanks t on t.id = l.vehicle_tank_id
  join public.vehicle_tank_configurations c on c.id = l.vehicle_tank_configuration_id
 where l.superseded_at is null;

-- ============================================================ 5. DUMPS (plan 5.8, owner rule of 2026-10-12)
create view public.v_vehicle_dumps as
with d as (
  select f.vehicle_stop_id, f.vehicle_id, f.arrived_at, f.departed_at, f.duration_minutes, f.site_property_id, f.formation,
         tc.arrival_fill_fraction, tc.departure_fill_fraction, tc.capacity_gallons,
         round((tc.arrival_fill_fraction - tc.departure_fill_fraction) * tc.capacity_gallons, 1) as offload_gallons,
         case when tc.vehicle_stop_tank_level_id is null then 'no_sensor'
              when tc.capacity_gallons is null then 'no_capacity'
              when tc.arrival_fill_fraction is null or tc.departure_fill_fraction is null then 'edge_missing'
              when (tc.arrival_fill_fraction - tc.departure_fill_fraction) < 0.10   -- offload below 10 % of capacity
                   or tc.departure_fill_fraction >= 0.90 then 'implausible_offload'
              when tc.arrival_fill_fraction >= 0.97 then 'lower_bound'
              else 'ok' end as offload_reason
    from public.v_vehicle_stop_facts f
    left join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f.vehicle_stop_id and tc.contents = 'sludge'
   where f.kind = 'dump'),
c as (
  select d.*,
         case d.offload_reason when 'no_sensor' then 'none' when 'no_capacity' then 'none' when 'ok' then 'high'
                               when 'lower_bound' then 'medium' else 'low' end as offload_confidence,
         lag(d.departed_at) over w as previous_dump_departed_at,
         lag(d.offload_reason) over w as previous_offload_reason
    from d window w as (partition by d.vehicle_id order by d.arrived_at)),
cy as (
  select c.*,
         (select round(sum(greatest(tc.net_gallons, 0)), 1)
            from public.v_vehicle_stop_facts f2
            join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f2.vehicle_stop_id and tc.contents = 'sludge'
           where f2.vehicle_id = c.vehicle_id and f2.kind in ('client','other')
             and f2.arrived_at >= c.previous_dump_departed_at and f2.arrived_at < c.arrived_at) as collected_since_previous_dump_gallons,
         coalesce((select bool_or(tc.net_gallons <= -300)
                     from public.v_vehicle_stop_facts f2
                     join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f2.vehicle_stop_id and tc.contents = 'sludge'
                    where f2.vehicle_id = c.vehicle_id and f2.kind <> 'dump'
                      and f2.arrived_at >= c.previous_dump_departed_at and f2.arrived_at < c.arrived_at), false) as cycle_offsite_drop
    from c)
select cy.vehicle_stop_id, cy.vehicle_id, cy.arrived_at, cy.departed_at, cy.duration_minutes, cy.site_property_id, cy.formation,
       cy.arrival_fill_fraction, cy.departure_fill_fraction, cy.capacity_gallons, cy.offload_gallons,
       cy.offload_confidence, cy.offload_reason, cy.previous_dump_departed_at,
       cy.collected_since_previous_dump_gallons, cy.cycle_offsite_drop,
       case when cy.offload_confidence in ('high','medium') and cy.previous_offload_reason in ('ok','lower_bound')
                 and not cy.cycle_offsite_drop and cy.collected_since_previous_dump_gallons > 0
            then round(cy.offload_gallons / cy.collected_since_previous_dump_gallons, 3) end as ratio,
       (select l.visit_id from public.visit_vehicle_stops l
         where l.vehicle_stop_id = cy.vehicle_stop_id and l.deleted_at is null
           and l.match_basis in ('dump_completion','dump_window')) as dump_visit_id
  from cy;

-- ============================================================ 6. VISIT SERVICE (plan 5.6, 5.7, 5.8 water)
create view public.v_visit_tank_service as
with lk as (                 -- every live link, with what the share rules need
  select l.visit_id, l.vehicle_stop_id, l.match_basis,
         exists (select 1 from public.non_customer_clients n where n.client_id = vl.client_id and n.kind = 'dump_site') as is_dump,
         vl.service_type = 'Pumping'
           and not exists (select 1 from public.non_customer_clients n where n.client_id = vl.client_id and n.kind = 'dump_site') as is_volume,
         pp.grease_trap_size_gallons as trap
    from public.visit_vehicle_stops l
    join public.v_visits_live vl on vl.id = l.visit_id
    left join public.properties pp on pp.id = vl.property_id
   where l.deleted_at is null),
sh as (
  select lk.*,
         case when not lk.is_volume then 0::numeric
              when bool_and(coalesce(lk.trap, 0) > 0) filter (where lk.is_volume) over (partition by lk.vehicle_stop_id)
                then lk.trap::numeric / sum(lk.trap) filter (where lk.is_volume) over (partition by lk.vehicle_stop_id)
              else 1.0 / count(*) filter (where lk.is_volume) over (partition by lk.vehicle_stop_id) end as sludge_share,
         case when lk.is_dump then 0::numeric
              else 1.0 / count(*) filter (where not lk.is_dump) over (partition by lk.vehicle_stop_id) end as water_share,
         count(*) filter (where lk.is_volume) over (partition by lk.vehicle_stop_id) as volume_links_on_stop,
         count(*) over (partition by lk.vehicle_stop_id) as links_on_stop
    from lk),
v as (
  select vl.id as visit_id, vl.vehicle_id, vl.client_id, vl.property_id, vl.visit_date, vl.completed_at, vl.service_type,
         vl.duration_minutes,
         exists (select 1 from public.non_customer_clients n where n.client_id = vl.client_id and n.kind = 'dump_site') as is_dump,
         pp.grease_trap_size_gallons as trap
    from public.v_visits_live vl
    left join public.properties pp on pp.id = vl.property_id
   where vl.visit_status = 'completed' and vl.visit_date >= date '2026-08-20'),
agg as (
  select v.visit_id as a_visit_id,
         count(sh.vehicle_stop_id)::int as link_count,
         array_agg(distinct sh.match_basis) filter (where sh.match_basis is not null) as match_bases,
         sum(f.duration_minutes) as stop_minutes,
         sum(f.rpm_pump_minutes) as pump_minutes,
         sum(f.pto_minutes) as pto_minutes,
         bool_or(f.pump_signature) as pump_signature,
         bool_or(f.engine_data_present) as engine_data_present,
         bool_or(sh.links_on_stop > 1) as shared_stop,
         bool_or(sh.volume_links_on_stop > 1) as shared_volume_stop,
         bool_or(sh.match_basis = 'window') as has_window_link,
         min(f.arrived_at) as first_arrived_at,
         -- sludge
         bool_or(ts.vehicle_stop_tank_level_id is null) as sludge_row_missing,
         bool_or(ts.arrival_fill_fraction is null or ts.departure_fill_fraction is null) as sludge_edge_missing,
         bool_or(ts.too_short) as sludge_too_short,
         bool_or(ts.at_ceiling) as sludge_at_ceiling,
         sum(sh.sludge_share * ts.net_gallons) as sludge_net,
         sum(sh.sludge_share * ts.risen_gallons) as sludge_gross,
         -- water (NULL propagates: one linked stop without a water measurement makes the visit's figure NULL)
         bool_or(tw.vehicle_stop_tank_level_id is null or tw.fill_fraction_fallen is null) as water_incomplete,
         bool_or(tw.capacity_gallons is null) as water_capacity_unknown,
         sum(sh.water_share * tw.fill_fraction_fallen) as water_used_fraction,
         sum(sh.water_share * tw.fill_fraction_risen) as water_refilled_fraction,
         sum(sh.water_share * tw.fallen_gallons) as water_used_gal,
         sum(sh.water_share * tw.risen_gallons) as water_refilled_gal
    from v
    left join sh on sh.visit_id = v.visit_id
    left join public.v_vehicle_stop_facts f on f.vehicle_stop_id = sh.vehicle_stop_id
    left join public.v_vehicle_stop_tank_changes ts on ts.vehicle_stop_id = sh.vehicle_stop_id and ts.contents = 'sludge'
    left join public.v_vehicle_stop_tank_changes tw on tw.vehicle_stop_id = sh.vehicle_stop_id and tw.contents = 'fresh_water'
   group by v.visit_id),
x as (
  select v.*, agg.*,
         (not v.is_dump and v.service_type = 'Pumping') as is_volume,
         exists (select 1 from public.tank_sensor_installations i
                   join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id and vt.deleted_at is null
                  where vt.vehicle_id = v.vehicle_id and vt.contents = 'sludge' and i.superseded_at is null
                    and i.installed_at <= coalesce(agg.first_arrived_at, v.completed_at)
                    and coalesce(agg.first_arrived_at, v.completed_at) < coalesce(i.removed_at, 'infinity')) as has_sludge_sensor,
         exists (select 1 from public.tank_sensor_installations i
                   join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id and vt.deleted_at is null
                  where vt.vehicle_id = v.vehicle_id and vt.contents = 'fresh_water' and i.superseded_at is null
                    and i.installed_at <= coalesce(agg.first_arrived_at, v.completed_at)
                    and coalesce(agg.first_arrived_at, v.completed_at) < coalesce(i.removed_at, 'infinity')) as has_water_sensor
    from v join agg on agg.a_visit_id = v.visit_id),
r as (
  select x.*,
         case when not x.is_volume                     then 'not_a_volume_visit'
              when not x.has_sludge_sensor             then 'no_sensor'
              when x.link_count = 0                    then 'no_stop'
              when x.sludge_row_missing                then 'no_config'
              when x.sludge_edge_missing               then 'edge_missing'
              when x.sludge_too_short                  then 'too_short'
              when x.trap <= 75                        then 'below_resolution'
              when x.sludge_at_ceiling                 then 'tank_at_ceiling'
              when x.trap is not null and x.sludge_net > 1.5 * x.trap + 40 then 'exceeds_trap_size'
              when x.sludge_net < 40 and coalesce(x.pump_signature, false) then 'pumped_no_rise'
              when x.sludge_net >= 40 and x.engine_data_present and not coalesce(x.pump_signature, false) then 'rise_without_pump'
              when x.trap is null                      then 'trap_size_unknown'
              when x.has_window_link                   then 'window_match'
              when x.shared_volume_stop                then 'shared_stop_allocated'
              when not coalesce(x.engine_data_present, false) then 'no_pump_signal'
              else 'ok' end as sludge_reason
    from x)
select r.visit_id, r.vehicle_id, r.client_id, r.property_id, r.visit_date, r.completed_at, r.service_type,
       case when r.is_dump then 'dump' when r.is_volume then 'volume' else 'other' end as visit_kind,
       r.link_count, r.match_bases, r.shared_stop,
       r.stop_minutes, r.duration_minutes,
       (r.stop_minutes is not null and r.duration_minutes is not null and abs(r.stop_minutes - r.duration_minutes) > 15)
         as time_on_site_disagreement,
       r.pump_minutes, r.pto_minutes, r.pump_signature, r.engine_data_present,
       case when r.sludge_reason in ('not_a_volume_visit','no_sensor','no_stop','no_config','edge_missing') then null
            else round(r.sludge_net, 1) end as sludge_collected_gallons,
       case when r.sludge_reason in ('not_a_volume_visit','no_sensor','no_stop','no_config','edge_missing') then null
            else round(r.sludge_gross, 1) end as sludge_gross_intake_gallons,
       case when r.sludge_reason in ('not_a_volume_visit','no_sensor','no_stop','no_config','edge_missing') then 'none'
            when r.sludge_reason in ('too_short','below_resolution','tank_at_ceiling','exceeds_trap_size',
                                     'pumped_no_rise','rise_without_pump') then 'low'
            when r.sludge_reason = 'ok' then 'high' else 'medium' end as sludge_confidence,
       r.sludge_reason,
       case when r.link_count = 0 or not r.has_water_sensor or r.water_incomplete then null
            else round(100 * r.water_used_fraction, 1) end as water_used_percent_points,
       case when r.link_count = 0 or not r.has_water_sensor or r.water_incomplete then null
            else round(100 * r.water_refilled_fraction, 1) end as water_refilled_percent_points,
       case when r.link_count = 0 or not r.has_water_sensor or r.water_incomplete or r.water_capacity_unknown then null
            else round(r.water_used_gal, 1) end as water_used_gallons,
       case when r.link_count = 0 or not r.has_water_sensor or r.water_incomplete or r.water_capacity_unknown then null
            else round(r.water_refilled_gal, 1) end as water_refilled_gallons,
       case when not r.has_water_sensor or r.link_count = 0 or r.water_incomplete then 'none' else 'low' end as water_confidence,
       case when not r.has_water_sensor then 'no_sensor'
            when r.link_count = 0 then 'no_stop'
            when r.water_incomplete then 'measurement_missing'
            when r.water_capacity_unknown then 'percent_only'
            else 'unvalidated' end as water_reason          -- low in v1: rinse water cannot be separated (N7, D12)
  from r;

-- ============================================================ 7. DATA QUALITY ISSUES (plan 8, business flags)
-- One row per open business flag. Must-be-zero (Z) and feed (T) checks are counted by fn_stop_facts_checks into
-- the sync_log sources stop_facts_integrity, tank_feed_freshness and tank_geometry_drift, not repeated here.
create view public.v_tank_data_quality_issues as
with gps_vehicle as (select e.entity_id as vehicle_id from public.entity_source_links e
                      where e.entity_type = 'vehicle' and e.source_system = 'samsara'),
sv as (select * from public.v_visit_tank_service)
-- F1 completed volume visit on a GPS truck with no live link
select 'F1'::text as issue_code, 'pumping_visit_without_stop'::text as issue, 'business_flag'::text as severity,
       sv.vehicle_id, sv.visit_id, null::bigint as vehicle_stop_id, null::bigint as nearest_property_id,
       'completed ' || sv.service_type || ' visit of ' || sv.visit_date || ' has no stop of its truck linked' as detail
  from sv where sv.visit_kind = 'volume' and sv.link_count = 0 and sv.vehicle_id in (select vehicle_id from gps_vehicle)
union all
-- F1b completed dump visit with no dump link (none: no dump stop of its site in its window; ambiguous: several)
select 'F1b', 'dump_visit_without_dump_stop', 'business_flag', sv.vehicle_id, sv.visit_id, null, null,
       case when (select count(*) from public.v_vehicle_dumps dd join public.properties sp on sp.id = dd.site_property_id
                   where dd.vehicle_id = sv.vehicle_id and sp.client_id = sv.client_id and dd.dump_visit_id is null
                     and dd.arrived_at >= (sv.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
                     and dd.arrived_at < ((sv.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York') > 1
            then 'ambiguous: several unlinked dump stops of its site in its window'
            else 'none: no unlinked dump stop of its site in its window' end
  from sv
 where sv.visit_kind = 'dump' and sv.vehicle_id is not null
   and not exists (select 1 from public.visit_vehicle_stops l where l.visit_id = sv.visit_id and l.deleted_at is null
                      and l.match_basis in ('dump_completion','dump_window'))
union all
-- F2 work with no visit: a client/other stop that rose 40 gal or more with a pump signature and no volume link
select 'F2', 'unlinked_work', 'business_flag', f.vehicle_id, null, f.vehicle_stop_id,
       coalesce(f.nearest_property_id, (select pp.id from public.properties pp
         where pp.deleted_at is null and coalesce(pp.is_billing, false) = false
           and pp.latitude between f.latitude - 0.003 and f.latitude + 0.003
           and pp.longitude between f.longitude - 0.0035 and f.longitude + 0.0035
           and ops.fn_haversine_km(pp.latitude, pp.longitude, f.latitude, f.longitude) <= 0.3
         order by ops.fn_haversine_km(pp.latitude, pp.longitude, f.latitude, f.longitude), pp.id limit 1)),
       'stop rose ' || round(tc.net_gallons) || ' gal with a pump signature and no Pumping visit linked'
  from public.v_vehicle_stop_facts f
  join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f.vehicle_stop_id and tc.contents = 'sludge'
 where f.kind in ('client','other') and tc.net_gallons >= 40 and f.pump_signature
   and not exists (select 1 from public.visit_vehicle_stops l join public.v_visits_live vl on vl.id = l.visit_id
                    where l.vehicle_stop_id = f.vehicle_stop_id and l.deleted_at is null and vl.service_type = 'Pumping'
                      and not exists (select 1 from public.non_customer_clients n where n.client_id = vl.client_id and n.kind = 'dump_site'))
union all
-- F3 dump stop with no dump visit
select 'F3', 'dump_without_record', 'business_flag', dd.vehicle_id, null, dd.vehicle_stop_id, null,
       'dump stop with no Dump Offload visit linked'
  from public.v_vehicle_dumps dd where dd.dump_visit_id is null
union all
-- F4 collected vs dumped ratio outside 0.75 to 1.25
select 'F4', 'dump_ratio_out_of_band', 'business_flag', dd.vehicle_id, dd.dump_visit_id, dd.vehicle_stop_id, null,
       'offload ' || round(dd.offload_gallons) || ' gal vs collected ' || round(dd.collected_since_previous_dump_gallons)
       || ' gal since the previous dump: ratio ' || dd.ratio
  from public.v_vehicle_dumps dd where dd.ratio is not null and (dd.ratio < 0.75 or dd.ratio > 1.25)
union all
-- F5 large drop not at a dump (yard decants, transfers, unknown sites)
select 'F5', 'large_drop_not_at_dump', 'business_flag', f.vehicle_id, null, f.vehicle_stop_id, f.nearest_property_id,
       f.kind || ' stop fell ' || round(-tc.net_gallons) || ' gal'
  from public.v_vehicle_stop_facts f
  join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f.vehicle_stop_id and tc.contents = 'sludge'
 where f.kind <> 'dump' and tc.net_gallons <= -300
union all
-- F6 possible wrong truck: no link on its own truck, while another truck stopped within 150 m in W(V) with a rise or
-- a pump signature
select 'F6', 'possible_wrong_truck', 'business_flag', sv.vehicle_id, sv.visit_id, o.vehicle_stop_id, null,
       'truck ' || o.vehicle_id || ' stopped within 150 m at ' || to_char(o.arrived_at at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI') || ' ET'
  from sv
  join public.properties vp on vp.id = sv.property_id and vp.latitude is not null
  cross join lateral (
    select f.vehicle_stop_id, f.vehicle_id, f.arrived_at from public.v_vehicle_stop_facts f
      left join public.v_vehicle_stop_tank_changes tc on tc.vehicle_stop_id = f.vehicle_stop_id and tc.contents = 'sludge'
     where f.vehicle_id <> sv.vehicle_id and f.site_property_id is null
       and f.arrived_at >= (sv.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and f.arrived_at < ((sv.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York'
       and ops.fn_haversine_km(vp.latitude, vp.longitude, f.latitude, f.longitude) <= 0.15
       and (coalesce(tc.net_gallons, 0) >= 40 or f.pump_signature)
     order by f.arrived_at limit 1) o
 where sv.visit_kind <> 'dump' and sv.link_count = 0 and sv.vehicle_id is not null
union all
-- F7 stop minutes and the official duration differ by more than 15 minutes
select 'F7', 'time_on_site_disagreement', 'business_flag', sv.vehicle_id, sv.visit_id, null, null,
       'stops ' || round(sv.stop_minutes) || ' min vs duration_minutes ' || sv.duration_minutes
  from sv where sv.time_on_site_disagreement
union all
-- F8 the fleet capacity differs from the sludge capacity in force (do NOT fix it by editing vehicles: see detail)
select 'F8', 'capacity_mismatch', 'business_flag', ve.id, null, null, null,
       'vehicles.grease_tank_capacity_gallons ' || coalesce(ve.grease_tank_capacity_gallons::text, 'NULL')
       || ' vs ' || c.capacity_gallons || ' in force. Editing vehicles rewrites past LWT rows '
       || '(derm.v_lwt_monthly_rows reads it live): owner approval needed (D10)'
  from public.vehicles ve
  join public.vehicle_tanks vt on vt.vehicle_id = ve.id and vt.contents = 'sludge' and vt.deleted_at is null
  join lateral (select c.capacity_gallons from public.vehicle_tank_configurations c
                 where c.vehicle_tank_id = vt.id and c.superseded_at is null and c.effective_from <= now()
                 order by c.effective_from desc limit 1) c on true
 where ve.grease_tank_capacity_gallons is distinct from c.capacity_gallons;

-- ---------------------------------------------------------------- grants + comments
revoke all on public.v_vehicle_site_addresses, public.v_tank_levels, public.v_vehicle_stop_facts,
              public.v_vehicle_stop_tank_changes, public.v_visit_tank_service, public.v_vehicle_dumps,
              public.v_tank_data_quality_issues
  from public, anon, authenticated, service_role;
grant select on public.v_vehicle_site_addresses, public.v_tank_levels, public.v_vehicle_stop_facts,
                public.v_vehicle_stop_tank_changes, public.v_visit_tank_service, public.v_vehicle_dumps,
                public.v_tank_data_quality_issues
  to service_role;

comment on view public.v_vehicle_site_addresses is
  'Samsara address id -> site property (dump sites and the yard), from entity_source_links. Read by the Samsara '
  'readings collector to resolve addressEntry/addressExit. service_role only. Tank sensors plan 2026-10-12, M6.';
comment on view public.v_tank_levels is
  'Every LM11 distance reading with the tank and configuration in force, fill fraction, percent, gallons (NULL '
  'without capacity) and Samsara''s own percent. service_role only.';
comment on view public.v_vehicle_stop_facts is
  'Per live stop: duration, kind (dump, yard, client, parked >= 4 h, other), RPM pump minutes (>= 900 rpm), PTO '
  'minutes, pump signature (>= 5 RPM minutes or >= 1 PTO minute), links, nearest property for other stops. '
  'Staff sensitivity: parked and other stops are personal stops; app wrappers (M9) must not expose their coordinates.';
comment on view public.v_vehicle_stop_tank_changes is
  'Per live level row: arrival/departure, net, risen and fallen as fractions, percent and gallons; too_short, '
  'at_ceiling; provenance ids. service_role only.';
comment on view public.v_visit_tank_service is
  'Per completed live visit since 2026-08-20: linked stops, stop and pump minutes, sludge collected and gross intake '
  'with confidence and reason (plan 5.7, first failing check wins), water used/refilled (pp and gallons, confidence '
  'low in v1), time-on-site disagreement (F7). Not for regulator filings (N1, D8).';
comment on view public.v_vehicle_dumps is
  'Per live dump stop: offload, confidence (owner rule 2026-10-12: low when the offload is below 10 % of capacity or '
  'the departure fill is 0.90 or more), collected since the previous dump, off-site drop, ratio, dump visit.';
comment on view public.v_tank_data_quality_issues is
  'One row per open business flag (F1, F1b, F2 to F8, plan section 8). Z and T checks live in sync_log '
  '(stop_facts_integrity, tank_feed_freshness, tank_geometry_drift).';

-- ============================================================ VERIFY
do $v$
declare
  t text; p text; n int; v_chk jsonb;
  v_views text[] := array['v_vehicle_site_addresses','v_tank_levels','v_vehicle_stop_facts','v_vehicle_stop_tank_changes',
                          'v_visit_tank_service','v_vehicle_dumps','v_tank_data_quality_issues'];
begin
  foreach t in array v_views loop
    if (select c.reloptions from pg_class c where c.oid = ('public.' || t)::regclass) is not null then
      raise exception 'VERIFY M6-1: % carries reloptions (must be owner-rights)', t;
    end if;
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) or has_table_privilege('authenticated', 'public.' || t, p) then
        raise exception 'VERIFY M6-1: anon or authenticated holds % on public.%', p, t;
      end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT') then raise exception 'VERIFY M6-1: service_role cannot read %', t; end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('service_role', 'public.' || t, p) then raise exception 'VERIFY M6-1: service_role holds % on %', p, t; end if;
    end loop;
    if exists (select 1 from pg_class c, aclexplode(c.relacl) a where c.oid = ('public.' || t)::regclass and a.grantee = 0) then
      raise exception 'VERIFY M6-1: PUBLIC holds a privilege on %', t;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.fn_tank_fill_fraction(numeric,numeric,numeric)', 'EXECUTE')
     or not has_function_privilege('service_role', 'ops.fn_haversine_km(numeric,numeric,numeric,numeric)', 'EXECUTE') then
    raise exception 'VERIFY M6-2: service_role lacks EXECUTE on a function the views call';
  end if;

  -- the collector's map: dump sites and the yard, each with its Samsara address
  select count(*) into n from public.v_vehicle_site_addresses
   where (property_id, site_kind, samsara_address_id) in ((98, 'dump_site', '322485232'), (155, 'dump_site', '4000003697171'),
                                                          (1194, 'yard', '4000000737885'));
  if n <> 3 then raise exception 'VERIFY M6-3: site address map has % of the 3 expected rows', n; end if;

  -- no water gallons while the capacity is unknown
  select count(*) into n from public.v_vehicle_stop_tank_changes
   where capacity_gallons is null and (arrival_gallons is not null or departure_gallons is not null or net_gallons is not null
                                       or risen_gallons is not null or fallen_gallons is not null);
  if n <> 0 then raise exception 'VERIFY M6-4: % level rows carry gallons without a capacity', n; end if;

  -- compliance boundary: no derm/customer/client view depends on a new view (control: v_lwt_monthly_rows -> vehicles)
  select count(*) into n from pg_rewrite rw
    join pg_class v on v.oid = rw.ev_class join pg_namespace vn on vn.oid = v.relnamespace
    join pg_depend dp on dp.objid = rw.oid and dp.classid = 'pg_rewrite'::regclass
   where vn.nspname in ('derm','customer','client') and dp.refobjid = any (array(select ('public.' || x)::regclass from unnest(v_views) x));
  if n <> 0 then raise exception 'VERIFY M6-5: % derm/customer/client dependencies on the new views', n; end if;
  if not exists (select 1 from pg_rewrite rw join pg_depend dp on dp.objid = rw.oid and dp.classid = 'pg_rewrite'::regclass
                  where rw.ev_class = 'derm.v_lwt_monthly_rows'::regclass and dp.refobjid = 'public.vehicles'::regclass) then
    raise exception 'VERIFY M6-5: positive control failed (derm.v_lwt_monthly_rows -> public.vehicles not found)';
  end if;
  v_chk := public.fn_stop_facts_checks();
  if (v_chk->'integrity'->>'Z8')::int <> 0 or (v_chk->'integrity'->>'Z8_control_found')::boolean is not true then
    raise exception 'VERIFY M6-6: Z8 = %, control found = %', v_chk->'integrity'->'Z8', v_chk->'integrity'->'Z8_control_found';
  end if;
end $v$;

notify pgrst, 'reload schema';

commit;
