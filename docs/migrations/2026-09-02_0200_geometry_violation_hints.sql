-- 2026-09-02_0200_geometry_violation_hints.sql
--
-- WHAT: the page-geometry guards stop shouting developer codes at operators, and one missing
--       precondition stops multiplying into one error per band edge.
--         1. NEW derm.fn_geometry_hint(code) -> an operator sentence for every guard.
--         2. derm._page_geometry_violations gains a PRECONDITION arm: a page with no detected
--            printed rules yields ONE G9_NOT_MEASURED instead of one G9_OFF_RULE per edge.
--         3. derm.check_page_geometry returns (code, detail, HINT).
--         4. derm.save_page_geometry raises the HINT, with code and detail kept in brackets.
--
-- WHY:  Fred, 2026-09-02, on the DERM Stamp Studio: "why so many errors with the bands", and
--       "we need to solve the root cause, so it doesn t happen again". Two live examples:
--
--       ticket-834489 (handwritten pad sheet 344): both cards UNPLACED, so p_bands is empty and
--       the operator got "G1_BANDS_SHAPE: p_bands must be a non-empty JSON array". Nothing on a
--       pad sheet auto-places, so EVERY fresh pad sheet opens in exactly that state.
--
--       ticket-834433 (generated sheet 1106): 3 of 3 placed, bands set BY HAND, and six red lines,
--       every one "G9_OFF_RULE ... (nearest no rules for this page)". That page has ZERO rows in
--       derm.page_row_rules: the detector found 14 rules / 7 boundaries and
--       fn_validate_page_rules REJECTED the set ("a phase flip at chain position 13"), and a
--       rejected scan writes nothing. So G9 NOT EXISTS was true for every changed edge.
--       SIX ERRORS, ONE CAUSE, and none of them told the operator what to do.
--
-- ROOT CAUSE, both halves:
--   (a) the guards ran without checking their own preconditions, so one absent input became N
--       per-item failures that read like operator mistakes;
--   (b) there was no operator vocabulary. _page_geometry_violations returns (code, detail), both
--       written for a developer, and the Stamp Studio bundle maps exactly ONE of the 16 codes
--       (G9_OFF_RULE). Measured over the live bundle: 15 of 16 codes appear 0 times, so whatever
--       the server returns is printed verbatim to a person.
--
-- WHY THE HINT LIVES IN THE DATABASE AND NOT IN THE APP. That 1-of-16 is the whole argument. The
--   codes are raised here and the mapping lived over there, so every guard added since shipped
--   without operator text and nobody noticed. Putting the sentence next to the guard means a new
--   code cannot reach a person as a bare token: the ELSE arm of fn_geometry_hint is loud, and
--   VERIFY 3 fails this migration if any code the function can emit has no hint.
--
-- THE FUNCTION BODIES WERE COPIED, NOT RETYPED. _page_geometry_violations is 20,098 characters and
--   CREATE OR REPLACE takes the WHOLE body, so anything not reproduced is silently deleted. Both
--   bodies were extracted with pg_get_functiondef into scripts/probes/geom/*.before.sql, edited by
--   anchored replacement (each anchor asserted to match exactly once) in
--   scripts/probes/geom/build_migration.py, and diffed. The violations diff is TWO insertions and
--   nothing else; the save diff is one changed line plus a comment.
--
-- NOT IN SCOPE, deliberately:
--   * The CLASSIFIER phase flip that produced the FAILED scan on ticket-834433 is the upstream
--     cause and is NOT fixed here. It is a known, documented limitation (the end-bar trim strips
--     only LONG bars, so a page whose outermost rule at each end is SHORT inverts every label
--     below it; ticket-312024 p1 hit it first). Fixing the trim means re-validating all 168
--     already-measured pages, so it is its own piece of work with its own spec.
--   * Snap-to-rule while dragging in the Studio is an app change, not a database one. Today an
--     operator must land a freehand drag within 0.35pp of an invisible line, on every edge.
--
-- RULE 8 (audit): NO TABLE CHANGES AT ALL. Functions only, so no opt-in or opt-out arises.
-- RULE 2/3: no columns, no storage, nothing derived or copied.

BEGIN;

-- ============================================================================
-- 1. The operator vocabulary, next to the guards that raise it.
-- ============================================================================
CREATE OR REPLACE FUNCTION derm.fn_geometry_hint(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE p_code
    WHEN 'G1_NULL_KEY' THEN
      'Something went wrong identifying this page. Reload the sheet and try again.'
    WHEN 'G1_BANDS_SHAPE' THEN
      'Place the stamps first. Row boundaries describe where each client sits on the sheet, so there is nothing to save until at least one card is placed.'
    WHEN 'G1_BAND_NULL' THEN
      'One of the rows has no top or bottom edge yet. Drag both edges of every row before saving.'
    WHEN 'G1_DUP_ROW' THEN
      'The same client row was sent twice. Reload the sheet and set the boundaries again.'
    WHEN 'G1_HALF_EXTENT' THEN
      'Set both the top and the bottom page boundary, or neither. One on its own cannot be saved.'
    WHEN 'G2_EXTENT_RANGE' THEN
      'A page boundary is off the sheet. Both boundaries must sit inside the page.'
    WHEN 'G2_BAND_RANGE' THEN
      'A row edge is off the sheet. Every edge must sit inside the page.'
    WHEN 'G3_NO_SUCH_PAGE' THEN
      'No stamp has been placed on this page yet, so there is no geometry to save. Place the stamps first.'
    WHEN 'G6_MISSING_ROW' THEN
      'A client on this page was left out. Every client printed on the page needs its own row boundaries.'
    WHEN 'G6_FOREIGN_ROW' THEN
      'A row that does not belong to this page was included. Reload the sheet and try again.'
    WHEN 'G7_OVERLAP' THEN
      'Two clients overlap. Each client needs its own strip with no shared space, or one client would be shown part of another row.'
    WHEN 'G8_NOT_CONTAINED' THEN
      'A page boundary cuts through a client row. Move the boundary so every row sits fully inside it.'
    WHEN 'G9_NOT_MEASURED' THEN
      'This page has not been measured yet, so there are no printed lines to check the edges against. Press "Re-measure printed lines" first. If measuring keeps failing on this sheet, it needs a person to look at it.'
    WHEN 'G9_OFF_RULE' THEN
      'A row edge is not sitting on one of the printed lines on the sheet. Drag it onto the nearest printed line: an edge between the lines can cut a client'' own text in half.'
    WHEN 'G11_ROSTER_NOT_COVERED' THEN
      'The page boundaries do not cover the whole printed list. Any printed line left outside them would be shown to the client.'
    WHEN 'G13_STAMP_OUTSIDE_BAND' THEN
      'A client'' stamp is outside the strip you gave it. The stamp marks that client'' own row, so the strip must contain it.'
    WHEN 'G14_SPANS_EXTRA_SLOTS' THEN
      'A client'' strip covers more printed rows than that client owns. If the client really has several permits on this sheet, it needs one card per permit.'
    ELSE
      'Unrecognised geometry check (' || COALESCE(p_code, 'null') || '). This is a bug: the check has no operator message. Tell Fred.'
  END;
$fn$;

COMMENT ON FUNCTION derm.fn_geometry_hint(text) IS
  'Operator-facing sentence for each derm._page_geometry_violations code. Lives beside the guards on purpose: the Stamp Studio previously mapped 1 of 16 codes and printed the rest raw, because the mapping was in the app while the codes were here. The ELSE arm is deliberately loud so a new code without a hint is visible rather than silent.';

REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_geometry_hint(text) FROM anon;
-- No grant is needed: every caller (check_page_geometry, save_page_geometry) is SECURITY DEFINER
-- and runs as the owner. Supabase default privileges hand new functions to anon and authenticated,
-- so the revokes above are the actual control, not the absence of a GRANT.

-- ============================================================================
-- 2. The precondition arm. Body copied from pg_get_functiondef, edited by anchor, diffed.
-- ============================================================================
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
  -- ðŸ›‘ This is what makes atomicity mean anything: without it a page can be saved with one card
  -- still on a derived band under a fresh extent, which is the 2026-08-19 shape.
  -- âš  WITHHELD cards (stamp point present, stamp_placed_at NULL) are EXCLUDED, because they cannot
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
  -- âš  TOUCHING IS LEGAL (a.y1 = b.y0): 145 manual pairs touch exactly and Fred's mockup is
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
  -- âš  "unchanged" means it matches an existing MANUAL band. A derived band made manual is a NEW
  -- assertion and must earn the check.
  -- âš  Accepts kind IN ('boundary','divider'): both are lines printed on the paper, which is the
  -- real invariant, and it matches v_band_edge_check's edge_verdict exactly. Boundary-only would
  -- refuse the halved-row sheets, where the writer fits 8 clients on a 6-slot form and the correct
  -- edges ARE mid-slot dividers (8 live serving bands at 2.300-2.820pp).
  ----------------------------------------------------------------------------
  -- PRECONDITION, added 2026-09-02. If this page has NO detected printed rules, every changed
  -- edge fails the NOT EXISTS below, so one unmeasured page produced one error PER EDGE, each
  -- reading "nearest no rules for this page". Six red lines for one missing input, and none of
  -- them actionable. Emit the precondition ONCE instead, and let every other guard still run:
  -- overlap, containment and stamp-in-band do not need rules and stay useful.
  IF NOT EXISTS (
    SELECT 1 FROM derm.v_page_printed_rules pr
     WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
       AND pr.kind IN ('boundary','divider')
  ) THEN
    RETURN QUERY SELECT 'G9_NOT_MEASURED',
      format('no printed rules are on record for %s page %s, so band edges cannot be checked against the sheet',
             p_dump_folder, p_effective_page);
  ELSE
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
  END IF;

  ----------------------------------------------------------------------------
  -- G13 OWN STAMP IN OWN BAND. NO-WORSE. Without it, a tiling shifted by one whole slot satisfies
  -- G7, G8 and G9 simultaneously (a snapped edge is on a rule whichever slot it bounds) and every
  -- client is served their neighbour's row. The stamp is the one thing that ties a band to the
  -- client who owns it, because a person put it on that client's printed row.
  -- âš  3 live bands already fail this (ids 209, 216, 239) and 2 are accepted in derm.band_review as
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
  -- ðŸ›‘ G11 exists because containment ALONE does not bind the extent to the printed roster: an
  -- extent equal to the band envelope satisfies G8 and leaves every EMPTY printed slot outside the
  -- black box, which is exactly the 2026-08-03_0046 leak. The lower bound must come from the RULES.
  ----------------------------------------------------------------------------
  IF p_top_pct IS NOT NULL THEN
    -- ðŸ›‘ G8 REWRITTEN 2026-08-28. Two changes, both driven by a real operator blocking on it.
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
    --    âš  It does NOT excuse the real cases. Of the 55 pages that violate containment today,
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
  -- G14 SLOT COVERAGE. ðŸ›‘ THE HALF THAT WAS MISSING, AND IT IS A LEAK PATH THROUGH A BUTTON.
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
  -- âš  NO-WORSE, like every other geometry guard: only a CHANGED band is checked. 80 accepted
  -- off-rule bands and the halved-row sheets are untouched, and replaying a page unchanged still
  -- costs nothing.
  -- âš  expected_slots is computed exactly as derm.v_band_edge_check computes it, through
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

-- ============================================================================
-- 3. check_page_geometry gains the hint. The return type changes, so this is DROP + CREATE, which
--    DISCARDS GRANTS: they are restored immediately below and asserted in VERIFY 4.
-- ============================================================================
DROP FUNCTION IF EXISTS derm.check_page_geometry(text, integer, jsonb, numeric, numeric);

CREATE FUNCTION derm.check_page_geometry(
  p_dump_folder text, p_effective_page integer, p_bands jsonb,
  p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
RETURNS TABLE(code text, detail text, hint text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
  SELECT v.code, v.detail, derm.fn_geometry_hint(v.code)
    FROM derm._page_geometry_violations($1,$2,$3,$4,$5) v;
$function$;

REVOKE ALL ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric)
  TO authenticated, service_role;

-- ============================================================================
-- 4. save_page_geometry raises the hint. Body copied, one line changed, diffed.
-- ============================================================================
CREATE OR REPLACE FUNCTION derm.save_page_geometry(p_dump_folder text, p_effective_page integer, p_bands jsonb, p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_bad   text;
  v_rows  integer;
  v_actor text;
  v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  -- 2026-09-02: raise the OPERATOR hint, not the raw guard code. This line used to emit
  -- "G1_BANDS_SHAPE: p_bands must be a non-empty JSON array" straight to a person in the
  -- Studio. The code and detail are kept in brackets so support can still identify the guard.

  SELECT string_agg(derm.fn_geometry_hint(code) || '  [' || code || ': ' || detail || ']', E'\n' ORDER BY code) INTO v_bad
    FROM derm._page_geometry_violations(p_dump_folder, p_effective_page, p_bands, p_top_pct, p_bottom_pct);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION E'page geometry refused:\n%', v_bad;
  END IF;

  v_actor := derm._actor('stamp-studio');

  UPDATE derm.address_row_map r
     SET band_y0_pct = round((e->>'y0')::numeric, 3),
         band_y1_pct = round((e->>'y1')::numeric, 3),
         band_source = 'manual', band_set_at = now(), band_set_by = v_actor
    FROM jsonb_array_elements(p_bands) e
   WHERE r.id = (e->>'row_id')::bigint
     -- do not write a row whose value did not move: a no-op UPDATE would re-stale the blackout
     -- fingerprint and republish a customer document for nothing.
     AND (r.band_y0_pct IS DISTINCT FROM round((e->>'y0')::numeric, 3)
       OR r.band_y1_pct IS DISTINCT FROM round((e->>'y1')::numeric, 3));
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF p_top_pct IS NOT NULL THEN
    INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
    VALUES (p_dump_folder, p_effective_page, round(p_top_pct,3), round(p_bottom_pct,3),
            'stamp-studio:' || v_actor, now())
    ON CONFLICT (dump_folder, effective_page) DO UPDATE
       SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
           source = EXCLUDED.source, measured_at = EXCLUDED.measured_at
     WHERE derm.page_block_extents.top_pct IS DISTINCT FROM EXCLUDED.top_pct
        OR derm.page_block_extents.bottom_pct IS DISTINCT FROM EXCLUDED.bottom_pct;
  END IF;

  -- Tell the caller the truth about what happens next, rather than just "ok". A folder can be
  -- perfectly measured and still publish nothing, and the operator must be able to see that.
  SELECT blocker INTO v_block FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder = p_dump_folder LIMIT 1;

  RETURN jsonb_build_object(
    'saved_bands', v_rows,
    'extent_written', (p_top_pct IS NOT NULL),
    'folder_still_blocked_by', v_block,
    -- âš  deliberately NOT derm.fn_blackout_targets() here: it materialises ticket_page_images for
    -- every ticket in the estate and would put seconds into an interactive save. The blocker above
    -- carries the signal that matters, and the gate itself is just "does this page have an extent".
    'gate_open', EXISTS (SELECT 1 FROM derm.page_block_extents e
                          WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page)
  );
END $function$;

DO $$
DECLARE
  v_n int; v_hint text; v_authn boolean; v_anon boolean; v_svc boolean; v_code text;
  v_bands433 jsonb; v_bands287 jsonb;
  v_codes text[] := ARRAY['G1_NULL_KEY','G1_BANDS_SHAPE','G1_BAND_NULL','G1_DUP_ROW','G1_HALF_EXTENT',
    'G2_EXTENT_RANGE','G2_BAND_RANGE','G3_NO_SUCH_PAGE','G6_MISSING_ROW','G6_FOREIGN_ROW','G7_OVERLAP',
    'G8_NOT_CONTAINED','G9_NOT_MEASURED','G9_OFF_RULE','G11_ROSTER_NOT_COVERED','G13_STAMP_OUTSIDE_BAND',
    'G14_SPANS_EXTRA_SLOTS'];
BEGIN
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 24.0, 'y1', 32.0))
    INTO v_bands433
    FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834433';

  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', 11.111, 'y1', 22.222))
    INTO v_bands287
    FROM derm.address_row_map r WHERE r.dump_folder = 'ticket-834287';

  -- 1. THE REPORTED DEFECT. ticket-834433 page 1 has NO detected rules and 3 placed cards, and it
  --    used to emit one G9_OFF_RULE per changed edge. It must now emit exactly one G9_NOT_MEASURED
  --    and no G9_OFF_RULE at all.
  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands433)
   WHERE code = 'G9_OFF_RULE';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: ticket-834433 still emits % G9_OFF_RULE row(s) on an unmeasured page', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834433', 1, v_bands433)
   WHERE code = 'G9_NOT_MEASURED';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 1b FAILED: expected exactly 1 G9_NOT_MEASURED on ticket-834433, got %', v_n;
  END IF;

  -- 2. CONTROL, and it is the one that matters. A page that IS measured must STILL get the real
  --    per-edge check. A precondition arm that swallowed G9 entirely would sail through VERIFY 1
  --    while disabling the guard that stops a band cutting through a client row.
  --    ticket-834287 has detected rules; 11.111..22.222 is deliberately off every one of them.
  SELECT count(*) INTO v_n
    FROM derm._page_geometry_violations('ticket-834287', 1, v_bands287)
   WHERE code = 'G9_OFF_RULE';
  IF v_n < 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a MEASURED page no longer reports G9_OFF_RULE for a deliberately off-rule edge. The guard has been disabled, which is worse than the bug being fixed.';
  END IF;

  -- 3. every code the function can emit has a real hint, and the fallback is still loud
  FOREACH v_code IN ARRAY v_codes LOOP
    v_hint := derm.fn_geometry_hint(v_code);
    IF v_hint IS NULL OR v_hint LIKE 'Unrecognised geometry check%' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: code % has no operator hint', v_code;
    END IF;
  END LOOP;
  IF derm.fn_geometry_hint('G99_MADE_UP') NOT LIKE 'Unrecognised geometry check%' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: the ELSE arm is not loud, so a new code would leak silently';
  END IF;

  -- 4. grants survived DROP + CREATE, and anon acquired nothing
  SELECT has_function_privilege('authenticated','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE'),
         has_function_privilege('anon','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE'),
         has_function_privilege('service_role','derm.check_page_geometry(text,integer,jsonb,numeric,numeric)','EXECUTE')
    INTO v_authn, v_anon, v_svc;
  IF NOT v_authn OR NOT v_svc OR v_anon THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: check_page_geometry grants are authn=% anon=% svc=%', v_authn, v_anon, v_svc;
  END IF;
  IF has_function_privilege('anon','derm.fn_geometry_hint(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 4b FAILED: anon can execute fn_geometry_hint';
  END IF;

  -- 5. the wrapper really returns three columns and the hint is the operator sentence
  SELECT hint INTO v_hint FROM derm.check_page_geometry('ticket-834489', 1, '[]'::jsonb) LIMIT 1;
  IF v_hint IS NULL OR v_hint NOT LIKE 'Place the stamps first%' THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: check_page_geometry hint for an empty payload was %', COALESCE(v_hint,'NULL');
  END IF;

  RAISE NOTICE 'OK: precondition arm live, 17 codes hinted, grants intact, wrapper serves the hint.';
END $$;

COMMIT;
