-- 2026-10-21_0545 · The sensor wins over the trap size on file (Grease pumped audit, Trello wv4xwPoG)
--
-- Fred, 2026-10-21: "go ahead with full trap, fix 241-WYN, sensor wins" (plan step 4,
-- Building Apps/Visit Calendar/docs/specs/2026-10-21-grease-pumped-data-audit-and-plan.md, section 4.3).
--
-- WHY. public.v_visit_tank_service marked a Moises reading LOW confidence, which keeps it out of every average
-- (ops.fn_client_sludge_averages reads high/medium only), in two cases that judge the SENSOR by the TRAP SIZE ON FILE:
--   exceeds_trap_size: the reading was above 1.5 x trap + 40 gal;
--   below_resolution:  the trap on file was 75 gal or less, whatever the reading.
-- So a trap size that was too small threw out the very readings that show it is wrong, and the wrong size then
-- became the estimate (022-GRO on file 250, measured 1,231; 024-GRO 500 vs 1,811; 012-DKC 1,200 vs 2,407; 111-YC 30
-- vs 363 and 396; 104-PV 302 vs 538). Samsara's own Fill Volume confirms real step rises at these stops.
--
-- WHAT. exceeds_trap_size no longer exists as a reason: the reading goes on to the sensor checks (too short, tank at
-- ceiling, pumped with no rise, rise without pump, ...), which still decide its confidence. below_resolution now
-- applies only when the trap on file is 75 gal or less AND the reading is under 100 gal (sensor noise is about 20 to
-- 45 gal). New LAST column sludge_above_trap_size (true when the reading is above 1.5 x trap + 40; NULL when there is
-- no reading) keeps the disagreement visible, so the trap size can be corrected in Jobber. Everything else is the
-- live definition (md5 guard below). Readers: v_tank_data_quality_issues, v_visit_water_balance, fn_stop_facts_checks,
-- ops.fn_client_sludge_averages; none reads the two reason codes (checked: no other view or function names them).
--
-- DRY RUN before apply (inside a rolled-back transaction): 21 readings change reason; trusted (high/medium) readings
-- 132 -> 150; 6218 and 6259 stay low (below_resolution, under 100 gal), 6252 stays low (tank_at_ceiling). The
-- Calendar's estimates for 2026-10-21..12-04 move on 27 visits, 57,193 -> 63,421 gal, e.g. 5944 (022-GRO, 10-27)
-- 250 -> 1,231, 5951 (024-GRO, 11-26) 500 -> 1,811, 5907 (012-DKC, 11-30) 1,200 -> 2,407, 6301 (111-YC, 11-01)
-- 30 -> 380, 6096 (061-TCE, today) 10 -> 203. Past days are frozen and do not move. A Moises stop with no reading
-- still uses the full trap size (Fred kept it).
--
-- ROLLBACK: docs/migrations/2026-10-21_rollback_sensor_wins_over_trap_size.sql puts both vetoes back (the appended
-- column stays; CREATE OR REPLACE VIEW cannot drop a column, and nothing reads it).
-- Rule 8: a view, no table; grants unchanged (service_role + db_backup_reader read only).

begin;
set local lock_timeout = '3s';

do $guard$ begin
  if md5(pg_get_viewdef('public.v_visit_tank_service'::regclass)) <> 'bbbaa38e99b2f2d46dfb787a85cf25c0' then
    raise exception 'v_visit_tank_service changed since the dry run; re-read the live definition';
  end if;
end $guard$;

CREATE OR REPLACE VIEW public.v_visit_tank_service AS
 WITH lk AS (
         SELECT l.visit_id,
            l.vehicle_stop_id,
            l.match_basis,
            (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE n.client_id = vl.client_id AND n.kind = 'dump_site'::text)) AS is_dump,
            vl.service_type = 'Pumping'::text AND NOT (EXISTS ( SELECT 1
                   FROM non_customer_clients n
                  WHERE n.client_id = vl.client_id AND n.kind = 'dump_site'::text)) AS is_volume,
            NULLIF(pp.grease_trap_size_gallons, 0) AS trap
           FROM visit_vehicle_stops l
             JOIN v_visits_live vl ON vl.id = l.visit_id
             LEFT JOIN properties pp ON pp.id = vl.property_id
          WHERE l.deleted_at IS NULL
        ), sh AS (
         SELECT lk.visit_id,
            lk.vehicle_stop_id,
            lk.match_basis,
            lk.is_dump,
            lk.is_volume,
            lk.trap,
                CASE
                    WHEN NOT lk.is_volume THEN 0::numeric
                    WHEN bool_and(COALESCE(lk.trap, 0) > 0) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id) THEN lk.trap::numeric / sum(lk.trap) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id)::numeric
                    ELSE 1.0 / count(*) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id)::numeric
                END AS sludge_share,
                CASE
                    WHEN lk.is_dump THEN 0::numeric
                    ELSE 1.0 / count(*) FILTER (WHERE NOT lk.is_dump) OVER (PARTITION BY lk.vehicle_stop_id)::numeric
                END AS water_share,
            count(*) FILTER (WHERE lk.is_volume) OVER (PARTITION BY lk.vehicle_stop_id) AS volume_links_on_stop,
            count(*) OVER (PARTITION BY lk.vehicle_stop_id) AS links_on_stop
           FROM lk
        ), sk AS (
         SELECT sh.visit_id AS k_visit_id,
            sh.vehicle_stop_id AS k_stop_id,
            (s.departed_at - s.arrived_at) < '00:10:00'::interval AND COALESCE(bool_or((s.departed_at - s.arrived_at) >= '00:10:00'::interval) OVER (PARTITION BY sh.visit_id), false) AS skip_short
           FROM sh
             JOIN vehicle_stops s ON s.id = sh.vehicle_stop_id
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
                  WHERE n.client_id = vl.client_id AND n.kind = 'dump_site'::text)) AS is_dump,
            NULLIF(pp.grease_trap_size_gallons, 0) AS trap
           FROM v_visits_live vl
             LEFT JOIN properties pp ON pp.id = vl.property_id
          WHERE vl.visit_status = 'completed'::text AND vl.visit_date >= '2026-08-20'::date
        ), agg AS (
         SELECT v.visit_id AS a_visit_id,
            count(sh.vehicle_stop_id)::integer AS link_count,
            array_agg(DISTINCT sh.match_basis) FILTER (WHERE sh.match_basis IS NOT NULL) AS match_bases,
            sum(f.duration_minutes) AS stop_minutes,
            sum(f.rpm_pump_minutes) AS pump_minutes,
            sum(f.pto_minutes) AS pto_minutes,
            bool_or(f.pump_signature) AS pump_signature,
            bool_or(f.engine_data_present) AS engine_data_present,
            bool_or(sh.links_on_stop > 1) AS shared_stop,
            bool_or(sh.volume_links_on_stop > 1) AS shared_volume_stop,
            bool_or(sh.match_basis = 'window'::text) AS has_window_link,
            min(f.arrived_at) AS first_arrived_at,
            bool_or(ts.vehicle_stop_tank_level_id IS NULL) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_row_missing,
            bool_or(ts.arrival_fill_fraction IS NULL OR ts.departure_fill_fraction IS NULL) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_edge_missing,
            bool_or(ts.too_short) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_too_short,
            bool_or(ts.at_ceiling) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_at_ceiling,
            sum(sh.sludge_share * ts.net_gallons) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_net,
            sum(sh.sludge_share * ts.risen_gallons) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS sludge_gross,
            bool_or(tw.vehicle_stop_tank_level_id IS NULL OR tw.fill_fraction_fallen IS NULL) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_incomplete,
            bool_or(tw.capacity_gallons IS NULL) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_capacity_unknown,
            sum(sh.water_share * tw.fill_fraction_fallen) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_used_fraction,
            sum(sh.water_share * tw.fill_fraction_risen) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_refilled_fraction,
            sum(sh.water_share * tw.fallen_gallons) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_used_gal,
            sum(sh.water_share * tw.risen_gallons) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_refilled_gal,
            count(*) FILTER (WHERE COALESCE(sk.skip_short, false))::integer AS short_stops_left_out,
            (array_agg(tw.arrival_gallons ORDER BY f.arrived_at) FILTER (WHERE NOT COALESCE(sk.skip_short, false)))[1] AS water_start_gal,
            max(tw.peak_gallons) FILTER (WHERE NOT COALESCE(sk.skip_short, false)) AS water_peak_gal,
            (array_agg(tw.departure_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE NOT COALESCE(sk.skip_short, false)))[1] AS water_end_gal,
            (array_agg(ts.late_change_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE NOT COALESCE(sk.skip_short, false)))[1] AS sludge_late_gal,
            (array_agg(tw.late_change_gallons ORDER BY f.arrived_at DESC NULLS LAST) FILTER (WHERE NOT COALESCE(sk.skip_short, false)))[1] AS water_late_gal,
            COALESCE(bool_or(ts.departure_basis = 'after_leaving'::text OR tw.departure_basis = 'after_leaving'::text) FILTER (WHERE NOT COALESCE(sk.skip_short, false)), false) AS after_leaving,
            COALESCE(sum(COALESCE(ts.ghost_measurement_count::integer, 0) + COALESCE(tw.ghost_measurement_count::integer, 0)) FILTER (WHERE NOT COALESCE(sk.skip_short, false)), 0::bigint)::integer AS ghosts_removed
           FROM v
             LEFT JOIN sh ON sh.visit_id = v.visit_id
             LEFT JOIN v_vehicle_stop_facts f ON f.vehicle_stop_id = sh.vehicle_stop_id
             LEFT JOIN v_vehicle_stop_tank_changes ts ON ts.vehicle_stop_id = sh.vehicle_stop_id AND ts.contents = 'sludge'::text
             LEFT JOIN v_vehicle_stop_tank_changes tw ON tw.vehicle_stop_id = sh.vehicle_stop_id AND tw.contents = 'fresh_water'::text
             LEFT JOIN sk ON sk.k_visit_id = sh.visit_id AND sk.k_stop_id = sh.vehicle_stop_id
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
            NOT v.is_dump AND v.service_type = 'Pumping'::text AS is_volume,
            (EXISTS ( SELECT 1
                   FROM tank_sensor_installations i
                     JOIN vehicle_tanks vt ON vt.id = i.vehicle_tank_id AND vt.deleted_at IS NULL
                  WHERE vt.vehicle_id = v.vehicle_id AND vt.contents = 'sludge'::text AND i.superseded_at IS NULL AND i.installed_at <= COALESCE(agg.first_arrived_at, v.completed_at) AND COALESCE(agg.first_arrived_at, v.completed_at) < COALESCE(i.removed_at, 'infinity'::timestamp with time zone))) AS has_sludge_sensor,
            (EXISTS ( SELECT 1
                   FROM tank_sensor_installations i
                     JOIN vehicle_tanks vt ON vt.id = i.vehicle_tank_id AND vt.deleted_at IS NULL
                  WHERE vt.vehicle_id = v.vehicle_id AND vt.contents = 'fresh_water'::text AND i.superseded_at IS NULL AND i.installed_at <= COALESCE(agg.first_arrived_at, v.completed_at) AND COALESCE(agg.first_arrived_at, v.completed_at) < COALESCE(i.removed_at, 'infinity'::timestamp with time zone))) AS has_water_sensor
           FROM v
             JOIN agg ON agg.a_visit_id = v.visit_id
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
                    WHEN NOT x.is_volume THEN 'not_a_volume_visit'::text
                    WHEN NOT x.has_sludge_sensor THEN 'no_sensor'::text
                    WHEN x.link_count = 0 THEN 'no_stop'::text
                    WHEN x.sludge_row_missing THEN 'no_config'::text
                    WHEN x.sludge_edge_missing THEN 'edge_missing'::text
                    WHEN x.sludge_too_short THEN 'too_short'::text
                    WHEN x.trap <= 75 AND x.sludge_net < 100::numeric THEN 'below_resolution'::text
                    WHEN x.sludge_at_ceiling THEN 'tank_at_ceiling'::text
                    WHEN x.sludge_net < 40::numeric AND COALESCE(x.pump_signature, false) THEN 'pumped_no_rise'::text
                    WHEN x.sludge_net >= 40::numeric AND x.engine_data_present AND NOT COALESCE(x.pump_signature, false) THEN 'rise_without_pump'::text
                    WHEN x.trap IS NULL THEN 'trap_size_unknown'::text
                    WHEN x.has_window_link THEN 'window_match'::text
                    WHEN x.shared_volume_stop THEN 'shared_stop_allocated'::text
                    WHEN NOT COALESCE(x.engine_data_present, false) THEN 'no_pump_signal'::text
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
    stop_minutes IS NOT NULL AND duration_minutes IS NOT NULL AND abs(stop_minutes - duration_minutes::numeric) > 15::numeric AS time_on_site_disagreement,
    pump_minutes,
    pto_minutes,
    pump_signature,
    engine_data_present,
        CASE
            WHEN sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text]) THEN NULL::numeric
            ELSE round(sludge_net, 1)
        END AS sludge_collected_gallons,
        CASE
            WHEN sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text]) THEN NULL::numeric
            ELSE round(sludge_gross, 1)
        END AS sludge_gross_intake_gallons,
        CASE
            WHEN sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text]) THEN 'none'::text
            WHEN sludge_reason = ANY (ARRAY['too_short'::text, 'below_resolution'::text, 'tank_at_ceiling'::text, 'exceeds_trap_size'::text, 'pumped_no_rise'::text, 'rise_without_pump'::text]) THEN 'low'::text
            WHEN sludge_reason = 'ok'::text THEN 'high'::text
            ELSE 'medium'::text
        END AS sludge_confidence,
    sludge_reason,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete THEN NULL::numeric
            ELSE round(100::numeric * water_used_fraction, 1)
        END AS water_used_percent_points,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete THEN NULL::numeric
            ELSE round(100::numeric * water_refilled_fraction, 1)
        END AS water_refilled_percent_points,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_used_gal, 1)
        END AS water_used_gallons,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_refilled_gal, 1)
        END AS water_refilled_gallons,
        CASE
            WHEN NOT has_water_sensor OR link_count = 0 OR water_incomplete THEN 'none'::text
            ELSE 'low'::text
        END AS water_confidence,
        CASE
            WHEN NOT has_water_sensor THEN 'no_sensor'::text
            WHEN link_count = 0 THEN 'no_stop'::text
            WHEN water_incomplete THEN 'measurement_missing'::text
            WHEN water_capacity_unknown THEN 'percent_only'::text
            ELSE 'unvalidated'::text
        END AS water_reason,
    short_stops_left_out,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_start_gal, 1)
        END AS water_start_gallons,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_peak_gal, 1)
        END AS water_peak_gallons,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_end_gal, 1)
        END AS water_end_gallons,
        CASE
            WHEN link_count = 0 OR NOT has_sludge_sensor THEN NULL::numeric
            ELSE round(sludge_late_gal, 1)
        END AS sludge_change_after_leaving_gallons,
        CASE
            WHEN link_count = 0 OR NOT has_water_sensor OR water_incomplete OR water_capacity_unknown THEN NULL::numeric
            ELSE round(water_late_gal, 1)
        END AS water_change_after_leaving_gallons,
    after_leaving AS departure_after_leaving,
    ghosts_removed AS ghost_readings_removed,
        CASE
            WHEN sludge_reason = ANY (ARRAY['not_a_volume_visit'::text, 'no_sensor'::text, 'no_stop'::text, 'no_config'::text, 'edge_missing'::text]) THEN NULL::boolean
            ELSE trap IS NOT NULL AND sludge_net > (1.5 * trap::numeric + 40::numeric)
        END AS sludge_above_trap_size
   FROM r;

do $verify$ declare r record; n int; begin
  select sludge_reason, sludge_confidence, sludge_above_trap_size into r from public.v_visit_tank_service where visit_id = 5943;
  if r.sludge_confidence <> 'high' or not r.sludge_above_trap_size then
    raise exception 'V1: 5943 reads % % %', r.sludge_reason, r.sludge_confidence, r.sludge_above_trap_size; end if;
  select sludge_reason into r from public.v_visit_tank_service where visit_id = 6218;
  if r.sludge_reason <> 'below_resolution' then raise exception 'V2: 6218 reads %', r.sludge_reason; end if;
  select sludge_reason into r from public.v_visit_tank_service where visit_id = 6252;
  if r.sludge_reason <> 'tank_at_ceiling' then raise exception 'V3: 6252 reads %', r.sludge_reason; end if;
  select count(*) into n from public.v_visit_tank_service where sludge_reason = 'exceeds_trap_size';
  if n <> 0 then raise exception 'V4: % exceeds_trap_size rows', n; end if;
  if (select relacl::text from pg_class where oid = 'public.v_visit_tank_service'::regclass)
     <> '{postgres=arwdDxtm/postgres,db_backup_reader=r/postgres,service_role=r/postgres}' then
    raise exception 'V5: grants moved'; end if;
  select gallons into r from ops.fn_grease_estimates_resolved('2026-10-27', '2026-10-27') where visit_id = 5944;
  if r.gallons not between 1200 and 1260 then raise exception 'V6: 5944 reads %', r.gallons; end if;
  perform count(*) from public.v_visit_water_balance;
  perform count(*) from public.v_tank_data_quality_issues;
end $verify$;

commit;
