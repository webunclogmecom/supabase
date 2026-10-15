-- ============================================================================
-- ROLLBACK of 2026-10-15_1648_trap_size_zero_placeholder
-- Restores the two bodies verbatim (as fetched 2026-10-15 16:48 ET) and puts the ten properties back to NULL, only
-- where they still hold the placeholder 0 (a size the team has typed since is kept). The shadow is re-baselined through
-- the sync's function again: Jobber 0 vs ours NULL answers IGNORE and records our_value null, the state before.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
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
            pp.grease_trap_size_gallons AS trap
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
            pp.grease_trap_size_gallons AS trap
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
            count(*) FILTER (WHERE COALESCE(sk.skip_short, false))::integer AS short_stops_left_out
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
            x.is_volume,
            x.has_sludge_sensor,
            x.has_water_sensor,
                CASE
                    WHEN NOT x.is_volume THEN 'not_a_volume_visit'::text
                    WHEN NOT x.has_sludge_sensor THEN 'no_sensor'::text
                    WHEN x.link_count = 0 THEN 'no_stop'::text
                    WHEN x.sludge_row_missing THEN 'no_config'::text
                    WHEN x.sludge_edge_missing THEN 'edge_missing'::text
                    WHEN x.trap IS NOT NULL AND x.sludge_net > (1.5 * x.trap::numeric + 40::numeric) THEN 'exceeds_trap_size'::text
                    WHEN x.sludge_too_short THEN 'too_short'::text
                    WHEN x.trap <= 75 THEN 'below_resolution'::text
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
    short_stops_left_out
   FROM r;

CREATE OR REPLACE FUNCTION ops.fn_grease_estimates_live(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], vehicle_id bigint, separates_water boolean, trap_size_gallons numeric, gallons numeric, basis text, readings integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH cfg AS (
    SELECT coalesce((SELECT array_agg(x::bigint)
                       FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                             WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                  '[^0-9]+') x
                      WHERE x <> ''), '{}'::bigint[]) AS sep
  ),
  tv AS MATERIALIZED (
    SELECT cv.id, cv.visit_date, cv.vehicle_id, cv.equipment_size_gallons::numeric AS cap,
           coalesce(cv.property_id,
                    (SELECT p.id FROM public.properties p
                      WHERE p.client_id = cv.client_id AND p.is_primary AND p.deleted_at IS NULL
                      ORDER BY p.id LIMIT 1)) AS prop,
           ops.fn_visit_pump_kinds(cv.id, cv.job_id) AS kinds
      FROM ops.v_calendar_visit cv
     WHERE cv.visit_date BETWEEN p_from AND p_to
  ),
  av AS MATERIALIZED (
    SELECT * FROM ops.fn_client_sludge_averages(ARRAY(SELECT DISTINCT tv.visit_date FROM tv WHERE tv.kinds <> '{}'))
  )
  SELECT tv.id, tv.visit_date, tv.kinds[1], tv.kinds, tv.vehicle_id, s.sep, tv.cap,
         CASE WHEN tv.kinds = '{}' THEN NULL
              WHEN s.sep AND a.readings_n >= 1 THEN a.avg_gallons
              ELSE round(tv.cap) END,
         CASE WHEN tv.kinds = '{}' THEN 'not_pumping'
              WHEN s.sep AND a.readings_n >= 1 THEN 'measured'
              WHEN tv.cap IS NOT NULL THEN 'trap_size'
              ELSE 'unknown' END,
         CASE WHEN s.sep AND tv.kinds <> '{}' THEN coalesce(a.readings_n, 0) ELSE 0 END
    FROM tv
    CROSS JOIN cfg
    CROSS JOIN LATERAL (SELECT coalesce(tv.vehicle_id = ANY (cfg.sep), false) AS sep) s
    LEFT JOIN av a ON a.as_of = tv.visit_date AND a.property_id = tv.prop
$function$
;

CREATE OR REPLACE VIEW customer.clients AS
 SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL THEN COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons)::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL THEN COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons)::text || ' gal'::text
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE j.client_id = c.id AND j.title ~~* '%Service Agreement%'::text AND (j.job_status <> ALL (ARRAY['archived'::text, 'destroyed'::text])) AND j.frequency_days > 0) AS service_frequency_days
   FROM clients c
     LEFT JOIN client_groups cg ON cg.id = c.group_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true AND p.deleted_at IS NULL
     LEFT JOIN v_client_agreement_services sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'Pumping'::text
     LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;

SELECT set_config('request.headers', json_build_object('x-change-reason', 'Rollback of the placeholder 0 (2026-10-15_1648).')::text, true);
UPDATE public.properties SET grease_trap_size_gallons = NULL
 WHERE id IN (40,655,656,246,354,1162,317,153,1201,1202) AND grease_trap_size_gallons = 0;
SELECT p.id, public.fn_sync_property_custom_field(p.id, 'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size', '0'::jsonb, true, false)
  FROM public.properties p WHERE p.id IN (40,655,656,246,354,1162,317,153,1201,1202) AND p.grease_trap_size_gallons IS NULL;
DO $v$ BEGIN
  IF md5(pg_get_viewdef('public.v_visit_tank_service'::regclass, true)) <> '304ae131fb668f13c5943c98a0215d6a'
  THEN RAISE EXCEPTION 'view not restored'; END IF;
  IF md5(pg_get_functiondef('ops.fn_grease_estimates_live'::regproc)) <> '005f10f91edf6fd5096910a0f40f84b6'
  THEN RAISE EXCEPTION 'function not restored'; END IF;
  IF md5(pg_get_viewdef('customer.clients'::regclass, true)) <> 'd40ae404fa9c909229418b93e0210642'
  THEN RAISE EXCEPTION 'customer.clients not restored'; END IF;
END $v$;
COMMIT;
