-- ============================================================================
-- ROLLBACK of 2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql
-- ============================================================================
-- Puts back, on the 9 visits Q11 wrote, the four time columns and the truck they held before it
-- (public.visit_time_on_site_corrections evidence->'q11_before_visit'), ONLY where the visit still holds the value Q11
-- wrote; and puts each ledger row back in its earlier state (evidence->'q11_before': a stage 2 row is 'applied' again
-- with its earlier value, so T7 keeps watching it; a card is 'proposed' again). A visit that moved since is kept and
-- listed; its ledger row is then kept too, so T7/T8 name it. The rollback is recorded in evidence->'q11_rolled_back'.
--   Labelled x-app-source time-on-site-fix-rollback. Writes the four time columns and vehicle_id only; nothing goes to
--   Jobber. A visit whose earlier source was NULL and whose minutes change back would be counted by T3 ("a time
--   written without a source") for 24 hours; none of the 9 has a NULL earlier source, and the VERIFY allows T3 to
--   rise by exactly the number of such rows (0).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'no ledger table'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.superseded_at IS NULL AND l.status = 'applied'
                  AND l.applied_by_migration = '2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql') THEN
    RAISE EXCEPTION 'q11: nothing applied to roll back'; END IF;
END $pin$;

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('rbq11:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('rbq11:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('rbq11:checks0', public.fn_time_on_site_checks()),
  ('rbq11:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

DO $lock$ BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT l.visit_id FROM public.visit_time_on_site_corrections l WHERE l.superseded_at IS NULL AND l.status = 'applied'
                                                  AND l.applied_by_migration = '2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql') FOR UPDATE;
END $lock$;
CREATE TEMP TABLE _q11_rb ON COMMIT DROP AS
SELECT l.id AS lid, l.visit_id, l.evidence->'q11_before' AS b, l.evidence->'q11_before_visit' AS bv,
       (l.evidence->'q11_before_visit'->>'duration_minutes')::int AS old_min,
       (l.evidence->'q11_before_visit'->>'actual_arrival_at')::timestamptz AS old_arr,
       (l.evidence->'q11_before_visit'->>'actual_departure_at')::timestamptz AS old_dep,
       l.evidence->'q11_before_visit'->>'time_on_site_source' AS old_src,
       (l.evidence->'q11_before_visit'->>'vehicle_id')::bigint AS old_veh, l.new_minutes AS q11_min,
       (v.id IS NOT NULL AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id)
          IS NOT DISTINCT FROM (l.new_minutes, l.new_arrival, l.new_departure, l.new_source, l.new_vehicle_id)) AS restore
  FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
 WHERE l.superseded_at IS NULL AND l.status = 'applied' AND l.applied_by_migration = '2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql';

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; e int;
BEGIN
  IF EXISTS (SELECT 1 FROM _q11_rb WHERE b IS NULL OR bv IS NULL) THEN RAISE EXCEPTION 'rollback q11: a ledger row has no q11_before snapshot'; END IF;
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-rollback',
         'x-change-reason', 'Rollback of the one-time 2026 duration fix, Q11 photo stamps, run tos-fix-2026-r1: the value and truck before Q11 put back (public.visit_time_on_site_corrections evidence q11_before_visit).'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = s.old_min, actual_arrival_at = s.old_arr, actual_departure_at = s.old_dep,
         time_on_site_source = s.old_src, vehicle_id = s.old_veh
    FROM _q11_rb s WHERE v.id = s.visit_id AND s.restore;
  GET DIAGNOSTICS n = row_count;
  SELECT count(*) INTO e FROM _q11_rb WHERE restore;
  IF n <> e THEN RAISE EXCEPTION 'rollback q11: restored % visits, expected %', n, e; END IF;
  UPDATE public.visit_time_on_site_corrections l
     SET status = s.b->>'status', action = s.b->>'action', method = s.b->>'method', confidence = s.b->>'confidence',
         decision_ref = s.b->>'decision_ref',
         new_arrival = (s.b->>'new_arrival')::timestamptz, new_departure = (s.b->>'new_departure')::timestamptz,
         new_minutes = (s.b->>'new_minutes')::int, new_source = s.b->>'new_source', new_vehicle_id = (s.b->>'new_vehicle_id')::bigint,
         truck_stage = s.b->>'truck_stage', truck_status = s.b->>'truck_status', truck_applied_at = (s.b->>'truck_applied_at')::timestamptz,
         applied_at = (s.b->>'applied_at')::timestamptz, applied_by_migration = s.b->>'applied_by_migration',
         evidence = (l.evidence - 'q11_before' - 'q11_before_visit' - 'q11')
                    || jsonb_build_object('q11_rolled_back', jsonb_build_object('at', now(), 'q11', l.evidence->'q11',
                         'value_rolled_back', jsonb_build_object('minutes', l.new_minutes, 'arrival', l.new_arrival, 'departure', l.new_departure, 'vehicle_id', l.new_vehicle_id)))
    FROM _q11_rb s WHERE l.id = s.lid AND s.restore;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; e int; a0 bigint; ck jsonb; ck0 jsonb; t text; kept jsonb; t3e int;
BEGIN
  SELECT count(*) INTO n FROM _q11_rb s JOIN public.visits v ON v.id = s.visit_id
   WHERE s.restore AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source, v.vehicle_id)
                       IS DISTINCT FROM (s.old_min, s.old_arr, s.old_dep, s.old_src, s.old_veh);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbq11: % restored visits do not hold the old value', n; END IF;
  SELECT count(*) INTO n FROM _q11_rb s JOIN public.visit_time_on_site_corrections l ON l.id = s.lid
   WHERE s.restore AND (l.evidence ? 'q11_before' OR l.applied_by_migration IS NOT DISTINCT FROM '2026-10-18_1631_time_on_site_one_time_fix_q11_stamps.sql');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbq11: % ledger rows not put back', n; END IF;
  SELECT jsonb_agg(visit_id) INTO kept FROM _q11_rb WHERE NOT restore;
  SELECT count(*) INTO e FROM _q11_rb WHERE restore;
  SELECT count(*) INTO t3e FROM _q11_rb WHERE restore AND old_src IS NULL AND old_min IS NOT NULL AND old_min IS DISTINCT FROM q11_min;
  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rbq11:audit_id0');
  -- (c) only the restored visits changed, once each, and only in the time columns and vehicle_id
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> e THEN RAISE EXCEPTION 'VERIFY rbq11: % audit rows on public.visits, expected %', n, e; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _q11_rb WHERE restore)
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
             IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'vehicle_id', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-rollback'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbq11: % visit writes outside the set, outside the allowed columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbq11: % audit rows on other tables', n; END IF;
  -- (d) the controls are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'rbq11:controls') THEN RAISE EXCEPTION 'VERIFY rbq11: a control visit changed'; END IF;
  -- (e) nothing went to Jobber
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rbq11:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _q11_rb);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbq11: % Jobber push requests queued', n; END IF;
  -- (f) T1 to T8: none newly failing except T3 by the restored legacy values, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'rbq11:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) AND t <> 'T3' THEN
      RAISE EXCEPTION 'VERIFY rbq11: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY rbq11: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  IF coalesce((ck->>'T3')::int, 0) > coalesce((ck0->>'T3')::int, 0) + t3e THEN
    RAISE EXCEPTION 'VERIFY rbq11: T3 rose by more than the % restored legacy values', t3e; END IF;
  INSERT INTO _tos_report VALUES ('rbq11', jsonb_build_object('restored', e, 'kept_because_moved', kept, 't3_expected', t3e, 'checks', ck - 'T_detail'));
END $v$;

COMMIT;
