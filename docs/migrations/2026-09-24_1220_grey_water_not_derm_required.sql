-- ============================================================================
-- 2026-09-24 · Grey water pumping (line items 03 and 10) is no longer DERM required
-- ============================================================================
-- THE ASK
--   Slack C0BD3VDPB9S, 2026-09-24, Diego: "we need that all grey water services say DERM they're not
--   required". Fred: "Noted, so we don't need the DERM anymore for Grey Water." Fred to this session:
--   "make it so when a visit only holds a Line Item 03 which is for Grey Water to not be DERM
--   Required", and then "go ahead, leave the filed ones alone".
--   Diego's example: 214-MYK, visit 6508 (9/18), "03 - Service Agreement - Pumping - Grey Water" +
--   "25 - Credit card fee (3.53%)", flagged in DERM Tracker as needing a manifest.
--
-- WHAT CHANGES (three parts, one transaction)
--   1. public.service_line_items: requires_derm = false for code 03 (Service Agreement - Pumping - Grey
--      Water) and code 10 (Service Call - Pumping - Grey Water). Diego said "all grey water services";
--      10 is the same physical service billed as a Service Call. The catalogue column is the single
--      source: fn_line_item_requires_derm, the Calendar's DERM badge (ops.service_line_items) and
--      ops.v_visit_requests all read it.
--   2. public.fn_visit_requires_derm: ONE predicate spliced into the live body (md5 6aed5867...): lines
--      whose taxonomy code has catalogue reason fee/other (25, 26, 27) are left out of the fold.
--      WHY: part 1 alone does nothing useful. 53 of the 56 live visits that reach a 03 line also reach
--      "25 - Credit card fee"; a fee line answers NULL (deliberately, since 2026-08-06), and the old fold
--      turned any NULL line into a NULL verdict, so 03 (false) + 25 (NULL) = NULL = "still needs a
--      manifest". The Calendar and SA writers already fold with bool_or and have ignored the abstaining
--      fee line since 2026-08-13 (2026-08-13_0415, probes E and F); this function was never brought in
--      line, so the two writer families already disagreed on 101 visits (stored FALSE by the writers,
--      deriving NULL here only because of a fee line). This makes the function match its writers and
--      its own documentation.
--      Kept: a visit reaching ONLY fee/admin lines has v_cnt = 0 and still derives NULL (the
--      2026-08-06 guard). An unrecognised free-text line still blocks (NULL). The wider "ignore every
--      NULL" fold was rejected: it moves 39 more visits NULL -> FALSE, 18 of them completed and not
--      stored FALSE, which the nightly fill would take out of the clients' Field Portal.
--   3. Backfill, PENDING visits only (visit_status = 'scheduled' AND visit_date >= today in ET), stored
--      TRUE, NOT locked, now deriving FALSE: 32 at the time of writing (214-MYK 26, 2026-09-25 to
--      2027-03-19; 084-ULT 6, 2026-10-05 to 2027-03-04). None has a manifest, a county filing or an email.
--      The automated writers never demote a TRUE (set_visit_derm_required writes only where the stored
--      value IS NOT TRUE; the nightly rederive fills NULL only), so without this they would stay TRUE.
--      New visits need nothing: the SA generator and the Calendar RPCs write bool_or(...) = false.
--
-- WHAT IS LEFT ALONE, ON PURPOSE (Fred: "leave the filed ones alone")
--   * 23 completed grey water visits stored TRUE, every one with a live manifest (214-MYK 18, 084-ULT 3,
--     209-TRUE 1, 212-TRUE 1). They stay TRUE and stay in the clients' Field Portal. After this change
--     19 of them DERIVE FALSE while stored TRUE (no writer demotes, so nothing moves), and 4 (4855, 5028,
--     5043, 5061) still derive TRUE because they also reach a free-text "Grey Water Pumping" line.
--     ⚠ They are protected against the AUTOMATED writers only: public.edit_calendar_visit recomputes
--     derm_required on a line edit even on a completed visit, so a Calendar line edit on one of them
--     would demote it (0 such edits in the last 90 days).
--   * 6507 (214-MYK), locked FALSE by a person on 2026-09-17: already matches the new rule.
--   * 8165 (320-MGF, completed 9/21, 10 + 25, manifest 1979): stays TRUE, derives FALSE.
--   * 8185 (338-PRT, code 10 only, no manifest) is 'scheduled' but dated 2026-09-22, so it is NOT pending
--     under the standing rule and is not backfilled. When it is completed it will show in DERM Tracker as
--     needing a manifest: use the per-visit "DERM not required" toggle on it.
--   * The free-text PUMP branch of fn_line_item_requires_derm still answers TRUE for "grey water ...
--     pump" names. Those names exist only on completed January to May 2026 visits (plus an invoice
--     re-import reaching two April visits); removing grey water from that branch would make them NULL,
--     not FALSE. Known gap: a NEW free-text grey water line typed in Jobber would still read TRUE.
--   * 1260, 1476 and 1533 are locked with a stored NULL, so no writer touches them. The 31 unlocked
--     stored-NULL live visits the nightly fill could touch derive NULL before and after (B5b asserts that
--     no NULL -> FALSE derive lands on a row that is not already stored FALSE).
--
-- LIMITS OF THE FOLD CHANGE, stated so nobody over-reads it
--   * Only CODED fee/admin lines abstain. A typed fee line ("CC Fees (Deduct if paid by Wire/Check or
--     Zelle) 3.53%", "ACH fee", ...) still answers FALSE through the classifier's non-pumping branch, so a
--     visit reaching only "25" plus a typed fee moves NULL -> FALSE. 0 live visits have that shape (probe
--     case xiii). B6 counts coded fees only, so it cannot see this case.
--   * The fold change turns public.v_gdo_reporting_derm_mismatch back on. Since 2026-08-06 a visit with a
--     visit-scoped 27 line could never derive FALSE (27 answered NULL and NULL blocked FALSE), so that
--     check and the rpa-derm-health 'gdo_not_derm_required' counter could not fire. A 27 line on a grey
--     water visit now derives FALSE and would raise that daily alert, which is correct (probe case xii).
--
-- CONSUMER EFFECTS (measured; no app change needed)
--   * DERM Tracker: new and backfilled grey water visits read Not Required and are not Missing Docs.
--   * Field Portal: customer.work_orders hides a not-required visit (Fred, 2026-08-05). Fred decided on
--     2026-09-24 ("No, keep showing them") that grey water visits must STAY visible to the client (work
--     order, photos, Service Report, report email). That exception is a SEPARATE migration shipped the
--     same day; until it lands, a completed grey water visit stored FALSE is hidden there.
--   * manifest_pickable_visits, the DERM Tracker "Attach visit" picker and dump_route_today: new grey
--     water visits are no longer offered for linking to a manifest and leave the driver's View Addresses
--     list, so they stop reaching the Miami-Dade LWT monthly filing (derm.v_lwt_monthly_rows is built
--     from manifest links; 30 of its 808 rows were grey water pickups, 20 of them on filed tickets). Fred:
--     "Ship now, track it". PART 4 adds derm.v_lwt_grey_water_unlinked (completed grey water pickups
--     since 2026-09-24 with no manifest link) for Jonathan to decide before the October filing; a link can
--     still be added afterwards by SQL (manifest_visits has no derm_required guard).
--   * Calendar: the DERM badge on the 03 / 10 services goes away. County GDO queue and city email: no
--     grey water visit was ever filed or emailed; both are keyed on other signals.
--   * customer.permits uses the classifier to spot a pumping job: 0 of 133 permit rows change.
--
-- VERIFIED BEFORE APPLYING
--   A rolled-back probe exercised the new fold on inserted test visits (112-YA), old body vs new body:
--   25 only NULL/NULL · 03+25 NULL/FALSE · 01+25 TRUE/TRUE · 05+27 NULL/FALSE · 03+unknown NULL/NULL ·
--   27 only NULL/NULL · 10+26 NULL/FALSE · 03+01 TRUE/TRUE · free-text grey water TRUE/TRUE · 05 only
--   FALSE/FALSE · 03 only FALSE/FALSE · 03+27 NULL/FALSE · 25+typed fee NULL/FALSE ("old" = the old fold
--   on the new catalogue). The whole file was then run end to end with
--   its final COMMIT replaced by a sentinel RAISE (nothing kept). The VERIFY block's control B2 fails on
--   the old body (NULL) and on the old catalogue (TRUE).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.visits and public.service_line_items are both audited;
-- every write here lands in audit.logs with old_row intact (the rollback record). The one new object,
-- derm.v_lwt_grey_water_unlinked, is a read-only view (nothing to audit), readable by service_role only
-- (asserted with has_table_privilege, because Supabase default privileges grant new objects by name).
-- The UPDATE on visits fires no Jobber push (derm_required is not in trg_push_visit_update's WHEN list)
-- and no email; it does not lock the rows (no DERM Tracker origin on this path).
--
-- ROLLBACK (one transaction)
--   UPDATE public.service_line_items SET requires_derm = true WHERE code IN ('03','10');
--   re-apply docs/migrations/_baseline/2026-09-24_fn_visit_requires_derm.before.sql (md5 6aed5867...);
--   UPDATE public.visits SET derm_required = true WHERE the id is one of the backfilled ids (audit.logs
--   old_row, app_source 'sql', this migration's timestamp) AND derm_required IS FALSE
--   AND derm_required_locked IS NOT TRUE AND visit_status = 'scheduled';
--   plus any grey water visit born FALSE after the ship that the old rule would call TRUE;
--   DROP VIEW derm.v_lwt_grey_water_unlinked;
-- ============================================================================

BEGIN;
-- One snapshot for the whole file: a Jobber poll committing mid-run cannot make a diff below
-- misfire. A row changed underneath the backfill aborts the file instead (fail-safe).
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- ============================================================================================
-- PART 0. Pre-flight: the objects are exactly what this file was written against.
-- ============================================================================================
DO $pre$
DECLARE v_def text; v_n int; v_set text;
BEGIN
  v_def := pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure);
  IF md5(v_def) <> '6aed5867075d93e7d8ca11e612175b03' THEN
    RAISE EXCEPTION 'pre-flight: fn_visit_requires_derm changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '8c272167ef33ef1751a237bd71a09341' THEN
    RAISE EXCEPTION 'pre-flight: fn_line_item_requires_derm changed; the fee mirror below must be rechecked';
  END IF;
  IF (length(v_def) - length(replace(v_def, '    WHERE v.id = p_visit_id
', ''))) / length('    WHERE v.id = p_visit_id
') <> 1 THEN
    RAISE EXCEPTION 'pre-flight: the splice anchor does not occur exactly once';
  END IF;
  SELECT count(*) INTO v_n FROM public.service_line_items
   WHERE code IN ('03','10') AND requires_derm IS TRUE AND location_target = 'Grey Water' AND service_type = 'Pumping';
  IF v_n <> 2 THEN RAISE EXCEPTION 'pre-flight: expected codes 03 and 10 to be grey water pumping and DERM required, found %', v_n; END IF;
  SELECT string_agg(code, ',' ORDER BY code) INTO v_set FROM public.service_line_items WHERE reason IN ('fee','other');
  IF v_set IS DISTINCT FROM '25,26,27' THEN RAISE EXCEPTION 'pre-flight: fee/other codes are %, expected 25,26,27', v_set; END IF;
  SELECT string_agg(code, ',' ORDER BY code) INTO v_set FROM public.service_line_items WHERE requires_derm;
  IF v_set IS DISTINCT FROM '01,02,03,04,09,10,11' THEN RAISE EXCEPTION 'pre-flight: DERM-required codes are %', v_set; END IF;
  IF public.fn_visit_requires_derm(6508) IS NOT TRUE OR public.fn_visit_requires_derm(6509) IS NOT TRUE THEN
    RAISE EXCEPTION 'pre-flight: controls 6508 / 6509 (214-MYK, 03 + 25) must derive TRUE before the change';
  END IF;
END
$pre$;

-- ============================================================================================
-- Snapshot of every live visit, taken BEFORE any change (dropped at commit).
-- ============================================================================================
CREATE TEMP TABLE _gw_old ON COMMIT DROP AS
  SELECT pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure) AS def;
CREATE TEMP TABLE _gw_snap ON COMMIT DROP AS
  SELECT v.id, public.fn_visit_requires_derm(v.id) AS derive_before, v.derm_required AS stored_before,
         v.derm_required_locked AS locked, v.visit_status, v.visit_date, v.sync_state AS sync_before,
         EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
             OR (v.job_id IS NOT NULL AND li.job_id = v.job_id))
        AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('03','10')) AS reaches_gw,
         EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
             OR (v.job_id IS NOT NULL AND li.job_id = v.job_id))
        AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN (SELECT code FROM public.service_line_items WHERE reason IN ('fee','other'))) AS reaches_fee
    FROM public.visits v
   WHERE v.deleted_at IS NULL;
CREATE TEMP TABLE _gw_wo ON COMMIT DROP AS SELECT count(*)::bigint AS n FROM customer.work_orders;
CREATE TEMP TABLE _gw_bf (id bigint PRIMARY KEY) ON COMMIT DROP;

-- ============================================================================================
-- PART 1. Catalogue: grey water pumping (03 Service Agreement, 10 Service Call) no longer requires DERM.
-- ============================================================================================
DO $cat$
DECLARE v_n int;
BEGIN
  IF (SELECT count(*) FROM _gw_snap) < 2000 THEN RAISE EXCEPTION 'snapshot too small'; END IF;
  UPDATE public.service_line_items SET requires_derm = false WHERE code IN ('03','10') AND requires_derm IS TRUE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN RAISE EXCEPTION 'catalogue: expected 2 rows, updated %', v_n; END IF;
  -- In-transaction control: with the catalogue changed but the OLD fold, 6508 (03 + 25) derives NULL,
  -- which still means "needs a manifest". This is why PART 2 is needed, and it proves the VERIFY
  -- control below can tell the old fold from the new one.
  IF public.fn_visit_requires_derm(6508) IS NOT NULL THEN
    RAISE EXCEPTION 'control: the old fold should answer NULL for 6508 after the catalogue change, got %', public.fn_visit_requires_derm(6508);
  END IF;
END
$cat$;

-- ============================================================================================
-- PART 2. fn_visit_requires_derm: the live body with ONE predicate spliced in (never retyped).
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.fn_visit_requires_derm(p_visit_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_any boolean; v_all boolean; v_cnt integer;
BEGIN
  SELECT bool_or(d IS TRUE), bool_and(d IS NOT NULL), count(*)
    INTO v_any, v_all, v_cnt
  FROM (
    SELECT public.fn_line_item_requires_derm(li.name) AS d
    FROM public.visits v
    JOIN public.line_items li
      ON  li.name IS NOT NULL
      AND ( li.visit_id = v.id
            OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
            OR (v.job_id     IS NOT NULL AND li.job_id     = v.job_id) )
    WHERE v.id = p_visit_id
      -- 2026-09-24: fee/admin catalogue lines (reason fee/other: 25, 26, 27) abstain for real: they
      -- neither decide the verdict nor block it, exactly as the Calendar and SA writers have folded
      -- them since 2026-08-13. A visit that reaches ONLY such lines keeps v_cnt = 0 and still
      -- derives NULL (the 2026-08-06 guard). An unrecognised free-text line still blocks (NULL).
      AND NOT EXISTS (
        SELECT 1 FROM public.service_line_items s
         WHERE s.reason IN ('fee','other')
           AND s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0'))
  ) q;

  IF v_cnt = 0 OR v_cnt IS NULL THEN RETURN NULL; END IF;
  IF v_any THEN RETURN true; END IF;
  IF v_all THEN RETURN false; END IF;
  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.fn_visit_requires_derm(bigint) IS
  'DERM required for a visit, from the line items it reaches (visit, invoice or job). Any line classified TRUE -> true; '
  'every line classified and none TRUE -> false; otherwise NULL (unknown, treated as still needing a manifest). '
  'Fee/admin catalogue lines (reason fee/other: 25, 26, 27) abstain: they are left out of the fold, so a visit '
  'reaching only such lines is NULL. Grey water pumping (03, 10) is not DERM required since 2026-09-24.';

-- ============================================================================================
-- VERIFY. Any failure raises and nothing above is kept.
-- ============================================================================================
DO $verify$
DECLARE v_n int; v_m int; v_a int; v_b int;
BEGIN
  -- B1. Splice only: the new definition is the old one plus the predicate, byte for byte.
  IF md5(pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure))
     <> md5(replace((SELECT def FROM _gw_old), '    WHERE v.id = p_visit_id
', '    WHERE v.id = p_visit_id
      -- 2026-09-24: fee/admin catalogue lines (reason fee/other: 25, 26, 27) abstain for real: they
      -- neither decide the verdict nor block it, exactly as the Calendar and SA writers have folded
      -- them since 2026-08-13. A visit that reaches ONLY such lines keeps v_cnt = 0 and still
      -- derives NULL (the 2026-08-06 guard). An unrecognised free-text line still blocks (NULL).
      AND NOT EXISTS (
        SELECT 1 FROM public.service_line_items s
         WHERE s.reason IN (''fee'',''other'')
           AND s.code = lpad(substring(btrim(li.name) from ''^([0-9]{1,2})[[:space:]]*-[[:space:]]''), 2, ''0''))
')) THEN
    RAISE EXCEPTION 'B1: the new body is not exactly the old body plus the predicate';
  END IF;
  -- B2. The control that fails on the old body (NULL there) and on the old catalogue (TRUE there).
  IF public.fn_visit_requires_derm(6508) IS NOT FALSE OR public.fn_visit_requires_derm(6509) IS NOT FALSE THEN
    RAISE EXCEPTION 'B2: 6508 / 6509 must now derive FALSE';
  END IF;
  -- B3. Mirror: the fold's exclusion is exactly the classifier's abstain arm, on every live name.
  SELECT count(*) FILTER (WHERE excl IS DISTINCT FROM absn), count(*) FILTER (WHERE excl AND public.fn_line_item_requires_derm(name) IS NOT NULL),
         count(*) FILTER (WHERE excl AND name = '25 - Credit card fee (3.53%)')
    INTO v_n, v_m, v_a
    FROM (SELECT DISTINCT li.name,
                 EXISTS (SELECT 1 FROM public.service_line_items s WHERE s.reason IN ('fee','other') AND s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')) AS excl,
                 COALESCE((SELECT s.reason IN ('fee','other') FROM public.service_line_items s
                            WHERE s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})\s*-\s'), 2, '0')), false) AS absn
            FROM public.line_items li WHERE li.name IS NOT NULL) x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'B3: % line names where the fold exclusion and the classifier abstain arm disagree', v_n; END IF;
  IF v_m <> 0 THEN RAISE EXCEPTION 'B3: % excluded names do not classify NULL', v_m; END IF;
  IF v_a < 1 THEN RAISE EXCEPTION 'B3 control: the credit card fee line must be in the excluded set'; END IF;
  -- B4. Every other pumping code still makes a visit DERM required.
  SELECT count(*), count(*) FILTER (WHERE public.fn_visit_requires_derm(v.id) IS NOT TRUE) INTO v_n, v_m
    FROM public.visits v
   WHERE v.deleted_at IS NULL AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
             OR (v.job_id IS NOT NULL AND li.job_id = v.job_id))
        AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('01','02','04','09','11'));
  IF v_n < 1000 THEN RAISE EXCEPTION 'B4 control: only % visits reach a DERM pumping code', v_n; END IF;
  IF v_m <> 0 THEN RAISE EXCEPTION 'B4: % visits with a DERM pumping line no longer derive TRUE', v_m; END IF;
  -- B5. Every derive change is one of the two intended kinds, and each kind is non-empty.
  CREATE TEMP TABLE _gw_after ON COMMIT DROP AS
    SELECT s.*, public.fn_visit_requires_derm(s.id) AS derive_after FROM _gw_snap s;
  SELECT count(*) FILTER (WHERE reaches_gw AND derive_before IS TRUE AND derive_after IS FALSE),
         count(*) FILTER (WHERE NOT reaches_gw AND reaches_fee AND derive_before IS NULL AND derive_after IS FALSE)
    INTO v_a, v_b FROM _gw_after;
  SELECT count(*) INTO v_n FROM _gw_after
   WHERE derive_after IS DISTINCT FROM derive_before
     AND NOT (reaches_gw AND derive_before IS TRUE AND derive_after IS FALSE)
     AND NOT (NOT reaches_gw AND reaches_fee AND derive_before IS NULL AND derive_after IS FALSE);
  RAISE NOTICE 'B5: grey water TRUE->FALSE %, fee-abstain NULL->FALSE %, other changes %', v_a, v_b, v_n;
  IF v_a < 1 OR v_b < 1 THEN RAISE EXCEPTION 'B5: the instrument sees no change (% / %)', v_a, v_b; END IF;
  IF v_n <> 0 THEN RAISE EXCEPTION 'B5: % derive changes of an unintended kind', v_n; END IF;
  -- B5b. A NULL->FALSE derive must not reach a row the nightly fill would newly hide: it may only land
  --      on a row already stored FALSE (the Calendar and SA writers wrote FALSE there already).
  SELECT count(*) INTO v_n FROM _gw_after
   WHERE derive_before IS NULL AND derive_after IS FALSE AND stored_before IS DISTINCT FROM false;
  IF v_n <> 0 THEN RAISE EXCEPTION 'B5b: % visits would newly be filled FALSE by the nightly job', v_n; END IF;
  -- B6. Fee-only guard (vacuous on live data today; the pre-ship probe is the real proof).
  SELECT count(*) INTO v_n FROM _gw_after a
   WHERE a.reaches_fee AND a.derive_after IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.visits v JOIN public.line_items li ON li.name IS NOT NULL
                       AND (li.visit_id = v.id OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
                            OR (v.job_id IS NOT NULL AND li.job_id = v.job_id))
                      WHERE v.id = a.id
                        AND COALESCE(lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0'), '') NOT IN (SELECT code FROM public.service_line_items WHERE reason IN ('fee','other')));
  IF v_n <> 0 THEN RAISE EXCEPTION 'B6: % visits reaching only fee/admin lines derive non-NULL', v_n; END IF;
  -- B7. The county-reporting mismatch view stays empty.
  IF EXISTS (SELECT 1 FROM public.v_gdo_reporting_derm_mismatch) THEN RAISE EXCEPTION 'B7: v_gdo_reporting_derm_mismatch is not empty'; END IF;
END
$verify$;

-- ============================================================================================
-- PART 3. Backfill: PENDING visits only (scheduled, dated today or later in ET), unlocked, stored TRUE,
-- now deriving FALSE. Completed visits, locked visits and anything with a manifest are left alone
-- (Fred: "leave the filed ones alone").
-- ============================================================================================
DO $bf$
DECLARE v_pre int; v_n int; v_bad int;
BEGIN
  INSERT INTO _gw_bf (id) SELECT v.id FROM public.visits v WHERE v.deleted_at IS NULL
     AND v.visit_status = 'scheduled'
     AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE
     AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_pre = ROW_COUNT;
  IF v_pre < 1 OR v_pre > 40 THEN RAISE EXCEPTION 'D1: % backfill candidates, expected 1 to 40', v_pre; END IF;
  SELECT count(*) INTO v_bad FROM _gw_bf b JOIN _gw_snap s USING (id) WHERE NOT s.reaches_gw;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D1: % candidates do not reach a grey water line', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM _gw_bf b
   WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id
                  WHERE mv.visit_id = b.id AND m.deleted_at IS NULL);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D1: % candidates have a live manifest', v_bad; END IF;

  UPDATE public.visits v SET derm_required = false FROM _gw_bf b WHERE v.id = b.id AND v.deleted_at IS NULL
     AND v.visit_status = 'scheduled'
     AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE
     AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> v_pre THEN RAISE EXCEPTION 'D1: updated % rows, expected %', v_n, v_pre; END IF;

  -- D2. No pending unlocked visit is left stored TRUE while deriving FALSE.
  SELECT count(*) INTO v_bad FROM public.visits v WHERE v.deleted_at IS NULL
     AND v.visit_status = 'scheduled'
     AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE
     AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D2: % pending visits still TRUE while deriving FALSE', v_bad; END IF;
  -- D3. Nothing else moved: completed, locked and non-candidate rows keep their stored value; none came out locked.
  SELECT count(*) INTO v_bad FROM _gw_snap s JOIN public.visits v ON v.id = s.id
   WHERE v.derm_required IS DISTINCT FROM s.stored_before AND s.id NOT IN (SELECT id FROM _gw_bf);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D3: % non-candidate visits changed their stored value', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM public.visits v JOIN _gw_bf b USING (id) WHERE v.derm_required_locked IS TRUE OR v.visit_status <> 'scheduled';
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D3: % backfilled rows are locked or not scheduled', v_bad; END IF;
  -- The backfill must not queue anything for Jobber (fn_mark_visit_sync_pending ignores derm_required).
  SELECT count(*) INTO v_bad FROM public.visits v JOIN _gw_snap s USING (id) JOIN _gw_bf b USING (id)
   WHERE v.sync_state IS DISTINCT FROM s.sync_before;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D3: % backfilled rows changed sync_state', v_bad; END IF;
  IF (SELECT count(*) FROM customer.work_orders) <> (SELECT n FROM _gw_wo) THEN
    RAISE EXCEPTION 'D3: customer.work_orders changed from % to %', (SELECT n FROM _gw_wo), (SELECT count(*) FROM customer.work_orders);
  END IF;
  -- D4. The SA generator's own verdict (bool_or over job lines) agrees with the backfill.
  SELECT count(*) INTO v_bad FROM (
    SELECT v.job_id, bool_or(public.fn_line_item_requires_derm(li.name)) AS gen
      FROM public.visits v JOIN _gw_bf b USING (id) JOIN public.line_items li ON li.job_id = v.job_id AND li.name IS NOT NULL
     GROUP BY v.job_id) j WHERE j.gen IS NOT FALSE;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'D4: % backfilled jobs would still generate DERM-required visits', v_bad; END IF;
  RAISE NOTICE 'backfill: % pending grey water visits set derm_required = false', v_n;
END
$bf$;

-- ============================================================================================
-- PART 4. Tracker for the Miami-Dade LWT monthly filing (Fred: "Ship now, track it").
-- derm.v_lwt_monthly_rows is built from manifest links only, and a not-required visit is no longer
-- offered for linking in the apps, so a grey water pickup from now on reaches that filing only if
-- someone links it on purpose. This lists the ones that are not linked, for Jonathan to decide.
-- Grey water is read from the catalogue (Pumping + Grey Water), never a hard-coded code list.
-- ============================================================================================
CREATE VIEW derm.v_lwt_grey_water_unlinked AS
SELECT v.id AS visit_id, c.client_code, c.name AS client_name, v.visit_date, p.county, v.derm_required
  FROM public.visits v
  LEFT JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.properties p ON p.id = v.property_id
 WHERE v.deleted_at IS NULL
   AND v.visit_status = 'completed'
   AND v.visit_date >= DATE '2026-09-24'
   AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
             OR (v.job_id IS NOT NULL AND li.job_id = v.job_id))
        AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN (SELECT code FROM public.service_line_items WHERE service_type = 'Pumping' AND location_target = 'Grey Water'))
   AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id
                    WHERE mv.visit_id = v.id AND m.deleted_at IS NULL);
COMMENT ON VIEW derm.v_lwt_grey_water_unlinked IS
  'Completed grey water pickups since 2026-09-24 (the day grey water stopped being DERM required) with no manifest link. '
  'derm.v_lwt_monthly_rows (the Miami-Dade LWT monthly filing) is built from manifest links, so these are NOT on it. '
  'Open question for Jonathan: must grey water pickups be filed? Empty means nothing is missing.';
REVOKE ALL ON derm.v_lwt_grey_water_unlinked FROM PUBLIC, anon, authenticated;
GRANT SELECT ON derm.v_lwt_grey_water_unlinked TO service_role;

DO $acl$
BEGIN
  -- Supabase default privileges grant a new object BY NAME; assert what is actually there.
  IF has_table_privilege('anon', 'derm.v_lwt_grey_water_unlinked', 'SELECT')
     OR has_table_privilege('authenticated', 'derm.v_lwt_grey_water_unlinked', 'SELECT') THEN
    RAISE EXCEPTION 'ACL: derm.v_lwt_grey_water_unlinked is readable by anon or authenticated';
  END IF;
  IF (SELECT count(*) FROM derm.v_lwt_grey_water_unlinked) <> 0 THEN
    RAISE EXCEPTION 'tracker: expected 0 rows on the day it ships';
  END IF;
END
$acl$;

COMMIT;
