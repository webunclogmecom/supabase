-- ============================================================================
-- 2026-09-24 · derm.visits.grey_water_pumping: the DERM Tracker bulk dialog stops overcounting
-- ============================================================================
-- 🛑 THIS FILE WAS NEVER APPLIED AS WRITTEN. My mutation-test harness applied it at ~16:03 ET with the
--   own-lines-first test removed (its cut point was computed before the mutation shortened the file, so the
--   COMMIT ran). 2026-09-24_1615_derm_visits_grey_water_pumping_own_lines_first.sql put the rule below back.
--   The VERIFY blocks here passed on the mutated rule: on today's data V3/V4 cannot tell the two apart
--   (see 1615). Read 1615 for the live definition's history; this file stays as the intended design.
-- ============================================================================
-- THE ASK
--   Since 2026-09-24_1353 a grey water pumping visit stays in the client's Field Portal when it is DERM
--   not required. The DERM Tracker's bulk "Mark DERM Not Required" dialog ("Hide these visits from the
--   client portal?", 2026-08-05) still counts every selected visit whose derm_required is not false as a
--   service record it will hide, so it overstates whenever grey water visits are selected. Fred: "Fix
--   this one".
--
-- WHAT CHANGES (one view; no function, no grant, no data write)
--   derm.visits gains a LAST column grey_water_pumping (boolean, never NULL): TRUE when the visit is grey
--   water pumping by EXACTLY the rule customer.work_orders uses for its grey water arm
--   (2026-09-24_1353): catalogue service_type 'Pumping' + location_target 'Grey Water' (03 and 10 today),
--   decided by the visit's OWN coded service lines first, then its job's, then its invoice's, with the
--   fee/admin codes (reason 'fee'/'other') abstaining. The DERM Tracker list reads it and the dialog
--   counts a visit as hidden only when derm_required !== false AND grey_water_pumping !== true
--   (Lovable bd120ad4, same day).
--   Inline in the view, like the work_orders arm: the view runs with its owner's rights and already reads
--   both tables. CTE names are prefixed gw_ because derm.visits already has a LATERAL alias "lc".
--
-- 🛑 THE RULE NOW EXISTS TWICE (customer.work_orders WHERE, derm.visits column). Change one, change both.
--   V3 below is the tie: over every portal-eligible derm.visits row stored FALSE, "is in
--   customer.work_orders" must equal grey_water_pumping. It fails the moment the two rules disagree.
--
-- 🛑 Spliced from the live pg_get_viewdef text inside this transaction (md5 pinned, the anchor counted to
-- exactly one), never retyped. Do not SET search_path in this file: pg_get_viewdef leaves names unqualified
-- that are visible on the current path, and the EXECUTE must resolve them the same way.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views are not audited.
-- ROLLBACK: CREATE OR REPLACE cannot drop a column, so DROP VIEW derm.visits (no dependents today) and
-- CREATE it from docs/migrations/_baseline/2026-09-24_derm_visits.before.sql, then restore the ACL
-- {postgres=arwdDxtm, authenticated=r, service_role=arwdDxtm}. The DERM Tracker list must stop selecting
-- grey_water_pumping first, or the list query fails.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _dv_before ON COMMIT DROP AS SELECT * FROM derm.visits;
CREATE TEMP TABLE _acl_before ON COMMIT DROP AS
  SELECT relacl::text AS acl, reloptions::text AS opts FROM pg_class WHERE oid = 'derm.visits'::regclass;

DO $mig$
DECLARE
  d text := pg_get_viewdef('derm.visits'::regclass);
  a_cols text := ' AS client_emails' || chr(10) || '   FROM ';
  new_cols text := $gw$ AS client_emails,
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
               AND gw_svc.code IN (SELECT code FROM public.service_line_items WHERE service_type = 'Pumping' AND location_target = 'Grey Water')))) AS grey_water_pumping
   FROM $gw$;
BEGIN
  IF md5(d) <> '39268bc36c7b38adff2b803d6eea85ef' THEN
    RAISE EXCEPTION 'derm.visits changed since this migration was built; rebuild it'; END IF;
  -- The rule this column mirrors must still be the one shipped in 2026-09-24_1353.
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '8691c35a57b742d45deff6d2d50e892a' THEN
    RAISE EXCEPTION 'customer.work_orders changed since this migration was built; re-read its grey water arm'; END IF;
  IF length(d) - length(replace(d, a_cols, '')) <> length(a_cols) THEN
    RAISE EXCEPTION 'derm.visits: column anchor is not unique'; END IF;
  IF (SELECT array_agg(code::text ORDER BY code) FROM public.service_line_items
       WHERE service_type = 'Pumping' AND location_target = 'Grey Water') IS DISTINCT FROM ARRAY['03','10'] THEN
    RAISE EXCEPTION 'grey water pumping catalogue is no longer exactly {03,10}; re-measure before shipping'; END IF;

  EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS ' || rtrim(replace(d, a_cols, new_cols), ';');
END
$mig$;

COMMENT ON COLUMN derm.visits.grey_water_pumping IS
  'TRUE when the visit is grey water pumping by the same rule as the customer.work_orders grey water arm (catalogue Pumping + Grey Water; own coded lines first, then job, then invoice; fee/other codes abstain). Such a visit stays in the client''s Field Portal when DERM not required, so the DERM Tracker bulk dialog does not count it as hidden (2026-09-24). Never NULL.';

DO $verify$
DECLARE
  n int; n_ctl int; n_ctl2 int; att int;
BEGIN
  -- V1 nothing else moved: same rows, every pre-existing column identical.
  SELECT count(*) INTO n FROM _dv_before b FULL JOIN derm.visits a ON a.id = b.id
   WHERE a.id IS NULL OR b.id IS NULL OR (to_jsonb(a) - 'grey_water_pumping') IS DISTINCT FROM to_jsonb(b);
  IF n <> 0 THEN RAISE EXCEPTION 'V1: % derm.visits rows changed or moved', n; END IF;

  -- V2 the new column is the LAST column, boolean, never NULL.
  SELECT max(attnum) INTO att FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum > 0 AND NOT attisdropped;
  IF (SELECT attname FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum = att) <> 'grey_water_pumping'
     OR (SELECT atttypid FROM pg_attribute WHERE attrelid = 'derm.visits'::regclass AND attnum = att) <> 'boolean'::regtype THEN
    RAISE EXCEPTION 'V2: grey_water_pumping is not the last boolean column'; END IF;
  IF EXISTS (SELECT 1 FROM derm.visits WHERE grey_water_pumping IS NULL) THEN RAISE EXCEPTION 'V2: NULL grey_water_pumping'; END IF;

  -- V3 THE TIE TO THE FIELD PORTAL. For a derm.visits row stored FALSE (client set, not deleted), being in
  -- customer.work_orders must equal grey_water_pumping. This is the dialog's own question, answered by the
  -- live portal view: "if this visit is not required, does the client still see it?"
  SELECT count(*),
         count(*) FILTER (WHERE a.grey_water_pumping),
         count(*) FILTER (WHERE (EXISTS (SELECT 1 FROM customer.work_orders wo WHERE wo.id = v.public_id))
                                IS DISTINCT FROM a.grey_water_pumping)
    INTO n_ctl, n_ctl2, n
    FROM derm.visits a JOIN public.visits v ON v.id = a.id
   WHERE v.derm_required IS FALSE AND v.client_id IS NOT NULL AND v.deleted_at IS NULL;
  IF n_ctl < 100 OR n_ctl2 < 3 THEN RAISE EXCEPTION 'V3 control: only % stored-FALSE rows, % of them grey water', n_ctl, n_ctl2; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: grey_water_pumping disagrees with customer.work_orders on % of % stored-FALSE rows', n, n_ctl; END IF;

  -- V4 rows stored TRUE or NULL are in the portal whatever the column says, so V3 cannot see them. Check
  -- them against grey water evidence of their own, independent of the arm: TRUE requires a 03/10 line on
  -- the visit, or (no coded own service line) a 03/10 line on its job or invoice; and every visit with a
  -- 03/10 own line and no other coded own service line must be TRUE.
  SELECT count(*) INTO n FROM derm.visits a JOIN public.visits v ON v.id = a.id
   WHERE a.grey_water_pumping
     AND NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = v.id AND li.name IS NOT NULL
                       AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10'))
     AND NOT (NOT EXISTS (SELECT 1 FROM public.line_items li JOIN public.service_line_items s
                            ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
                           WHERE li.visit_id = v.id AND s.reason NOT IN ('fee','other'))
              AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
                            AND ((v.job_id IS NOT NULL AND li.job_id = v.job_id) OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
                            AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10')));
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % rows are grey_water_pumping with no grey water line of their own or inherited', n; END IF;
  SELECT count(*), count(*) FILTER (WHERE NOT a.grey_water_pumping) INTO n_ctl, n
    FROM derm.visits a
   WHERE EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = a.id AND li.name IS NOT NULL
                   AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10'))
     AND NOT EXISTS (SELECT 1 FROM public.line_items li JOIN public.service_line_items s
                       ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
                      WHERE li.visit_id = a.id AND s.reason NOT IN ('fee','other')
                        AND s.code NOT IN ('03','10'));
  IF n_ctl < 20 THEN RAISE EXCEPTION 'V4 control: only % visits with an own 03/10 line and no other service', n_ctl; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % visits whose only coded service is 03/10 read grey_water_pumping = false', n; END IF;

  -- V5 named controls: grey water stored FALSE (6507 coded, 7085 coded 10, 5159 free text on its own line so
  -- decided by its job/invoice), grey water stored TRUE and filed (6508); grease trap 7849 and Labor 8117 false.
  IF (SELECT count(*) FROM derm.visits WHERE id IN (6507, 7085, 5159, 6508) AND grey_water_pumping) <> 4 THEN
    RAISE EXCEPTION 'V5: a grey water control (6507, 7085, 5159, 6508) is not grey_water_pumping'; END IF;
  IF (SELECT count(*) FROM derm.visits WHERE id IN (7849, 8117) AND NOT grey_water_pumping) <> 2 THEN
    RAISE EXCEPTION 'V5: control 7849 or 8117 is missing or reads grey_water_pumping'; END IF;

  -- V6 ACL and reloptions unchanged; anon still has nothing, authenticated can read the new column.
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.visits'::regclass) IS DISTINCT FROM (SELECT acl FROM _acl_before)
     OR (SELECT reloptions::text FROM pg_class WHERE oid = 'derm.visits'::regclass) IS DISTINCT FROM (SELECT opts FROM _acl_before) THEN
    RAISE EXCEPTION 'V6: ACL or reloptions changed'; END IF;
  IF has_table_privilege('anon', 'derm.visits', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'derm.visits', 'grey_water_pumping', 'SELECT') THEN
    RAISE EXCEPTION 'V6: grants are not as expected'; END IF;

  RAISE NOTICE 'OK: derm.visits % rows; grey_water_pumping TRUE on %, of which stored FALSE %',
    (SELECT count(*) FROM derm.visits), (SELECT count(*) FROM derm.visits WHERE grey_water_pumping), n_ctl2;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
