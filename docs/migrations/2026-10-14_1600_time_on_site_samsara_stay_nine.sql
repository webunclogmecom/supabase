-- ============================================================================
-- 2026-10-14_1600 Time on site: save Samsara's own stay on 9 old visits; a source label for it
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14, after the check of which blank visits a truck was parked at when marked complete: "yes do both,
--   use Samsara's time for the old ones".
-- WHAT CHANGES
--   1. visits_time_on_site_source_chk admits 'samsara_stay': the time is Samsara's own stay, the gap between the
--      truck's two Samsara trips (/v1/fleet/trips) that overlaps the stop where it was parked when marked complete.
--      No writer overwrites it: the stop fill and the 150 m measurement only replace NULL or gps_150m_cluster, the
--      any-truck fill only blanks. A reopened visit loses it (trg_zz_clear_time_on_site_on_reopen), as intended.
--   2. fn_time_on_site_checks: T1 leaves samsara_stay values alone (Samsara is the judge, the stop is not), T4 counts
--      a samsara_stay value overwritten by a GPS fallback.
--   3. Nine blank visits from before the stop table (2026-08-20) where a truck was parked when the job was marked
--      complete get Samsara's stay (read 2026-10-14 ~15:30 ET; each re-checked below to hold the completion time,
--      -5 / +15 min, like the stop rule). Their truck is NOT changed (6498 and 6194 are set to another truck and are
--      on DERM manifests; Fred's call). Labelled x-app-source time-on-site-samsara with a reason.
--      5061 5157 5788 6496 6498 (214-MYK, parked 158 to 213 m from the map point), 6194, 1522, 1523, 6592.
-- ROLLBACK: set the nine back to NULL (audit.logs holds the old rows), restore fn_time_on_site_checks from
--   2026-10-14_1110 and the CHECK without samsara_stay.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_time_on_site_checks'::regproc))) IS DISTINCT FROM 'b9931a5fd5f4e0b516115f00970ca273' THEN
    RAISE EXCEPTION 'fn_time_on_site_checks changed since this file was written: splice again'; END IF;
END $g$;

ALTER TABLE public.visits DROP CONSTRAINT visits_time_on_site_source_chk;
ALTER TABLE public.visits ADD CONSTRAINT visits_time_on_site_source_chk CHECK (time_on_site_source = ANY (ARRAY[
  'gps_150m_cluster', 'gps_150m_any_truck', 'stop_at_completion', 'dump_site_dwell', 'review', 'reviewed_blank', 'samsara_stay']));

CREATE OR REPLACE FUNCTION public.fn_time_on_site_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-14_1110 (time on site plan step 8): the checks that keep the time on site honest. Each must read 0; they ride
-- in fn_stop_facts_checks' integrity set, so fn_refresh_stop_facts (hourly) writes stop_facts_integrity as error when one
-- is not, and log_jobber_sync_health raises it to the health email. T_detail names the visits (never counted).
DECLARE
  v_today date := (now() at time zone 'America/New_York')::date;
  v_since timestamptz := greatest(now() - interval '24 hours', timestamptz '2026-10-14 02:00+00');   -- writers labelled from step 2
  t1 bigint[]; t3 bigint[]; t4 bigint[]; t5 bigint[]; t6 bigint[]; t2 int; g jsonb;
BEGIN
  -- T1 a client visit from 3 to 10 days ago (the nightly fill has run) whose truck stop holds the completion, but its
  --    time is blank or under 70% of the stop and at least 5 min shorter
  SELECT array_agg(v.id ORDER BY v.id) INTO t1
    FROM public.visits v JOIN public.v_visit_stop_reference r ON r.visit_id = v.id AND r.basis = 'completion' AND r.split_ok
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND NOT public.fn_is_non_customer(v.client_id)
     AND v.visit_date BETWEEN v_today - 10 AND v_today - 3
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank', 'samsara_stay')   -- 2026-10-14_1600: Samsara's own stay is the judge
     AND (v.duration_minutes IS NULL
          OR (v.duration_minutes < 0.7 * extract(epoch FROM r.departure - r.arrival) / 60
              AND extract(epoch FROM r.departure - r.arrival) / 60 - v.duration_minutes >= 5));
  -- T2 positive control: visit 6509 (the truck parked 164 m from the map point) keeps its 34 min stop. Fires if the
  --    matching rule is narrowed again.
  t2 := CASE WHEN EXISTS (SELECT 1 FROM public.v_visit_stop_reference r JOIN public.visits v ON v.id = r.visit_id
                           WHERE r.visit_id = 6509 AND r.basis = 'completion'
                             AND r.arrival = timestamptz '2026-09-25 14:29:11+00' AND r.departure = timestamptz '2026-09-25 15:02:59+00'
                             AND v.duration_minutes BETWEEN 31 AND 35) THEN 0 ELSE 1 END;
  -- T3 a time on site written without a source or a reason (in the last 24 hours)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t3 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > v_since
     AND a.new_row->>'duration_minutes' IS NOT NULL AND a.new_row->>'duration_minutes' IS DISTINCT FROM a.old_row->>'duration_minutes'
     AND (a.new_row->>'time_on_site_source' IS NULL OR coalesce(a.request_context->>'change_reason', '') = '');
  -- T4 a stop-based or reviewed time overwritten by a GPS fallback (ever, since the source column exists)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t4 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > timestamptz '2026-10-14 01:00+00'
     AND a.old_row->>'time_on_site_source' IN ('stop_at_completion', 'dump_site_dwell', 'review', 'reviewed_blank', 'samsara_stay')
     AND a.new_row->>'time_on_site_source' IN ('gps_150m_cluster', 'gps_150m_any_truck');
  -- T5 the 11 AM alert's instrument misses a stop the stop table has (yesterday's blanks): the alert would say
  --    "passed by" or "no truck" about a truck that was parked there
  g := public.fn_time_on_site_gaps(v_today - 1);
  SELECT array_agg((x->>'visit_id')::bigint) INTO t5 FROM jsonb_array_elements(coalesce(g->'visits', '[]')) x
   WHERE (x->'stop_at_completion' IS NULL OR jsonb_typeof(x->'stop_at_completion') = 'null')
     AND EXISTS (SELECT 1 FROM public.v_visit_stop_reference r WHERE r.visit_id = (x->>'visit_id')::bigint AND r.basis = 'completion');
  -- T6 a visit that is not completed still carries a time on site
  SELECT array_agg(v.id ORDER BY v.id) INTO t6 FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status <> 'completed'
     AND (v.duration_minutes IS NOT NULL OR v.actual_arrival_at IS NOT NULL OR v.actual_departure_at IS NOT NULL);
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0), 'T2', t2, 'T3', coalesce(cardinality(t3), 0),
    'T4', coalesce(cardinality(t4), 0), 'T5', coalesce(cardinality(t5), 0), 'T6', coalesce(cardinality(t6), 0),
    'T_detail', jsonb_build_object('T1', t1, 'T3', t3, 'T4', t4, 'T5', t5, 'T6', t6));
END $function$
;

CREATE TEMP TABLE _samsara_nine (visit_id bigint, arrival timestamptz, departure timestamptz, truck text) ON COMMIT DROP;
INSERT INTO _samsara_nine VALUES
    (5061, timestamptz '2026-05-15T08:25:44.400Z', timestamptz '2026-05-15T09:04:55.220Z', 'Moises'),
    (5157, timestamptz '2026-05-29T05:21:11.275Z', timestamptz '2026-05-29T06:02:42.438Z', 'David'),
    (5788, timestamptz '2026-06-11T03:22:34.576Z', timestamptz '2026-06-11T04:05:06.566Z', 'Moises'),
    (6496, timestamptz '2026-06-26T11:05:50.514Z', timestamptz '2026-06-26T11:32:12.529Z', 'David'),
    (6498, timestamptz '2026-07-11T07:40:28.573Z', timestamptz '2026-07-11T08:14:40.723Z', 'Moises'),
    (6194, timestamptz '2026-08-17T17:56:41.513Z', timestamptz '2026-08-17T18:29:04.504Z', 'Cloggy'),
    (1522, timestamptz '2026-03-22T23:34:53.985Z', timestamptz '2026-03-23T00:36:35.038Z', 'Moises'),
    (1523, timestamptz '2026-03-23T00:57:53.273Z', timestamptz '2026-03-23T02:38:50.029Z', 'Moises'),
    (6592, timestamptz '2026-06-30T11:06:39.508Z', timestamptz '2026-06-30T11:23:13.512Z', 'Cloggy');

DO $s$ DECLARE v_hdr text := current_setting('request.headers', true); n int; BEGIN
  -- each stay must hold the completion time, and each visit must still be a blank completed visit
  IF EXISTS (SELECT 1 FROM _samsara_nine s JOIN public.visits v ON v.id = s.visit_id
              WHERE NOT (v.completed_at BETWEEN s.arrival - interval '5 minutes' AND s.departure + interval '15 minutes')) THEN
    RAISE EXCEPTION 'a Samsara stay does not hold its visit''s completion time'; END IF;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-samsara',
         'x-change-reason', 'Time on site set to Samsara''s own stay: the truck was parked there when the job was marked complete (Fred, 2026-10-14).'))::text, true);
  UPDATE public.visits v
     SET actual_arrival_at = s.arrival, actual_departure_at = s.departure,
         duration_minutes = round(extract(epoch FROM s.departure - s.arrival) / 60)::integer,
         time_on_site_source = 'samsara_stay'
    FROM _samsara_nine s
   WHERE v.id = s.visit_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.duration_minutes IS NULL;
  GET DIAGNOSTICS n = row_count;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  IF n <> 9 THEN RAISE EXCEPTION 'expected 9 visits saved, got %', n; END IF;
END $s$;

-- VERIFY
DO $v$ DECLARE r jsonb; BEGIN
  IF (SELECT count(*) FROM public.visits WHERE id IN (SELECT visit_id FROM _samsara_nine) AND time_on_site_source = 'samsara_stay') <> 9 THEN
    RAISE EXCEPTION 'VERIFY: not all nine labelled'; END IF;
  IF (SELECT duration_minutes FROM public.visits WHERE id = 6498) <> 34 THEN RAISE EXCEPTION 'VERIFY: 6498 is not 34 min'; END IF;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 6498) IS DISTINCT FROM (SELECT id FROM public.vehicles WHERE name = 'David') THEN
    RAISE EXCEPTION 'VERIFY: 6498 truck moved'; END IF;
  BEGIN   -- the CHECK still refuses an unknown label
    UPDATE public.visits SET time_on_site_source = 'banana' WHERE id = 6498;
    RAISE EXCEPTION 'VERIFY: CHECK let banana in';
  EXCEPTION WHEN check_violation THEN NULL; END;
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
END $v$;
COMMIT;
