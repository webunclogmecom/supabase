-- ============================================================================
-- 2026-11-12_1140_time_on_site_s6_shared_tap_rows  S6 close-out: two rows the classifier should have held for a person
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj, stage S6 (Fred 2026-11-12: "run the night-3 check now and S6 today"). The S6 runs (11:22 ET, 13 real
--   rules-2 runs, one per date 10-18 to 10-30) wrote 81 close-out rows. 79 equal the prediction register; 2 do not.
-- WHAT WENT WRONG
--   The close-out gives "applied, keep_verified, nightly_self" to a kept visit only when no OTHER completed visit of the same
--   truck has its completion (its "tap") inside the stay; otherwise "proposed, shared_tap", for a person (plan 5.5 b). The
--   edge function looks for those taps only among the visits its read returns, and fn_time_on_site_recheck_visits returns
--   visits DATED p_from - 1 to p_to + 1. Two taps came from visits completed three days after their own date:
--     8853 (10-19, truck 2, stay 09:44:02 to 10:41:19 ET): 8854, dated 10-16, completed 10-19 09:59:40 ET inside it.
--     8886 (10-26, truck 2, stay 11:44:28 to 12:30:48 ET): 8882, dated 10-23, completed 10-26 12:25:22 ET inside it.
--   Neither was in the read, so both rows came out applied/nightly_self. The register (S6/predict.mjs) asks the table for
--   any completed visit of the truck, any date, which is why it said shared_tap.
-- WHAT IS WRITTEN
--   Rows 2150 (8853) and 2188 (8886) are superseded, never edited. Each gets a new current row, a copy with status proposed,
--   method shared_tap, confidence person, no applied_at, and evidence naming the other visit and the row it corrects. Same
--   run ids (nightly-20261019, nightly-20261026) and stage nightly, so S6 keeps its 81 current rows and its rollback
--   (2026-11-12_rollback_time_on_site_s6_band_c.sql) still applies.
--   No visit is written: both keep their times (57 and 46 min) and stay locked (a proposed row is a lock too).
-- REACH (measured 11:30 ET): every current applied nightly_self row in the ledger whose stay holds another completed tap of
--   the same truck: exactly these 2. No row of the switched-on nightly (11-10 on) has it. The nightly can meet it again:
--   a visit completed two or more days after its date, inside a stay on the close-out day. The fix to the read is NOT in
--   this file (it changes the nightly; plan it separately).
-- PIN: fn_time_on_site_checks is the S1 body; rows 2150 and 2188 current, applied, nightly_self, on their visits and runs;
--   8854's and 8882's completion still inside those stays; 81 current rows of the 13 S6 runs.
-- VERIFY: 81 current rows of the 13 runs; the two new rows current, proposed, shared_tap, naming the other visit; the two
--   old rows superseded; the two visits' rows byte-identical and still locked; audit rows only on the ledger (2 updates, 2
--   inserts), labelled; T7 = T8 = 0.
-- LABEL: x-app-source time-on-site-recheck-2026.
-- ROLLBACK: docs/migrations/2026-11-12_rollback_time_on_site_s6_shared_tap_rows.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S6 shared tap: fn_time_on_site_checks() is not the S1 body'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections l
       WHERE (l.id, l.visit_id, l.run_id) IN ((2150, 8853, 'nightly-20261019'), (2188, 8886, 'nightly-20261026'))
         AND l.superseded_at IS NULL AND l.status = 'applied' AND l.action = 'keep_verified' AND l.method = 'nightly_self' AND l.stage = 'nightly') <> 2 THEN
    RAISE EXCEPTION 'S6 shared tap: rows 2150 / 2188 are not the current applied nightly_self rows of 8853 / 8886'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections l JOIN public.visits o ON o.id = CASE l.visit_id WHEN 8853 THEN 8854 WHEN 8886 THEN 8882 END
       WHERE l.id IN (2150, 2188) AND o.vehicle_id = l.new_vehicle_id AND o.visit_status = 'completed' AND o.deleted_at IS NULL
         AND o.completed_at BETWEEN l.new_arrival AND l.new_departure) <> 2 THEN
    RAISE EXCEPTION 'S6 shared tap: 8854 / 8882 no longer complete inside those stays'; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND superseded_at IS NULL) <> 81 THEN
    RAISE EXCEPTION 'S6 shared tap: the S6 runs do not hold 81 current rows'; END IF;
END $pin$;

CREATE TEMP TABLE _st ON COMMIT DROP AS
SELECT * FROM (VALUES (2150::bigint, 8853::bigint, 8854::bigint), (2188::bigint, 8886::bigint, 8882::bigint)) t(old_id, visit_id, other_visit);
CREATE TEMP TABLE _st_ctx ON COMMIT DROP AS
SELECT (SELECT max(id) FROM audit.logs) AS audit_id0,
       (SELECT jsonb_object_agg(v.id, md5(to_jsonb(v)::text)) FROM public.visits v WHERE v.id IN (8853, 8886)) AS visits0;

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (8853, 8886) FOR UPDATE;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'S6 close-out correction: 8853 and 8886 hold another visit''s completion (8854, 8882, each completed three days after its own date) inside their stay, so their rows are proposed shared_tap for a person, not applied. Times unchanged.'))::text, true);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now() FROM _st s WHERE l.id = s.old_id AND l.superseded_at IS NULL;
  GET DIAGNOSTICS n = row_count;
  IF n <> 2 THEN RAISE EXCEPTION 'S6 shared tap: superseded % rows, expected 2', n; END IF;
  INSERT INTO public.visit_time_on_site_corrections
    (visit_id, run_id, param_version, input_hashes, old_vehicle_id, new_vehicle_id, truck_stage, truck_status, truck_applied_at, stage, action, status,
     old_arrival, old_departure, old_minutes, old_source, old_visit_date, old_completed_at, bonus_decided_at_seen,
     new_arrival, new_departure, new_minutes, new_source, method, confidence, error_classes, decision_ref, shared_group_id, group_size,
     group_total_minutes, activity_minutes, alternatives, evidence, evidence_file_sha256)
  SELECT l.visit_id, l.run_id, l.param_version, l.input_hashes, l.old_vehicle_id, l.new_vehicle_id, l.truck_stage, l.truck_status, l.truck_applied_at, l.stage, l.action, 'proposed',
         l.old_arrival, l.old_departure, l.old_minutes, l.old_source, l.old_visit_date, l.old_completed_at, l.bonus_decided_at_seen,
         l.new_arrival, l.new_departure, l.new_minutes, l.new_source, 'shared_tap', 'person', l.error_classes, l.decision_ref, l.shared_group_id, l.group_size,
         l.group_total_minutes, l.activity_minutes, l.alternatives,
         l.evidence || jsonb_build_object('other_visit', s.other_visit, 'corrects_row', l.id,
           'correction', 'the other visit is dated outside the read (completed 3 days after its date); 2026-11-12_1140_time_on_site_s6_shared_tap_rows.sql'),
         l.evidence_file_sha256
    FROM public.visit_time_on_site_corrections l JOIN _st s ON s.old_id = l.id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 2 THEN RAISE EXCEPTION 'S6 shared tap: inserted % rows, expected 2', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; ck jsonb; a0 bigint := (SELECT audit_id0 FROM _st_ctx);
BEGIN
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id BETWEEN 'nightly-20261018' AND 'nightly-20261030' AND superseded_at IS NULL) <> 81 THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap: the S6 runs do not hold 81 current rows'; END IF;
  SELECT count(*) INTO n FROM _st s JOIN public.visit_time_on_site_corrections l ON l.visit_id = s.visit_id AND l.superseded_at IS NULL
   WHERE l.status = 'proposed' AND l.action = 'keep_verified' AND l.method = 'shared_tap' AND l.confidence = 'person' AND l.applied_at IS NULL
     AND (l.evidence->>'other_visit')::bigint = s.other_visit AND (l.evidence->>'corrects_row')::bigint = s.old_id;
  IF n <> 2 THEN RAISE EXCEPTION 'VERIFY S6 shared tap: % new rows as expected, expected 2', n; END IF;
  IF (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE id IN (2150, 2188) AND superseded_at IS NOT NULL AND status = 'applied') <> 2 THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap: the old rows are not superseded (and otherwise untouched)'; END IF;
  IF (SELECT jsonb_object_agg(v.id, md5(to_jsonb(v)::text)) FROM public.visits v WHERE v.id IN (8853, 8886)) IS DISTINCT FROM (SELECT visits0 FROM _st_ctx) THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap: a visit row changed'; END IF;
  IF NOT (public.fn_time_on_site_is_locked(8853) AND public.fn_time_on_site_is_locked(8886)) THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap: 8853 / 8886 not locked'; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current();
  IF n <> 4 OR EXISTS (SELECT 1 FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
                        AND ((a.table_schema, a.table_name) <> ('public', 'visit_time_on_site_corrections') OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026')) THEN
    RAISE EXCEPTION 'VERIFY S6 shared tap: % audit rows, expected 4 labelled ledger rows', n; END IF;
  ck := public.fn_time_on_site_checks();
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S6 shared tap: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  RAISE NOTICE 'S6 shared tap: 8853 and 8886 now proposed shared_tap (8854, 8882), checks %', ck - 'T_detail';
END $v$;

COMMIT;
