-- ============================================================================
-- 2026-09-24 · Grey water pumping stays visible to the client in the Field Portal
-- ============================================================================
-- THE ASK
--   2026-09-24_1220 made grey water pumping (line items 03, 10) not DERM required. customer.work_orders
--   hides a not-required visit (Fred, 2026-08-05: "we only show derms required jobs to the work
--   orders"), so grey-water-only clients (214-MYK, 084-ULT) would have lost every new work order,
--   Service Report and photo from 2026-09-25 on. Asked the same day, Fred answered "No, keep showing
--   them", then "All three" for the grey water visits a person had switched off (6507, 5159, 7085), and
--   "Keep it" for the PERMIT & FREQUENCY block on grey water reports.
--
-- WHAT CHANGES (views only; no function, no grant, no data write)
--   1. customer.work_orders: the WHERE becomes
--        COALESCE(v.derm_required, true) = true  OR  <the visit is grey water pumping>
--      "Grey water pumping" is read from the catalogue (service_type 'Pumping' + location_target
--      'Grey Water', codes 03 and 10 today, asserted) and decided by the visit's OWN coded service lines
--      first, then its job's, then its invoice's (fee/admin codes 25/26/27 abstain). Own lines first,
--      because 66 invoices cover more than one visit: with an any-path test, a grease trap sibling on an
--      invoice that also bills a 10 line would be admitted with its DERM parts suppressed (invoice 2299:
--      7323, a 09 grease trap pump switched off, next to 7085's 10). Inline, because the view runs with
--      its owner's rights and already reads both tables: no new function, RPC or grant.
--      New LAST column derm_required = COALESCE(v.derm_required, true), never NULL: TRUE on every row the
--      old filter admitted, FALSE only on a grey water row admitted by the new arm. The Field Portal hides
--      its DERM-paperwork pieces on derm_required === false AND no manifest number (Lovable 8f5974df,
--      shipped before this file, inert until the column exists).
--   2. customer.work_orders_all (staff twin, 2026-09-24_1150): the same last column, WHERE unchanged,
--      so the twin keeps the original's row shape (asked for by @Supabase in WORKING-NOW).
--   3. public.v_visit_report_manifest: new LAST column report_available = a customer work order exists
--      (the one honest "the client has a Service Report" signal for staff apps).
--
-- WHAT APPEARS: the completed grey water visits stored FALSE: 5159 (253-CG), 6507 (214-MYK),
-- 7085 (239-COM) today, computed at apply time (V2). 0 not-required non-grey-water visits appear (V4).
-- ⚠ visit_num moves on 2 already-visible rows (a new row sorts before them); nothing prints visit_num.
-- ⚠ Visit tokens (public_id) are never written in this file: the repo is public and a token is the only
--   thing guarding a client's work order. V6 resolves them from the visit id at run time.
--
-- 🛑 Spliced from the live pg_get_viewdef text inside this transaction (md5 pinned, each anchor counted
-- to exactly one), never retyped. CREATE OR REPLACE VIEW keeps the ACL but replaces reloptions; all three
-- views have none, and V9 asserts both unchanged. Do not SET search_path in this file: pg_get_viewdef
-- leaves names unqualified that are visible on the current path, and the EXECUTE must resolve them the
-- same way.
--
-- NOT CHANGED, on purpose: Admin Review (Send / Open report still key on visits.derm_required; grey
-- water has no city report to send), send-visit-photos-email (gate 0 already refuses: no grey water
-- property has a City email), send-derm-email and derm-visit-report (latent only). The DERM Tracker bulk
-- "Hide these visits from the client portal?" dialog now overstates for grey water: follow-up.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views are not audited.
-- ROLLBACK: re-create the three views from docs/migrations/_baseline/2026-09-24_customer_work_orders.before.sql
-- (the pre-change definitions; the added columns go away with them).
-- ============================================================================

BEGIN;

-- Snapshots for the VERIFY block (taken before any change).
CREATE TEMP TABLE _wo_before  ON COMMIT DROP AS SELECT * FROM customer.work_orders;
CREATE TEMP TABLE _vrm_before ON COMMIT DROP AS SELECT * FROM public.v_visit_report_manifest;
CREATE TEMP TABLE _acl_before ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts
    FROM pg_class
   WHERE oid IN ('customer.work_orders'::regclass, 'customer.work_orders_all'::regclass,
                 'public.v_visit_report_manifest'::regclass);
-- Completed, live, client grey water pumping visits, by the SAME rule as the new arm (used by V2/V3).
CREATE TEMP TABLE _gw ON COMMIT DROP AS
  SELECT v.id, v.public_id, v.derm_required
    FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL AND v.deleted_at IS NULL
     AND EXISTS (
       WITH lc AS (
         SELECT lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') AS code,
                CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier
           FROM public.line_items li
          WHERE li.name IS NOT NULL
            AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
                 OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
       ), svc AS (
         SELECT lc.code, lc.tier FROM lc JOIN public.service_line_items s ON s.code = lc.code
          WHERE s.reason NOT IN ('fee','other')
       )
       SELECT 1 FROM svc
        WHERE svc.tier = (SELECT min(tier) FROM svc)
          AND svc.code IN (SELECT code FROM public.service_line_items WHERE service_type = 'Pumping' AND location_target = 'Grey Water'));

DO $mig$
DECLARE
  d_wo  text := pg_get_viewdef('customer.work_orders'::regclass);
  d_woa text := pg_get_viewdef('customer.work_orders_all'::regclass);
  d_vrm text := pg_get_viewdef('public.v_visit_report_manifest'::regclass);
  a_filter text := '(COALESCE(v.derm_required, true) = true)';
  a_cols   text := ' AS service_type' || chr(10) || '   FROM ';
  a_vrm    text := ' AS report_has_manifest' || chr(10) || '   FROM ';
  gw_filter text := $gw$((COALESCE(v.derm_required, true) = true) OR EXISTS (
       WITH lc AS (
         SELECT lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') AS code,
                CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier
           FROM public.line_items li
          WHERE li.name IS NOT NULL
            AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
                 OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
       ), svc AS (
         SELECT lc.code, lc.tier FROM lc JOIN public.service_line_items s ON s.code = lc.code
          WHERE s.reason NOT IN ('fee','other')
       )
       SELECT 1 FROM svc
        WHERE svc.tier = (SELECT min(tier) FROM svc)
          AND svc.code IN (SELECT code FROM public.service_line_items WHERE service_type = 'Pumping' AND location_target = 'Grey Water')))$gw$;
  wo_cols  text := ' AS service_type,' || chr(10) || '    COALESCE(v.derm_required, true) AS derm_required' || chr(10) || '   FROM ';
  vrm_cols text := ' AS report_has_manifest,' || chr(10) || '    (wo.id IS NOT NULL) AS report_available' || chr(10) || '   FROM ';
BEGIN
  IF md5(d_wo)  <> '5dc2f07cadc35bbbfe7e3a32a48c6d39' THEN RAISE EXCEPTION 'customer.work_orders changed since this migration was built; rebuild it'; END IF;
  IF md5(d_woa) <> 'd2de18b85f6b3cbc4a1dbdf397d607b5' THEN RAISE EXCEPTION 'customer.work_orders_all changed since this migration was built; rebuild it'; END IF;
  IF md5(d_vrm) <> '5b081bdf33e22d4a3343aac2e4c2a797' THEN RAISE EXCEPTION 'public.v_visit_report_manifest changed since this migration was built; rebuild it'; END IF;
  -- Each anchor occurs exactly once (replace() would hit every occurrence).
  IF length(d_wo)  - length(replace(d_wo,  a_filter, '')) <> length(a_filter) THEN RAISE EXCEPTION 'work_orders: filter anchor is not unique'; END IF;
  IF length(d_wo)  - length(replace(d_wo,  a_cols,   '')) <> length(a_cols)   THEN RAISE EXCEPTION 'work_orders: column anchor is not unique'; END IF;
  IF length(d_woa) - length(replace(d_woa, a_cols,   '')) <> length(a_cols)   THEN RAISE EXCEPTION 'work_orders_all: column anchor is not unique'; END IF;
  IF position(a_filter in d_woa) > 0 THEN RAISE EXCEPTION 'work_orders_all carries the DERM filter; it must not'; END IF;
  IF length(d_vrm) - length(replace(d_vrm, a_vrm,    '')) <> length(a_vrm)    THEN RAISE EXCEPTION 'v_visit_report_manifest: anchor is not unique'; END IF;
  IF (SELECT array_agg(code::text ORDER BY code) FROM public.service_line_items
       WHERE service_type = 'Pumping' AND location_target = 'Grey Water') IS DISTINCT FROM ARRAY['03','10'] THEN
    RAISE EXCEPTION 'grey water pumping catalogue is no longer exactly {03,10}; re-measure before shipping';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW customer.work_orders AS '
       || rtrim(replace(replace(d_wo, a_filter, gw_filter), a_cols, wo_cols), ';');
  EXECUTE 'CREATE OR REPLACE VIEW customer.work_orders_all AS '
       || rtrim(replace(d_woa, a_cols, wo_cols), ';');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_visit_report_manifest AS '
       || rtrim(replace(d_vrm, a_vrm, vrm_cols), ';');
END
$mig$;

COMMENT ON COLUMN customer.work_orders.derm_required IS
  'COALESCE(visits.derm_required, true), never NULL. FALSE only on a grey water pumping visit (catalogue Pumping + Grey Water, decided by the visit''s own coded lines first), the one not-required kind the client still sees (Fred, 2026-09-24). Apps hide the DERM paperwork parts on === false with no manifest number, never on !== true.';
COMMENT ON COLUMN customer.work_orders_all.derm_required IS
  'Same expression as customer.work_orders.derm_required. In this staff twin it is FALSE on every not-required visit.';
COMMENT ON COLUMN public.v_visit_report_manifest.report_available IS
  'TRUE when the Field Portal publishes a Service Report for this visit (a customer.work_orders row exists). Grey water pumping is not DERM required but keeps its report (2026-09-24).';

CREATE TEMP TABLE _wo_after ON COMMIT DROP AS SELECT * FROM customer.work_orders;

DO $verify$
DECLARE
  n_before int := (SELECT count(*) FROM _wo_before);
  n_after  int := (SELECT count(*) FROM _wo_after);
  n int; n_ctl int; j jsonb; added text; shifts text;
  t6507 text := (SELECT public_id FROM public.visits WHERE id = 6507);
  t7849 text := (SELECT public_id FROM public.visits WHERE id = 7849);
  t8117 text := (SELECT public_id FROM public.visits WHERE id = 8117);
BEGIN
  IF t6507 IS NULL OR t7849 IS NULL OR t8117 IS NULL THEN RAISE EXCEPTION 'control visits 6507 / 7849 / 8117 not found'; END IF;

  -- V1 nothing leaves.
  SELECT count(*) INTO n FROM _wo_before b WHERE NOT EXISTS (SELECT 1 FROM _wo_after w WHERE w.id = b.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V1: % work orders disappeared', n; END IF;

  -- V2 the exact set that appears = the completed grey water visits stored FALSE, both directions.
  SELECT count(*) INTO n FROM (
    (SELECT id FROM _wo_after EXCEPT SELECT id FROM _wo_before)
    EXCEPT SELECT public_id FROM _gw WHERE derm_required IS FALSE) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % visits appeared that are not stored-FALSE grey water pumping', n; END IF;
  SELECT count(*) INTO n FROM (
    SELECT public_id FROM _gw WHERE derm_required IS FALSE
    EXCEPT (SELECT id FROM _wo_after EXCEPT SELECT id FROM _wo_before)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % stored-FALSE grey water visits did not appear', n; END IF;

  -- V3 FAILS ON THE OLD VIEW (3 missing today): every completed grey water visit has a work order.
  SELECT count(*), count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM _wo_after w WHERE w.id = g.public_id))
    INTO n_ctl, n FROM _gw g;
  IF n_ctl = 0 THEN RAISE EXCEPTION 'V3 control: no completed grey water visit to test'; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % of % completed grey water visits have no client work order', n, n_ctl; END IF;

  -- V4 independent of the arm: every ADDED visit carries grey water evidence on its OWN lines (a 03/10
  -- code, or free text "grey/gray water"), or has no coded own service line and a 03/10 line on its job or
  -- invoice. And the 2026-08-05 rule still holds for the rest (control: such hidden visits exist).
  SELECT count(*) INTO n
    FROM (SELECT id FROM _wo_after EXCEPT SELECT id FROM _wo_before) a
    JOIN public.visits v ON v.public_id = a.id
   WHERE NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = v.id AND li.name IS NOT NULL
                       AND (lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10')
                            OR li.name ~* 'gr[ae]y[[:space:]]*water'))
     AND NOT (NOT EXISTS (SELECT 1 FROM public.line_items li JOIN public.service_line_items s
                            ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
                           WHERE li.visit_id = v.id AND s.reason NOT IN ('fee','other'))
              AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
                            AND ((v.job_id IS NOT NULL AND li.job_id = v.job_id) OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
                            AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10')));
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % added visits carry no grey water evidence of their own', n; END IF;
  SELECT count(*) INTO n_ctl
    FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL AND v.deleted_at IS NULL AND v.derm_required IS FALSE
     AND NOT EXISTS (SELECT 1 FROM _wo_after w WHERE w.id = v.public_id);
  IF n_ctl < 100 THEN RAISE EXCEPTION 'V4 control: only % not-required visits remain hidden', n_ctl; END IF;

  -- V5 on pre-existing rows nothing moves except visit_num, and derm_required is TRUE; FALSE on added rows.
  SELECT count(*) INTO n FROM _wo_before b JOIN _wo_after w ON w.id = b.id
   WHERE (to_jsonb(w) - 'visit_num' - 'derm_required') IS DISTINCT FROM (to_jsonb(b) - 'visit_num')
      OR w.derm_required IS NOT TRUE;
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % pre-existing work orders changed', n; END IF;
  SELECT count(*) INTO n FROM _wo_after w
   WHERE NOT EXISTS (SELECT 1 FROM _wo_before b WHERE b.id = w.id) AND w.derm_required IS NOT FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % added rows do not carry derm_required = false', n; END IF;
  SELECT string_agg(format('%s %s->%s', v.id, b.visit_num, w.visit_num), ', ' ORDER BY v.id) INTO shifts
    FROM _wo_before b JOIN _wo_after w ON w.id = b.id JOIN public.visits v ON v.public_id = b.id
   WHERE b.visit_num IS DISTINCT FROM w.visit_num;

  -- V6 the path the client actually uses (DEFINER RPCs), tokens resolved from visit ids.
  j := customer.get_work_order(t6507);                             -- 6507, 214-MYK, grey water
  IF j IS NULL OR j->'work_order'->>'derm_required' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'V6: 6507 has no client work order, or derm_required is not false'; END IF;
  IF customer.get_work_order(t7849)->'work_order'->>'derm_required' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'V6: 7849 (DERM visit) does not read derm_required = true'; END IF;
  IF customer.get_work_order(t8117) IS NOT NULL THEN               -- 8117, 235-LOU, Labor, not required
    RAISE EXCEPTION 'V6: 8117 (not required, not grey water) became visible'; END IF;
  IF (SELECT count(*) FROM customer.get_visit_by_slug_and_token('214-myk', t6507)) <> 1 THEN
    RAISE EXCEPTION 'V6: get_visit_by_slug_and_token does not return 6507 on the new row type'; END IF;
  IF NOT (customer.get_client_portal('214-myk')->'work_orders' @> jsonb_build_array(jsonb_build_object('id', t6507))) THEN
    RAISE EXCEPTION 'V6: 6507 is missing from the 214-MYK portal'; END IF;

  -- V7 the twin keeps the original's shape and values (beyond visit_num) and keeps its extra rows.
  SELECT count(*) INTO n FROM _wo_after w LEFT JOIN customer.work_orders_all t ON t.id = w.id
   WHERE t.id IS NULL OR (to_jsonb(w) - 'visit_num') IS DISTINCT FROM (to_jsonb(t) - 'visit_num');
  IF n <> 0 THEN RAISE EXCEPTION 'V7: twin differs from work_orders (beyond visit_num) on % rows', n; END IF;
  IF (SELECT count(*) FROM customer.work_orders_all) <= n_after THEN RAISE EXCEPTION 'V7: twin lost its non-DERM rows'; END IF;
  IF customer.get_work_order_internal(t8117)->'work_order'->>'derm_required' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'V7: twin 8117 does not read derm_required = false'; END IF;

  -- V8 report_available = a work order exists; report_has_manifest untouched.
  SELECT count(*) INTO n FROM _vrm_before b FULL JOIN public.v_visit_report_manifest r ON r.visit_id = b.visit_id
   WHERE r.visit_id IS NULL OR b.visit_id IS NULL
      OR r.report_has_manifest IS DISTINCT FROM b.report_has_manifest OR r.public_id IS DISTINCT FROM b.public_id;
  IF n <> 0 THEN RAISE EXCEPTION 'V8: v_visit_report_manifest changed on % visits', n; END IF;
  IF (SELECT count(*) FROM public.v_visit_report_manifest WHERE report_available) <> n_after THEN
    RAISE EXCEPTION 'V8: report_available count differs from the work orders count'; END IF;
  IF (SELECT report_available FROM public.v_visit_report_manifest WHERE visit_id = 6507) IS NOT TRUE
     OR (SELECT report_available FROM public.v_visit_report_manifest WHERE visit_id = 8117) IS NOT FALSE THEN
    RAISE EXCEPTION 'V8: report_available is wrong on 6507 or 8117'; END IF;

  -- V9 ACL and reloptions byte-identical; the grant shape as expected.
  SELECT count(*) INTO n FROM _acl_before a JOIN pg_class c ON c.oid = a.reloid
   WHERE c.relacl::text IS DISTINCT FROM a.acl OR c.reloptions::text IS DISTINCT FROM a.opts;
  IF n <> 0 OR (SELECT count(*) FROM _acl_before) <> 3 THEN RAISE EXCEPTION 'V9: ACL or reloptions changed'; END IF;
  IF has_table_privilege('anon', 'customer.work_orders', 'SELECT')
     OR has_table_privilege('anon', 'customer.work_orders_all', 'SELECT')
     OR has_table_privilege('authenticated', 'customer.work_orders_all', 'SELECT')
     OR has_table_privilege('anon', 'public.v_visit_report_manifest', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'customer.work_orders', 'SELECT')
     OR NOT has_table_privilege('service_role', 'customer.work_orders', 'SELECT')
     OR NOT has_table_privilege('service_role', 'customer.work_orders_all', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.v_visit_report_manifest', 'SELECT') THEN
    RAISE EXCEPTION 'V9: view grants are not as expected'; END IF;

  SELECT string_agg(format('%s %s %s', v.id, c.client_code, v.visit_date), ', ' ORDER BY v.visit_date) INTO added
    FROM _wo_after w JOIN public.visits v ON v.public_id = w.id JOIN public.clients c ON c.id = v.client_id
   WHERE NOT EXISTS (SELECT 1 FROM _wo_before b WHERE b.id = w.id);
  RAISE NOTICE 'OK: work orders % -> %; added: %; visit_num shifts: %', n_before, n_after, added, coalesce(shifts, 'none');
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
