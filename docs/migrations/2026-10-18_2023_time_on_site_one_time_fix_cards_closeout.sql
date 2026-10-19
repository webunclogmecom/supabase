-- ============================================================================
-- 2026-10-18_2023_time_on_site_one_time_fix_cards_closeout One-time 2026 duration fix: the cards close out
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-19 (his clock; 2026-10-18 evening ET), "go ahead" with: (1) accept the photo-settled cards of
--   samsara-checks/duration_fix_run_2026-10-18/ledger/cards.md section 8 as a batch, 6270 keeping its saved 101;
--   (2) close every other card as "keep the saved time", locked so the night jobs do not touch it; (3) list, for him
--   to look at, the cards whose answer would change the truck on a visit filed with Miami-Dade (local, not here).
--   The cards and the evidence are local (they name clients). Visit ids only here.
-- WHAT IS WRITTEN (101 stage 4 ledger rows of run tos-fix-2026-r1; 96 visits)
--   a_change 12: the answer the crew's photo stamps settle (section 8), each interval re-derived from the P and V
--            parkings and reproduced within 2 min (local derive.json): written, labelled review (locked).
--   a_keep   5: section 8 "keep the saved": same minutes and interval, labelled review (locked).
--   b_keep   79: every other card with a saved time: same minutes and interval, labelled review (locked).
--   b_blank  5: every other card whose visit is BLANK: the visit is NOT written (blank does not mean "no service",
--            so no reviewed_blank); its ledger row is closed as applied, action lock_decided, new value NULL = the
--            visit's, so T7 names the visit if a night job ever fills it.
--   Every ledger row: status applied, action change (a_change) or lock_decided, method photo_stamp (section 8) or
--   card_keep_saved, confidence medium (stamps) or person, decision_ref Q11 or cards-closeout; its earlier state and
--   the visit's earlier values go to evidence->'co_before' / 'co_before_visit' for the rollback. Same transaction, so
--   T7 and T8 stay 0.
--   Trucks (vehicle_id only): 6854 none -> Cloggy and 5819 Moises -> Cloggy (neither is filed with Miami-Dade; the row's
--   truck part becomes truck_stage 1, applied). 1465 is filed with Miami-Dade: its Cloggy -> Moises is HELD, the time
--   only is written and the truck stays Cloggy (on Fred's step 3 list).
-- LEFT OUT ON PURPOSE
--   6270 (section 8, keep the saved 101): the saved 10-02 23:44:13 to 10-03 01:25:30 is not a measured parking within
--     2 min (nearest: Moises 23:50:52 to 01:24:05 in P and V, +400 s / -85 s; with V's short halt at the site
--     23:46:51, +158 s). It stays a stage 4 card ('proposed'), its visit untouched, until it is decided again.
--   1582 (applied by 2026-10-18_1631) and the 61 catch_up rows (dated 10-08 to 10-17): not touched.
-- WHAT CHANGES (visit  ledger id  kind  truck  minutes  interval ET)
--   1259  20    b_keep    David             100 -> 100    unchanged 01-07 19:51:13 to 01-07 21:31:13 (samsara_stay -> review)
--   1260  21    b_keep    David             100 -> 100    unchanged 01-07 19:51:13 to 01-07 21:31:13 (samsara_stay -> review)
--   1262  23    b_keep    David             100 -> 100    unchanged 01-07 19:51:13 to 01-07 21:31:13 (samsara_stay -> review)
--   1289  50    b_keep    Cloggy            77 -> 77      unchanged 01-16 13:42:24 to 01-16 14:59:25 (NULL -> review)
--   1296  57    b_keep    Cloggy            120 -> 120    unchanged 01-19 12:01:33 to 01-19 14:01:28 (samsara_stay -> review)
--   1302  63    b_keep    David             106 -> 106    unchanged 01-20 20:30:41 to 01-20 22:16:46 (samsara_stay -> review)
--   1314  75    b_keep    David             90 -> 90      unchanged 01-23 03:11:14 to 01-23 04:41:09 (samsara_stay -> review)
--   1315  76    b_keep    David             90 -> 90      unchanged 01-23 03:11:14 to 01-23 04:41:09 (samsara_stay -> review)
--   1316  77    b_keep    David             90 -> 90      unchanged 01-23 03:11:14 to 01-23 04:41:09 (samsara_stay -> review)
--   1327  88    b_keep    David             98 -> 98      unchanged 01-28 05:48:21 to 01-28 07:26:11 (samsara_stay -> review)
--   1352  112   b_keep    David             110 -> 110    unchanged 02-04 21:06:25 to 02-04 22:56:06 (NULL -> review)
--   1353  113   b_keep    David             46 -> 46      unchanged 02-05 01:52:40 to 02-05 02:39:09 (NULL -> review)
--   1357  117   b_keep    David             116 -> 116    unchanged 02-05 04:10:48 to 02-05 06:07:13 (NULL -> review)
--   1362  122   b_keep    Cloggy            51 -> 51      unchanged 02-06 13:29:12 to 02-06 14:19:48 (NULL -> review)
--   1366  126   b_keep    David             19 -> 19      unchanged 02-08 20:29:02 to 02-08 20:48:24 (NULL -> review)
--   1418  173   b_keep    David             73 -> 73      unchanged 02-24 14:47:54 to 02-24 16:00:24 (NULL -> review)
--   1419  174   b_keep    Cloggy            6 -> 6        unchanged 02-25 13:36:03 to 02-25 13:42:17 (samsara_stay -> review)
--   1462  217   b_keep    Cloggy            29 -> 29      unchanged 03-09 17:25:13 to 03-09 17:54:09 (samsara_stay -> review)
--   1465  220   a_change  Cloggy            24 -> 38      03-09 23:16:29 to 03-09 23:54:52 (NULL -> review)
--   1466  221   b_keep    Cloggy            102 -> 102    unchanged 03-09 23:59:01 to 03-10 01:41:25 (NULL -> review)
--   1540  285   a_change  Moises            64 -> 84      03-26 02:56:35 to 03-26 04:20:40 (NULL -> review)
--   1541  286   a_change  Moises            68 -> 84      03-26 02:56:35 to 03-26 04:20:40 (NULL -> review)
--   1571  314   b_keep    Cloggy            71 -> 71      unchanged 04-02 22:38:49 to 04-02 23:49:59 (samsara_stay -> review)
--   1574  317   a_change  Cloggy            33 -> 18      04-03 17:06:09 to 04-03 17:24:09 (NULL -> review)
--   1597  337   b_keep    Cloggy            101 -> 101    unchanged 04-09 22:59:31 to 04-10 00:40:01 (NULL -> review)
--   1601  340   b_keep    Cloggy            101 -> 101    unchanged 04-09 22:59:31 to 04-10 00:40:01 (NULL -> review)
--   1707  348   b_keep    Cloggy            14 -> 14      unchanged 04-10 04:02:28 to 04-10 04:16:09 (samsara_stay -> review)
--   1598  362   b_keep    Moises            136 -> 136    unchanged 04-15 21:36:35 to 04-15 23:52:39 (stop_at_completion -> review)
--   1740  401   b_keep    Cloggy            20 -> 20      unchanged 04-22 06:47:28 to 04-22 07:07:31 (samsara_stay -> review)
--   1749  403   b_keep    Cloggy            186 -> 186    unchanged 04-22 12:56:08 to 04-22 16:01:54 (NULL -> review)
--   1773  409   b_keep    Moises            245 -> 245    unchanged 04-23 23:25:33 to 04-24 03:30:19 (NULL -> review)
--   1775  411   b_keep    Moises            245 -> 245    unchanged 04-23 23:25:33 to 04-24 03:30:14 (NULL -> review)
--   1782  418   b_keep    Moises            209 -> 209    unchanged 04-26 23:36:57 to 04-27 03:05:28 (NULL -> review)
--   1784  420   b_keep    Moises            25 -> 25      unchanged 04-27 07:17:28 to 04-27 07:42:50 (samsara_stay -> review)
--   1787  424   b_keep    Cloggy            277 -> 277    unchanged 04-27 17:06:35 to 04-27 21:43:36 (NULL -> review)
--   1793  429   b_keep    Cloggy            44 -> 44      unchanged 04-28 16:37:15 to 04-28 17:20:56 (samsara_stay -> review)
--   3890  441   b_keep    Cloggy            107 -> 107    unchanged 04-29 17:13:59 to 04-29 19:01:07 (samsara_stay -> review)
--   3920  462   b_keep    Moises            61 -> 61      unchanged 05-04 23:02:03 to 05-05 00:02:39 (samsara_stay -> review)
--   3921  463   b_keep    Cloggy            52 -> 52      unchanged 05-05 13:25:47 to 05-05 14:18:10 (samsara_stay -> review)
--   5080  472   b_keep    David             68 -> 68      unchanged 05-08 06:00:36 to 05-08 07:08:43 (samsara_stay -> review)
--   3931  474   b_keep    Cloggy            50 -> 50      unchanged 05-08 09:33:23 to 05-08 10:23:45 (NULL -> review)
--   3932  475   b_keep    David             30 -> 30      unchanged 05-08 07:48:36 to 05-08 08:18:08 (samsara_stay -> review)
--   3934  477   b_keep    Cloggy            70 -> 70      unchanged 05-08 10:47:41 to 05-08 11:57:55 (NULL -> review)
--   3935  478   a_change  David             30 -> 56      05-08 07:21:46 to 05-08 08:18:08 (samsara_stay -> review)
--   5636  489   b_blank   none              blank -> blank visit not written (blank kept blank), ledger closed
--   3903  491   b_keep    Moises            205 -> 205    unchanged 05-12 22:53:29 to 05-13 02:18:15 (NULL -> review)
--   5081  494   b_keep    Moises            153 -> 153    unchanged 05-12 07:00:25 to 05-12 09:33:29 (NULL -> review)
--   5082  495   b_keep    Moises            153 -> 153    unchanged 05-12 07:00:25 to 05-12 09:33:29 (NULL -> review)
--   5100  520   b_keep    Moises            129 -> 129    unchanged 05-18 02:44:57 to 05-18 04:53:50 (samsara_stay -> review)
--   5101  521   b_keep    Moises            84 -> 84      unchanged 05-18 04:58:30 to 05-18 06:22:13 (samsara_stay -> review)
--   5028  546   a_keep    David             54 -> 54      unchanged 05-21 06:09:13 to 05-21 07:02:48 (samsara_stay -> review)
--   5043  547   b_keep    David             19 -> 19      unchanged 05-21 07:28:00 to 05-21 07:46:35 (samsara_stay -> review)
--   5133  552   b_keep    Cloggy            65 -> 65      unchanged 05-23 11:04:49 to 05-23 12:10:14 (samsara_stay -> review)
--   5159  577   b_keep    Cloggy            65 -> 65      unchanged 05-28 23:41:33 to 05-29 00:46:48 (NULL -> review)
--   5732  605   b_blank   Cloggy            blank -> blank visit not written (blank kept blank), ledger closed
--   5734  607   b_keep    Cloggy            129 -> 129    unchanged 06-03 14:48:29 to 06-03 16:57:52 (samsara_stay -> review)
--   5736  610   a_keep    Moises            19 -> 19      unchanged 06-04 06:34:32 to 06-04 06:53:28 (samsara_stay -> review)
--   5755  631   a_keep    Moises            121 -> 121    unchanged 06-09 01:16:35 to 06-09 03:17:13 (NULL -> review)
--   5795  662   b_keep    Cloggy            29 -> 29      unchanged 06-12 08:23:59 to 06-12 08:53:11 (NULL -> review)
--   5802  668   b_keep    David             28 -> 28      unchanged 06-16 11:09:01 to 06-16 11:37:14 (samsara_stay -> review)
--   5814  680   b_blank   Cloggy            blank -> blank visit not written (blank kept blank), ledger closed
--   5819  684   a_change  Moises -> Cloggy  51 -> 18      06-19 21:52:34 to 06-19 22:10:41 (NULL -> review)
--   6816  703   a_change  Cloggy            10 -> 21      06-25 12:21:23 to 06-25 12:42:15 (samsara_stay -> review)
--   6854  726   a_change  none -> Cloggy    blank -> 12   06-30 13:51:01 to 06-30 14:03:10 (NULL -> review)
--   7054  778   b_keep    Cloggy            29 -> 29      unchanged 07-07 13:11:15 to 07-07 13:39:54 (samsara_stay -> review)
--   7068  791   b_keep    Moises            42 -> 42      unchanged 07-08 22:49:02 to 07-08 23:30:38 (NULL -> review)
--   7069  792   b_keep    Moises            42 -> 42      unchanged 07-08 22:49:02 to 07-08 23:30:38 (NULL -> review)
--   7085  811   b_keep    Cloggy            17 -> 17      unchanged 07-13 21:02:08 to 07-13 21:18:42 (samsara_stay -> review)
--   7088  814   b_keep    Cloggy            17 -> 17      unchanged 07-13 21:02:08 to 07-13 21:18:42 (samsara_stay -> review)
--   7299  880   b_blank   Cloggy            blank -> blank visit not written (blank kept blank), ledger closed
--   7319  881   b_blank   Cloggy            blank -> blank visit not written (blank kept blank), ledger closed
--   7328  882   b_keep    David             35 -> 35      unchanged 07-24 00:24:18 to 07-24 00:59:35 (samsara_stay -> review)
--   7391  909   b_keep    Cloggy            68 -> 68      unchanged 07-29 12:56:15 to 07-29 14:04:00 (samsara_stay -> review)
--   6708  949   b_keep    Cloggy            97 -> 97      unchanged 08-05 06:29:42 to 08-05 08:06:37 (samsara_stay -> review)
--   7065  952   b_keep    Cloggy            97 -> 97      unchanged 08-05 06:29:42 to 08-05 08:06:37 (samsara_stay -> review)
--   6316  955   a_keep    Moises            98 -> 98      unchanged 08-07 01:08:40 to 08-07 02:46:57 (samsara_stay -> review)
--   6751  957   a_keep    Moises            98 -> 98      unchanged 08-07 01:08:40 to 08-07 02:46:57 (samsara_stay -> review)
--   7739  980   b_keep    Cloggy            73 -> 73      unchanged 08-10 18:04:14 to 08-10 19:17:05 (NULL -> review)
--   7745  983   b_keep    Cloggy            191 -> 191    unchanged 08-11 15:18:43 to 08-11 18:29:30 (samsara_stay -> review)
--   7694  1000  a_change  Cloggy            18 -> 40      08-14 00:33:34 to 08-14 01:13:16 (samsara_stay -> review)
--   7757  1009  b_keep    Cloggy            120 -> 120    unchanged 08-14 12:27:19 to 08-14 14:27:29 (NULL -> review)
--   7797  1026  b_keep    Moises            50 -> 50      unchanged 08-18 01:43:07 to 08-18 02:33:10 (samsara_stay -> review)
--   7804  1036  a_change  Cloggy            5 -> 11       08-18 12:43:55 to 08-18 12:54:31 (samsara_stay -> review)
--   6771  1043  b_keep    Cloggy            63 -> 63      unchanged 08-20 08:14:24 to 08-20 09:17:13 (samsara_stay -> review)
--   7828  1046  b_keep    Moises            260 -> 260    unchanged 08-20 06:21:02 to 08-20 10:41:21 (NULL -> review)
--   7834  1068  a_change  Cloggy            9 -> 4        08-24 11:49:25 to 08-24 11:53:54 (NULL -> review)
--   7843  1075  b_keep    Cloggy            57 -> 57      unchanged 08-26 11:45:19 to 08-26 12:42:38 (samsara_stay -> review)
--   7848  1086  b_keep    Moises            69 -> 69      unchanged 08-28 21:58:03 to 08-28 23:07:22 (NULL -> review)
--   6399  1097  b_keep    Moises            100 -> 100    unchanged 09-02 01:09:09 to 09-02 02:48:42 (samsara_stay -> review)
--   6488  1116  b_keep    Moises            70 -> 70      unchanged 09-03 06:48:53 to 09-03 07:59:05 (samsara_stay -> review)
--   8018  1145  b_keep    Moises            84 -> 84      unchanged 09-05 04:02:20 to 09-05 05:25:50 (samsara_stay -> review)
--   8046  1168  b_keep    Cloggy            42 -> 42      unchanged 09-08 15:59:04 to 09-08 16:41:01 (NULL -> review)
--   8051  1170  b_keep    Cloggy            108 -> 108    unchanged 09-09 05:53:19 to 09-09 07:41:40 (samsara_stay -> review)
--   8054  1177  b_keep    Cloggy            45 -> 45      unchanged 09-09 09:57:07 to 09-09 10:42:19 (NULL -> review)
--   6094  1183  b_keep    Moises            90 -> 90      unchanged 09-12 00:03:59 to 09-12 01:34:04 (NULL -> review)
--   6563  1185  b_keep    Moises            90 -> 90      unchanged 09-12 00:03:53 to 09-12 01:34:04 (NULL -> review)
--   8139  1215  b_keep    Cloggy            29 -> 29      unchanged 09-16 14:41:48 to 09-16 15:10:27 (samsara_stay -> review)
--   8177  1239  a_change  Cloggy            192 -> 118    09-22 18:03:32 to 09-22 20:01:35 (NULL -> review)
--   6645  1244  b_keep    Moises            33 -> 33      unchanged 09-24 05:31:36 to 09-24 06:04:36 (samsara_stay -> review)
--   6237  1250  b_keep    Moises            63 -> 63      unchanged 09-25 00:55:43 to 09-25 01:58:38 (samsara_stay -> review)
--   6253  1251  b_keep    Moises            63 -> 63      unchanged 09-25 00:55:43 to 09-25 01:58:38 (samsara_stay -> review)
--   Net minutes: +0 (a blank counted as 0).
-- SHARED STOPS
--   1540 and 1541 take the same Moises interval (one parking; whole to each stands when they are one stop): the one
--   new pairing the VERIFY allows. 3935 keeps sharing with 3932 (both on David's 05-08 stop, as before). Every other
--   written visit may only share time with visits it shared with before (v_visit_shared_time read in this
--   transaction). No split here, so no 1 s seam.
-- THE ROW GUARD
--   Every visit must still hold exactly the values, truck, visit_date and completed_at its ledger row saw, be
--   completed and not deleted, with no bonus decided since the ledger saw it; every ledger row must still be the
--   current stage 4 'proposed' row (PIN). ONE moved row stops the whole file: re-read and re-rehearse instead of forcing.
--   A decided bonus on a kept value (6645) moves nothing.
-- PIN: Stage 0's four bodies (md5); the 101 ledger rows, md5 8f460dc2a51df2fa958de9dec47104d8 of the ordered row text without
--   evidence, input_hashes and alternatives. A second run refuses (the rows are no longer 'proposed').
-- WHAT DOES NOT CHANGE
--   visit_date, start_at, end_at, visit_status, deleted_at, sync_state, the schedule: the VERIFY reads every audit row
--   of this transaction and allows only the four time columns, vehicle_id and updated_at on the 96 written visits.
--   Nothing goes to Jobber (asserted on net.http_request_queue). Every visit is dated before today.
-- CONSEQUENCES: Calendar Hours worked moves on the 11 days the a_change visits are dated (rehearsal, local:
--   samsara-checks/duration_fix_run_2026-10-18/stages/closeout/): 03-09 +14, 03-25 +36, 04-03 -15, 05-08 +26,
--   06-19 -33, 06-25 +11, 06-30 -48 (6854 was counted 60 as one_hour), 08-13 +22, 08-18 +6, 08-24 -5, 09-22 -74 min;
--   today's average estimate moves by +4 min. The two truck changes move to Cloggy's lane. The b_keep / a_keep / b_blank
--   rows move no minute. Rehearsal linker dry run: no change before or after.
--   After applying, dry-run the linker: select public.fn_link_visit_vehicle_stops(false)->'changes';
-- LABEL: x-app-source time-on-site-fix-2026, one reason for the transaction.
-- VERIFY: every row applied and holding its value, truck, date and completion; shape checks; only these visits,
--   only those columns, labelled; controls byte-identical; no Jobber push; no new shared time on a truck except
--   1540/1541; T1 to T6 not newly failing, T7 = T8 = 0.
-- REHEARSED: forward then rollback in one transaction forced to roll back (local, stages/closeout).
-- LOCKS: lock_timeout 3s. Apply between 10:00 and 18:00 ET on a weekday, not :30 to :45 past the hour.
-- ROLLBACK: docs/migrations/2026-10-18_rollback_time_on_site_one_time_fix_cards_closeout.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN
DO $pin$ DECLARE n int; c text; BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'Stage 0 is not applied: the ledger table does not exist'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION '% is not the Stage 0 body', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION '% is not the Stage 0 body', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION '% is not the Stage 0 body', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a1d91a0a28604c25852429d697c1622f' THEN
    RAISE EXCEPTION '% is not the Stage 0 body', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  SELECT count(*), md5(string_agg((to_jsonb(l) - 'evidence' - 'input_hashes' - 'alternatives')::text, E'\n' ORDER BY l.id)) INTO n, c
    FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.run_id = 'tos-fix-2026-r1' AND l.stage = '4' AND l.status = 'proposed'
     AND l.id IN (20, 21, 23, 50, 57, 63, 75, 76, 77, 88, 112, 113, 117, 122, 126, 173, 174, 217, 220, 221, 285, 286, 314, 317, 337, 340, 348, 362, 401, 403, 409, 411, 418, 420, 424, 429, 441, 462, 463, 472, 474, 475, 477, 478, 489, 491, 494, 495, 520, 521, 546, 547, 552, 577, 605, 607, 610, 631, 662, 668, 680, 684, 703, 726, 778, 791, 792, 811, 814, 880, 881, 882, 909, 949, 952, 955, 957, 980, 983, 1000, 1009, 1026, 1036, 1043, 1046, 1068, 1075, 1086, 1097, 1116, 1145, 1168, 1170, 1177, 1183, 1185, 1215, 1239, 1244, 1250, 1251);
  IF n <> 101 OR c IS DISTINCT FROM '8f460dc2a51df2fa958de9dec47104d8' THEN
    RAISE EXCEPTION 'closeout: % ledger rows, checksum %; expected 101, 8f460dc2a51df2fa958de9dec47104d8 (already applied, or a row moved: re-read and re-rehearse)', n, c; END IF;
END $pin$;

-- 1. The rows: ledger id, visit, kind, the values the visit holds now (guard), the new values.
CREATE TEMP TABLE _co_rows ON COMMIT DROP AS
SELECT * FROM (VALUES
  --  lid  visit  kind  cur_min cur_arr cur_dep cur_src cur_veh  new_min new_arr new_dep new_src new_veh  action method confidence decision_ref
  (20, 1259, 'b_keep', 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'samsara_stay', 3, 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (21, 1260, 'b_keep', 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'samsara_stay', 3, 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (23, 1262, 'b_keep', 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'samsara_stay', 3, 100, timestamptz '2026-01-08 00:51:13.032+00', timestamptz '2026-01-08 02:31:13.023+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (50, 1289, 'b_keep', 77, timestamptz '2026-01-16 18:42:24+00', timestamptz '2026-01-16 19:59:25.022+00', NULL, 2, 77, timestamptz '2026-01-16 18:42:24+00', timestamptz '2026-01-16 19:59:25.022+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (57, 1296, 'b_keep', 120, timestamptz '2026-01-19 17:01:33.107+00', timestamptz '2026-01-19 19:01:28.129+00', 'samsara_stay', 2, 120, timestamptz '2026-01-19 17:01:33.107+00', timestamptz '2026-01-19 19:01:28.129+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (63, 1302, 'b_keep', 106, timestamptz '2026-01-21 01:30:41.057+00', timestamptz '2026-01-21 03:16:46.039+00', 'samsara_stay', 3, 106, timestamptz '2026-01-21 01:30:41.057+00', timestamptz '2026-01-21 03:16:46.039+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (75, 1314, 'b_keep', 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'samsara_stay', 3, 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (76, 1315, 'b_keep', 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'samsara_stay', 3, 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (77, 1316, 'b_keep', 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'samsara_stay', 3, 90, timestamptz '2026-01-23 08:11:14.035+00', timestamptz '2026-01-23 09:41:09.022+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (88, 1327, 'b_keep', 98, timestamptz '2026-01-28 10:48:21.008+00', timestamptz '2026-01-28 12:26:11.038+00', 'samsara_stay', 3, 98, timestamptz '2026-01-28 10:48:21.008+00', timestamptz '2026-01-28 12:26:11.038+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (112, 1352, 'b_keep', 110, timestamptz '2026-02-05 02:06:25+00', timestamptz '2026-02-05 03:56:06.038+00', NULL, 3, 110, timestamptz '2026-02-05 02:06:25+00', timestamptz '2026-02-05 03:56:06.038+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (113, 1353, 'b_keep', 46, timestamptz '2026-02-05 06:52:40+00', timestamptz '2026-02-05 07:39:09.005+00', NULL, 3, 46, timestamptz '2026-02-05 06:52:40+00', timestamptz '2026-02-05 07:39:09.005+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (117, 1357, 'b_keep', 116, timestamptz '2026-02-05 09:10:48+00', timestamptz '2026-02-05 11:07:13.08+00', NULL, 3, 116, timestamptz '2026-02-05 09:10:48+00', timestamptz '2026-02-05 11:07:13.08+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (122, 1362, 'b_keep', 51, timestamptz '2026-02-06 18:29:12+00', timestamptz '2026-02-06 19:19:48.041+00', NULL, 2, 51, timestamptz '2026-02-06 18:29:12+00', timestamptz '2026-02-06 19:19:48.041+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (126, 1366, 'b_keep', 19, timestamptz '2026-02-09 01:29:02+00', timestamptz '2026-02-09 01:48:24.035+00', NULL, 3, 19, timestamptz '2026-02-09 01:29:02+00', timestamptz '2026-02-09 01:48:24.035+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (173, 1418, 'b_keep', 73, timestamptz '2026-02-24 19:47:54+00', timestamptz '2026-02-24 21:00:24.02+00', NULL, 3, 73, timestamptz '2026-02-24 19:47:54+00', timestamptz '2026-02-24 21:00:24.02+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (174, 1419, 'b_keep', 6, timestamptz '2026-02-25 18:36:03.013+00', timestamptz '2026-02-25 18:42:17.023+00', 'samsara_stay', 2, 6, timestamptz '2026-02-25 18:36:03.013+00', timestamptz '2026-02-25 18:42:17.023+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (217, 1462, 'b_keep', 29, timestamptz '2026-03-09 21:25:13.014+00', timestamptz '2026-03-09 21:54:09.057+00', 'samsara_stay', 2, 29, timestamptz '2026-03-09 21:25:13.014+00', timestamptz '2026-03-09 21:54:09.057+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (220, 1465, 'a_change', 24, timestamptz '2026-03-10 03:30:12+00', timestamptz '2026-03-10 03:54:29.088+00', NULL, 2, 38, timestamptz '2026-03-10 03:16:29+00', timestamptz '2026-03-10 03:54:52+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (221, 1466, 'b_keep', 102, timestamptz '2026-03-10 03:59:01+00', timestamptz '2026-03-10 05:41:25.089+00', NULL, 2, 102, timestamptz '2026-03-10 03:59:01+00', timestamptz '2026-03-10 05:41:25.089+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (285, 1540, 'a_change', 64, timestamptz '2026-03-26 06:54:52+00', timestamptz '2026-03-26 07:59:13.033+00', NULL, 1, 84, timestamptz '2026-03-26 06:56:35+00', timestamptz '2026-03-26 08:20:40+00', 'review', 1, 'change', 'photo_stamp', 'medium', 'Q11'),
  (286, 1541, 'a_change', 68, timestamptz '2026-03-26 03:15:03+00', timestamptz '2026-03-26 04:22:37.06+00', NULL, 1, 84, timestamptz '2026-03-26 06:56:35+00', timestamptz '2026-03-26 08:20:40+00', 'review', 1, 'change', 'photo_stamp', 'medium', 'Q11'),
  (314, 1571, 'b_keep', 71, timestamptz '2026-04-03 02:38:49.034+00', timestamptz '2026-04-03 03:49:59.014+00', 'samsara_stay', 2, 71, timestamptz '2026-04-03 02:38:49.034+00', timestamptz '2026-04-03 03:49:59.014+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (317, 1574, 'a_change', 33, timestamptz '2026-04-03 21:48:05+00', timestamptz '2026-04-03 22:21:03.038+00', NULL, 2, 18, timestamptz '2026-04-03 21:06:09+00', timestamptz '2026-04-03 21:24:09+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (337, 1597, 'b_keep', 101, timestamptz '2026-04-10 02:59:31+00', timestamptz '2026-04-10 04:40:01.062+00', NULL, 2, 101, timestamptz '2026-04-10 02:59:31+00', timestamptz '2026-04-10 04:40:01.062+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (340, 1601, 'b_keep', 101, timestamptz '2026-04-10 02:59:31+00', timestamptz '2026-04-10 04:40:01.062+00', NULL, 2, 101, timestamptz '2026-04-10 02:59:31+00', timestamptz '2026-04-10 04:40:01.062+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (348, 1707, 'b_keep', 14, timestamptz '2026-04-10 08:02:28.037+00', timestamptz '2026-04-10 08:16:09.019+00', 'samsara_stay', 2, 14, timestamptz '2026-04-10 08:02:28.037+00', timestamptz '2026-04-10 08:16:09.019+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (362, 1598, 'b_keep', 136, timestamptz '2026-04-16 01:36:35+00', timestamptz '2026-04-16 03:52:39.03+00', 'stop_at_completion', 1, 136, timestamptz '2026-04-16 01:36:35+00', timestamptz '2026-04-16 03:52:39.03+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (401, 1740, 'b_keep', 20, timestamptz '2026-04-22 10:47:28.107+00', timestamptz '2026-04-22 11:07:31.059+00', 'samsara_stay', 2, 20, timestamptz '2026-04-22 10:47:28.107+00', timestamptz '2026-04-22 11:07:31.059+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (403, 1749, 'b_keep', 186, timestamptz '2026-04-22 16:56:08+00', timestamptz '2026-04-22 20:01:54+00', NULL, 2, 186, timestamptz '2026-04-22 16:56:08+00', timestamptz '2026-04-22 20:01:54+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (409, 1773, 'b_keep', 245, timestamptz '2026-04-24 03:25:33+00', timestamptz '2026-04-24 07:30:19.278+00', NULL, 1, 245, timestamptz '2026-04-24 03:25:33+00', timestamptz '2026-04-24 07:30:19.278+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (411, 1775, 'b_keep', 245, timestamptz '2026-04-24 03:25:33+00', timestamptz '2026-04-24 07:30:14.337+00', NULL, 1, 245, timestamptz '2026-04-24 03:25:33+00', timestamptz '2026-04-24 07:30:14.337+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (418, 1782, 'b_keep', 209, timestamptz '2026-04-27 03:36:57+00', timestamptz '2026-04-27 07:05:28.056+00', NULL, 1, 209, timestamptz '2026-04-27 03:36:57+00', timestamptz '2026-04-27 07:05:28.056+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (420, 1784, 'b_keep', 25, timestamptz '2026-04-27 11:17:28.273+00', timestamptz '2026-04-27 11:42:50.493+00', 'samsara_stay', 1, 25, timestamptz '2026-04-27 11:17:28.273+00', timestamptz '2026-04-27 11:42:50.493+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (424, 1787, 'b_keep', 277, timestamptz '2026-04-27 21:06:35+00', timestamptz '2026-04-28 01:43:36.542+00', NULL, 2, 277, timestamptz '2026-04-27 21:06:35+00', timestamptz '2026-04-28 01:43:36.542+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (429, 1793, 'b_keep', 44, timestamptz '2026-04-28 20:37:15.069+00', timestamptz '2026-04-28 21:20:56.141+00', 'samsara_stay', 2, 44, timestamptz '2026-04-28 20:37:15.069+00', timestamptz '2026-04-28 21:20:56.141+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (441, 3890, 'b_keep', 107, timestamptz '2026-04-29 21:13:59.041+00', timestamptz '2026-04-29 23:01:07.106+00', 'samsara_stay', 2, 107, timestamptz '2026-04-29 21:13:59.041+00', timestamptz '2026-04-29 23:01:07.106+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (462, 3920, 'b_keep', 61, timestamptz '2026-05-05 03:02:03.135+00', timestamptz '2026-05-05 04:02:39.172+00', 'samsara_stay', 1, 61, timestamptz '2026-05-05 03:02:03.135+00', timestamptz '2026-05-05 04:02:39.172+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (463, 3921, 'b_keep', 52, timestamptz '2026-05-05 17:25:47.546+00', timestamptz '2026-05-05 18:18:10.063+00', 'samsara_stay', 2, 52, timestamptz '2026-05-05 17:25:47.546+00', timestamptz '2026-05-05 18:18:10.063+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (472, 5080, 'b_keep', 68, timestamptz '2026-05-08 10:00:36.394+00', timestamptz '2026-05-08 11:08:43.315+00', 'samsara_stay', 3, 68, timestamptz '2026-05-08 10:00:36.394+00', timestamptz '2026-05-08 11:08:43.315+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (474, 3931, 'b_keep', 50, timestamptz '2026-05-08 13:33:23+00', timestamptz '2026-05-08 14:23:45+00', NULL, 2, 50, timestamptz '2026-05-08 13:33:23+00', timestamptz '2026-05-08 14:23:45+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (475, 3932, 'b_keep', 30, timestamptz '2026-05-08 11:48:36.335+00', timestamptz '2026-05-08 12:18:08.527+00', 'samsara_stay', 3, 30, timestamptz '2026-05-08 11:48:36.335+00', timestamptz '2026-05-08 12:18:08.527+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (477, 3934, 'b_keep', 70, timestamptz '2026-05-08 14:47:41+00', timestamptz '2026-05-08 15:57:55+00', NULL, 2, 70, timestamptz '2026-05-08 14:47:41+00', timestamptz '2026-05-08 15:57:55+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (478, 3935, 'a_change', 30, timestamptz '2026-05-08 11:48:36.335+00', timestamptz '2026-05-08 12:18:08.527+00', 'samsara_stay', 3, 56, timestamptz '2026-05-08 11:21:46+00', timestamptz '2026-05-08 12:18:08+00', 'review', 3, 'change', 'photo_stamp', 'medium', 'Q11'),
  (489, 5636, 'b_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, NULL::bigint, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, NULL::bigint, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (491, 3903, 'b_keep', 205, timestamptz '2026-05-13 02:53:29+00', timestamptz '2026-05-13 06:18:15+00', NULL, 1, 205, timestamptz '2026-05-13 02:53:29+00', timestamptz '2026-05-13 06:18:15+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (494, 5081, 'b_keep', 153, timestamptz '2026-05-12 11:00:25+00', timestamptz '2026-05-12 13:33:29+00', NULL, 1, 153, timestamptz '2026-05-12 11:00:25+00', timestamptz '2026-05-12 13:33:29+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (495, 5082, 'b_keep', 153, timestamptz '2026-05-12 11:00:25+00', timestamptz '2026-05-12 13:33:29+00', NULL, 1, 153, timestamptz '2026-05-12 11:00:25+00', timestamptz '2026-05-12 13:33:29+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (520, 5100, 'b_keep', 129, timestamptz '2026-05-18 06:44:57.549+00', timestamptz '2026-05-18 08:53:50.242+00', 'samsara_stay', 1, 129, timestamptz '2026-05-18 06:44:57.549+00', timestamptz '2026-05-18 08:53:50.242+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (521, 5101, 'b_keep', 84, timestamptz '2026-05-18 08:58:30.505+00', timestamptz '2026-05-18 10:22:13.146+00', 'samsara_stay', 1, 84, timestamptz '2026-05-18 08:58:30.505+00', timestamptz '2026-05-18 10:22:13.146+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (546, 5028, 'a_keep', 54, timestamptz '2026-05-21 10:09:13.516+00', timestamptz '2026-05-21 11:02:48.515+00', 'samsara_stay', 3, 54, timestamptz '2026-05-21 10:09:13.516+00', timestamptz '2026-05-21 11:02:48.515+00', 'review', 3, 'lock_decided', 'photo_stamp', 'medium', 'Q11'),
  (547, 5043, 'b_keep', 19, timestamptz '2026-05-21 11:28:00.515+00', timestamptz '2026-05-21 11:46:35.566+00', 'samsara_stay', 3, 19, timestamptz '2026-05-21 11:28:00.515+00', timestamptz '2026-05-21 11:46:35.566+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (552, 5133, 'b_keep', 65, timestamptz '2026-05-23 15:04:49.275+00', timestamptz '2026-05-23 16:10:14.147+00', 'samsara_stay', 2, 65, timestamptz '2026-05-23 15:04:49.275+00', timestamptz '2026-05-23 16:10:14.147+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (577, 5159, 'b_keep', 65, timestamptz '2026-05-29 03:41:33+00', timestamptz '2026-05-29 04:46:48+00', NULL, 2, 65, timestamptz '2026-05-29 03:41:33+00', timestamptz '2026-05-29 04:46:48+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (605, 5732, 'b_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (607, 5734, 'b_keep', 129, timestamptz '2026-06-03 18:48:29.476+00', timestamptz '2026-06-03 20:57:52.503+00', 'samsara_stay', 2, 129, timestamptz '2026-06-03 18:48:29.476+00', timestamptz '2026-06-03 20:57:52.503+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (610, 5736, 'a_keep', 19, timestamptz '2026-06-04 10:34:32.518+00', timestamptz '2026-06-04 10:53:28.109+00', 'samsara_stay', 1, 19, timestamptz '2026-06-04 10:34:32.518+00', timestamptz '2026-06-04 10:53:28.109+00', 'review', 1, 'lock_decided', 'photo_stamp', 'medium', 'Q11'),
  (631, 5755, 'a_keep', 121, timestamptz '2026-06-09 05:16:35+00', timestamptz '2026-06-09 07:17:13+00', NULL, 1, 121, timestamptz '2026-06-09 05:16:35+00', timestamptz '2026-06-09 07:17:13+00', 'review', 1, 'lock_decided', 'photo_stamp', 'medium', 'Q11'),
  (662, 5795, 'b_keep', 29, timestamptz '2026-06-12 12:23:59+00', timestamptz '2026-06-12 12:53:11+00', NULL, 2, 29, timestamptz '2026-06-12 12:23:59+00', timestamptz '2026-06-12 12:53:11+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (668, 5802, 'b_keep', 28, timestamptz '2026-06-16 15:09:01.138+00', timestamptz '2026-06-16 15:37:14.641+00', 'samsara_stay', 3, 28, timestamptz '2026-06-16 15:09:01.138+00', timestamptz '2026-06-16 15:37:14.641+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (680, 5814, 'b_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (684, 5819, 'a_change', 51, timestamptz '2026-06-19 04:58:01+00', timestamptz '2026-06-19 05:49:25+00', NULL, 1, 18, timestamptz '2026-06-20 01:52:34+00', timestamptz '2026-06-20 02:10:41+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (703, 6816, 'a_change', 10, timestamptz '2026-06-25 16:21:23.365+00', timestamptz '2026-06-25 16:31:38.521+00', 'samsara_stay', 2, 21, timestamptz '2026-06-25 16:21:23+00', timestamptz '2026-06-25 16:42:15+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (726, 6854, 'a_change', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, NULL::bigint, 12, timestamptz '2026-06-30 17:51:01+00', timestamptz '2026-06-30 18:03:10+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (778, 7054, 'b_keep', 29, timestamptz '2026-07-07 17:11:15.515+00', timestamptz '2026-07-07 17:39:54.51+00', 'samsara_stay', 2, 29, timestamptz '2026-07-07 17:11:15.515+00', timestamptz '2026-07-07 17:39:54.51+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (791, 7068, 'b_keep', 42, timestamptz '2026-07-09 02:49:02+00', timestamptz '2026-07-09 03:30:38+00', NULL, 1, 42, timestamptz '2026-07-09 02:49:02+00', timestamptz '2026-07-09 03:30:38+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (792, 7069, 'b_keep', 42, timestamptz '2026-07-09 02:49:02+00', timestamptz '2026-07-09 03:30:38+00', NULL, 1, 42, timestamptz '2026-07-09 02:49:02+00', timestamptz '2026-07-09 03:30:38+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (811, 7085, 'b_keep', 17, timestamptz '2026-07-14 01:02:08.497+00', timestamptz '2026-07-14 01:18:42.489+00', 'samsara_stay', 2, 17, timestamptz '2026-07-14 01:02:08.497+00', timestamptz '2026-07-14 01:18:42.489+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (814, 7088, 'b_keep', 17, timestamptz '2026-07-14 01:02:08.497+00', timestamptz '2026-07-14 01:18:42.489+00', 'samsara_stay', 2, 17, timestamptz '2026-07-14 01:02:08.497+00', timestamptz '2026-07-14 01:18:42.489+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (880, 7299, 'b_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (881, 7319, 'b_blank', NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, NULL::int, NULL::timestamptz, NULL::timestamptz, NULL, 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (882, 7328, 'b_keep', 35, timestamptz '2026-07-24 04:24:18.614+00', timestamptz '2026-07-24 04:59:35.508+00', 'samsara_stay', 3, 35, timestamptz '2026-07-24 04:24:18.614+00', timestamptz '2026-07-24 04:59:35.508+00', 'review', 3, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (909, 7391, 'b_keep', 68, timestamptz '2026-07-29 16:56:15.5+00', timestamptz '2026-07-29 18:04:00.015+00', 'samsara_stay', 2, 68, timestamptz '2026-07-29 16:56:15.5+00', timestamptz '2026-07-29 18:04:00.015+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (949, 6708, 'b_keep', 97, timestamptz '2026-08-05 10:29:42.513+00', timestamptz '2026-08-05 12:06:37.515+00', 'samsara_stay', 2, 97, timestamptz '2026-08-05 10:29:42.513+00', timestamptz '2026-08-05 12:06:37.515+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (952, 7065, 'b_keep', 97, timestamptz '2026-08-05 10:29:42.513+00', timestamptz '2026-08-05 12:06:37.515+00', 'samsara_stay', 2, 97, timestamptz '2026-08-05 10:29:42.513+00', timestamptz '2026-08-05 12:06:37.515+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (955, 6316, 'a_keep', 98, timestamptz '2026-08-07 05:08:40.495+00', timestamptz '2026-08-07 06:46:57.518+00', 'samsara_stay', 1, 98, timestamptz '2026-08-07 05:08:40.495+00', timestamptz '2026-08-07 06:46:57.518+00', 'review', 1, 'lock_decided', 'photo_stamp', 'medium', 'Q11'),
  (957, 6751, 'a_keep', 98, timestamptz '2026-08-07 05:08:40.495+00', timestamptz '2026-08-07 06:46:57.518+00', 'samsara_stay', 1, 98, timestamptz '2026-08-07 05:08:40.495+00', timestamptz '2026-08-07 06:46:57.518+00', 'review', 1, 'lock_decided', 'photo_stamp', 'medium', 'Q11'),
  (980, 7739, 'b_keep', 73, timestamptz '2026-08-10 22:04:14+00', timestamptz '2026-08-10 23:17:05+00', NULL, 2, 73, timestamptz '2026-08-10 22:04:14+00', timestamptz '2026-08-10 23:17:05+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (983, 7745, 'b_keep', 191, timestamptz '2026-08-11 19:18:43.51+00', timestamptz '2026-08-11 22:29:30.524+00', 'samsara_stay', 2, 191, timestamptz '2026-08-11 19:18:43.51+00', timestamptz '2026-08-11 22:29:30.524+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1000, 7694, 'a_change', 18, timestamptz '2026-08-14 04:37:22.506+00', timestamptz '2026-08-14 04:55:11.518+00', 'samsara_stay', 2, 40, timestamptz '2026-08-14 04:33:34+00', timestamptz '2026-08-14 05:13:16+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (1009, 7757, 'b_keep', 120, timestamptz '2026-08-14 16:27:19+00', timestamptz '2026-08-14 18:27:29+00', NULL, 2, 120, timestamptz '2026-08-14 16:27:19+00', timestamptz '2026-08-14 18:27:29+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1026, 7797, 'b_keep', 50, timestamptz '2026-08-18 05:43:07.564+00', timestamptz '2026-08-18 06:33:10.535+00', 'samsara_stay', 1, 50, timestamptz '2026-08-18 05:43:07.564+00', timestamptz '2026-08-18 06:33:10.535+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1036, 7804, 'a_change', 5, timestamptz '2026-08-18 16:43:55.51+00', timestamptz '2026-08-18 16:49:00.508+00', 'samsara_stay', 2, 11, timestamptz '2026-08-18 16:43:55+00', timestamptz '2026-08-18 16:54:31+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (1043, 6771, 'b_keep', 63, timestamptz '2026-08-20 12:14:24.503+00', timestamptz '2026-08-20 13:17:13.548+00', 'samsara_stay', 2, 63, timestamptz '2026-08-20 12:14:24.503+00', timestamptz '2026-08-20 13:17:13.548+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1046, 7828, 'b_keep', 260, timestamptz '2026-08-20 10:21:02+00', timestamptz '2026-08-20 14:41:21+00', NULL, 1, 260, timestamptz '2026-08-20 10:21:02+00', timestamptz '2026-08-20 14:41:21+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1068, 7834, 'a_change', 9, timestamptz '2026-08-24 21:06:11+00', timestamptz '2026-08-24 21:14:51+00', NULL, 2, 4, timestamptz '2026-08-24 15:49:25+00', timestamptz '2026-08-24 15:53:54+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (1075, 7843, 'b_keep', 57, timestamptz '2026-08-26 15:45:19.513+00', timestamptz '2026-08-26 16:42:38.522+00', 'samsara_stay', 2, 57, timestamptz '2026-08-26 15:45:19.513+00', timestamptz '2026-08-26 16:42:38.522+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1086, 7848, 'b_keep', 69, timestamptz '2026-08-29 01:58:03+00', timestamptz '2026-08-29 03:07:22+00', NULL, 1, 69, timestamptz '2026-08-29 01:58:03+00', timestamptz '2026-08-29 03:07:22+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1097, 6399, 'b_keep', 100, timestamptz '2026-09-02 05:09:09.564+00', timestamptz '2026-09-02 06:48:42.511+00', 'samsara_stay', 1, 100, timestamptz '2026-09-02 05:09:09.564+00', timestamptz '2026-09-02 06:48:42.511+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1116, 6488, 'b_keep', 70, timestamptz '2026-09-03 10:48:53.512+00', timestamptz '2026-09-03 11:59:05.521+00', 'samsara_stay', 1, 70, timestamptz '2026-09-03 10:48:53.512+00', timestamptz '2026-09-03 11:59:05.521+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1145, 8018, 'b_keep', 84, timestamptz '2026-09-05 08:02:20.501+00', timestamptz '2026-09-05 09:25:50.512+00', 'samsara_stay', 1, 84, timestamptz '2026-09-05 08:02:20.501+00', timestamptz '2026-09-05 09:25:50.512+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1168, 8046, 'b_keep', 42, timestamptz '2026-09-08 19:59:04+00', timestamptz '2026-09-08 20:41:01+00', NULL, 2, 42, timestamptz '2026-09-08 19:59:04+00', timestamptz '2026-09-08 20:41:01+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1170, 8051, 'b_keep', 108, timestamptz '2026-09-09 09:53:19.504+00', timestamptz '2026-09-09 11:41:40.784+00', 'samsara_stay', 2, 108, timestamptz '2026-09-09 09:53:19.504+00', timestamptz '2026-09-09 11:41:40.784+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1177, 8054, 'b_keep', 45, timestamptz '2026-09-09 13:57:07+00', timestamptz '2026-09-09 14:42:19+00', NULL, 2, 45, timestamptz '2026-09-09 13:57:07+00', timestamptz '2026-09-09 14:42:19+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1183, 6094, 'b_keep', 90, timestamptz '2026-09-12 04:03:59+00', timestamptz '2026-09-12 05:34:04+00', NULL, 1, 90, timestamptz '2026-09-12 04:03:59+00', timestamptz '2026-09-12 05:34:04+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1185, 6563, 'b_keep', 90, timestamptz '2026-09-12 04:03:53+00', timestamptz '2026-09-12 05:34:04+00', NULL, 1, 90, timestamptz '2026-09-12 04:03:53+00', timestamptz '2026-09-12 05:34:04+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1215, 8139, 'b_keep', 29, timestamptz '2026-09-16 18:41:48.519+00', timestamptz '2026-09-16 19:10:27.515+00', 'samsara_stay', 2, 29, timestamptz '2026-09-16 18:41:48.519+00', timestamptz '2026-09-16 19:10:27.515+00', 'review', 2, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1239, 8177, 'a_change', 192, timestamptz '2026-09-22 16:29:43+00', timestamptz '2026-09-22 19:41:17+00', NULL, 2, 118, timestamptz '2026-09-22 22:03:32+00', timestamptz '2026-09-23 00:01:35+00', 'review', 2, 'change', 'photo_stamp', 'medium', 'Q11'),
  (1244, 6645, 'b_keep', 33, timestamptz '2026-09-24 09:31:36.51+00', timestamptz '2026-09-24 10:04:36.511+00', 'samsara_stay', 1, 33, timestamptz '2026-09-24 09:31:36.51+00', timestamptz '2026-09-24 10:04:36.511+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1250, 6237, 'b_keep', 63, timestamptz '2026-09-25 04:55:43.519+00', timestamptz '2026-09-25 05:58:38.504+00', 'samsara_stay', 1, 63, timestamptz '2026-09-25 04:55:43.519+00', timestamptz '2026-09-25 05:58:38.504+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout'),
  (1251, 6253, 'b_keep', 63, timestamptz '2026-09-25 04:55:43.519+00', timestamptz '2026-09-25 05:58:38.504+00', 'samsara_stay', 1, 63, timestamptz '2026-09-25 04:55:43.519+00', timestamptz '2026-09-25 05:58:38.504+00', 'review', 1, 'lock_decided', 'card_keep_saved', 'person', 'cards-closeout')
) AS t(lid, visit_id, kind, cur_min, cur_arr, cur_dep, cur_src, cur_veh, new_min, new_arr, new_dep, new_src, new_veh, action, method, confidence, decision_ref);

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('co:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('co:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('co:checks0', public.fn_time_on_site_checks()),
  ('co:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1311))),
  ('co:shared0', (SELECT coalesce(jsonb_object_agg(s.visit_id, (SELECT jsonb_agg(x->'visit_id') FROM jsonb_array_elements(s.shared_with) x)), '{}')
                    FROM public.v_visit_shared_time s WHERE s.visit_id IN (SELECT visit_id FROM _co_rows) AND s.shared_with_count > 0));

-- 2. Lock, then the guard: any moved row stops the file.
DO $lock$ DECLARE bad jsonb; BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT visit_id FROM _co_rows) FOR UPDATE;
  PERFORM 1 FROM public.visit_time_on_site_corrections l WHERE l.id IN (SELECT lid FROM _co_rows) FOR UPDATE;
  IF (SELECT count(*) FROM _co_rows) <> 101 OR (SELECT count(DISTINCT visit_id) FROM _co_rows) <> 101 THEN RAISE EXCEPTION 'closeout: row list is not 101 distinct visits'; END IF;
  SELECT jsonb_object_agg(r.visit_id, CASE
           WHEN v.id IS NULL THEN 'missing'
           WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
           WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src) THEN 'time_moved'
           WHEN v.vehicle_id IS DISTINCT FROM r.cur_veh THEN 'truck_moved'
           WHEN l.id IS NULL OR l.visit_id <> r.visit_id OR l.superseded_at IS NOT NULL OR l.status <> 'proposed' OR l.stage <> '4' THEN 'ledger_row_not_current'
           WHEN (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh) THEN 'ledger_old_differs'
           WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at) THEN 'date_or_completion_moved'
           WHEN (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen THEN 'bonus_decided'
           WHEN l.truck_stage IS NOT NULL THEN 'truck_part_already_set'
         END)
    INTO bad
    FROM _co_rows r LEFT JOIN public.visits v ON v.id = r.visit_id LEFT JOIN public.visit_time_on_site_corrections l ON l.id = r.lid
   WHERE v.id IS NULL OR l.id IS NULL OR v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL
      OR (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src)
      OR v.vehicle_id IS DISTINCT FROM r.cur_veh OR l.visit_id <> r.visit_id OR l.superseded_at IS NOT NULL OR l.status <> 'proposed' OR l.stage <> '4'
      OR (l.old_minutes, l.old_arrival, l.old_departure, l.old_source, l.old_vehicle_id) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_src, r.cur_veh)
      OR (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at)
      OR (SELECT max(b.bonus_decided_at) FROM public.visit_reviews b WHERE b.visit_id = r.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen
      OR l.truck_stage IS NOT NULL;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'closeout: rows moved since they were read, nothing written: %', bad; END IF;
END $lock$;

-- 3. Write the visits (not the blanks), labelled, then every ledger row, in the same transaction.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-2026',
         'x-change-reason', 'One-time 2026 duration fix, the cards close out, run tos-fix-2026-r1, Fred''s go-ahead of 2026-10-19: the photo-settled cards accepted, every other card keeps its saved time, locked as review. Method, evidence and decision per visit in public.visit_time_on_site_corrections. Not pushed to Jobber.'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = r.new_min, actual_arrival_at = r.new_arr, actual_departure_at = r.new_dep,
         time_on_site_source = r.new_src, vehicle_id = r.new_veh
    FROM _co_rows r WHERE v.id = r.visit_id AND r.kind <> 'b_blank';
  GET DIAGNOSTICS n = row_count;
  IF n <> 96 THEN RAISE EXCEPTION 'closeout: wrote % visits, expected 96', n; END IF;
  UPDATE public.visit_time_on_site_corrections l
     SET evidence = l.evidence || jsonb_build_object(
           'co_before', jsonb_build_object('status', l.status, 'action', l.action, 'method', l.method, 'confidence', l.confidence,
              'decision_ref', l.decision_ref, 'new_arrival', l.new_arrival, 'new_departure', l.new_departure, 'new_minutes', l.new_minutes,
              'new_source', l.new_source, 'new_vehicle_id', l.new_vehicle_id, 'truck_stage', l.truck_stage, 'truck_status', l.truck_status,
              'truck_applied_at', l.truck_applied_at, 'applied_at', l.applied_at, 'applied_by_migration', l.applied_by_migration),
           'co_before_visit', jsonb_build_object('duration_minutes', r.cur_min, 'actual_arrival_at', r.cur_arr, 'actual_departure_at', r.cur_dep,
              'time_on_site_source', r.cur_src, 'vehicle_id', r.cur_veh),
           'co', jsonb_build_object('kind', r.kind, 'visit_written', r.kind <> 'b_blank',
              'decided', CASE WHEN r.kind LIKE 'a_%' THEN 'Fred 2026-10-19: accept the photo-settled cards as a batch'
                              ELSE 'Fred 2026-10-19: close the other cards as keep the saved time, locked' END,
              'source', CASE WHEN r.kind LIKE 'a_%' THEN 'ledger/cards.md section 8, interval re-derived from P and V (local)' ELSE 'ledger/cards.md (local)' END)),
         status = 'applied', applied_at = now(),
         applied_by_migration = '2026-10-18_2023_time_on_site_one_time_fix_cards_closeout.sql',
         action = r.action, method = r.method, confidence = r.confidence, decision_ref = r.decision_ref,
         new_arrival = r.new_arr, new_departure = r.new_dep, new_minutes = r.new_min, new_source = r.new_src, new_vehicle_id = r.new_veh,
         truck_stage = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN '1' ELSE l.truck_stage END,
         truck_status = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN 'applied' ELSE l.truck_status END,
         truck_applied_at = CASE WHEN r.new_veh IS DISTINCT FROM l.old_vehicle_id THEN now() ELSE l.truck_applied_at END
    FROM _co_rows r WHERE l.id = r.lid;
  GET DIAGNOSTICS n = row_count;
  IF n <> 101 THEN RAISE EXCEPTION 'closeout: marked % ledger rows, expected 101', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 4. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; a0 bigint; ck jsonb; ck0 jsonb; t text; bad jsonb;
BEGIN
  -- (b) every row holds its value, truck, date and completion, visit and ledger alike (a blank stays exactly as it was)
  SELECT count(*) INTO n FROM _co_rows r JOIN public.visits v ON v.id = r.visit_id JOIN public.visit_time_on_site_corrections l ON l.id = r.lid
   WHERE l.status <> 'applied' OR l.superseded_at IS NOT NULL OR l.applied_by_migration IS DISTINCT FROM '2026-10-18_2023_time_on_site_one_time_fix_cards_closeout.sql'
      OR (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src, r.new_veh)
      OR (l.new_minutes, l.new_arrival, l.new_departure, l.new_source, l.new_vehicle_id) IS DISTINCT FROM (r.new_min, r.new_arr, r.new_dep, r.new_src, r.new_veh)
      OR (r.kind <> 'b_blank' AND r.new_src IS DISTINCT FROM 'review')
      OR (r.kind = 'b_blank' AND (r.new_min, r.new_src, r.new_veh) IS DISTINCT FROM (r.cur_min, r.cur_src, r.cur_veh))
      OR (r.kind <> 'a_change' AND (r.new_min, r.new_arr, r.new_dep, r.new_veh) IS DISTINCT FROM (r.cur_min, r.cur_arr, r.cur_dep, r.cur_veh))
      OR (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at)
      OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % rows do not hold their new value', n; END IF;
  -- (b1) the trucks: only 6854 and 5819 change, both to Cloggy (2), and their truck part is applied; 1465 keeps Cloggy
  SELECT jsonb_object_agg(r.visit_id, r.new_veh) INTO bad FROM _co_rows r WHERE r.new_veh IS DISTINCT FROM r.cur_veh;
  IF bad IS DISTINCT FROM '{"5819": 2, "6854": 2}'::jsonb THEN RAISE EXCEPTION 'VERIFY closeout: truck changes are %', bad; END IF;
  SELECT count(*) INTO n FROM _co_rows r JOIN public.visit_time_on_site_corrections l ON l.id = r.lid
   WHERE (r.new_veh IS DISTINCT FROM r.cur_veh) <> (l.truck_stage = '1' AND l.truck_status = 'applied' AND l.truck_applied_at IS NOT NULL);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % truck parts not as expected', n; END IF;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 1465) IS DISTINCT FROM 2::bigint THEN RAISE EXCEPTION 'VERIFY closeout: 1465 must keep Cloggy (its truck change is held)'; END IF;
  -- (b2) shape on the written visits: all set, at most 719 min, departure after arrival, minutes = departure - arrival within 1 min
  SELECT count(*) INTO n FROM _co_rows r JOIN public.visits v ON v.id = r.visit_id
   WHERE r.kind <> 'b_blank' AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) <> 0 OR v.duration_minutes > 719
      OR v.actual_departure_at <= v.actual_arrival_at
      OR abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % written values fail the shape checks', n; END IF;
  -- (c) only the 96 written visits changed, once each, and only in the time columns and vehicle_id
  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'co:audit_id0');
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> 96 THEN RAISE EXCEPTION 'VERIFY closeout: % audit rows on public.visits, expected 96', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _co_rows WHERE kind <> 'b_blank')
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % visit writes outside the set, outside the allowed columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % audit rows on other tables', n; END IF;
  -- (d) the controls are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1311))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'co:controls') THEN RAISE EXCEPTION 'VERIFY closeout: a control visit changed'; END IF;
  -- (e) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'co:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _co_rows);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY closeout: % Jobber push requests queued', n; END IF;
  -- (g) no visit of the set shares time on its truck with a visit it did not share with before, except 1540 with 1541
  SELECT jsonb_object_agg(s.visit_id, x.other) INTO bad
    FROM public.v_visit_shared_time s CROSS JOIN LATERAL (SELECT (e->>'visit_id')::bigint AS other FROM jsonb_array_elements(s.shared_with) e) x
   WHERE s.visit_id IN (SELECT visit_id FROM _co_rows) AND s.shared_with_count > 0
     AND NOT coalesce((SELECT j->s.visit_id::text FROM _tos_ctx WHERE k = 'co:shared0') @> to_jsonb(x.other), false)
     AND (s.visit_id, x.other) NOT IN ((1540, 1541), (1541, 1540));
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY closeout: new shared time on a truck: %', bad; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'co:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY closeout: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY closeout: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  INSERT INTO _tos_report VALUES ('closeout', jsonb_build_object(
    'rows', (SELECT jsonb_object_agg(k, c) FROM (SELECT kind k, count(*) c FROM _co_rows GROUP BY 1) x),
    'visits_written', (SELECT count(*) FROM _co_rows WHERE kind <> 'b_blank'), 'checks', ck - 'T_detail',
    'net_minutes', (SELECT sum(coalesce(new_min, 0) - coalesce(cur_min, 0)) FROM _co_rows),
    'trucks_changed', (SELECT jsonb_object_agg(r.visit_id, v.vehicle_id) FROM _co_rows r JOIN public.visits v ON v.id = r.visit_id WHERE r.new_veh IS DISTINCT FROM r.cur_veh)));
  RAISE NOTICE 'closeout: 96 visits written, 101 ledger rows applied';
END $v$;

COMMIT;
