-- ============================================================================
-- 2026-10-18_1631_time_on_site_one_time_fix_q11_stamps One-time 2026 duration fix, Q11: the values the crew's photo stamps settle
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18, on the Q11 photo-stamp proposals: "apply the fairly sure ones (the 6 medium values, the 3 medium
--   blanks, the 4750/5139 split) and turn the 19 cards the photos settle into ready answers; leave the weak ones as
--   cards". The proposals, the stamps and the per-visit evidence are local (samsara-checks/duration_fix_run_2026-10-18/
--   q11, outside the repos because they name clients). Each value below is a measured truck parking (or the ledger's
--   re-park span) that holds every usable stamp; the stamps are bounds, never the duration.
-- WHICH SPLIT (read this before applying)
--   The Q11 REPORT names 4750/5139 as the confident split, but the proposals rate that pair LOW (stamps cluster by time
--   only; 4750's stamps print a street that is not its property's, and its completion tap falls in 5139's part) and
--   rate 4658/4636 MEDIUM (each client's stamps print its own street, 13 min gap, both taps inside their own part).
--   Decision (2026-10-18, coordinator): this file writes the MEDIUM pair, 4658/4636; 4750/5139 stays a card.
-- LEFT OUT ON PURPOSE: 6270 (a bonus was decided on 2026-10-06; the stamps also fit its saved value) and 5819 (Fred's
--   own truck card from the trucks stage). Both stay stage 4 cards ('proposed') waiting for Fred's word.
-- WHAT CHANGES (9 visits, net +174 min; times ET; truck changes are vehicle_id only)
--   visit  kind                 truck            minutes   new interval (ET)
--   1311   stamps, new parking  David -> Cloggy   66 ->  99   01-22 21:37:08 to 23:15:50
--   3927   stamps, new parking  Cloggy -> Moises  36 ->  93   05-07 07:36:01 to 09:08:42
--   6427   stamps, re-park span Moises            50 -> 101   09-06 22:15:53 to 23:56:26
--   6989   stamps, new parking  David -> Cloggy   85 -> 178   07-02 09:40:30 to 12:38:41
--   7850   stamps, new parking  Cloggy             9 ->  17   08-31 16:04:05 to 16:21:25
--   8722   stamps, new parking  Cloggy -> David   40 ->  78   10-02 16:10:15 to 17:28:34
--   1582   card (was "blank")   Moises            58 ->  58   unchanged 04-07 04:49:10 to 05:47:01, locked (samsara_stay -> review)
--   4658   shared stop split    Moises           105 ->  71   05-29 00:35:15 to 01:46:30
--   4636   shared stop split    Moises           105 ->  33   05-29 01:46:31 to 02:19:55 (1 s after 4658: v_visit_shared_time pairs with <=)
--   Every written visit is labelled time_on_site_source 'review' (locked: every writer skips it). Its ledger row in
--   public.visit_time_on_site_corrections takes the new value in the SAME transaction (status applied, method
--   photo_stamp or photo_stamp:split, confidence medium, decision_ref Q11, this file), so T7 and T8 stay 0. A truck
--   change also sets the row's truck part (truck_stage '1', truck_status applied). The row's earlier state and the
--   visit's earlier values are kept in evidence->'q11_before' and 'q11_before_visit' for the rollback.
--   1582 was a stage 4 card whose dry-run proposal was to blank the visit (no own evidence); the photos prove a crew
--   there inside the saved truck parking, so it keeps that value, locked.
-- THE ROW GUARD
--   Every visit must still hold exactly the values, truck, visit_date and completed_at read on 2026-10-18 16:40 ET,
--   be completed and not deleted, with no bonus decided since the ledger saw it; every ledger row must still be the
--   current row in the state read then (PIN). ONE moved row stops the whole file: the set is hand-picked and the split
--   pair must land together. Re-read and re-rehearse instead of forcing.
-- PIN: Stage 0's four bodies (md5); the 9 ledger rows, md5 60e7a11e0b2f0866cdcf4cad1eb3aa83 of the ordered row text
--   without evidence, input_hashes and alternatives. A second run refuses (the rows are no longer in that state).
-- WHAT DOES NOT CHANGE
--   visit_date, start_at, end_at, visit_status, deleted_at, sync_state, the schedule: the VERIFY reads every audit row
--   of this transaction and allows only the four time columns, vehicle_id and updated_at on these 9 visits. Nothing
--   goes to Jobber (no time column and no vehicle_id in trg_push_visit_update's WHEN list; asserted). Every visit is
--   dated before today, so trg_zz_queue_start_recheck queues nothing.
-- CONSEQUENCES: Calendar Hours worked moves on 7 of the 8 days these visits are dated (rehearsal: stages/q11_apply/);
--   the 4 truck-changed visits move to the new truck's lane. After applying, dry-run the linker:
--   select public.fn_link_visit_vehicle_stops(false)->'changes';  (rehearsed: only 8722 relinks, to David's stops)
-- LABEL: x-app-source time-on-site-fix-2026, one reason for the transaction.
-- VERIFY: 9 written and marked; each holds its value, truck, date and completion; shape checks; only these visits,
--   only those columns, labelled; controls byte-identical; no Jobber push; no written visit shares time on its truck
--   (v_visit_shared_time); T1 to T6 not newly failing, T7 = T8 = 0.
-- REHEARSED: forward then rollback in one transaction forced to roll back (local, stages/q11_apply).
-- LOCKS: lock_timeout 3s. Apply between 10:00 and 18:00 ET on a weekday, not :30 to :45 past the hour.
-- ROLLBACK: docs/migrations/2026-10-18_rollback_time_on_site_one_time_fix_q11_stamps.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN
DO $pin$ DECLARE n int; c text; BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'Stage 0 is not applied: the ledger table does not exist'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a1d91a0a28604c25852429d697c1622f' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.run_id = 'tos-fix-2026-r1' AND l.id IN (72, 469, 1149, 740, 1092, 1302, 324, 571, 570);
  IF n <> 9 OR c IS DISTINCT FROM '60e7a11e0b2f0866cdcf4cad1eb3aa83' THEN
    RAISE EXCEPTION 'q11: % ledger rows, checksum %; expected 9, 60e7a11e0b2f0866cdcf4cad1eb3aa83 (already applied, or a row moved since 2026-10-18 16:40 ET: re-read and re-rehearse)', n, c; END IF;
END $pin$;

-- 1. The rows: ledger id, visit, the values the visit holds now (guard), the new values.
CREATE TEMP TABLE _q11_rows ON COMMIT DROP AS
SELECT * FROM (VALUES
  --  lid   visit  kind         cur_min cur_arr                          cur_dep                          cur_src         cur_veh new_veh new_arr                     new_dep                      new_min action        method
  (  72::bigint, 1311::bigint, 'precision',  66, timestamptz '2026-01-23 04:56:15.019+00', timestamptz '2026-01-23 06:02:41.018+00', 'samsara_stay', 3::bigint, 2::bigint, timestamptz '2026-01-22 21:37:08-05', timestamptz '2026-01-22 23:15:50-05',  99, 'change',       'photo_stamp'),
  ( 469,  3927, 'precision',  36, timestamptz '2026-05-07 13:05:31.168+00', timestamptz '2026-05-07 13:41:14.221+00', 'samsara_stay', 2, 1, timestamptz '2026-05-07 07:36:01-04', timestamptz '2026-05-07 09:08:42-04',  93, 'change',       'photo_stamp'),
  (1149,  6427, 'precision',  50, timestamptz '2026-09-07 03:06:50.516+00', timestamptz '2026-09-07 03:56:26.514+00', 'samsara_stay', 1, 1, timestamptz '2026-09-06 22:15:53-04', timestamptz '2026-09-06 23:56:26-04', 101, 'change',       'photo_stamp'),
  ( 740,  6989, 'precision',  85, timestamptz '2026-07-02 14:49:07.468+00', timestamptz '2026-07-02 16:14:20.51+00',  'samsara_stay', 3, 2, timestamptz '2026-07-02 09:40:30-04', timestamptz '2026-07-02 12:38:41-04', 178, 'change',       'photo_stamp'),
  (1092,  7850, 'precision',   9, timestamptz '2026-08-31 19:36:42+00',     timestamptz '2026-08-31 19:46:06+00',     'review',       2, 2, timestamptz '2026-08-31 16:04:05-04', timestamptz '2026-08-31 16:21:25-04',  17, 'change',       'photo_stamp'),
  (1302,  8722, 'precision',  40, timestamptz '2026-10-02 18:23:02.513+00', timestamptz '2026-10-02 19:03:13.512+00', 'samsara_stay', 2, 3, timestamptz '2026-10-02 16:10:15-04', timestamptz '2026-10-02 17:28:34-04',  78, 'change',       'photo_stamp'),
  ( 324,  1582, 'card_blank', 58, timestamptz '2026-04-07 08:49:10.027+00', timestamptz '2026-04-07 09:47:01.047+00', 'samsara_stay', 1, 1, timestamptz '2026-04-07 08:49:10.027+00', timestamptz '2026-04-07 09:47:01.047+00', 58, 'lock_decided', 'photo_stamp'),
  ( 571,  4658, 'split',     105, timestamptz '2026-05-29 04:35:15.314+00', timestamptz '2026-05-29 06:19:55.072+00', 'samsara_stay', 1, 1, timestamptz '2026-05-29 04:35:15.314+00', timestamptz '2026-05-29 01:46:30-04',  71, 'change',       'photo_stamp:split'),
  ( 570,  4636, 'split',     105, timestamptz '2026-05-29 04:35:15.314+00', timestamptz '2026-05-29 06:19:55.072+00', 'samsara_stay', 1, 1, timestamptz '2026-05-29 01:46:31-04', timestamptz '2026-05-29 06:19:55.072+00', 33, 'change',       'photo_stamp:split')
) AS t(lid, visit_id, kind, cur_min, cur_arr, cur_dep, cur_src, cur_veh, new_veh, new_arr, new_dep, new_min, action, method);

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('q11:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('q11:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('q11:checks0', public.fn_time_on_site_checks()),
  ('q11:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

-- 2. Lock, then the guard: any moved row stops the file.
DO $lock$ DECLARE bad jsonb; BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _q11_rows) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.id IN (SELECT lid FROM _q11_rows) FOR UPDATE;
  SELECT jsonb_object_agg(r.visit_id, CASE
           WHEN v.id IS NULL THEN 'missing'
           WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
           WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
           WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
           WHEN l.id IS NULL OR l.visit_id <> r.visit_id OR l.superseded_at IS NOT NULL THEN 'ledger_row_not_current'
           WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at) THEN 'date_or_completion_moved'
           WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen THEN 'bonus_decided'
         END)
    INTO bad
    FROM _q11_rows r LEFT JOIN public.visits v ON v.id = r.visit_id LEFT JOIN public.visit_time_on_site_corrections l ON l.id = r.lid
   WHERE v.id IS NULL OR l.id IS NULL OR v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL
      OR (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src)
      OR v.vehicle_id IS DISTINCT FROM r.cur_veh OR l.visit_id <> r.visit_id OR l.superseded_at IS NOT NULL
      OR (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at)
      OR (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'q11: rows moved since 2026-10-18 16:40 ET, nothing written: %', bad; END IF;
END $lock$;

-- 3. Write the visits, labelled, then their ledger rows, in the same transaction.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-2026',
         'x-change-reason', 'One-time 2026 duration fix, Q11 (the crew''s photo stamps), run tos-fix-2026-r1, Fred''s approval of 2026-10-18: the truck parking that holds every stamp. Method, evidence and decision per visit in public.visit_time_on_site_corrections. Not pushed to Jobber.'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep,
         time_on_site_source = 'review', vehicle_id = r.new_veh
    FROM _q11_rows r WHERE v.id = r.visit_id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 9 THEN RAISE EXCEPTION 'q11: wrote % visits, expected 9', n; END IF;
  UPDATE public.visit_time_on_site_corrections l
     SET evidence = l.evidence || jsonb_build_object(
           'q11_before', jsonb_build_object('status', l.status, 'action', l.action, 'method', l.method, 'confidence', l.confidence,
              'decision_ref', l.decision_ref, 'new_arrival', l.new_arrival, 'new_departure', l.new_departure, 'new_minutes', l.new_minutes,
              'new_source', l.new_source, 'new_vehicle_id', l.new_vehicle_id, 'truck_stage', l.truck_stage, 'truck_status', l.truck_status,
              'truck_applied_at', l.truck_applied_at, 'applied_at', l.applied_at, 'applied_by_migration', l.applied_by_migration),
           'q11_before_visit', jsonb_build_object('duration_minutes', r.cur_min, 'actual_arrival_at', r.cur_arr, 'actual_departure_at', r.cur_dep,
              'time_on_site_source', r.cur_src, 'vehicle_id', r.cur_veh),
           'q11', jsonb_build_object('kind', r.kind, 'decided', 'Fred 2026-10-18: apply the fairly sure ones', 'source', 'q11/proposals.json (local)')),
         status = 'applied', applied_at = now(),
         applied_by_migration = '2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql',
         action = r.action, method = r.method, confidence = 'medium', decision_ref = 'Q11',
         new_arrival = r.new_arr, new_departure = r.new_dep, new_minutes = r.new_min, new_source = 'review', new_vehicle_id = r.new_veh,
         truck_stage = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN '1' ELSE l.truck_stage END,
         truck_status = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN 'applied' ELSE l.truck_status END,
         truck_applied_at = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN now() ELSE l.truck_applied_at END
    FROM _q11_rows r WHERE l.id = r.lid;
  GET DIAGNOSTICS n = row_count;
  IF n <> 9 THEN RAISE EXCEPTION 'q11: marked % ledger rows, expected 9', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint; ck jsonb; ck0 jsonb; t text; sh jsonb;
BEGIN
  -- (b) every row holds its value, truck, date and completion, visit and ledger alike
  SELECT count(*) INTO n FROM _q11_rows r JOIN public.visits v ON v.id = r.visit_id JOIN public.visit_time_on_site_corrections l ON l.id = r.lid
   WHERE l.status <> 'applied' OR l.superseded_at IS NOT NULL
      OR (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, 'review', r.new_veh)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source, l.new_vehicle_id) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, 'review', r.new_veh)
      OR (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY q11: % rows do not hold their new value', n; END IF;
  -- (b2) shape: all set, at most 719 min, departure after arrival, minutes = departure - arrival within 1 min
  SELECT count(*) INTO n FROM _q11_rows r JOIN public.visits v ON v.id = r.visit_id
   WHERE num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
      OR v.actual_departure_at <= v.actual_arrival_at
      OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY q11: % written values fail the shape checks', n; END IF;
  -- (c) only these 9 visits changed, once each, and only in the time columns and vehicle_id
  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'q11:audit_id0');
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> 9 THEN RAISE EXCEPTION 'VERIFY q11: % audit rows on public.visits, expected 9', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _q11_rows)
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY q11: % visit writes outside the set, outside the allowed columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY q11: % audit rows on other tables', n; END IF;
  -- (d) the controls are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'q11:controls') THEN RAISE EXCEPTION 'VERIFY q11: a control visit changed'; END IF;
  -- (e) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'q11:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _q11_rows);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY q11: % Jobber push requests queued', n; END IF;
  -- (g) no written visit shares time with another visit on its truck (the split parts are 1 s apart)
  SELECT jsonb_object_agg(s.visit_id, s.shared_with) INTO sh FROM public.v_visit_shared_time s
   WHERE s.visit_id IN (SELECT visit_id FROM _q11_rows) AND s.shared_with_count > 0;
  IF sh IS NOT NULL THEN RAISE EXCEPTION 'VERIFY q11: written visits share time on their truck: %', sh; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'q11:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY q11: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY q11: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  INSERT INTO _tos_report VALUES ('q11', jsonb_build_object('visits_written', 9, 'checks', ck - 'T_detail',
    'net_minutes', (SELECT sum(new_min - cur_min) FROM _q11_rows),
    'trucks_now', (SELECT jsonb_object_agg(v.id, v.vehicle_id) FROM _q11_rows r JOIN public.visits v ON v.id = r.visit_id)));
  RAISE NOTICE 'q11: 9 visits written and their ledger rows applied';
END $v$;

COMMIT;
