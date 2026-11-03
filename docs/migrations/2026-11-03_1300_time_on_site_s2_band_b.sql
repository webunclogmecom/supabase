-- ============================================================================
-- 2026-11-03_1300_time_on_site_s2_band_b  Visit duration re-check, stage S2: band B (10-08 to 10-17) plus 8854
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred approved the whole re-check plan on 2026-10-27 (samsara-checks/recheck_plan_2026-10-27/PLAN.md,
--   section 6.1, stage S2 on Tue 11-03). His band B card answers, 2026-10-29 (in chat): "5892 write 91; 8845 write 186;
--   8851 write 55; 8773 keep 23; 5936 / 6523 keep 67, relabel only; 8854 keep 38." On 11-03: "can you go ahead with this
--   now?". The plan, the verdicts and the cards are local (they name clients): run folder
--   samsara-checks/duration_recheck_run_2026-10-28 (report/REPORT.md "S2", S2/). Visit ids, minutes and times only here.
-- WHY
--   The 10-18 band B rows (run tos-fix-2026-r1, stage catch_up, 61 'proposed' rows) were built by the old rule and could
--   not be applied as built (PLAN B20). The 10-28 re-check measured every band B visit again with two independent judges
--   (T, trips; V2, the 1-second track). This file replaces those rows with SUPERSEDING rows of a new run; the 10-18 rows
--   are never edited in place (only superseded_at is set, PLAN G-7).
-- WHAT IS WRITTEN (62 ledger rows of run tos-recheck-2026-r2, param recheck-2026-10-28:v06c6bea1, stage catch_up)
--   keep 32, keep_card 1, relabel 4, relabel_card 2, change 1, change_card 3, lock_card 1, lock_reviewed_blank 1, held 14, held_card 2, blank_held 1
--   applied keep / keep_card (33): T and V2 agree with the saved value within 2 min (method two_judges). The visit is
--     not written; the applied row makes T7 / T8 watch it. 8854 (made in the office on 10-19) per Fred's card.
--   applied relabel / relabel_card (6): a NULL-label value both judges confirm (4), and 5936 / 6523 per Fred's card:
--     same minutes and interval, label NULL -> review (the label every writer skips). Nothing a reviewer saw moves.
--   applied change / change_card (4): 6975 159 -> 174 (G-2 met, a small move, no card); 5892 83 -> 91, 8845 48 -> 186
--     and 8851 28 -> 55 per Fred's cards (8845 and 8851 are big moves with stamps and pump activity as the second
--     family; 5892 has a decided bonus, which is why it was a card). The interval is the one both judges measured.
--   applied lock_card (1): 8773 keeps 23, Fred refused the change (method card_keep_saved, new = the live value).
--   applied lock_reviewed_blank (1): 8765 stays the reviewed blank (Fred, 2026-10-13).
--   proposed held / held_card (16): UNSETTLED in the re-check (a judge or a setting flips it); the saved value is kept
--     and the row is left for a person (Monday page, Q-D). action keep_verified with status proposed = the proposal is
--     "keep"; nobody has verified it. 5918 and 8780 are cards Fred has not answered: same treatment (PLAN 6.3).
--   proposed blank_held (1): 8752 stays blank for a person, method far_park: the decided blank needs no stop of ours
--     within 500 m of the site in the window (PLAN 5.5 b test 4), and one exists (David 10:56 to 12:33 ET, 471 m, the
--     stop of another visit that day).
--   Stage stays 'catch_up' (band B's name in the stage CHECK, which this file does not widen); the run id separates.
-- WHAT CHANGES (visit  superseded row  kind  minutes  label  status)
--   5889  1348  keep                159 -> 159           samsara_stay -> samsara_stay  applied
--   5892  1382  change_card         83 -> 91             samsara_stay -> review  applied  10-16 02:19:57 to 10-16 03:51:05 ET
--   5918  1357  held_card           96 -> 96             stop_at_completion -> stop_at_completion  proposed
--   5930  1369  held                40 -> 40             stop_at_completion -> stop_at_completion  proposed
--   5936  1334  relabel_card        67 -> 67             NULL -> review  applied
--   6002  1352  relabel             40 -> 40             NULL -> review  applied
--   6033  1349  keep                42 -> 42             samsara_stay -> samsara_stay  applied
--   6224  1370  held                221 -> 221           samsara_stay -> samsara_stay  proposed
--   6248  1383  keep                50 -> 50             samsara_stay -> samsara_stay  applied
--   6261  1353  keep                27 -> 27             samsara_stay -> samsara_stay  applied
--   6276  1384  keep                34 -> 34             samsara_stay -> samsara_stay  applied
--   6406  1358  keep                89 -> 89             stop_at_completion -> stop_at_completion  applied
--   6419  1354  relabel             61 -> 61             NULL -> review  applied
--   6461  1371  keep                58 -> 58             stop_at_completion -> stop_at_completion  applied
--   6478  1372  keep                33 -> 33             stop_at_completion -> stop_at_completion  applied
--   6489  1385  keep                74 -> 74             stop_at_completion -> stop_at_completion  applied
--   6511  1342  keep                20 -> 20             samsara_stay -> samsara_stay  applied
--   6512  1390  keep                41 -> 41             stop_at_completion -> stop_at_completion  applied
--   6523  1335  relabel_card        67 -> 67             NULL -> review  applied
--   6576  1350  keep                75 -> 75             samsara_stay -> samsara_stay  applied
--   6589  1359  keep                68 -> 68             samsara_stay -> samsara_stay  applied
--   6608  1373  keep                36 -> 36             samsara_stay -> samsara_stay  applied
--   6666  1360  held                95 -> 95             samsara_stay -> samsara_stay  proposed
--   6721  1361  keep                72 -> 72             stop_at_completion -> stop_at_completion  applied
--   6800  1386  held                48 -> 48             stop_at_completion -> stop_at_completion  proposed
--   6975  1336  change              159 -> 174           samsara_stay -> review  applied  10-09 08:14:45 to 10-09 11:08:17 ET
--   7019  1351  keep                103 -> 103           samsara_stay -> samsara_stay  applied
--   7866  1337  keep                46 -> 46             samsara_stay -> samsara_stay  applied
--   7873  1355  held                34 -> 34             samsara_stay -> samsara_stay  proposed
--   8089  1374  held                52 -> 52             stop_at_completion -> stop_at_completion  proposed
--   8126  1375  held                18 -> 18             samsara_stay -> samsara_stay  proposed
--   8586  1338  keep                19 -> 19             samsara_stay -> samsara_stay  applied
--   8587  1362  keep                21 -> 21             stop_at_completion -> stop_at_completion  applied
--   8588  1391  keep                16 -> 16             samsara_stay -> samsara_stay  applied
--   8741  1339  keep                138 -> 138           samsara_stay -> samsara_stay  applied
--   8746  1363  keep                23 -> 23             samsara_stay -> samsara_stay  applied
--   8752  1343  blank_held          blank -> blank       NULL -> NULL  proposed
--   8753  1340  keep                77 -> 77             samsara_stay -> samsara_stay  applied
--   8760  1341  keep                36 -> 36             samsara_stay -> samsara_stay  applied
--   8761  1364  keep                94 -> 94             stop_at_completion -> stop_at_completion  applied
--   8762  1344  relabel             49 -> 49             NULL -> review  applied
--   8763  1345  relabel             75 -> 75             NULL -> review  applied
--   8764  1346  keep                96 -> 96             samsara_stay -> samsara_stay  applied
--   8765  1347  lock_reviewed_blank blank -> blank       reviewed_blank -> reviewed_blank  applied
--   8766  1376  keep                72 -> 72             samsara_stay -> samsara_stay  applied
--   8769  1365  held                54 -> 54             samsara_stay -> samsara_stay  proposed
--   8771  1356  keep                55 -> 55             samsara_stay -> samsara_stay  applied
--   8772  1366  keep                33 -> 33             samsara_stay -> samsara_stay  applied
--   8773  1367  lock_card           23 -> 23             samsara_stay -> samsara_stay  applied
--   8776  1368  keep                21 -> 21             samsara_stay -> samsara_stay  applied
--   8778  1377  keep                20 -> 20             samsara_stay -> samsara_stay  applied
--   8780  1378  held_card           26 -> 26             stop_at_completion -> stop_at_completion  proposed
--   8782  1387  held                90 -> 90             samsara_stay -> samsara_stay  proposed
--   8783  1379  keep                60 -> 60             samsara_stay -> samsara_stay  applied
--   8784  1380  held                11 -> 11             samsara_stay -> samsara_stay  proposed
--   8785  1381  held                80 -> 80             stop_at_completion -> stop_at_completion  proposed
--   8815  1388  held                48 -> 48             stop_at_completion -> stop_at_completion  proposed
--   8817  1392  held                73 -> 73             stop_at_completion -> stop_at_completion  proposed
--   8821  1389  held                19 -> 19             samsara_stay -> samsara_stay  proposed
--   8845  1393  change_card         48 -> 186            samsara_stay -> review  applied  10-16 11:18:16 to 10-16 14:24:01 ET
--   8851  1394  change_card         28 -> 55             samsara_stay -> review  applied  10-17 12:19:41 to 10-17 13:15:09 ET
--   8854  -     keep_card           38 -> 38             stop_at_completion -> stop_at_completion  applied
--   Net minutes: +188 (a blank counted as 0). 10 visits written: 6 labels, 4 values.
-- LEFT OUT ON PURPOSE
--   7873 (34, measured 44): UNSETTLED (V2's 4-minute minimum parking flips it), held, not written.
--   The Q-G reopen of 22 band A locks is band A (stage S4, Fri 11-06), not this file.
-- THE ROW GUARD
--   Every visit must still hold exactly what the 11-03 10:13 ET read saw: its four time columns, truck, visit_date and
--   completed_at, completed and not deleted, the same max(visit_reviews.bonus_decided_at), and the same current ledger
--   row. Visits and ledger rows are locked first (FOR UPDATE). A moved row is skipped, recorded as a 'skipped_guard' row
--   (superseded at once, so its old row stays current), never forced; more than 3 skipped rows stop the file.
-- PIN: the md5 of fn_time_on_site_checks (S1 body), the two fillers, the reopen trigger function, the Jobber push and
--   sync-pending trigger functions, audit.log_change and log_truck_gps_health; the 61 current catch_up rows (md5
--   1471d90964c37d521b2a054d307aee73 of the ordered row text without evidence, input_hashes and alternatives); no row
--   of run tos-recheck-2026-r2 and none for 8854 (a second run refuses). Evidence: verdicts.json sha256 06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700,
--   cards.html sha256 ddeff48e08a43b1d2407fa60c9bebdea0cc809a2c8f704477ae0e06bb0472d63.
-- WHAT DOES NOT CHANGE
--   vehicle_id, visit_date, start_at, end_at, visit_status, deleted_at, sync_state, the schedule: the VERIFY reads every
--   audit row of this transaction and allows only the four time columns (and updated_at) on the 10 written visits.
--   Nothing goes to Jobber (the push trigger does not list the time columns; asserted on net.http_request_queue).
--   No truck change, so no relink: tank, water and Grease pumped do not move.
-- CONSEQUENCES (prediction register, S2/PREDICT.md, local)
--   Calendar Hours worked (ops.calendar_hours_estimates), measured in the rehearsal: the four changed visits only,
--     6975 (10-08) 159 -> 174, 5892 (10-15) 83 -> 91, 8845 (10-16) 48 -> 186, 8851 (10-17) 28 -> 55; the averages of
--     two upcoming visits move, 5893 82 -> 83 and 6976 110 -> 115 (the clients of 5892 and 6975). Nothing else in
--     10-01 to 10-24 or in the next 45 days.
--   v_visit_tank_service: time_on_site_disagreement true -> false on 6975, 8845, 8851 (stops 174.1, 187.7, 58.3 min);
--     duration_minutes as above; every other column of every row unchanged (hash). F7 95 -> 92 (the same three).
--   Unchanged: ops.visit_grease_frozen, every other completed visit's time, shared time (5936 / 6523 keep their
--     67-min pair), v_visit_stop_reference (452 rows), T1 to T8 (all 0), truck GPS health (0 items; an applied row
--     with the visit's own truck also stands for a decision there, as the 10-18 rows do).
-- LABEL: x-app-source time-on-site-recheck-2026, one reason for the transaction.
-- VERIFY: 62 rows, one current row per visit; every row holds its value, truck, date and completion; shape checks;
--   only the 10 visits, only the time columns, labelled; the ledger audited, no other table; controls 6509 and 1240
--   byte-identical; no Jobber push; no new shared time; T1 to T8 not newly failing, T7 = T8 = 0; the row list's md5.
-- REHEARSED (scripts/probes style runner S2/rehearse.mjs, local; every run rolled back)
--   (a) as written: pass (1.7 s). (p) the consumer diff above. (b) 6033 moved before the guard: skipped and recorded
--   as skipped_guard, its 10-18 row stays current, the other 61 pass. (b4) four moved: the file stops, nothing written.
--   (c) the 61-row checksum altered: the file raises. (r) the rollback on top: the 62 visits and the 61 10-18 rows
--   byte-identical to before S2, no current row of the run, 8854 with no row, T1 to T8 0.
-- LOCKS: lock_timeout 3s. Apply 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20, :30 to :45 (PLAN G-9).
-- ROLLBACK: docs/migrations/2026-11-03_rollback_time_on_site_s2_band_b.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN: the bodies this file relies on, the 61 band B rows it supersedes, and no earlier run of this file.
DO $pin$ DECLARE n int; c text; BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S2: % is not the S1 body', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION 'S2: % moved', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION 'S2: % moved', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure)) <> '8cb07e2569923869e9da325fbfc3d868' THEN
    RAISE EXCEPTION 'S2: % moved', 'fn_clear_time_on_site_on_reopen()'; END IF;
  IF md5(pg_get_functiondef('public.fn_push_visit_to_jobber()'::regprocedure)) <> 'a6512e3f1b2cb2de0fddd39bb3679fbe' THEN
    RAISE EXCEPTION 'S2: % moved', 'fn_push_visit_to_jobber()'; END IF;
  IF md5(pg_get_functiondef('public.fn_mark_visit_sync_pending()'::regprocedure)) <> 'f607c3772a444f8fe275380e44651fb4' THEN
    RAISE EXCEPTION 'S2: % moved', 'fn_mark_visit_sync_pending()'; END IF;
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'c93f59bc7978be06d78747c9fd929da0' THEN
    RAISE EXCEPTION 'S2: % moved', 'audit.log_change()'; END IF;
  IF md5(pg_get_functiondef('public.log_truck_gps_health()'::regprocedure)) <> 'cd9b3e5f3bd7f969a14417fc2c3763e6' THEN
    RAISE EXCEPTION 'S2: % moved', 'log_truck_gps_health()'; END IF;
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.run_id = 'tos-fix-2026-r1' AND l.stage = 'catch_up' AND l.status = 'proposed';
  IF n <> 61 OR c IS DISTINCT FROM '1471d90964c37d521b2a054d307aee73' THEN
    RAISE EXCEPTION 'S2: % current catch_up rows, checksum %; expected 61, 1471d90964c37d521b2a054d307aee73 (already applied, or a row moved: re-read and re-rehearse)', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r2') THEN
    RAISE EXCEPTION 'S2: run tos-recheck-2026-r2 already has rows'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE visit_id = 8854) THEN
    RAISE EXCEPTION 'S2: 8854 already has a ledger row'; END IF;
END $pin$;

-- 1. The rows: visit, the row it supersedes, kind, what the visit holds now (guard), the new values, the ledger labels.
CREATE TEMP TABLE _s2 ON COMMIT DROP AS
SELECT t.*, NULL::text AS skip FROM (VALUES
  (5889, 1348, 'keep', 159, timestamptz '2026-10-12T04:46:16.503+00:00', timestamptz '2026-10-12T07:24:54.526+00:00', 'samsara_stay', 1, date '2026-10-11', timestamptz '2026-10-12T07:23:51+00:00', NULL::timestamptz, 159, timestamptz '2026-10-12T04:46:16.503+00:00', timestamptz '2026-10-12T07:24:54.526+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":159,"parts":[["2026-10-12T04:46:16.503Z","2026-10-12T07:24:54.526Z"]]}}'::jsonb),
  (6033, 1349, 'keep', 42, timestamptz '2026-10-12T01:42:16.515+00:00', timestamptz '2026-10-12T02:24:12.538+00:00', 'samsara_stay', 1, date '2026-10-11', timestamptz '2026-10-12T02:23:08+00:00', NULL::timestamptz, 42, timestamptz '2026-10-12T01:42:16.515+00:00', timestamptz '2026-10-12T02:24:12.538+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":42,"parts":[["2026-10-12T01:42:16.515Z","2026-10-12T02:24:12.538Z"]]}}'::jsonb),
  (6248, 1383, 'keep', 50, timestamptz '2026-10-16T05:12:50.511+00:00', timestamptz '2026-10-16T06:02:57.508+00:00', 'samsara_stay', 1, date '2026-10-15', timestamptz '2026-10-16T06:01:39+00:00', timestamptz '2026-10-21T15:13:59.038+00:00', 50, timestamptz '2026-10-16T05:12:50.511+00:00', timestamptz '2026-10-16T06:02:57.508+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":50,"parts":[["2026-10-16T05:12:50.511Z","2026-10-16T06:02:57.508Z"]]}}'::jsonb),
  (6261, 1353, 'keep', 27, timestamptz '2026-10-13T03:51:05.505+00:00', timestamptz '2026-10-13T04:18:11.55+00:00', 'samsara_stay', 1, date '2026-10-12', timestamptz '2026-10-13T04:17:17+00:00', NULL::timestamptz, 27, timestamptz '2026-10-13T03:51:05.505+00:00', timestamptz '2026-10-13T04:18:11.55+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":27,"parts":[["2026-10-13T03:51:05.505Z","2026-10-13T04:18:11.550Z"]]}}'::jsonb),
  (6276, 1384, 'keep', 34, timestamptz '2026-10-16T03:48:58.5+00:00', timestamptz '2026-10-16T04:23:04.512+00:00', 'samsara_stay', 1, date '2026-10-15', timestamptz '2026-10-16T04:21:17+00:00', NULL::timestamptz, 34, timestamptz '2026-10-16T03:48:58.5+00:00', timestamptz '2026-10-16T04:23:04.512+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":34,"parts":[["2026-10-16T03:48:58.500Z","2026-10-16T04:23:04.512Z"]]}}'::jsonb),
  (6406, 1358, 'keep', 89, timestamptz '2026-10-14T08:58:44+00:00', timestamptz '2026-10-14T10:28:05+00:00', 'stop_at_completion', 1, date '2026-10-13', timestamptz '2026-10-14T10:27:28+00:00', timestamptz '2026-10-19T11:16:32.929+00:00', 89, timestamptz '2026-10-14T08:58:44+00:00', timestamptz '2026-10-14T10:28:05+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":88,"parts":[["2026-10-14T08:59:40.525Z","2026-10-14T10:27:52.541Z"]]}}'::jsonb),
  (6461, 1371, 'keep', 58, timestamptz '2026-10-14T09:10:43+00:00', timestamptz '2026-10-14T10:08:20+00:00', 'stop_at_completion', 2, date '2026-10-14', timestamptz '2026-10-14T10:07:03+00:00', NULL::timestamptz, 58, timestamptz '2026-10-14T09:10:43+00:00', timestamptz '2026-10-14T10:08:20+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":57,"parts":[["2026-10-14T09:11:09.506Z","2026-10-14T10:08:03.530Z"]]}}'::jsonb),
  (6478, 1372, 'keep', 33, timestamptz '2026-10-15T08:48:19+00:00', timestamptz '2026-10-15T09:21:12+00:00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15T09:18:35+00:00', NULL::timestamptz, 33, timestamptz '2026-10-15T08:48:19+00:00', timestamptz '2026-10-15T09:21:12+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":32,"parts":[["2026-10-15T08:49:31.512Z","2026-10-15T09:21:04.521Z"]]}}'::jsonb),
  (6489, 1385, 'keep', 74, timestamptz '2026-10-16T08:02:18+00:00', timestamptz '2026-10-16T09:16:45+00:00', 'stop_at_completion', 1, date '2026-10-15', timestamptz '2026-10-16T09:14:24+00:00', NULL::timestamptz, 74, timestamptz '2026-10-16T08:02:18+00:00', timestamptz '2026-10-16T09:16:45+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":75,"parts":[["2026-10-16T08:00:59.506Z","2026-10-16T09:16:10.512Z"]]}}'::jsonb),
  (6511, 1342, 'keep', 20, timestamptz '2026-10-09T18:12:24.528+00:00', timestamptz '2026-10-09T18:32:24.558+00:00', 'samsara_stay', 3, date '2026-10-09', timestamptz '2026-10-09T18:57:29+00:00', NULL::timestamptz, 20, timestamptz '2026-10-09T18:12:24.528+00:00', timestamptz '2026-10-09T18:32:24.558+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":20,"parts":[["2026-10-09T18:12:24.528Z","2026-10-09T18:32:24.558Z"]]}}'::jsonb),
  (6512, 1390, 'keep', 41, timestamptz '2026-10-16T10:38:03+00:00', timestamptz '2026-10-16T11:19:21+00:00', 'stop_at_completion', 3, date '2026-10-16', timestamptz '2026-10-16T10:59:31+00:00', NULL::timestamptz, 41, timestamptz '2026-10-16T10:38:03+00:00', timestamptz '2026-10-16T11:19:21+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":40,"parts":[["2026-10-16T10:39:31.510Z","2026-10-16T11:19:10.534Z"]]}}'::jsonb),
  (6576, 1350, 'keep', 75, timestamptz '2026-10-12T03:14:56.517+00:00', timestamptz '2026-10-12T04:30:04.522+00:00', 'samsara_stay', 1, date '2026-10-11', timestamptz '2026-10-12T04:23:41+00:00', NULL::timestamptz, 75, timestamptz '2026-10-12T03:14:56.517+00:00', timestamptz '2026-10-12T04:30:04.522+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":75,"parts":[["2026-10-12T03:14:56.517Z","2026-10-12T04:30:04.522Z"]]}}'::jsonb),
  (6589, 1359, 'keep', 68, timestamptz '2026-10-14T04:36:56.572+00:00', timestamptz '2026-10-14T05:45:22.517+00:00', 'samsara_stay', 1, date '2026-10-13', timestamptz '2026-10-14T05:43:09+00:00', timestamptz '2026-10-19T11:14:02.814+00:00', 68, timestamptz '2026-10-14T04:36:56.572+00:00', timestamptz '2026-10-14T05:45:22.517+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":68,"parts":[["2026-10-14T04:36:56.572Z","2026-10-14T05:45:22.517Z"]]}}'::jsonb),
  (6608, 1373, 'keep', 36, timestamptz '2026-10-15T08:09:40.533+00:00', timestamptz '2026-10-15T08:45:36.537+00:00', 'samsara_stay', 1, date '2026-10-14', timestamptz '2026-10-15T08:44:55+00:00', NULL::timestamptz, 36, timestamptz '2026-10-15T08:09:40.533+00:00', timestamptz '2026-10-15T08:45:36.537+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":36,"parts":[["2026-10-15T08:09:40.533Z","2026-10-15T08:45:36.537Z"]]}}'::jsonb),
  (6721, 1361, 'keep', 72, timestamptz '2026-10-14T05:50:04+00:00', timestamptz '2026-10-14T07:01:52+00:00', 'stop_at_completion', 1, date '2026-10-13', timestamptz '2026-10-14T07:02:07+00:00', timestamptz '2026-10-19T11:13:14.433+00:00', 72, timestamptz '2026-10-14T05:50:04+00:00', timestamptz '2026-10-14T07:01:52+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":72,"parts":[["2026-10-14T05:51:03.515Z","2026-10-14T07:03:24.531Z"]]}}'::jsonb),
  (7019, 1351, 'keep', 103, timestamptz '2026-10-12T07:28:23.545+00:00', timestamptz '2026-10-12T09:11:05.508+00:00', 'samsara_stay', 1, date '2026-10-11', timestamptz '2026-10-12T09:10:15+00:00', NULL::timestamptz, 103, timestamptz '2026-10-12T07:28:23.545+00:00', timestamptz '2026-10-12T09:11:05.508+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":103,"parts":[["2026-10-12T07:28:23.545Z","2026-10-12T09:11:05.508Z"]]}}'::jsonb),
  (7866, 1337, 'keep', 46, timestamptz '2026-10-09T09:41:30.506+00:00', timestamptz '2026-10-09T10:27:26.557+00:00', 'samsara_stay', 1, date '2026-10-08', timestamptz '2026-10-09T10:28:54+00:00', timestamptz '2026-10-23T15:36:07.549+00:00', 46, timestamptz '2026-10-09T09:41:30.506+00:00', timestamptz '2026-10-09T10:27:26.557+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":46,"parts":[["2026-10-09T09:41:30.506Z","2026-10-09T10:27:26.557Z"]]}}'::jsonb),
  (8586, 1338, 'keep', 19, timestamptz '2026-10-08T16:56:44.508+00:00', timestamptz '2026-10-08T17:16:11.532+00:00', 'samsara_stay', 3, date '2026-10-08', timestamptz '2026-10-08T17:15:45+00:00', NULL::timestamptz, 19, timestamptz '2026-10-08T16:56:44.508+00:00', timestamptz '2026-10-08T17:16:11.532+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":19,"parts":[["2026-10-08T16:56:44.508Z","2026-10-08T17:16:11.532Z"]]}}'::jsonb),
  (8587, 1362, 'keep', 21, timestamptz '2026-10-13T17:30:24+00:00', timestamptz '2026-10-13T17:50:54+00:00', 'stop_at_completion', 3, date '2026-10-13', timestamptz '2026-10-13T17:49:41+00:00', NULL::timestamptz, 21, timestamptz '2026-10-13T17:30:24+00:00', timestamptz '2026-10-13T17:50:54+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":20,"parts":[["2026-10-13T17:30:57.589Z","2026-10-13T17:51:09.570Z"]]}}'::jsonb),
  (8588, 1391, 'keep', 16, timestamptz '2026-10-16T13:53:17.523+00:00', timestamptz '2026-10-16T14:09:08.531+00:00', 'samsara_stay', 3, date '2026-10-16', timestamptz '2026-10-16T14:08:08+00:00', NULL::timestamptz, 16, timestamptz '2026-10-16T13:53:17.523+00:00', timestamptz '2026-10-16T14:09:08.531+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":16,"parts":[["2026-10-16T13:53:17.523Z","2026-10-16T14:09:08.531Z"]]}}'::jsonb),
  (8741, 1339, 'keep', 138, timestamptz '2026-10-09T04:03:37.522+00:00', timestamptz '2026-10-09T06:21:14.516+00:00', 'samsara_stay', 1, date '2026-10-08', timestamptz '2026-10-09T06:19:54+00:00', timestamptz '2026-10-21T15:30:18.131+00:00', 138, timestamptz '2026-10-09T04:03:37.522+00:00', timestamptz '2026-10-09T06:21:14.516+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":138,"parts":[["2026-10-09T04:03:37.522Z","2026-10-09T06:21:14.516Z"]]}}'::jsonb),
  (8746, 1363, 'keep', 23, timestamptz '2026-10-13T08:50:23.52+00:00', timestamptz '2026-10-13T09:13:40.929+00:00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13T09:12:36+00:00', NULL::timestamptz, 23, timestamptz '2026-10-13T08:50:23.52+00:00', timestamptz '2026-10-13T09:13:40.929+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":23,"parts":[["2026-10-13T08:50:23.520Z","2026-10-13T09:13:40.929Z"]]}}'::jsonb),
  (8753, 1340, 'keep', 77, timestamptz '2026-10-08T19:53:24.492+00:00', timestamptz '2026-10-08T21:10:37.508+00:00', 'samsara_stay', 2, date '2026-10-08', timestamptz '2026-10-08T21:11:48+00:00', NULL::timestamptz, 77, timestamptz '2026-10-08T19:53:24.492+00:00', timestamptz '2026-10-08T21:10:37.508+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":77,"parts":[["2026-10-08T19:53:24.492Z","2026-10-08T21:10:37.508Z"]]}}'::jsonb),
  (8760, 1341, 'keep', 36, timestamptz '2026-10-08T18:04:45.5+00:00', timestamptz '2026-10-08T18:40:45.505+00:00', 'samsara_stay', 2, date '2026-10-08', timestamptz '2026-10-08T18:39:50+00:00', NULL::timestamptz, 36, timestamptz '2026-10-08T18:04:45.5+00:00', timestamptz '2026-10-08T18:40:45.505+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":36,"parts":[["2026-10-08T18:04:45.500Z","2026-10-08T18:40:45.505Z"]]}}'::jsonb),
  (8761, 1364, 'keep', 94, timestamptz '2026-10-13T13:54:35+00:00', timestamptz '2026-10-13T15:28:35+00:00', 'stop_at_completion', 2, date '2026-10-13', timestamptz '2026-10-13T15:23:09+00:00', NULL::timestamptz, 94, timestamptz '2026-10-13T13:54:35+00:00', timestamptz '2026-10-13T15:28:35+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":93,"parts":[["2026-10-13T13:55:10.541Z","2026-10-13T15:28:24.512Z"]]}}'::jsonb),
  (8764, 1346, 'keep', 96, timestamptz '2026-10-09T14:57:42.513+00:00', timestamptz '2026-10-09T16:33:28.513+00:00', 'samsara_stay', 3, date '2026-10-09', timestamptz '2026-10-09T16:25:05+00:00', timestamptz '2026-10-21T15:30:59.427+00:00', 96, timestamptz '2026-10-09T14:57:42.513+00:00', timestamptz '2026-10-09T16:33:28.513+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":96,"parts":[["2026-10-09T14:57:42.513Z","2026-10-09T16:33:28.513Z"]]}}'::jsonb),
  (8766, 1376, 'keep', 72, timestamptz '2026-10-14T14:32:21.501+00:00', timestamptz '2026-10-14T15:44:01.517+00:00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14T15:42:49+00:00', NULL::timestamptz, 72, timestamptz '2026-10-14T14:32:21.501+00:00', timestamptz '2026-10-14T15:44:01.517+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":72,"parts":[["2026-10-14T14:32:21.501Z","2026-10-14T15:44:01.517Z"]]}}'::jsonb),
  (8771, 1356, 'keep', 55, timestamptz '2026-10-12T16:42:44.512+00:00', timestamptz '2026-10-12T17:37:28.518+00:00', 'samsara_stay', 2, date '2026-10-12', timestamptz '2026-10-12T17:38:37+00:00', NULL::timestamptz, 55, timestamptz '2026-10-12T16:42:44.512+00:00', timestamptz '2026-10-12T17:37:28.518+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":55,"parts":[["2026-10-12T16:42:44.512Z","2026-10-12T17:37:28.518Z"]]}}'::jsonb),
  (8772, 1366, 'keep', 33, timestamptz '2026-10-13T13:16:11.535+00:00', timestamptz '2026-10-13T13:49:21.5+00:00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13T13:47:22+00:00', NULL::timestamptz, 33, timestamptz '2026-10-13T13:16:11.535+00:00', timestamptz '2026-10-13T13:49:21.5+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":33,"parts":[["2026-10-13T13:16:11.535Z","2026-10-13T13:49:21.500Z"]]}}'::jsonb),
  (8776, 1368, 'keep', 21, timestamptz '2026-10-13T12:22:51.504+00:00', timestamptz '2026-10-13T12:43:43.53+00:00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13T12:43:18+00:00', NULL::timestamptz, 21, timestamptz '2026-10-13T12:22:51.504+00:00', timestamptz '2026-10-13T12:43:43.53+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":21,"parts":[["2026-10-13T12:22:51.504Z","2026-10-13T12:43:43.530Z"]]}}'::jsonb),
  (8778, 1377, 'keep', 20, timestamptz '2026-10-14T17:38:01.497+00:00', timestamptz '2026-10-14T17:58:12.51+00:00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14T17:55:14+00:00', NULL::timestamptz, 20, timestamptz '2026-10-14T17:38:01.497+00:00', timestamptz '2026-10-14T17:58:12.51+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":20,"parts":[["2026-10-14T17:38:01.497Z","2026-10-14T17:58:12.510Z"]]}}'::jsonb),
  (8783, 1379, 'keep', 60, timestamptz '2026-10-14T16:25:50.503+00:00', timestamptz '2026-10-14T17:26:01.508+00:00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14T17:23:56+00:00', NULL::timestamptz, 60, timestamptz '2026-10-14T16:25:50.503+00:00', timestamptz '2026-10-14T17:26:01.508+00:00', 'samsara_stay', 'applied', 'keep_verified', 'two_judges', 'high', NULL, '{"s2_kind":"keep","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":60,"parts":[["2026-10-14T16:25:50.503Z","2026-10-14T17:26:01.508Z"]]}}'::jsonb),
  (8854, NULL::bigint, 'keep_card', 38, timestamptz '2026-10-16T20:59:07+00:00', timestamptz '2026-10-16T21:37:23+00:00', 'stop_at_completion', 2, date '2026-10-16', timestamptz '2026-10-19T13:59:40+00:00', NULL::timestamptz, 38, timestamptz '2026-10-16T20:59:07+00:00', timestamptz '2026-10-16T21:37:23+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'two_judges', 'person', 'fred:2026-10-29:card_8854', '{"s2_kind":"keep_card","verdict":"UNSETTLED","reason":"C7_flip:T site radius 200 m","card":true,"measured":{"minutes":37,"parts":[["2026-10-16T20:59:48.510Z","2026-10-16T21:37:06.520Z"]]}}'::jsonb),
  (8762, 1344, 'relabel', 49, timestamptz '2026-10-09T19:00:32+00:00', timestamptz '2026-10-09T19:49:38+00:00', NULL, 2, date '2026-10-09', timestamptz '2026-10-09T19:48:45+00:00', NULL::timestamptz, 49, timestamptz '2026-10-09T19:00:32+00:00', timestamptz '2026-10-09T19:49:38+00:00', 'review', 'applied', 'relabel', 'two_judges', 'high', NULL, '{"s2_kind":"relabel","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":48,"parts":[["2026-10-09T19:01:36.503Z","2026-10-09T19:49:13.510Z"]]}}'::jsonb),
  (8763, 1345, 'relabel', 75, timestamptz '2026-10-09T20:04:20+00:00', timestamptz '2026-10-09T21:19:45+00:00', NULL, 2, date '2026-10-09', timestamptz '2026-10-09T21:19:09+00:00', NULL::timestamptz, 75, timestamptz '2026-10-09T20:04:20+00:00', timestamptz '2026-10-09T21:19:45+00:00', 'review', 'applied', 'relabel', 'two_judges', 'high', NULL, '{"s2_kind":"relabel","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":75,"parts":[["2026-10-09T20:04:57.505Z","2026-10-09T21:19:39.514Z"]]}}'::jsonb),
  (6002, 1352, 'relabel', 40, timestamptz '2026-10-13T05:24:00+00:00', timestamptz '2026-10-13T06:04:15+00:00', NULL, 1, date '2026-10-12', timestamptz '2026-10-13T06:02:44+00:00', NULL::timestamptz, 40, timestamptz '2026-10-13T05:24:00+00:00', timestamptz '2026-10-13T06:04:15+00:00', 'review', 'applied', 'relabel', 'two_judges', 'high', NULL, '{"s2_kind":"relabel","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":39,"parts":[["2026-10-13T05:25:05.515Z","2026-10-13T06:03:53.507Z"]]}}'::jsonb),
  (6419, 1354, 'relabel', 61, timestamptz '2026-10-13T02:40:57+00:00', timestamptz '2026-10-13T03:42:22+00:00', NULL, 1, date '2026-10-12', timestamptz '2026-10-13T03:40:28+00:00', NULL::timestamptz, 61, timestamptz '2026-10-13T02:40:57+00:00', timestamptz '2026-10-13T03:42:22+00:00', 'review', 'applied', 'relabel', 'two_judges', 'high', NULL, '{"s2_kind":"relabel","verdict":"AGREE","reason":"saved_equals_judges","card":false,"measured":{"minutes":60,"parts":[["2026-10-13T02:42:41.537Z","2026-10-13T03:42:11.560Z"]]}}'::jsonb),
  (5936, 1334, 'relabel_card', 67, timestamptz '2026-10-09T07:37:58+00:00', timestamptz '2026-10-09T08:45:15+00:00', NULL, 1, date '2026-10-08', timestamptz '2026-10-09T08:42:22+00:00', timestamptz '2026-10-12T11:35:35.967+00:00', 67, timestamptz '2026-10-09T07:37:58+00:00', timestamptz '2026-10-09T08:45:15+00:00', 'review', 'applied', 'relabel', 'card_keep_saved', 'person', 'fred:2026-10-29:card_5936', '{"s2_kind":"relabel_card","verdict":"AGREE","reason":"saved_equals_judges","card":true,"measured":{"minutes":66,"parts":[["2026-10-09T07:39:21.519Z","2026-10-09T08:44:52.518Z"]]}}'::jsonb),
  (6523, 1335, 'relabel_card', 67, timestamptz '2026-10-09T07:37:58+00:00', timestamptz '2026-10-09T08:45:15+00:00', NULL, 1, date '2026-10-08', timestamptz '2026-10-09T08:43:35+00:00', timestamptz '2026-10-12T11:39:58.17+00:00', 67, timestamptz '2026-10-09T07:37:58+00:00', timestamptz '2026-10-09T08:45:15+00:00', 'review', 'applied', 'relabel', 'card_keep_saved', 'person', 'fred:2026-10-29:card_6523', '{"s2_kind":"relabel_card","verdict":"UNSETTLED","reason":"C7_flip:T T parking position (README ruling 21) trip_end","card":true,"measured":{"minutes":66,"parts":[["2026-10-09T07:39:21.519Z","2026-10-09T08:44:52.518Z"]]}}'::jsonb),
  (5892, 1382, 'change_card', 83, timestamptz '2026-10-16T06:27:36.518+00:00', timestamptz '2026-10-16T07:51:05.511+00:00', 'samsara_stay', 1, date '2026-10-15', timestamptz '2026-10-16T07:49:34+00:00', timestamptz '2026-10-20T18:35:51.318+00:00', 91, timestamptz '2026-10-16T06:19:57.523Z', timestamptz '2026-10-16T07:51:05.511Z', 'review', 'applied', 'change', 'two_judges', 'person', 'fred:2026-10-29:card_5892', '{"s2_kind":"change_card","verdict":"UNSETTLED","reason":"C7_flip:V2 minimum parking 4 min","card":true,"measured":{"minutes":91,"parts":[["2026-10-16T06:19:57.523Z","2026-10-16T07:51:05.511Z"]]}}'::jsonb),
  (6975, 1336, 'change', 159, timestamptz '2026-10-09T12:29:28.513+00:00', timestamptz '2026-10-09T15:08:17.519+00:00', 'samsara_stay', 1, date '2026-10-08', timestamptz '2026-10-09T15:03:36+00:00', NULL::timestamptz, 174, timestamptz '2026-10-09T12:14:45.508Z', timestamptz '2026-10-09T15:08:17.519Z', 'review', 'applied', 'change', 'two_judges', 'high', NULL, '{"s2_kind":"change","verdict":"DIFFERS","reason":"g2_small_move","card":false,"measured":{"minutes":174,"parts":[["2026-10-09T12:14:45.508Z","2026-10-09T15:08:17.519Z"]]}}'::jsonb),
  (8845, 1393, 'change_card', 48, timestamptz '2026-10-16T15:18:16.504+00:00', timestamptz '2026-10-16T16:06:18.52+00:00', 'samsara_stay', 2, date '2026-10-16', timestamptz '2026-10-16T19:36:39+00:00', NULL::timestamptz, 186, timestamptz '2026-10-16T15:18:16.504Z', timestamptz '2026-10-16T18:24:01.508Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'high', 'fred:2026-10-29:card_8845', '{"s2_kind":"change_card","verdict":"DIFFERS","reason":"g2_big_move_stamp+pump","card":true,"measured":{"minutes":186,"parts":[["2026-10-16T15:18:16.504Z","2026-10-16T18:24:01.508Z"]]}}'::jsonb),
  (8851, 1394, 'change_card', 28, timestamptz '2026-10-17T16:19:41.502+00:00', timestamptz '2026-10-17T16:48:10.881+00:00', 'samsara_stay', 2, date '2026-10-17', timestamptz '2026-10-17T17:14:23+00:00', NULL::timestamptz, 55, timestamptz '2026-10-17T16:19:41.502Z', timestamptz '2026-10-17T17:15:09.513Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'high', 'fred:2026-10-29:card_8851', '{"s2_kind":"change_card","verdict":"DIFFERS","reason":"g2_big_move_stamp+pump","card":true,"measured":{"minutes":55,"parts":[["2026-10-17T16:19:41.502Z","2026-10-17T17:15:09.513Z"]]}}'::jsonb),
  (8773, 1367, 'lock_card', 23, timestamptz '2026-10-13T08:50:23.52+00:00', timestamptz '2026-10-13T09:13:40.929+00:00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13T10:44:04+00:00', NULL::timestamptz, 23, timestamptz '2026-10-13T08:50:23.52+00:00', timestamptz '2026-10-13T09:13:40.929+00:00', 'samsara_stay', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-10-29:card_8773', '{"s2_kind":"lock_card","verdict":"UNSETTLED","reason":"big_move_no_second_family","card":true,"measured":{"minutes":6,"parts":[["2026-10-13T09:15:53.498Z","2026-10-13T09:21:33.440Z"]]}}'::jsonb),
  (8765, 1347, 'lock_reviewed_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, 'reviewed_blank', NULL::bigint, date '2026-10-09', timestamptz '2026-10-09T15:25:26+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, 'reviewed_blank', 'applied', 'lock_decided', 'kept_by_decision', 'person', 'fred:2026-10-13:step_4', '{"s2_kind":"lock_reviewed_blank","verdict":"BLANK_OK","reason":"no_presence","card":false,"measured":null}'::jsonb),
  (5930, 1369, 'held', 40, timestamptz '2026-10-15T07:05:45+00:00', timestamptz '2026-10-15T07:46:09+00:00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15T07:42:49+00:00', NULL::timestamptz, 40, timestamptz '2026-10-15T07:05:45+00:00', timestamptz '2026-10-15T07:46:09+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 pumpPick (ruling 13: \"A run with pumpPick off is part of C7\") off","card":false,"measured":{"minutes":40,"parts":[["2026-10-15T07:06:14.557Z","2026-10-15T07:46:10.000Z"]]}}'::jsonb),
  (6224, 1370, 'held', 221, timestamptz '2026-10-15T03:24:07.518+00:00', timestamptz '2026-10-15T07:04:46.512+00:00', 'samsara_stay', 1, date '2026-10-14', timestamptz '2026-10-15T07:03:06+00:00', timestamptz '2026-10-19T13:19:16.678+00:00', 221, timestamptz '2026-10-15T03:24:07.518+00:00', timestamptz '2026-10-15T07:04:46.512+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:T T parking position (README ruling 21) trip_end","card":false,"measured":{"minutes":221,"parts":[["2026-10-15T03:24:07.518Z","2026-10-15T07:04:46.512Z"]]}}'::jsonb),
  (6666, 1360, 'held', 95, timestamptz '2026-10-14T02:45:59.517+00:00', timestamptz '2026-10-14T04:20:33.528+00:00', 'samsara_stay', 1, date '2026-10-13', timestamptz '2026-10-14T04:11:43+00:00', timestamptz '2026-10-19T11:12:31.085+00:00', 95, timestamptz '2026-10-14T02:45:59.517+00:00', timestamptz '2026-10-14T04:20:33.528+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:T site radius 300 m","card":false,"measured":{"minutes":95,"parts":[["2026-10-14T02:45:59.517Z","2026-10-14T04:20:33.528Z"]]}}'::jsonb),
  (6800, 1386, 'held', 48, timestamptz '2026-10-16T02:53:28+00:00', timestamptz '2026-10-16T03:41:52+00:00', 'stop_at_completion', 1, date '2026-10-15', timestamptz '2026-10-16T03:37:24+00:00', timestamptz '2026-10-26T14:27:34.137+00:00', 48, timestamptz '2026-10-16T02:53:28+00:00', timestamptz '2026-10-16T03:41:52+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 pumpPick (ruling 13: \"A run with pumpPick off is part of C7\") off","card":false,"measured":{"minutes":48,"parts":[["2026-10-16T02:54:09.507Z","2026-10-16T03:41:43.543Z"]]}}'::jsonb),
  (7873, 1355, 'held', 34, timestamptz '2026-10-13T04:32:25.513+00:00', timestamptz '2026-10-13T05:06:48.518+00:00', 'samsara_stay', 1, date '2026-10-12', timestamptz '2026-10-13T05:05:35+00:00', NULL::timestamptz, 34, timestamptz '2026-10-13T04:32:25.513+00:00', timestamptz '2026-10-13T05:06:48.518+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 minimum parking 4 min","card":false,"measured":{"minutes":44,"parts":[["2026-10-13T04:23:09.510Z","2026-10-13T05:06:48.518Z"]]}}'::jsonb),
  (8089, 1374, 'held', 52, timestamptz '2026-10-15T09:31:45+00:00', timestamptz '2026-10-15T10:24:00+00:00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15T10:20:44+00:00', NULL::timestamptz, 52, timestamptz '2026-10-15T09:31:45+00:00', timestamptz '2026-10-15T10:24:00+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:T guard margin 20 m","card":false,"measured":{"minutes":51,"parts":[["2026-10-15T09:32:25.521Z","2026-10-15T10:23:16.551Z"]]}}'::jsonb),
  (8126, 1375, 'held', 18, timestamptz '2026-10-14T13:39:44.495+00:00', timestamptz '2026-10-14T13:57:52.516+00:00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14T13:59:30+00:00', NULL::timestamptz, 18, timestamptz '2026-10-14T13:39:44.495+00:00', timestamptz '2026-10-14T13:57:52.516+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"V2_several","card":false,"measured":null}'::jsonb),
  (8769, 1365, 'held', 54, timestamptz '2026-10-13T11:18:05.512+00:00', timestamptz '2026-10-13T12:12:10.529+00:00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13T12:10:52+00:00', NULL::timestamptz, 54, timestamptz '2026-10-13T11:18:05.512+00:00', timestamptz '2026-10-13T12:12:10.529+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 pumpPick (ruling 13: \"A run with pumpPick off is part of C7\") off","card":false,"measured":{"minutes":54,"parts":[["2026-10-13T11:18:05.512Z","2026-10-13T12:12:10.529Z"]]}}'::jsonb),
  (8782, 1387, 'held', 90, timestamptz '2026-10-15T19:03:42.511+00:00', timestamptz '2026-10-15T20:33:41.613+00:00', 'samsara_stay', 2, date '2026-10-15', timestamptz '2026-10-15T20:36:03+00:00', NULL::timestamptz, 90, timestamptz '2026-10-15T19:03:42.511+00:00', timestamptz '2026-10-15T20:33:41.613+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":95,"parts":[["2026-10-15T18:58:51.000Z","2026-10-15T20:33:41.613Z"]]}}'::jsonb),
  (8784, 1380, 'held', 11, timestamptz '2026-10-14T18:22:07.507+00:00', timestamptz '2026-10-14T18:33:25.5+00:00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14T18:32:41+00:00', NULL::timestamptz, 11, timestamptz '2026-10-14T18:22:07.507+00:00', timestamptz '2026-10-14T18:33:25.5+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"T_unclaimed_tap_part_belongs_to_other_client","card":false,"measured":null}'::jsonb),
  (8785, 1381, 'held', 80, timestamptz '2026-10-15T11:44:58+00:00', timestamptz '2026-10-15T13:05:18+00:00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15T13:03:51+00:00', NULL::timestamptz, 80, timestamptz '2026-10-15T11:44:58+00:00', timestamptz '2026-10-15T13:05:18+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 pumpPick (ruling 13: \"A run with pumpPick off is part of C7\") off","card":false,"measured":{"minutes":79,"parts":[["2026-10-15T11:45:57.512Z","2026-10-15T13:05:12.559Z"]]}}'::jsonb),
  (8815, 1388, 'held', 48, timestamptz '2026-10-15T15:59:43+00:00', timestamptz '2026-10-15T16:47:52+00:00', 'stop_at_completion', 2, date '2026-10-15', timestamptz '2026-10-15T16:45:16+00:00', NULL::timestamptz, 48, timestamptz '2026-10-15T15:59:43+00:00', timestamptz '2026-10-15T16:47:52+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"C7_flip:V2 site radius 300 m","card":false,"measured":{"minutes":47,"parts":[["2026-10-15T16:00:31.514Z","2026-10-15T16:47:41.511Z"]]}}'::jsonb),
  (8817, 1392, 'held', 73, timestamptz '2026-10-16T12:26:58+00:00', timestamptz '2026-10-16T13:40:19+00:00', 'stop_at_completion', 3, date '2026-10-16', timestamptz '2026-10-16T13:38:12+00:00', timestamptz '2026-10-20T16:00:03.017+00:00', 73, timestamptz '2026-10-16T12:26:58+00:00', timestamptz '2026-10-16T13:40:19+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"V2_several","card":false,"measured":null}'::jsonb),
  (8821, 1389, 'held', 19, timestamptz '2026-10-15T17:22:44.515+00:00', timestamptz '2026-10-15T17:41:24.52+00:00', 'samsara_stay', 2, date '2026-10-15', timestamptz '2026-10-15T17:35:34+00:00', NULL::timestamptz, 19, timestamptz '2026-10-15T17:22:44.515+00:00', timestamptz '2026-10-15T17:41:24.52+00:00', 'samsara_stay', 'proposed', 'keep_verified', 'held_unsettled', 'person', NULL, '{"s2_kind":"held","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":26,"parts":[["2026-10-15T17:15:51.000Z","2026-10-15T17:41:24.520Z"]]}}'::jsonb),
  (5918, 1357, 'held_card', 96, timestamptz '2026-10-14T07:20:39+00:00', timestamptz '2026-10-14T08:56:13+00:00', 'stop_at_completion', 1, date '2026-10-13', timestamptz '2026-10-14T08:54:12+00:00', NULL::timestamptz, 96, timestamptz '2026-10-14T07:20:39+00:00', timestamptz '2026-10-14T08:56:13+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_card_open', 'person', NULL, '{"s2_kind":"held_card","verdict":"UNSETTLED","reason":"V2_several","card":true,"measured":null}'::jsonb),
  (8780, 1378, 'held_card', 26, timestamptz '2026-10-14T12:47:31+00:00', timestamptz '2026-10-14T13:13:33+00:00', 'stop_at_completion', 2, date '2026-10-14', timestamptz '2026-10-14T13:12:29+00:00', NULL::timestamptz, 26, timestamptz '2026-10-14T12:47:31+00:00', timestamptz '2026-10-14T13:13:33+00:00', 'stop_at_completion', 'proposed', 'keep_verified', 'held_card_open', 'person', NULL, '{"s2_kind":"held_card","verdict":"UNSETTLED","reason":"V2_several","card":true,"measured":null}'::jsonb),
  (8752, 1343, 'blank_held', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 3, date '2026-10-09', timestamptz '2026-10-09T19:43:22+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'proposed', 'blank', 'far_park', 'person', NULL, '{"s2_kind":"blank_held","verdict":"BLANK_OK","reason":"no_presence","card":false,"measured":null}'::jsonb)
) AS t(visit_id, old_lid, kind, cur_min, cur_arr, cur_dep, cur_src, cur_veh, cur_date, cur_comp, cur_bonus,
       new_min, new_arr, new_dep, new_src, status, action, method, confidence, decision_ref, evidence);

CREATE TEMP TABLE _s2_ctx ON COMMIT DROP AS
SELECT (SELECT max(id) FROM audit.logs) AS audit_id0,
       (SELECT coalesce(max(id), 0) FROM net.http_request_queue) AS net_id0,
       public.fn_time_on_site_checks() AS checks0,
       (SELECT jsonb_object_agg(s.visit_id, s.shared_with) FROM public.v_visit_shared_time s
         WHERE s.visit_id IN (SELECT visit_id FROM _s2) AND s.shared_with_count > 0) AS shared0;

-- 2. Lock, then the guard: a row that moved since 11-03 10:13 ET is skipped (recorded as skipped_guard), never forced.
DO $lock$ DECLARE nskip int; BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _s2) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (SELECT visit_id FROM _s2) AND l.superseded_at IS NULL FOR UPDATE;
  IF (SELECT count(*) FROM _s2) <> 62 OR (SELECT count(DISTINCT visit_id) FROM _s2) <> 62 THEN RAISE EXCEPTION 'S2: row list is not 62 distinct visits'; END IF;
  UPDATE _s2 r SET skip = CASE
      WHEN v.id IS NULL THEN 'missing'
      WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
      WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
      WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
      WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (r.cur_date, r.cur_comp) THEN 'date_or_completion_moved'
      WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM r.cur_bonus THEN 'bonus_decided'
      WHEN (SELECT l.id FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) IS DISTINCT FROM r.old_lid THEN 'ledger_row_not_current'
    END
    FROM _s2 r0 LEFT JOIN public.visits v ON v.id = r0.visit_id
   WHERE r0.visit_id = r.visit_id;
  SELECT count(*) INTO nskip FROM _s2 WHERE skip IS NOT NULL;
  IF nskip > 3 THEN RAISE EXCEPTION 'S2: % rows moved since they were read, nothing written: %', nskip,
    (SELECT jsonb_object_agg(visit_id, skip) FROM _s2 WHERE skip IS NOT NULL); END IF;
  IF nskip > 0 THEN RAISE NOTICE 'S2: skipped (moved since read): %', (SELECT jsonb_object_agg(visit_id, skip) FROM _s2 WHERE skip IS NOT NULL); END IF;
END $lock$;

-- 3. Ledger first (supersede, then insert run tos-recheck-2026-r2), then the visits, in the same transaction, labelled.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Visit duration re-check, stage S2 (band B 10-08 to 10-17 plus 8854), run tos-recheck-2026-r2: superseding ledger rows from the 10-28 re-check, Fred''s band B card answers of 2026-10-29. Method, evidence and decision per visit in public.visit_time_on_site_corrections. Not pushed to Jobber.'))::text, true);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now()
    FROM _s2 r WHERE r.skip IS NULL AND l.id = r.old_lid AND l.superseded_at IS NULL;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _s2 WHERE skip IS NULL AND old_lid IS NOT NULL) THEN RAISE EXCEPTION 'S2: superseded % rows, expected %', n, (SELECT count(*) FROM _s2 WHERE skip IS NULL AND old_lid IS NOT NULL); END IF;
  INSERT INTO public.visit_time_on_site_corrections
    (visit_id, run_id, param_version, input_hashes, old_vehicle_id, new_vehicle_id, stage, action, status, superseded_at,
     old_arrival, old_departure, old_minutes, old_source, old_visit_date, old_completed_at, bonus_decided_at_seen,
     new_arrival, new_departure, new_minutes, new_source, method, confidence, decision_ref, evidence, evidence_file_sha256,
     applied_at, applied_by_migration)
  SELECT r.visit_id, 'tos-recheck-2026-r2', 'recheck-2026-10-28:v06c6bea1',
         jsonb_build_object('verdicts_json_sha256', '06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700', 'cards_html_sha256', 'ddeff48e08a43b1d2407fa60c9bebdea0cc809a2c8f704477ae0e06bb0472d63', 'freeze', 'c29053ed'),
         r.cur_veh, r.cur_veh, 'catch_up', r.action,
         CASE WHEN r.skip IS NULL THEN r.status ELSE 'skipped_guard' END,
         CASE WHEN r.skip IS NULL THEN NULL ELSE now() END,
         r.cur_arr, r.cur_dep, r.cur_min, r.cur_src, r.cur_date, r.cur_comp, r.cur_bonus,
         r.new_arr, r.new_dep, r.new_min, r.new_src, r.method, r.confidence, r.decision_ref,
         r.evidence || jsonb_build_object('superseded_row_id', r.old_lid, 'skip', r.skip),
         '06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700',
         CASE WHEN r.skip IS NULL AND r.status = 'applied' THEN now() END,
         CASE WHEN r.skip IS NULL AND r.status = 'applied' THEN '2026-11-03_1300_time_on_site_s2_band_b.sql' END
    FROM _s2 r ORDER BY r.visit_id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 62 THEN RAISE EXCEPTION 'S2: inserted % ledger rows, expected 62', n; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep, time_on_site_source = r.new_src
    FROM _s2 r WHERE v.id = r.visit_id AND r.skip IS NULL AND r.kind IN ('relabel', 'relabel_card', 'change', 'change_card');
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _s2 WHERE skip IS NULL AND kind IN ('relabel', 'relabel_card', 'change', 'change_card')) THEN
    RAISE EXCEPTION 'S2: wrote % visits, expected %', n, (SELECT count(*) FROM _s2 WHERE skip IS NULL AND kind IN ('relabel', 'relabel_card', 'change', 'change_card')); END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint; ck jsonb; ck0 jsonb; t text; bad jsonb; nw int; nsk int;
BEGIN
  nsk := (SELECT count(*) FROM _s2 WHERE skip IS NOT NULL);
  nw := (SELECT count(*) FROM _s2 WHERE skip IS NULL AND kind IN ('relabel', 'relabel_card', 'change', 'change_card'));
  -- (a) the rows: 62 of the run, one current row per passing visit (its new row), a skipped visit keeps its old row
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r2';
  IF n <> 62 THEN RAISE EXCEPTION 'VERIFY S2: % rows of the run, expected 62', n; END IF;
  SELECT count(*) INTO n FROM _s2 r
   WHERE (SELECT count(*) FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) <> CASE WHEN r.skip IS NULL OR r.old_lid IS NOT NULL THEN 1 ELSE 0 END
      OR (r.skip IS NULL AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL
                                           AND l.run_id = 'tos-recheck-2026-r2' AND l.status = r.status))
      OR (r.skip IS NOT NULL AND r.old_lid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.id = r.old_lid AND l.superseded_at IS NULL));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % visits without the expected current row', n; END IF;
  -- (b) every passing row: the visit holds the new value, the ledger row holds it, its truck, date and completion;
  --     a kind that writes nothing has new = what the visit held
  SELECT count(*) INTO n FROM _s2 r JOIN public.visits v ON v.id = r.visit_id
    JOIN public.visit_time_on_site_corrections l ON l.visit_id = r.visit_id AND l.superseded_at IS NULL AND l.run_id = 'tos-recheck-2026-r2'
   WHERE r.skip IS NULL AND (
         (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh)
      OR (v.vehicle_id, v.visit_date, v.completed_at) IS DISTINCT FROM (l.new_vehicle_id, l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL
      OR (r.kind NOT IN ('relabel', 'relabel_card', 'change', 'change_card') AND (r.new_min, r.new_arr, r.new_dep, r.new_src) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src))
      OR (r.kind IN ('relabel', 'relabel_card') AND ((r.new_min, r.new_arr, r.new_dep) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep) OR r.cur_src IS NOT NULL OR r.new_src <> 'review'))
      OR (r.kind IN ('change', 'change_card') AND r.new_src <> 'review')
      OR (l.status = 'applied') <> (l.applied_at IS NOT NULL AND l.applied_by_migration = '2026-11-03_1300_time_on_site_s2_band_b.sql'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % rows do not hold their new value', n; END IF;
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections l JOIN _s2 r ON r.visit_id = l.visit_id
   WHERE l.run_id = 'tos-recheck-2026-r2' AND l.status = 'skipped_guard' AND (r.skip IS NULL OR l.superseded_at IS NULL);
  IF n > 0 OR (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r2' AND status = 'skipped_guard') <> nsk THEN
    RAISE EXCEPTION 'VERIFY S2: skipped rows not recorded as expected'; END IF;
  -- (c) shape on the written visits: all set, at most 719 min, minutes = departure - arrival within 1 min
  SELECT count(*) INTO n FROM _s2 r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.skip IS NULL AND r.kind IN ('relabel', 'relabel_card', 'change', 'change_card')
     AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
          OR v.actual_departure_at <= v.actual_arrival_at
          OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % written values fail the shape checks', n; END IF;
  -- (d) only the written visits changed, once each, only in the time columns, labelled; the ledger audited; nothing else
  a0 := (SELECT audit_id0 FROM _s2_ctx);
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> nw THEN RAISE EXCEPTION 'VERIFY S2: % audit rows on public.visits, expected %', n, nw; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _s2 WHERE skip IS NULL AND kind IN ('relabel', 'relabel_card', 'change', 'change_card'))
          OR a.operation <> 'UPDATE'
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % visit writes outside the set, outside the time columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visit_time_on_site_corrections';
  IF n <> 62 + (SELECT count(*) FROM _s2 WHERE skip IS NULL AND old_lid IS NOT NULL) THEN RAISE EXCEPTION 'VERIFY S2: % audit rows on the ledger', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % audit rows on other tables', n; END IF;
  -- (e) the controls are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, md5(to_jsonb(v)::text)) FROM public.visits v WHERE v.id IN (6509, 1240))
     IS DISTINCT FROM '{"1240": "e9ba7acf41f96121526a16787482d178", "6509": "0b47731ca0c0197aefa9ff6c8f3b8b2f"}'::jsonb THEN
    RAISE EXCEPTION 'VERIFY S2: a control visit changed'; END IF;
  -- (f) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT net_id0 FROM _s2_ctx) AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _s2);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S2: % Jobber requests queued', n; END IF;
  -- (g) no visit of the set shares time on its truck with a visit it did not share with before
  SELECT jsonb_object_agg(s.visit_id, x.other) INTO bad
    FROM public.v_visit_shared_time s CROSS JOIN LATERAL (SELECT (e->>'visit_id')::bigint AS other FROM jsonb_array_elements(s.shared_with) e) x
   WHERE s.visit_id IN (SELECT visit_id FROM _s2) AND s.shared_with_count > 0
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce((SELECT shared0 FROM _s2_ctx)->s.visit_id::text, '[]'::jsonb)) e0
                      WHERE (e0->>'visit_id')::bigint = x.other);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S2: new shared time on a truck: %', bad; END IF;
  -- (h) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT checks0 FROM _s2_ctx);
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY S2: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S2: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  -- (i) the rows are the ones the generator wrote (S2/build_s2.mjs)
  IF (SELECT md5(string_agg(concat_ws('|', visit_id, status, action, method, coalesce(new_min::text, '~'), coalesce(new_src, '~')), E'\n' ORDER BY visit_id)) FROM _s2)
     <> '1fec0f3c68c67299d5880c42843fc9f9' THEN RAISE EXCEPTION 'VERIFY S2: the row list is not the generated one'; END IF;
  RAISE NOTICE 'S2: % ledger rows (% applied, % proposed, % skipped), % visits written, checks %',
    62, (SELECT count(*) FROM _s2 WHERE skip IS NULL AND status = 'applied'), (SELECT count(*) FROM _s2 WHERE skip IS NULL AND status = 'proposed'), nsk, nw, ck - 'T_detail';
END $v$;

COMMIT;
