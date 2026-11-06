-- ============================================================================
-- 2026-11-06_1121_time_on_site_s4_band_a_cards  Visit duration re-check, stage S4: Fred's band A cards
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred approved the whole re-check plan on 2026-10-27 (samsara-checks/recheck_plan_2026-10-27/PLAN.md,
--   section 6.2, stage S4 on Fri 11-06). The band A page, 2026-11-05 ~09:15 ET: "yes, keep 25 on 6599". The plan, the
--   verdicts and the page are local (they name clients): run folder samsara-checks/duration_recheck_run_2026-10-28 (S4/).
--   Visit ids, minutes and times only here.
-- WHY
--   Band A (01-01 to 10-07) was settled by the 10-18 rows of run tos-fix-2026-r1. The 10-28 re-check measured it again with
--   two independent judges (T, trips; V2, the 1-second track), and Fred read the cards where they disagreed with the saved
--   time. The rule on the page: change a time only when both judges land on the same stay, a second kind of evidence backs
--   it (a photo time, a Jobber timer or a pump reading inside that stay, plan G-2), and no other visit shares that time.
--   Everything else keeps its saved time. The 10-18 rows are never edited in place (only superseded_at is set, PLAN G-7).
-- WHAT IS WRITTEN (33 ledger rows of run tos-recheck-2026-r4, param recheck-2026-10-28:v06c6bea1, stage person, status applied)
--   change_card 7, lock_card 17, relabel_card 1, keep_card 2, flag_card 6
--   change_card (7): the interval both judges measured, label stays review, method two_judges:stamp_pump. 3903 comes down
--     (its 205 held the stay of 3901 on the same truck); the other six go up.
--   lock_card (17): Fred's reopened locks (Q-G) that keep their minutes, action lock_decided, method card_keep_saved.
--     "The 22 lose the lock" on the page comes to this: T9 (S7, 11-16) fires on any completed visit over 10 days old with
--     no current applied or proposed row, and a current row IS the lock, so the 22 cannot end with no row. Q-G reopened
--     them for his decision and he has decided: 5 change above, these 17 get a new settled row saying so.
--   relabel_card (1): 6270 keeps 101, label NULL -> review only (as 5936 and 6523 in S2). Replaces its proposed blank.
--   keep_card (2): 5918 (96) and 8780 (26) keep their time. Replaces the proposed rows S2 left open for an answer.
--   flag_card (6): 1419, 3920, 5732, 5814, 7299, 7319 stay as they are (the last 4 stay blank). The open audit flag on each
--     closes in this transaction, resolved_note "Reviewed 2026-11-05, kept as is, no truck change".
-- WHAT CHANGES (visit  superseded row  kind  minutes  label)
--   1262  23    lock_card     100 -> 100     review -> review
--   1311  72    change_card   99 -> 117      review -> review  01-22 21:19 to 01-22 23:15 ET
--   1314  75    lock_card     90 -> 90       review -> review
--   1327  88    lock_card     98 -> 98       review -> review
--   1352  112   lock_card     110 -> 110     review -> review
--   1418  173   lock_card     73 -> 73       review -> review
--   1419  174   flag_card     6 -> 6         review -> review
--   1462  217   change_card   29 -> 67       review -> review  03-09 17:15 to 03-09 18:22 ET
--   1784  420   lock_card     25 -> 25       review -> review
--   1793  429   lock_card     44 -> 44       review -> review
--   3890  441   change_card   107 -> 178     review -> review  04-29 17:07 to 04-29 20:05 ET
--   3903  491   change_card   205 -> 55      review -> review  05-13 01:20 to 05-13 02:15 ET
--   3920  462   flag_card     61 -> 61       review -> review
--   3927  469   change_card   93 -> 117      review -> review  05-07 07:36 to 05-07 09:32 ET
--   5100  520   lock_card     129 -> 129     review -> review
--   5133  552   lock_card     65 -> 65       review -> review
--   5732  605   flag_card     blank -> blank NULL -> NULL
--   5734  607   lock_card     129 -> 129     review -> review
--   5802  668   change_card   28 -> 51       review -> review  06-16 10:46 to 06-16 11:37 ET
--   5814  680   flag_card     blank -> blank NULL -> NULL
--   5918  1769  keep_card     96 -> 96       stop_at_completion -> stop_at_completion
--   6270  1297  relabel_card  101 -> 101     NULL -> review
--   6399  1097  lock_card     100 -> 100     review -> review
--   6563  1185  lock_card     90 -> 90       review -> review
--   6645  1244  lock_card     33 -> 33       review -> review
--   7054  778   lock_card     29 -> 29       review -> review
--   7299  880   flag_card     blank -> blank NULL -> NULL
--   7319  881   flag_card     blank -> blank NULL -> NULL
--   7745  983   lock_card     191 -> 191     review -> review
--   7828  1046  lock_card     260 -> 260     review -> review
--   7843  1075  lock_card     57 -> 57       review -> review
--   8139  1215  change_card   29 -> 50       review -> review  09-16 14:20 to 09-16 15:10 ET
--   8780  1818  keep_card     26 -> 26       stop_at_completion -> stop_at_completion
--   Net minutes: +45 (a blank counted as 0). 8 visits written: 7 values, 1 label.
-- LEFT OUT ON PURPOSE
--   Every other visit on the page (their rows already stand). The blanks 1417, 6857, 7847, 8009, 5636 (each has a current
--   row, read this morning). 7828's truck question (Q-J): its flag stays open. Band C (5944, 6096, 6254): the nightly and S6.
-- THE ROW GUARD
--   Every visit must still hold exactly what the same-day read saw: its four time columns, truck, visit_date and
--   completed_at, completed and not deleted, the same max(visit_reviews.bonus_decided_at) (6270 and 6645 have a decided
--   bonus), the same current ledger row, and for a flag_card one open flag. Visits, ledger rows and flags are locked first
--   (FOR UPDATE). A moved row is skipped, recorded as a 'skipped_guard' row (superseded at once, so its old row stays
--   current), never forced; more than 3 skipped rows stop the file.
-- PIN: the md5 of fn_time_on_site_checks (S1 body), the two fillers, the reopen trigger function, the Jobber push and
--   sync-pending trigger functions, audit.log_change and log_truck_gps_health; the 33 current rows (md5
--   60f22d4918c6c62d9dbd698c44f1ac13 of the ordered row text without evidence, input_hashes and alternatives); no row of run
--   tos-recheck-2026-r4 (a second run refuses). Evidence: verdicts.json sha256 06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700, recommendations.md sha256 ebfcf3b126f27553e88fa86a2921168a13e804fcb327216f2ab8b75102c19a42.
-- WHAT DOES NOT CHANGE
--   vehicle_id, visit_date, start_at, end_at, visit_status, deleted_at, sync_state, the schedule: the VERIFY reads every
--   audit row of this transaction and allows only the four time columns (and updated_at) on the 8 written visits.
--   Nothing goes to Jobber (the push trigger does not list the time columns; asserted on net.http_request_queue).
--   No truck change, so no relink: tank, water and Grease pumped do not move.
-- CONSEQUENCES (measured in the rolled-back rehearsal, S4/rehearse.mjs p)
--   Calendar Hours worked (ops.calendar_hours_estimates, every day of 2026 and the next 45 days): the 7 changed visits only,
--     1311 99 -> 117, 1462 29 -> 67, 3890 107 -> 178, 3903 205 -> 55, 3927 93 -> 117, 5802 28 -> 51, 8139 29 -> 50; the
--     average of one upcoming visit moves, 6239 95 -> 70 (the client of 3903).
--   v_visit_tank_service: time_on_site_disagreement true -> false on 8139 (stops 53.5 min); duration_minutes as above; every
--     other column of every row unchanged (hash). F7 106 -> 105 (8139). 6270 stays flagged (stops 162, keeps 101, Fred's card).
--   Shared time: 3903 loses its overlap with 3901; no new overlap on any of the 33. Open audit flags 7 -> 1 (7828).
--   Unchanged: ops.visit_grease_frozen, every other completed visit's time, v_visit_stop_reference (479 rows), T1 to T8 (all 0).
-- LABEL: x-app-source time-on-site-recheck-2026, one reason for the transaction.
-- VERIFY: 33 rows, one current row per visit; every row holds its value, truck, date and completion; shape checks; only
--   the 8 visits, only the time columns, labelled; the ledger and the 6 flags audited, no other table; the 6 flags closed
--   with the note and 7828's still open; controls 6509 and 1240 byte-identical; no Jobber push; no new shared time; T1 to
--   T8 not newly failing, T7 = T8 = 0; the row list's md5.
-- REHEARSED (S4/rehearse.mjs, local; every run rolled back)
--   (a) as written: pass (2.3 s). (p) the consumer diff above. (b) 5918 (a proposed row) moved before the guard: skipped and
--   recorded as skipped_guard, its old row stays current, the other 32 pass. (b7) 1262 (an applied row) moved: T7 stands, so
--   the file stops, which is the safer answer for a visit whose settled value changed. (b4) four moved: the file stops,
--   nothing written. (c) the 33-row checksum altered: the file raises. (r) the rollback on top: visits, earlier rows and flags
--   byte-identical to before S4, no current row of the run, T1 to T8 0. (ra) the rollback alone: refuses.
-- LOCKS: lock_timeout 3s. Apply 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20, :30 to :45 (PLAN G-9).
-- ROLLBACK: docs/migrations/2026-11-06_rollback_time_on_site_s4_band_a_cards.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN: the bodies this file relies on, the 33 current rows it supersedes, and no earlier run of this file.
DO $pin$ DECLARE n int; c text; BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S4: % is not the S1 body', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> '624d5e168bbc7745ad9af73ac1c03c41' THEN
    RAISE EXCEPTION 'S4: % moved', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> '2c2f358c93aac5a89dd826142284e116' THEN
    RAISE EXCEPTION 'S4: % moved', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure)) <> 'c38d5a5ed8c5b9f1bfa99c3bf2321638' THEN
    RAISE EXCEPTION 'S4: % moved', 'fn_clear_time_on_site_on_reopen()'; END IF;
  IF md5(pg_get_functiondef('public.fn_push_visit_to_jobber()'::regprocedure)) <> 'a6512e3f1b2cb2de0fddd39bb3679fbe' THEN
    RAISE EXCEPTION 'S4: % moved', 'fn_push_visit_to_jobber()'; END IF;
  IF md5(pg_get_functiondef('public.fn_mark_visit_sync_pending()'::regprocedure)) <> 'f607c3772a444f8fe275380e44651fb4' THEN
    RAISE EXCEPTION 'S4: % moved', 'fn_mark_visit_sync_pending()'; END IF;
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'ce7784f65675e10a0c2a13f853ce0acc' THEN
    RAISE EXCEPTION 'S4: % moved', 'audit.log_change()'; END IF;
  IF md5(pg_get_functiondef('public.log_truck_gps_health()'::regprocedure)) <> 'cd9b3e5f3bd7f969a14417fc2c3763e6' THEN
    RAISE EXCEPTION 'S4: % moved', 'log_truck_gps_health()'; END IF;
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.visit_id = ANY (ARRAY[1262,1311,1314,1327,1352,1418,1419,1462,1784,1793,3890,3903,3920,3927,5100,5133,5732,5734,5802,5814,5918,6270,6399,6563,6645,7054,7299,7319,7745,7828,7843,8139,8780]::bigint[]);
  IF n <> 33 OR c IS DISTINCT FROM '60f22d4918c6c62d9dbd698c44f1ac13' THEN
    RAISE EXCEPTION 'S4: % current rows, checksum %; expected 33, 60f22d4918c6c62d9dbd698c44f1ac13 (already applied, or a row moved: re-read and re-rehearse)', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r4') THEN
    RAISE EXCEPTION 'S4: run tos-recheck-2026-r4 already has rows'; END IF;
END $pin$;

-- 1. The rows: visit, the row it supersedes, kind, what the visit holds now (guard), the new values, the ledger labels.
CREATE TEMP TABLE _s4 ON COMMIT DROP AS
SELECT t.*, NULL::text AS skip FROM (VALUES
  (1311, 72::bigint, 'change_card', 99, timestamptz '2026-01-23T02:37:08+00:00', timestamptz '2026-01-23T04:15:50+00:00', 'review', 2, date '2026-01-22', timestamptz '2026-01-23T06:41:36+00:00', NULL::timestamptz, 117, timestamptz '2026-01-23T02:19:05.021Z', timestamptz '2026-01-23T04:15:50.014Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_1311', '{"s4_kind":"change_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":true,"measured":{"minutes":117,"parts":[["2026-01-23T02:19:05.021Z","2026-01-23T04:15:50.014Z"]]}}'::jsonb),
  (1462, 217::bigint, 'change_card', 29, timestamptz '2026-03-09T21:25:13.014+00:00', timestamptz '2026-03-09T21:54:09.057+00:00', 'review', 2, date '2026-03-09', timestamptz '2026-03-11T15:19:21+00:00', NULL::timestamptz, 67, timestamptz '2026-03-09T21:15:21.034Z', timestamptz '2026-03-09T22:22:27.060Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_1462', '{"s4_kind":"change_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_38_min","card":true,"measured":{"minutes":67,"parts":[["2026-03-09T21:15:21.034Z","2026-03-09T22:22:27.060Z"]]}}'::jsonb),
  (3890, 441::bigint, 'change_card', 107, timestamptz '2026-04-29T21:13:59.041+00:00', timestamptz '2026-04-29T23:01:07.106+00:00', 'review', 2, date '2026-04-29', timestamptz '2026-05-01T15:02:36+00:00', NULL::timestamptz, 178, timestamptz '2026-04-29T21:07:11.012Z', timestamptz '2026-04-30T00:05:13.015Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_3890', '{"s4_kind":"change_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_71_min","card":true,"measured":{"minutes":178,"parts":[["2026-04-29T21:07:11.012Z","2026-04-30T00:05:13.015Z"]]}}'::jsonb),
  (3903, 491::bigint, 'change_card', 205, timestamptz '2026-05-13T02:53:29+00:00', timestamptz '2026-05-13T06:18:15+00:00', 'review', 1, date '2026-05-12', timestamptz '2026-05-13T06:32:52+00:00', NULL::timestamptz, 55, timestamptz '2026-05-13T05:20:26.447Z', timestamptz '2026-05-13T06:15:48.423Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_3903', '{"s4_kind":"change_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_150_min","card":true,"measured":{"minutes":55,"parts":[["2026-05-13T05:20:26.447Z","2026-05-13T06:15:48.423Z"]]}}'::jsonb),
  (3927, 469::bigint, 'change_card', 93, timestamptz '2026-05-07T11:36:01+00:00', timestamptz '2026-05-07T13:08:42+00:00', 'review', 1, date '2026-05-06', timestamptz '2026-05-07T13:06:55+00:00', NULL::timestamptz, 117, timestamptz '2026-05-07T11:36:01.297Z', timestamptz '2026-05-07T13:32:40.506Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_3927', '{"s4_kind":"change_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":true,"measured":{"minutes":117,"parts":[["2026-05-07T11:36:01.297Z","2026-05-07T13:32:40.506Z"]]}}'::jsonb),
  (5802, 668::bigint, 'change_card', 28, timestamptz '2026-06-16T15:09:01.138+00:00', timestamptz '2026-06-16T15:37:14.641+00:00', 'review', 3, date '2026-06-16', timestamptz '2026-06-18T13:45:33+00:00', NULL::timestamptz, 51, timestamptz '2026-06-16T14:46:14.287Z', timestamptz '2026-06-16T15:37:14.641Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_5802', '{"s4_kind":"change_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_23_min","card":true,"measured":{"minutes":51,"parts":[["2026-06-16T14:46:14.287Z","2026-06-16T15:37:14.641Z"]]}}'::jsonb),
  (8139, 1215::bigint, 'change_card', 29, timestamptz '2026-09-16T18:41:48.519+00:00', timestamptz '2026-09-16T19:10:27.515+00:00', 'review', 2, date '2026-09-16', timestamptz '2026-09-16T19:28:12+00:00', NULL::timestamptz, 50, timestamptz '2026-09-16T18:20:55.509Z', timestamptz '2026-09-16T19:10:27.515Z', 'review', 'applied', 'change', 'two_judges:stamp_pump', 'person', 'fred:2026-11-05:card_8139', '{"s4_kind":"change_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_21_min","card":true,"measured":{"minutes":50,"parts":[["2026-09-16T18:20:55.509Z","2026-09-16T19:10:27.515Z"]]}}'::jsonb),
  (1262, 23::bigint, 'lock_card', 100, timestamptz '2026-01-08T00:51:13.032+00:00', timestamptz '2026-01-08T02:31:13.023+00:00', 'review', 3, date '2026-01-07', timestamptz '2026-01-08T02:09:06+00:00', NULL::timestamptz, 100, timestamptz '2026-01-08T00:51:13.032+00:00', timestamptz '2026-01-08T02:31:13.023+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1262', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":79,"parts":[["2026-01-08T00:51:13.032Z","2026-01-08T02:10:00.000Z"]]}}'::jsonb),
  (1314, 75::bigint, 'lock_card', 90, timestamptz '2026-01-23T08:11:14.035+00:00', timestamptz '2026-01-23T09:41:09.022+00:00', 'review', 3, date '2026-01-22', timestamptz '2026-01-23T08:44:15+00:00', NULL::timestamptz, 90, timestamptz '2026-01-23T08:11:14.035+00:00', timestamptz '2026-01-23T09:41:09.022+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1314', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":30,"parts":[["2026-01-23T08:11:14.035Z","2026-01-23T08:40:57.000Z"]]}}'::jsonb),
  (1327, 88::bigint, 'lock_card', 98, timestamptz '2026-01-28T10:48:21.008+00:00', timestamptz '2026-01-28T12:26:11.038+00:00', 'review', 3, date '2026-01-28', timestamptz '2026-01-28T22:21:25+00:00', NULL::timestamptz, 98, timestamptz '2026-01-28T10:48:21.008+00:00', timestamptz '2026-01-28T12:26:11.038+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1327', '{"s4_kind":"lock_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_63_min","card":true,"measured":{"minutes":161,"parts":[["2026-01-28T10:48:21.008Z","2026-01-28T13:29:02.046Z"]]}}'::jsonb),
  (1352, 112::bigint, 'lock_card', 110, timestamptz '2026-02-05T02:06:25+00:00', timestamptz '2026-02-05T03:56:06.038+00:00', 'review', 3, date '2026-02-04', timestamptz '2026-02-05T03:48:33+00:00', NULL::timestamptz, 110, timestamptz '2026-02-05T02:06:25+00:00', timestamptz '2026-02-05T03:56:06.038+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1352', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":39,"parts":[["2026-02-04T05:36:38.013Z","2026-02-04T06:15:23.051Z"]]}}'::jsonb),
  (1418, 173::bigint, 'lock_card', 73, timestamptz '2026-02-24T19:47:54+00:00', timestamptz '2026-02-24T21:00:24.02+00:00', 'review', 3, date '2026-02-24', timestamptz '2026-02-25T12:39:08+00:00', NULL::timestamptz, 73, timestamptz '2026-02-24T19:47:54+00:00', timestamptz '2026-02-24T21:00:24.02+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1418', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":69,"parts":[["2026-02-25T10:02:03.076Z","2026-02-25T11:10:44.014Z"]]}}'::jsonb),
  (1784, 420::bigint, 'lock_card', 25, timestamptz '2026-04-27T11:17:28.273+00:00', timestamptz '2026-04-27T11:42:50.493+00:00', 'review', 1, date '2026-04-26', timestamptz '2026-04-27T11:42:22+00:00', NULL::timestamptz, 25, timestamptz '2026-04-27T11:17:28.273+00:00', timestamptz '2026-04-27T11:42:50.493+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1784', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":false,"measured":{"minutes":33,"parts":[["2026-04-27T11:09:55.044Z","2026-04-27T11:42:50.493Z"]]}}'::jsonb),
  (1793, 429::bigint, 'lock_card', 44, timestamptz '2026-04-28T20:37:15.069+00:00', timestamptz '2026-04-28T21:20:56.141+00:00', 'review', 2, date '2026-04-28', timestamptz '2026-04-29T00:15:35+00:00', NULL::timestamptz, 44, timestamptz '2026-04-28T20:37:15.069+00:00', timestamptz '2026-04-28T21:20:56.141+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1793', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":true,"measured":{"minutes":13,"parts":[["2026-04-28T20:37:15.069Z","2026-04-28T20:49:52.000Z"]]}}'::jsonb),
  (5100, 520::bigint, 'lock_card', 129, timestamptz '2026-05-18T06:44:57.549+00:00', timestamptz '2026-05-18T08:53:50.242+00:00', 'review', 1, date '2026-05-17', timestamptz '2026-05-18T08:51:52+00:00', NULL::timestamptz, 129, timestamptz '2026-05-18T06:44:57.549+00:00', timestamptz '2026-05-18T08:53:50.242+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5100', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":135,"parts":[["2026-05-18T06:32:11.551Z","2026-05-18T08:47:22.000Z"]]}}'::jsonb),
  (5133, 552::bigint, 'lock_card', 65, timestamptz '2026-05-23T15:04:49.275+00:00', timestamptz '2026-05-23T16:10:14.147+00:00', 'review', 2, date '2026-05-23', timestamptz '2026-05-23T17:07:18+00:00', NULL::timestamptz, 65, timestamptz '2026-05-23T15:04:49.275+00:00', timestamptz '2026-05-23T16:10:14.147+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5133', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":80,"parts":[["2026-05-23T15:04:49.275Z","2026-05-23T16:24:53.519Z"]]}}'::jsonb),
  (5734, 607::bigint, 'lock_card', 129, timestamptz '2026-06-03T18:48:29.476+00:00', timestamptz '2026-06-03T20:57:52.503+00:00', 'review', 2, date '2026-06-03', timestamptz '2026-06-03T21:17:44+00:00', NULL::timestamptz, 129, timestamptz '2026-06-03T18:48:29.476+00:00', timestamptz '2026-06-03T20:57:52.503+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5734', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":23,"parts":[["2026-06-03T18:48:29.476Z","2026-06-03T19:11:19.000Z"]]}}'::jsonb),
  (6399, 1097::bigint, 'lock_card', 100, timestamptz '2026-09-02T05:09:09.564+00:00', timestamptz '2026-09-02T06:48:42.511+00:00', 'review', 1, date '2026-09-01', timestamptz '2026-09-02T06:43:14+00:00', NULL::timestamptz, 100, timestamptz '2026-09-02T05:09:09.564+00:00', timestamptz '2026-09-02T06:48:42.511+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_6399', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":false,"measured":{"minutes":106,"parts":[["2026-09-02T05:02:17.509Z","2026-09-02T06:48:42.511Z"]]}}'::jsonb),
  (6563, 1185::bigint, 'lock_card', 90, timestamptz '2026-09-12T04:03:53+00:00', timestamptz '2026-09-12T05:34:04+00:00', 'review', 1, date '2026-09-11', timestamptz '2026-09-12T04:43:50+00:00', NULL::timestamptz, 90, timestamptz '2026-09-12T04:03:53+00:00', timestamptz '2026-09-12T05:34:04+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_6563', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":40,"parts":[["2026-09-12T04:04:46.496Z","2026-09-12T04:44:41.000Z"]]}}'::jsonb),
  (6645, 1244::bigint, 'lock_card', 33, timestamptz '2026-09-24T09:31:36.51+00:00', timestamptz '2026-09-24T10:04:36.511+00:00', 'review', 1, date '2026-09-23', timestamptz '2026-09-24T10:02:45+00:00', timestamptz '2026-09-25T13:23:22.703+00:00', 33, timestamptz '2026-09-24T09:31:36.51+00:00', timestamptz '2026-09-24T10:04:36.511+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_6645', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":true,"measured":{"minutes":45,"parts":[["2026-09-24T09:31:36.510Z","2026-09-24T10:16:19.554Z"]]}}'::jsonb),
  (7054, 778::bigint, 'lock_card', 29, timestamptz '2026-07-07T17:11:15.515+00:00', timestamptz '2026-07-07T17:39:54.51+00:00', 'review', 2, date '2026-07-07', timestamptz '2026-07-07T17:39:33+00:00', NULL::timestamptz, 29, timestamptz '2026-07-07T17:11:15.515+00:00', timestamptz '2026-07-07T17:39:54.51+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7054', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"judges_differ","card":false,"measured":{"minutes":9,"parts":[["2026-07-07T17:11:15.515Z","2026-07-07T17:20:34.000Z"]]}}'::jsonb),
  (7745, 983::bigint, 'lock_card', 191, timestamptz '2026-08-11T19:18:43.51+00:00', timestamptz '2026-08-11T22:29:30.524+00:00', 'review', 2, date '2026-08-11', timestamptz '2026-08-12T14:06:04+00:00', NULL::timestamptz, 191, timestamptz '2026-08-11T19:18:43.51+00:00', timestamptz '2026-08-11T22:29:30.524+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7745', '{"s4_kind":"lock_card","verdict":"UNSETTLED","reason":"C7_flip:V2 minimum parking 4 min","card":true,"measured":{"minutes":131,"parts":[["2026-08-11T18:02:00.513Z","2026-08-11T20:13:28.000Z"]]}}'::jsonb),
  (7828, 1046::bigint, 'lock_card', 260, timestamptz '2026-08-20T10:21:02+00:00', timestamptz '2026-08-20T14:41:21+00:00', 'review', 1, date '2026-08-20', timestamptz '2026-08-20T19:55:32+00:00', NULL::timestamptz, 260, timestamptz '2026-08-20T10:21:02+00:00', timestamptz '2026-08-20T14:41:21+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7828', '{"s4_kind":"lock_card","verdict":"LOCKED_DIFFERS","reason":"sibling_set_contradicts_fred_row_by_68_min","card":true,"measured":{"minutes":192,"parts":[["2026-08-20T02:38:45.547Z","2026-08-20T05:51:09.529Z"]]}}'::jsonb),
  (7843, 1075::bigint, 'lock_card', 57, timestamptz '2026-08-26T15:45:19.513+00:00', timestamptz '2026-08-26T16:42:38.522+00:00', 'review', 2, date '2026-08-26', timestamptz '2026-08-26T16:42:58+00:00', NULL::timestamptz, 57, timestamptz '2026-08-26T15:45:19.513+00:00', timestamptz '2026-08-26T16:42:38.522+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7843', '{"s4_kind":"lock_card","verdict":"LOCKED_DIFFERS","reason":"two_families_contradict_fred_row_by_63_min","card":true,"measured":{"minutes":120,"parts":[["2026-08-26T15:45:19.513Z","2026-08-26T17:45:16.512Z"]]}}'::jsonb),
  (6270, 1297::bigint, 'relabel_card', 101, timestamptz '2026-10-03T03:44:13+00:00', timestamptz '2026-10-03T05:25:30+00:00', NULL, 1, date '2026-10-02', timestamptz '2026-10-06T15:41:16+00:00', timestamptz '2026-10-06T19:42:00.481+00:00', 101, timestamptz '2026-10-03T03:44:13+00:00', timestamptz '2026-10-03T05:25:30+00:00', 'review', 'applied', 'relabel', 'card_keep_saved', 'person', 'fred:2026-11-05:card_6270', '{"s4_kind":"relabel_card","verdict":"UNSETTLED","reason":"T_unclaimed_several_own_intervals_no_tap_claim","card":true,"measured":null}'::jsonb),
  (5918, 1769::bigint, 'keep_card', 96, timestamptz '2026-10-14T07:20:39+00:00', timestamptz '2026-10-14T08:56:13+00:00', 'stop_at_completion', 1, date '2026-10-13', timestamptz '2026-10-14T08:54:12+00:00', NULL::timestamptz, 96, timestamptz '2026-10-14T07:20:39+00:00', timestamptz '2026-10-14T08:56:13+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5918', '{"s4_kind":"keep_card","verdict":"UNSETTLED","reason":"V2_several","card":true,"measured":null}'::jsonb),
  (8780, 1818::bigint, 'keep_card', 26, timestamptz '2026-10-14T12:47:31+00:00', timestamptz '2026-10-14T13:13:33+00:00', 'stop_at_completion', 2, date '2026-10-14', timestamptz '2026-10-14T13:12:29+00:00', NULL::timestamptz, 26, timestamptz '2026-10-14T12:47:31+00:00', timestamptz '2026-10-14T13:13:33+00:00', 'stop_at_completion', 'applied', 'keep_verified', 'card_keep_saved', 'person', 'fred:2026-11-05:card_8780', '{"s4_kind":"keep_card","verdict":"UNSETTLED","reason":"V2_several","card":true,"measured":null}'::jsonb),
  (1419, 174::bigint, 'flag_card', 6, timestamptz '2026-02-25T18:36:03.013+00:00', timestamptz '2026-02-25T18:42:17.023+00:00', 'review', 2, date '2026-02-25', timestamptz '2026-02-26T11:15:41+00:00', NULL::timestamptz, 6, timestamptz '2026-02-25T18:36:03.013+00:00', timestamptz '2026-02-25T18:42:17.023+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_1419', '{"s4_kind":"flag_card","verdict":"UNSETTLED","reason":"C3_band_A_fails","card":true,"measured":{"minutes":6,"parts":[["2026-02-25T18:36:03.013Z","2026-02-25T18:42:17.023Z"]]}}'::jsonb),
  (3920, 462::bigint, 'flag_card', 61, timestamptz '2026-05-05T03:02:03.135+00:00', timestamptz '2026-05-05T04:02:39.172+00:00', 'review', 1, date '2026-05-05', timestamptz '2026-05-05T14:33:06+00:00', NULL::timestamptz, 61, timestamptz '2026-05-05T03:02:03.135+00:00', timestamptz '2026-05-05T04:02:39.172+00:00', 'review', 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_3920', '{"s4_kind":"flag_card","verdict":"UNSETTLED","reason":"same_client_ambiguous","card":true,"measured":null}'::jsonb),
  (5732, 605::bigint, 'flag_card', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, date '2026-06-03', timestamptz '2026-06-03T21:27:58+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5732', '{"s4_kind":"flag_card","verdict":"TRUCK_QUESTION","reason":"other_truck_at_site","card":true,"measured":null}'::jsonb),
  (5814, 680::bigint, 'flag_card', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, date '2026-06-18', timestamptz '2026-06-18T21:54:01+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_5814', '{"s4_kind":"flag_card","verdict":"TRUCK_QUESTION","reason":"other_truck_at_site","card":true,"measured":null}'::jsonb),
  (7299, 880::bigint, 'flag_card', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, date '2026-07-24', timestamptz '2026-07-23T20:12:25+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7299', '{"s4_kind":"flag_card","verdict":"TRUCK_QUESTION","reason":"other_truck_at_site","card":true,"measured":null}'::jsonb),
  (7319, 881::bigint, 'flag_card', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, date '2026-07-24', timestamptz '2026-07-24T16:15:12+00:00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'applied', 'lock_decided', 'card_keep_saved', 'person', 'fred:2026-11-05:card_7319', '{"s4_kind":"flag_card","verdict":"UNSETTLED","reason":"C7_flip:V2 minimum parking 4 min","card":true,"measured":null}'::jsonb)
) AS t(visit_id, old_lid, kind, cur_min, cur_arr, cur_dep, cur_src, cur_veh, cur_date, cur_comp, cur_bonus,
       new_min, new_arr, new_dep, new_src, status, action, method, confidence, decision_ref, evidence);

CREATE TEMP TABLE _s4_ctx ON COMMIT DROP AS
SELECT (SELECT max(id) FROM audit.logs) AS audit_id0,
       (SELECT coalesce(max(id), 0) FROM net.http_request_queue) AS net_id0,
       public.fn_time_on_site_checks() AS checks0,
       (SELECT count(*) FROM public.visit_audit_flags WHERE resolved_at IS NULL) AS open_flags0,
       (SELECT jsonb_object_agg(s.visit_id, s.shared_with) FROM public.v_visit_shared_time s
         WHERE s.visit_id IN (SELECT visit_id FROM _s4) AND s.shared_with_count > 0) AS shared0;

-- 2. Lock, then the guard: a row that moved since the morning read is skipped (recorded as skipped_guard), never forced.
DO $lock$ DECLARE nskip int; BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _s4) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (SELECT visit_id FROM _s4) AND l.superseded_at IS NULL FOR UPDATE;
  PERFORM 1 FROM public.visit_audit_flags f WHERE f.visit_id IN (SELECT visit_id FROM _s4 WHERE kind = 'flag_card') AND f.resolved_at IS NULL FOR UPDATE;
  IF (SELECT count(*) FROM _s4) <> 33 OR (SELECT count(DISTINCT visit_id) FROM _s4) <> 33 THEN RAISE EXCEPTION 'S4: row list is not 33 distinct visits'; END IF;
  UPDATE _s4 r SET skip = CASE
      WHEN v.id IS NULL THEN 'missing'
      WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
      WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
      WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
      WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (r.cur_date, r.cur_comp) THEN 'date_or_completion_moved'
      WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM r.cur_bonus THEN 'bonus_decided'
      WHEN (SELECT l.id FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) IS DISTINCT FROM r.old_lid THEN 'ledger_row_not_current'
      WHEN r.kind = 'flag_card' AND (SELECT count(*) FROM public.visit_audit_flags f WHERE f.visit_id = r.visit_id AND f.resolved_at IS NULL) <> 1 THEN 'flag_moved'
    END
    FROM _s4 r0 LEFT JOIN public.visits v ON v.id = r0.visit_id
   WHERE r0.visit_id = r.visit_id;
  SELECT count(*) INTO nskip FROM _s4 WHERE skip IS NOT NULL;
  IF nskip > 3 THEN RAISE EXCEPTION 'S4: % rows moved since they were read, nothing written: %', nskip,
    (SELECT jsonb_object_agg(visit_id, skip) FROM _s4 WHERE skip IS NOT NULL); END IF;
  IF nskip > 0 THEN RAISE NOTICE 'S4: skipped (moved since read): %', (SELECT jsonb_object_agg(visit_id, skip) FROM _s4 WHERE skip IS NOT NULL); END IF;
END $lock$;

-- 3. Ledger first (supersede, then insert run tos-recheck-2026-r4), then the visits and the flags, in the same transaction, labelled.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Visit duration re-check, stage S4 (band A cards), run tos-recheck-2026-r4: Fred''s approved page of 2026-11-05. Method, evidence and decision per visit in public.visit_time_on_site_corrections. Not pushed to Jobber.'))::text, true);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now()
    FROM _s4 r WHERE r.skip IS NULL AND l.id = r.old_lid AND l.superseded_at IS NULL;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _s4 WHERE skip IS NULL) THEN RAISE EXCEPTION 'S4: superseded % rows, expected %', n, (SELECT count(*) FROM _s4 WHERE skip IS NULL); END IF;
  INSERT INTO public.visit_time_on_site_corrections
    (visit_id, run_id, param_version, input_hashes, old_vehicle_id, new_vehicle_id, stage, action, status, superseded_at,
     old_arrival, old_departure, old_minutes, old_source, old_visit_date, old_completed_at, bonus_decided_at_seen,
     new_arrival, new_departure, new_minutes, new_source, method, confidence, decision_ref, evidence, evidence_file_sha256,
     applied_at, applied_by_migration)
  SELECT r.visit_id, 'tos-recheck-2026-r4', 'recheck-2026-10-28:v06c6bea1',
         jsonb_build_object('verdicts_json_sha256', '06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700', 'recommendations_md_sha256', 'ebfcf3b126f27553e88fa86a2921168a13e804fcb327216f2ab8b75102c19a42', 'freeze', 'c29053ed'),
         r.cur_veh, r.cur_veh, 'person', r.action,
         CASE WHEN r.skip IS NULL THEN r.status ELSE 'skipped_guard' END,
         CASE WHEN r.skip IS NULL THEN NULL ELSE now() END,
         r.cur_arr, r.cur_dep, r.cur_min, r.cur_src, r.cur_date, r.cur_comp, r.cur_bonus,
         r.new_arr, r.new_dep, r.new_min, r.new_src, r.method, r.confidence, r.decision_ref,
         r.evidence || jsonb_build_object('superseded_row_id', r.old_lid, 'skip', r.skip),
         '06c6bea10c68db35e79c3550162531c7004fd26c9ce65b08be6048065f17c700',
         CASE WHEN r.skip IS NULL AND r.status = 'applied' THEN now() END,
         CASE WHEN r.skip IS NULL AND r.status = 'applied' THEN '2026-11-06_1121_time_on_site_s4_band_a_cards.sql' END
    FROM _s4 r ORDER BY r.visit_id;
  GET DIAGNOSTICS n = row_count;
  IF n <> 33 THEN RAISE EXCEPTION 'S4: inserted % ledger rows, expected 33', n; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep, time_on_site_source = r.new_src
    FROM _s4 r WHERE v.id = r.visit_id AND r.skip IS NULL AND r.kind IN ('relabel_card', 'change_card');
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind IN ('relabel_card', 'change_card')) THEN
    RAISE EXCEPTION 'S4: wrote % visits, expected %', n, (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind IN ('relabel_card', 'change_card')); END IF;
  UPDATE public.visit_audit_flags f SET resolved_at = now(), resolved_note = 'Reviewed 2026-11-05, kept as is, no truck change'
    FROM _s4 r WHERE f.visit_id = r.visit_id AND r.skip IS NULL AND r.kind = 'flag_card' AND f.resolved_at IS NULL;
  GET DIAGNOSTICS n = row_count;
  IF n <> (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind = 'flag_card') THEN
    RAISE EXCEPTION 'S4: closed % flags, expected %', n, (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind = 'flag_card'); END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint; ck jsonb; ck0 jsonb; t text; bad jsonb; nw int; nsk int; nfl int;
BEGIN
  nsk := (SELECT count(*) FROM _s4 WHERE skip IS NOT NULL);
  nw := (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind IN ('relabel_card', 'change_card'));
  nfl := (SELECT count(*) FROM _s4 WHERE skip IS NULL AND kind = 'flag_card');
  -- (a) the rows: 33 of the run, one current row per visit (its new row, or for a skipped visit its old row)
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r4';
  IF n <> 33 THEN RAISE EXCEPTION 'VERIFY S4: % rows of the run, expected 33', n; END IF;
  SELECT count(*) INTO n FROM _s4 r
   WHERE (SELECT count(*) FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) <> 1
      OR (r.skip IS NULL AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL
                                           AND l.run_id = 'tos-recheck-2026-r4' AND l.status = r.status AND l.stage = 'person'))
      OR (r.skip IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.id = r.old_lid AND l.superseded_at IS NULL));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % visits without the expected current row', n; END IF;
  -- (b) every passing row: the visit holds the new value, the ledger row holds it, its truck, date and completion;
  --     a kind that writes nothing has new = what the visit held
  SELECT count(*) INTO n FROM _s4 r JOIN public.visits v ON v.id = r.visit_id
    JOIN public.visit_time_on_site_corrections l ON l.visit_id = r.visit_id AND l.superseded_at IS NULL AND l.run_id = 'tos-recheck-2026-r4'
   WHERE r.skip IS NULL AND (
         (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh)
      OR (v.vehicle_id, v.visit_date, v.completed_at) IS DISTINCT FROM (l.new_vehicle_id, l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL
      OR (r.kind NOT IN ('relabel_card', 'change_card') AND (r.new_min, r.new_arr, r.new_dep, r.new_src) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src))
      OR (r.kind = 'relabel_card' AND ((r.new_min, r.new_arr, r.new_dep) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep) OR r.cur_src IS NOT NULL OR r.new_src <> 'review'))
      OR (r.kind = 'change_card' AND (r.new_src <> 'review' OR r.cur_src <> 'review'))
      OR (l.status = 'applied') <> (l.applied_at IS NOT NULL AND l.applied_by_migration = '2026-11-06_1121_time_on_site_s4_band_a_cards.sql'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % rows do not hold their new value', n; END IF;
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections l JOIN _s4 r ON r.visit_id = l.visit_id
   WHERE l.run_id = 'tos-recheck-2026-r4' AND l.status = 'skipped_guard' AND (r.skip IS NULL OR l.superseded_at IS NULL);
  IF n > 0 OR (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-recheck-2026-r4' AND status = 'skipped_guard') <> nsk THEN
    RAISE EXCEPTION 'VERIFY S4: skipped rows not recorded as expected'; END IF;
  -- (c) shape on the written visits: all set, at most 719 min, minutes = departure - arrival within 1 min
  SELECT count(*) INTO n FROM _s4 r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.skip IS NULL AND r.kind IN ('relabel_card', 'change_card')
     AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
          OR v.actual_departure_at <= v.actual_arrival_at
          OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % written values fail the shape checks', n; END IF;
  -- (d) only the written visits changed, once each, only in the time columns, labelled; the ledger and the 6 flags audited; nothing else
  a0 := (SELECT audit_id0 FROM _s4_ctx);
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> nw THEN RAISE EXCEPTION 'VERIFY S4: % audit rows on public.visits, expected %', n, nw; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _s4 WHERE skip IS NULL AND kind IN ('relabel_card', 'change_card'))
          OR a.operation <> 'UPDATE'
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % visit writes outside the set, outside the time columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visit_time_on_site_corrections';
  IF n <> 33 + (SELECT count(*) FROM _s4 WHERE skip IS NULL) THEN RAISE EXCEPTION 'VERIFY S4: % audit rows on the ledger', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visit_audit_flags';
  IF n <> nfl THEN RAISE EXCEPTION 'VERIFY S4: % audit rows on the flags, expected %', n, nfl; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visit_audit_flags'
     AND (a.operation <> 'UPDATE' OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026'
          OR (a.old_row - ARRAY['resolved_at', 'resolved_note']) IS DISTINCT FROM (a.new_row - ARRAY['resolved_at', 'resolved_note'])
          OR (a.new_row->>'visit_id')::bigint NOT IN (SELECT visit_id FROM _s4 WHERE skip IS NULL AND kind = 'flag_card'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % flag writes outside the six, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'), ('public', 'visit_audit_flags'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % audit rows on other tables', n; END IF;
  -- (d2) the flags: each closed with the note, the open count down by exactly that many, 7828's truck question still open
  SELECT count(*) INTO n FROM _s4 r WHERE r.skip IS NULL AND r.kind = 'flag_card'
     AND NOT EXISTS (SELECT 1 FROM public.visit_audit_flags f WHERE f.visit_id = r.visit_id AND f.resolved_at = now() AND f.resolved_note = 'Reviewed 2026-11-05, kept as is, no truck change');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % flags not closed with the note', n; END IF;
  IF (SELECT count(*) FROM public.visit_audit_flags WHERE resolved_at IS NULL) <> (SELECT open_flags0 FROM _s4_ctx) - nfl THEN RAISE EXCEPTION 'VERIFY S4: the open flag count moved by more than the six'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_audit_flags WHERE visit_id = 7828 AND resolved_at IS NULL) THEN RAISE EXCEPTION 'VERIFY S4: 7828''s truck question was closed'; END IF;
  -- (e) the controls are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, md5(to_jsonb(v)::text)) FROM public.visits v WHERE v.id IN (6509, 1240))
     IS DISTINCT FROM '{"1240":"e9ba7acf41f96121526a16787482d178","6509":"0b47731ca0c0197aefa9ff6c8f3b8b2f"}'::jsonb THEN
    RAISE EXCEPTION 'VERIFY S4: a control visit changed'; END IF;
  -- (f) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT net_id0 FROM _s4_ctx) AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _s4);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY S4: % Jobber requests queued', n; END IF;
  -- (g) no visit of the set shares time on its truck with a visit it did not share with before (stop and tell Fred)
  SELECT jsonb_object_agg(s.visit_id, x.other) INTO bad
    FROM public.v_visit_shared_time s CROSS JOIN LATERAL (SELECT (e->>'visit_id')::bigint AS other FROM jsonb_array_elements(s.shared_with) e) x
   WHERE s.visit_id IN (SELECT visit_id FROM _s4) AND s.shared_with_count > 0
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce((SELECT shared0 FROM _s4_ctx)->s.visit_id::text, '[]'::jsonb)) e0
                      WHERE (e0->>'visit_id')::bigint = x.other);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S4: new shared time on a truck: %', bad; END IF;
  -- (h) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT checks0 FROM _s4_ctx);
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY S4: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S4: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  -- (i) the rows are the ones the generator wrote (S4/build_s4.mjs)
  IF (SELECT md5(string_agg(concat_ws('|', visit_id, status, action, method, coalesce(new_min::text, '~'), coalesce(new_src, '~')), E'\n' ORDER BY visit_id)) FROM _s4)
     <> '06a9b6b50f9bd0f28000c873831293a3' THEN RAISE EXCEPTION 'VERIFY S4: the row list is not the generated one'; END IF;
  RAISE NOTICE 'S4: 33 ledger rows (% applied, % skipped), % visits written, % flags closed, checks %',
    (SELECT count(*) FROM _s4 WHERE skip IS NULL), nsk, nw, nfl, ck - 'T_detail';
END $v$;

COMMIT;
