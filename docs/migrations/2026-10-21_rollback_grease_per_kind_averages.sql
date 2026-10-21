-- ROLLBACK of 2026-10-21_1500_grease_per_kind_averages.sql: back to one pooled average per place and the borrowed
-- trap size (bodies as of 2026-10-21_0700). Run as one transaction. The Calendar app must stop reading
-- unknown_reason first (it is an extra column; an older bundle ignores it, a newer one shows "no size").
DROP VIEW ops.v_client_sludge_average;
DROP FUNCTION ops.fn_client_sludge_averages(date[]);
CREATE FUNCTION ops.fn_client_sludge_averages(p_dates date[])
 RETURNS TABLE(as_of date, property_id bigint, client_id bigint, readings_n integer, avg_gallons numeric, last_reading_date date, readings jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH pool AS MATERIALIZED (
    SELECT t.property_id, rv.client_id, t.visit_date, t.visit_id, t.sludge_collected_gallons AS g,
           ops.fn_visit_pump_kind(t.visit_id, rv.job_id) AS kind
      FROM public.v_visit_tank_service t
      JOIN public.visits rv ON rv.id = t.visit_id
     WHERE t.visit_kind = 'volume' AND t.sludge_confidence IN ('high', 'medium')
       AND t.sludge_collected_gallons BETWEEN 40 AND 3840 AND t.property_id IS NOT NULL
  ), ok AS MATERIALIZED (
    SELECT * FROM pool WHERE kind IS NOT NULL
  ), d AS (
    SELECT DISTINCT x AS as_of FROM unnest(p_dates) x WHERE x IS NOT NULL
  )
  SELECT d.as_of, pr.property_id, l.client_id, l.n, l.avg_g, l.last_d, l.rs
    FROM d
    CROSS JOIN (SELECT DISTINCT ok.property_id FROM ok) pr
    CROSS JOIN LATERAL (
      SELECT count(*)::int AS n, round(avg(x.g)) AS avg_g, max(x.visit_date) AS last_d,
             (array_agg(x.client_id ORDER BY x.visit_date DESC, x.visit_id DESC))[1] AS client_id,
             jsonb_agg(jsonb_build_object('visit_id', x.visit_id, 'visit_date', x.visit_date,
                                          'gallons', round(x.g, 1), 'pump_kind', x.kind)
                       ORDER BY x.visit_date DESC, x.visit_id DESC) AS rs
        FROM (SELECT ok.* FROM ok
               WHERE ok.property_id = pr.property_id AND ok.visit_date < d.as_of
               ORDER BY ok.visit_date DESC, ok.visit_id DESC
               LIMIT 6) x
    ) l
   WHERE l.n > 0
$function$;
REVOKE ALL ON FUNCTION ops.fn_client_sludge_averages(date[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_client_sludge_averages(date[]) TO service_role;
CREATE VIEW ops.v_client_sludge_average AS
 SELECT a.client_id,
    c.client_code,
    c.name AS client_name,
    a.property_id,
    a.readings_n,
    a.avg_gallons,
    a.last_reading_date,
    a.readings
   FROM (ops.fn_client_sludge_averages(ARRAY[(((now() AT TIME ZONE 'America/New_York'::text))::date + 1)]) a(as_of, property_id, client_id, readings_n, avg_gallons, last_reading_date, readings)
     LEFT JOIN public.clients c ON ((c.id = a.client_id)));
REVOKE ALL ON ops.v_client_sludge_average FROM PUBLIC, anon, authenticated;
GRANT SELECT ON ops.v_client_sludge_average TO service_role, db_backup_reader;
COMMENT ON VIEW ops.v_client_sludge_average IS 'Each client place''s grease average today: the last 6 trusted sludge sensor readings of its pumping visits (Moises). Computed on read from ops.fn_client_sludge_averages. 2026-10-15_1540.';
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
$function$;
DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean, vehicle_id bigint, measured_gallons numeric, measurable boolean, vehicle_source text, truck_capacity_gallons numeric, over_truck_capacity boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_grease_estimates: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_grease_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  -- 2026-10-21_0600 (step 5): the visit's own trusted sludge reading on that date, read live and never frozen, so a
  -- past day can show what was really measured next to its stored estimate. Same trust rule as the averages.
  WITH m AS MATERIALIZED (
    SELECT t.visit_id AS m_visit_id, t.visit_date AS m_date, round(t.sludge_collected_gallons) AS m_gallons
      FROM public.v_visit_tank_service t
     WHERE t.visit_date BETWEEN p_from AND p_to
       AND t.visit_kind = 'volume' AND t.sludge_confidence IN ('high', 'medium')
       AND t.sludge_collected_gallons BETWEEN 40 AND 3840),
  cv AS MATERIALIZED (
    SELECT v.id AS vs_id, v.visit_date AS vs_date, v.vehicle_source AS vs_source
      FROM ops.v_calendar_visit v WHERE v.visit_date BETWEEN p_from AND p_to)
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live',
         r.vehicle_id, m.m_gallons,
         -- 2026-10-21_0630: the stop's truck separates water and carries the tank sensor (app_config), the same list
         -- fn_grease_estimates_live uses, so the app never decides which truck can be measured
         coalesce(r.vehicle_id = ANY (coalesce((SELECT array_agg(x::bigint)
                                                  FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                                                        WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                                             '[^0-9]+') x
                                                 WHERE x <> ''), '{}'::bigint[])), false),
         -- 2026-10-21_0700 (step 6): where today's truck comes from ('assigned' / 'default' / 'none', the visit's live
         -- source, meaningful for today and later) and whether the stop's estimate is more than its truck's tank holds
         cv.vs_source, vh.grease_tank_capacity_gallons,
         coalesce(r.gallons > vh.grease_tank_capacity_gallons, false)
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
    LEFT JOIN m ON m.m_visit_id = r.visit_id AND m.m_date = r.visit_date
    LEFT JOIN cv ON cv.vs_id = r.visit_id AND cv.vs_date = r.visit_date
    LEFT JOIN public.vehicles vh ON vh.id = r.vehicle_id
   WHERE r.pump_kind IS NOT NULL;
END $function$;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;
DO $v$ BEGIN
  IF md5(pg_get_functiondef('ops.fn_client_sludge_averages(date[])'::regprocedure)) <> '26b851af285d74cff24aab350be00ff1'
  OR md5(pg_get_functiondef('ops.fn_grease_estimates_live(date,date)'::regprocedure)) <> '792ad967bfdbb294339bc5955178bc22'
  OR md5(pg_get_functiondef('ops.calendar_grease_estimates(date,date)'::regprocedure)) <> '193f5260bf1e060c97a1a5690df9f025' THEN
    RAISE EXCEPTION 'rollback: bodies do not match the pre-step-7 md5';
  END IF;
END $v$;
