-- ============================================================================
-- 2026-10-18_1300_time_on_site_one_time_fix_trucks One-time 2026 duration fix, trucks stage: the truck Fred named on 5 visits
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18 (answers to the plan's questions, final): Q4 "pumping -> the truck whose pump ran at the client
--   with no other visit; labor -> the visit's truck", naming 1600 -> Moises, 1467 -> Moises, 1350 -> David; Q6 grouped
--   lines "as a line of the same job done by the same truck in the same stay". Trucks before times (PLAN.md 6): every
--   writer trusts the visit's truck, and the time stage's guard compares the live truck with the ledger's.
-- WHAT CHANGES
--   public.visits.vehicle_id on the ledger rows of run tos-fix-2026-r1 with truck_stage '1' and truck_status 'approved':
--   1350 none -> David (Q4:1350), 1467 Cloggy -> Moises (Q4:1467), 1600 Cloggy -> Moises (Q4:1600), 8017 Moises -> Cloggy (Q6:8017), 8820 none -> Moises (Q6:8820).
--   Their times are written by 2026-10-18_1302_time_on_site_one_time_fix_times_medium.sql (stage 3), measured on the new truck.
--   Not here: 8018 (Fred named Cloggy) went to a card with its time on 2026-10-18 (the verifier reproduced 44 min where
--   Fred said 38), so its truck and its time land together; 5795, 7828, 5819, 7319 are cards (Fred: "CARDS").
-- THE ROW GUARD
--   Written only while the visit still has the old truck and exactly the dry run's time columns, visit_date and
--   completed_at, completed and not deleted, no bonus decided since. A moved row becomes truck_status 'skipped_guard';
--   its time row is then skipped by stage 3's guard too (truck_not_applied).
-- PIN: Stage 0's bodies; 5 approved truck rows, checksum 0985da56213c5c3e40ed1791e3808304; every one dated before today ET, so
--   trg_zz_queue_start_recheck (it lists vehicle_id) returns before queueing anything (it only queues today or later).
-- NOTHING GOES TO JOBBER: vehicle_id is not in the WHEN list of trg_push_visit_update nor in fn_mark_visit_sync_pending;
--   the VERIFY asserts no jobber-push request was queued and that only vehicle_id (and updated_at) changed.
-- CONSEQUENCE (PLAN.md 7.5 R18): Calendar Hours worked moves these visits to the new truck's lane; a frozen past Grease
--   day keeps its stored truck. After applying, dry-run the linker: select public.fn_link_visit_vehicle_stops(false)->'changes'.
-- LABEL: x-app-source time-on-site-fix-2026, one reason for the transaction.
-- REHEARSED: in one transaction forced to roll back, on top of Stage 0 and the ledger load (stages/rehearsal, local).
-- ROLLBACK: docs/migrations/2026-10-18_rollback_time_on_site_one_time_fix_trucks.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

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
  SELECT count(*), md5(string_agg(concat_ws('|', l.visit_id, coalesce(l.old_vehicle_id::text, '~'), coalesce(l.new_vehicle_id::text, '~')), E'\n' ORDER BY l.visit_id)) INTO n, c
    FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_stage = '1' AND l.truck_status = 'approved';
  IF n <> 5 OR c IS DISTINCT FROM '0985da56213c5c3e40ed1791e3808304' THEN
    RAISE EXCEPTION 'trucks: % approved truck rows, checksum %; expected 5, 0985da56213c5c3e40ed1791e3808304 (ledger not loaded, already applied, or another ledger file)', n, c; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_stage = '1' AND l.truck_status = 'approved'
              AND l.old_visit_date >= (now() AT TIME ZONE 'America/New_York')::date) THEN
    RAISE EXCEPTION 'trucks: a truck row is dated today or later'; END IF;
END $pin$;

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('trucks:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('trucks:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('trucks:checks0', public.fn_time_on_site_checks()),
  ('trucks:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

DO $lock$ BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT l.visit_id FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_stage = '1' AND l.truck_status = 'approved') FOR UPDATE;
END $lock$;
CREATE TEMP TABLE _tos_trk ON COMMIT DROP AS
SELECT l.id AS lid, l.visit_id, l.old_vehicle_id, l.new_vehicle_id,
       CASE WHEN v.id IS NULL THEN 'missing'
            WHEN v.visit_status IS DISTINCT FROM 'completed' OR v.deleted_at IS NOT NULL THEN 'not_completed_or_deleted'
            WHEN v.vehicle_id IS DISTINCT FROM l.old_vehicle_id THEN 'truck_moved'
            WHEN (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (l.old_minutes, l.old_arrival, l.old_departure, l.old_source) THEN 'time_moved'
            WHEN (v.visit_date, v.completed_at) IS DISTINCT FROM (l.old_visit_date, l.old_completed_at) THEN 'date_or_completion_moved'
            WHEN (SELECT max(r.bonus_decided_at) FROM public.visit_reviews r WHERE r.visit_id = l.visit_id) IS DISTINCT FROM l.bonus_decided_at_seen THEN 'bonus_decided'
       END AS skip_reason
  FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
 WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_stage = '1' AND l.truck_status = 'approved';

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; e int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-2026',
         'x-change-reason', 'One-time 2026 duration fix, trucks stage, run tos-fix-2026-r1: the truck Fred named on 2026-10-18 (Q4 pumping goes to the truck whose pump ran at the client; Q6 grouped lines). Per-visit decision in public.visit_time_on_site_corrections. Not pushed to Jobber.'))::text, true);
  UPDATE public.visits v SET vehicle_id = s.new_vehicle_id
    FROM _tos_trk s WHERE v.id = s.visit_id AND s.skip_reason IS NULL;
  GET DIAGNOSTICS n = row_count;
  SELECT count(*) INTO e FROM _tos_trk WHERE skip_reason IS NULL;
  IF n <> e THEN RAISE EXCEPTION 'trucks: wrote % visits, expected %', n, e; END IF;
  UPDATE public.visit_time_on_site_corrections l
     SET truck_status = CASE WHEN s.skip_reason IS NULL THEN 'applied' ELSE 'skipped_guard' END,
         truck_applied_at = CASE WHEN s.skip_reason IS NULL THEN now() END,
         evidence = l.evidence || jsonb_build_object('truck_applied_by_migration', CASE WHEN s.skip_reason IS NULL THEN '2026-10-18_1300_time_on_site_one_time_fix_trucks.sql' END)
    FROM _tos_trk s WHERE l.id = s.lid;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; e int; a0 bigint; ck jsonb; ck0 jsonb; t text; n_app int; n_skip int; skipped jsonb;
BEGIN
  SELECT count(*) FILTER (WHERE l.truck_status = 'applied'), count(*) FILTER (WHERE l.truck_status = 'skipped_guard'),
         jsonb_object_agg(s.visit_id, s.skip_reason) FILTER (WHERE s.skip_reason IS NOT NULL)
    INTO n_app, n_skip, skipped FROM _tos_trk s JOIN public.visit_time_on_site_corrections l ON l.id = s.lid;
  IF n_app + n_skip <> 5 THEN RAISE EXCEPTION 'VERIFY trucks: % applied + % skipped, expected 5', n_app, n_skip; END IF;
  SELECT count(*) INTO n FROM _tos_trk s JOIN public.visits v ON v.id = s.visit_id
   WHERE s.skip_reason IS NULL AND v.vehicle_id IS DISTINCT FROM s.new_vehicle_id;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY trucks: % visits do not carry the new truck', n; END IF;
  e := n_app;
  CREATE TEMP TABLE _tos_wtrk ON COMMIT DROP AS SELECT visit_id FROM _tos_trk WHERE skip_reason IS NULL;

  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'trucks:audit_id0');
  -- (c) only the visits this file wrote changed, once each, and only in vehicle_id
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> e THEN RAISE EXCEPTION 'VERIFY trucks: % audit rows on public.visits, expected %', n, e; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _tos_wtrk)
          OR (a.old_row - ARRAY['vehicle_id', 'updated_at']) IS DISTINCT FROM (a.new_row - ARRAY['vehicle_id', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-2026'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY trucks: % visit writes outside the stage, outside vehicle_id, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY trucks: % audit rows on other tables', n; END IF;
  -- (d) the controls (a timed visit outside the ledger, a card row) are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'trucks:controls') THEN RAISE EXCEPTION 'VERIFY trucks: a control visit changed'; END IF;
  -- (e) nothing went to Jobber: no push request queued for these visits (the push trigger's WHEN list has no time column
  --     and no vehicle_id, so it does not fire; this proves it)
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'trucks:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _tos_wtrk);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY trucks: % Jobber push requests queued', n; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'trucks:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) THEN
      RAISE EXCEPTION 'VERIFY trucks: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY trucks: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  INSERT INTO _tos_report VALUES ('trucks', jsonb_build_object('applied', n_app, 'skipped', n_skip, 'skipped_rows', skipped, 'checks', ck - 'T_detail',
    'trucks_now', (SELECT jsonb_object_agg(v.id, v.vehicle_id) FROM _tos_trk s JOIN public.visits v ON v.id = s.visit_id)));
  RAISE NOTICE 'trucks: % applied, % skipped_guard %', n_app, n_skip, skipped;
END $v$;

COMMIT;
