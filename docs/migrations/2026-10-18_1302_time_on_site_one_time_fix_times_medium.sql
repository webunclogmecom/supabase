-- ============================================================================
-- 2026-10-18_1302_time_on_site_one_time_fix_times_medium One-time 2026 duration fix, stage 3: the medium-confidence and shared values
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "design a plan ... on what needs to be done, so the durations we currently have in our DB is as
--   precise as possible, this is a one time fix", then his answers to the plan's questions (2026-10-18, final). The plan,
--   the ledger and the evidence are local (samsara-checks/duration_fix_plan_2026-10-18 and duration_fix_run_2026-10-18,
--   outside the repos because they name clients). This file is PLAN.md section 7.2 for stage 3.
-- WHAT CHANGES
--   public.visits.duration_minutes, actual_arrival_at, actual_departure_at and time_on_site_source on the ledger rows of
--   run tos-fix-2026-r1 with stage '3' and status 'approved' (59 rows: 59 change).
--   59 visits are written (59 labelled 'review', 0 'reviewed_blank'); the other 0 rows only become
--   'applied' in the ledger, so T7 watches them (keep_verified: a verified samsara_stay or stop_at_completion value kept
--   as it is; a blank with no Samsara presence or no data stays NULL: unknown is not zero). Net change -553 min.
--   'review' is the label every writer skips (PLAN.md 7.3): a changed value, a legacy NULL-label value kept by the
--   no-churn rule, and Fred's locks (same minutes). 'reviewed_blank' = a person found nothing to measure, all four NULL.
-- THE ROW GUARD
--   A visit is written only while it still holds exactly what the dry run saw: its four time columns, its truck (the
--   ledger's new_vehicle_id: the new truck on the 5 truck rows, the old one elsewhere), visit_date and completed_at, completed and not deleted, and no
--   bonus decided since (visit_reviews.bonus_decided_at). Its stage's visits are locked first (FOR UPDATE). A row that
--   moved is never forced: it becomes 'skipped_guard' in the ledger and is listed in the report; more than
--   10 skipped rows stop the file (something ran over history since the dry run).
-- PIN
--   Stage 0's four bodies (md5); the stage's approved ledger rows: 59 rows, checksum d16754d2a2a8ed77034be99b1e56664c (md5 of the
--   ordered visit_id, stage, action, old and new values and trucks, as stages/load_ledger.mjs computes it from
--   ledger_final.json sha256 2082acc7c0726196...). A second run refuses (no approved rows left).
--   The trucks stage first (2026-10-18_1300_time_on_site_one_time_fix_trucks.sql): a stage 3 row whose truck part is still 'approved' refuses.
-- WHAT DOES NOT CHANGE
--   visit_date, start_at, end_at, visit_status, deleted_at, vehicle_id, sync_state, the schedule: the VERIFY reads every
--   audit row of this transaction and allows only the four time columns (and updated_at) on this stage's visits.
--   Nothing goes to Jobber: trg_push_visit_update and trg_mark_visit_sync_pending fire only on visit_date, start_at,
--   end_at, title, notes, job_id, line items, team, deleted_at or visit_status; trg_zz_queue_start_recheck does not list
--   the time columns. The VERIFY also asserts no jobber-push request was queued for these visits.
-- LABEL: x-app-source time-on-site-fix-2026 with one reason for the transaction (audit.log_change keeps 500 characters;
--   the per-visit method, evidence and decision are in public.visit_time_on_site_corrections).
-- VERIFY: applied + skipped = 59; every applied row holds the ledger's new value, truck, date and completion; only this
--   stage's visits changed, only in the time columns, each labelled; two control visits byte-identical; no Jobber push;
--   T1 to T6 not newly failing, T7 = T8 = 0.
-- REHEARSED: in one transaction forced to roll back, on top of Stage 0 and the ledger load (stages/rehearsal, local).
-- LOCKS: lock_timeout 3s. Apply between 10:00 and 18:00 ET on a weekday, not :30 to :45 past the hour.
-- ROLLBACK: docs/migrations/2026-10-18_rollback_time_on_site_one_time_fix_times_medium.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 0. PIN
DO $pin$ DECLARE n int; c text; BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'Stage 0 is not applied: the ledger table does not exist'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_time_on_site_from_stops(boolean)'::regprocedure)) <> 'acaaf87971f7ca4536f96c6772acc170' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_fill_time_on_site_from_stops(boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_fill_blank_time_on_site(date,date,boolean)'::regprocedure)) <> 'b1d8cea3a5f2fc01c62b2a2d1fccbe5d' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_fill_blank_time_on_site(date,date,boolean)'; END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_time_on_site_checks()'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'a1d91a0a28604c25852429d697c1622f' THEN
    RAISE EXCEPTION '% is not the Stage 0 body: Stage 0 is not applied, or something changed it since', 'fn_refresh_stop_facts(bigint,timestamp with time zone)'; END IF;
  SELECT count(*), md5(string_agg(concat_ws('|', l.visit_id, l.stage, l.action, coalesce(l.old_minutes::text, '~'), coalesce(extract(epoch from l.old_arrival)::text, '~'), coalesce(extract(epoch from l.old_departure)::text, '~'), coalesce(l.old_source, '~'), coalesce(l.new_minutes::text, '~'), coalesce(extract(epoch from l.new_arrival)::text, '~'), coalesce(extract(epoch from l.new_departure)::text, '~'), coalesce(l.new_source, '~'), coalesce(l.old_vehicle_id::text, '~'), coalesce(l.new_vehicle_id::text, '~')), E'\n' ORDER BY l.visit_id)) INTO n, c
    FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'approved';
  IF n <> 59 OR c IS DISTINCT FROM 'd16754d2a2a8ed77034be99b1e56664c' THEN
    RAISE EXCEPTION 'stage 3: % approved ledger rows, checksum %; expected 59, d16754d2a2a8ed77034be99b1e56664c (ledger not loaded, stage already applied, or another ledger file)', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'approved' AND l.truck_stage = '1' AND l.truck_status = 'approved') THEN
    RAISE EXCEPTION 'apply the trucks stage first (2026-10-18_1300_time_on_site_one_time_fix_trucks.sql)'; END IF;
END $pin$;

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('medium:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('medium:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('medium:checks0', public.fn_time_on_site_checks()),
  ('medium:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

-- 1. Lock the stage's visits, then compare each with what the dry run saw.
DO $lock$ BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT l.visit_id FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'approved') FOR UPDATE;
END $lock$;
CREATE TEMP TABLE _tos_s3 ON COMMIT DROP AS
SELECT l.id AS lid, l.visit_id, l.new_minutes, l.new_arrival, l.new_departure, l.new_source,
       CASE WHEN v.id IS NULL THEN 'missing'
            WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
            WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (l.old_minutes, l.old_arrival, l.old_departure, l.old_source) THEN 'time_moved'
            WHEN v.vehicle_id IS DISTINCT FROM l.new_vehicle_id THEN 'truck_moved'
            WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at) THEN 'date_or_completion_moved'
            WHEN (SELECT max(r.bonus_decided_at) FROM public.visit_reviews r WHERE r.visit_id = l.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen THEN 'bonus_decided'
            WHEN l.truck_stage = '1' AND l.truck_status IS DISTINCT FROM 'applied' THEN 'truck_not_applied'
       END AS skip_reason,
       (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (l.old_minutes, l.old_arrival, l.old_departure, l.old_source) AS writes
  FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
 WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'approved';

-- 2. Write, labelled, then mark the ledger.
DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; e int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-2026',
         'x-change-reason', 'One-time 2026 duration fix, stage 3 (medium and shared), run tos-fix-2026-r1, Fred''s answers of 2026-10-18: time on site from Samsara''s own trips and 1 Hz track. Method, evidence and decision per visit in public.visit_time_on_site_corrections.'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = s.new_minutes, actual_arrival_at = s.new_arrival,
         actual_departure_at = s.new_departure, time_on_site_source = s.new_source
    FROM _tos_s3 s
   WHERE v.id = s.visit_id AND s.skip_reason IS NULL AND s.writes;
  GET DIAGNOSTICS n = row_count;
  SELECT count(*) INTO e FROM _tos_s3 WHERE skip_reason IS NULL AND writes;
  IF n <> e THEN RAISE EXCEPTION 'stage 3: wrote % visits, expected %', n, e; END IF;
  UPDATE public.visit_time_on_site_corrections l
     SET status = CASE WHEN s.skip_reason IS NULL THEN 'applied' ELSE 'skipped_guard' END,
         applied_at = CASE WHEN s.skip_reason IS NULL THEN now() END,
         applied_by_migration = CASE WHEN s.skip_reason IS NULL THEN '2026-10-18_1302_time_on_site_one_time_fix_times_medium.sql' END
    FROM _tos_s3 s WHERE l.id = s.lid;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

-- 3. VERIFY (each check raises, so a failure rolls the whole file back)
DO $v$
DECLARE n int; e int; a0 bigint; ck jsonb; ck0 jsonb; t text; n_app int; n_skip int; skipped jsonb;
BEGIN
  SELECT count(*) FILTER (WHERE l.status = 'applied'), count(*) FILTER (WHERE l.status = 'skipped_guard'),
         jsonb_object_agg(s.visit_id, s.skip_reason) FILTER (WHERE s.skip_reason IS NOT NULL)
    INTO n_app, n_skip, skipped FROM _tos_s3 s JOIN public.visit_time_on_site_corrections l ON l.id = s.lid;
  IF n_app + n_skip <> 59 THEN RAISE EXCEPTION 'VERIFY medium: % applied + % skipped, expected 59', n_app, n_skip; END IF;
  IF n_skip > 10 THEN RAISE EXCEPTION 'VERIFY medium: % rows moved since the dry run (more than 10): stop and re-measure: %', n_skip, skipped; END IF;
  -- (b) every applied row now holds the ledger's new value, truck, date and completion
  SELECT count(*) INTO n FROM _tos_s3 s JOIN public.visit_time_on_site_corrections l ON l.id = s.lid JOIN public.visits v ON v.id = l.visit_id
   WHERE l.status = 'applied'
     AND ((v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) OR v.vehicle_id IS DISTINCT FROM l.new_vehicle_id
          OR (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at)
          OR v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY medium: % applied rows do not hold the ledger value', n; END IF;
  -- (b2) the shape of every value written (PLAN.md 8.3): all four set or the three times NULL together, at most 719 min
  --      (the Calendar's measured cap), minutes = departure - arrival within 1 min except summed loads (Q2 iii: the
  --      clock times are the main load's, the minutes are the sum)
  SELECT count(*) INTO n FROM _tos_s3 s JOIN public.visits v ON v.id = s.visit_id JOIN public.visit_time_on_site_corrections l ON l.id = s.lid
   WHERE s.skip_reason IS NULL AND s.writes
     AND (num_nulls(v.duration_minutes, v.actual_arrival_at, v.actual_departure_at) NOT IN (0, 3)
          OR v.duration_minutes > 719 OR v.actual_departure_at <= v.actual_arrival_at
          OR (l.method <> 'loads_summed'
              AND abs(v.duration_minutes - round(extract(epoch FROM v.actual_departure_at - v.actual_arrival_at) / 60)) > 1));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY medium: % written values fail the shape checks', n; END IF;
  SELECT count(*) INTO e FROM _tos_s3 WHERE skip_reason IS NULL AND writes;
  CREATE TEMP TABLE _tos_w3 ON COMMIT DROP AS SELECT visit_id FROM _tos_s3 WHERE skip_reason IS NULL AND writes;

  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'medium:audit_id0');
  -- (c) only the visits this file wrote changed, once each, and only in the four time columns
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> e THEN RAISE EXCEPTION 'VERIFY medium: % audit rows on public.visits, expected %', n, e; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _tos_w3)
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at']) IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY medium: % visit writes outside the stage, outside the four time columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY medium: % audit rows on other tables', n; END IF;
  -- (d) the controls (a timed visit outside the ledger, a card row) are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'medium:controls') THEN RAISE EXCEPTION 'VERIFY medium: a control visit changed'; END IF;
  -- (e) nothing went to Jobber: no push request queued for these visits (the push trigger's WHEN list has no time column
  --     and no vehicle_id, so it does not fire; this proves it)
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'medium:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _tos_w3);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY medium: % Jobber push requests queued', n; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'medium:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY medium: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY medium: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  INSERT INTO _tos_report VALUES ('medium', jsonb_build_object('applied', n_app, 'skipped', n_skip, 'skipped_rows', skipped,
    'visits_written', e, 'checks', ck - 'T_detail', 'by_source', (SELECT jsonb_object_agg(src, c) FROM (SELECT coalesce(v.time_on_site_source, 'NULL') src, count(*) c
       FROM _tos_s3 s JOIN public.visits v ON v.id = s.visit_id GROUP BY 1) x)));
  RAISE NOTICE 'stage 3: % applied (% visits written), % skipped_guard %', n_app, e, n_skip, skipped;
END $v$;

COMMIT;
