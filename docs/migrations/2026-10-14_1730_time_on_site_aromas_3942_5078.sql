-- ============================================================================
-- 2026-10-14_1730 Time on site: 227-PER visits 3942 and 5078 share David's one stay of 2026-05-11
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14, on the report row for 5078 (2026-05-12, "remove test ball and pump", no property, no truck):
--   "the 5078 makes no sense because the data is in 3942, which is the address". Same rule as visit 8017 earlier the
--   same day ("give 8017 the 1h 23m, because they had the same truck, and also they just went once that date").
-- WHAT THE DATA SAYS
--   Samsara: David parked at the client's address once, 2026-05-11 10:28:36 to 17:20:38 ET (trip gap, 6 h 52 min);
--   our GPS stays agree (10:27 to 17:21, one re-park 0 m apart). No truck went there on 2026-05-12. 3942 (pumping,
--   David) was marked complete at 18:24, after he left, so no rule matched it; 5078 has no property and no truck, so
--   nothing could. Both are the same stay (two services, one stop, as 8013 and 8017).
-- WHAT CHANGES
--   duration / arrival / departure on 3942 and 5078 = that Samsara stay, source samsara_stay, x-app-source
--   time-on-site-samsara with a reason; guarded on both still being blank. 5078's missing property and truck are NOT
--   set here (they are Jobber-mastered visit fields).
-- ROLLBACK: audit.logs.old_row for the two visits (x-app-source time-on-site-samsara).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $s$ DECLARE v_hdr text := current_setting('request.headers', true); n int; BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', 'Time on site set to Samsara''s stay: David parked at the address once on 2026-05-11, and visits 3942 and 5078 were done in that one stay (Fred, 2026-10-14).'))::text, true);
  UPDATE public.visits
     SET actual_arrival_at = timestamptz '2026-05-11T14:28:36.541Z', actual_departure_at = timestamptz '2026-05-11T21:20:38.521Z',
         duration_minutes = 412, time_on_site_source = 'samsara_stay'
   WHERE id IN (3942, 5078) AND visit_status = 'completed' AND deleted_at IS NULL AND duration_minutes IS NULL;
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 visits saved, got %', n; END IF;
END $s$;
DO $v$ DECLARE r jsonb; BEGIN
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
END $v$;
COMMIT;
