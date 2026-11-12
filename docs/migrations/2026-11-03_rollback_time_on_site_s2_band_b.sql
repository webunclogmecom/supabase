-- ============================================================================
-- 2026-11-03_rollback_time_on_site_s2_band_b  Undo 2026-11-03_1300_time_on_site_s2_band_b (re-check stage S2)
-- ============================================================================
-- WHAT IT DOES
--   1. A written visit (labels and values, 10) gets its old_* back ONLY while it still holds the S2 row's new_*; a visit
--      that moved since is listed in the NOTICE and left alone (re-measure it instead).
--   2. Every current row of run tos-recheck-2026-r2 gets superseded_at and status 'rolled_back' (never deleted).
--   3. Only then are the 10-18 rows those rows superseded (evidence->'superseded_row_id') made current again: the unique
--      current-row index allows one current row per visit. 8854 is left with no current row, as before S2.
-- PIN: fn_time_on_site_checks is the S1 body; the run has 62 rows and its current rows still name the rows they
--   superseded.
-- VERIFY: the 61 10-18 rows are current again and byte-identical to before S2 (md5 1471d90964c37d521b2a054d307aee73);
--   no current row of the run; the restored visits hold old_*; only visits and the ledger audited, labelled;
--   T7 = T8 = 0.
-- LABEL: x-app-source time-on-site-recheck-2026.
-- REHEARSED: on top of the forward file, in one rolled-back transaction (S2/rehearse.mjs r, local).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) NOT IN ('11e4b8113c609737ea8edd5798faa833', '03d6d444ec2f782418ab28c575e149b7') THEN   -- the S1 body, or the same with T12 (2026-11-12_1430)
    RAISE EXCEPTION 'S2 rollback: fn_time_on_site_checks() is not the S1 body'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r2') <> 62 THEN
    RAISE EXCEPTION 'S2 rollback: run tos-recheck-2026-r2 does not have 62 rows'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-recheck-2026-r2' AND l.superseded_at IS NULL
              AND l.visit_id <> 8854 AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections o
                                                     WHERE o.id = (l.evidence->>'superseded_row_id')::bigint AND o.visit_id = l.visit_id AND o.superseded_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'S2 rollback: a current S2 row does not name the 10-18 row it superseded'; END IF;
END $pin$;

CREATE TEMP TABLE _rb ON COMMIT DROP AS
SELECT l.id, l.visit_id, (l.evidence->>'superseded_row_id')::bigint AS old_lid, l.evidence->>'s2_kind' AS kind,
       l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.new_minutes, l.new_arrival, l.new_departure, l.new_source
  FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-recheck-2026-r2' AND l.superseded_at IS NULL;
CREATE TEMP TABLE _rb_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; moved jsonb;
BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _rb) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (SELECT visit_id FROM _rb) FOR UPDATE;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Rollback of visit duration re-check stage S2 (run tos-recheck-2026-r2): the 10-18 band B rows are current again and the 10 written visits get their previous values back.'))::text, true);
  SELECT jsonb_agg(r.visit_id) INTO moved FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.kind IN ('relabel', 'relabel_card', 'change', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  IF moved IS NOT NULL THEN RAISE NOTICE 'S2 rollback: these visits moved since S2 and are NOT restored: %', moved; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.old_minutes, actual_arrival_at = r.old_arrival, actual_departure_at = r.old_departure, time_on_site_source = r.old_source
    FROM _rb r WHERE v.id = r.visit_id AND r.kind IN ('relabel', 'relabel_card', 'change', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS NOT DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now(), status = 'rolled_back', rolled_back_at = now()
    FROM _rb r WHERE l.id = r.id;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _rb) THEN RAISE EXCEPTION 'S2 rollback: rolled back % rows, expected %', n, (SELECT count(*) FROM _rb); END IF;
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = NULL
    FROM _rb r WHERE l.id = r.old_lid AND l.superseded_at IS NOT NULL;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; c text; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _rb_ctx);
BEGIN
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.run_id = 'tos-fix-2026-r1' AND l.stage = 'catch_up' AND l.status = 'proposed';
  IF n <> 61 OR c IS DISTINCT FROM '1471d90964c37d521b2a054d307aee73' THEN
    RAISE EXCEPTION 'VERIFY S2 rollback: % current catch_up rows, checksum %; expected 61, 1471d90964c37d521b2a054d307aee73', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r2' AND superseded_at IS NULL) THEN
    RAISE EXCEPTION 'VERIFY S2 rollback: a row of the run is still current'; END IF;
  SELECT count(*) INTO n FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.kind IN ('relabel', 'relabel_card', 'change', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.old_minutes, r.old_arrival, r.old_departure, r.old_source);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2 rollback: % written visits do not hold their old value (see the NOTICE)', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND ((a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'))
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2 rollback: % audit rows outside visits and the ledger, or unlabelled', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S2 rollback: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  RAISE NOTICE 'S2 rollback: % rows rolled back, 61 10-18 rows current again, checks %', (SELECT count(*) FROM _rb), ck - 'T_detail';
END $v$;

COMMIT;
