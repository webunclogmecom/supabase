-- 2026-08-27_2150_page_geometry_slot_coverage_and_withheld_cards.sql
--
-- WHY: TWO HOLES IN THE GUARDS I SHIPPED THIS AFTERNOON, BOTH PROVEN END TO END.
-- ---------------------------------------------------------------------------
-- `2026-08-27_1430` gave the Stamp Studio a page-atomic geometry save, the first human-facing write
-- path onto regulator-facing redactions. A test pass found it validates edge position and nothing
-- about slot COVERAGE, and that it is blind to withheld cards. Both were demonstrated against live
-- Prod in rolled-back transactions, and both are leak paths through a button an operator can press.
--
-- HOLE 1 - SLOT COVERAGE. On ticket-833530 p1 (6 printed slots, 3 carded), growing 249-LOU from one
-- slot (38.482..44.018) to three (38.482..54.911) returned **ZERO violations**. save_page_geometry
-- accepted it, and derm.fn_blackout_targets immediately emitted a publishable target revealing
-- 38.482..54.911, i.e. two printed slots the client does not own.
-- Every existing guard passed HONESTLY: both edges really are printed boundaries (G9), no CARDED
-- band overlaps because those slots are empty (G7), and the client's own stamp is inside (G13).
-- The empty printed slot is exactly what a band-vs-band check cannot see, which is the same
-- blindness that made ticket-310590 p2 a real leak on 2026-08-19.
-- 🛑 CLAUDE.md says it in as many words - "ON_RULE is necessary, not sufficient" - and 1430 shipped
-- only the necessary half. `derm.v_band_edge_check` has had the sufficient half all along in
-- `slot_verdict`; it simply was not wired into the save.
-- ⚠ And the detector does NOT cover the gap: v_band_edges_off_rule DID flag the bad band, but only
-- AFTER the save, and the */5 sweep republishes within five minutes. A post-hoc alarm is not a gate.
--
-- HOLE 2 - WITHHELD CARDS. A card with a stamp point but no `stamp_placed_at` is excluded from the
-- closed set (G6) because it cannot publish, so it never appears in the payload and G7 cannot see it.
-- A neighbour's band can therefore be grown straight across the withheld client's printed row with
-- every guard green. 🛑 Withholding is the mechanism this estate used THIS MORNING to contain the
-- window4-sheet1 cross-client leak, so the safety mechanism and the blind spot were the same rows.
-- 10 withheld cards exist on 8 folders.
--
-- BOTH NEW GUARDS ARE ABSOLUTE WHERE THAT IS SAFE AND NO-WORSE WHERE IT IS NOT:
--   G7b is absolute - measured, no submitted band overlaps a withheld card today.
--   G14 is NO-WORSE - only a CHANGED band is checked, so the 80 accepted off-rule bands, the
--   halved-row sheets and an unchanged replay are all untouched.
-- `expected_slots` is computed exactly as derm.v_band_edge_check computes it, so a multi-permit
-- client that legitimately owns several consecutive printed rows is not refused; it falls back to 1
-- on a handwritten pad, which is correct there.
--
-- 🛑 BODY COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT: two anchors, each asserted to match
-- exactly once. Everything else byte-identical.
--
-- RULE 8 (audit trail): a function holds no state; opt-out.

BEGIN;

CREATE OR REPLACE FUNCTION derm._page_geometry_violations(p_dump_folder text, p_effective_page integer, p_bands jsonb, p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
 RETURNS TABLE(code text, detail text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_tol   constant numeric := 0.35;   -- the ON_RULE tolerance v_band_edge_check already grades with
  v_n     integer;
  v_scan  record;
BEGIN
  ----------------------------------------------------------------------------
  -- G1 SHAPE. Fail-closed on every NULL. set_row_band's own Defect 1 was a NULL slipping past an
  -- IF that evaluated to NULL; do not repeat it one level up.
  ----------------------------------------------------------------------------
  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RETURN QUERY SELECT 'G1_NULL_KEY', 'dump_folder and effective_page are required'; RETURN;
  END IF;
  IF p_bands IS NULL OR jsonb_typeof(p_bands) <> 'array' OR jsonb_array_length(p_bands) = 0 THEN
    RETURN QUERY SELECT 'G1_BANDS_SHAPE', 'p_bands must be a non-empty JSON array'; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_bands) e
              WHERE (e->>'row_id') IS NULL OR (e->>'y0') IS NULL OR (e->>'y1') IS NULL) THEN
    RETURN QUERY SELECT 'G1_BAND_NULL', 'every band needs row_id, y0 and y1'; RETURN;
  END IF;
  SELECT count(*) - count(DISTINCT (e->>'row_id')::bigint) INTO v_n
    FROM jsonb_array_elements(p_bands) e;
  IF v_n <> 0 THEN
    RETURN QUERY SELECT 'G1_DUP_ROW', format('%s duplicate row_id(s) in payload', v_n); RETURN;
  END IF;
  -- An extent is all-or-nothing: one edge without the other is meaningless.
  IF (p_top_pct IS NULL) <> (p_bottom_pct IS NULL) THEN
    RETURN QUERY SELECT 'G1_HALF_EXTENT', 'supply both p_top_pct and p_bottom_pct, or neither'; RETURN;
  END IF;

  ----------------------------------------------------------------------------
  -- G2 RANGE. Mirrors the table CHECKs so the message is readable, not a raw 23514.
  ----------------------------------------------------------------------------
  IF p_top_pct IS NOT NULL AND NOT (p_top_pct >= 0 AND p_bottom_pct <= 100 AND p_top_pct < p_bottom_pct) THEN
    RETURN QUERY SELECT 'G2_EXTENT_RANGE', format('extent out of range (%s..%s)', p_top_pct, p_bottom_pct);
  END IF;
  RETURN QUERY
    SELECT 'G2_BAND_RANGE', format('row %s band out of range (%s..%s)', e->>'row_id', e->>'y0', e->>'y1')
      FROM jsonb_array_elements(p_bands) e
     WHERE NOT ((e->>'y0')::numeric >= 0 AND (e->>'y1')::numeric <= 100
                AND (e->>'y0')::numeric < (e->>'y1')::numeric);

  ----------------------------------------------------------------------------
  -- G3 PAGE EXISTS. Resolved from the grain the whole pipeline uses,
  -- (dump_folder, COALESCE(stamp_page, page)). NOT via ticket_page_images: that takes a WHITE
  -- MANIFEST NUMBER, and only 38 of 132 folders are 'ticket-<white#>' shaped, so on the other 94 it
  -- resolves NULL, array_length(NULL,1) is NULL, and the guard would silently pass.
  ----------------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                  WHERE r.dump_folder = p_dump_folder
                    AND COALESCE(r.stamp_page, r.page) = p_effective_page
                    AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL) THEN
    RETURN QUERY SELECT 'G3_NO_SUCH_PAGE',
      format('no placed card on %s page %s', p_dump_folder, p_effective_page); RETURN;
  END IF;

  ----------------------------------------------------------------------------
  -- G6 CLOSED SET. The payload must name EXACTLY the publishable cards on the page.
  -- 🛑 This is what makes atomicity mean anything: without it a page can be saved with one card
  -- still on a derived band under a fresh extent, which is the 2026-08-19 shape.
  -- ⚠ WITHHELD cards (stamp point present, stamp_placed_at NULL) are EXCLUDED, because they cannot
  -- publish, so blocking on them buys nothing and would couple a geometry edit to an unrelated
  -- placement decision on 6 serving pages carrying 20 documents.
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH want AS (
      SELECT r.id FROM derm.address_row_map r
       WHERE r.dump_folder = p_dump_folder
         AND COALESCE(r.stamp_page, r.page) = p_effective_page
         AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
    ), got AS (
      SELECT (e->>'row_id')::bigint AS id FROM jsonb_array_elements(p_bands) e
    )
    SELECT 'G6_MISSING_ROW', format('row %s is on this page but not in the payload', w.id)
      FROM want w WHERE NOT EXISTS (SELECT 1 FROM got g WHERE g.id = w.id)
    UNION ALL
    SELECT 'G6_FOREIGN_ROW', format('row %s is not a publishable card on this page', g.id)
      FROM got g WHERE NOT EXISTS (SELECT 1 FROM want w WHERE w.id = g.id);

  ----------------------------------------------------------------------------
  -- G7 NO OVERLAP. ABSOLUTE, not no-worse: measured, ZERO publishable pairs overlap today, so
  -- nothing legitimate is refused. Rounded to 3dp first, because set_row_band stores round(x,3) and
  -- comparing unrounded input would turn a legal touching edge into a refusal.
  -- ⚠ TOUCHING IS LEGAL (a.y1 = b.y0): 145 manual pairs touch exactly and Fred's mockup is
  -- edge-to-edge. GAPS ARE LEGAL TOO (342 of 488 adjacent pairs have one, 14 a whole empty printed
  -- row). This function NEVER adjusts a neighbour to close a gap.
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH b AS (
      SELECT (e->>'row_id')::bigint AS id,
             round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
        FROM jsonb_array_elements(p_bands) e
    )
    SELECT 'G7_OVERLAP', format('rows %s and %s overlap (%s..%s vs %s..%s)', x.id, y.id, x.y0, x.y1, y.y0, y.y1)
      FROM b x JOIN b y ON y.id < x.id AND x.y0 < y.y1 AND y.y0 < x.y1;

  ----------------------------------------------------------------------------
  -- G7b WITHHELD CARDS. A card with a stamp POINT but no stamp_placed_at is excluded from the
  -- closed set (G6) because it cannot publish, so it never appears in the payload and G7 above
  -- cannot see it. That makes the estate's own containment mechanism its blind spot: withholding a
  -- card is exactly how the window4-sheet1 cross-client leak was contained on 2026-08-27, and a
  -- neighbour's band could then be grown straight across the withheld client's printed row with
  -- every guard green. 10 withheld cards exist on 8 folders right now.
  -- Absolute, not no-worse: measured, no submitted band overlaps a withheld card today.
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH b AS (
      SELECT (e->>'row_id')::bigint AS id,
             round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
        FROM jsonb_array_elements(p_bands) e
    )
    SELECT 'G7B_OVERLAPS_WITHHELD',
           format('row %s (%s..%s) covers withheld card %s (%s..%s), which cannot defend itself',
                  b.id, b.y0, b.y1, w.id, w.band_y0_pct, w.band_y1_pct)
      FROM b
      JOIN (SELECT r.id, vb.band_y0_pct, vb.band_y1_pct
              FROM derm.address_row_map r JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
             WHERE r.dump_folder = p_dump_folder
               AND COALESCE(r.stamp_page, r.page) = p_effective_page
               AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NULL) w
        ON b.y0 < w.band_y1_pct AND w.band_y0_pct < b.y1;

  ----------------------------------------------------------------------------
  -- The winning scan for this page, if any. Read from the ONE definition.
  ----------------------------------------------------------------------------
  SELECT DISTINCT ON (v.dump_folder, v.effective_page) v.source, v.grade
    INTO v_scan
    FROM derm.v_page_printed_rules v
   WHERE v.dump_folder = p_dump_folder AND v.effective_page = p_effective_page;

  ----------------------------------------------------------------------------
  -- G9 ON A PRINTED RULE. NO-WORSE: only edges the operator actually CHANGED are checked.
  -- ⚠ "unchanged" means it matches an existing MANUAL band. A derived band made manual is a NEW
  -- assertion and must earn the check.
  -- ⚠ Accepts kind IN ('boundary','divider'): both are lines printed on the paper, which is the
  -- real invariant, and it matches v_band_edge_check's edge_verdict exactly. Boundary-only would
  -- refuse the halved-row sheets, where the writer fits 8 clients on a 6-slot form and the correct
  -- edges ARE mid-slot dividers (8 live serving bands at 2.300-2.820pp).
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH b AS (
      SELECT (e->>'row_id')::bigint AS id,
             round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
        FROM jsonb_array_elements(p_bands) e
    ), edges AS (
      SELECT b.id, 'top'::text AS which, b.y0 AS val, r.band_y0_pct AS stored FROM b
        JOIN derm.address_row_map r ON r.id = b.id
      UNION ALL
      SELECT b.id, 'bottom', b.y1, r.band_y1_pct FROM b
        JOIN derm.address_row_map r ON r.id = b.id
    ), changed AS (
      SELECT * FROM edges WHERE stored IS NULL OR stored <> val
    )
    SELECT 'G9_OFF_RULE',
           format('row %s %s edge %s is not on a printed rule (nearest %s)', c.id, c.which, c.val,
                  COALESCE((SELECT min(abs(pr.rule_pct - c.val))::text FROM derm.v_page_printed_rules pr
                             WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
                               AND pr.kind IN ('boundary','divider')), 'no rules for this page'))
      FROM changed c
     WHERE NOT EXISTS (
       SELECT 1 FROM derm.v_page_printed_rules pr
        WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
          AND pr.kind IN ('boundary','divider')
          AND abs(pr.rule_pct - c.val) <= v_tol);

  ----------------------------------------------------------------------------
  -- G13 OWN STAMP IN OWN BAND. NO-WORSE. Without it, a tiling shifted by one whole slot satisfies
  -- G7, G8 and G9 simultaneously (a snapped edge is on a rule whichever slot it bounds) and every
  -- client is served their neighbour's row. The stamp is the one thing that ties a band to the
  -- client who owns it, because a person put it on that client's printed row.
  -- ⚠ 3 live bands already fail this (ids 209, 216, 239) and 2 are accepted in derm.band_review as
  -- the client's handwriting overflowing its slot, so they are grandfathered by the no-worse arm.
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH b AS (
      SELECT (e->>'row_id')::bigint AS id,
             round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
        FROM jsonb_array_elements(p_bands) e
    )
    SELECT 'G13_STAMP_OUTSIDE_BAND',
           format('row %s: its stamp (%s) is outside the submitted band %s..%s', b.id, r.stamp_y_pct, b.y0, b.y1)
      FROM b JOIN derm.address_row_map r ON r.id = b.id
     WHERE r.stamp_y_pct IS NOT NULL
       AND NOT (r.stamp_y_pct BETWEEN b.y0 AND b.y1)
       AND (r.band_y0_pct IS NULL OR r.band_y0_pct <> b.y0 OR r.band_y1_pct <> b.y1);  -- changed only

  ----------------------------------------------------------------------------
  -- G8 CONTAINMENT + G11 ROSTER COVERAGE. Only when an extent is being written, and NO-WORSE:
  -- 55 pages violate containment today (max overshoot 1.885pp) and refusing them would make the
  -- editor unusable on a third of the fleet.
  -- 🛑 G11 exists because containment ALONE does not bind the extent to the printed roster: an
  -- extent equal to the band envelope satisfies G8 and leaves every EMPTY printed slot outside the
  -- black box, which is exactly the 2026-08-03_0046 leak. The lower bound must come from the RULES.
  ----------------------------------------------------------------------------
  IF p_top_pct IS NOT NULL THEN
    RETURN QUERY
      WITH b AS (
        SELECT round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
          FROM jsonb_array_elements(p_bands) e
      ), agg AS (SELECT min(y0) AS miny, max(y1) AS maxy FROM b),
      cur AS (SELECT e.top_pct, e.bottom_pct FROM derm.page_block_extents e
               WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page)
      SELECT 'G8_NOT_CONTAINED',
             format('extent %s..%s does not contain the bands %s..%s', p_top_pct, p_bottom_pct, agg.miny, agg.maxy)
        FROM agg
       WHERE (p_top_pct > agg.miny OR p_bottom_pct < agg.maxy)
         AND NOT EXISTS (SELECT 1 FROM cur WHERE cur.top_pct = p_top_pct AND cur.bottom_pct = p_bottom_pct);

    RETURN QUERY
      WITH lim AS (
        SELECT min(pr.rule_pct) AS first_b, max(pr.rule_pct) AS last_b
          FROM derm.v_page_printed_rules pr
         WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
           AND pr.kind = 'boundary'
      ), cur AS (SELECT e.top_pct, e.bottom_pct FROM derm.page_block_extents e
                  WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page)
      SELECT 'G11_ROSTER_NOT_COVERED',
             format('extent %s..%s does not span the printed roster %s..%s (empty printed slots would be served)',
                    p_top_pct, p_bottom_pct, lim.first_b, lim.last_b)
        FROM lim
       WHERE lim.first_b IS NOT NULL
         AND (p_top_pct > lim.first_b + v_tol OR p_bottom_pct < lim.last_b - v_tol)
         AND NOT EXISTS (SELECT 1 FROM cur WHERE cur.top_pct = p_top_pct AND cur.bottom_pct = p_bottom_pct);
  END IF;

  ----------------------------------------------------------------------------
  -- G14 SLOT COVERAGE. 🛑 THE HALF THAT WAS MISSING, AND IT IS A LEAK PATH THROUGH A BUTTON.
  -- G9 proves each edge sits on a line that is printed on the paper. It says NOTHING about how many
  -- printed SLOTS the band then encloses. CLAUDE.md states this directly - "ON_RULE is necessary,
  -- not sufficient" - and 2026-08-27_1430 shipped only the necessary half.
  -- Proven end to end before this fix: on ticket-833530 p1 (6 printed slots, 3 carded) growing
  -- 249-LOU from 38.482..44.018 to 38.482..54.911 returned ZERO violations, save_page_geometry
  -- accepted it, and fn_blackout_targets immediately emitted a reveal window covering two printed
  -- slots the client does not own. Every other guard passed honestly: both edges ARE boundaries, no
  -- CARDED band overlaps because those slots are empty, and the stamp is inside.
  -- The empty slot is precisely the case a band-vs-band check cannot see, which is the same blindness
  -- that made ticket-310590 p2 a real leak on 2026-08-19.
  --
  -- ⚠ NO-WORSE, like every other geometry guard: only a CHANGED band is checked. 80 accepted
  -- off-rule bands and the halved-row sheets are untouched, and replaying a page unchanged still
  -- costs nothing.
  -- ⚠ expected_slots is computed exactly as derm.v_band_edge_check computes it, through
  -- derm.v_sheet_printed_rows and fn_sheet_image_position, so a multi-permit client that legitimately
  -- owns several consecutive printed rows is NOT refused. It falls back to 1 on a handwritten pad,
  -- which is correct there: one card, one printed row.
  ----------------------------------------------------------------------------
  RETURN QUERY
    WITH b AS (
      SELECT (e->>'row_id')::bigint AS id,
             round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
        FROM jsonb_array_elements(p_bands) e
    ), changed AS (
      SELECT b.* FROM b JOIN derm.address_row_map r ON r.id = b.id
       WHERE r.band_y0_pct IS NULL OR r.band_y0_pct <> b.y0 OR r.band_y1_pct <> b.y1
    ), slots AS (
      SELECT c.id, c.y0, c.y1,
             GREATEST(COALESCE((SELECT count(*)
                 FROM derm.address_row_map a2
                 JOIN public.derm_manifests dm ON dm.id = a2.matched_manifest_id AND dm.deleted_at IS NULL
                 JOIN derm.address_sheet_manifests asm ON asm.manifest_id = dm.id
                 JOIN derm.address_sheets ash ON ash.id = asm.sheet_id AND ash.deleted_at IS NULL
                 JOIN derm.v_sheet_printed_rows vpr ON vpr.sheet_id = asm.sheet_id
                  AND vpr.client_id = a2.matched_client_id
                WHERE a2.id = c.id
                  AND derm.fn_sheet_image_position(a2.dump_folder, vpr.printed_page) = p_effective_page
             ), 0::bigint), 1::bigint)::integer AS expected_slots,
             (SELECT count(*) FROM derm.v_page_printed_rules pr
               WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
                 AND pr.kind = 'boundary' AND pr.rule_pct > c.y0 + v_tol AND pr.rule_pct < c.y1 - v_tol
             )::integer AS inner_boundaries
        FROM changed c
    )
    SELECT 'G14_SPANS_EXTRA_SLOTS',
           format('row %s band %s..%s encloses %s printed slot boundaries but the client owns %s printed row(s) on this page',
                  s.id, s.y0, s.y1, s.inner_boundaries, s.expected_slots)
      FROM slots s
     WHERE s.inner_boundaries > s.expected_slots - 1;

  RETURN;
END $function$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_pay jsonb; v_n integer; v_codes text;
BEGIN
  -- the real page, as the app would build it
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', b.band_y0_pct, 'y1', b.band_y1_pct))
    INTO v_pay
    FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder='ticket-833530' AND COALESCE(r.stamp_page,r.page)=1
     AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL;
  IF jsonb_array_length(v_pay) <> 3 THEN RAISE EXCEPTION 'VERIFY: fixture moved'; END IF;

  -- 1. 🛑 THE HOLE IS CLOSED. The exact payload that was accepted before must now be refused.
  SELECT string_agg(code,',') INTO v_codes FROM derm._page_geometry_violations('ticket-833530', 1,
    (SELECT jsonb_agg(CASE WHEN (e->>'y1')::numeric = 44.018
                           THEN jsonb_set(e,'{y1}', to_jsonb(54.911::numeric)) ELSE e END)
       FROM jsonb_array_elements(v_pay) e));
  IF v_codes IS NULL OR v_codes NOT LIKE '%G14_SPANS_EXTRA_SLOTS%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the 3-slot band is STILL accepted (codes: %)', COALESCE(v_codes,'<none>');
  END IF;

  -- 2. 🛑 THE NO-WORSE CONTROL. Replaying the page unchanged must still be accepted, or the editor
  --    is now broken on every page. This is the assertion that stops G14 becoming absolute.
  SELECT count(*) INTO v_n FROM derm._page_geometry_violations('ticket-833530', 1, v_pay);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an unchanged replay is now refused (% violations)', v_n;
  END IF;

  -- 3. FLEET no-worse: every all-manual page must still replay clean.
  SELECT count(*) INTO v_n FROM (
    SELECT p.dump_folder, p.pg,
           (SELECT count(*) FROM derm._page_geometry_violations(p.dump_folder, p.pg,
              (SELECT jsonb_agg(jsonb_build_object('row_id', r2.id, 'y0', b2.band_y0_pct, 'y1', b2.band_y1_pct))
                 FROM derm.address_row_map r2 JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                WHERE r2.dump_folder = p.dump_folder AND COALESCE(r2.stamp_page,r2.page) = p.pg
                  AND r2.stamp_y_pct IS NOT NULL AND r2.stamp_placed_at IS NOT NULL))) AS nv
      FROM (SELECT r.dump_folder, COALESCE(r.stamp_page,r.page) AS pg
              FROM derm.address_row_map r
             WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
             GROUP BY 1,2 HAVING count(*) FILTER (WHERE r.band_y0_pct IS NULL) = 0) p
  ) z WHERE z.nv > 0;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % all-manual page(s) can no longer replay; G14 is not no-worse', v_n;
  END IF;

  -- 4. 🛑 G7b BITES. Grow a band across a withheld card's row on window4-sheet1, where the
  --    containment withheld two cards this morning, and require the refusal.
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('window4-sheet1', 1,
      (SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 0.5, 'y1', 99.5))
         FROM derm.address_row_map r
        WHERE r.dump_folder='window4-sheet1' AND COALESCE(r.stamp_page,r.page)=1
          AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL));
  IF v_codes IS NULL OR v_codes NOT LIKE '%G7B_OVERLAPS_WITHHELD%' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a band across a WITHHELD card was accepted (codes: %)', COALESCE(v_codes,'<none>');
  END IF;

  RAISE NOTICE 'VERIFY ok: the 3-slot band is refused, an unchanged replay is still accepted on every all-manual page, and a band across a withheld card is refused.';
END $do$;

COMMIT;
