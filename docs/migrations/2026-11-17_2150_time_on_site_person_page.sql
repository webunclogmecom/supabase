-- ============================================================================
-- 2026-11-17_2150_time_on_site_person_page  Visit duration re-check: the person page (the 46 visits the nightly held)
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. Fred, 2026-11-17: "i want that to be completed ... once it's done we need to visually check it's
--   correct using our DB + Samsara". The nightly rule (S5, on since 2026-11-09) holds for a person what the GPS alone cannot
--   settle (shared stays, two parkings, loads, another truck, another day); the weekly person loop (PLAN 9) never ran, so
--   45 proposed rows waited, 15 of them since 2026-11-03 (alarm T10 would have opened on those). Visit 6974 joined them:
--   its applied row went stale when it was re-completed on 2026-11-16 (alarm T8 open since then).
--   The page (local, it names clients: samsara-checks/duration_recheck_run_2026-10-28/person_2026-11-17/page.html) showed
--   each visit against its truck's Samsara stops (trip history screen and the trips API) and the crews' photo time stamps.
--   Fred, AskUserQuestion 2026-11-17 ~21:30 ET: "Apply all (Recommended)".
-- WHAT IS WRITTEN (run tos-person-20261117, stage person, status applied, confidence person, decision_ref fred:2026-11-17:person_page)
--   31 keep: action keep_verified, method card_keep_saved, the saved value equals the truck's own Samsara stop
--     at the address within 2 min. No visit write. 6974's row records its new completion (clears T8).
--   13 change (a truck stop that served two or three visits one after the other: each visit gets its own part,
--     split at the earlier visit's completion tap, or at the gap between the two visits' photo time stamps when both were
--     completed at the same minute; two visits get their own stop: 6844 the second stop of the night (photos inside it),
--     6096 its own short stop, since the stop it held was another client's, whose photos fill it). New label review.
--   6219  229 ->  62 min  11/03 23:41 to 00:43 ET  (split:tap_6219)  bonus decided, not re-priced
--   6709  229 -> 167 min  11/04 00:43 to 03:30 ET  (split:tap_6219)  bonus decided, not re-priced
--   8127  152 ->  79 min  10/22 02:23 to 03:42 ET  (split:tap_8127)  bonus decided, not re-priced
--   8871  152 ->  73 min  10/22 03:42 to 04:55 ET  (split:tap_8127)  bonus decided, not re-priced
--   8872  110 ->  18 min  10/22 09:44 to 10:02 ET  (split:tap_8872)
--   8873  110 ->   9 min  10/22 10:02 to 10:11 ET  (split:tap_8872_tap_8873)
--   8875  110 ->  83 min  10/22 10:11 to 11:34 ET  (split:tap_8873)
--   6238   77 ->  51 min  10/25 23:30 to 00:22 ET  (split:photo_gap)  bonus decided, not re-priced
--   6254   77 ->  26 min  10/26 00:22 to 00:47 ET  (split:photo_gap)  bonus decided, not re-priced
--   6614   86 ->  54 min  11/03 01:56 to 02:50 ET  (split:photo_gap)  bonus decided, not re-priced
--   7020   86 ->  32 min  11/03 02:50 to 03:22 ET  (split:photo_gap)  bonus decided, not re-priced
--   6844  135 ->  28 min  10/28 06:11 to 06:39 ET  (stop)
--   6096   73 ->  14 min  10/22 06:19 to 06:33 ET  (stop)
--   2 blank: action blank, method no_samsara_presence (no stop of the truck near the property that day; both
--     judges no_stay). The visits are blank already: no visit write.
--   Each visit's previous current row is superseded (superseded_at only, never edited, PLAN G-7).
--   Approved bonuses are not re-priced: a visit bonus is a set amount per person, not a function of the minutes.
-- THE ROW GUARD
--   Each visit must still hold exactly what resolve.mjs read on 2026-11-17 ~21:20 ET: the four time columns, truck, date,
--   completion, completed and not deleted, the bonus decision time, and exactly one current ledger row, the expected one.
--   Anything else raises (all 46 or nothing).
-- PIN: fn_time_on_site_checks (T12 body), fn_time_on_site_is_locked, audit.log_change, fn_push_visit_to_jobber,
--   fn_mark_visit_sync_pending, fn_clear_time_on_site_on_reopen; no row of run tos-person-20261117 (a second run refuses).
--   Evidence: resolved.json sha256 5b78b5ff7cf22c2fdfae8abbd8b2e8331cd5a84d384441a6f69be140bb5b1127.
-- WHAT DOES NOT CHANGE
--   vehicle_id, visit_date, start_at, end_at, visit_status, deleted_at: the VERIFY allows only the four time columns (and
--   updated_at) on the 13 written visits. Every other visit's time columns and truck: hashed before and after. Nothing
--   goes to Jobber (asserted on net.http_request_queue).
-- CONSEQUENCES
--   Calendar Hours worked on 10-21/22, 10-25/26, 11-02/03 and 11-03/04 drop by the double-counted minutes (a shared stop
--   counted once per visit). v_visit_tank_service duration of the 13 visits. Admin Review shows the new minutes.
-- LABEL: x-app-source time-on-site-recheck-2026, one reason for the transaction.
-- VERIFY: 46 current applied rows of the run, the 46 previous rows superseded; each visit and row hold the new value, each
--   row the old one, truck, date and completion; shape of the written values; only the 13 visits written, only the time
--   columns, labelled; 46 ledger inserts and 46 ledger updates audited, nothing else; every other visit unchanged; no Jobber
--   push; T1 to T12 not newly failing, T7 = T8 = 0; no proposed row older than 8 days (T10's list empty); all 46 locked.
-- ROLLBACK: docs/migrations/2026-11-17_rollback_time_on_site_person_page.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN
DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '03d6d444ec2f782418ab28c575e149b7' THEN
    RAISE EXCEPTION 'person page: % moved', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_is_locked(bigint)'::regprocedure)) <> '69f6f29bc74439f009524796f060c8d0' THEN
    RAISE EXCEPTION 'person page: % moved', 'fn_time_on_site_is_locked(bigint)'; END IF;
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'ce7784f65675e10a0c2a13f853ce0acc' THEN
    RAISE EXCEPTION 'person page: % moved', 'audit.log_change()'; END IF;
  IF md5(pg_get_functiondef('public.fn_push_visit_to_jobber()'::regprocedure)) <> 'a6512e3f1b2cb2de0fddd39bb3679fbe' THEN
    RAISE EXCEPTION 'person page: % moved', 'fn_push_visit_to_jobber()'; END IF;
  IF md5(pg_get_functiondef('public.fn_mark_visit_sync_pending()'::regprocedure)) <> 'f607c3772a444f8fe275380e44651fb4' THEN
    RAISE EXCEPTION 'person page: % moved', 'fn_mark_visit_sync_pending()'; END IF;
  IF md5(pg_get_functiondef('public.fn_clear_time_on_site_on_reopen()'::regprocedure)) <> 'c38d5a5ed8c5b9f1bfa99c3bf2321638' THEN
    RAISE EXCEPTION 'person page: % moved', 'fn_clear_time_on_site_on_reopen()'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-person-20261117') THEN
    RAISE EXCEPTION 'person page: run tos-person-20261117 already has rows'; END IF;
END $pin$;

-- 1. The rows: what each visit holds now (guard) and the answer.
CREATE TEMP TABLE _p (visit_id, old_lid, cur_min, cur_arr, cur_dep, cur_src, cur_veh, cur_date, cur_comp, cur_bonus, new_min, new_arr, new_dep, new_src, action, method, kind, held_as, split_ref) ON COMMIT DROP AS
SELECT * FROM (VALUES
  (6974, 998, 67, timestamptz '2026-08-14 04:25:27+00', timestamptz '2026-08-14 05:32:42+00', 'review', 1, date '2026-08-13', timestamptz '2026-11-16 21:52:10+00', NULL::timestamptz, 67, timestamptz '2026-08-14 04:25:27+00', timestamptz '2026-08-14 05:32:42+00', 'review', 'keep_verified', 'card_keep_saved', 'keep', 'single', 'keep'),
  (7873, 1795, 34, timestamptz '2026-10-13 04:32:25.513+00', timestamptz '2026-10-13 05:06:48.518+00', 'samsara_stay', 1, date '2026-10-12', timestamptz '2026-10-13 05:05:35+00', NULL::timestamptz, 34, timestamptz '2026-10-13 04:32:25.513+00', timestamptz '2026-10-13 05:06:48.518+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (6666, 1789, 95, timestamptz '2026-10-14 02:45:59.517+00', timestamptz '2026-10-14 04:20:33.528+00', 'samsara_stay', 1, date '2026-10-13', timestamptz '2026-10-14 04:11:43+00', timestamptz '2026-10-19 11:12:31.085+00', 95, timestamptz '2026-10-14 02:45:59.517+00', timestamptz '2026-10-14 04:20:33.528+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8769, 1812, 54, timestamptz '2026-10-13 11:18:05.512+00', timestamptz '2026-10-13 12:12:10.529+00', 'samsara_stay', 2, date '2026-10-13', timestamptz '2026-10-13 12:10:52+00', NULL::timestamptz, 54, timestamptz '2026-10-13 11:18:05.512+00', timestamptz '2026-10-13 12:12:10.529+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (5930, 1770, 40, timestamptz '2026-10-15 07:05:45+00', timestamptz '2026-10-15 07:46:09+00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15 07:42:49+00', NULL::timestamptz, 40, timestamptz '2026-10-15 07:05:45+00', timestamptz '2026-10-15 07:46:09+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (6224, 1774, 221, timestamptz '2026-10-15 03:24:07.518+00', timestamptz '2026-10-15 07:04:46.512+00', 'samsara_stay', 1, date '2026-10-14', timestamptz '2026-10-15 07:03:06+00', timestamptz '2026-10-19 13:19:16.678+00', 221, timestamptz '2026-10-15 03:24:07.518+00', timestamptz '2026-10-15 07:04:46.512+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8089, 1796, 52, timestamptz '2026-10-15 09:31:45+00', timestamptz '2026-10-15 10:24:00+00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15 10:20:44+00', NULL::timestamptz, 52, timestamptz '2026-10-15 09:31:45+00', timestamptz '2026-10-15 10:24:00+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8126, 1797, 18, timestamptz '2026-10-14 13:39:44.495+00', timestamptz '2026-10-14 13:57:52.516+00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14 13:59:30+00', NULL::timestamptz, 18, timestamptz '2026-10-14 13:39:44.495+00', timestamptz '2026-10-14 13:57:52.516+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8784, 1821, 11, timestamptz '2026-10-14 18:22:07.507+00', timestamptz '2026-10-14 18:33:25.5+00', 'samsara_stay', 2, date '2026-10-14', timestamptz '2026-10-14 18:32:41+00', NULL::timestamptz, 11, timestamptz '2026-10-14 18:22:07.507+00', timestamptz '2026-10-14 18:33:25.5+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8785, 1822, 80, timestamptz '2026-10-15 11:44:58+00', timestamptz '2026-10-15 13:05:18+00', 'stop_at_completion', 1, date '2026-10-14', timestamptz '2026-10-15 13:03:51+00', NULL::timestamptz, 80, timestamptz '2026-10-15 11:44:58+00', timestamptz '2026-10-15 13:05:18+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (6800, 1791, 48, timestamptz '2026-10-16 02:53:28+00', timestamptz '2026-10-16 03:41:52+00', 'stop_at_completion', 1, date '2026-10-15', timestamptz '2026-10-16 03:37:24+00', timestamptz '2026-10-26 14:27:34.137+00', 48, timestamptz '2026-10-16 02:53:28+00', timestamptz '2026-10-16 03:41:52+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8782, 1819, 90, timestamptz '2026-10-15 19:03:42.511+00', timestamptz '2026-10-15 20:33:41.613+00', 'samsara_stay', 2, date '2026-10-15', timestamptz '2026-10-15 20:36:03+00', NULL::timestamptz, 90, timestamptz '2026-10-15 19:03:42.511+00', timestamptz '2026-10-15 20:33:41.613+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8815, 1823, 48, timestamptz '2026-10-15 15:59:43+00', timestamptz '2026-10-15 16:47:52+00', 'stop_at_completion', 2, date '2026-10-15', timestamptz '2026-10-15 16:45:16+00', NULL::timestamptz, 48, timestamptz '2026-10-15 15:59:43+00', timestamptz '2026-10-15 16:47:52+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8821, 1825, 19, timestamptz '2026-10-15 17:22:44.515+00', timestamptz '2026-10-15 17:41:24.52+00', 'samsara_stay', 2, date '2026-10-15', timestamptz '2026-10-15 17:35:34+00', NULL::timestamptz, 19, timestamptz '2026-10-15 17:22:44.515+00', timestamptz '2026-10-15 17:41:24.52+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8817, 1824, 73, timestamptz '2026-10-16 12:26:58+00', timestamptz '2026-10-16 13:40:19+00', 'stop_at_completion', 3, date '2026-10-16', timestamptz '2026-10-16 13:38:12+00', timestamptz '2026-10-20 16:00:03.017+00', 73, timestamptz '2026-10-16 12:26:58+00', timestamptz '2026-10-16 13:40:19+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'held_unsettled', 'keep'),
  (8853, 2238, 57, timestamptz '2026-10-19 13:44:02.506+00', timestamptz '2026-10-19 14:41:19.525+00', 'samsara_stay', 2, date '2026-10-19', timestamptz '2026-10-19 14:26:27+00', NULL::timestamptz, 57, timestamptz '2026-10-19 13:44:02.506+00', timestamptz '2026-10-19 14:41:19.525+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'shared_tap', 'keep'),
  (8882, 2175, 18, timestamptz '2026-10-23 18:28:37.506+00', timestamptz '2026-10-23 18:46:41.529+00', 'samsara_stay', 2, date '2026-10-23', timestamptz '2026-10-26 16:25:22+00', NULL::timestamptz, 18, timestamptz '2026-10-23 18:28:37.506+00', timestamptz '2026-10-23 18:46:41.529+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'other_day', 'keep'),
  (8886, 2239, 46, timestamptz '2026-10-26 15:44:28.516+00', timestamptz '2026-10-26 16:30:48.523+00', 'samsara_stay', 2, date '2026-10-26', timestamptz '2026-10-26 16:27:51+00', NULL::timestamptz, 46, timestamptz '2026-10-26 15:44:28.516+00', timestamptz '2026-10-26 16:30:48.523+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'shared_tap', 'keep'),
  (5995, 2197, 135, timestamptz '2026-10-28 07:55:28.506+00', timestamptz '2026-10-28 10:10:42.52+00', 'samsara_stay', 2, date '2026-10-28', timestamptz '2026-10-28 10:11:59+00', NULL::timestamptz, 135, timestamptz '2026-10-28 07:55:28.506+00', timestamptz '2026-10-28 10:10:42.52+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'shared_stay', 'keep'),
  (8895, 2214, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 2, date '2026-10-29', timestamptz '2026-10-29 17:55:48+00', NULL::timestamptz, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'shared_stay', 'keep'),
  (8897, 2215, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 2, date '2026-10-29', timestamptz '2026-10-29 17:55:56+00', NULL::timestamptz, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'shared_stay', 'keep'),
  (8937, 2216, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 2, date '2026-10-29', timestamptz '2026-10-29 17:54:47+00', NULL::timestamptz, 205, timestamptz '2026-10-29 14:18:02+00', timestamptz '2026-10-29 17:42:52+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'shared_stay', 'keep'),
  (6400, 2127, 89, timestamptz '2026-11-02 04:07:37.517+00', timestamptz '2026-11-02 05:36:38.51+00', 'samsara_stay', 1, date '2026-11-01', timestamptz '2026-11-02 05:36:05+00', timestamptz '2026-11-02 17:27:01.215+00', 89, timestamptz '2026-11-02 04:07:37.517+00', timestamptz '2026-11-02 05:36:38.51+00', 'samsara_stay', 'keep_verified', 'card_keep_saved', 'keep', 'big_change', 'keep'),
  (9048, 2244, 83, timestamptz '2026-11-03 18:22:49+00', timestamptz '2026-11-03 19:46:17+00', 'stop_at_completion', 3, date '2026-11-03', timestamptz '2026-11-03 19:45:53+00', timestamptz '2026-11-04 15:14:16.054+00', 83, timestamptz '2026-11-03 18:22:49+00', timestamptz '2026-11-03 19:46:17+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'loads', 'keep'),
  (9056, 2245, 257, timestamptz '2026-11-03 17:54:10+00', timestamptz '2026-11-03 22:10:44+00', 'stop_at_completion', 1, date '2026-11-03', timestamptz '2026-11-11 20:39:40+00', NULL::timestamptz, 257, timestamptz '2026-11-03 17:54:10+00', timestamptz '2026-11-03 22:10:44+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'other_day', 'keep'),
  (9069, 2246, 203, timestamptz '2026-11-04 09:18:25+00', timestamptz '2026-11-04 12:41:54+00', 'stop_at_completion', 1, date '2026-11-03', timestamptz '2026-11-04 12:37:51+00', timestamptz '2026-11-11 16:26:28.969+00', 203, timestamptz '2026-11-04 09:18:25+00', timestamptz '2026-11-04 12:41:54+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'another_truck', 'keep'),
  (9072, 2247, 5, timestamptz '2026-11-04 10:05:46+00', timestamptz '2026-11-04 10:10:54+00', 'stop_at_completion', 3, date '2026-11-03', timestamptz '2026-11-04 14:59:03+00', NULL::timestamptz, 5, timestamptz '2026-11-04 10:05:46+00', timestamptz '2026-11-04 10:10:54+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'several', 'keep'),
  (9070, 2253, 83, timestamptz '2026-11-04 12:56:48+00', timestamptz '2026-11-04 14:20:05+00', 'stop_at_completion', 3, date '2026-11-04', timestamptz '2026-11-04 13:59:34+00', NULL::timestamptz, 83, timestamptz '2026-11-04 12:56:48+00', timestamptz '2026-11-04 14:20:05+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'loads', 'keep'),
  (9073, 2254, 77, timestamptz '2026-11-04 14:14:46+00', timestamptz '2026-11-04 15:32:14+00', 'stop_at_completion', 2, date '2026-11-04', timestamptz '2026-11-04 15:25:46+00', NULL::timestamptz, 77, timestamptz '2026-11-04 14:14:46+00', timestamptz '2026-11-04 15:32:14+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'another_truck', 'keep'),
  (6969, 2262, 32, timestamptz '2026-11-06 13:22:53+00', timestamptz '2026-11-06 13:55:18+00', 'stop_at_completion', 1, date '2026-11-05', timestamptz '2026-11-06 13:58:06+00', timestamptz '2026-11-09 15:07:15.468+00', 32, timestamptz '2026-11-06 13:22:53+00', timestamptz '2026-11-06 13:55:18+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'loads', 'keep'),
  (9138, 2273, 29, timestamptz '2026-11-07 19:54:14+00', timestamptz '2026-11-07 20:22:45+00', 'stop_at_completion', 2, date '2026-11-07', timestamptz '2026-11-07 20:22:19+00', NULL::timestamptz, 29, timestamptz '2026-11-07 19:54:14+00', timestamptz '2026-11-07 20:22:45+00', 'stop_at_completion', 'keep_verified', 'card_keep_saved', 'keep', 'loads', 'keep'),
  (6219, 2241, 229, timestamptz '2026-11-04 04:41:39.497+00', timestamptz '2026-11-04 08:30:31.533+00', 'samsara_stay', 1, date '2026-11-03', timestamptz '2026-11-04 05:43:30+00', timestamptz '2026-11-04 19:07:28.602+00', 62, timestamptz '2026-11-04 04:41:39.497+00', timestamptz '2026-11-04 05:43:30+00', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:tap_6219'),
  (6709, 2242, 229, timestamptz '2026-11-04 04:41:39.497+00', timestamptz '2026-11-04 08:30:31.533+00', 'samsara_stay', 1, date '2026-11-03', timestamptz '2026-11-04 08:28:06+00', timestamptz '2026-11-04 19:06:06.804+00', 167, timestamptz '2026-11-04 05:43:30+00', timestamptz '2026-11-04 08:30:31.533+00', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:tap_6219'),
  (8127, 2158, 152, timestamptz '2026-10-22 06:23:26+00', timestamptz '2026-10-22 08:55:54+00', 'stop_at_completion', 1, date '2026-10-21', timestamptz '2026-10-22 07:42:43+00', timestamptz '2026-10-22 18:27:00.777+00', 79, timestamptz '2026-10-22 06:23:26+00', timestamptz '2026-10-22 07:42:43+00', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:tap_8127'),
  (8871, 2160, 152, timestamptz '2026-10-22 06:23:26+00', timestamptz '2026-10-22 08:55:54+00', 'stop_at_completion', 1, date '2026-10-21', timestamptz '2026-10-22 08:51:02+00', timestamptz '2026-10-29 19:56:13.401+00', 73, timestamptz '2026-10-22 07:42:43+00', timestamptz '2026-10-22 08:55:54+00', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:tap_8127'),
  (8872, 2167, 110, timestamptz '2026-10-22 13:44:22+00', timestamptz '2026-10-22 15:34:51+00', 'stop_at_completion', 2, date '2026-10-22', timestamptz '2026-10-22 14:02:32+00', NULL::timestamptz, 18, timestamptz '2026-10-22 13:44:22+00', timestamptz '2026-10-22 14:02:32+00', 'review', 'change', 'photo_stamp:split', 'split', 'no_free_stay', 'split:tap_8872'),
  (8873, 2168, 110, timestamptz '2026-10-22 13:44:22+00', timestamptz '2026-10-22 15:34:51+00', 'stop_at_completion', 2, date '2026-10-22', timestamptz '2026-10-22 14:11:28+00', NULL::timestamptz, 9, timestamptz '2026-10-22 14:02:32+00', timestamptz '2026-10-22 14:11:28+00', 'review', 'change', 'photo_stamp:split', 'split', 'no_free_stay', 'split:tap_8872_tap_8873'),
  (8875, 2170, 110, timestamptz '2026-10-22 13:44:22+00', timestamptz '2026-10-22 15:34:51+00', 'stop_at_completion', 2, date '2026-10-22', timestamptz '2026-10-22 15:35:23+00', NULL::timestamptz, 83, timestamptz '2026-10-22 14:11:28+00', timestamptz '2026-10-22 15:34:51+00', 'review', 'change', 'photo_stamp:split', 'split', 'shared_tap', 'split:tap_8873'),
  (6238, 2178, 77, timestamptz '2026-10-26 03:30:33+00', timestamptz '2026-10-26 04:47:53+00', 'stop_at_completion', 1, date '2026-10-25', timestamptz '2026-10-26 04:46:10+00', timestamptz '2026-10-29 15:57:19.422+00', 51, timestamptz '2026-10-26 03:30:33+00', timestamptz '2026-10-26T04:22:00.000Z', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:photo_gap'),
  (6254, 2179, 77, timestamptz '2026-10-26 03:30:33+00', timestamptz '2026-10-26 04:47:53+00', 'stop_at_completion', 1, date '2026-10-25', timestamptz '2026-10-26 04:46:56+00', timestamptz '2026-10-29 16:09:24.675+00', 26, timestamptz '2026-10-26T04:22:00.000Z', timestamptz '2026-10-26 04:47:53+00', 'review', 'change', 'photo_stamp:split', 'split', 'two_parkings', 'split:photo_gap'),
  (6614, 2133, 86, timestamptz '2026-11-03 06:56:02+00', timestamptz '2026-11-03 08:22:14+00', 'stop_at_completion', 1, date '2026-11-02', timestamptz '2026-11-03 08:20:14+00', timestamptz '2026-11-04 19:07:04.624+00', 54, timestamptz '2026-11-03 06:56:02+00', timestamptz '2026-11-03T07:50:00.000Z', 'review', 'change', 'photo_stamp:split', 'split', 'shared_stay', 'split:photo_gap'),
  (7020, 2136, 86, timestamptz '2026-11-03 06:56:02+00', timestamptz '2026-11-03 08:22:14+00', 'stop_at_completion', 1, date '2026-11-02', timestamptz '2026-11-03 08:19:30+00', timestamptz '2026-11-04 19:06:44.699+00', 32, timestamptz '2026-11-03T07:50:00.000Z', timestamptz '2026-11-03 08:22:14+00', 'review', 'change', 'photo_stamp:split', 'split', 'shared_stay', 'split:photo_gap'),
  (6844, 2204, 135, timestamptz '2026-10-28 07:55:28.506+00', timestamptz '2026-10-28 10:10:42.52+00', 'samsara_stay', 2, date '2026-10-28', timestamptz '2026-10-28 10:39:26+00', NULL::timestamptz, 28, timestamptz '2026-10-28T10:11:45.512Z', timestamptz '2026-10-28T10:39:56.504Z', 'review', 'change', 'photo_stamp:own_stop', 'stop', 'shared_stay', 'stop'),
  (6096, 2154, 73, timestamptz '2026-10-22 09:04:18.509+00', timestamptz '2026-10-22 10:16:59.541+00', 'samsara_stay', 1, date '2026-10-21', timestamptz '2026-10-22 08:51:46+00', NULL::timestamptz, 14, timestamptz '2026-10-22T10:19:41.500Z', timestamptz '2026-10-22T10:33:52.533Z', 'review', 'change', 'one_judge:own_stop', 'stop', 'no_free_stay', 'stop'),
  (8752, 1803, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 3, date '2026-10-09', timestamptz '2026-10-09 19:43:22+00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'blank', 'no_samsara_presence', 'blank', 'far_park', 'blank'),
  (9046, 2131, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, date '2026-11-01', timestamptz '2026-11-02 16:43:01+00', NULL::timestamptz, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 'blank', 'no_samsara_presence', 'blank', 'other_day', 'blank')
) AS x (visit_id, old_lid, cur_min, cur_arr, cur_dep, cur_src, cur_veh, cur_date, cur_comp, cur_bonus, new_min, new_arr, new_dep, new_src, action, method, kind, held_as, split_ref);

CREATE TEMP TABLE _p_ctx ON COMMIT DROP AS
SELECT (SELECT max(id) FROM audit.logs) AS audit_id0,
       (SELECT coalesce(max(id), 0) FROM net.http_request_queue) AS net_id0,
       public.fn_time_on_site_checks() AS checks0,
       (SELECT md5(string_agg(concat_ws('|', v.id, v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id, v.visit_date), E'\n' ORDER BY v.id))
          FROM public.visits v WHERE v.id NOT IN (SELECT visit_id FROM _p WHERE action = 'change')) AS others0;

-- 2. Lock, then the guard: anything moved since the read raises.
DO $lock$ DECLARE bad text; BEGIN
  IF (SELECT count(*) FROM _p) <> 46 OR (SELECT count(DISTINCT visit_id) FROM _p) <> 46 THEN RAISE EXCEPTION 'person page: the row list is not 46 distinct visits'; END IF;
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _p) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.visit_id IN (SELECT visit_id FROM _p) FOR UPDATE;
  SELECT string_agg(r.visit_id || ':' || why, ', ') INTO bad FROM (
    SELECT r.visit_id, CASE
      WHEN v.id IS NULL THEN 'missing'
      WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
      WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
      WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
      WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (r.cur_date, r.cur_comp) THEN 'date_or_completion_moved'
      WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM r.cur_bonus THEN 'bonus_moved'
      WHEN (SELECT count(*) FROM public.visit_time_on_site_corrections l WHERE l.visit_id = r.visit_id AND l.superseded_at IS NULL) <> 1
        OR NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.id = r.old_lid AND l.visit_id = r.visit_id AND l.superseded_at IS NULL) THEN 'ledger_row_not_current'
    END AS why
    FROM _p r LEFT JOIN public.visits v ON v.id = r.visit_id) r WHERE r.why IS NOT NULL;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'person page: visits moved since the read (%), nothing written: re-read and re-rehearse', bad; END IF;
END $lock$;

-- 3. Supersede, insert, then the visits, in the same transaction, labelled.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-recheck-2026',
         'x-change-reason', 'Visit duration re-check, the person page of 2026-11-17 (Fred: "Apply all (Recommended)"), run tos-person-20261117: the 46 visits the nightly held for a person, checked against Samsara and the photo time stamps. Not pushed to Jobber.'))::text, true);
  UPDATE public.visit_time_on_site_corrections l SET superseded_at = now()
    FROM _p r WHERE l.id = r.old_lid AND l.superseded_at IS NULL;
  GET DIAGNOSTICS n = row_count;
  IF n <> 46 THEN RAISE EXCEPTION 'person page: superseded % rows, expected 46', n; END IF;
  INSERT INTO public.visit_time_on_site_corrections
    (visit_id, run_id, param_version, input_hashes, old_vehicle_id, new_vehicle_id, stage, action, status,
     old_arrival, old_departure, old_minutes, old_source, old_visit_date, old_completed_at, bonus_decided_at_seen,
     new_arrival, new_departure, new_minutes, new_source, method, confidence, decision_ref, evidence, evidence_file_sha256,
     applied_at, applied_by_migration)
  SELECT r.visit_id, 'tos-person-20261117', 'person-page-20261117',
         jsonb_build_object('resolved_json_sha256', '5b78b5ff7cf22c2fdfae8abbd8b2e8331cd5a84d384441a6f69be140bb5b1127'),
         r.cur_veh, r.cur_veh, 'person', r.action, 'applied',
         r.cur_arr, r.cur_dep, r.cur_min, r.cur_src, r.cur_date, r.cur_comp, r.cur_bonus,
         r.new_arr, r.new_dep, r.new_min, r.new_src, r.method, 'person', 'fred:2026-11-17:person_page',
         jsonb_build_object('kind', r.kind, 'held_as', r.held_as, 'superseded_row', r.old_lid, 'split', r.split_ref,
           'checked', 'samsara trips (screen and API) and photo time stamps', 'bonus', CASE WHEN r.cur_bonus IS NOT NULL THEN 'decided, not re-priced' END),
         '5b78b5ff7cf22c2fdfae8abbd8b2e8331cd5a84d384441a6f69be140bb5b1127', now(), '2026-11-17_2150_time_on_site_person_page.sql'
    FROM _p r;
  GET DIAGNOSTICS n = row_count;
  IF n <> 46 THEN RAISE EXCEPTION 'person page: inserted % ledger rows, expected 46', n; END IF;
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep, time_on_site_source = r.new_src
    FROM _p r WHERE v.id = r.visit_id AND r.action = 'change';
  GET DIAGNOSTICS n = row_count;
  IF n <> 13 THEN RAISE EXCEPTION 'person page: wrote % visits, expected 13', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint := (SELECT audit_id0 FROM _p_ctx); ck jsonb; ck0 jsonb := (SELECT checks0 FROM _p_ctx); t text;
BEGIN
  -- (a) 46 current applied person rows of the run; the 46 previous rows superseded
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections l JOIN _p r ON r.visit_id = l.visit_id
   WHERE l.run_id = 'tos-person-20261117' AND l.superseded_at IS NULL AND l.status = 'applied' AND l.stage = 'person'
     AND l.applied_by_migration = '2026-11-17_2150_time_on_site_person_page.sql' AND l.applied_at IS NOT NULL AND l.action = r.action AND l.method = r.method;
  IF n <> 46 OR (SELECT count(*) FROM public.visit_time_on_site_corrections WHERE run_id = 'tos-person-20261117') <> 46 THEN
    RAISE EXCEPTION 'VERIFY person page: % current applied rows of the run, expected 46', n; END IF;
  SELECT count(*) INTO n FROM public.visit_time_on_site_corrections l JOIN _p r ON l.id = r.old_lid WHERE l.superseded_at IS NOT NULL;
  IF n <> 46 THEN RAISE EXCEPTION 'VERIFY person page: % previous rows superseded, expected 46', n; END IF;
  -- (b) each visit and its row hold the new value; the row holds the old value, truck, date and completion
  SELECT count(*) INTO n FROM _p r JOIN public.visits v ON v.id = r.visit_id
    JOIN public.visit_time_on_site_corrections l ON l.visit_id = r.visit_id AND l.superseded_at IS NULL
   WHERE (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src)
      OR (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh)
      OR (v.vehicle_id, v.visit_date, v.completed_at) IS DISTINCT FROM (l.new_vehicle_id, l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY person page: % visits or rows do not hold the expected values', n; END IF;
  -- (c) shape of the written values: set, under 720 min, minutes = departure - arrival within 1 min
  IF EXISTS (SELECT 1 FROM _p r JOIN public.visits v ON v.id = r.visit_id WHERE r.action = 'change'
              AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
                   OR v.actual_departure_at <= v.actual_arrival_at
                   OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1)) THEN
    RAISE EXCEPTION 'VERIFY person page: a written value fails the shape checks'; END IF;
  -- (d) only the 13 visits written, only the time columns, labelled; 46 + 46 ledger audit rows; nothing else
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> 13 THEN RAISE EXCEPTION 'VERIFY person page: % audit rows on public.visits, expected 13', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _p WHERE action = 'change') OR a.operation <> 'UPDATE'
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-recheck-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY person page: % visit writes outside the time columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public'
     AND a.table_name = 'visit_time_on_site_corrections' AND a.operation = 'INSERT' AND a.app_source = 'time-on-site-recheck-2026';
  IF n <> 46 THEN RAISE EXCEPTION 'VERIFY person page: % labelled ledger inserts audited, expected 46', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public'
     AND a.table_name = 'visit_time_on_site_corrections' AND a.operation = 'UPDATE' AND a.app_source = 'time-on-site-recheck-2026'
     AND (a.old_row - 'superseded_at') = (a.new_row - 'superseded_at') AND a.old_row->>'superseded_at' IS NULL AND a.new_row->>'superseded_at' IS NOT NULL;
  IF n <> 46 THEN RAISE EXCEPTION 'VERIFY person page: % labelled supersede updates audited, expected 46', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY person page: % audit rows on other tables', n; END IF;
  -- (e) every other visit's time columns, truck and date are unchanged
  IF (SELECT md5(string_agg(concat_ws('|', v.id, v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id, v.visit_date), E'\n' ORDER BY v.id))
        FROM public.visits v WHERE v.id NOT IN (SELECT visit_id FROM _p WHERE action = 'change')) IS DISTINCT FROM (SELECT others0 FROM _p_ctx) THEN
    RAISE EXCEPTION 'VERIFY person page: another visit''s time, truck or date changed'; END IF;
  -- (f) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT net_id0 FROM _p_ctx) AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _p);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY person page: % Jobber requests queued', n; END IF;
  -- (g) T1 to T12: none newly failing; T7 and T8 zero; T10's list (a proposed row older than 8 days) empty
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8', 'T12'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY person page: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY person page: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE superseded_at IS NULL AND status = 'proposed' AND created_at < now() - interval '8 days') THEN
    RAISE EXCEPTION 'VERIFY person page: a proposed row older than 8 days is left'; END IF;
  -- (h) every visit is locked, so no writer and no nightly moves it
  IF EXISTS (SELECT 1 FROM _p r WHERE NOT public.fn_time_on_site_is_locked(r.visit_id)) THEN RAISE EXCEPTION 'VERIFY person page: a visit is not locked'; END IF;
  RAISE NOTICE 'person page: 46 rows applied (31 keep, 13 change, 2 blank), checks %', ck - 'T_detail';
END $v$;

COMMIT;
