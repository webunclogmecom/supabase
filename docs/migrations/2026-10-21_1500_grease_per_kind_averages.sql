-- 2026-10-21_1500 · Grease pumped step 7: lift stations and grey water at grease-trap places
--
-- Fred, 2026-10-21: "go ahead with step 7" (plan Building Apps/Visit Calendar/docs/specs/
-- 2026-10-21-grease-pumped-data-audit-and-plan.md, step 7; reverses his 10-15 acceptance of the borrowed size).
--
-- WHAT
--  1. ops.fn_client_sludge_averages: one average per place AND pump kind (new last column pump_kind). A lift station
--     or grey water reading never feeds the grease trap average of the same place, and the other way round.
--     DROP + CREATE (return type change); ops.v_client_sludge_average re-created with pump_kind appended.
--  2. ops.fn_grease_estimates_live: a visit reads the average of its own first pump kind. A lift station or grey water
--     visit (no grease trap line) at a place with an open grease trap job no longer borrows the trap size on file
--     (it is the grease trap's): it is 'unknown' (gallons NULL) until Moises has a reading of its own kind.
--  3. ops.calendar_grease_estimates: new last column unknown_reason ('no_size' / 'no_reading_for_kind') so the
--     Calendar hover says the truth for those stops. DROP + CREATE, grants restored.
-- REACH (dry run 2026-10-21 14:55 ET over all of 2026): 17 visits at 4 places (031-KRU, 083-SHUL, 168-AVA, 196-PV);
--  14 are past days, frozen in ops.visit_grease_frozen, so they do NOT move (past days stay the same, Fred 10-15).
--  Moves now: 6844 (Oct 28, Cloggy, 375 -> unknown), 6845 (Nov 27) and 6846 (Dec 27) on Moises (292, the pooled
--  grease trap average -> unknown). No grease trap visit changes (none used a lift station or grey water reading).
-- RULE 8: no table created or changed; functions and a view only.
-- ROLLBACK: 2026-10-21_rollback_grease_per_kind_averages.sql

DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.fn_client_sludge_averages(date[])'::regprocedure)) <> '26b851af285d74cff24aab350be00ff1'
  OR md5(pg_get_functiondef('ops.fn_grease_estimates_live(date,date)'::regprocedure)) <> '792ad967bfdbb294339bc5955178bc22'
  OR md5(pg_get_functiondef('ops.calendar_grease_estimates(date,date)'::regprocedure)) <> '193f5260bf1e060c97a1a5690df9f025' THEN
    RAISE EXCEPTION 'step 7: a live body changed since the dry run, stop';
  END IF;
END $g$;

-- snapshot of the Calendar's answer before the change (today .. +70 days), compared in VERIFY
CREATE TEMP TABLE s7_before ON COMMIT DROP AS
  SELECT * FROM ops.calendar_grease_estimates((now() AT TIME ZONE 'America/New_York')::date,
                                              (now() AT TIME ZONE 'America/New_York')::date + 45)
  UNION ALL
  SELECT * FROM ops.calendar_grease_estimates((now() AT TIME ZONE 'America/New_York')::date + 46,
                                              (now() AT TIME ZONE 'America/New_York')::date + 70);

DROP VIEW ops.v_client_sludge_average;
DROP FUNCTION ops.fn_client_sludge_averages(date[]);
CREATE FUNCTION ops.fn_client_sludge_averages(p_dates date[])
 RETURNS TABLE(as_of date, property_id bigint, client_id bigint, readings_n integer, avg_gallons numeric, last_reading_date date, readings jsonb, pump_kind text)
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
  -- one average per place AND pump kind (step 7, 2026-10-21): a lift station or grey water reading never feeds
  -- the grease trap average of the same place, and the other way round. A visit's kind is its first pump kind
  -- (grease trap, then grey water, then lift station), the same rule the estimate uses.
  SELECT d.as_of, pr.property_id, l.client_id, l.n, l.avg_g, l.last_d, l.rs, pr.kind
    FROM d
    CROSS JOIN (SELECT DISTINCT ok.property_id, ok.kind FROM ok) pr
    CROSS JOIN LATERAL (
      SELECT count(*)::int AS n, round(avg(x.g)) AS avg_g, max(x.visit_date) AS last_d,
             (array_agg(x.client_id ORDER BY x.visit_date DESC, x.visit_id DESC))[1] AS client_id,
             jsonb_agg(jsonb_build_object('visit_id', x.visit_id, 'visit_date', x.visit_date,
                                          'gallons', round(x.g, 1), 'pump_kind', x.kind)
                       ORDER BY x.visit_date DESC, x.visit_id DESC) AS rs
        FROM (SELECT ok.* FROM ok
               WHERE ok.property_id = pr.property_id AND ok.kind = pr.kind AND ok.visit_date < d.as_of
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
    a.readings,
    a.pump_kind
   FROM ops.fn_client_sludge_averages(ARRAY[((now() AT TIME ZONE 'America/New_York')::date + 1)]) a
     LEFT JOIN public.clients c ON c.id = a.client_id;

REVOKE ALL ON ops.v_client_sludge_average FROM PUBLIC, anon, authenticated;
GRANT SELECT ON ops.v_client_sludge_average TO service_role, db_backup_reader;
COMMENT ON VIEW ops.v_client_sludge_average IS 'Each client place''s grease average today, per pump kind: the last 6 trusted sludge sensor readings of its pumping visits of that kind (Moises). Computed on read from ops.fn_client_sludge_averages. 2026-10-15_1540, per kind since 2026-10-21_1500.';

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
  ),
  -- step 7 (2026-10-21): places with a grease trap service, i.e. an open job (not archived or destroyed) whose
  -- own lines pump a grease trap. The trap size on file there is the grease trap's, so a lift station or grey
  -- water visit at such a place never borrows it. Decided from jobs only, so the answer does not depend on the
  -- date range asked for.
  gt AS MATERIALIZED (
    SELECT DISTINCT j.property_id AS prop FROM public.jobs j
     WHERE j.property_id IN (SELECT tv.prop FROM tv WHERE tv.kinds <> '{}' AND NOT ('grease_trap' = ANY (tv.kinds)))
       AND coalesce(j.job_status, '') NOT IN ('archived', 'destroyed')
       AND 'grease_trap' = ANY (ops.fn_visit_pump_kinds(NULL::bigint, j.id))
  )
  SELECT tv.id, tv.visit_date, tv.kinds[1], tv.kinds, tv.vehicle_id, s.sep, tv.cap,
         CASE WHEN tv.kinds = '{}' THEN NULL
              WHEN s.sep AND a.readings_n >= 1 THEN a.avg_gallons
              WHEN b.borrowed THEN NULL
              ELSE round(tv.cap) END,
         CASE WHEN tv.kinds = '{}' THEN 'not_pumping'
              WHEN s.sep AND a.readings_n >= 1 THEN 'measured'
              WHEN b.borrowed THEN 'unknown'
              WHEN tv.cap IS NOT NULL THEN 'trap_size'
              ELSE 'unknown' END,
         CASE WHEN s.sep AND tv.kinds <> '{}' THEN coalesce(a.readings_n, 0) ELSE 0 END
    FROM tv
    CROSS JOIN cfg
    CROSS JOIN LATERAL (SELECT coalesce(tv.vehicle_id = ANY (cfg.sep), false) AS sep) s
    CROSS JOIN LATERAL (SELECT (tv.kinds <> '{}' AND NOT ('grease_trap' = ANY (tv.kinds))
                                AND tv.prop IN (SELECT gt.prop FROM gt)) AS borrowed) b
    LEFT JOIN av a ON a.as_of = tv.visit_date AND a.property_id = tv.prop AND a.pump_kind = tv.kinds[1]
$function$;

DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean, vehicle_id bigint, measured_gallons numeric, measurable boolean, vehicle_source text, truck_capacity_gallons numeric, over_truck_capacity boolean, unknown_reason text)
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
         coalesce(r.gallons > vh.grease_tank_capacity_gallons, false),
         -- 2026-10-21_1500 (step 7): why a stop adds nothing. 'no_size': no trap size on file. 'no_reading_for_kind':
         -- a lift station or grey water stop at a place whose trap size is the grease trap's, with no reading of its own
         CASE WHEN r.gallons IS NULL THEN CASE WHEN r.trap_size_gallons IS NOT NULL THEN 'no_reading_for_kind'
                                               ELSE 'no_size' END END
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
    LEFT JOIN m ON m.m_visit_id = r.visit_id AND m.m_date = r.visit_date
    LEFT JOIN cv ON cv.vs_id = r.visit_id AND cv.vs_date = r.visit_date
    LEFT JOIN public.vehicles vh ON vh.id = r.vehicle_id
   WHERE r.pump_kind IS NOT NULL;
END $function$;

REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;

-- VERIFY
DO $v$
DECLARE n_changed int; n_bad int; bad text;
BEGIN
  CREATE TEMP TABLE s7_after ON COMMIT DROP AS
    SELECT * FROM ops.calendar_grease_estimates((now() AT TIME ZONE 'America/New_York')::date,
                                                (now() AT TIME ZONE 'America/New_York')::date + 45)
    UNION ALL
    SELECT * FROM ops.calendar_grease_estimates((now() AT TIME ZONE 'America/New_York')::date + 46,
                                                (now() AT TIME ZONE 'America/New_York')::date + 70);
  -- 1. same rows
  SELECT count(*) INTO n_bad FROM (
    (SELECT visit_id, visit_date FROM s7_before EXCEPT ALL SELECT visit_id, visit_date FROM s7_after)
    UNION ALL
    (SELECT visit_id, visit_date FROM s7_after EXCEPT ALL SELECT visit_id, visit_date FROM s7_before)) z;
  IF n_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 1: row set changed (%)', n_bad; END IF;
  -- 2. only 6844, 6845, 6846 change
  SELECT string_agg(a.visit_id::text, ',' ORDER BY a.visit_id), count(*) INTO bad, n_changed
    FROM s7_after a JOIN s7_before b USING (visit_id, visit_date)
   WHERE (a.gallons, a.basis, a.readings, a.over_truck_capacity, a.pump_kind, a.vehicle_id)
         IS DISTINCT FROM (b.gallons, b.basis, b.readings, b.over_truck_capacity, b.pump_kind, b.vehicle_id);
  IF coalesce(bad, '') <> '6844,6845,6846' THEN
    RAISE EXCEPTION 'VERIFY 2: changed visits are % (expected 6844,6845,6846)', bad;
  END IF;
  -- 3. they become unknown with the new reason
  IF EXISTS (SELECT 1 FROM s7_after WHERE visit_id IN (6844, 6845, 6846)
              AND (gallons IS NOT NULL OR basis <> 'unknown' OR unknown_reason IS DISTINCT FROM 'no_reading_for_kind')) THEN
    RAISE EXCEPTION 'VERIFY 3: the three lift station stops are not unknown / no_reading_for_kind';
  END IF;
  -- 4. every other stop without gallons says no_size; every stop with gallons has no reason
  IF EXISTS (SELECT 1 FROM s7_after WHERE gallons IS NULL AND visit_id NOT IN (6844, 6845, 6846)
              AND unknown_reason IS DISTINCT FROM 'no_size')
  OR EXISTS (SELECT 1 FROM s7_after WHERE gallons IS NOT NULL AND unknown_reason IS NOT NULL) THEN
    RAISE EXCEPTION 'VERIFY 4: unknown_reason wrong on another stop';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM s7_after WHERE unknown_reason = 'no_size') THEN
    RAISE EXCEPTION 'VERIFY 4b: positive control, a no_size stop (077-TCE Oct 23) must exist';
  END IF;
  -- 5. grants
  IF NOT has_function_privilege('authenticated', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE')
  OR has_function_privilege('anon', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE')
  OR has_function_privilege('authenticated', 'ops.fn_client_sludge_averages(date[])', 'EXECUTE')
  OR has_table_privilege('authenticated', 'ops.v_client_sludge_average', 'SELECT')
  OR NOT has_table_privilege('service_role', 'ops.v_client_sludge_average', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 5: grants';
  END IF;
  -- 6. the view: one row per place and kind; 031-KRU has a grease trap row and no lift station row
  IF EXISTS (SELECT 1 FROM ops.v_client_sludge_average GROUP BY property_id, pump_kind HAVING count(*) > 1)
  OR EXISTS (SELECT 1 FROM ops.v_client_sludge_average WHERE client_code = '031-KRU' AND pump_kind = 'lift_station')
  OR NOT EXISTS (SELECT 1 FROM ops.v_client_sludge_average WHERE client_code = '031-KRU' AND pump_kind = 'grease_trap') THEN
    RAISE EXCEPTION 'VERIFY 6: view';
  END IF;
  RAISE NOTICE 'step 7 VERIFY ok: % stops changed', n_changed;
END $v$;
