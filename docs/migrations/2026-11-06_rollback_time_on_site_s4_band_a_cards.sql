-- ============================================================================
-- 2026-11-06_rollback_time_on_site_s4_band_a_cards  Undo 2026-11-06_1121_time_on_site_s4_band_a_cards.sql (re-check stage S4)
-- ============================================================================
-- WHAT IT DOES
--   1. A written visit (7 values, 1 label) gets its old_* back ONLY while it still holds the S4 row's new_*; a visit that
--      moved since is listed in the NOTICE and left alone (re-measure it instead).
--   2. Every current row of run tos-recheck-2026-r4 gets superseded_at and status 'rolled_back' (never deleted).
--   3. Only then are the rows those rows superseded (evidence->'superseded_row_id') made current again: the unique
--      current-row index allows one current row per visit.
--   4. The 6 flags this file closed open again (only a flag whose resolved_at is the S4 row's applied_at).
-- PIN: fn_time_on_site_checks is the S1 body; the run has 33 rows and its current rows still name the rows they superseded.
-- VERIFY: the 33 earlier rows are current again and byte-identical to before S4 (md5 60f22d4918c6c62d9dbd698c44f1ac13); no current row of the
--   run; the restored visits hold old_*; the 6 flags open; only visits, the ledger and the flags audited, labelled;
--   T7 = T8 = 0.
-- LABEL: x-app-source time-on-site-recheck-2026.
-- REHEARSED: on top of the forward file, in one rolled-back transaction (S4/rehearse.mjs r, local); alone it refuses.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) NOT IN ('11e4b8113c609737ea8edd5798faa833', '03d6d444ec2f782418ab28c575e149b7') THEN   -- the S1 body, or the same with T12 (2026-11-12_1430)
    RAISE EXCEPTION 'S4 rollback: fn_time_on_site_checks() is not the S1 body'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r4') <> 33 THEN
    RAISE EXCEPTION 'S4 rollback: run tos-recheck-2026-r4 does not have 33 rows'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-recheck-2026-r4' AND l.superseded_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections o
                               WHERE o.id = (l.evidence->>'superseded_row_id')::bigint AND o.visit_id = l.visit_id AND o.superseded_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'S4 rollback: a current S4 row does not name the row it superseded'; END IF;
END $pin$;

CREATE TEMP TABLE _rb ON COMMIT DROP AS
SELECT l.id, l.visit_id, (l.evidence->>'superseded_row_id')::bigint AS old_lid, l.evidence->>'s4_kind' AS kind, l.applied_at,
       l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.new_minutes, l.new_arrival, l.new_departure, l.new_source
  FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-recheck-2026-r4' AND l.superseded_at IS NULL;
CREATE TEMP TABLE _rb_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; moved jsonb;
BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _rb) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (SELECT visit_id FROM _rb) FOR UPDATE;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Rollback of visit duration re-check stage S4 (run tos-recheck-2026-r4): the earlier rows are current again, the 8 written visits get their previous values back, the 6 flags open.'))::text, true);
  SELECT jsonb_agg(r.visit_id) INTO moved FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.kind IN ('relabel_card', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  IF moved IS NOT NULL THEN RAISE NOTICE 'S4 rollback: these visits moved since S4 and are NOT restored: %', moved; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.old_minutes, actual_arrival_at = r.old_arrival, actual_departure_at = r.old_departure, time_on_site_source = r.old_source
    FROM _rb r WHERE v.id = r.visit_id AND r.kind IN ('relabel_card', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS NOT DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now(), status = 'rolled_back', rolled_back_at = now()
    FROM _rb r WHERE l.id = r.id;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _rb) THEN RAISE EXCEPTION 'S4 rollback: rolled back % rows, expected %', n, (SELECT count(*) FROM _rb); END IF;
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = NULL
    FROM _rb r WHERE l.id = r.old_lid AND l.superseded_at IS NOT NULL;
  UPDATE public.visit_audit_flags f SET resolved_at = NULL, resolved_note = NULL
    FROM _rb r WHERE f.visit_id = r.visit_id AND r.kind = 'flag_card' AND f.resolved_at = r.applied_at AND f.resolved_note = 'Reviewed 2026-11-05, kept as is, no truck change';
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; c text; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _rb_ctx);
BEGIN
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.visit_id = ANY (ARRAY[1262,1311,1314,1327,1352,1418,1419,1462,1784,1793,3890,3903,3920,3927,5100,5133,5732,5734,5802,5814,5918,6270,6399,6563,6645,7054,7299,7319,7745,7828,7843,8139,8780]::bigint[]);
  IF n <> 33 OR c IS DISTINCT FROM '60f22d4918c6c62d9dbd698c44f1ac13' THEN
    RAISE EXCEPTION 'VERIFY S4 rollback: % current rows, checksum %; expected 33, 60f22d4918c6c62d9dbd698c44f1ac13', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r4' AND superseded_at IS NULL) THEN
    RAISE EXCEPTION 'VERIFY S4 rollback: a row of the run is still current'; END IF;
  SELECT count(*) INTO n FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.kind IN ('relabel_card', 'change_card')
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.old_minutes, r.old_arrival, r.old_departure, r.old_source);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4 rollback: % written visits do not hold their old value (see the NOTICE)', n; END IF;
  SELECT count(*) INTO n FROM _rb r WHERE r.kind = 'flag_card'
     AND NOT EXISTS (SELECT 1 FROM public.visit_audit_flags f WHERE f.visit_id = r.visit_id AND f.resolved_at IS NULL);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4 rollback: % flags did not open', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND ((a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'), ('public', 'visit_audit_flags'))
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4 rollback: % audit rows outside visits, the ledger and the flags, or unlabelled', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S4 rollback: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  RAISE NOTICE 'S4 rollback: % rows rolled back, the earlier rows current again, checks %', (SELECT count(*) FROM _rb), ck - 'T_detail';
END $v$;

COMMIT;
