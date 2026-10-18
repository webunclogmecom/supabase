-- ============================================================================
-- ROLLBACK of 2026-10-18_1300_time_on_site_one_time_fix_trucks.sql
-- ============================================================================
-- Puts the old truck back on the visits the trucks stage changed, ONLY where the visit still carries the new truck.
-- Refuses while the time part of any of them is applied: roll back 2026-10-18_1302_time_on_site_one_time_fix_times_medium.sql first (its guard measured the time on
-- the new truck, and T8 would ring). Restored rows become truck_status 'rolled_back'. Then dry-run the linker again:
-- select public.fn_link_visit_vehicle_stops(false)->'changes'. Labelled x-app-source time-on-site-fix-rollback; writes
-- vehicle_id only; nothing goes to Jobber.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regclass('public.visit_time_on_site_corrections') IS NULL THEN RAISE EXCEPTION 'no ledger table'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_status = 'applied') THEN
    RAISE EXCEPTION 'trucks: nothing applied to roll back'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_status = 'applied' AND l.status = 'applied') THEN
    RAISE EXCEPTION 'roll back 2026-10-18_1302_time_on_site_one_time_fix_times_medium.sql first: the time part of a truck row is applied'; END IF;
END $pin$;

CREATE TEMP TABLE IF NOT EXISTS _tos_ctx (k text PRIMARY KEY, j jsonb) ON COMMIT DROP;
CREATE TEMP TABLE IF NOT EXISTS _tos_report (step text PRIMARY KEY, j jsonb) ON COMMIT DROP;
INSERT INTO _tos_ctx VALUES
  ('rbtrucks:audit_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM audit.logs))),
  ('rbtrucks:net_id0', to_jsonb((SELECT coalesce(max(id), 0) FROM net.http_request_queue))),
  ('rbtrucks:checks0', public.fn_time_on_site_checks()),
  ('rbtrucks:controls', (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259)));

DO $lock$ BEGIN
  PERFORM 1 FROM public.visits v WHERE v.id IN (SELECT l.visit_id FROM public.visit_time_on_site_corrections l WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_status = 'applied') FOR UPDATE;
END $lock$;
CREATE TEMP TABLE _tos_rbtrk ON COMMIT DROP AS
SELECT l.id AS lid, l.visit_id, l.old_vehicle_id, (v.vehicle_id IS NOT DISTINCT FROM l.new_vehicle_id) AS restore
  FROM public.visit_time_on_site_corrections l LEFT JOIN public.visits v ON v.id = l.visit_id
 WHERE l.run_id = 'tos-fix-2026-r1' AND l.superseded_at IS NULL AND l.truck_status = 'applied';

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int; e int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-rollback',
         'x-change-reason', 'Rollback of the one-time 2026 duration fix, trucks stage, run tos-fix-2026-r1: the truck before the fix put back (public.visit_time_on_site_corrections old_vehicle_id).'))::text, true);
  UPDATE public.visits v SET vehicle_id = s.old_vehicle_id FROM _tos_rbtrk s WHERE v.id = s.visit_id AND s.restore;
  GET DIAGNOSTICS n = row_count;
  SELECT count(*) INTO e FROM _tos_rbtrk WHERE restore;
  IF n <> e THEN RAISE EXCEPTION 'rollback trucks: restored % visits, expected %', n, e; END IF;
  UPDATE public.visit_time_on_site_corrections l SET truck_status = 'rolled_back' FROM _tos_rbtrk s WHERE l.id = s.lid AND s.restore;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE n int; e int; a0 bigint; ck jsonb; ck0 jsonb; t text;
BEGIN
  SELECT count(*) INTO n FROM _tos_rbtrk s JOIN public.visits v ON v.id = s.visit_id WHERE s.restore AND v.vehicle_id IS DISTINCT FROM s.old_vehicle_id;
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbtrucks: % visits do not carry the old truck', n; END IF;
  SELECT count(*) INTO e FROM _tos_rbtrk WHERE restore;
  CREATE TEMP TABLE _tos_wrbtrk ON COMMIT DROP AS SELECT visit_id FROM _tos_rbtrk WHERE restore;

  a0 := (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rbtrucks:audit_id0');
  -- (c) only the visits this file wrote changed, once each, and only in vehicle_id
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits';
  IF n <> e THEN RAISE EXCEPTION 'VERIFY rbtrucks: % audit rows on public.visits, expected %', n, e; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current() AND a.table_schema = 'public' AND a.table_name = 'visits'
     AND ((a.record_pk->>'id')::bigint NOT IN (SELECT visit_id FROM _tos_wrbtrk)
          OR (a.old_row - ARRAY['vehicle_id', 'updated_at']) IS DISTINCT FROM (a.new_row - ARRAY['vehicle_id', 'updated_at'])
          OR a.app_source IS DISTINCT FROM 'time-on-site-fix-rollback'
          OR coalesce(a.request_context->>'change_reason', '') = '');
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbtrucks: % visit writes outside the stage, outside vehicle_id, or unlabelled', n; END IF;
  SELECT count(*) INTO n FROM audit.logs a WHERE a.id > a0 AND a.txid = txid_current()
     AND (a.table_schema, a.table_name) NOT IN (('public', 'visits'), ('public', 'visit_time_on_site_corrections'));
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbtrucks: % audit rows on other tables', n; END IF;
  -- (d) the controls (a timed visit outside the ledger, a card row) are untouched, byte for byte
  IF (SELECT jsonb_object_agg(v.id, to_jsonb(v)) FROM public.visits v WHERE v.id IN (1468, 1259))
     IS DISTINCT FROM (SELECT j FROM _tos_ctx WHERE k = 'rbtrucks:controls') THEN RAISE EXCEPTION 'VERIFY rbtrucks: a control visit changed'; END IF;
  -- (e) nothing went to Jobber: no push request queued for these visits (the push trigger's WHEN list has no time column
  --     and no vehicle_id, so it does not fire; this proves it)
  SELECT count(*) INTO n FROM net.http_request_queue q
   WHERE q.id > (SELECT (j #>> '{}')::bigint FROM _tos_ctx WHERE k = 'rbtrucks:net_id0') AND q.url LIKE '%jobber-push%'
     AND (convert_from(q.body, 'UTF8')::jsonb->>'visit_id')::bigint IN (SELECT visit_id FROM _tos_wrbtrk);
  IF n > 0 THEN RAISE EXCEPTION 'VERIFY rbtrucks: % Jobber push requests queued', n; END IF;
  -- (f) T1 to T8: none newly failing, T7 and T8 zero
  ck0 := (SELECT j FROM _tos_ctx WHERE k = 'rbtrucks:checks0');
  ck := public.fn_time_on_site_checks();
  FOREACH t IN ARRAY ARRAY['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8'] LOOP
    IF coalesce((ck->>t)::int, 0) > coalesce((ck0->>t)::int, 0) AND t <> 'T3' THEN
      RAISE EXCEPTION 'VERIFY rbtrucks: % went from % to %: %', t, ck0->>t, ck->>t, ck->'T_detail'; END IF;
  END LOOP;
  IF (ck->>'T7')::int <> 0 OR (ck->>'T8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY rbtrucks: T7 % T8 %: %', ck->>'T7', ck->>'T8', ck->'T_detail'; END IF;
  INSERT INTO _tos_report VALUES ('rbtrucks', jsonb_build_object('restored', e, 'kept_because_moved', (SELECT jsonb_agg(visit_id) FROM _tos_rbtrk WHERE NOT restore), 'checks', ck - 'T_detail'));
END $v$;

COMMIT;
