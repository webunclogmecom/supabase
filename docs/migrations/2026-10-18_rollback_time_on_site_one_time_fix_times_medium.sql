-- ============================================================================
-- ROLLBACK of 2026-10-18_1302_time_on_site_one_time_fix_times_medium.sql
-- ============================================================================
-- Puts back the dry run's old four time columns on the visits stage 3 applied, ONLY where the visit still holds
-- the value the stage wrote (a later legitimate change is never clobbered; such a row stays 'applied', T7 already
-- names it, and it is listed in the report). Restored rows become 'rolled_back' with rolled_back_at.
--   Labelled x-app-source time-on-site-fix-rollback. Writes the four time columns only; nothing goes to Jobber.
--   A restored legacy value has time_on_site_source NULL again, so T3 ("a time written without a source") counts each
--   one whose minutes changed for the next 24 hours: expected, and the VERIFY allows T3 to rise by exactly that number.
--   Roll back in reverse order: times_medium, times_high, trucks, then Stage 0 (2026-10-18_rollback_time_on_site_one_time_fix_stage0.sql).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'no ledger table'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'applied') THEN
    RAISE EXCEPTION 'stage 3: nothing applied to roll back'; END IF;
END $pin$;

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('rb3:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('rb3:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('rb3:checks0', public.fn_time_on_site_checks()),
  ('rb3:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

DO $lock$ BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT l.visit_id FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'applied') FOR UPDATE;
END $lock$;
CREATE TEMP TABLE _tos_rb3 ON COMMIT DROP AS
SELECT l.id AS lid, l.visit_id, l.old_minutes, l.old_arrival, l.old_departure, l.old_source,
       (v.id IS NOT NULL AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS NOT DISTINCT FROM (l.new_minutes, l.new_arrival, l.new_departure, l.new_source)) AS restore,
       (l.new_minutes, l.new_arrival, l.new_departure, l.new_source) IS DISTINCT FROM (l.old_minutes, l.old_arrival, l.old_departure, l.old_source) AS writes,
       (l.old_source IS NULL AND l.old_minutes IS NOT NULL AND l.old_minutes IS DISTINCT FROM l.new_minutes) AS t3_expected
  FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
 WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.stage = '3' AND l.status = 'applied';

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; e int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-rollback',
         'x-change-reason', 'Rollback of the one-time 2026 duration fix, stage 3, run tos-fix-2026-r1: the value before the fix put back (public.visit_time_on_site_corrections old_*).'))::text, true);
  UPDATE public.visits v
     SET duration_minutes = s.old_minutes, actual_arrival_at = s.old_arrival,
         actual_departure_at = s.old_departure, time_on_site_source = s.old_source
    FROM _tos_rb3 s WHERE v.id = s.visit_id AND s.restore AND s.writes;
  GET DIAGNOSTICS n = row_count;
  SELECT count(*) INTO e FROM _tos_rb3 WHERE restore AND writes;
  IF n <> e THEN RAISE EXCEPTION 'rollback stage 3: restored % visits, expected %', n, e; END IF;
  UPDATE public.visit_time_on_site_corrections l SET status = 'rolled_back', rolled_back_at = now() FROM _tos_rb3 s WHERE l.id = s.lid AND s.restore;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; e int; a0 bigint; ck jsonb; ck0 jsonb; t text; kept jsonb; t3e int;
BEGIN
  SELECT count(*) INTO n FROM _tos_rb3 s JOIN public.visits v ON v.id = s.visit_id
   WHERE s.restore AND (v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source) IS DISTINCT FROM (s.old_minutes, s.old_arrival, s.old_departure, s.old_source);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rb3: % restored rows do not hold the old value', n; END IF;
  SELECT jsonb_agg(visit_id) INTO kept FROM _tos_rb3 WHERE NOT restore;
  SELECT count(*) INTO e FROM _tos_rb3 WHERE restore AND writes;
  SELECT count(*) INTO t3e FROM _tos_rb3 WHERE restore AND t3_expected;
  CREATE TEMP TABLE _tos_wrb3 ON COMMIT DROP AS SELECT visit_id FROM _tos_rb3 WHERE restore AND writes;

  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rb3:audit_id0');
  -- (c) only the visits this file wrote changed, once each, and only in the four time columns
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> e THEN RAISE EXCEPTION 'VERIFY rb3: % audit rows on public.visits, expected %', n, e; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _tos_wrb3)
          OR (a.old_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at']) IS DISTINCT FROM (a.new_row - ARRAY['duration_minutes', 'actual_arrival_at', 'actual_departure_at', 'time_on_site_source', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-rollback'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rb3: % visit writes outside the stage, outside the four time columns, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rb3: % audit rows on other tables', n; END IF;
  -- (d) the controls (a timed visit outside the ledger, a card row) are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'rb3:controls') THEN RAISE EXCEPTION 'VERIFY rb3: a control visit changed'; END IF;
  -- (e) nothing went to Jobber: no push request queued for these visits (the push trigger's WHEN list has no time column
  --     and no vehicle_id, so it does not fire; this proves it)
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rb3:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _tos_wrb3);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rb3: % Jobber push requests queued', n; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'rb3:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) AND t <> 'T3' THEN
      RAISE EXCEPTION 'VERIFY rb3: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY rb3: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  IF coalesce((ck->>'T3')::int, 0) > coalesce((ck0->>'T3')::int, 0) + t3e THEN
    RAISE EXCEPTION 'VERIFY rb3: T3 rose by more than the % restored legacy values', t3e; END IF;
  INSERT INTO _tos_report VALUES ('rb3', jsonb_build_object('restored', e, 'marked_rolled_back', (SELECT count(*) FROM _tos_rb3 WHERE restore),
    'kept_because_moved', kept, 't3_expected', t3e, 'checks', ck - 'T_detail'));
END $v$;

COMMIT;
