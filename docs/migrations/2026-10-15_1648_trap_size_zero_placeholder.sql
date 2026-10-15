-- ============================================================================
-- 2026-10-15_1648 Grease trap size 0 for ten properties, and 0 reads as "no size" in the sensor view and the Calendar estimate
-- ============================================================================
-- THE ASK (Fred, 2026-10-15, on the stops with no trap size behind the Calendar's Grease pumped tile):
--   "Make them have 0 in our DB, and give me the list of them so i can pass it to the team" (Friday's 3 grease traps),
--   "put them as 0 and give me a list with them to pass it to the team so they can add it later on" (the 25 grey water /
--   lift station stops). Ten properties: 40 (057-BAY), 655 (209-TRUE), 656 (212-TRUE), 246 (253-CG), 354 (053-PV),
--   1162 (335-EDS), 317 (338-PRT), 153 (077-TCE), 1201 and 1202 (349-EPS). Jobber already holds 0 on all ten (read live
--   2026-10-15 16:40 ET, Grease Trap size, gid://Jobber/CustomFieldConfigurationNumeric/3061111); ours was NULL.
--
-- WHY THE TWO READERS CHANGE TOO (measured first, rolled-back probe):
--   a plain 0 made public.v_visit_tank_service flag 4 Moises readings 'exceeds_trap_size' (the check is
--   sludge_net > 1.5 x trap + 40, and with trap 0 every reading exceeds it), which took them out of the trusted set and
--   dropped 057-BAY's measured average (461 gal from 556 + 366) to the trap size 0 on its next visit, 6630; and the
--   estimate turned 'unknown' stops into 0-gallon 'trap_size' rows. 0 is Jobber's empty (the custom-field sync and
--   derm.v_lwt_monthly_rows already read it that way, NULLIF(...,0)), so both readers now do too:
--     public.v_visit_tank_service   pp.grease_trap_size_gallons AS trap        -> NULLIF(..., 0) AS trap   (2 places)
--     ops.fn_grease_estimates_live  cv.equipment_size_gallons::numeric AS cap  -> NULLIF(..., 0) AS cap    (1 place)
--   Both bodies are copied from pg_get_viewdef / pg_get_functiondef (md5 304ae131... / 005f10f9...), never retyped;
--   VERIFY V3 undoes the change and proves the md5. The view's stop split already treated 0 as unusable
--   (bool_and(COALESCE(lk.trap, 0) > 0)), so it is unchanged in effect.
--   Side effect, intended: properties 170 (777-YA, test) and 183 (021-GRA) already held 0, so their tank rows move from
--   'exceeds_trap_size' to 'trap_size_unknown' (V4 allows those two only).
--
-- WHAT STILL SHOWS 0 (by design, it is the ask): the office screens that read the column directly: client.clients,
--   client.properties (Client App), ops.v_calendar_visit.equipment_size_gallons, ops.v_derm_compliance, ops.v_gdo_expiry,
--   ops.v_service_due, public.client_services_flat, public.v_client_agreement_services. Frozen Calendar days do not
--   move (ops.visit_grease_frozen is append-only).
--
-- THE FIELD PORTAL (customer-facing): customer.clients.trap_capacity would have read "0 gal" for all 9 clients (probe
--   keyed on the view's text client id; a first probe keyed on client_id matched 0 rows and looked clean). Customer
--   apps hide what we lack, so each of its three sources is guarded (NULLIF on the property and the agreement size, a
--   sibling property only when > 0) and a real size elsewhere still shows. This also stops 021-GRA and 777-YA, which
--   already held 0, from showing customers "0 gal" (C3 allows only those two rows to move). Replaced LAST so the
--   Field Portal waits only for that statement.
--
-- THE SYNC: the shadow is re-baselined through public.fn_sync_property_custom_field (answer IN_SYNC, our_value 0), so
--   when the team types the real size in Jobber the poll ADOPTS it (source moved, ours did not). Without this step ours
--   moving NULL -> 0 would read as both sides changed and FREEZE the field as a conflict. Writes through the Management
--   API carry no JWT, so trg_properties_enqueue_outbound queues nothing (V6); Jobber is untouched.
-- Rule 8: no new table. public.properties stays audited; the reason rides x-change-reason into audit.logs.
-- Rollback: docs/migrations/2026-10-15_rollback_trap_size_zero_placeholder.sql (all three bodies verbatim, the ten back to NULL)
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

-- before, for the VERIFY diff (the whole view and 31 days of live estimates)
CREATE TEMP TABLE b_tank ON COMMIT DROP AS SELECT to_jsonb(t) j FROM public.v_visit_tank_service t;
CREATE TEMP TABLE b_est ON COMMIT DROP AS SELECT to_jsonb(g) j FROM ops.fn_grease_estimates_live((now() AT TIME ZONE 'America/New_York')::date, (now() AT TIME ZONE 'America/New_York')::date + 30) g;
CREATE TEMP TABLE b_cust ON COMMIT DROP AS SELECT to_jsonb(c) j FROM customer.clients c;
CREATE TEMP TABLE b_acl ON COMMIT DROP AS
  SELECT (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_tank_service'::regclass) v,
         (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.fn_grease_estimates_live'::regproc) f,
         (SELECT relacl::text FROM pg_class WHERE oid = 'customer.clients'::regclass) c,
         (SELECT count(*) FROM sync.outbound_queue) q;

-- 1. the sensor view: a trap size of 0 means no size on file (two lines; the rest is the live body, copied)
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

-- 2. the Calendar estimate: the same rule for its trap-size fallback (one line; the rest is the live body, copied)
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
    SELECT cv.id, cv.visit_date, cv.vehicle_id, NULLIF(cv.equipment_size_gallons::numeric, 0) AS cap,
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

-- 3. the ten properties get 0, with the reason in their history
SELECT set_config('request.headers', json_build_object('x-change-reason', 'Placeholder 0 until the team measures the trap (Fred, 2026-10-15). 0 is what Jobber holds for an empty Grease Trap size.')::text, true);
DO $w$
DECLARE n int;
BEGIN
  UPDATE public.properties SET grease_trap_size_gallons = 0
   WHERE id IN (40,655,656,246,354,1162,317,153,1201,1202) AND grease_trap_size_gallons IS NULL AND deleted_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 10 THEN RAISE EXCEPTION 'expected 10 properties set to 0, got %', n; END IF;
END $w$;

-- 4. re-baseline the Jobber shadow through the sync's own function (Jobber holds 0, read live before apply),
--    so a size the team types in Jobber later is ADOPTED, never frozen as a conflict
DO $s$
DECLARE r record; d text;
BEGIN
  FOR r IN SELECT unnest(array[40,655,656,246,354,1162,317,153,1201,1202]::bigint[]) pid LOOP
    d := public.fn_sync_property_custom_field(r.pid, 'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size', '0'::jsonb, true, false);
    IF d <> 'IN_SYNC' THEN RAISE EXCEPTION 'property %: the sync answered % (expected IN_SYNC)', r.pid, d; END IF;
  END LOOP;
END $s$;

-- VERIFY
DO $v$
DECLARE n int; vt text; vf text; bad int; acl record;
BEGIN
  -- V1 the ten hold 0
  SELECT count(*) INTO n FROM public.properties WHERE id IN (40,655,656,246,354,1162,317,153,1201,1202) AND grease_trap_size_gallons = 0;
  IF n <> 10 THEN RAISE EXCEPTION 'V1 % of 10 at 0', n; END IF;
  -- V2 shadow: Jobber 0, ours 0, no conflict
  SELECT count(*) INTO n FROM sync.source_field_shadow
   WHERE entity_type = 'property' AND source_system = 'jobber' AND field_key = 'gid://Jobber/CustomFieldConfigurationNumeric/3061111'
     AND entity_id IN (40,655,656,246,354,1162,317,153,1201,1202) AND source_value = '0'::jsonb AND our_value = '0'::jsonb AND conflict_at IS NULL;
  IF n <> 10 THEN RAISE EXCEPTION 'V2 % of 10 shadow rows re-baselined', n; END IF;
  -- V3 nothing else moved in either body: undo the change and the md5 matches the copied original
  vt := replace(pg_get_viewdef('public.v_visit_tank_service'::regclass, true), 'NULLIF(pp.grease_trap_size_gallons, 0) AS trap', 'pp.grease_trap_size_gallons AS trap');
  IF md5(vt) <> '304ae131fb668f13c5943c98a0215d6a' THEN RAISE EXCEPTION 'V3 view body moved beyond the two lines'; END IF;
  vf := replace(pg_get_functiondef('ops.fn_grease_estimates_live'::regproc), 'NULLIF(cv.equipment_size_gallons::numeric, 0) AS cap', 'cv.equipment_size_gallons::numeric AS cap');
  IF md5(vf) <> '005f10f91edf6fd5096910a0f40f84b6' THEN RAISE EXCEPTION 'V3 function body moved beyond the one line'; END IF;
  -- V4 the view changed ONLY on the two properties that already held 0 (170 777-YA, 183 021-GRA)
  SELECT count(*) INTO bad FROM (
    (SELECT j FROM b_tank EXCEPT SELECT to_jsonb(t) FROM public.v_visit_tank_service t)
    UNION ALL
    (SELECT to_jsonb(t) FROM public.v_visit_tank_service t EXCEPT SELECT j FROM b_tank)) d
   WHERE (d.j->>'property_id')::bigint NOT IN (170, 183);
  IF bad <> 0 THEN RAISE EXCEPTION 'V4 % tank rows moved outside properties 170/183', bad; END IF;
  -- V5 the live estimates did not move at all for 31 days (057-BAY keeps its measured average)
  SELECT count(*) INTO bad FROM (
    (SELECT j FROM b_est EXCEPT SELECT to_jsonb(g) FROM ops.fn_grease_estimates_live((now() AT TIME ZONE 'America/New_York')::date, (now() AT TIME ZONE 'America/New_York')::date + 30) g)
    UNION ALL
    (SELECT to_jsonb(g) FROM ops.fn_grease_estimates_live((now() AT TIME ZONE 'America/New_York')::date, (now() AT TIME ZONE 'America/New_York')::date + 30) g EXCEPT SELECT j FROM b_est)) d;
  IF bad <> 0 THEN RAISE EXCEPTION 'V5 % live estimate rows moved', bad; END IF;
  -- V6 grants unchanged, and no push to Jobber was queued
  SELECT * INTO acl FROM b_acl;
  IF acl.v IS DISTINCT FROM (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_tank_service'::regclass)
     OR acl.f IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.fn_grease_estimates_live'::regproc)
  THEN RAISE EXCEPTION 'V6 a grant changed'; END IF;
  IF (SELECT count(*) FROM sync.outbound_queue) <> acl.q THEN RAISE EXCEPTION 'V6 an outbound push was queued'; END IF;
END $v$;

-- 5. the Field Portal: a trap capacity of 0 is never shown to a customer ("customer apps hide what we lack").
--    Each source is guarded (the property, a sibling property, the agreement size), so a real size on another
--    property of the client still shows. Last, so the Field Portal waits only for this statement.
CREATE OR REPLACE VIEW customer.clients AS
 SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric)) IS NOT NULL THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric))::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric)) IS NOT NULL THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric))::text || ' gal'::text
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

DO $c$
DECLARE bad int; acl record;
BEGIN
  -- C1 nothing else moved in the body
  IF md5(replace(replace(replace(pg_get_viewdef('customer.clients'::regclass, true), 'NULLIF(sc_gt.equipment_size_gallons, 0::numeric))', 'sc_gt.equipment_size_gallons)'), 'ps.grease_trap_size_gallons > 0', 'ps.grease_trap_size_gallons IS NOT NULL'), 'NULLIF(p.grease_trap_size_gallons, 0)::numeric', 'p.grease_trap_size_gallons::numeric')) <> 'd40ae404fa9c909229418b93e0210642' THEN RAISE EXCEPTION 'C1 customer.clients body moved beyond the guarded lines'; END IF;
  -- C2 no customer is shown 0 gal
  IF EXISTS (SELECT 1 FROM customer.clients WHERE trap_capacity LIKE '0 %') THEN RAISE EXCEPTION 'C2 a customer still sees 0 gal'; END IF;
  -- C3 only the two clients that showed 0 gal before (008 021-GRA, 047 777-YA) moved; every other row is identical
  SELECT count(*) INTO bad FROM (
    (SELECT j FROM b_cust EXCEPT SELECT to_jsonb(c) FROM customer.clients c)
    UNION ALL
    (SELECT to_jsonb(c) FROM customer.clients c EXCEPT SELECT j FROM b_cust)) d
   WHERE d.j->>'id' NOT IN ('00000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000047');
  IF bad <> 0 THEN RAISE EXCEPTION 'C3 % customer rows moved outside 021-GRA / 777-YA', bad; END IF;
  -- C4 grant unchanged
  SELECT * INTO acl FROM b_acl;
  IF acl.c IS DISTINCT FROM (SELECT relacl::text FROM pg_class WHERE oid = 'customer.clients'::regclass) THEN RAISE EXCEPTION 'C4 grant changed'; END IF;
END $c$;

COMMIT;
