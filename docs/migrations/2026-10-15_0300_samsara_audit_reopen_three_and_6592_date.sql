-- ============================================================================
-- 2026-10-15_0300 Samsara audit: three "nothing to measure" visits get their stay; 6592 gets its date back
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15, on the Samsara audit: "For 4 yes" (save Cloggy's 20 min Mar 19 stop on 1509, reopen 1416 and
--   7088; 1477 and 1509 keep Cloggy) and "For 8 yes" (put 6592's date back).
-- DECISION 4: Samsara contradicts "nothing to measure" (reviewed_blank) on three visits
--   * 1509 (2026-03-18): Cloggy parked at the address 2026-03-19 3:39:04 to 3:59:31 PM ET (Samsara trip gap, 60 m from
--     our map point, inside the client's Samsara place), and the job was marked complete at 4:01 PM. Done the day after
--     its date, outside the date window, like 1522 and 1523 (kept for the same reason in the audit).
--   * 1416 (2026-02-24): Cloggy parked 79 m from the address 2026-02-25 10:40:34 to 11:39:20 AM ET, and the job was
--     marked complete at 11:38 AM, during that stay. Also done the morning after its window.
--   * 7088 (2026-07-13): Cloggy's one stop there, 9:02:08 to 9:18:42 PM ET, 153 m from the address on Washington Ave,
--     is the same stop as the next-door visit 7085 (239-COM, already 17 min); both were marked complete after it. One
--     parking spot, two services: the whole stop to each (decision 3).
--   Saved as samsara_stay, labelled time-on-site-samsara, guarded on still being reviewed_blank and blank.
-- DECISION 8: 6592's date
--   audit.logs: at completion (2026-06-30 07:35 ET) the visit was set for Jun 30 4:15 AM ET (start 2026-06-30 08:15 UTC,
--   then dated Jun 29 by the old 06:00 cutoff); Samsara agrees (Cloggy there 7:06 to 7:23 AM, done 7:30). Two automated
--   writes (app_source sql) then moved start_at a day forward twice, and the operating-date fix dated it Jul 2. Put back:
--   start_at 2026-06-30 08:15 UTC, end_at 09:15 UTC, visit_date 2026-06-30 (the ET clock date, today's rule).
--   The Jobber push is SUPPRESSED (app.suppress_jobber_push), and sync_state is put back to 'confirmed' in a second
--   statement (the BEFORE trigger forces 'pending' on a date change). Jobber still shows Jul 2 (our earlier push wrote
--   it); no sync copies Jobber's date onto a completed visit (the drift reconciler skips completed visits, the poll
--   re-reads only visits edited in Jobber), so this holds unless someone edits the visit in Jobber.
-- ROLLBACK: audit.logs.old_row for 1509, 1416, 7088, 6592 (2026-10-15).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $s$
DECLARE v_hdr text := current_setting('request.headers', true); r record; n int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      (1509, timestamptz '2026-03-19T19:39:04.048Z', timestamptz '2026-03-19T19:59:31.079Z',
       'Cloggy parked at the address Mar 19 3:39 to 3:59 PM and the job was marked complete at 4:01 PM, the day after its date'),
      (1416, timestamptz '2026-02-25T15:40:34.007Z', timestamptz '2026-02-25T16:39:20.022Z',
       'Cloggy parked 79 m from the address Feb 25 10:40 to 11:39 AM and the job was marked complete at 11:38 AM, during that stay'),
      (7088, timestamptz '2026-07-14T01:02:08.497Z', timestamptz '2026-07-14T01:18:42.489Z',
       'Cloggy''s one stop there (9:02 to 9:18 PM) is the same stop as the next-door visit 7085: one parking spot, two services, the whole stop to each')
    ) AS t(id, a, d, why)
  LOOP
    PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-samsara',
           'x-change-reason', 'Samsara audit 2026-10-15 (Fred: "For 4 yes"): ' || r.why || '. Was marked nothing to measure.'))::text, true);
    UPDATE public.visits
       SET actual_arrival_at = r.a, actual_departure_at = r.d,
           duration_minutes = round(extract(epoch FROM r.d - r.a) / 60)::integer, time_on_site_source = 'samsara_stay'
     WHERE id = r.id AND visit_status = 'completed' AND deleted_at IS NULL
       AND time_on_site_source = 'reviewed_blank' AND duration_minutes IS NULL;
    GET DIAGNOSTICS n = row_count;
    IF n <> 1 THEN RAISE EXCEPTION 'visit % not saved (no longer reviewed_blank?)', r.id; END IF;
  END LOOP;

  SET LOCAL app.suppress_jobber_push = 'on';
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'samsara-audit',
         'x-change-reason', 'Samsara audit 2026-10-15 (Fred: "For 8 yes"): date put back to Jun 30, 4:15 AM, as it was when the job was completed (Samsara: Cloggy there 7:06 to 7:23 AM); automated writes had moved it to Jul 2 after completion. Jobber push suppressed.'))::text, true);
  UPDATE public.visits
     SET start_at = timestamptz '2026-06-30T08:15:00Z', end_at = timestamptz '2026-06-30T09:15:00Z', visit_date = date '2026-06-30'
   WHERE id = 6592 AND visit_status = 'completed' AND deleted_at IS NULL
     AND visit_date = date '2026-07-02' AND start_at = timestamptz '2026-07-02T08:15:00Z';
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION '6592 not moved (changed since the audit?)'; END IF;
  UPDATE public.visits SET sync_state = 'confirmed' WHERE id = 6592 AND sync_state = 'pending';
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $s$;

DO $v$ DECLARE r jsonb; BEGIN
  IF (SELECT count(*) FROM public.visits WHERE id IN (1509, 1416, 7088) AND time_on_site_source = 'samsara_stay'
        AND duration_minutes IN (20, 59, 17)) <> 3 THEN RAISE EXCEPTION 'VERIFY: the three stays'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visits WHERE id = 6592 AND visit_date = date '2026-06-30'
                   AND start_at = timestamptz '2026-06-30T08:15:00Z' AND sync_state = 'confirmed'
                   AND completed_at = timestamptz '2026-06-30T11:30:46Z') THEN RAISE EXCEPTION 'VERIFY: 6592'; END IF;
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T2')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
END $v$;

COMMIT;
