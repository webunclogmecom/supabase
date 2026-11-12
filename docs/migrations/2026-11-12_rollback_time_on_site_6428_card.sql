-- ============================================================================
-- 2026-11-12_rollback_time_on_site_6428_card  Undo 2026-11-12_1200_time_on_site_6428_card.sql (Fred's card on visit 6428)
-- ============================================================================
-- WHAT IT DOES
--   1. Visit 6428 gets its old_* back (30 min, samsara_stay, 00:37:45 to 01:08:02 ET 11-06) ONLY while it still holds the
--      card row's new_*; if it moved since, the file raises and changes nothing (re-measure it instead).
--   2. The card row gets superseded_at, status 'rolled_back' and rolled_back_at (never deleted). The visit had no ledger row
--      before the card, so no earlier row is made current again: the nightly measures 6428 again from its next run, and
--      holds it as big_change as before.
-- PIN: fn_time_on_site_checks is the S1 body; run tos-card-20261112-6428 has exactly one row and it is current.
-- VERIFY: no current row of the run; 6428 holds old_*; only visits and the ledger audited, labelled; T7 = T8 = 0; 6428 is
--   not locked.
-- LABEL: x-app-source time-on-site-recheck-2026.
-- REHEARSED: on top of the forward file, in one rolled-back transaction (card_6428/rehearse.mjs, local); alone it refuses.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) NOT IN ('11e4b8113c609737ea8edd5798faa833', '03d6d444ec2f782418ab28c575e149b7') THEN   -- the S1 body, or the same with T12 (2026-11-12_1430)
    RAISE EXCEPTION '6428 card rollback: fn_time_on_site_checks() is not the S1 body'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-card-20261112-6428' AND visit_id = 6428 AND superseded_at IS NULL) <> 1
     OR (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-card-20261112-6428') <> 1 THEN
    RAISE EXCEPTION '6428 card rollback: run tos-card-20261112-6428 does not have its one current row'; END IF;
END $pin$;

CREATE TEMP TABLE _rb ON COMMIT DROP AS
SELECT l.id, l.visit_id, l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.new_minutes, l.new_arrival, l.new_departure, l.new_source
  FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-card-20261112-6428' AND l.superseded_at IS NULL;
CREATE TEMP TABLE _rb_ctx ON COMMIT DROP AS SELECT (SELECT max(id) FROM audit.logs) AS audit_id0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id = 6428 FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id = 6428 FOR UPDATE;
  IF EXISTS (SELECT 1 FROM _rb r JOIN public.visits v ON v.id = r.visit_id
              WHERE (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_minutes, r.new_arrival, r.new_departure, r.new_source)) THEN
    RAISE EXCEPTION '6428 card rollback: 6428 no longer holds the card value, nothing changed (re-measure it instead)'; END IF;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Rollback of Fred''s card on visit 6428 (run tos-card-20261112-6428): the visit gets its previous 30 min back and the row is rolled back.'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = r.old_minutes, actual_arrival_at = r.old_arrival, actual_departure_at = r.old_departure, time_on_site_source = r.old_source
    FROM _rb r WHERE v.id = r.visit_id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION '6428 card rollback: restored % visits, expected 1', n; END IF;
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now(), status = 'rolled_back', rolled_back_at = now()
    FROM _rb r WHERE l.id = r.id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION '6428 card rollback: rolled back % rows, expected 1', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _rb_ctx);
BEGIN
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-card-20261112-6428' AND superseded_at IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 6428 card rollback: the row of the run is still current'; END IF;
  IF EXISTS (SELECT 1 FROM _rb r JOIN public.visits v ON v.id = r.visit_id
              WHERE (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.old_minutes, r.old_arrival, r.old_departure, r.old_source)) THEN
    RAISE EXCEPTION 'VERIFY 6428 card rollback: 6428 does not hold its old value'; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND ((a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'))
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY 6428 card rollback: % audit rows outside visits and the ledger, or unlabelled', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY 6428 card rollback: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  IF public.fn_time_on_site_is_locked(6428) THEN RAISE EXCEPTION 'VERIFY 6428 card rollback: 6428 is still locked'; END IF;
  RAISE NOTICE '6428 card rollback: 6428 back to 30 min, the row rolled back, checks %', ck - 'T_detail';
END $v$;

COMMIT;
