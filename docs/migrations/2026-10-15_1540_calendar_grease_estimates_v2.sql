-- ============================================================================
-- 2026-10-15_1540 Calendar "Grease pumped" v2: every pumping service, the client's average, moved visits keep theirs
-- ============================================================================
-- THE ASK (Fred, voice note 2026-10-15, then his picks on the v2 mockup the same afternoon):
--   "I do want at least the last six visits ... if it has only three visits, just take three visits instead ... if it
--   has zero visits ... go as the grease trap size"; "I only want to use right now for this icon the data from the
--   sensors ... the sludge sensor"; "go to the visits that are pumping ... even if it's like a service call ... a lift
--   station or gray water, sometimes they do actually do some pumping on the sludge tank"; "I need ... that to be safe
--   and correlated to the client in the database, so now we have this estimate about the average of how much pump the
--   client has"; picks: "1. All pumping services", "4. recompute once", "3. ... decide by yourself what is the best
--   approach"; and on past days: "once a date has passed the data should stay the same, we don't update that, unless we
--   move the visits ... once a date has passed it should stay the same unless like a visit is moved from that date or
--   into that date, then yes we'd need to recalculate, but i'd like to recalculate with that same average."
-- Plan + findings: Building Apps/Visit Calendar/docs/specs/2026-10-14-grease-pumped-icon-plan.md (v2 block);
-- mockup https://claude.ai/artifact/LEFrdpPWqTWej9DeM636mx (Version 2). Reviewed adversarially before apply (3 lenses).
--
-- WHAT IT CHANGES (v1 = 2026-10-15_1150)
--   1. ops.fn_visit_pump_kinds(visit, job) -> text[]: EVERY pump kind a visit's lines carry, in the order grease_trap,
--      grey_water, lift_station ('{}' when none). Same sources as before (own coded lines, else the job's open ones,
--      else the dated old-text exception). ops.fn_visit_pump_kind now returns its first element, so the single-kind
--      answer cannot drift from the list (VERIFY V2 proves it unchanged for every visit).
--   2. ops.fn_client_sludge_averages(dates[]) -> per (as_of date, property): the LAST 6 trusted sludge readings dated
--      before that day, their average, the date of the last one and the list. Trusted = public.v_visit_tank_service
--      visit_kind 'volume', confidence high/medium, 40 to 3,840 gal (the view's no-rise threshold and the tank), on a
--      visit with any pump kind (grease trap, grey water, lift station; service agreement or service call). Fewer than
--      6 is fine. The ONE definition of "the client's average"; the Calendar estimate and the view below both call it.
--   3. ops.v_client_sludge_average: each client place's average today, with the client code and name (Fred's
--      "correlated to the client"). Computed on read, never stored (DB rules 2 and 3): a correction of the sensor math
--      (86 readings on 10-15) flows in; past days are protected by the freeze instead.
--   4. ops.fn_grease_estimates_live: ALL pumping visits get gallons (v1: grease traps only, others 'other_pump').
--      Moises (app_config grease_separating_vehicle_ids) with at least 1 reading at that place: the average (2.); else
--      the trap size on file (ops.v_calendar_visit.equipment_size_gallons, the grease trap size: Fred accepted that a
--      grey water or lift station stop with no reading uses it); no size: 'unknown'. Adds pump_kinds.
--   5. ops.visit_grease_frozen gains pump_kinds (the bullets of a past day stay what they were); the guard now keeps it
--      immutable too. Existing rows are filled once, consistently with their stored pump_kind.
--   6. ops.fn_grease_estimates_resolved: what is shown. A past day with its own stored row: that row ('frozen').
--      Else a pumping visit now on Moises that has a stored MEASURED estimate from another date (it was moved) keeps
--      that average ('carried': Fred's "recalculate with that same average"; truck and trap size are today's, so a
--      visit moved onto David or Cloggy gets the whole trap size, as Fred's truck rule says). Else live ('live').
--   7. ops.calendar_grease_estimates: same guards, reads (6.), returns pump_kinds too (the hover bullets count per
--      pumping service). Return type changed, so DROP + CREATE and the grants again.
--   8. ops.fn_freeze_grease_estimates: stores the missing past rows from (6.) with pump_kinds, so a moved-in visit is
--      stored with its carried average; it computes only from the earliest day that has a missing row.
--   9. RECOMPUTE ONCE (Fred's pick 4), scoped to what the rule changed: the stored 'other_pump' rows (grey water and lift
--      stations, gallons NULL in v1). Rows whose visit is still on that day are stored again under the new rule, after
--      asserting their stored truck and trap size equal today's (else the migration stops: a person decides); rows
--      whose visit has left that day are only superseded (a later move back recalculates). No grease trap row is
--      touched. Logged in sync_log 'calendar_grease_refreeze' with the superseded ids (what the rollback restores).
-- NOT CHANGED: the cron, the health tuple, ops.v_calendar_visit, public.v_visit_tank_service, app_config.
-- RULE 8: ops.visit_grease_frozen stays OPT-OUT (machine-written, append-only, itself the record); the new view is
-- derived. GRANTS: every new object revoked by name from PUBLIC, anon, authenticated (Supabase default privileges grant
-- by name); service_role keeps what it needs; only ops.calendar_grease_estimates is EXECUTE-able by authenticated.
-- ⚠ DEPENDENCY (unchanged): public.v_visit_tank_service (visit_id, property_id, visit_date, visit_kind,
-- sludge_confidence, sludge_collected_gallons) and ops.v_calendar_visit (id, job_id, client_id, property_id,
-- vehicle_id, equipment_size_gallons, visit_date).
-- VERIFY pins as of 2026-10-15: Krudo (031-KRU) 292 from 2 readings; Oct 11 to 14 raw sums 1718, 1298, 1800, 1995.
--
-- HOW TO RUN: node scripts/probes/apply_sql_file.mjs <file> rehearse   (then without rehearse). Apply between :10 and
-- :55 ET, never 00:00 to 00:06 ET (yesterday not frozen yet) and not at :17 UTC of an even hour (the backup dump holds
-- locks; the ALTER waits 3 s and the whole migration rolls back, safely).
-- ROLLBACK: 2026-10-15_rollback_calendar_grease_estimates_v2.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- snapshot of the v1 single-kind answer, to prove 1. changes nothing for it
CREATE TEMP TABLE _kind_v1 ON COMMIT DROP AS
SELECT v.id, ops.fn_visit_pump_kind(v.id, v.job_id) AS k FROM public.visits v;

-- 1 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_visit_pump_kinds(p_visit_id bigint, p_job_id bigint) RETURNS text[]
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
  WITH own AS (
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.visit_id = p_visit_id AND sli.schedulable
  ), coded AS (
    SELECT * FROM own
    UNION ALL
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND sli.schedulable
       AND NOT EXISTS (SELECT 1 FROM own)
  ), old_text AS (  -- dated exception: lines from before the codes, only when nothing is coded
    SELECT btrim(li.name) AS nm
      FROM public.line_items li
     WHERE (li.visit_id = p_visit_id OR (li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL))
       AND btrim(li.name) !~ '^[0-9]'
       AND NOT EXISTS (SELECT 1 FROM coded)
  ), k AS (
    SELECT CASE WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grease trap' THEN 1
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grey water' THEN 2
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'lift station' THEN 3 END AS r
      FROM coded c
    UNION ALL
    SELECT CASE WHEN o.nm ~* 'grease trap' THEN 1
                WHEN o.nm ~* 'grey water' THEN 2
                WHEN o.nm ~* '(lift|lyft) station' THEN 3 END
      FROM old_text o
  )
  SELECT coalesce(array_agg(CASE r WHEN 1 THEN 'grease_trap' WHEN 2 THEN 'grey_water' ELSE 'lift_station' END ORDER BY r),
                  '{}'::text[])
    FROM (SELECT DISTINCT r FROM k WHERE r IS NOT NULL) d
$f$;
COMMENT ON FUNCTION ops.fn_visit_pump_kinds(bigint, bigint) IS
  'Every pump kind a visit''s lines carry (grease_trap, grey_water, lift_station, in that order). 2026-10-15_1540.';

CREATE OR REPLACE FUNCTION ops.fn_visit_pump_kind(p_visit_id bigint, p_job_id bigint) RETURNS text
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
  SELECT (ops.fn_visit_pump_kinds(p_visit_id, p_job_id))[1]
$f$;

-- 2 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_client_sludge_averages(p_dates date[])
RETURNS TABLE (as_of date, property_id bigint, client_id bigint, readings_n integer, avg_gallons numeric,
               last_reading_date date, readings jsonb)
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
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
$f$;
COMMENT ON FUNCTION ops.fn_client_sludge_averages(date[]) IS
  'The client''s average: per (as_of, property) the last 6 trusted sludge readings (40 to 3,840 gal) of pumping visits '
  'dated before as_of (fewer is fine), their rounded average, the last date and the list. The one definition; 2026-10-15_1540.';

-- 3 ---------------------------------------------------------------------------------------------------------
CREATE VIEW ops.v_client_sludge_average AS
SELECT a.client_id, c.client_code, c.name AS client_name, a.property_id, a.readings_n, a.avg_gallons,
       a.last_reading_date, a.readings
  FROM ops.fn_client_sludge_averages(ARRAY[((now() AT TIME ZONE 'America/New_York')::date + 1)]) a
  LEFT JOIN public.clients c ON c.id = a.client_id;
COMMENT ON VIEW ops.v_client_sludge_average IS
  'Each client place''s grease average today: the last 6 trusted sludge sensor readings of its pumping visits (Moises). '
  'Computed on read from ops.fn_client_sludge_averages. 2026-10-15_1540.';

-- 4 ---------------------------------------------------------------------------------------------------------
DROP FUNCTION ops.fn_grease_estimates_live(date, date);
CREATE FUNCTION ops.fn_grease_estimates_live(p_from date, p_to date)
RETURNS TABLE (visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], vehicle_id bigint,
               separates_water boolean, trap_size_gallons numeric, gallons numeric, basis text, readings integer)
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
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
$f$;

-- 5 ---------------------------------------------------------------------------------------------------------
ALTER TABLE ops.visit_grease_frozen ADD COLUMN pump_kinds text[];
COMMENT ON COLUMN ops.visit_grease_frozen.pump_kinds IS
  'Every pump kind of the visit when the day was stored (the hover bullets of a past day). 2026-10-15_1540.';

CREATE OR REPLACE FUNCTION ops.fn_visit_grease_frozen_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'ops', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ops.visit_grease_frozen is permanent: supersede a row instead of deleting it';
  END IF;
  IF OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL
     OR (NEW.visit_id, NEW.visit_date, NEW.pump_kind, NEW.vehicle_id, NEW.trap_size_gallons, NEW.gallons,
         NEW.basis, NEW.readings, NEW.frozen_at, NEW.pump_kinds)
        IS DISTINCT FROM
        (OLD.visit_id, OLD.visit_date, OLD.pump_kind, OLD.vehicle_id, OLD.trap_size_gallons, OLD.gallons,
         OLD.basis, OLD.readings, OLD.frozen_at, OLD.pump_kinds) THEN
    RAISE EXCEPTION 'ops.visit_grease_frozen rows never change: only superseded_at can be set, once';
  END IF;
  RETURN NEW;
END $function$;

-- the one-time fill, with the guard off for this statement only (same transaction)
ALTER TABLE ops.visit_grease_frozen DISABLE TRIGGER visit_grease_frozen_guard;
UPDATE ops.visit_grease_frozen f
   SET pump_kinds = CASE WHEN f.pump_kind IS NULL THEN '{}'::text[]
                         WHEN k.kinds[1] IS NOT DISTINCT FROM f.pump_kind THEN k.kinds
                         ELSE ARRAY[f.pump_kind] END
  FROM (SELECT x.id, ops.fn_visit_pump_kinds(v.id, v.job_id) AS kinds
          FROM ops.visit_grease_frozen x JOIN public.visits v ON v.id = x.visit_id) k
 WHERE k.id = f.id AND f.pump_kinds IS NULL;
ALTER TABLE ops.visit_grease_frozen ENABLE TRIGGER visit_grease_frozen_guard;

-- 6 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_grease_estimates_resolved(p_from date, p_to date)
RETURNS TABLE (visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], vehicle_id bigint,
               trap_size_gallons numeric, gallons numeric, basis text, readings integer, source text)
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
  SELECT l.visit_id, l.visit_date,
         CASE WHEN f.id IS NOT NULL THEN f.pump_kind ELSE l.pump_kind END,
         CASE WHEN f.id IS NOT NULL THEN coalesce(f.pump_kinds, array_remove(ARRAY[f.pump_kind], NULL)) ELSE l.pump_kinds END,
         CASE WHEN f.id IS NOT NULL THEN f.vehicle_id        ELSE l.vehicle_id END,
         CASE WHEN f.id IS NOT NULL THEN f.trap_size_gallons ELSE l.trap_size_gallons END,
         CASE WHEN f.id IS NOT NULL THEN f.gallons  WHEN c.id IS NOT NULL THEN c.gallons  ELSE l.gallons END,
         CASE WHEN f.id IS NOT NULL THEN f.basis    WHEN c.id IS NOT NULL THEN c.basis    ELSE l.basis END,
         CASE WHEN f.id IS NOT NULL THEN f.readings WHEN c.id IS NOT NULL THEN c.readings ELSE l.readings END,
         CASE WHEN f.id IS NOT NULL THEN 'frozen'   WHEN c.id IS NOT NULL THEN 'carried'  ELSE 'live' END
    FROM ops.fn_grease_estimates_live(p_from, p_to) l
    -- a past day keeps its own stored row
    LEFT JOIN ops.visit_grease_frozen f
      ON f.visit_id = l.visit_id AND f.visit_date = l.visit_date AND f.superseded_at IS NULL
     AND l.visit_date < (now() AT TIME ZONE 'America/New_York')::date
    -- a moved pumping visit still on Moises keeps the measured average it had on its earlier date
    LEFT JOIN LATERAL (
      SELECT x.* FROM ops.visit_grease_frozen x
       WHERE x.visit_id = l.visit_id AND x.visit_date <> l.visit_date AND x.superseded_at IS NULL
         AND x.basis = 'measured' AND x.gallons IS NOT NULL
       ORDER BY x.frozen_at DESC, x.id DESC
       LIMIT 1
    ) c ON f.id IS NULL AND l.pump_kind IS NOT NULL AND l.separates_water
$f$;

-- 7 ---------------------------------------------------------------------------------------------------------
DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
RETURNS TABLE (visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text,
               readings integer, frozen boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, public, pg_temp AS $f$
#variable_conflict use_column
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
BEGIN
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_grease_estimates: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_grease_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live'
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
   WHERE r.pump_kind IS NOT NULL;
END $f$;

-- 8 ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.fn_freeze_grease_estimates() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public, pg_temp AS $f$
DECLARE
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_started timestamptz := clock_timestamp();
  v_from    date;
  n         integer := 0;
  n_carried integer := 0;
  v_err     text;
BEGIN
  BEGIN
    -- only from the earliest past day that has a visit with no stored row (usually yesterday)
    SELECT min(cv.visit_date) INTO v_from
      FROM ops.v_calendar_visit cv
     WHERE cv.visit_date BETWEEN date '2026-01-01' AND v_today - 1
       AND NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
                        WHERE f.visit_id = cv.id AND f.visit_date = cv.visit_date AND f.superseded_at IS NULL);
    IF v_from IS NOT NULL THEN
      WITH src AS MATERIALIZED (
        SELECT * FROM ops.fn_grease_estimates_resolved(v_from, v_today - 1) r WHERE r.source <> 'frozen'
      ), ins AS (
        INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, trap_size_gallons, gallons, basis, readings)
        SELECT s.visit_id, s.visit_date, s.pump_kind, s.pump_kinds, s.vehicle_id, s.trap_size_gallons, s.gallons, s.basis, s.readings
          FROM src s
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM src WHERE src.source = 'carried') INTO n, n_carried;
    END IF;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_inserted, status, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), n, 'success',
            jsonb_build_object('frozen', n, 'carried', n_carried, 'from', v_from, 'through', v_today - 1));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    n := 0;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_errored, status, error_details, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), 1, 'error',
            jsonb_build_object('message', left(v_err, 300)), jsonb_build_object('through', v_today - 1));
  END;
  RETURN n;
END $f$;

-- grants (by name; Supabase default privileges hand out EXECUTE/SELECT nobody wrote) ----------------------------
REVOKE ALL ON FUNCTION ops.fn_visit_pump_kinds(bigint, bigint)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_visit_pump_kind(bigint, bigint)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_client_sludge_averages(date[])             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_grease_estimates_live(date, date)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_grease_estimates_resolved(date, date)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_freeze_grease_estimates()                  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_visit_grease_frozen_guard()                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date)         FROM PUBLIC, anon;
REVOKE ALL ON ops.v_client_sludge_average                                FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_visit_pump_kinds(bigint, bigint)        TO service_role;
GRANT EXECUTE ON FUNCTION ops.fn_visit_pump_kind(bigint, bigint)         TO service_role;
GRANT EXECUTE ON FUNCTION ops.fn_client_sludge_averages(date[])          TO service_role;
GRANT SELECT  ON ops.v_client_sludge_average                             TO service_role;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date)      TO authenticated, service_role;

-- 9 RECOMPUTE ONCE, scoped to the rows the rule changed --------------------------------------------------------
DO $r$
DECLARE
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  v_stay   bigint[];
  v_gone   bigint[];
  n_drift  int;
  n_ins    int;
BEGIN
  CREATE TEMP TABLE _newv ON COMMIT DROP AS
  SELECT * FROM ops.fn_grease_estimates_live(date '2026-01-01', v_today - 1);

  -- other_pump rows whose visit is still on that day: stored again under the new rule
  SELECT array_agg(f.id ORDER BY f.id) INTO v_stay
    FROM ops.visit_grease_frozen f JOIN _newv n ON n.visit_id = f.visit_id AND n.visit_date = f.visit_date
   WHERE f.superseded_at IS NULL AND f.basis = 'other_pump';
  -- other_pump rows whose visit has left that day: superseded only
  SELECT array_agg(f.id ORDER BY f.id) INTO v_gone
    FROM ops.visit_grease_frozen f
   WHERE f.superseded_at IS NULL AND f.basis = 'other_pump'
     AND NOT EXISTS (SELECT 1 FROM _newv n WHERE n.visit_id = f.visit_id AND n.visit_date = f.visit_date);

  -- past inputs must equal today's for the rows recomputed, or a person decides
  SELECT count(*) INTO n_drift
    FROM ops.visit_grease_frozen f JOIN _newv n ON n.visit_id = f.visit_id AND n.visit_date = f.visit_date
   WHERE f.id = ANY (coalesce(v_stay, '{}'))
     AND (f.vehicle_id IS DISTINCT FROM n.vehicle_id OR f.trap_size_gallons IS DISTINCT FROM n.trap_size_gallons
          OR f.pump_kind IS DISTINCT FROM n.pump_kind);
  IF n_drift <> 0 THEN
    RAISE EXCEPTION 'recompute: % stored grey water / lift station rows have a truck, trap size or kind different from today: decide by hand', n_drift; END IF;

  UPDATE ops.visit_grease_frozen SET superseded_at = now()
   WHERE id = ANY (coalesce(v_stay, '{}') || coalesce(v_gone, '{}'));

  INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, trap_size_gallons, gallons, basis, readings)
  SELECT n.visit_id, n.visit_date, n.pump_kind, n.pump_kinds, n.vehicle_id, n.trap_size_gallons, n.gallons, n.basis, n.readings
    FROM ops.visit_grease_frozen f JOIN _newv n ON n.visit_id = f.visit_id AND n.visit_date = f.visit_date
   WHERE f.id = ANY (coalesce(v_stay, '{}'));
  GET DIAGNOSTICS n_ins = ROW_COUNT;
  IF n_ins <> coalesce(array_length(v_stay, 1), 0) THEN
    RAISE EXCEPTION 'recompute: % rows to store again but % stored', coalesce(array_length(v_stay, 1), 0), n_ins; END IF;

  INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_updated, status, details)
  VALUES ('calendar_grease_refreeze', now(), clock_timestamp(), 0,
          coalesce(array_length(v_stay, 1), 0) + coalesce(array_length(v_gone, 1), 0), 'success',
          jsonb_build_object('migration', '2026-10-15_1540', 'superseded_at', now(),
                             'stored_again', coalesce(array_length(v_stay, 1), 0),
                             'superseded_ids', to_jsonb(coalesce(v_stay, '{}') || coalesce(v_gone, '{}'))));
END $r$;

-- VERIFY ----------------------------------------------------------------------------------------------------
DO $v$
DECLARE n int; m int; g numeric; ks text[]; r record; v_vid bigint; v_d date; v_want numeric;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  -- V1 grants
  IF has_table_privilege('authenticated', 'ops.v_client_sludge_average', 'SELECT') OR has_table_privilege('anon', 'ops.v_client_sludge_average', 'SELECT')
     OR has_function_privilege('authenticated', 'ops.fn_client_sludge_averages(date[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_grease_estimates_live(date,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_grease_estimates_resolved(date,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_freeze_grease_estimates()', 'EXECUTE')
     OR has_function_privilege('anon', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'ops.visit_grease_frozen', 'SELECT')
     OR NOT has_function_privilege('authenticated', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE')
     OR NOT has_table_privilege('service_role', 'ops.v_client_sludge_average', 'SELECT') THEN
    RAISE EXCEPTION 'V1 grants wrong'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'visit_grease_frozen_guard' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'V1 the guard trigger is not enabled'; END IF;

  -- V2 the single-kind answer is unchanged for every visit (positive control: hundreds of pumping visits)
  SELECT count(*) FILTER (WHERE k IS NOT NULL) INTO m FROM _kind_v1;
  IF m < 500 THEN RAISE EXCEPTION 'V2 control: only % pumping visits in the snapshot', m; END IF;
  SELECT count(*) INTO n FROM _kind_v1 s JOIN public.visits v ON v.id = s.id
   WHERE ops.fn_visit_pump_kind(v.id, v.job_id) IS DISTINCT FROM s.k;
  IF n <> 0 THEN RAISE EXCEPTION 'V2 % visits changed pump kind', n; END IF;

  -- V3 every kind is listed: 6224 (083-SHUL, Oct 14) pumps a grease trap and a lift station; 8587 is grey water
  SELECT ops.fn_visit_pump_kinds(v.id, v.job_id) INTO ks FROM public.visits v WHERE v.id = 6224;
  IF ks IS DISTINCT FROM ARRAY['grease_trap', 'lift_station'] THEN RAISE EXCEPTION 'V3 6224 kinds %', ks; END IF;
  SELECT ops.fn_visit_pump_kinds(v.id, v.job_id) INTO ks FROM public.visits v WHERE v.id = 8587;
  IF ks IS DISTINCT FROM ARRAY['grey_water'] THEN RAISE EXCEPTION 'V3 8587 kinds %', ks; END IF;
  -- and a past day returns the STORED list: 6224 on Oct 14
  SELECT e.pump_kinds INTO ks FROM ops.calendar_grease_estimates('2026-10-14', '2026-10-14') e WHERE e.visit_id = 6224;
  IF ks IS DISTINCT FROM ARRAY['grease_trap', 'lift_station'] THEN RAISE EXCEPTION 'V3 stored kinds of 6224 read %', ks; END IF;
  SELECT count(*) INTO n FROM ops.visit_grease_frozen
   WHERE superseded_at IS NULL AND (pump_kinds IS NULL OR pump_kinds[1] IS DISTINCT FROM pump_kind);
  IF n <> 0 THEN RAISE EXCEPTION 'V3 % stored rows have no or inconsistent pump_kinds', n; END IF;

  -- V4 the client's average: Krudo Fish Market (031-KRU) = (299.7 + 285.0) / 2 -> 292 from 2 readings (as of 10-15)
  SELECT count(*), max(avg_gallons), max(readings_n) INTO n, g, m FROM ops.v_client_sludge_average WHERE client_code = '031-KRU';
  IF n <> 1 OR g IS DISTINCT FROM 292 OR m <> 2 THEN RAISE EXCEPTION 'V4 031-KRU average % from % readings (% rows)', g, m, n; END IF;
  SELECT count(*) INTO n FROM ops.v_client_sludge_average;
  IF n < 80 THEN RAISE EXCEPTION 'V4 only % client places have an average', n; END IF;
  SELECT count(*) INTO n FROM ops.v_client_sludge_average
   WHERE readings_n > 6 OR readings_n < 1 OR jsonb_array_length(readings) <> readings_n OR avg_gallons < 40;
  IF n <> 0 THEN RAISE EXCEPTION 'V4 % rows break the 1 to 6 readings or the 40 gal floor', n; END IF;

  -- V5 the week: raw sums of the shown pumping visits (the app rounds to 10): Sun 1718, Mon 1298, Tue 1800, Wed 1995
  FOR r IN SELECT * FROM (VALUES (date '2026-10-11', 1718::numeric), (date '2026-10-12', 1298), (date '2026-10-13', 1800), (date '2026-10-14', 1995)) t(d, want) LOOP
    SELECT sum(e.gallons) INTO g FROM ops.calendar_grease_estimates(r.d, r.d) e
      JOIN ops.v_calendar_visit cv ON cv.id = e.visit_id AND cv.visit_date = e.visit_date
     WHERE coalesce(cv.visit_status, '') NOT IN ('skipped', 'cancelled');
    IF g IS DISTINCT FROM r.want THEN RAISE EXCEPTION 'V5 % sums %, expected %', r.d, g, r.want; END IF;
  END LOOP;
  SELECT e.gallons INTO g FROM ops.calendar_grease_estimates('2026-10-13', '2026-10-13') e WHERE e.visit_id = 8587;
  IF g IS DISTINCT FROM 120 THEN RAISE EXCEPTION 'V5 8587 (grey water, David) reads %', g; END IF;

  -- V6 the recompute: only other_pump rows were superseded, the ones stored again equal the new rule, none left
  SELECT count(*) INTO n FROM ops.visit_grease_frozen WHERE superseded_at = now() AND basis <> 'other_pump';
  IF n <> 0 THEN RAISE EXCEPTION 'V6 the recompute superseded % rows that were not other_pump', n; END IF;
  SELECT count(*), count(*) FILTER (WHERE f.gallons IS DISTINCT FROM n2.gallons OR f.basis IS DISTINCT FROM n2.basis
                                       OR f.readings IS DISTINCT FROM n2.readings OR f.pump_kinds IS DISTINCT FROM n2.pump_kinds)
    INTO n, m
    FROM ops.visit_grease_frozen f JOIN _newv n2 ON n2.visit_id = f.visit_id AND n2.visit_date = f.visit_date
   WHERE f.superseded_at IS NULL AND f.frozen_at = now();
  IF n < 80 THEN RAISE EXCEPTION 'V6 control: only % rows stored again', n; END IF;
  IF m <> 0 THEN RAISE EXCEPTION 'V6 % stored-again rows differ from the new rule', m; END IF;
  IF EXISTS (SELECT 1 FROM ops.visit_grease_frozen WHERE superseded_at IS NULL AND basis = 'other_pump') THEN
    RAISE EXCEPTION 'V6 other_pump rows remain'; END IF;

  -- V7 a moved visit (rolled back each time)
  -- (a) today or later, on Moises: a stored MEASURED average from another date is carried
  SELECT l.visit_id, l.visit_date INTO v_vid, v_d FROM ops.fn_grease_estimates_live(v_today, v_today + 21) l
   WHERE l.pump_kind IS NOT NULL AND l.separates_water
     AND NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen x WHERE x.visit_id = l.visit_id AND x.superseded_at IS NULL)
   ORDER BY l.visit_date, l.visit_id LIMIT 1;
  IF v_vid IS NULL THEN RAISE EXCEPTION 'V7a no Moises pumping visit in the next 3 weeks to test with'; END IF;
  BEGIN
    INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, gallons, basis, readings)
    VALUES (v_vid, v_today - 30, 'grease_trap', '{grease_trap}', 1, 777, 'measured', 3);
    SELECT e.gallons INTO g FROM ops.calendar_grease_estimates(v_d, v_d) e WHERE e.visit_id = v_vid;
    IF g IS DISTINCT FROM 777 THEN RAISE EXCEPTION 'V7a % reads %, expected the carried 777', v_vid, g; END IF;
    RAISE EXCEPTION 'v7_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v7_rollback' THEN RAISE; END IF;
  END;
  -- (a2) not carried when the stored row was a trap size (no average then)
  BEGIN
    SELECT e.gallons INTO v_want FROM ops.calendar_grease_estimates(v_d, v_d) e WHERE e.visit_id = v_vid;
    INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, gallons, basis, readings)
    VALUES (v_vid, v_today - 30, 'grease_trap', '{grease_trap}', 3, 444, 'trap_size', 0);
    SELECT e.gallons INTO g FROM ops.calendar_grease_estimates(v_d, v_d) e WHERE e.visit_id = v_vid;
    IF g IS DISTINCT FROM v_want THEN RAISE EXCEPTION 'V7a2 % reads %, a trap-size row was carried', v_vid, g; END IF;
    RAISE EXCEPTION 'v7_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v7_rollback' THEN RAISE; END IF;
  END;
  -- (a3) not carried onto a stop that is not on Moises: a David or Cloggy stop keeps the trap size rule
  SELECT l.visit_id, l.visit_date, l.gallons INTO v_vid, v_d, v_want FROM ops.fn_grease_estimates_live(v_today, v_today + 21) l
   WHERE l.pump_kind IS NOT NULL AND NOT l.separates_water ORDER BY l.visit_date, l.visit_id LIMIT 1;
  IF v_vid IS NOT NULL THEN
    BEGIN
      INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, gallons, basis, readings)
      VALUES (v_vid, v_today - 30, 'grease_trap', '{grease_trap}', 1, 777, 'measured', 3);
      SELECT e.gallons INTO g FROM ops.calendar_grease_estimates(v_d, v_d) e WHERE e.visit_id = v_vid;
      IF g IS DISTINCT FROM v_want THEN RAISE EXCEPTION 'V7a3 % (not Moises) reads %, expected its own %', v_vid, g, v_want; END IF;
      RAISE EXCEPTION 'v7_rollback';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v7_rollback' THEN RAISE; END IF;
    END;
  END IF;
  -- (b) into a past day: Wed 14's 6608 (Krudo, stored 300) without its own row carries the other date's average
  BEGIN
    UPDATE ops.visit_grease_frozen SET superseded_at = now() WHERE visit_id = 6608 AND visit_date = '2026-10-14' AND superseded_at IS NULL;
    INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, gallons, basis, readings)
    VALUES (6608, '2026-09-30', 'grease_trap', '{grease_trap}', 1, 555, 'measured', 1);
    SELECT e.gallons INTO g FROM ops.calendar_grease_estimates('2026-10-14', '2026-10-14') e WHERE e.visit_id = 6608;
    IF g IS DISTINCT FROM 555 THEN RAISE EXCEPTION 'V7b 6608 reads %, expected the carried 555', g; END IF;
    PERFORM ops.fn_freeze_grease_estimates();
    SELECT f.gallons, f.vehicle_id, f.pump_kinds INTO g, n, ks FROM ops.visit_grease_frozen f
     WHERE f.visit_id = 6608 AND f.visit_date = '2026-10-14' AND f.superseded_at IS NULL;
    IF g IS DISTINCT FROM 555 OR n IS DISTINCT FROM 1 OR ks IS DISTINCT FROM ARRAY['grease_trap'] THEN
      RAISE EXCEPTION 'V7b the freezer stored % gal, truck %, kinds %', g, n, ks; END IF;
    IF (SELECT status FROM public.sync_log WHERE sync_source = 'calendar_grease_freeze' ORDER BY id DESC LIMIT 1) <> 'success' THEN
      RAISE EXCEPTION 'V7b the freezer logged an error: %', (SELECT error_details FROM public.sync_log WHERE sync_source = 'calendar_grease_freeze' ORDER BY id DESC LIMIT 1); END IF;
    RAISE EXCEPTION 'v7_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v7_rollback' THEN RAISE; END IF;
  END;
  SELECT f.gallons INTO g FROM ops.visit_grease_frozen f WHERE f.visit_id = 6608 AND f.visit_date = '2026-10-14' AND f.superseded_at IS NULL;
  IF g IS DISTINCT FROM 300 THEN RAISE EXCEPTION 'V7 rollback left 6608 at %', g; END IF;

  -- V8 the reader as the app calls it, and the view as service_role
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM ops.calendar_grease_estimates('2026-10-11', '2026-10-17');
  RESET ROLE;
  IF n < 25 THEN RAISE EXCEPTION 'V8 authenticated got % rows for the week', n; END IF;
  SET LOCAL ROLE service_role;
  SELECT count(*) INTO n FROM ops.v_client_sludge_average;
  RESET ROLE;
  IF n < 80 THEN RAISE EXCEPTION 'V8 service_role sees % client averages', n; END IF;

  -- V9 the range guard
  BEGIN
    PERFORM * FROM ops.calendar_grease_estimates('2026-01-01', '2026-03-01');
    RAISE EXCEPTION 'V9 a 59-day range went through';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'calendar_grease_estimates: bad range%' THEN RAISE; END IF;
  END;

  -- V10 the guard still refuses a change to a stored row, pump_kinds included (rolled back)
  BEGIN
    UPDATE ops.visit_grease_frozen SET pump_kinds = '{}' WHERE visit_id = 6608 AND visit_date = '2026-10-14' AND superseded_at IS NULL;
    RAISE EXCEPTION 'V10 an UPDATE of pump_kinds went through';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'ops.visit_grease_frozen rows never change%' THEN RAISE; END IF;
  END;

  -- V11 the cron is untouched
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'calendar-grease-freeze' AND schedule = '5 * * * *') THEN
    RAISE EXCEPTION 'V11 cron calendar-grease-freeze missing'; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
