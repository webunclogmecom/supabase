-- ============================================================================
-- 2026-11-12_rollback_time_on_site_s6_band_c  Undo stage S6 of the visit duration re-check (Trello vpF5PLQj)
-- ============================================================================
-- WHAT S6 DID (no forward migration: it is 13 real runs of the deployed edge function time-on-site-samsara-recheck,
--   rules 2, one per visit date from 2026-10-18 to 2026-10-30, so each date gets its close-out; Fred, 2026-11-12:
--   "run the night-3 check now and S6 today"). The runs wrote 2 visit times through fn_save_time_on_site_stay
--   (6243 57 to 50 minutes, Fred's card of 2026-11-09 "50, go with your recommendation"; 8868 blank to 23) and one
--   ledger row per completed client visit of those dates through fn_close_time_on_site (run ids nightly-20261018 to
--   nightly-20261030, stage 'nightly', 81 rows).
-- WHAT THIS FILE DOES
--   1. A visit whose S6 row has action 'change' gets its old_* back ONLY while it still holds that row's new_*; a visit
--      that moved since is listed in the NOTICE and left alone (re-measure it instead).
--   2. Every current row of those 13 runs gets superseded_at and status 'rolled_back' (never deleted). No earlier row
--      exists for these visits (S6 found none), so nothing is made current again.
-- PIN: fn_time_on_site_checks is the S1 body; the 13 runs hold exactly 81 current rows, all stage 'nightly'; the only
--   superseded rows allowed are 2150 / 2188 (8853 / 8886) and the shared tap rows that replaced them
--   (2026-11-12_1140_time_on_site_s6_shared_tap_rows.sql). It may run with or without that file applied, and after its
--   rollback too: it rolls back whatever 81 rows are current.
-- VERIFY: no current row of the 13 runs; the restored visits hold old_*; only visits and the ledger audited, labelled;
--   T7 = T8 = 0.
-- LABEL: x-app-source time-on-site-recheck-2026.
-- REHEARSED: alone before the runs (refuses: the runs had no rows), and on top of the runs in one rolled-back
--   transaction (S6/rehearse_rollback.mjs, local). Again 2026-11-12 ~11:28 ET after the runs (S6/rehearse_shared_tap.mjs):
--   alone, on top of the shared tap correction, and after that correction's rollback, each ending with 0 current rows,
--   6243 at 57 (gps_150m_cluster) and 8868 blank; T4 then reads 1 (8868 blank again), T7 = T8 = 0. A superseded row it
--   does not name refuses.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S6 rollback: fn_time_on_site_checks() is not the S1 body'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections
       WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND stage = 'nightly' AND superseded_at IS NULL) <> 81
     OR EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections
                 WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030'
                   AND (stage <> 'nightly' OR (superseded_at IS NOT NULL
                        -- the only superseded rows allowed: 2150 / 2188 and the shared tap rows that replaced them
                        -- (2026-11-12_1140_time_on_site_s6_shared_tap_rows.sql, and its rollback)
                        AND id NOT IN (2150, 2188) AND coalesce(evidence->>'corrects_row', '') NOT IN ('2150', '2188')))) THEN
    RAISE EXCEPTION 'S6 rollback: the runs nightly-20261018 to nightly-20261030 do not hold exactly 81 current nightly rows'; END IF;
END $pin$;

CREATE TEMP TABLE _rb ON COMMIT DROP AS
SELECT l.id, l.visit_id, l.action, l.old_minutes, l.old_arrival, l.old_departure, l.old_source,
       l.new_minutes, l.new_arrival, l.new_departure, l.new_source
  FROM public.visit_time_on_site_corrections l
 WHERE l.run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND l.stage = 'nightly' AND l.superseded_at IS NULL;
CREATE TEMP TABLE _rb_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; moved jsonb;
BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _rb) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.id IN (SELECT id FROM _rb) FOR UPDATE;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Rollback of visit duration re-check stage S6 (runs nightly-20261018 to nightly-20261030): the written visits get their previous values back, the 81 close-out rows are rolled back.'))::text, true);
  SELECT jsonb_agg(r.visit_id) INTO moved FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.action = 'change'
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  IF moved IS NOT NULL THEN RAISE NOTICE 'S6 rollback: these visits moved since S6 and are NOT restored: %', moved; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.old_minutes, actual_arrival_at = r.old_arrival, actual_departure_at = r.old_departure, time_on_site_source = r.old_source
    FROM _rb r WHERE v.id = r.visit_id AND r.action = 'change'
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS NOT DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now(), status = 'rolled_back', rolled_back_at = now()
    FROM _rb r WHERE l.id = r.id;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _rb) THEN RAISE EXCEPTION 'S6 rollback: rolled back % rows, expected %', n, (SELECT count(*) FROM _rb); END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _rb_ctx);
BEGIN
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections
              WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND superseded_at IS NULL) THEN
    RAISE EXCEPTION 'VERIFY S6 rollback: a row of the runs is still current'; END IF;
  SELECT count(*) INTO n FROM _rb r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.action = 'change'
     AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.old_minutes, r.old_arrival, r.old_departure, r.old_source);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S6 rollback: % written visits do not hold their old value (see the NOTICE)', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND ((a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'))
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S6 rollback: % audit rows outside visits and the ledger, or unlabelled', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S6 rollback: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  RAISE NOTICE 'S6 rollback: % rows rolled back, checks %', (SELECT count(*) FROM _rb), ck - 'T_detail';
END $v$;

COMMIT;
