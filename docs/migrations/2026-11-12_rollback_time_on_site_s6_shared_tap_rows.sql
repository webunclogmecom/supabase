-- ============================================================================
-- 2026-11-12_rollback_time_on_site_s6_shared_tap_rows  Undo 2026-11-12_1140_time_on_site_s6_shared_tap_rows.sql
-- ============================================================================
-- WHAT IT DOES: the two proposed shared_tap rows of 8853 and 8886 (the ones that name rows 2150 / 2188 in
--   evidence->'corrects_row') are rolled back (superseded_at, status 'rolled_back', rolled_back_at; never deleted), then
--   rows 2150 and 2188 are current again. No visit is written.
-- ORDER: to undo all of S6, the S6 rollback alone is enough (it rolls back every current row of its runs, these two
--   included). This file is for undoing only the correction; after the S6 rollback it refuses (nothing is current).
-- PIN: the two correction rows are current; rows 2150 and 2188 superseded; 81 current rows of the 13 S6 runs.
-- VERIFY: 2150 and 2188 current again, applied, unchanged otherwise; the correction rows rolled back; 81 current rows;
--   only the ledger audited, labelled; T7 = T8 = 0.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections
       WHERE visit_id IN (8853, 8886) AND superseded_at IS NULL AND method = 'shared_tap' AND status = 'proposed'
         AND (evidence->>'corrects_row')::bigint IN (2150, 2188)) <> 2 THEN
    RAISE EXCEPTION 'S6 shared tap rollback: the two correction rows are not current'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE id IN (2150, 2188) AND superseded_at IS NOT NULL) <> 2 THEN
    RAISE EXCEPTION 'S6 shared tap rollback: rows 2150 / 2188 are not superseded'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND superseded_at IS NULL) <> 81 THEN
    RAISE EXCEPTION 'S6 shared tap rollback: the S6 runs do not hold 81 current rows (run this before the S6 rollback)'; END IF;
END $pin$;

CREATE TEMP TABLE _rbst_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (8853, 8886) FOR UPDATE;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Rollback of the S6 shared tap correction: rows 2150 and 2188 are current again.'))::text, true);
  UPDATE public.visit_time_on_site_corrections SET superseded_at = now(), status = 'rolled_back', rolled_back_at = now()
   WHERE visit_id IN (8853, 8886) AND superseded_at IS NULL AND method = 'shared_tap' AND (evidence->>'corrects_row')::bigint IN (2150, 2188);
  GET DIAGNOSTICS n = row_count;
  IF n <> 2 THEN RAISE EXCEPTION 'S6 shared tap rollback: rolled back % rows, expected 2', n; END IF;
  UPDATE public.visit_time_on_site_corrections SET superseded_at = NULL WHERE id IN (2150, 2188);
  GET DIAGNOSTICS n = row_count;
  IF n <> 2 THEN RAISE EXCEPTION 'S6 shared tap rollback: restored % rows, expected 2', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _rbst_ctx);
BEGIN
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE id IN (2150, 2188) AND superseded_at IS NULL AND status = 'applied' AND method = 'nightly_self') <> 2 THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap rollback: 2150 / 2188 not current'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND superseded_at IS NULL) <> 81 THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap rollback: the S6 runs do not hold 81 current rows'; END IF;
  IF EXISTS (SELECT 1 FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
              AND ((a.table_schema, a.table_name) <> ('public', 'visit_time_on_site_corrections') OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026')) THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap rollback: an audit row outside the ledger, or unlabelled'; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S6 shared tap rollback: T7 % T8 %', ck->>'T7', ck->>'T8'; END IF;
  RAISE NOTICE 'S6 shared tap rollback: 2150 and 2188 current again';
END $v$;

COMMIT;
