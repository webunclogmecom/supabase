-- ============================================================================
-- 2026-10-14_0955 Time on site, step 5b: correct the 18 saved values the stop and Samsara both prove wrong
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 5". scripts/checks/time_on_site_audit.mjs (2026-10-13_2350's
--   fn_time_on_site_audit + Samsara /v1/fleet/trips) audited the 313 saved client values since Aug 20: 189 agree, 18
--   pass the strict gate below, the rest are on the review list (samsara-checks/time_on_site_audit_2026-10-13.html,
--   outside the repos).
--
-- THE GATE (all must hold, per visit; a set of visits that saved the same window on the same truck, all or none)
--   the reference (public.v_visit_stop_reference: the truck's stop holding the completion, with the step 3 chain) exists,
--   is not shared; no other visit of that truck was completed inside it; no truck question; not stale; Samsara's trip
--   gap agrees within 5 min at BOTH ends; the saved value is flagged (wrong stay, too short, too long, closed before
--   arrival, window cut); it is not a reviewed value.
--   Examples: 6507 6 -> 41 min (Samsara 40), 6106 8 -> 101 (98), 7454 4 -> 81 (80), 8145 220 -> 16 (15), 8010 16:27
--   saved, really 14:00 to 14:20. Eight carry a bonus decision still pending: Admin Review's hero changes for them.
--
-- SAFETY: each row is written only if it still holds the snapshot below (any change since the audit skips it, and the
--   VERIFY then fails the whole batch). The old values are in backups/2026-10-13_time_on_site_step5_corrections_before.json (workspace, outside
--   the repos) and in audit.logs old_row. Labelled time-on-site-audit. Nothing reaches Jobber.
-- ROLLBACK: restore the snapshot columns from the backup file (or from audit.logs old_row for this transaction).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TEMP TABLE _fix5 (visit_id bigint, s_arr timestamptz, s_dep timestamptz, s_min int, s_src text,
                          arrival timestamptz, departure timestamptz, samsara_minutes int) ON COMMIT DROP;
INSERT INTO _fix5 VALUES
    (6544, timestamptz '2026-08-23T06:23:00+00:00', timestamptz '2026-08-23T07:59:16+00:00', 96, NULL::text, timestamptz '2026-08-23T06:26:52+00:00', timestamptz '2026-08-23T07:21:29+00:00', 54),
    (6236, timestamptz '2026-08-25T08:07:07+00:00', timestamptz '2026-08-25T09:50:54+00:00', 104, NULL::text, timestamptz '2026-08-25T08:12:53+00:00', timestamptz '2026-08-25T09:02:35+00:00', 49),
    (6252, timestamptz '2026-08-25T08:07:13+00:00', timestamptz '2026-08-25T09:50:54+00:00', 104, NULL::text, timestamptz '2026-08-25T09:03:45+00:00', timestamptz '2026-08-25T09:49:39+00:00', 44),
    (6105, timestamptz '2026-08-29T03:48:28+00:00', timestamptz '2026-08-29T04:34:11+00:00', 46, NULL::text, timestamptz '2026-08-29T03:13:45+00:00', timestamptz '2026-08-29T04:34:06+00:00', 79),
    (6418, timestamptz '2026-09-02T09:05:14+00:00', timestamptz '2026-09-02T10:47:34+00:00', 102, NULL::text, timestamptz '2026-09-02T09:22:55+00:00', timestamptz '2026-09-02T10:47:34+00:00', 89),
    (8010, timestamptz '2026-09-04T20:27:23+00:00', timestamptz '2026-09-04T20:57:13+00:00', 30, NULL::text, timestamptz '2026-09-04T18:00:52+00:00', timestamptz '2026-09-04T18:20:39+00:00', 19),
    (5925, timestamptz '2026-09-07T07:19:57+00:00', timestamptz '2026-09-07T09:43:06+00:00', 143, NULL::text, timestamptz '2026-09-07T07:21:58+00:00', timestamptz '2026-09-07T08:34:17+00:00', 70),
    (6507, timestamptz '2026-09-14T23:46:51+00:00', timestamptz '2026-09-14T23:53:19+00:00', 6, NULL::text, timestamptz '2026-09-14T23:53:01+00:00', timestamptz '2026-09-15T00:33:45+00:00', 40),
    (8145, timestamptz '2026-09-17T17:19:54+00:00', timestamptz '2026-09-17T21:00:05+00:00', 220, NULL::text, timestamptz '2026-09-17T17:22:20+00:00', timestamptz '2026-09-17T17:37:56+00:00', 15),
    (6260, timestamptz '2026-09-23T02:01:51+00:00', timestamptz '2026-09-23T04:17:36+00:00', 136, NULL::text, timestamptz '2026-09-23T04:44:22+00:00', timestamptz '2026-09-23T05:26:26+00:00', 41),
    (6645, timestamptz '2026-09-24T09:27:03+00:00', timestamptz '2026-09-24T10:19:02+00:00', 52, NULL::text, timestamptz '2026-09-24T09:27:44+00:00', timestamptz '2026-09-24T10:04:49+00:00', 33),
    (8231, timestamptz '2026-09-28T13:18:22+00:00', timestamptz '2026-09-28T14:44:13+00:00', 86, NULL::text, timestamptz '2026-09-28T14:31:39+00:00', timestamptz '2026-09-28T14:43:17+00:00', 9),
    (7454, timestamptz '2026-09-30T02:10:47+00:00', timestamptz '2026-09-30T02:14:52+00:00', 4, NULL::text, timestamptz '2026-09-30T02:14:07+00:00', timestamptz '2026-09-30T03:34:48+00:00', 80),
    (6449, timestamptz '2026-10-01T05:46:07+00:00', timestamptz '2026-10-01T07:52:36+00:00', 126, NULL::text, timestamptz '2026-10-01T06:55:04+00:00', timestamptz '2026-10-01T07:51:58+00:00', 56),
    (8720, timestamptz '2026-10-02T17:54:53+00:00', timestamptz '2026-10-02T18:14:53+00:00', 20, NULL::text, timestamptz '2026-10-02T17:45:20+00:00', timestamptz '2026-10-02T18:14:47+00:00', 29),
    (6106, timestamptz '2026-10-05T09:52:56+00:00', timestamptz '2026-10-05T10:01:24+00:00', 8, NULL::text, timestamptz '2026-10-05T09:53:37+00:00', timestamptz '2026-10-05T11:34:26+00:00', 98),
    (6412, timestamptz '2026-10-05T07:48:58+00:00', timestamptz '2026-10-05T11:35:16+00:00', 226, NULL::text, timestamptz '2026-10-05T07:50:00+00:00', timestamptz '2026-10-05T09:47:42+00:00', 114),
    (6975, timestamptz '2026-10-09T12:12:42+00:00', timestamptz '2026-10-09T13:59:56+00:00', 107, NULL::text, timestamptz '2026-10-09T12:12:48+00:00', timestamptz '2026-10-09T15:08:24+00:00', 174);
CREATE TEMP TABLE _pre5 ON COMMIT DROP AS SELECT id, sync_state, vehicle_id FROM public.visits;

-- re-read the proof: the reference still says exactly this, unshared
DO $p$ BEGIN
  IF EXISTS (SELECT 1 FROM _fix5 f WHERE NOT EXISTS (SELECT 1 FROM public.v_visit_stop_reference r
               WHERE r.visit_id = f.visit_id AND r.basis = 'completion' AND r.sharing = 1 AND r.split_ok
                 AND r.arrival = f.arrival AND r.departure = f.departure)) THEN
    RAISE EXCEPTION 'a reference moved since the audit: re-run scripts/checks/time_on_site_audit.mjs'; END IF;
END $p$;

SELECT set_config('request.headers', jsonb_build_object('x-app-source', 'time-on-site-audit',
  'x-change-reason', 'Time on site corrected to the truck''s stop that holds the completion time; Samsara''s trip gap agrees within 5 min at both ends (time on site plan step 5 audit).')::text, true);
UPDATE public.visits v SET actual_arrival_at = f.arrival, actual_departure_at = f.departure,
       duration_minutes = round(extract(epoch from f.departure - f.arrival) / 60)::integer, time_on_site_source = 'stop_at_completion'
  FROM _fix5 f
 WHERE v.id = f.visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
   AND v.actual_arrival_at IS NOT DISTINCT FROM f.s_arr AND v.actual_departure_at IS NOT DISTINCT FROM f.s_dep
   AND v.duration_minutes IS NOT DISTINCT FROM f.s_min AND v.time_on_site_source IS NOT DISTINCT FROM f.s_src;
SELECT set_config('request.headers', '', true);

DO $v$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.visits v JOIN _fix5 f ON f.visit_id = v.id
   WHERE v.actual_arrival_at = f.arrival AND v.actual_departure_at = f.departure AND v.time_on_site_source = 'stop_at_completion'
     AND abs(v.duration_minutes - f.samsara_minutes) <= 5;
  IF n <> 18 THEN RAISE EXCEPTION 'V1: % of 18 corrected (a value changed since the audit?)', n; END IF;
  IF (SELECT count(*) FROM audit.logs a WHERE a.table_name = 'visits' AND a.txid = txid_current()
        AND a.app_source = 'time-on-site-audit' AND coalesce(a.request_context->>'change_reason', '') <> '') <> 18 THEN
    RAISE EXCEPTION 'V2: not all labelled'; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v JOIN _pre5 p ON p.id = v.id
              WHERE v.sync_state IS DISTINCT FROM p.sync_state OR v.vehicle_id IS DISTINCT FROM p.vehicle_id) THEN
    RAISE EXCEPTION 'V3: a sync_state or a truck moved'; END IF;
  -- the audit now finds these clean
  IF EXISTS (SELECT 1 FROM public.fn_time_on_site_audit() a JOIN _fix5 f ON f.visit_id = a.visit_id
              WHERE a.verdicts && array['wrong_stay','too_short','too_long','closed_before_arrival','window_cut']) THEN
    RAISE EXCEPTION 'V4: a corrected visit is still flagged'; END IF;
END $v$;

COMMIT;
