-- ============================================================================
-- 2026-11-12_1200_time_on_site_6428_card  Visit duration re-check: Fred's card on visit 6428 (30 -> 57 min)
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-12, after the independent test of the nightly rule: "yes change 6428 to 57". The test
--   folder is local (it names clients): samsara-checks/duration_recheck_run_2026-10-28/S6/refresh_2026-11-12b_test_1102_1110/.
--   Visit ids, minutes and times only here.
-- WHY
--   Visit 6428 (dated 11-05, truck 1) holds 30 min (samsara_stay, 00:37:45 to 01:08:02 ET 11-06), written by the old rule on
--   11-06 02:50 ET. Both independent judges (T, trips; V2, the 1-second track) give 57 min with the same ends, and the nightly
--   rule computes the same 57 itself (basis tap, 2 parts: the truck parked, moved, and parked again at the site). The nightly
--   HOLDS it as big_change every night, by design: a big move on a visit whose bonus is already decided (approved
--   2026-11-09 10:01 ET) waits for a person (plan Q-F). Fred is that person and picked the measured value.
-- WHAT IS WRITTEN (one ledger row, run tos-card-20261112-6428, stage person, status applied, action change)
--   6428  30 -> 57 min  samsara_stay -> samsara_stay  00:10:46 to 01:08:02 ET 11-06 (2026-11-06 05:10:46.51Z to 06:08:02.537Z)
--   The label stays samsara_stay: the value is the nightly rule's own measure of Samsara's stay, the same way S6 writes
--   6243's card answer (Fred 2026-11-09: "50, go with your recommendation"). The applied row is the lock: every writer and
--   the nightly skip a visit with a current applied row (decision 'locked', no close-out row on 11-15, no refusal).
--   The approved bonus is not re-priced: a visit bonus is a set amount per person, not a function of the minutes.
-- THE ROW GUARD
--   The visit must still hold exactly what the read of 2026-11-12 09:12 ET saw: the four time columns, truck 1, visit_date
--   11-05, completed_at 2026-11-06 06:05:59Z, completed and not deleted, the bonus decided at 2026-11-09 15:01:29.169Z, no
--   current ledger row and not locked. Anything else raises (one visit: there is nothing to skip to).
-- PIN: fn_time_on_site_checks (S1 body), fn_time_on_site_is_locked, audit.log_change, fn_push_visit_to_jobber,
--   fn_mark_visit_sync_pending, fn_clear_time_on_site_on_reopen; no row of run tos-card-20261112-6428 (a second run refuses).
--   Evidence: verdicts_1102_1110.json sha256 e17bc7c35854773bc085b421a66ad592217d4fb717f9259e60049e5b652c4b90.
-- WHAT DOES NOT CHANGE
--   vehicle_id, visit_date, start_at, end_at, visit_status, deleted_at, the schedule: the VERIFY reads every audit row of
--   this transaction and allows only the four time columns (and updated_at) on 6428. Every other visit's time columns and
--   truck: hashed before and after inside the transaction. Nothing goes to Jobber (the push trigger does not list the time
--   columns; asserted on net.http_request_queue). trg_zz_queue_start_recheck does not fire (it lists no time column).
-- CONSEQUENCES (measured 2026-11-12 09:20 ET in the rolled-back rehearsal, local card_6428/rehearse.mjs a)
--   Calendar Hours worked (ops.calendar_hours_estimates): past days, 6428 only, 30 -> 57; the next 45 days, nothing moves.
--   v_visit_tank_service: 6428 duration 30 -> 57 and time_on_site_disagreement true -> false; every other column of every
--     row unchanged (hash). F7 (v_tank_data_quality_issues) 121 -> 120 (6428 leaves it). ops.visit_grease_frozen unchanged.
--   Shared time: none before, none after. Every other visit's times and truck: hash equal. T1 to T8: 0 before and after.
-- REHEARSED (card_6428/rehearse.mjs, every run rolled back)
--   (a) as written: pass, row 1 applied and current, 6428 locked. (g) 6428's minutes moved first: refuses (time_moved).
--   (d) a second run: refuses (run already has rows). (r) the rollback on top: 6428 byte-equal to before, the row
--   rolled_back, not locked, every other visit equal. (ra) the rollback alone: refuses.
-- APPLY: AFTER the S6 runs of 2026-11-12 have finished and been compared (S6 snapshots every visit time before and after
--   its runs; this write between them would fail its comparison). 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20,
--   :30 to :45 (PLAN G-9). lock_timeout 3s.
-- LABEL: x-app-source time-on-site-recheck-2026, one reason for the transaction.
-- VERIFY: the one row, current and applied; the visit and the row hold the new value, the row holds the old one, its truck,
--   date and completion; the shape; only 6428 written, only the time columns, labelled; one ledger audit row, no other
--   table; every other visit's times unchanged; no Jobber push; no new shared time; T1 to T8 not newly failing, T7 = T8 = 0;
--   6428 locked.
-- ROLLBACK: docs/migrations/2026-11-12_rollback_time_on_site_6428_card.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN
DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION '6428 card: % is not the S1 body', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_is_locked(bigint)'::regprocedure)) <> '69f6f29bc74439f009524796f060c8d0' THEN
    RAISE EXCEPTION '6428 card: % moved', 'fn_time_on_site_is_locked(bigint)'; END IF;
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'ce7784f65675e10a0c2a13f853ce0acc' THEN
    RAISE EXCEPTION '6428 card: % moved', 'audit.log_change()'; END IF;
  IF md5(pg_get_functiondef('public.fn_push_visit_to_jobber()'::regprocedure)) <> 'a6512e3f1b2cb2de0fddd39bb3679fbe' THEN
    RAISE EXCEPTION '6428 card: % moved', 'fn_push_visit_to_jobber()'; END IF;
  IF md5(pg_get_functiondef('public.fn_mark_visit_sync_pending()'::regprocedure)) <> 'f607c3772a444f8fe275380e44651fb4' THEN
    RAISE EXCEPTION '6428 card: % moved', 'fn_mark_visit_sync_pending()'; END IF;
  IF md5(pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure)) <> 'c38d5a5ed8c5b9f1bfa99c3bf2321638' THEN
    RAISE EXCEPTION '6428 card: % moved', 'fn_clear_time_on_site_on_reopen()'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-card-20261112-6428') THEN
    RAISE EXCEPTION '6428 card: run tos-card-20261112-6428 already has rows'; END IF;
END $pin$;

-- 1. The row: what the visit holds now (guard) and the new value.
CREATE TEMP TABLE _c ON COMMIT DROP AS
SELECT 6428::bigint AS visit_id,
       30 AS cur_min, timestamptz '2026-11-06T05:37:45.513+00:00' AS cur_arr, timestamptz '2026-11-06T06:08:02.537+00:00' AS cur_dep,
       'samsara_stay'::text AS cur_src, 1::bigint AS cur_veh, date '2026-11-05' AS cur_date,
       timestamptz '2026-11-06T06:05:59+00:00' AS cur_comp, timestamptz '2026-11-09T15:01:29.169+00:00' AS cur_bonus,
       57 AS new_min, timestamptz '2026-11-06T05:10:46.51+00:00' AS new_arr, timestamptz '2026-11-06T06:08:02.537+00:00' AS new_dep,
       'samsara_stay'::text AS new_src;

CREATE TEMP TABLE _c_ctx ON COMMIT DROP AS
SELECT (SELECT max(id) FROM audit.logs) AS audit_id0,
       (SELECT coalesce(max(id), 0) FROM net.http_request_queue) AS net_id0,
       public.fn_time_on_site_checks() AS checks0,
       (SELECT md5(string_agg(concat_ws('|', v.id, v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id), E'\n' ORDER BY v.id))
          FROM public.visits v WHERE v.id <> 6428) AS others0,
       (SELECT s.shared_with FROM public.v_visit_shared_time s WHERE s.visit_id = 6428) AS shared0;

-- 2. Lock, then the guard: anything moved since the read raises.
DO $lock$ DECLARE why text; BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id = 6428 FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id = 6428 FOR UPDATE;
  SELECT CASE
      WHEN v.id IS NULL THEN 'missing'
      WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
      WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
      WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
      WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (r.cur_date, r.cur_comp) THEN 'date_or_completion_moved'
      WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM r.cur_bonus THEN 'bonus_moved'
      WHEN EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) THEN 'ledger_row_exists'
      WHEN public.fn_time_on_site_is_locked(r.visit_id) THEN 'locked'
    END INTO why
    FROM _c r LEFT JOIN public.visits v ON v.id = r.visit_id;
  IF why IS NOT NULL THEN RAISE EXCEPTION '6428 card: the visit moved since it was read (%), nothing written: re-read and re-rehearse', why; END IF;
END $lock$;

-- 3. Ledger row, then the visit, in the same transaction, labelled.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Visit duration re-check, Fred''s card on visit 6428 (2026-11-12: "yes change 6428 to 57"), run tos-card-20261112-6428: the nightly rule''s and both judges'' 57 min over the saved 30; the nightly held it as big_change (decided bonus). Not pushed to Jobber.'))::text, true);
  INSERT INTO public.visit_time_on_site_corrections
    (visit_id, run_id, param_version, input_hashes, old_vehicle_id, new_vehicle_id, stage, action, status,
     old_arrival, old_departure, old_minutes, old_source, old_visit_date, old_completed_at, bonus_decided_at_seen,
     new_arrival, new_departure, new_minutes, new_source, method, confidence, decision_ref, evidence, evidence_file_sha256,
     applied_at, applied_by_migration)
  SELECT r.visit_id, 'tos-card-20261112-6428', 'nightly-v15-rules2',
         jsonb_build_object('verdicts_1102_1110_json_sha256', 'e17bc7c35854773bc085b421a66ad592217d4fb717f9259e60049e5b652c4b90'),
         r.cur_veh, r.cur_veh, 'person', 'change', 'applied',
         r.cur_arr, r.cur_dep, r.cur_min, r.cur_src, r.cur_date, r.cur_comp, r.cur_bonus,
         r.new_arr, r.new_dep, r.new_min, r.new_src, 'two_judges:rule', 'person', 'fred:2026-11-12:card_6428',
         jsonb_build_object('kind', 'change_card', 'card', true, 'nightly_hold', 'big_change', 'bonus', 'approved 2026-11-09, not re-priced',
           'rule', jsonb_build_object('minutes', 57, 'basis', 'tap', 'parts', 2, 'arrival', '2026-11-06T05:10:46.510Z', 'departure', '2026-11-06T06:08:02.537Z'),
           'judges', jsonb_build_object('T', 57, 'V2', 57, 'ends_within_2_min', true)),
         'e17bc7c35854773bc085b421a66ad592217d4fb717f9259e60049e5b652c4b90',
         now(), '2026-11-12_1200_time_on_site_6428_card.sql'
    FROM _c r;
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION '6428 card: inserted % ledger rows, expected 1', n; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep, time_on_site_source = r.new_src
    FROM _c r WHERE v.id = r.visit_id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION '6428 card: wrote % visits, expected 1', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint := (SELECT audit_id0 FROM _c_ctx); ck jsonb; ck0 jsonb := (SELECT checks0 FROM _c_ctx); t text;
BEGIN
  -- (a) the one row: current, applied, stage person
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections
   WHERE run_id = 'tos-card-20261112-6428' AND visit_id = 6428 AND superseded_at IS NULL AND status = 'applied' AND stage = 'person'
     AND applied_by_migration = '2026-11-12_1200_time_on_site_6428_card.sql' AND applied_at IS NOT NULL;
  IF n <> 1 OR (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-card-20261112-6428') <> 1 THEN
    RAISE EXCEPTION 'VERIFY 6428 card: the run does not hold exactly one current applied row'; END IF;
  -- (b) the visit and the row hold the new value; the row holds the old value, the truck, date and completion
  SELECT count(*) INTO n FROM _c r JOIN public.visits v ON v.id = r.visit_id
    JOIN public.visit_time_on_site_corrections l ON l.visit_id = r.visit_id AND l.superseded_at IS NULL
   WHERE (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh)
      OR (v.vehicle_id, v.visit_date, v.completed_at) IS DISTINCT FROM (l.new_vehicle_id, l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY 6428 card: the visit or its row does not hold the expected values'; END IF;
  -- (c) shape: set, under 720 min, minutes = departure - arrival within 1 min
  IF EXISTS (SELECT 1 FROM public.visits v WHERE v.id = 6428
              AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
                   OR v.actual_departure_at <= v.actual_arrival_at
                   OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1)) THEN
    RAISE EXCEPTION 'VERIFY 6428 card: the written value fails the shape checks'; END IF;
  -- (d) one visit write, only the time columns, labelled; one ledger audit row; nothing else audited
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 6428 card: % audit rows on public.visits, expected 1', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint <> 6428 OR a.operation <> 'UPDATE'
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY 6428 card: the visit write is outside the time columns, or unlabelled'; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public'
     AND a.table_name = 'visit_time_on_site_corrections' AND a.operation = 'INSERT' AND a.app_source = 'time-on-site-recheck-2026';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 6428 card: % labelled ledger inserts audited, expected 1', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY 6428 card: % audit rows on other tables', n; END IF;
  -- (e) every other visit's time columns and truck are unchanged
  IF (SELECT md5(string_agg(concat_ws('|', v.id, v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id), E'\n' ORDER BY v.id))
        FROM public.visits v WHERE v.id <> 6428) IS DISTINCT FROM (SELECT others0 FROM _c_ctx) THEN
    RAISE EXCEPTION 'VERIFY 6428 card: another visit''s time or truck changed'; END IF;
  -- (f) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT net_id0 FROM _c_ctx) AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint = 6428;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY 6428 card: % Jobber requests queued', n; END IF;
  -- (g) no new shared time on the truck
  IF (SELECT s.shared_with FROM public.v_visit_shared_time s WHERE s.visit_id = 6428) IS DISTINCT FROM (SELECT shared0 FROM _c_ctx) THEN
    RAISE EXCEPTION 'VERIFY 6428 card: shared time moved: %', (SELECT s.shared_with FROM public.v_visit_shared_time s WHERE s.visit_id = 6428); END IF;
  -- (h) T1 to T8: none newly failing, T7 and T8 zero
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY 6428 card: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY 6428 card: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  -- (i) the visit is locked now, so no writer and no nightly moves it
  IF NOT public.fn_time_on_site_is_locked(6428) THEN RAISE EXCEPTION 'VERIFY 6428 card: 6428 is not locked'; END IF;
  RAISE NOTICE '6428 card: 30 -> 57 min, one applied row, locked, checks %', ck - 'T_detail';
END $v$;

COMMIT;
