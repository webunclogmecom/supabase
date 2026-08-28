-- 2026-08-28_1720_g8_semantic_message_and_subpixel_tolerance.sql
--
-- WHY: THE GUARD BLOCKED A REAL OPERATOR OVER 0.04 OF A PIXEL, AND COULD NOT SAY WHO IT WAS ABOUT.
-- ---------------------------------------------------------------------------
-- Fred, setting the page boundary on ticket-312433:
--
--     G8_NOT_CONTAINED: extent 25.401..62.634 does not contain the bands 25.399..62.634
--
-- and asked: "can't you put something more semantic like 'Top Boundary doesn't contains the band
-- 195-MYK Main'?"
--
-- He is right twice over, and the second problem is the one he did not ask about.
--
-- 1. THE MESSAGE NAMED NOBODY. It emitted a single aggregate row built from min(y0)/max(y1). It
--    does not say which edge is wrong, which client is uncovered, or which way to move. G8 now
--    emits ONE ROW PER OFFENDING CLIENT, naming the edge, the client code, its GDO nickname and
--    the distance to move.
--
-- 2. THE COMPARISON WAS EXACT, SO IT FIRED ON 0.002pp. The redactor renders the black boxes with
--    round(H * pct / 100) - INTEGER PIXELS. A difference under one pixel cannot change a single
--    byte of the served document. Measured on the live fleet:
--        smallest scan   485px tall  ->  1px = 0.2062pp
--        typical scan   ~2200px tall ->  1px = 0.045pp
--        Fred's case     0.002pp     =  0.04 of a pixel
--    The new tolerance is 0.05pp: about one pixel at typical size, a quarter of a pixel at worst.
--    This is not a relaxation of the guard. It is refusing to measure what the renderer cannot
--    express.
--
-- 🛑 THE TOLERANCE DOES NOT EXCUSE THE REAL CASES, AND THEY ARE REAL. Measured 2026-08-28 across
-- the 166 pages carrying an extent, 55 violate containment TODAY and every one of them is SERVING:
--        under 1px    11
--        >= 2px       39
--        >= 5px       30
--        >= 10px      19
--        worst        43.4px  (ticket-308792 p1, 1.885pp on a 2304px scan)
-- Text on these scans is 15-25px tall, and the confirmed 2026-08-19 cross-client leak was 1.665pp.
-- All 54 with a top-side shortfall have MANUALLY SNAPPED top bands, so these are measured
-- positions and not heuristic guesses. Those pages stay flagged and are NOT addressed here: they
-- need a person to open the served documents, the same adjudication the 2026-08-23/24 band review
-- used. Nothing in this migration changes what any page publishes.
--
-- ⚠ The NO-WORSE arm is preserved exactly: a submission whose extent is byte-identical to the
-- stored one is never flagged, so an operator fixing one client's band on a page that already
-- violates containment is not forced to fix the whole page first.
--
-- 🛑 BODY COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT. One anchor, asserted to match
-- exactly once; G9, G11, G13 and G7B are untouched bytes.
--
-- RULE 8 (audit trail): a pure function, no state. Opt-out.

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
    -- 🛑 G8 REWRITTEN 2026-08-28. Two changes, both driven by a real operator blocking on it.
    --
    -- 1. SEMANTIC MESSAGE. It used to emit ONE aggregate row reading
    --      "extent 25.401..62.634 does not contain the bands 25.399..62.634"
    --    which names no client, no edge, and no action. Fred hit exactly that and asked for
    --    "Top Boundary doesn't contain the band 195-MYK Main". It now emits one row PER offending
    --    client, naming the edge, the client, its nickname and how far to move.
    --
    -- 2. A SUB-PIXEL TOLERANCE. The comparison was exact, so it fired on 0.002pp. The redactor
    --    renders with round(H * pct / 100), i.e. INTEGER PIXELS, so a difference smaller than a
    --    pixel cannot change a single byte of the output. Measured: the smallest scan in the fleet
    --    is 485px tall, where 1px = 0.2062pp; a typical scan is ~2200px, where 1px = 0.045pp. The
    --    0.05pp tolerance is therefore about one pixel at typical size and a quarter of a pixel at
    --    the worst. It is not a relaxation of the guard, it is refusing to measure what the
    --    renderer cannot express.
    --    ⚠ It does NOT excuse the real cases. Of the 55 pages that violate containment today,
    --    39 are 2px or worse, 30 are 5px or worse, 19 are 10px or worse and the worst is 43.4px
    --    on ticket-308792 p1. Text on these scans is 15-25px tall. Those stay flagged.
    RETURN QUERY
      WITH b AS (
        SELECT (e->>'row_id')::bigint AS id,
               round((e->>'y0')::numeric,3) AS y0, round((e->>'y1')::numeric,3) AS y1
          FROM jsonb_array_elements(p_bands) e
      ),
      lbl AS (
        SELECT b.*,
               coalesce(c.client_code, 'row ' || b.id::text) AS who,
               coalesce(g.nickname, g.location_label, g.gdo_number) AS nick
          FROM b
          LEFT JOIN derm.address_row_map r ON r.id = b.id
          LEFT JOIN public.clients c ON c.id = r.matched_client_id
          LEFT JOIN public.gdos g ON g.id = r.gdo_id
      ),
      cur AS (SELECT e.top_pct, e.bottom_pct FROM derm.page_block_extents e
               WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page),
      unchanged AS (SELECT EXISTS (SELECT 1 FROM cur
                     WHERE cur.top_pct = p_top_pct AND cur.bottom_pct = p_bottom_pct) AS same)
      SELECT 'G8_NOT_CONTAINED',
             format('The TOP page boundary (%s) sits below %s, whose row starts at %s. '
                    || 'Move the top boundary up by at least %spp so the black box covers that row.',
                    p_top_pct,
                    lbl.who || coalesce(' - ' || lbl.nick, ''),
                    lbl.y0, round(p_top_pct - lbl.y0, 3))
        FROM lbl, unchanged
       WHERE NOT unchanged.same
         AND p_top_pct - lbl.y0 > 0.05
      UNION ALL
      SELECT 'G8_NOT_CONTAINED',
             format('The BOTTOM page boundary (%s) sits above %s, whose row ends at %s. '
                    || 'Move the bottom boundary down by at least %spp so the black box covers that row.',
                    p_bottom_pct,
                    lbl.who || coalesce(' - ' || lbl.nick, ''),
                    lbl.y1, round(lbl.y1 - p_bottom_pct, 3))
        FROM lbl, unchanged
       WHERE NOT unchanged.same
         AND lbl.y1 - p_bottom_pct > 0.05;

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
DECLARE
  v_bands  jsonb;
  v_n      integer;
  v_msg    text;
  v_top    numeric;
  v_minb   numeric;
  v_maxb   numeric;
  v_def    text;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id,
           'y0', round(vb.band_y0_pct,3), 'y1', round(vb.band_y1_pct,3))),
         min(round(vb.band_y0_pct,3)), max(round(vb.band_y1_pct,3))
    INTO v_bands, v_minb, v_maxb
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
   WHERE r.dump_folder = 'ticket-312433' AND coalesce(r.stamp_page, r.page) = 1
     AND r.stamp_placed_at IS NOT NULL;

  IF v_bands IS NULL THEN
    RAISE EXCEPTION 'VERIFY setup FAILED: no placed bands on ticket-312433 p1';
  END IF;

  -- 1. FRED'S EXACT CASE. A top boundary 0.002pp below the topmost band must NO LONGER flag.
  v_top := v_minb + 0.002;
  SELECT count(*) INTO v_n FROM derm._page_geometry_violations(
    'ticket-312433', 1, v_bands, v_top, 99.0) WHERE code = 'G8_NOT_CONTAINED';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: 0.002pp still blocks';
  END IF;

  -- 2. 🛑 THE CONTROL. A REAL overshoot must STILL flag, or test 1 proves only that G8 is dead.
  v_top := v_minb + 1.0;
  SELECT count(*) INTO v_n FROM derm._page_geometry_violations(
    'ticket-312433', 1, v_bands, v_top, 99.0) WHERE code = 'G8_NOT_CONTAINED';
  IF v_n = 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a 1.0pp overshoot was accepted; the guard is dead';
  END IF;

  -- 3. THE MESSAGE IS SEMANTIC: edge, client code, and what to do.
  SELECT detail INTO v_msg FROM derm._page_geometry_violations(
    'ticket-312433', 1, v_bands, v_top, 99.0) WHERE code = 'G8_NOT_CONTAINED' LIMIT 1;
  IF v_msg NOT LIKE '%TOP page boundary%' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: message does not name the edge: %', v_msg;
  END IF;
  IF v_msg !~ '[0-9]{3}-[A-Z]' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: message does not name a client code: %', v_msg;
  END IF;
  IF v_msg NOT LIKE '%Move the top boundary up%' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: message does not say what to do: %', v_msg;
  END IF;
  RAISE NOTICE 'sample TOP message: %', v_msg;

  -- 4. The BOTTOM edge produces its own distinct message.
  SELECT detail INTO v_msg FROM derm._page_geometry_violations(
    'ticket-312433', 1, v_bands, 0.0, v_maxb - 1.0)
   WHERE code = 'G8_NOT_CONTAINED' LIMIT 1;
  IF v_msg IS NULL OR v_msg NOT LIKE '%BOTTOM page boundary%' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: bottom edge message missing or wrong: %', coalesce(v_msg,'NULL');
  END IF;
  RAISE NOTICE 'sample BOTTOM message: %', v_msg;

  -- 5. ONE ROW PER OFFENDING CLIENT, not one aggregate row.
  SELECT count(*) INTO v_n FROM derm._page_geometry_violations(
    'ticket-312433', 1, v_bands, v_minb + 12.0, 99.0) WHERE code = 'G8_NOT_CONTAINED';
  IF v_n < 2 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: expected one row per uncovered client, got %', v_n;
  END IF;

  -- 6. 🛑 THE NO-WORSE ARM SURVIVES on the worst page in the fleet, and is not a blanket exemption.
  IF EXISTS (SELECT 1 FROM derm.page_block_extents
              WHERE dump_folder = 'ticket-308792' AND effective_page = 1) THEN
    DECLARE
      v_b2 jsonb; v_t numeric; v_bo numeric;
    BEGIN
      SELECT jsonb_agg(jsonb_build_object('row_id', r.id,
               'y0', round(vb.band_y0_pct,3), 'y1', round(vb.band_y1_pct,3)))
        INTO v_b2
        FROM derm.address_row_map r JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
       WHERE r.dump_folder = 'ticket-308792' AND coalesce(r.stamp_page, r.page) = 1
         AND r.stamp_placed_at IS NOT NULL;
      SELECT top_pct, bottom_pct INTO v_t, v_bo FROM derm.page_block_extents
       WHERE dump_folder = 'ticket-308792' AND effective_page = 1;
      IF v_b2 IS NOT NULL THEN
        SELECT count(*) INTO v_n FROM derm._page_geometry_violations('ticket-308792',1,v_b2,v_t,v_bo)
         WHERE code = 'G8_NOT_CONTAINED';
        IF v_n <> 0 THEN
          RAISE EXCEPTION 'VERIFY 6 FAILED: replaying the stored extent verbatim now flags (% rows)', v_n;
        END IF;
        SELECT count(*) INTO v_n FROM derm._page_geometry_violations('ticket-308792',1,v_b2,v_t + 1.0,v_bo)
         WHERE code = 'G8_NOT_CONTAINED';
        IF v_n = 0 THEN
          RAISE EXCEPTION 'VERIFY 6 FAILED: no-worse became a blanket exemption';
        END IF;
      END IF;
    END;
  END IF;

  -- 7. Every sibling guard survived the splice.
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = '_page_geometry_violations';
  IF position('G9_OFF_RULE' in v_def) = 0 OR position('G11' in v_def) = 0
     OR position('G13' in v_def) = 0 OR position('G7B_OVERLAPS_WITHHELD' in v_def) = 0 THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: a sibling guard was lost in the splice';
  END IF;

  RAISE NOTICE 'VERIFY ok: 0.002pp no longer blocks, 1.0pp still does, messages name the edge and '
    'the client, one row per client, the no-worse arm holds, all sibling guards survive.';
END $do$;

COMMIT;
