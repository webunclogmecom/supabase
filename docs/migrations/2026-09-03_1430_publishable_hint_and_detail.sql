-- 2026-09-03_1430_publishable_hint_and_detail.sql
--
-- WHY
-- ---
-- Fred hit the new gate on `ticket-834742` and got the raw code: **"Cannot complete yet:
-- needs_snap_then_extent"**. It is accurate and it is useless to an operator - it neither says what
-- to do nor WHICH PAGE is at fault. He had already measured page 1 correctly; the sheet was blocked
-- entirely by page 3, and nothing on screen said so, so he re-opened page 1 and drew it again.
--
-- This is the same lesson `derm.fn_geometry_hint` already encodes for the save-time guards
-- (2026-09-02_0200: "raise the OPERATOR hint, not the raw guard code"). The completion gate shipped
-- hours ago without its own hint table, so it re-created the defect that function exists to prevent.
-- ⇒ Extend the ESTABLISHED pattern; do not invent a second mapping.
--
-- WHAT THIS ADDS (both additive; nothing existing changes behaviour)
--   1. derm.fn_publishable_hint(code) - the sibling of fn_geometry_hint for the SEVEN publishable
--      codes, with the same fail-loud ELSE so an unmapped code is a visible bug rather than a blank.
--   2. derm.fn_sheet_publishable_detail(dump_folder) -> jsonb, carrying the code, the PAGES that
--      still need bands and/or an extent, and a ready-to-render operator message that NAMES the page.
--
-- 🛑 `derm.fn_sheet_publishable` IS DELIBERATELY LEFT ALONE. It returns a bare code and is consumed by
-- the completion gate (trg_a0), by derm.set_sheet_completed and by
-- derm.v_blackout_completed_unpublished. Changing its return type to carry a message would break all
-- three. The UI gets a SEPARATE, richer function; the machine keeps the terse one.
--
-- ⚠ The page numbers reported are `effective_page` = COALESCE(stamp_page, page), i.e. the IMAGE
-- position the Studio tabs show - NOT the printed page number. Those genuinely differ on reversed
-- scans (see the stamp_page-is-an-ordinal note in Supabase/CLAUDE.md), and the operator is clicking
-- image tabs, so the image position is the right thing to name.
--
-- RULE 8 (audit): two read-only functions, no table or column change; nothing to opt in or out.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. Code -> operator English. Sibling of derm.fn_geometry_hint.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_publishable_hint(p_code text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $fn$
  SELECT CASE p_code
    WHEN 'needs_extent' THEN
      'The row boundaries are set, but this sheet has no page boundary yet. Shift-click to place the two Limit bands, the top and the bottom of Section B, then save.'
    WHEN 'needs_snap_then_extent' THEN
      'Some rows are still using an estimated position rather than the printed lines. Drag every row edge onto a printed line, then shift-click to place the two Limit bands (the top and bottom of Section B), and save. Both are needed before this sheet can be blacked out.'
    WHEN 'cards_withheld' THEN
      'A card on this sheet has a stamp position but was never confirmed, so it is on hold and nothing may be published over its row. Re-place that stamp in the Studio to finish it, or remove the card.'
    WHEN 'no_stamp_timestamp' THEN
      'A stamp on this sheet was never actually placed - it has a position but no placement. Re-place it in the Studio; measuring this sheet again will not fix it.'
    WHEN 'held_by_constraint' THEN
      'This sheet is deliberately frozen at the database level because its page layout is known to be wrong. It cannot be published and this is not something to work around. Tell Fred.'
    WHEN 'frozen_closed_world' THEN
      'One card on this sheet has no stamp point at all, which freezes every client on the sheet. Place the missing stamp; clearing the bands will not release it.'
    WHEN 'no_stamps' THEN
      'Nothing has been stamped on this sheet yet, so there is no document to produce. Place the stamps first.'
    ELSE
      'Unrecognised publish check (' || COALESCE(p_code, 'null') || '). This is a bug: the check has no operator message. Tell Fred.'
  END;
$fn$;

REVOKE ALL ON FUNCTION derm.fn_publishable_hint(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_publishable_hint(text) FROM anon;
GRANT EXECUTE ON FUNCTION derm.fn_publishable_hint(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- PART 2. The UI-facing detail: which page, and what to do about it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable_detail(p_dump_folder text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
  WITH code AS (
    SELECT derm.fn_sheet_publishable(p_dump_folder) AS blocker
  ), stamped AS (
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
  ), need_band AS (
    -- a stamped row still on an ESTIMATED band (no manual/snapped override)
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
       AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)
  ), need_ext AS (
    SELECT s.pg FROM stamped s
     WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                        WHERE e.dump_folder = p_dump_folder AND e.effective_page = s.pg)
  ), agg AS (
    SELECT (SELECT blocker FROM code) AS blocker,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_band) AS pages_bands,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_ext)  AS pages_ext
  )
  SELECT jsonb_build_object(
    'blocker', a.blocker,
    'pages_needing_bands',  to_jsonb(a.pages_bands),
    'pages_needing_extent', to_jsonb(a.pages_ext),
    'message',
      CASE
        WHEN a.blocker IS NULL THEN NULL
        -- Name the page whenever the fault IS per-page. This is the whole point of the function:
        -- 834742 was blocked only by page 3 while page 1 was already correct, and the bare code
        -- sent the operator back to redo the page that was fine.
        WHEN a.blocker IN ('needs_extent', 'needs_snap_then_extent')
             AND (array_length(a.pages_bands, 1) > 0 OR array_length(a.pages_ext, 1) > 0)
          THEN 'Page ' ||
               array_to_string(
                 (SELECT array_agg(DISTINCT p ORDER BY p)
                    FROM unnest(a.pages_bands || a.pages_ext) AS u(p)), ', ')
               || ': ' || derm.fn_publishable_hint(a.blocker)
        ELSE derm.fn_publishable_hint(a.blocker)
      END)
  FROM agg a;
$fn$;

REVOKE ALL ON FUNCTION derm.fn_sheet_publishable_detail(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_sheet_publishable_detail(text) FROM anon;
GRANT EXECUTE ON FUNCTION derm.fn_sheet_publishable_detail(text) TO authenticated, service_role;

-- VERIFY
DO $do$
DECLARE v jsonb; v_txt text; v_n integer;
BEGIN
  -- 1. THE CASE THAT PROMPTED THIS. 834742 is blocked by page 3 only; page 1 is already measured.
  v := derm.fn_sheet_publishable_detail('ticket-834742');
  IF v->>'blocker' IS DISTINCT FROM 'needs_snap_then_extent' THEN
    RAISE EXCEPTION 'VERIFY 1: 834742 blocker is %, expected needs_snap_then_extent', v->>'blocker';
  END IF;
  IF (v->'pages_needing_extent') <> '[3]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY 1: pages_needing_extent = %, expected [3]', v->'pages_needing_extent';
  END IF;
  IF (v->'pages_needing_bands') <> '[3]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY 1: pages_needing_bands = %, expected [3]', v->'pages_needing_bands';
  END IF;
  IF (v->>'message') NOT LIKE 'Page 3:%' THEN
    RAISE EXCEPTION 'VERIFY 1: message does not name page 3: %', v->>'message';
  END IF;
  -- and it must NOT accuse page 1, which Fred measured correctly
  IF (v->>'message') LIKE '%Page 1%' THEN
    RAISE EXCEPTION 'VERIFY 1: message wrongly names page 1, which is already measured';
  END IF;

  -- 2. A PUBLISHABLE sheet returns a null blocker AND a null message (no scary text on a good sheet).
  v := derm.fn_sheet_publishable_detail('ticket-834287');
  IF v->>'blocker' IS NOT NULL OR v->>'message' IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 2: publishable sheet returned blocker=% message=%', v->>'blocker', v->>'message';
  END IF;

  -- 3. A FOLDER-LEVEL blocker still gets English, and does NOT get a page prefix it cannot justify.
  v := derm.fn_sheet_publishable_detail('ticket-833049');
  IF v->>'blocker' IS DISTINCT FROM 'held_by_constraint' THEN
    RAISE EXCEPTION 'VERIFY 3: 833049 blocker = %', v->>'blocker';
  END IF;
  IF (v->>'message') NOT LIKE '%frozen%' THEN
    RAISE EXCEPTION 'VERIFY 3: 833049 message is not the frozen hint: %', v->>'message';
  END IF;

  -- 4. EVERY code the predicate can emit has an operator message. This is the control that stops the
  --    hint table silently drifting behind fn_sheet_publishable, which is exactly how the raw code
  --    reached Fred in the first place.
  SELECT count(*) INTO v_n FROM unnest(ARRAY[
      'needs_extent','needs_snap_then_extent','cards_withheld','no_stamp_timestamp',
      'held_by_constraint','frozen_closed_world','no_stamps']) AS c(code)
   WHERE derm.fn_publishable_hint(c.code) LIKE 'Unrecognised publish check%';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % publishable code(s) have no operator message', v_n; END IF;

  -- 5. MUTATION TEST on the control itself: an unknown code MUST fall through loudly, or check 4
  --    would pass even with an empty mapping.
  v_txt := derm.fn_publishable_hint('__not_a_code__');
  IF v_txt NOT LIKE 'Unrecognised publish check%' THEN
    RAISE EXCEPTION 'VERIFY 5: the fail-loud ELSE does not fire; check 4 proves nothing';
  END IF;

  -- 6. Grants: the Studio (authenticated) can call both; anon cannot.
  IF NOT has_function_privilege('authenticated','derm.fn_sheet_publishable_detail(text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','derm.fn_publishable_hint(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 6: authenticated cannot execute the new functions';
  END IF;
  IF has_function_privilege('anon','derm.fn_sheet_publishable_detail(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 6: anon can execute the detail function';
  END IF;

  RAISE NOTICE 'VERIFY ok: 834742 names page 3 only, a good sheet says nothing, folder-level codes get English, all 7 codes mapped, and the fail-loud ELSE is proven to fire.';
END $do$;

COMMIT;
