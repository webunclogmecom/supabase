-- ============================================================================
-- 2026-10-14_1021 Time on site, step 6b: correct the 106 values saved before Aug 20 that the GPS and Samsara both prove wrong
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "go ahead with step 6". scripts/checks/time_on_site_audit.mjs over 2026-01-01..2026-08-19
--   (fn_time_on_site_audit_gps, 2026-10-14_1020, + Samsara /v1/fleet/trips): 970 saved client values, 550 agree,
--   106 pass the step 5 gate, the rest are on the review list (samsara-checks/time_on_site_audit_before_aug20.html,
--   outside the repos).
-- THE GATE: step 5's (unshared reference holding the completion, no other completion inside, no truck question, not
--   stale, Samsara within 5 min at both ends, flagged, not reviewed, neighbours all or none), plus one added for step 6:
--   a wrong stay is not corrected onto a stop under 15 min (the truck dropping by to close the job: 1331, 3907, 5673
--   stay on the review list). Measured: worst Samsara end difference 4.4 min, median 1.0. The large fixes are
--   neighbours that each saved the whole night on the block (1591 / 1592 207 -> 59 / 38) and the old 04:00 cut
--   (3926 13 -> 176).
-- 20 carry a bonus decision still pending: 5841, 5844, 5847, 5858, 5843, 6486, 6982, 6497, 6426, 6573, 6499, 6241, 5877, 6188, 6104, 6366, 7683, 7738, 7693, 7696.
-- SAFETY: written only where the row still holds the snapshot; every reference is re-read from fn_time_on_site_audit_gps
--   first. Old values: backups/2026-10-14_time_on_site_step6_corrections_before.json (workspace) and audit.logs old_row.
--   Labelled time-on-site-audit. Nothing reaches Jobber.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TEMP TABLE _fix6 (visit_id bigint, visit_date date, s_arr timestamptz, s_dep timestamptz, s_min int, s_src text,
                          arrival timestamptz, departure timestamptz, samsara_minutes int) ON COMMIT DROP;
INSERT INTO _fix6 VALUES
    (1244, date '2026-01-04', timestamptz '2026-01-05T08:54:15+00:00', timestamptz '2026-01-05T08:59:32.014+00:00', 5, NULL::text, timestamptz '2026-01-05T08:54:15+00:00', timestamptz '2026-01-05T09:27:27.034+00:00', 31),
    (1257, date '2026-01-06', timestamptz '2026-01-07T08:44:04+00:00', timestamptz '2026-01-07T08:59:55.001+00:00', 16, NULL::text, timestamptz '2026-01-07T08:44:26+00:00', timestamptz '2026-01-07T09:08:41.088+00:00', 23),
    (1275, date '2026-01-13', timestamptz '2026-01-14T07:59:25+00:00', timestamptz '2026-01-14T08:55:44.021+00:00', 56, NULL::text, timestamptz '2026-01-14T02:41:15+00:00', timestamptz '2026-01-14T03:35:22.032+00:00', 50),
    (1283, date '2026-01-14', timestamptz '2026-01-15T06:16:24+00:00', timestamptz '2026-01-15T06:43:57.081+00:00', 28, NULL::text, timestamptz '2026-01-15T09:15:58+00:00', timestamptz '2026-01-15T09:31:43.023+00:00', 15),
    (1295, date '2026-01-18', timestamptz '2026-01-19T08:10:42+00:00', timestamptz '2026-01-19T08:59:48.084+00:00', 49, NULL::text, timestamptz '2026-01-19T08:11:33+00:00', timestamptz '2026-01-19T09:06:59.993+00:00', 55),
    (1300, date '2026-01-19', timestamptz '2026-01-20T08:32:53+00:00', timestamptz '2026-01-20T08:57:27.019+00:00', 25, NULL::text, timestamptz '2026-01-20T08:33:51+00:00', timestamptz '2026-01-20T09:19:50.02+00:00', 46),
    (1304, date '2026-01-20', timestamptz '2026-01-21T07:13:39+00:00', timestamptz '2026-01-21T07:31:44.056+00:00', 18, NULL::text, timestamptz '2026-01-21T10:10:51+00:00', timestamptz '2026-01-21T10:40:28.037+00:00', 28),
    (1305, date '2026-01-20', timestamptz '2026-01-21T03:33:27+00:00', timestamptz '2026-01-21T04:06:44.041+00:00', 33, NULL::text, timestamptz '2026-01-21T10:54:10+00:00', timestamptz '2026-01-21T11:15:38.042+00:00', 20),
    (1307, date '2026-01-21', timestamptz '2026-01-22T06:52:51+00:00', timestamptz '2026-01-22T07:25:58.058+00:00', 33, NULL::text, timestamptz '2026-01-22T02:00:05+00:00', timestamptz '2026-01-22T02:26:04.995+00:00', 24),
    (1321, date '2026-01-26', timestamptz '2026-01-26T14:12:15+00:00', timestamptz '2026-01-26T16:56:13.129+00:00', 164, NULL::text, timestamptz '2026-01-26T19:08:21+00:00', timestamptz '2026-01-26T20:05:49.04+00:00', 56),
    (1324, date '2026-01-27', timestamptz '2026-01-28T02:26:03+00:00', timestamptz '2026-01-28T04:21:18.512+00:00', 115, NULL::text, timestamptz '2026-01-28T08:59:39+00:00', timestamptz '2026-01-28T09:51:31.015+00:00', 52),
    (1326, date '2026-01-27', timestamptz '2026-01-28T02:26:03+00:00', timestamptz '2026-01-28T04:07:15.015+00:00', 101, NULL::text, timestamptz '2026-01-28T08:04:37+00:00', timestamptz '2026-01-28T08:52:48.018+00:00', 48),
    (1329, date '2026-01-28', timestamptz '2026-01-29T03:32:28+00:00', timestamptz '2026-01-29T04:00:35.024+00:00', 28, NULL::text, timestamptz '2026-01-29T07:01:46+00:00', timestamptz '2026-01-29T07:20:14.015+00:00', 17),
    (1358, date '2026-02-05', timestamptz '2026-02-05T04:24:34+00:00', timestamptz '2026-02-05T06:17:15.058+00:00', 113, NULL::text, timestamptz '2026-02-06T04:03:54+00:00', timestamptz '2026-02-06T05:02:57.161+00:00', 58),
    (1360, date '2026-02-05', timestamptz '2026-02-06T06:52:08+00:00', timestamptz '2026-02-06T07:41:26.002+00:00', 49, NULL::text, timestamptz '2026-02-06T07:08:38+00:00', timestamptz '2026-02-06T07:40:36.191+00:00', 31),
    (1369, date '2026-02-09', timestamptz '2026-02-10T04:29:47+00:00', timestamptz '2026-02-10T05:38:01.046+00:00', 68, NULL::text, timestamptz '2026-02-10T07:31:29+00:00', timestamptz '2026-02-10T08:20:58.029+00:00', 48),
    (1375, date '2026-02-10', timestamptz '2026-02-11T04:20:25+00:00', timestamptz '2026-02-11T06:19:50.994+00:00', 119, NULL::text, timestamptz '2026-02-11T09:24:10+00:00', timestamptz '2026-02-11T09:49:37.039+00:00', 24),
    (1379, date '2026-02-11', timestamptz '2026-02-12T08:37:48+00:00', timestamptz '2026-02-12T08:59:35.089+00:00', 22, NULL::text, timestamptz '2026-02-12T08:37:48+00:00', timestamptz '2026-02-12T09:13:32.07+00:00', 34),
    (1403, date '2026-02-18', timestamptz '2026-02-19T08:33:10+00:00', timestamptz '2026-02-19T08:59:52.015+00:00', 27, NULL::text, timestamptz '2026-02-19T08:33:54+00:00', timestamptz '2026-02-19T09:52:56.055+00:00', 78),
    (1410, date '2026-02-19', timestamptz '2026-02-20T06:08:04+00:00', timestamptz '2026-02-20T06:47:56.073+00:00', 40, NULL::text, timestamptz '2026-02-20T06:08:15+00:00', timestamptz '2026-02-20T06:22:43.035+00:00', 13),
    (1414, date '2026-02-23', timestamptz '2026-02-23T20:52:50+00:00', timestamptz '2026-02-23T21:42:20.053+00:00', 50, NULL::text, timestamptz '2026-02-23T22:13:11+00:00', timestamptz '2026-02-23T22:32:15.073+00:00', 17),
    (1427, date '2026-02-26', timestamptz '2026-02-27T03:41:12+00:00', timestamptz '2026-02-27T05:47:45.016+00:00', 127, NULL::text, timestamptz '2026-02-27T03:41:24+00:00', timestamptz '2026-02-27T04:48:44.029+00:00', 66),
    (1429, date '2026-02-26', timestamptz '2026-02-27T03:40:40+00:00', timestamptz '2026-02-27T06:45:15.057+00:00', 185, NULL::text, timestamptz '2026-02-27T05:37:50+00:00', timestamptz '2026-02-27T06:45:03.083+00:00', 64),
    (1444, date '2026-03-04', timestamptz '2026-03-04T05:42:23+00:00', timestamptz '2026-03-04T06:02:30.022+00:00', 20, NULL::text, timestamptz '2026-03-05T09:22:02+00:00', timestamptz '2026-03-05T09:59:15.075+00:00', 35),
    (1448, date '2026-03-05', timestamptz '2026-03-06T04:39:46+00:00', timestamptz '2026-03-06T07:27:27.033+00:00', 168, NULL::text, timestamptz '2026-03-06T07:06:38+00:00', timestamptz '2026-03-06T07:27:21.034+00:00', 18),
    (1473, date '2026-03-10', timestamptz '2026-03-11T03:22:50+00:00', timestamptz '2026-03-11T04:32:50.043+00:00', 70, NULL::text, timestamptz '2026-03-11T03:24:03+00:00', timestamptz '2026-03-11T04:04:44.005+00:00', 40),
    (1490, date '2026-03-15', timestamptz '2026-03-16T07:23:15+00:00', timestamptz '2026-03-16T07:57:24.509+00:00', 34, NULL::text, timestamptz '2026-03-16T07:26:27+00:00', timestamptz '2026-03-16T08:40:04.414+00:00', 73),
    (1495, date '2026-03-16', timestamptz '2026-03-17T06:16:06+00:00', timestamptz '2026-03-17T07:59:07.57+00:00', 103, NULL::text, timestamptz '2026-03-17T06:19:32+00:00', timestamptz '2026-03-17T07:29:20.036+00:00', 68),
    (1497, date '2026-03-16', timestamptz '2026-03-17T06:15:38+00:00', timestamptz '2026-03-17T07:59:07.57+00:00', 103, NULL::text, timestamptz '2026-03-17T07:34:22+00:00', timestamptz '2026-03-17T08:41:42.084+00:00', 68),
    (1499, date '2026-03-17', timestamptz '2026-03-17T11:50:45+00:00', timestamptz '2026-03-17T11:54:49.03+00:00', 4, NULL::text, timestamptz '2026-03-17T11:12:33+00:00', timestamptz '2026-03-17T11:53:23.358+00:00', 40),
    (1501, date '2026-03-17', timestamptz '2026-03-17T03:25:11+00:00', timestamptz '2026-03-17T03:42:40.031+00:00', 17, NULL::text, timestamptz '2026-03-18T11:05:13+00:00', timestamptz '2026-03-18T12:10:49.061+00:00', 63),
    (1503, date '2026-03-17', timestamptz '2026-03-17T06:16:06+00:00', timestamptz '2026-03-17T08:42:20.045+00:00', 146, NULL::text, timestamptz '2026-03-18T05:58:36+00:00', timestamptz '2026-03-18T06:49:40.047+00:00', 49),
    (1520, date '2026-03-20', timestamptz '2026-03-20T16:15:11+00:00', timestamptz '2026-03-20T17:29:18.069+00:00', 74, NULL::text, timestamptz '2026-03-20T20:28:31+00:00', timestamptz '2026-03-20T21:04:49.05+00:00', 35),
    (1529, date '2026-03-24', timestamptz '2026-03-25T00:02:53+00:00', timestamptz '2026-03-25T00:07:46.057+00:00', 5, NULL::text, timestamptz '2026-03-25T08:00:37+00:00', timestamptz '2026-03-25T08:50:52.076+00:00', 49),
    (1532, date '2026-03-24', timestamptz '2026-03-25T00:14:23+00:00', timestamptz '2026-03-25T01:14:00.045+00:00', 60, NULL::text, timestamptz '2026-03-25T08:57:15+00:00', timestamptz '2026-03-25T09:47:34.031+00:00', 49),
    (1533, date '2026-03-24', timestamptz '2026-03-25T06:33:38+00:00', timestamptz '2026-03-25T06:37:31.174+00:00', 4, NULL::text, timestamptz '2026-03-25T06:34:52+00:00', timestamptz '2026-03-25T07:47:35.152+00:00', 72),
    (1545, date '2026-03-26', timestamptz '2026-03-27T04:29:08+00:00', timestamptz '2026-03-27T05:55:15.075+00:00', 86, NULL::text, timestamptz '2026-03-27T04:33:46+00:00', timestamptz '2026-03-27T05:06:28.039+00:00', 32),
    (1550, date '2026-03-30', timestamptz '2026-03-31T04:42:09+00:00', timestamptz '2026-03-31T06:59:16.057+00:00', 137, NULL::text, timestamptz '2026-03-31T02:00:55+00:00', timestamptz '2026-03-31T02:35:44.021+00:00', 35),
    (1563, date '2026-04-01', timestamptz '2026-04-02T03:27:00+00:00', timestamptz '2026-04-02T03:35:44.13+00:00', 9, NULL::text, timestamptz '2026-04-02T03:27:45+00:00', timestamptz '2026-04-02T04:45:27.044+00:00', 79),
    (1579, date '2026-04-06', timestamptz '2026-04-07T03:00:33+00:00', timestamptz '2026-04-07T04:30:46.327+00:00', 90, NULL::text, timestamptz '2026-04-07T03:01:16+00:00', timestamptz '2026-04-07T04:08:26.12+00:00', 66),
    (1584, date '2026-04-07', timestamptz '2026-04-07T17:24:25+00:00', timestamptz '2026-04-07T18:49:18.024+00:00', 85, NULL::text, timestamptz '2026-04-07T17:53:24+00:00', timestamptz '2026-04-07T18:47:05.057+00:00', 52),
    (1591, date '2026-04-08', timestamptz '2026-04-09T02:02:03+00:00', timestamptz '2026-04-09T05:29:11.024+00:00', 207, NULL::text, timestamptz '2026-04-09T02:02:15+00:00', timestamptz '2026-04-09T03:01:07.029+00:00', 56),
    (1592, date '2026-04-08', timestamptz '2026-04-09T02:02:27+00:00', timestamptz '2026-04-09T05:29:33.097+00:00', 207, NULL::text, timestamptz '2026-04-09T03:03:30+00:00', timestamptz '2026-04-09T03:41:18.09+00:00', 37),
    (1618, date '2026-04-13', timestamptz '2026-04-14T06:52:54+00:00', timestamptz '2026-04-14T07:58:53.535+00:00', 66, NULL::text, timestamptz '2026-04-14T06:53:00+00:00', timestamptz '2026-04-14T08:51:03.138+00:00', 117),
    (1598, date '2026-04-15', timestamptz '2026-04-16T01:35:47+00:00', timestamptz '2026-04-16T04:10:59.025+00:00', 155, NULL::text, timestamptz '2026-04-16T01:36:35+00:00', timestamptz '2026-04-16T03:52:39.03+00:00', 133),
    (1712, date '2026-04-15', timestamptz '2026-04-15T02:59:25+00:00', timestamptz '2026-04-15T06:55:25+00:00', 236, NULL::text, timestamptz '2026-04-15T15:43:59+00:00', timestamptz '2026-04-15T16:27:58+00:00', 40),
    (1714, date '2026-04-15', timestamptz '2026-04-16T03:50:35+00:00', timestamptz '2026-04-16T04:11:17.027+00:00', 21, NULL::text, timestamptz '2026-04-16T08:22:31+00:00', timestamptz '2026-04-16T09:38:23.035+00:00', 75),
    (1715, date '2026-04-15', timestamptz '2026-04-16T07:29:20+00:00', timestamptz '2026-04-16T07:59:52.044+00:00', 31, NULL::text, timestamptz '2026-04-16T07:29:54+00:00', timestamptz '2026-04-16T08:10:30.11+00:00', 40),
    (1728, date '2026-04-19', timestamptz '2026-04-20T06:05:39+00:00', timestamptz '2026-04-20T07:59:57.101+00:00', 114, NULL::text, timestamptz '2026-04-20T06:05:45+00:00', timestamptz '2026-04-20T08:01:02.47+00:00', 114),
    (1742, date '2026-04-21', timestamptz '2026-04-21T18:46:58+00:00', timestamptz '2026-04-21T18:55:53+00:00', 9, NULL::text, timestamptz '2026-04-21T18:46:42+00:00', timestamptz '2026-04-21T19:32:34+00:00', 46),
    (1768, date '2026-04-21', timestamptz '2026-04-22T07:30:38+00:00', timestamptz '2026-04-22T07:59:56.128+00:00', 29, NULL::text, timestamptz '2026-04-22T07:30:54+00:00', timestamptz '2026-04-22T09:06:04.597+00:00', 93),
    (1738, date '2026-04-22', timestamptz '2026-04-23T06:05:43+00:00', timestamptz '2026-04-23T07:59:54.039+00:00', 114, NULL::text, timestamptz '2026-04-23T06:07:05+00:00', timestamptz '2026-04-23T09:04:10.03+00:00', 177),
    (1526, date '2026-04-23', timestamptz '2026-04-23T09:07:20+00:00', timestamptz '2026-04-23T09:12:42+00:00', 5, NULL::text, timestamptz '2026-04-24T09:17:39+00:00', timestamptz '2026-04-24T11:10:17+00:00', 115),
    (1771, date '2026-04-23', timestamptz '2026-04-23T12:21:22+00:00', timestamptz '2026-04-23T16:09:10+00:00', 228, NULL::text, timestamptz '2026-04-23T12:22:51+00:00', timestamptz '2026-04-23T15:53:02+00:00', 210),
    (1777, date '2026-04-23', timestamptz '2026-04-24T07:31:55+00:00', timestamptz '2026-04-24T07:59:54.085+00:00', 28, NULL::text, timestamptz '2026-04-24T07:33:17+00:00', timestamptz '2026-04-24T08:12:08.209+00:00', 37),
    (1783, date '2026-04-26', timestamptz '2026-04-27T03:37:03+00:00', timestamptz '2026-04-27T07:05:28.056+00:00', 208, NULL::text, timestamptz '2026-04-27T09:53:21+00:00', timestamptz '2026-04-27T10:57:14.524+00:00', 62),
    (1790, date '2026-04-27', timestamptz '2026-04-28T07:49:31+00:00', timestamptz '2026-04-28T07:59:18.068+00:00', 10, NULL::text, timestamptz '2026-04-28T07:49:48+00:00', timestamptz '2026-04-28T08:47:52.549+00:00', 54),
    (3897, date '2026-04-30', timestamptz '2026-05-01T05:50:46+00:00', timestamptz '2026-05-01T07:59:52.531+00:00', 129, NULL::text, timestamptz '2026-05-01T05:51:18+00:00', timestamptz '2026-05-01T08:19:55.563+00:00', 147),
    (3926, date '2026-05-06', timestamptz '2026-05-07T07:46:36+00:00', timestamptz '2026-05-07T07:59:50+00:00', 13, NULL::text, timestamptz '2026-05-07T07:47:20+00:00', timestamptz '2026-05-07T10:43:07+00:00', 175),
    (3930, date '2026-05-08', timestamptz '2026-05-08T09:57:40+00:00', timestamptz '2026-05-08T10:42:36+00:00', 45, NULL::text, timestamptz '2026-05-08T09:57:45+00:00', timestamptz '2026-05-08T11:08:48+00:00', 68),
    (4643, date '2026-05-13', timestamptz '2026-05-14T00:54:16+00:00', timestamptz '2026-05-14T03:13:39+00:00', 139, NULL::text, timestamptz '2026-05-14T00:54:49+00:00', timestamptz '2026-05-14T02:20:04+00:00', 83),
    (4813, date '2026-05-17', timestamptz '2026-05-18T03:26:22+00:00', timestamptz '2026-05-18T05:46:01+00:00', 140, NULL::text, timestamptz '2026-05-18T03:27:12+00:00', timestamptz '2026-05-18T04:25:05+00:00', 57),
    (5100, date '2026-05-17', timestamptz '2026-05-18T06:27:50+00:00', timestamptz '2026-05-18T07:56:12+00:00', 88, NULL::text, timestamptz '2026-05-18T06:31:26+00:00', timestamptz '2026-05-18T08:49:44+00:00', 142),
    (4742, date '2026-05-18', timestamptz '2026-05-19T07:52:30+00:00', timestamptz '2026-05-19T07:57:17+00:00', 5, NULL::text, timestamptz '2026-05-19T07:52:42+00:00', timestamptz '2026-05-19T08:47:29+00:00', 54),
    (3900, date '2026-05-19', timestamptz '2026-05-19T03:04:36+00:00', timestamptz '2026-05-19T03:31:14+00:00', 27, NULL::text, timestamptz '2026-05-20T07:36:39+00:00', timestamptz '2026-05-20T08:30:46+00:00', 53),
    (5129, date '2026-05-20', timestamptz '2026-05-21T07:23:00+00:00', timestamptz '2026-05-21T07:57:13+00:00', 34, NULL::text, timestamptz '2026-05-21T07:23:29+00:00', timestamptz '2026-05-21T08:22:39+00:00', 58),
    (5641, date '2026-06-01', timestamptz '2026-06-01T09:11:46+00:00', timestamptz '2026-06-01T11:33:49+00:00', 142, NULL::text, timestamptz '2026-06-01T18:41:48+00:00', timestamptz '2026-06-01T20:07:14+00:00', 85),
    (5295, date '2026-06-03', timestamptz '2026-06-04T07:03:07+00:00', timestamptz '2026-06-04T07:06:20+00:00', 3, NULL::text, timestamptz '2026-06-04T09:48:07+00:00', timestamptz '2026-06-04T10:24:06+00:00', 32),
    (5746, date '2026-06-04', timestamptz '2026-06-05T07:27:41+00:00', timestamptz '2026-06-05T07:56:09+00:00', 28, NULL::text, timestamptz '2026-06-05T07:28:57+00:00', timestamptz '2026-06-05T08:22:42+00:00', 53),
    (5751, date '2026-06-05', timestamptz '2026-06-05T14:44:58+00:00', timestamptz '2026-06-05T15:12:36+00:00', 28, NULL::text, timestamptz '2026-06-05T12:40:59+00:00', timestamptz '2026-06-05T15:13:21+00:00', 150),
    (5752, date '2026-06-08', timestamptz '2026-06-09T07:21:24+00:00', timestamptz '2026-06-09T07:58:20+00:00', 37, NULL::text, timestamptz '2026-06-09T07:22:39+00:00', timestamptz '2026-06-09T08:28:44+00:00', 65),
    (4836, date '2026-06-09', timestamptz '2026-06-09T11:47:15+00:00', timestamptz '2026-06-09T11:50:22+00:00', 3, NULL::text, timestamptz '2026-06-09T11:22:38+00:00', timestamptz '2026-06-09T11:48:12+00:00', 25),
    (5797, date '2026-06-16', timestamptz '2026-06-17T06:58:58+00:00', timestamptz '2026-06-17T07:59:43+00:00', 61, NULL::text, timestamptz '2026-06-17T07:02:05+00:00', timestamptz '2026-06-17T08:04:33+00:00', 61),
    (5807, date '2026-06-19', timestamptz '2026-06-19T12:47:49+00:00', timestamptz '2026-06-19T13:46:10+00:00', 58, NULL::text, timestamptz '2026-06-19T13:32:17+00:00', timestamptz '2026-06-19T13:45:50+00:00', 12),
    (5826, date '2026-06-23', timestamptz '2026-06-23T15:38:44+00:00', timestamptz '2026-06-23T16:38:20+00:00', 60, NULL::text, timestamptz '2026-06-23T15:38:50+00:00', timestamptz '2026-06-23T18:16:40+00:00', 156),
    (5841, date '2026-06-23', timestamptz '2026-06-24T03:30:22+00:00', timestamptz '2026-06-24T05:43:09+00:00', 133, NULL::text, timestamptz '2026-06-24T03:32:29+00:00', timestamptz '2026-06-24T04:25:51+00:00', 52),
    (5842, date '2026-06-23', timestamptz '2026-06-24T03:30:16+00:00', timestamptz '2026-06-24T05:47:22+00:00', 137, NULL::text, timestamptz '2026-06-24T04:28:17+00:00', timestamptz '2026-06-24T05:47:22+00:00', 74),
    (5844, date '2026-06-25', timestamptz '2026-06-26T07:16:54+00:00', timestamptz '2026-06-26T07:59:29+00:00', 43, NULL::text, timestamptz '2026-06-26T07:17:27+00:00', timestamptz '2026-06-26T08:10:57+00:00', 53),
    (5847, date '2026-06-28', timestamptz '2026-06-29T03:43:45+00:00', timestamptz '2026-06-29T05:08:11+00:00', 84, NULL::text, timestamptz '2026-06-29T03:44:06+00:00', timestamptz '2026-06-29T04:24:24+00:00', 38),
    (5858, date '2026-06-28', timestamptz '2026-06-29T07:30:58+00:00', timestamptz '2026-06-29T07:58:23+00:00', 27, NULL::text, timestamptz '2026-06-29T07:32:45+00:00', timestamptz '2026-06-29T08:14:42+00:00', 41),
    (5843, date '2026-06-30', timestamptz '2026-07-01T07:11:39+00:00', timestamptz '2026-07-01T07:59:59+00:00', 48, NULL::text, timestamptz '2026-07-01T07:11:39+00:00', timestamptz '2026-07-01T08:16:18+00:00', 64),
    (6486, date '2026-07-01', timestamptz '2026-07-02T02:18:05+00:00', timestamptz '2026-07-02T05:58:10+00:00', 220, NULL::text, timestamptz '2026-07-02T03:35:21+00:00', timestamptz '2026-07-02T04:56:26+00:00', 79),
    (6982, date '2026-07-02', timestamptz '2026-07-02T19:55:45+00:00', timestamptz '2026-07-02T20:16:18+00:00', 21, NULL::text, timestamptz '2026-07-02T19:56:27+00:00', timestamptz '2026-07-02T20:55:32+00:00', 55),
    (6497, date '2026-07-03', timestamptz '2026-07-03T17:51:37+00:00', timestamptz '2026-07-03T17:54:46+00:00', 3, NULL::text, timestamptz '2026-07-03T17:51:43+00:00', timestamptz '2026-07-03T18:16:06+00:00', 23),
    (6710, date '2026-07-03', timestamptz '2026-07-04T07:21:55+00:00', timestamptz '2026-07-04T07:59:12+00:00', 37, NULL::text, timestamptz '2026-07-04T07:23:29+00:00', timestamptz '2026-07-04T08:26:36+00:00', 60),
    (6957, date '2026-07-04', timestamptz '2026-07-05T07:35:30+00:00', timestamptz '2026-07-05T07:55:01+00:00', 20, NULL::text, timestamptz '2026-07-05T07:35:35+00:00', timestamptz '2026-07-05T08:47:54+00:00', 71),
    (6426, date '2026-07-07', timestamptz '2026-07-08T01:51:29+00:00', timestamptz '2026-07-08T02:43:44+00:00', 52, NULL::text, timestamptz '2026-07-08T03:08:10+00:00', timestamptz '2026-07-08T03:36:49+00:00', 27),
    (6573, date '2026-07-08', timestamptz '2026-07-08T03:08:22+00:00', timestamptz '2026-07-08T03:36:38+00:00', 28, NULL::text, timestamptz '2026-07-09T02:21:26+00:00', timestamptz '2026-07-09T02:40:39+00:00', 16),
    (7110, date '2026-07-16', timestamptz '2026-07-17T01:27:01+00:00', timestamptz '2026-07-17T01:33:18+00:00', 6, NULL::text, timestamptz '2026-07-17T00:52:28+00:00', timestamptz '2026-07-17T01:27:01+00:00', 34),
    (6499, date '2026-07-18', timestamptz '2026-07-19T03:23:24+00:00', timestamptz '2026-07-19T03:32:24+00:00', 9, NULL::text, timestamptz '2026-07-19T03:23:54+00:00', timestamptz '2026-07-19T03:59:09+00:00', 33),
    (6241, date '2026-07-21', timestamptz '2026-07-22T06:29:47+00:00', timestamptz '2026-07-22T07:52:41+00:00', 83, NULL::text, timestamptz '2026-07-22T06:30:37+00:00', timestamptz '2026-07-22T07:11:34+00:00', 40),
    (7298, date '2026-07-21', timestamptz '2026-07-21T02:06:30+00:00', timestamptz '2026-07-21T03:08:10+00:00', 62, NULL::text, timestamptz '2026-07-22T03:34:30+00:00', timestamptz '2026-07-22T04:09:38+00:00', 33),
    (5877, date '2026-07-23', timestamptz '2026-07-24T02:13:00+00:00', timestamptz '2026-07-24T04:00:08+00:00', 107, NULL::text, timestamptz '2026-07-24T02:43:32+00:00', timestamptz '2026-07-24T03:23:29+00:00', 39),
    (6188, date '2026-07-24', timestamptz '2026-07-25T07:44:57+00:00', timestamptz '2026-07-25T07:59:51+00:00', 15, NULL::text, timestamptz '2026-07-25T11:54:43+00:00', timestamptz '2026-07-25T12:25:10+00:00', 28),
    (7366, date '2026-07-24', timestamptz '2026-07-24T17:17:20+00:00', timestamptz '2026-07-24T17:42:49+00:00', 25, NULL::text, timestamptz '2026-07-24T17:17:38+00:00', timestamptz '2026-07-24T18:06:57+00:00', 48),
    (7392, date '2026-07-27', timestamptz '2026-07-28T05:55:07+00:00', timestamptz '2026-07-28T07:59:55+00:00', 125, NULL::text, timestamptz '2026-07-28T05:55:44+00:00', timestamptz '2026-07-28T08:17:44+00:00', 141),
    (7421, date '2026-07-28', timestamptz '2026-07-28T21:38:46+00:00', timestamptz '2026-07-28T22:04:40+00:00', 26, NULL::text, timestamptz '2026-07-29T13:04:49+00:00', timestamptz '2026-07-29T13:22:27+00:00', 17),
    (6104, date '2026-07-29', timestamptz '2026-07-30T05:27:00+00:00', timestamptz '2026-07-30T05:31:25+00:00', 4, NULL::text, timestamptz '2026-07-30T05:32:59+00:00', timestamptz '2026-07-30T06:44:45+00:00', 71),
    (6756, date '2026-07-29', timestamptz '2026-07-30T10:01:44+00:00', timestamptz '2026-07-30T10:04:56+00:00', 3, NULL::text, timestamptz '2026-07-30T08:50:49+00:00', timestamptz '2026-07-30T10:04:56+00:00', 71),
    (6366, date '2026-08-04', timestamptz '2026-08-04T12:34:28+00:00', timestamptz '2026-08-04T12:39:25+00:00', 5, NULL::text, timestamptz '2026-08-04T12:35:49+00:00', timestamptz '2026-08-04T13:17:27+00:00', 42),
    (7683, date '2026-08-05', timestamptz '2026-08-05T12:53:48+00:00', timestamptz '2026-08-05T13:00:06+00:00', 6, NULL::text, timestamptz '2026-08-05T12:23:05+00:00', timestamptz '2026-08-05T12:59:54+00:00', 39),
    (7738, date '2026-08-10', timestamptz '2026-08-10T17:24:47+00:00', timestamptz '2026-08-10T18:54:01+00:00', 89, NULL::text, timestamptz '2026-08-10T19:45:39+00:00', timestamptz '2026-08-10T20:48:04+00:00', 61),
    (7692, date '2026-08-11', timestamptz '2026-08-11T09:50:22+00:00', timestamptz '2026-08-11T09:53:24+00:00', 3, NULL::text, timestamptz '2026-08-11T09:01:28+00:00', timestamptz '2026-08-11T09:50:22+00:00', 51),
    (7693, date '2026-08-13', timestamptz '2026-08-14T05:58:32+00:00', timestamptz '2026-08-14T06:19:50+00:00', 21, NULL::text, timestamptz '2026-08-14T05:34:39+00:00', timestamptz '2026-08-14T06:19:30+00:00', 42),
    (7694, date '2026-08-13', timestamptz '2026-08-14T04:31:22+00:00', timestamptz '2026-08-14T04:55:57+00:00', 25, NULL::text, timestamptz '2026-08-14T04:33:28+00:00', timestamptz '2026-08-14T05:14:25+00:00', 36),
    (7696, date '2026-08-13', timestamptz '2026-08-14T02:00:47+00:00', timestamptz '2026-08-14T02:37:44+00:00', 37, NULL::text, timestamptz '2026-08-14T08:25:47+00:00', timestamptz '2026-08-14T08:44:55+00:00', 18);
CREATE TEMP TABLE _pre6 ON COMMIT DROP AS SELECT id, sync_state, vehicle_id FROM public.visits;
CREATE TEMP TABLE _ref6 ON COMMIT DROP AS
  SELECT g.* FROM (SELECT DISTINCT visit_date FROM _fix6) d, LATERAL public.fn_time_on_site_audit_gps(d.visit_date) g;

DO $p$ BEGIN
  IF EXISTS (SELECT 1 FROM _fix6 f WHERE NOT EXISTS (SELECT 1 FROM _ref6 r WHERE r.visit_id = f.visit_id
               AND r.ref_arrival = f.arrival AND r.ref_departure = f.departure AND r.ref_sharing = 1
               AND NOT r.other_completion_inside AND r.truck_question IS NULL)) THEN
    RAISE EXCEPTION 'a GPS reference moved since the audit: re-run scripts/checks/time_on_site_audit.mjs'; END IF;
END $p$;

SELECT set_config('request.headers', jsonb_build_object('x-app-source', 'time-on-site-audit',
  'x-change-reason', 'Time on site corrected to the truck''s GPS stop that holds the completion time; Samsara''s trip gap agrees within 5 min at both ends (time on site plan step 6 audit, before the stop table).')::text, true);
UPDATE public.visits v SET actual_arrival_at = f.arrival, actual_departure_at = f.departure,
       duration_minutes = round(extract(epoch from f.departure - f.arrival) / 60)::integer, time_on_site_source = 'stop_at_completion'
  FROM _fix6 f
 WHERE v.id = f.visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
   AND v.actual_arrival_at IS NOT DISTINCT FROM f.s_arr AND v.actual_departure_at IS NOT DISTINCT FROM f.s_dep
   AND v.duration_minutes IS NOT DISTINCT FROM f.s_min AND v.time_on_site_source IS NOT DISTINCT FROM f.s_src;
SELECT set_config('request.headers', '', true);

DO $v$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.visits v JOIN _fix6 f ON f.visit_id = v.id
   WHERE v.actual_arrival_at = f.arrival AND v.actual_departure_at = f.departure AND v.time_on_site_source = 'stop_at_completion'
     AND abs(v.duration_minutes - f.samsara_minutes) <= 10;
  IF n <> 106 THEN RAISE EXCEPTION 'V1: % of 106 corrected (a value changed since the audit?)', n; END IF;
  IF (SELECT count(*) FROM audit.logs a WHERE a.table_name = 'visits' AND a.txid = txid_current()
        AND a.app_source = 'time-on-site-audit' AND coalesce(a.request_context->>'change_reason', '') <> '') <> 106 THEN
    RAISE EXCEPTION 'V2: not all labelled'; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v JOIN _pre6 p ON p.id = v.id
              WHERE v.sync_state IS DISTINCT FROM p.sync_state OR v.vehicle_id IS DISTINCT FROM p.vehicle_id) THEN
    RAISE EXCEPTION 'V3: a sync_state or a truck moved'; END IF;
END $v$;

COMMIT;
