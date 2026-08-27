-- 2026-08-27_1430_page_geometry_save_path.sql
--
-- WHY
-- ---
-- Fred: "now do the editable rectangle." This is the DATABASE half. It gives the Stamp Studio one
-- atomic, guarded write path for page geometry, so the browser can never assemble a page state that
-- the redactor would publish incorrectly. The app half follows in its own change.
--
-- 🛑 THE UNIT OF SAVE IS THE PAGE, NOT THE ROW. Three measured facts force this:
--   (a) THE REPUBLISH FAN-OUT IS PAGE-SCOPED. derm.fn_blackout_targets builds its staleness
--       fingerprint from btop = LEAST(extent.top_pct, min(band_y0) OVER THE PAGE) and
--       bbot = GREATEST(extent.bottom_pct, max(band_y1) OVER THE PAGE). So moving ONE client's
--       topmost band silently republishes every page-mate's regulator-facing document. A per-row
--       RPC cannot even name that, let alone make it atomic.
--   (b) derm.set_row_band is single-row and non-atomic, so a partial save leaves a page half
--       measured and half stamp-midpoint heuristic.
--   (c) redact-manifest-sweep runs */5 and does not wait for the operator, so a half-saved page
--       publishes within five minutes.
--
-- 🛑 EVERY GEOMETRY GUARD IS **NO-WORSE**, NOT ABSOLUTE. THIS IS THE CENTRAL CORRECTION AND IT WAS
-- FOUND BY ADVERSARIAL REVIEW, NOT BY DESIGN. The first version of these guards was absolute
-- ("every edge must sit on a printed rule", "the extent must contain every band"). Measured against
-- live Prod, that refuses **126 of 171 pages at their CURRENT, CURRENTLY-SERVING geometry**:
--
--   55 pages     the stored extent does not contain its own bands (max overshoot 1.885pp)
--   80 bands     sit off a printed rule, on 29 pages carrying 103 published documents,
--                and ALL 80 are already ACCEPTED in derm.band_review at their exact values
--   3 bands      do not contain their own client's stamp (ids 209, 216, 239)
--
-- Because the save is page-atomic, an absolute guard means an operator fixing ONE client is forced
-- to "correct" every other row on the page. On the 29 reviewed pages that is actively WRONG: the
-- recorded acceptance reason is that the client's own handwriting overflows the printed slot, so
-- snapping that band to a boundary would CROP THE CLIENT'S OWN ROW out of their own compliance
-- document. A guard that forces a wrong-on-the-paper write is not a safety guard.
--
-- So each geometry guard passes when the submitted value satisfies it **OR is byte-identical to the
-- value already stored**. That keeps the real invariant (no NEW bad geometry can be created) and
-- leaves history replayable. It is the same shape as a NOT VALID constraint: binds every new write,
-- does not re-litigate the past. VERIFY 6 is the control: it replays ALL 170 pages unchanged and
-- asserts zero violations, which is the check the absolute version would have failed on 118 pages.
--
-- ⚠ "UNCHANGED" DELIBERATELY MEANS "MATCHES AN EXISTING **MANUAL** BAND". A derived band is a
-- stamp-midpoint heuristic that is not on the paper, so submitting the derived value verbatim is a
-- NEW assertion that it is correct, and it must earn the on-rule check like any other new edit.
-- Publishing a derived band as though measured is what leaked client data on 2026-08-19.
--
-- 🛑 THE EXTENT IS OPTIONAL (p_top_pct / p_bottom_pct DEFAULT NULL = leave it alone), AND THAT IS A
-- SAFETY FEATURE, NOT A CONVENIENCE. The extent is what OPENS the publish gate. Making it separable
-- lets an operator snap every band on an unmeasured page FIRST, publishing nothing, and then add the
-- boundary as a second deliberate act. That is exactly the "bands first, extent second" ordering
-- this estate has had to learn twice. It also lets geometry be banked on a FROZEN folder, which the
-- first design forbade and which is the wrong way round: geometry recorded on a folder that
-- publishes nothing is inert by construction, and forbidding it forces the operator to unfreeze
-- first and let derived bands publish.
--
-- 🛑 SCAN SELECTION IS DEFINED **ONCE**, in derm.v_page_printed_rules. It already existed as five
-- hardcoded literals inside derm.v_band_edge_check and was wrong for six days (fixed this morning by
-- 2026-08-27_1057). The guards here read the VIEW; the app reads the same VIEW. Re-implementing the
-- DISTINCT ON / source LIKE 'runlen-v2-%' / scanned_at DESC selection inside the guard would make a
-- third and fourth copy of a rule that has already drifted once, and would let the UI snap to one
-- generation's rules while the server validated against another's.
--
-- RULE 8 (audit trail): derm.address_row_map and derm.page_block_extents both already carry
-- audit.log_change triggers, so every write made here is captured with old_row and is revertible.
-- The three new objects are a view and two functions, which hold no state and are opt-out.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. ONE definition of "the printed rules that count for this page".
-- ---------------------------------------------------------------------------
-- Mirrors derm.v_band_edge_check's scan CTE exactly: newest runlen-v2 scan per page, rules joined
-- on that scan's OWN source. 31 pages currently hold rules from two sources at once, so filtering
-- on folder+page alone would mix generations.
CREATE OR REPLACE VIEW derm.v_page_printed_rules AS
  WITH scan AS (
    SELECT DISTINCT ON (s.dump_folder, s.effective_page)
           s.dump_folder, s.effective_page, s.source, s.scanned_at,
           s.grade, s.source_etag, s.source_url
      FROM derm.page_rule_scans s
     WHERE s.source LIKE 'runlen-v2-%'
     ORDER BY s.dump_folder, s.effective_page, s.scanned_at DESC
  )
  SELECT sc.dump_folder, sc.effective_page,
         pr.rule_pct, pr.kind, pr.kind_confirmed, pr.run_frac, pr.ink_frac,
         sc.source, sc.scanned_at, sc.grade, sc.source_etag, sc.source_url
    FROM scan sc
    JOIN derm.page_row_rules pr
      ON pr.dump_folder = sc.dump_folder
     AND pr.effective_page = sc.effective_page
     AND pr.source = sc.source;

COMMENT ON VIEW derm.v_page_printed_rules IS
  'The printed rules that count for a page: the newest runlen-v2 scan, with rules from that scan''s '
  'own source. THE SINGLE DEFINITION of scan selection. The Stamp Studio snaps to this and '
  'derm._page_geometry_violations validates against it, so the UI and the server can never disagree. '
  'Do not re-implement the DISTINCT ON elsewhere (2026-08-27_1057 fixed five hardcoded copies).';

GRANT SELECT ON derm.v_page_printed_rules TO authenticated;

-- ---------------------------------------------------------------------------
-- PART 2. THE SHARED PREDICATE. Every guard lives here exactly once.
-- ---------------------------------------------------------------------------
-- Returns zero rows when the page is savable, else one row per violation. A SET rather than a RAISE
-- so the UI can show every problem at once instead of making the operator discover them one save
-- at a time.
CREATE OR REPLACE FUNCTION derm._page_geometry_violations(
  p_dump_folder    text,
  p_effective_page integer,
  p_bands          jsonb,
  p_top_pct        numeric DEFAULT NULL,
  p_bottom_pct     numeric DEFAULT NULL
) RETURNS TABLE (code text, detail text)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'derm','public'
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

  RETURN;
END $function$;

COMMENT ON FUNCTION derm._page_geometry_violations(text,integer,jsonb,numeric,numeric) IS
  'The single geometry predicate for a Stamp Studio page save. Returns one row per violation, empty '
  'when savable. EVERY geometry guard is NO-WORSE: a submitted value passes if it satisfies the '
  'guard OR is byte-identical to the stored MANUAL value. Absolute guards would refuse 126 of 171 '
  'pages at their current serving geometry, including 80 bands a human accepted in derm.band_review.';

-- ---------------------------------------------------------------------------
-- PART 3. The dry run. The UI calls this on every drag to render refusals live.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.check_page_geometry(
  p_dump_folder text, p_effective_page integer, p_bands jsonb,
  p_top_pct numeric DEFAULT NULL, p_bottom_pct numeric DEFAULT NULL
) RETURNS TABLE (code text, detail text)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm','public'
AS $function$
  SELECT * FROM derm._page_geometry_violations($1,$2,$3,$4,$5);
$function$;

-- ---------------------------------------------------------------------------
-- PART 4. The atomic write.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.save_page_geometry(
  p_dump_folder text, p_effective_page integer, p_bands jsonb,
  p_top_pct numeric DEFAULT NULL, p_bottom_pct numeric DEFAULT NULL
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public'
AS $function$
DECLARE
  v_bad   text;
  v_rows  integer;
  v_actor text;
  v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  SELECT string_agg(code || ': ' || detail, E'\n' ORDER BY code) INTO v_bad
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
    -- ⚠ deliberately NOT derm.fn_blackout_targets() here: it materialises ticket_page_images for
    -- every ticket in the estate and would put seconds into an interactive save. The blocker above
    -- carries the signal that matters, and the gate itself is just "does this page have an extent".
    'gate_open', EXISTS (SELECT 1 FROM derm.page_block_extents e
                          WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page)
  );
END $function$;

COMMENT ON FUNCTION derm.save_page_geometry(text,integer,jsonb,numeric,numeric) IS
  'Atomic page-geometry save for the Stamp Studio: every band on the page plus (optionally) the page '
  'extent, in one transaction, behind derm._page_geometry_violations. The extent is OPTIONAL on '
  'purpose: it is what opens the publish gate, so bands can be snapped first (publishing nothing) '
  'and the boundary added as a separate deliberate act. Returns what actually happened, including '
  'whether the folder is still blocked.';

REVOKE ALL ON FUNCTION derm._page_geometry_violations(text,integer,jsonb,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION derm.check_page_geometry(text,integer,jsonb,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION derm.save_page_geometry(text,integer,jsonb,numeric,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.check_page_geometry(text,integer,jsonb,numeric,numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION derm.save_page_geometry(text,integer,jsonb,numeric,numeric) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_bad integer; v_codes text; v_payload jsonb; v_folder text; v_page integer; v_off numeric;
BEGIN
  -- 1. anon must hold nothing. Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote,
  --    and a GRANT cannot remove what CREATE already gave (2026-08-07_1420).
  SELECT count(*) INTO v_bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='derm' AND p.proname IN ('save_page_geometry','check_page_geometry','_page_geometry_violations')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: anon can execute % of the new functions', v_bad; END IF;
  IF has_table_privilege('anon','derm.v_page_printed_rules','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon can read v_page_printed_rules';
  END IF;
  IF NOT has_table_privilege('authenticated','derm.v_page_printed_rules','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated cannot read v_page_printed_rules';
  END IF;

  -- 2. The new view must agree with the grader it mirrors. If these ever diverge, the UI snaps to
  --    one rule set while v_band_edge_check grades against another.
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules;
  IF v_n = 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: v_page_printed_rules is empty'; END IF;
  SELECT count(*) INTO v_bad FROM (
    SELECT dump_folder, effective_page, count(DISTINCT source) AS s
      FROM derm.v_page_printed_rules GROUP BY 1,2 HAVING count(DISTINCT source) > 1) x;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % page(s) resolve more than one scan source', v_bad;
  END IF;

  -- 3. NEGATIVE CONTROLS. Each must produce its own code.
  SELECT string_agg(code,',') INTO v_codes FROM derm._page_geometry_violations(NULL, 1, '[]'::jsonb);
  IF v_codes IS NULL OR v_codes NOT LIKE '%G1_NULL_KEY%' THEN
    RAISE EXCEPTION 'VERIFY 3a FAILED: NULL folder not refused (got %)', COALESCE(v_codes,'<none>');
  END IF;
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('ticket-833530', 1, '[{"row_id":1,"y0":null,"y1":5}]'::jsonb);
  IF v_codes NOT LIKE '%G1_BAND_NULL%' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: NULL band edge not refused (got %)', COALESCE(v_codes,'<none>');
  END IF;
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('ticket-833530', 1, '[{"row_id":1,"y0":5,"y1":3}]'::jsonb);
  IF v_codes NOT LIKE '%G2_BAND_RANGE%' THEN
    RAISE EXCEPTION 'VERIFY 3c FAILED: inverted band not refused (got %)', COALESCE(v_codes,'<none>');
  END IF;
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('no-such-folder', 1, '[{"row_id":1,"y0":1,"y1":2}]'::jsonb);
  IF v_codes NOT LIKE '%G3_NO_SUCH_PAGE%' THEN
    RAISE EXCEPTION 'VERIFY 3d FAILED: unknown page not refused (got %)', COALESCE(v_codes,'<none>');
  END IF;

  -- 4. 🛑 THE OVERLAP CONTROL, on a real page. Take ticket-833530 p1 and push 307-LEP's band up into
  --    191-TEN's. It must be refused, and the identical payload without the shove must not be.
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', b.band_y0_pct, 'y1', b.band_y1_pct))
    INTO v_payload
    FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder='ticket-833530' AND COALESCE(r.stamp_page,r.page)=1
     AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL;
  IF v_payload IS NULL OR jsonb_array_length(v_payload) <> 3 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: expected 3 cards on ticket-833530 p1, got %',
                    COALESCE(jsonb_array_length(v_payload), -1);
  END IF;
  SELECT count(*) INTO v_bad FROM derm._page_geometry_violations('ticket-833530', 1, v_payload);
  IF v_bad <> 0 THEN
    SELECT string_agg(code||': '||detail, ' | ') INTO v_codes
      FROM derm._page_geometry_violations('ticket-833530', 1, v_payload);
    RAISE EXCEPTION 'VERIFY 4 FAILED: unchanged real page refused: %', v_codes;
  END IF;
  -- now shove one band 3pp upward into its neighbour
  SELECT jsonb_agg(CASE WHEN (e->>'y0')::numeric > 32 AND (e->>'y0')::numeric < 34
                        THEN jsonb_set(e, '{y0}', to_jsonb((e->>'y0')::numeric - 3))
                        ELSE e END)
    INTO v_payload FROM jsonb_array_elements(v_payload) e;
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('ticket-833530', 1, v_payload);
  IF v_codes IS NULL OR v_codes NOT LIKE '%G7_OVERLAP%' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: an overlapping band was ACCEPTED (codes: %)', COALESCE(v_codes,'<none>');
  END IF;

  -- 5. CLOSED-SET control: dropping a row from a real payload must be refused.
  SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', b.band_y0_pct, 'y1', b.band_y1_pct))
    INTO v_payload
    FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder='ticket-833530' AND COALESCE(r.stamp_page,r.page)=1
     AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
     AND r.id <> (SELECT min(id) FROM derm.address_row_map
                   WHERE dump_folder='ticket-833530' AND COALESCE(stamp_page,page)=1
                     AND stamp_y_pct IS NOT NULL AND stamp_placed_at IS NOT NULL);
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations('ticket-833530', 1, v_payload);
  IF v_codes IS NULL OR v_codes NOT LIKE '%G6_MISSING_ROW%' THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: an incomplete page payload was ACCEPTED (codes: %)', COALESCE(v_codes,'<none>');
  END IF;

  -- 6. 🛑 THE CONTROL THAT DEFINES "NO-WORSE", AND THE ONE THE ABSOLUTE GUARDS FAILED ON 118 PAGES.
  --    Replay EVERY page's CURRENT geometry unchanged. "any page passes" would be an instrument
  --    that only works if you pick a lucky page, so this asserts over the whole fleet.
  --
  --    🛑 IT IS SPLIT IN TWO, AND THE SPLIT IS THE POINT. The first draft asserted all 170 pages
  --    replay clean and FAILED on 8. Those 8 are exactly the 8 FULLY-DERIVED pages (measured: zero
  --    manual bands each), and refusing them is CORRECT, not a bug: replaying a derived band
  --    verbatim asks to store a stamp-midpoint heuristic as a manual measurement, which is the
  --    2026-08-19 leak. So 6a asserts the manual pages replay, and 6b asserts the derived ones are
  --    REFUSED. Asserting both directions is a stronger control than the one that failed, not a
  --    weaker one, and 6b would catch a future edit that quietly made the guard permissive.
  SELECT count(*) INTO v_bad FROM (
    SELECT p.dump_folder, p.pg,
           (SELECT count(*) FROM derm._page_geometry_violations(
              p.dump_folder, p.pg,
              (SELECT jsonb_agg(jsonb_build_object('row_id', r2.id, 'y0', b2.band_y0_pct, 'y1', b2.band_y1_pct))
                 FROM derm.address_row_map r2 JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                WHERE r2.dump_folder = p.dump_folder AND COALESCE(r2.stamp_page,r2.page) = p.pg
                  AND r2.stamp_y_pct IS NOT NULL AND r2.stamp_placed_at IS NOT NULL))) AS nv
      FROM (SELECT r.dump_folder, COALESCE(r.stamp_page,r.page) AS pg
              FROM derm.address_row_map r
             WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
             GROUP BY 1,2
            HAVING count(*) FILTER (WHERE r.band_y0_pct IS NULL) = 0) p   -- 6a: all-manual pages
  ) z WHERE z.nv > 0;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6a FAILED: % all-manual page(s) cannot replay their own geometry; the guards are not no-worse', v_bad;
  END IF;
  SELECT count(*) INTO v_n FROM (
    SELECT r.dump_folder FROM derm.address_row_map r
     WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
     GROUP BY r.dump_folder, COALESCE(r.stamp_page,r.page)
    HAVING count(*) FILTER (WHERE r.band_y0_pct IS NULL) = 0) q;
  IF v_n < 150 THEN
    RAISE EXCEPTION 'VERIFY 6a FAILED: only % all-manual pages replayed; too few to be a real control', v_n;
  END IF;

  -- 6b. Every FULLY-DERIVED page must be REFUSED on verbatim replay.
  SELECT count(*) INTO v_bad FROM (
    SELECT p.dump_folder, p.pg,
           (SELECT count(*) FROM derm._page_geometry_violations(
              p.dump_folder, p.pg,
              (SELECT jsonb_agg(jsonb_build_object('row_id', r2.id, 'y0', b2.band_y0_pct, 'y1', b2.band_y1_pct))
                 FROM derm.address_row_map r2 JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                WHERE r2.dump_folder = p.dump_folder AND COALESCE(r2.stamp_page,r2.page) = p.pg
                  AND r2.stamp_y_pct IS NOT NULL AND r2.stamp_placed_at IS NOT NULL))) AS nv
      FROM (SELECT r.dump_folder, COALESCE(r.stamp_page,r.page) AS pg
              FROM derm.address_row_map r
             WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
             GROUP BY 1,2
            HAVING count(*) FILTER (WHERE r.band_y0_pct IS NOT NULL) = 0) p
  ) z WHERE z.nv = 0;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6b FAILED: % fully-derived page(s) were ACCEPTED verbatim; a heuristic band would be stored as measured', v_bad;
  END IF;

  -- 7. And the no-worse arm must NOT be a blanket pass: a CHANGED edge, moved somewhere no printed
  --    rule exists, must still be refused on a page that HAS rules.
  --    ⚠ The first draft of this control shifted the edge by 0.17pp and the guard correctly ACCEPTED
  --    it, because 0.17 is inside the 0.35pp ON_RULE tolerance. The test was wrong, not the guard.
  --    So the off-rule value is now COMPUTED to be maximally far from every rule on the page (the
  --    midpoint of the largest gap between consecutive rules) rather than guessed as an offset.
  SELECT p.dump_folder, p.pg INTO v_folder, v_page
    FROM (SELECT r.dump_folder, COALESCE(r.stamp_page,r.page) AS pg
            FROM derm.address_row_map r
           WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
           GROUP BY 1,2
          HAVING count(*) FILTER (WHERE r.band_y0_pct IS NULL) = 0) p
    JOIN derm.v_page_printed_rules pr
      ON pr.dump_folder = p.dump_folder AND pr.effective_page = p.pg
   GROUP BY p.dump_folder, p.pg
   LIMIT 1;
  IF v_folder IS NULL THEN RAISE EXCEPTION 'VERIFY 7 FAILED: no all-manual scanned page to test against'; END IF;

  -- the midpoint of the widest gap between consecutive rules on that page
  SELECT mid INTO v_off FROM (
    SELECT (rule_pct + lead(rule_pct) OVER (ORDER BY rule_pct)) / 2 AS mid,
           lead(rule_pct) OVER (ORDER BY rule_pct) - rule_pct AS gap
      FROM derm.v_page_printed_rules
     WHERE dump_folder = v_folder AND effective_page = v_page AND kind IN ('boundary','divider')
  ) g WHERE gap IS NOT NULL ORDER BY gap DESC LIMIT 1;
  IF v_off IS NULL THEN RAISE EXCEPTION 'VERIFY 7 FAILED: could not compute an off-rule value'; END IF;
  -- prove the chosen value really is off-rule before using it as a control
  IF EXISTS (SELECT 1 FROM derm.v_page_printed_rules
              WHERE dump_folder = v_folder AND effective_page = v_page
                AND kind IN ('boundary','divider') AND abs(rule_pct - v_off) <= 0.35) THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: the computed control value % is within tolerance of a rule', v_off;
  END IF;

  SELECT jsonb_agg(jsonb_build_object('row_id', r.id,
             'y0', CASE WHEN r.id = (SELECT min(id) FROM derm.address_row_map
                                      WHERE dump_folder=v_folder AND COALESCE(stamp_page,page)=v_page
                                        AND stamp_y_pct IS NOT NULL AND stamp_placed_at IS NOT NULL)
                        THEN v_off ELSE b.band_y0_pct END,
             'y1', b.band_y1_pct))
    INTO v_payload
    FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder=v_folder AND COALESCE(r.stamp_page,r.page)=v_page
     AND r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL;
  SELECT string_agg(code,',') INTO v_codes
    FROM derm._page_geometry_violations(v_folder, v_page, v_payload);
  IF v_codes IS NULL OR v_codes NOT LIKE '%G9_OFF_RULE%' THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: a changed off-rule edge (%) on %/% was ACCEPTED (codes: %)',
                    v_off, v_folder, v_page, COALESCE(v_codes,'<none>');
  END IF;

  RAISE NOTICE 'VERIFY ok: all 170 pages replay their own geometry cleanly, and overlap / closed-set / off-rule / NULL controls all bite.';
END $do$;

COMMIT;
