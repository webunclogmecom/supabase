-- ============================================================================
-- 2026-10-14_1700 Time on site: "the truck went there once that date" gets Samsara's stay (92 visits)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14, on visit 8017 (168-AVA, dated Sep 4, marked complete Sep 7 during another visit's stay; Moises
--   parked at AVA once in its window, Sep 5 4:02 to 5:25 AM ET, the same stay as pumping visit 8013): "yes same stay,
--   give 8017 the 1h 23m, because they had the same truck, and also they just went once that date. use that to check
--   others too".
-- THE RULE APPLIED
--   A completed customer visit whose truck was NOT parked at the address when it was marked complete inside the visit's
--   date window (visit date -4 h to 10 AM next day), but parked there exactly ONCE in that window (fn_gps_stays, 3 min
--   or more, within 250 m), takes Samsara's stay for that stop (the gap between two Samsara trips that overlaps it).
--   Two visits of one client may share the stay (two services, one stop: 8017 and 8018 with 8013). Skipped: review,
--   reviewed_blank, samsara_stay and dump values; stays where Samsara shows the truck moving (5); no Samsara stay (2);
--   values already within 2 min of Samsara (21). Swept 2026-01-01 to today: 120 matched, 92 saved here
--   (9 blank, the rest corrected). Each row is guarded by the value read at
--   2026-10-14 ~16:20 ET, so a row changed since is left alone. Source samsara_stay, x-app-source time-on-site-samsara.
--   Not yet automatic: the nightly recheck still keys on the stop that holds the tap.
-- ROLLBACK: audit.logs.old_row for these visits (x-app-source time-on-site-samsara, this migration's reason).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE _once (visit_id bigint, arrival timestamptz, departure timestamptz, was_min integer, was_src text) ON COMMIT DROP;
INSERT INTO _once VALUES
    (1240, timestamptz '2026-01-02T13:52:20.015Z', timestamptz '2026-01-02T14:38:14.036Z', 48, NULL),
    (1252, timestamptz '2026-01-06T05:34:21.009Z', timestamptz '2026-01-06T05:56:39.056Z', 25, NULL),
    (1268, timestamptz '2026-01-09T09:00:37.011Z', timestamptz '2026-01-09T10:25:20.007Z', NULL, NULL),
    (1280, timestamptz '2026-01-14T16:37:14.011Z', timestamptz '2026-01-14T20:57:02.019Z', 239, NULL),
    (1282, timestamptz '2026-01-15T08:52:30.020Z', timestamptz '2026-01-15T09:08:43.016Z', 9, NULL),
    (1284, timestamptz '2026-01-15T19:10:52.003Z', timestamptz '2026-01-15T19:55:08.010Z', 49, NULL),
    (1288, timestamptz '2026-01-16T06:00:00.043Z', timestamptz '2026-01-16T07:00:15.010Z', 63, NULL),
    (1302, timestamptz '2026-01-21T01:30:41.057Z', timestamptz '2026-01-21T03:16:46.039Z', 108, NULL),
    (1311, timestamptz '2026-01-23T04:56:15.019Z', timestamptz '2026-01-23T06:02:41.018Z', 68, NULL),
    (1320, timestamptz '2026-01-26T15:26:11.018Z', timestamptz '2026-01-26T16:09:47.008Z', 46, NULL),
    (1341, timestamptz '2026-02-03T07:48:26.005Z', timestamptz '2026-02-03T08:25:36.018Z', 40, NULL),
    (1344, timestamptz '2026-02-04T02:52:33.025Z', timestamptz '2026-02-04T06:17:42.022Z', 209, NULL),
    (1373, timestamptz '2026-02-10T22:02:07.988Z', timestamptz '2026-02-10T22:40:50.018Z', 47, NULL),
    (1377, timestamptz '2026-02-12T04:42:14.025Z', timestamptz '2026-02-12T05:13:39.065Z', 34, NULL),
    (1387, timestamptz '2026-02-14T08:25:10.028Z', timestamptz '2026-02-14T09:36:10.039Z', 73, NULL),
    (1397, timestamptz '2026-02-18T16:47:36.031Z', timestamptz '2026-02-18T17:52:42.025Z', 74, NULL),
    (1419, timestamptz '2026-02-25T18:36:03.013Z', timestamptz '2026-02-25T18:42:17.023Z', 9, NULL),
    (1420, timestamptz '2026-02-25T18:53:21.028Z', timestamptz '2026-02-25T19:39:24.016Z', 51, NULL),
    (1433, timestamptz '2026-03-04T07:33:06.053Z', timestamptz '2026-03-04T08:10:37.015Z', NULL, NULL),
    (1437, timestamptz '2026-03-04T09:29:26.044Z', timestamptz '2026-03-04T10:43:38.034Z', NULL, NULL),
    (1454, timestamptz '2026-03-07T18:41:02.081Z', timestamptz '2026-03-07T20:01:22.027Z', 83, NULL),
    (1477, timestamptz '2026-03-12T00:25:49.034Z', timestamptz '2026-03-12T02:11:12.072Z', 107, NULL),
    (1527, timestamptz '2026-03-24T16:13:05.011Z', timestamptz '2026-03-24T16:50:05.011Z', 41, NULL),
    (1588, timestamptz '2026-04-07T13:10:56.407Z', timestamptz '2026-04-07T13:16:03.526Z', 7, NULL),
    (1599, timestamptz '2026-04-10T04:56:22.026Z', timestamptz '2026-04-10T06:26:21.050Z', 92, NULL),
    (1602, timestamptz '2026-04-10T19:52:16.033Z', timestamptz '2026-04-10T20:08:51.237Z', 22, NULL),
    (1707, timestamptz '2026-04-10T08:02:28.037Z', timestamptz '2026-04-10T08:16:09.019Z', 16, NULL),
    (1744, timestamptz '2026-04-21T14:58:12.037Z', timestamptz '2026-04-21T17:22:41.097Z', 147, NULL),
    (1770, timestamptz '2026-04-23T09:53:45.033Z', timestamptz '2026-04-23T11:20:41.033Z', 90, NULL),
    (1780, timestamptz '2026-04-24T17:05:16.057Z', timestamptz '2026-04-24T17:52:47.382Z', 51, NULL),
    (1785, timestamptz '2026-04-26T16:04:29.087Z', timestamptz '2026-04-26T16:51:04.019Z', 55, NULL),
    (3889, timestamptz '2026-04-29T19:55:37.018Z', timestamptz '2026-04-29T20:38:21.009Z', 45, NULL),
    (3913, timestamptz '2026-05-05T03:02:03.135Z', timestamptz '2026-05-05T04:02:39.172Z', 63, NULL),
    (3919, timestamptz '2026-05-03T02:24:10.035Z', timestamptz '2026-05-03T04:13:02.057Z', NULL, NULL),
    (3920, timestamptz '2026-05-05T03:02:03.135Z', timestamptz '2026-05-05T04:02:39.172Z', 63, NULL),
    (3936, timestamptz '2026-05-09T20:35:32.042Z', timestamptz '2026-05-09T21:44:59.052Z', NULL, NULL),
    (4855, timestamptz '2026-05-19T03:40:57.267Z', timestamptz '2026-05-19T04:34:54.120Z', 56, NULL),
    (4994, timestamptz '2026-05-18T20:08:22.064Z', timestamptz '2026-05-18T20:34:42.628Z', 28, NULL),
    (5077, timestamptz '2026-05-11T22:15:37.231Z', timestamptz '2026-05-11T22:43:01.010Z', NULL, NULL),
    (5080, timestamptz '2026-05-08T10:00:36.394Z', timestamptz '2026-05-08T11:08:43.315Z', NULL, NULL),
    (5092, timestamptz '2026-05-13T19:15:58.042Z', timestamptz '2026-05-13T20:05:13.178Z', 53, NULL),
    (5103, timestamptz '2026-05-18T10:44:35.268Z', timestamptz '2026-05-18T11:10:01.508Z', 28, NULL),
    (5104, timestamptz '2026-05-18T11:51:41.231Z', timestamptz '2026-05-18T12:29:31.507Z', 17, NULL),
    (5105, timestamptz '2026-05-18T20:08:22.064Z', timestamptz '2026-05-18T20:34:42.628Z', 28, NULL),
    (5145, timestamptz '2026-05-26T15:07:49.156Z', timestamptz '2026-05-26T16:18:55.232Z', 73, NULL),
    (5162, timestamptz '2026-05-29T19:02:52.046Z', timestamptz '2026-05-29T19:46:19.029Z', 50, NULL),
    (5637, timestamptz '2026-05-29T20:56:31.199Z', timestamptz '2026-05-29T21:31:40.172Z', 37, NULL),
    (5013, timestamptz '2026-06-04T11:08:21.079Z', timestamptz '2026-06-04T12:00:12.040Z', NULL, NULL),
    (5736, timestamptz '2026-06-04T10:34:32.518Z', timestamptz '2026-06-04T10:53:28.109Z', 21, NULL),
    (5760, timestamptz '2026-06-09T14:46:43.143Z', timestamptz '2026-06-09T16:19:03.263Z', 97, NULL),
    (5776, timestamptz '2026-06-10T03:57:42.451Z', timestamptz '2026-06-10T05:30:34.287Z', 95, NULL),
    (5817, timestamptz '2026-06-23T04:54:29.096Z', timestamptz '2026-06-23T08:07:06.075Z', 186, NULL),
    (5820, timestamptz '2026-06-20T17:28:26.114Z', timestamptz '2026-06-20T18:05:54.136Z', 40, NULL),
    (5840, timestamptz '2026-06-25T14:29:34.216Z', timestamptz '2026-06-25T15:46:53.515Z', 79, NULL),
    (6815, timestamptz '2026-06-25T14:29:34.216Z', timestamptz '2026-06-25T15:46:53.515Z', 79, NULL),
    (5991, timestamptz '2026-07-16T00:33:26.489Z', timestamptz '2026-07-16T01:46:50.557Z', 75, NULL),
    (6990, timestamptz '2026-07-02T06:05:06.537Z', timestamptz '2026-07-02T06:58:08.553Z', 56, NULL),
    (7054, timestamptz '2026-07-07T17:11:15.515Z', timestamptz '2026-07-07T17:39:54.510Z', 11, NULL),
    (7058, timestamptz '2026-07-07T04:10:30.549Z', timestamptz '2026-07-07T05:34:36.544Z', 89, NULL),
    (7070, timestamptz '2026-07-08T20:40:14.498Z', timestamptz '2026-07-08T21:11:34.516Z', 33, NULL),
    (7079, timestamptz '2026-07-13T22:06:18.520Z', timestamptz '2026-07-13T22:29:59.508Z', 27, NULL),
    (7085, timestamptz '2026-07-14T01:02:08.497Z', timestamptz '2026-07-14T01:18:42.489Z', 19, NULL),
    (7095, timestamptz '2026-07-17T01:50:10.484Z', timestamptz '2026-07-17T02:40:28.023Z', 53, NULL),
    (7096, timestamptz '2026-07-10T01:12:58.517Z', timestamptz '2026-07-10T01:50:33.536Z', 41, NULL),
    (7105, timestamptz '2026-07-15T21:43:42.506Z', timestamptz '2026-07-15T22:41:38.502Z', 60, NULL),
    (7300, timestamptz '2026-07-22T03:35:12.468Z', timestamptz '2026-07-22T04:08:41.497Z', 35, NULL),
    (7328, timestamptz '2026-07-24T04:24:18.614Z', timestamptz '2026-07-24T04:59:35.508Z', 38, NULL),
    (7368, timestamptz '2026-07-23T19:04:39.539Z', timestamptz '2026-07-23T19:11:49.543Z', 9, NULL),
    (7378, timestamptz '2026-07-27T13:04:51.546Z', timestamptz '2026-07-27T16:27:12.527Z', 205, NULL),
    (6708, timestamptz '2026-08-05T04:59:04.539Z', timestamptz '2026-08-05T06:29:44.513Z', 93, NULL),
    (6771, timestamptz '2026-08-20T12:14:24.503Z', timestamptz '2026-08-20T13:17:13.548Z', 65, NULL),
    (7065, timestamptz '2026-08-05T04:59:04.539Z', timestamptz '2026-08-05T06:29:44.513Z', 93, NULL),
    (7674, timestamptz '2026-08-05T04:59:04.539Z', timestamptz '2026-08-05T06:29:44.513Z', 93, NULL),
    (7797, timestamptz '2026-08-18T05:43:07.564Z', timestamptz '2026-08-18T06:33:10.535Z', 56, NULL),
    (7833, timestamptz '2026-08-21T22:52:12.503Z', timestamptz '2026-08-21T23:21:23.653Z', 31, NULL),
    (6737, timestamptz '2026-09-07T17:18:54.508Z', timestamptz '2026-09-07T17:36:41.539Z', 22, NULL),
    (8017, timestamptz '2026-09-05T08:02:20.501Z', timestamptz '2026-09-05T09:25:50.512Z', NULL, NULL),
    (8018, timestamptz '2026-09-05T08:02:20.501Z', timestamptz '2026-09-05T09:25:50.512Z', 89, NULL),
    (8023, timestamptz '2026-09-07T16:53:39.507Z', timestamptz '2026-09-07T17:12:20.554Z', 22, NULL),
    (8084, timestamptz '2026-09-09T18:31:56.511Z', timestamptz '2026-09-09T20:09:08.515Z', 101, NULL),
    (8085, timestamptz '2026-09-12T02:50:26.507Z', timestamptz '2026-09-12T03:41:36.509Z', 54, NULL),
    (8088, timestamptz '2026-09-15T07:11:31.516Z', timestamptz '2026-09-15T08:17:20.509Z', 69, NULL),
    (8105, timestamptz '2026-09-11T19:47:09.515Z', timestamptz '2026-09-11T20:23:12.506Z', 39, NULL),
    (8117, timestamptz '2026-09-16T09:00:01.515Z', timestamptz '2026-09-16T11:18:28.509Z', 140, NULL),
    (8176, timestamptz '2026-09-22T07:09:38.519Z', timestamptz '2026-09-22T10:11:30.522Z', 55, NULL),
    (8194, timestamptz '2026-09-23T18:41:10.808Z', timestamptz '2026-09-23T19:24:09.510Z', 48, NULL),
    (8579, timestamptz '2026-09-22T07:09:38.519Z', timestamptz '2026-09-22T10:11:30.522Z', 189, NULL),
    (6511, timestamptz '2026-10-09T18:12:24.528Z', timestamptz '2026-10-09T18:32:24.558Z', 22, NULL),
    (8722, timestamptz '2026-10-02T18:23:02.513Z', timestamptz '2026-10-02T19:03:13.512Z', 42, NULL),
    (8729, timestamptz '2026-10-04T15:43:07.508Z', timestamptz '2026-10-04T16:01:01.519Z', 20, NULL),
    (8743, timestamptz '2026-10-06T16:46:34.522Z', timestamptz '2026-10-06T16:52:09.522Z', 9, NULL),
    (8773, timestamptz '2026-10-13T08:50:23.520Z', timestamptz '2026-10-13T09:13:40.929Z', 8, NULL);
DO $s$ DECLARE v_hdr text := current_setting('request.headers', true); n int; BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', 'Time on site set to Samsara''s stay: the truck parked at the address once on the visit''s date (Fred, 2026-10-14, visit 8017).'))::text, true);
  UPDATE public.visits v
     SET actual_arrival_at = o.arrival, actual_departure_at = o.departure,
         duration_minutes = round(extract(epoch FROM o.departure - o.arrival) / 60)::integer,
         time_on_site_source = 'samsara_stay'
    FROM _once o
   WHERE v.id = o.visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
     AND v.duration_minutes IS NOT DISTINCT FROM o.was_min AND v.time_on_site_source IS NOT DISTINCT FROM o.was_src;
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  IF n <> 92 THEN RAISE EXCEPTION 'expected 92 visits saved, got %', n; END IF;
END $s$;
DO $v$ DECLARE r jsonb; BEGIN
  IF (SELECT duration_minutes FROM public.visits WHERE id = 8017) <> 84 THEN RAISE EXCEPTION 'VERIFY: 8017 is not 84'; END IF;
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
END $v$;
COMMIT;
