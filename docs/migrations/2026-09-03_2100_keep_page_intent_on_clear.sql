-- 2026-09-03_2100_keep_page_intent_on_clear.sql
--
-- WHY
-- ---
-- Fred, approving decision 2 of `docs/superpowers/specs/2026-09-03-derm-page-integrity-plan.md`:
-- **"Change clear_stamp_position semantics? I recommend yes"** - and decision 3, unblock the stuck
-- clients first and harden second. The clients are unblocked (`_2030`, `_2040`); this is the harden.
--
-- THE DEFECT (hazard H1 in the plan)
-- ----------------------------------
-- `effective_page = COALESCE(stamp_page, page)` is what `derm.fn_blackout_targets` indexes
-- `imgs[effective_page]` with. It decides WHICH SCAN a client's redacted document is cut from.
-- `derm.auto_place_page(folder, page)` rostered on **raw `page`** and wrote `stamp_page = p_page`.
--
-- On a folder scanned as one sheet, `derm._materialize_card` writes `page = 1` for EVERY card, so
-- `page` is a constant, not a locator. **Measured: 23 of 138 folders (193 of 726 cards) are in that
-- state**, and all 106 cards estate-wide with `page <> stamp_page` are a single shape - `page = 1`,
-- `stamp_page` in {2,3,4}.
--
-- Demonstrated end to end in a rolled-back probe on `ticket-834742` before the repair: clearing a
-- page-2 stamp and pressing Auto-place on tab 1 moved the card to page 1 against `address_1.jpg`,
-- the injectivity guard stayed silent (neither `page` nor `image_url` moved), and with the extent in
-- place `fn_blackout_targets` went **10 targets -> 8**: two clients lost their document entirely and
-- two had their revealed window widened by up to 2.8 percentage points.
--
-- 🛑 THE OBVIOUS ONE-LINE FIX IS A NO-OP AND WOULD NOT HAVE PREVENTED THIS. I proposed changing only
-- the roster to `COALESCE(stamp_page, page)`. **Measured: 0 of 23 unplaced cards differ under the two
-- predicates** (control: 23 unplaced cards exist), because `derm.clear_stamp_position` sets
-- `stamp_page = NULL` FIRST. After a clear the COALESCE collapses to `page`, which is the field
-- carrying no information. **The locator is destroyed by the CLEAR, not lost by the predicate.**
-- Both halves therefore ship together, in this one migration; neither works alone.
--
-- WHAT CHANGES
--   1. `derm.clear_stamp_position` stops nulling `stamp_page`. It still clears `stamp_x_pct`,
--      `stamp_y_pct`, `stamp_placed_at`, `stamp_placed_by` and the whole band block.
--   2. `derm.auto_place_page` rosters on `COALESCE(g.stamp_page, g.page)` in BOTH the skipped-count
--      SELECT and the UPDATE. The value it WRITES (`stamp_page = p_page`) is unchanged.
--
-- 🛑 THE RISK THE PLAN FLAGGED, MEASURED AND CLOSED: "a card with a `stamp_page` and no
-- `stamp_placed_at` is a new state, and that is the shape that freezes a folder." **It is not.**
-- Every arm of `derm.v_blackout_blocked_sheets` - `no_stamp_timestamp`, `cards_withheld`,
-- `frozen_closed_world`, `needs_snap_then_extent` - keys on **`stamp_y_pct IS NOT NULL`**, never on
-- `stamp_page`; so does `derm.v_stamp_row_bands`, and therefore so does the closed-world gate in
-- `fn_blackout_targets`. `stamp_y_pct` is still nulled by the clear, so a retained `stamp_page`
-- cannot make a card look placed, cannot withhold a client and cannot freeze a sheet. VERIFY 4
-- asserts the blocked worklist is byte-identical across the change.
--
-- ⚠ THE WITNESS IS STILL CLEARED, AND THAT IS RIGHT. `derm.fn_stamp_witness`'s first branch nulls
-- `stamp_image_url` whenever `stamp_placed_at` is null. So a cleared card keeps the operator's page
-- INTENT and loses the record of where a placed stamp actually sat, which is the correct division:
-- the witness is evidence about a placement, and there is no longer a placement.
--
-- 🛑 THE CLIENT SIDE IS NOT SHIPPED IN THIS CYCLE, AND THE DIVERGENCE IS DELIBERATE AND SAFE.
-- The live Stamp Studio bundle gates its Auto-place button on its own copy of the roster rule:
--     se = l.filter(e => e.page === d);  le = se.filter(e => !e.placed)
-- which is still raw `page`. Until that ships, on a folder where the two disagree:
--   * tab N>1 will say "Nothing to auto-place on this page" even though the server would now offer
--     the card - conservative, nothing is written;
--   * tab 1 will offer the card and the server will place **0** - visible as "Auto-placed 0", and
--     **it no longer mis-files**, which is the whole point.
--   * the folder-wide "Unplaced" drag tray is page-agnostic already, so dragging the card onto the
--     correct page tab still works and writes `set_stamp_position(p_page = <that tab>)` correctly.
-- ⇒ The app change is a follow-up and is recorded in `Building Apps/DERM Stamp Studio/docs/08-changelog.md`.
-- It was NOT bundled here because a person was actively working in that Lovable project while this
-- was written (measured: `app_source='derm-stamp-studio'` writes at 20:27 ET), and rule 13 is one
-- owner per project.
--
-- 🛑 BOTH BODIES WERE COPIED FROM THE LIVE `pg_get_functiondef` AND EDITED IN PLACE, never retyped,
-- with each anchor asserted to match exactly once and the post-conditions asserted against CODE LINES
-- ONLY - a comment mentioning `stamp_page` must not satisfy a check that `stamp_page` is gone.
--
-- RULE 8 (audit): two function bodies replaced. No table, column, trigger, grant or constraint
-- changes. `derm.address_row_map` keeps its existing audit trigger.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. Keep the page intent when the point is cleared.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.clear_stamp_position(p_row_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     -- 🛑 2026-09-03: the null-out of stamp_page was REMOVED from this SET. Clearing the point
     -- must not also destroy WHICH SCAN the operator had chosen: on a folder where every card
     -- shares page = 1, stamp_page is the only thing that says so, and discarding it dropped the
     -- card onto the page-1 tab where auto-place re-filed it against the wrong scan. Every
     -- publishing predicate keys on stamp_y_pct (verified across all four arms of
     -- v_blackout_blocked_sheets and the closed-world gate in fn_blackout_targets), and that is
     -- still nulled here, so a retained stamp_page cannot make a card look placed or block a sheet.
     SET stamp_x_pct = NULL, stamp_y_pct = NULL,
         stamp_placed_at = NULL, stamp_placed_by = NULL,
         -- clearing the point must clear the rectangle: a band with no stamp is invisible to
         -- derm.v_stamp_row_bands and fails the folder's closed-world gate
         band_y0_pct = NULL, band_y1_pct = NULL,
         band_source = NULL, band_set_at = NULL, band_set_by = NULL
   WHERE id = p_row_id;
END $function$;


-- ---------------------------------------------------------------------------
-- PART 2. Roster on the effective page, in both places.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.auto_place_page(p_dump_folder text, p_page integer)
 RETURNS TABLE(placed integer, skipped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_sheet text; v_placed integer := 0; v_skipped integer := 0;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_dump_folder IS NULL OR p_page IS NULL OR p_page < 1 THEN
    RAISE EXCEPTION 'auto-place: bad arguments (folder=%, page=%)', p_dump_folder, p_page;
  END IF;
  SELECT min(white_manifest_number) INTO v_sheet FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_sheet IS NULL THEN RAISE EXCEPTION 'auto-place: unknown sheet %', p_dump_folder; END IF;
  -- 🛑 2026-09-03: the roster keys on the EFFECTIVE page, COALESCE(stamp_page, page), not on
  -- raw `page`. On a folder scanned as one sheet, derm._materialize_card writes page = 1 for every
  -- card, so `page` is a constant and cannot say which scan a card belongs on: 23 of 138 folders
  -- (193 cards) are in that state. Rostering on it offered a page-2 card from the PAGE-1 tab and
  -- re-filed it against page 1's scan. Paired with clear_stamp_position keeping stamp_page, this
  -- reads the operator's page intent instead.
  SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
    FROM derm.v_stamp_rows g
   WHERE g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page AND NOT g.placed;
  UPDATE derm.address_row_map a
     SET stamp_x_pct = round(g.guess_x_pct, 3),
         stamp_y_pct = round(g.guess_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
    FROM derm.v_stamp_rows g
   WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page
     AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
  GET DIAGNOSTICS v_placed = ROW_COUNT;
  RETURN QUERY SELECT v_placed, v_skipped;
END $function$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_before jsonb; v_after jsonb; n int; d text;
  v_id bigint; v_sp int; v_y numeric; v_tab1 int; v_tab2 int;
BEGIN
  -- 0. STATIC: the edits are in the bodies, and the controls prove the bodies were not damaged.
  d := pg_get_functiondef('derm.clear_stamp_position'::regproc);
  IF d ~ 'stamp_page[[:space:]]*=[[:space:]]*NULL' THEN
    RAISE EXCEPTION 'VERIFY 0a: clear_stamp_position still nulls stamp_page';
  END IF;
  IF d !~ 'stamp_placed_at[[:space:]]*=[[:space:]]*NULL' OR d !~ 'band_y0_pct[[:space:]]*=[[:space:]]*NULL'
     OR d !~ '_require_stamp_key' THEN
    RAISE EXCEPTION 'VERIFY 0b: control failed - clear_stamp_position lost the rest of its clear, so the body was damaged';
  END IF;
  d := pg_get_functiondef('derm.auto_place_page'::regproc);
  IF d !~ 'COALESCE\(g.stamp_page, g.page\) = p_page' THEN
    RAISE EXCEPTION 'VERIFY 0c: auto_place_page does not roster on the effective page';
  END IF;
  IF d !~ 'stamp_page  = p_page' OR d !~ 'guess_y_pct' OR d !~ '_require_stamp_key' THEN
    RAISE EXCEPTION 'VERIFY 0d: control failed - auto_place_page lost its write, its guess filter or its key gate';
  END IF;

  -- 1. THE WORKLIST IS UNCHANGED. This is the assertion that closes the flagged risk: if a retained
  --    stamp_page could withhold a client or freeze a sheet, it would show up here.
  SELECT jsonb_agg(jsonb_build_object('f', dump_folder, 'b', blocker, 'c', clients_blocked) ORDER BY dump_folder)
    INTO v_before FROM derm.v_blackout_blocked_sheets;

  -- 2. THE DEMONSTRATED HARM SCENARIO, replayed against the new bodies and rolled back.
  --    ticket-834742 is the case: all 10 cards carry page = 1, five carry stamp_page = 2.
  BEGIN
    SELECT r.id, r.stamp_page, r.stamp_y_pct INTO v_id, v_sp, v_y
      FROM derm.address_row_map r
     WHERE r.dump_folder = 'ticket-834742' AND r.stamp_page = 2
     ORDER BY r.stamp_y_pct LIMIT 1;
    IF v_id IS NULL THEN RAISE EXCEPTION 'VERIFY 2: no page-2 card on ticket-834742 to probe with'; END IF;

    PERFORM derm.clear_stamp_position(v_id);

    -- 2a. THE FIX: the page intent survives the clear, and the placement does not.
    SELECT stamp_page INTO n FROM derm.address_row_map WHERE id = v_id;
    IF n IS DISTINCT FROM 2 THEN
      RAISE EXCEPTION 'VERIFY 2a: stamp_page is % after the clear, expected it to be kept at 2', n;
    END IF;
    SELECT count(*) INTO n FROM derm.address_row_map
     WHERE id = v_id AND (stamp_y_pct IS NOT NULL OR stamp_placed_at IS NOT NULL
                          OR stamp_image_url IS NOT NULL OR band_y0_pct IS NOT NULL);
    IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2b: the clear did not clear the point, the witness or the band'; END IF;

    -- 2c. THE ROSTER NOW OFFERS IT FROM THE RIGHT TAB, AND ONLY FROM THERE.
    SELECT count(*) INTO v_tab1 FROM derm.v_stamp_rows g
     WHERE g.dump_folder = 'ticket-834742' AND COALESCE(g.stamp_page, g.page) = 1 AND NOT g.placed;
    SELECT count(*) INTO v_tab2 FROM derm.v_stamp_rows g
     WHERE g.dump_folder = 'ticket-834742' AND COALESCE(g.stamp_page, g.page) = 2 AND NOT g.placed;
    IF v_tab2 <> 1 THEN RAISE EXCEPTION 'VERIFY 2c: tab 2 offers % unplaced card(s), expected 1', v_tab2; END IF;
    IF v_tab1 <> 0 THEN RAISE EXCEPTION 'VERIFY 2d: tab 1 still offers % card(s) - the harm path is open', v_tab1; END IF;

    -- 2e. MUTATION CONTROL. Under the OLD roster (raw `page`) the same cleared card would have been
    --     offered by tab 1 and not by tab 2. If that is not true, this probe proves nothing.
    SELECT count(*) INTO n FROM derm.v_stamp_rows g
     WHERE g.dump_folder = 'ticket-834742' AND g.page = 1 AND NOT g.placed;
    IF n <> 1 THEN
      RAISE EXCEPTION 'VERIFY 2e: control failed - the OLD predicate offers % cards on tab 1, so the change is untested', n;
    END IF;

    -- 2f. And auto-placing from the WRONG tab now does nothing rather than mis-filing.
    SELECT placed INTO n FROM derm.auto_place_page('ticket-834742', 1);
    IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2f: auto_place_page(folder, 1) placed % card(s) - it still mis-files', n; END IF;

    -- 2g. ...while the right tab does the work.
    SELECT placed INTO n FROM derm.auto_place_page('ticket-834742', 2);
    IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 2g: auto_place_page(folder, 2) placed %, expected 1', n; END IF;
    SELECT stamp_page INTO n FROM derm.address_row_map WHERE id = v_id;
    IF n <> 2 THEN RAISE EXCEPTION 'VERIFY 2h: the re-placed card landed on stamp_page %, expected 2', n; END IF;

    RAISE EXCEPTION 'ZZ_H1_PROBE_ROLLBACK';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ZZ_H1_PROBE_ROLLBACK' THEN RAISE; END IF;
  END;

  -- 3. The probe left nothing behind.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834742' AND (stamp_placed_at IS NULL OR stamp_image_url IS NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % card(s) on ticket-834742 did not come back from the probe', n; END IF;

  -- 4. THE WORKLIST IS BYTE-IDENTICAL. Nothing became blocked or unblocked by this change.
  SELECT jsonb_agg(jsonb_build_object('f', dump_folder, 'b', blocker, 'c', clients_blocked) ORDER BY dump_folder)
    INTO v_after FROM derm.v_blackout_blocked_sheets;
  IF v_before IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'VERIFY 4: the blocked worklist changed: % -> %', v_before, v_after;
  END IF;

  RAISE NOTICE 'VERIFY ok: the clear keeps the page intent, the roster reads it, the wrong tab places 0, and the worklist is unchanged';
END $do$;

COMMIT;

-- ---------------------------------------------------------------------------
-- ROLLBACK: re-apply the two previous bodies from git (commit before this one), i.e. restore
--   clear_stamp_position's `stamp_page = NULL` and auto_place_page's two `g.page = p_page` rosters.
-- ---------------------------------------------------------------------------
