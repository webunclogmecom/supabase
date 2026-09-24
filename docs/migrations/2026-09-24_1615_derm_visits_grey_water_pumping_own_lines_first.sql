-- ============================================================================
-- 2026-09-24 · derm.visits.grey_water_pumping: put back the "own lines first" rule
-- ============================================================================
-- WHAT HAPPENED
--   2026-09-24_1600_derm_visits_grey_water_pumping.sql was applied at ~16:03 ET, but in a MUTATED form,
--   by my own mutation-test harness, not by a --commit run. The harness removed the own-lines-first test
--   from the column (to prove the checks can see a wrong rule), and then cut the file at a COMMIT offset
--   computed BEFORE that edit shortened it. The cut therefore kept the migration's COMMIT: the mutated
--   view was committed, and the probe that followed ran outside the transaction (its two [TEST] 112-YA
--   visits rolled back with its RAISE; verified 0 remain). The harness now computes the cut after any edit
--   and refuses to run if a COMMIT or END would come before the probe.
--
-- WHAT WAS LIVE, AND WHY NOTHING WAS AFFECTED
--   The committed column read "any 03/10 service line on the visit, its job or its invoice", without the
--   precedence customer.work_orders uses (the visit's OWN coded service lines first, then its job's, then
--   its invoice's). That rule can only ADD visits to the correct set, and on 2026-09-24 both rules give the
--   same 27 of 1259 derm.visits rows (equal counts on a superset = the same set). No app read the column
--   yet: the DERM Tracker change that reads it ships after this file.
--   ⚠ The 1600 VERIFY passed on the mutated rule. Its V3 (the tie to customer.work_orders) and V4 cannot
--   tell the two rules apart on today's data, because no completed visit has a grey water line only on a
--   sibling's job or invoice. The rolled-back fixture in the probe (a 112-YA visit with its own 06 line on
--   a grey water invoice must read FALSE) is what distinguishes them, and it read TRUE on the mutant.
--
-- WHAT CHANGES
--   derm.visits: the grey_water_pumping expression is replaced by the intended one (same text as the
--   1600 file), spliced between " AS client_emails," and " AS grey_water_pumping", each counted to one.
--   Values do not change today (V1). Same checks as 1600, plus V2b: the stored rule carries the
--   min(tier) precedence.
--
-- 🛑 THE RULE EXISTS TWICE (customer.work_orders WHERE, derm.visits column). Change one, change both.
-- 🛑 Do not SET search_path in this file (see 1600).
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views are not audited.
-- ROLLBACK: as in 1600 (baseline docs/migrations/_baseline/2026-09-24_derm_visits.before.sql).
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _dv_before ON COMMIT DROP AS SELECT * FROM derm.visits;
CREATE TEMP TABLE _acl_before ON COMMIT DROP AS
  SELECT relacl::text AS acl, reloptions::text AS opts FROM pg_class WHERE oid = 'derm.visits'::regclass;

DO $mig$
DECLARE
  d text := pg_get_viewdef('derm.visits'::regclass);
  a1 text := ' AS client_emails,';
  a2 text := ' AS grey_water_pumping';
  p1 int; p2 int;
  gw text := $gw$
    (EXISTS ( SELECT 1
           FROM public.visits gv
          WHERE gv.id = w3.id AND EXISTS (
            WITH gw_lc AS (
              SELECT lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') AS code,
                     CASE WHEN li.visit_id = gv.id THEN 1 WHEN gv.job_id IS NOT NULL AND li.job_id = gv.job_id THEN 2 ELSE 3 END AS tier
                FROM public.line_items li
               WHERE li.name IS NOT NULL
                 AND (li.visit_id = gv.id OR (gv.job_id IS NOT NULL AND li.job_id = gv.job_id)
                      OR (gv.invoice_id IS NOT NULL AND li.invoice_id = gv.invoice_id))
            ), gw_svc AS (
              SELECT gw_lc.code, gw_lc.tier FROM gw_lc JOIN public.service_line_items s ON s.code = gw_lc.code
               WHERE s.reason NOT IN ('fee','other')
            )
            SELECT 1 FROM gw_svc
             WHERE gw_svc.tier = (SELECT min(tier) FROM gw_svc)
               AND gw_svc.code IN (SELECT code FROM public.service_line_items WHERE service_type = 'Pumping' AND location_target = 'Grey Water'))))$gw$;
BEGIN
  IF md5(d) <> 'd1f01e62aa1a2495ada2ec61aabf7ae4' THEN
    RAISE EXCEPTION 'derm.visits is not the mutated 1600 definition this file corrects; re-read it'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '8691c35a57b742d45deff6d2d50e892a' THEN
    RAISE EXCEPTION 'customer.work_orders changed; re-read its grey water arm'; END IF;
  IF length(d) - length(replace(d, a1, '')) <> length(a1) OR length(d) - length(replace(d, a2, '')) <> length(a2) THEN
    RAISE EXCEPTION 'derm.visits: an anchor is not unique'; END IF;
  p1 := position(a1 in d) + length(a1);
  p2 := position(a2 in d);
  IF p2 <= p1 THEN RAISE EXCEPTION 'derm.visits: anchors out of order'; END IF;
  IF (SELECT array_agg(code::text ORDER BY code) FROM public.service_line_items
       WHERE service_type = 'Pumping' AND location_target = 'Grey Water') IS DISTINCT FROM ARRAY['03','10'] THEN
    RAISE EXCEPTION 'grey water pumping catalogue is no longer exactly {03,10}; re-measure before shipping'; END IF;

  EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS ' || rtrim(left(d, p1 - 1) || gw || substr(d, p2), ';');
END
$mig$;

COMMENT ON COLUMN derm.visits.grey_water_pumping IS
  'TRUE when the visit is grey water pumping by the same rule as the customer.work_orders grey water arm (catalogue Pumping + Grey Water; own coded lines first, then job, then invoice; fee/other codes abstain). Such a visit stays in the client''s Field Portal when DERM not required, so the DERM Tracker bulk dialog does not count it as hidden (2026-09-24). Never NULL.';

DO $verify$
DECLARE
  n int; n_ctl int; n_ctl2 int; att int; d text := pg_get_viewdef('derm.visits'::regclass);
BEGIN
  -- V1 nothing moved, grey_water_pumping included (both rules give the same set today).
  SELECT count(*) INTO n FROM _dv_before b FULL JOIN derm.visits a ON a.id = b.id
   WHERE a.id IS NULL OR b.id IS NULL OR to_jsonb(a) IS DISTINCT FROM to_jsonb(b);
  IF n <> 0 THEN RAISE EXCEPTION 'V1: % derm.visits rows changed or moved', n; END IF;

  -- V2 last column, boolean, never NULL. V2b the precedence is in the stored rule, once, in this column.
  SELECT max(attnum) INTO att FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum > 0 AND NOT attisdropped;
  IF (SELECT attname FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum = att) <> 'grey_water_pumping'
     OR (SELECT atttypid FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum = att) <> 'boolean'::regtype THEN
    RAISE EXCEPTION 'V2: grey_water_pumping is not the last boolean column'; END IF;
  IF EXISTS (SELECT 1 FROM derm.visits WHERE grey_water_pumping IS NULL) THEN RAISE EXCEPTION 'V2: NULL grey_water_pumping'; END IF;
  IF length(d) - length(replace(d, 'min(gw_svc_1.tier)', '')) <> length('min(gw_svc_1.tier)') THEN
    RAISE EXCEPTION 'V2b: the own-lines-first precedence is not in the stored rule exactly once'; END IF;

  -- V3 the tie to the Field Portal (see 1600).
  SELECT count(*),
         count(*) FILTER (WHERE a.grey_water_pumping),
         count(*) FILTER (WHERE (EXISTS (SELECT 1 FROM customer.work_orders wo WHERE wo.id = v.public_id))
                                IS DISTINCT FROM a.grey_water_pumping)
    INTO n_ctl, n_ctl2, n
    FROM derm.visits a JOIN public.visits v ON v.id = a.id
   WHERE v.derm_required IS FALSE AND v.client_id IS NOT NULL AND v.deleted_at IS NULL;
  IF n_ctl < 100 OR n_ctl2 < 3 THEN RAISE EXCEPTION 'V3 control: only % stored-FALSE rows, % of them grey water', n_ctl, n_ctl2; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: grey_water_pumping disagrees with customer.work_orders on % of % stored-FALSE rows', n, n_ctl; END IF;

  -- V5 named controls (see 1600).
  IF (SELECT count(*) FROM derm.visits WHERE id IN (6507, 7085, 5159, 6508) AND grey_water_pumping) <> 4 THEN
    RAISE EXCEPTION 'V5: a grey water control (6507, 7085, 5159, 6508) is not grey_water_pumping'; END IF;
  IF (SELECT count(*) FROM derm.visits WHERE id IN (7849, 8117, 7323) AND NOT grey_water_pumping) <> 3 THEN
    RAISE EXCEPTION 'V5: control 7849, 8117 or 7323 is missing or reads grey_water_pumping'; END IF;

  -- V6 ACL and reloptions unchanged; anon has nothing, authenticated reads the column.
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.visits'::regclass) IS DISTINCT FROM (SELECT acl FROM _acl_before)
     OR (SELECT reloptions::text FROM pg_class WHERE oid = 'derm.visits'::regclass) IS DISTINCT FROM (SELECT opts FROM _acl_before) THEN
    RAISE EXCEPTION 'V6: ACL or reloptions changed'; END IF;
  IF has_table_privilege('anon', 'derm.visits', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'derm.visits', 'grey_water_pumping', 'SELECT') THEN
    RAISE EXCEPTION 'V6: grants are not as expected'; END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
