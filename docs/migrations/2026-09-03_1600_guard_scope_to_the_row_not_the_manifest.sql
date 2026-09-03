-- 2026-09-03_1600_guard_scope_to_the_row_not_the_manifest.sql
--
-- WHY
-- ---
-- `2026-09-03_1510` shipped `trg_zz_page_image_injective` with a header claiming it is **NO-WORSE**:
-- *"only a write that MOVES a card into (or leaves it in) the violating shape is refused"*, and that
-- on `ticket-833049` *"band edits, stamp clears and the eventual repair all have to remain
-- possible."*
--
-- 🛑 THAT CLAIM WAS FALSE FOR INSERTS, AND AN ADVERSARIAL AUDIT OF THE MIGRATION CAUGHT IT.
-- Two defects, one cause:
--   1. the no-worse skip is gated on `IF TG_OP = 'UPDATE'`, so it never applies to an INSERT; and
--   2. the predicate asked *"is this white manifest violating?"* - a question about the FOLDER, not
--      about the write - so ANY insert into an already-violating folder was refused, including a
--      perfectly correct one.
-- Because the trigger is DEFERRABLE INITIALLY DEFERRED the `23514` lands at COMMIT, **outside**
-- `derm._materialize_card`'s `EXCEPTION WHEN unique_violation THEN NULL` handler, so the entire
-- calling transaction aborts with nothing able to catch it.
--
-- Reproduced on live Prod in a rolled-back probe WITH A CONTROL, which is the only reason the
-- result means anything (`SET CONSTRAINTS ALL IMMEDIATE` is required - without it the deferred
-- check never runs inside a transaction that rolls back, and the probe returns a false ACCEPTED,
-- which is exactly what my first attempt did):
--
--     control: delete card 1098 (clean ticket-834742), derm._materialize_card(1777)  -> ACCEPTED
--     case:    delete card  964 (violating ticket-833049), derm._materialize_card(1711)
--              -> REFUSED 23514 "white manifest 833049 would have one image carried by more than
--                 one page (pages {1,2}, image .../derm/1710/address_1.jpg)"
--
-- So re-linking a card on `ticket-833049` - which is precisely what the estate's own
-- `v_blackout_blocked_sheets.what_to_do` and `fn_publishable_hint` texts instruct an operator to do
-- ("re-place that stamp in the Studio") - was broken by a guard whose stated purpose was to leave
-- that folder workable. `ticket-833049` has **10 client documents undelivered since 2026-08-17**;
-- making it harder to repair is the opposite of the intent.
--
-- 🛑 WHY THE ORIGINAL VERIFY DID NOT CATCH IT: all four of its live controls (A-D) exercised the
-- shapes I had in mind - a clean INSERT on a CLEAN folder, a duplicate INSERT on a CLEAN folder, a
-- no-op UPDATE on the violator, a page-move UPDATE on the violator. **Not one of them was a
-- LEGITIMATE INSERT INTO THE VIOLATING FOLDER**, which is the exact cell where the two defects
-- live. Enumerate the COMBINATIONS (operation x folder-state x row-legitimacy), not one cell per
-- variable. The estate already has this lesson written down for trigger guards
-- (`fn_lock_manual_derm_required`, 2026-08-05) and I re-made the mistake.
--
-- THE CORRECTED PREDICATE
-- -----------------------
-- Ask about THE ROW, not the manifest. Inserting `(image I, page P)` can only ever add `P` to `I`'s
-- page-set, so scoping to `NEW.image_url` is COMPLETE as well as narrower. Refuse iff:
--   (a) this row's image is carried by more than one page in this white manifest, AND
--   (b) no OLDER row (`id <`) already carries that same image on that same page -
--       i.e. THIS row is what put its page into the set.
--
-- | case                                                        | (a) | (b) | verdict |
-- |-------------------------------------------------------------|-----|-----|---------|
-- | `_materialize_card` re-link on 833049, (a1, page 1)          | yes | an older (a1,1) exists | ACCEPT |
-- | the original defect, card 1106 (a1, page 2) on 834742        | yes | none               | REFUSE |
-- | clean two-page folder, (b, page 2)                           | no  | -                  | ACCEPT |
-- | third page carrying page 1's image, (a1, page 3)             | yes | none               | REFUSE |
-- | page MOVE on 833049, card 964 page 1 -> 5                    | yes | none               | REFUSE |
-- | a genuinely new third scan at page 3                         | no  | -                  | ACCEPT |
--
-- ⚠ THE `id <` IS LOAD-BEARING AND `id <>` WOULD BE A HOLE. Two sibling rows inserted in the SAME
-- statement at the same (image, page) would each see the other and BOTH pass - the exact shape that
-- corrupted ticket-834742. With `id <` the lower id has no older partner and is refused, so the
-- transaction aborts. The natural key is `(dump_folder, page, row_index)`, so two rows CAN legally
-- share (page, image_url); this is not hypothetical.
-- ⚠ Accepted cost of `id <`: an UPDATE that moves an OLD row onto a pair an even older row already
-- occupies is refused although it is harmless. Rare, deliberate, fail-closed, and it raises a
-- readable hint rather than corrupting anything.
--
-- ⚠ ALSO ADDED: `'pending'` rows now return early. `ticket_page_images` excludes them from its
-- `mode()`, so they can never affect the image list, and the old body only excluded them from the
-- aggregate - a `'pending'` NEW row still paid for a full scan of the manifest.
--
-- 🛑 WHAT THIS DOES NOT CHANGE, AND IT IS THE BIGGER FINDING: the guard defends `page`, and the
-- column that decides which scan a CLIENT'S DOCUMENT is cut from is `stamp_page`
-- (`effective_page = COALESCE(stamp_page, page)` is what `fn_blackout_targets` indexes
-- `imgs[effective_page]` with). `stamp_page` remains unguarded, and `derm.auto_place_page` filters
-- its roster on `page` rather than `COALESCE(stamp_page, page)` - so on ticket-834742, where all
-- ten cards now carry `page = 1` and five carry `stamp_page = 2`, re-placing a page-2 stamp through
-- the Studio silently re-files it against `address_1.jpg`. The audit demonstrated this end to end
-- in a rolled-back probe: two clients lost their document entirely and two had their revealed
-- window widened by up to 2.8 percentage points. **This is PRE-EXISTING** (106 cards across 24
-- folders already have `page <> stamp_page`) and is NOT introduced here, but it is the live hazard
-- on the folder Fred is about to work. It needs its own reviewed migration; do not bolt it on here.
--
-- RULE 8 (audit): one function body replaced. No table, column, trigger or grant changes - the
-- CONSTRAINT TRIGGER `trg_zz_page_image_injective` still points at this same function.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. The corrected predicate. Copied from the live `pg_get_functiondef` and edited in place,
--         never retyped, with every anchor asserted to match exactly once.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_guard_page_image_injective()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_wm text; v_pages integer[];
BEGIN
  v_wm := NEW.white_manifest_number;

  -- Out of scope: derm.ticket_page_images filters `white_manifest_number = p_wm`, which NULL can
  -- never satisfy, so a NULL-white# row cannot corrupt any image list.
  IF v_wm IS NULL THEN RETURN NULL; END IF;

  -- A 'pending' placeholder is excluded from ticket_page_images' mode(), so it cannot corrupt it.
  IF NEW.image_url = 'pending' THEN RETURN NULL; END IF;

  -- 🛑 NO-WORSE, NOT ABSOLUTE. An UPDATE that does not move this row's (white#, page, image_url)
  -- cannot have created or worsened a violation, so it is not this write's business. Without this
  -- skip the guard would freeze every band edit, stamp clear and repair attempt on ticket-833049,
  -- which is a folder a person still has to work on. Same reasoning as derm.save_page_geometry.
  IF TG_OP = 'UPDATE'
     AND NEW.white_manifest_number IS NOT DISTINCT FROM OLD.white_manifest_number
     AND NEW.page                  IS NOT DISTINCT FROM OLD.page
     AND NEW.image_url             IS NOT DISTINCT FROM OLD.image_url
  THEN RETURN NULL; END IF;

  -- 🛑 SCOPED TO THIS ROW'S OWN IMAGE, AND TO WHETHER THIS ROW IS WHAT PUT ITS PAGE IN THAT
  -- IMAGE'S PAGE-SET. The first version asked "is this white manifest violating?", which is a
  -- question about the FOLDER, not about the write - so it refused a perfectly correct INSERT into
  -- a folder that was already violating. Reproduced with a control on 2026-09-03: deleting a card
  -- on ticket-833049 and re-linking it through derm._materialize_card raised 23514, while the same
  -- re-link on a clean folder was accepted. Because the trigger is DEFERRED the refusal lands at
  -- COMMIT, outside _materialize_card's `EXCEPTION WHEN unique_violation` handler, so the whole
  -- filing transaction aborts with nothing to catch it.
  -- Inserting (image I, page P) can only ever add P to I's page-set, so scoping to NEW.image_url
  -- is complete as well as narrower.
  SELECT array_agg(DISTINCT r.page ORDER BY r.page)
    INTO v_pages
    FROM derm.address_row_map r
   WHERE r.white_manifest_number = v_wm
     AND r.image_url = NEW.image_url
     AND r.image_url <> 'pending';

  -- This row's image sits on one page (or none). Nothing to answer for.
  IF coalesce(array_length(v_pages, 1), 0) <= 1 THEN RETURN NULL; END IF;

  -- The image spans pages. Refuse ONLY if THIS row is the one that put its page into that set -
  -- i.e. no OLDER row already carries this image on this page. An existing pair means the split
  -- predates this write, and refusing it would freeze a folder somebody still has to repair.
  -- ⚠ The `id <` (rather than `id <>`) is load-bearing: with `<>`, two sibling rows inserted in
  -- the same statement would each see the other and BOTH pass, which is exactly the shape that
  -- corrupted ticket-834742. With `<`, the lower id has no older partner and is refused.
  IF EXISTS (SELECT 1 FROM derm.address_row_map r2
              WHERE r2.white_manifest_number = v_wm
                AND r2.image_url = NEW.image_url
                AND r2.page = NEW.page
                AND r2.id < NEW.id)
  THEN RETURN NULL; END IF;

  IF TRUE THEN
    RAISE EXCEPTION
      'white manifest % would have one image carried by more than one page (pages %, image %)',
      v_wm, v_pages, NEW.image_url
      USING ERRCODE = '23514',
            HINT = 'derm.ticket_page_images GROUPs BY page and takes mode(image_url), so a second '
                   'page holding an image another page already holds APPENDS a duplicate entry to '
                   'the image list and silently re-points every later stamp ordinal at a different '
                   'scan. `page` is the OCR page: on a folder scanned as one sheet every card '
                   'shares it and only `stamp_page` varies. If you meant "place this stamp on '
                   'image N", set stamp_page, not page. If you are adding a card to a real second '
                   'page, give it that page''s own image (derm.fn_page_image_url).';
  END IF;

  RETURN NULL;
END $function$;


COMMENT ON FUNCTION derm.fn_guard_page_image_injective() IS
  'Constraint trigger: refuses a write that puts this row''s image_url onto a page that image did '
  'not already occupy within the same white_manifest_number. Scoped to the ROW, not the manifest, '
  'so a pre-existing violator stays repairable; deferred to commit.';

-- ---------------------------------------------------------------------------
-- VERIFY. The guard is INITIALLY DEFERRED, so inside this transaction it would only fire at COMMIT
-- and every probe below would return a false ACCEPTED. Make it immediate for the checks.
-- ---------------------------------------------------------------------------
SET CONSTRAINTS ALL IMMEDIATE;

DO $do$
DECLARE
  v_folder text := 'zz-guard-probe2';
  v_wm     text := 'ZZGUARDPROBE2';
  v_a      text := 'https://example.invalid/zz-guard2/a.jpg';
  v_b      text := 'https://example.invalid/zz-guard2/b.jpg';
  a_legit boolean := false;   b_refused boolean := false;
  c_editable boolean := false; d_moved_refused boolean := false;
  e_relink boolean := false;  f_refused boolean := false;
  v_msg text; n int; v_still_violating boolean;
BEGIN
  -- 0. MUTATION CONTROL FOR CASE E. ticket-833049 must STILL satisfy the OLD, manifest-wide
  --    predicate, or E passing below would prove nothing: it could just mean the folder stopped
  --    violating rather than that the predicate was narrowed.
  SELECT EXISTS (
    SELECT 1 FROM derm.address_row_map r
     WHERE r.white_manifest_number = '833049' AND r.image_url <> 'pending'
     GROUP BY r.image_url HAVING count(DISTINCT r.page) > 1)
    INTO v_still_violating;
  IF NOT v_still_violating THEN
    RAISE EXCEPTION 'VERIFY 0: ticket-833049 no longer satisfies the OLD predicate, so CASE E cannot distinguish the fix from a changed world';
  END IF;

  BEGIN
    -- A (must ACCEPT): a GENUINE two-page folder, one image per page. The 17-folder legitimate
    --                  population. If this is refused the guard is unshippable.
    INSERT INTO derm.address_row_map
      (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
    VALUES (v_folder, v_wm, 1, 1, v_a, 'matched', 'high', 'guard-probe'),
           (v_folder, v_wm, 2, 1, v_b, 'matched', 'high', 'guard-probe');
    a_legit := true;

    -- B (must REFUSE): the ticket-834742 shape - a further page carrying an image an earlier page
    --                  already carries.
    BEGIN
      INSERT INTO derm.address_row_map
        (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
      VALUES (v_folder, v_wm, 3, 1, v_a, 'matched', 'high', 'guard-probe');
      b_refused := false;
    EXCEPTION WHEN others THEN v_msg := SQLERRM; b_refused := (SQLERRM LIKE '%more than one page%');
    END;

    -- C (must ACCEPT): the no-worse skip on an UPDATE that moves nothing.
    BEGIN
      UPDATE derm.address_row_map SET confidence = confidence WHERE dump_folder = 'ticket-833049';
      c_editable := true;
    EXCEPTION WHEN others THEN c_editable := false;
    END;

    -- D (must REFUSE): a page MOVE on the violator, onto a page its image does not occupy.
    BEGIN
      UPDATE derm.address_row_map SET page = 3
       WHERE dump_folder = 'ticket-833049' AND id = 964;
      d_moved_refused := false;
    EXCEPTION WHEN others THEN d_moved_refused := (SQLERRM LIKE '%more than one page%');
    END;

    -- E (must ACCEPT) - THE REGRESSION THIS MIGRATION FIXES, AND THE CELL THE ORIGINAL VERIFY
    --   NEVER TESTED: an ordinary re-link INTO the already-violating folder. This is the estate's
    --   own documented recovery action for a withheld card.
    BEGIN
      DELETE FROM derm.address_row_map WHERE id = 964;
      PERFORM derm._materialize_card(1711);
      e_relink := true;
    EXCEPTION WHEN others THEN v_msg := SQLSTATE || ' ' || SQLERRM; e_relink := false;
    END;

    -- F (must REFUSE): ...and the guard is NOT simply dead on that folder. Same folder, but an
    --   insert that genuinely puts address_1 onto a page it does not occupy.
    BEGIN
      INSERT INTO derm.address_row_map
        (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
      SELECT r.dump_folder, r.white_manifest_number, 7, 1, r.image_url, 'matched', 'high', 'guard-probe'
        FROM derm.address_row_map r WHERE r.id = 965;
      f_refused := false;
    EXCEPTION WHEN others THEN f_refused := (SQLERRM LIKE '%more than one page%');
    END;

    RAISE EXCEPTION 'ZZ_GUARD_PROBE2_ROLLBACK';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ZZ_GUARD_PROBE2_ROLLBACK' THEN RAISE; END IF;
  END;

  IF NOT a_legit THEN RAISE EXCEPTION 'VERIFY A: a legitimate two-page folder was REFUSED'; END IF;
  IF NOT b_refused THEN RAISE EXCEPTION 'VERIFY B: the duplicate-image shape was ACCEPTED - the guard is dead'; END IF;
  IF NOT c_editable THEN RAISE EXCEPTION 'VERIFY C: the no-worse UPDATE skip is broken'; END IF;
  IF NOT d_moved_refused THEN RAISE EXCEPTION 'VERIFY D: a page MOVE on the violator was allowed'; END IF;
  IF NOT e_relink THEN
    RAISE EXCEPTION 'VERIFY E: an ordinary re-link into ticket-833049 is STILL refused (%) - the regression is not fixed',
      coalesce(v_msg, 'no error captured');
  END IF;
  IF NOT f_refused THEN
    RAISE EXCEPTION 'VERIFY F: the guard no longer bites on ticket-833049 at all - E passed for the wrong reason';
  END IF;

  -- Nothing survived the rollback.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'zz-guard-probe2' OR white_manifest_number = 'ZZGUARDPROBE2';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY G: % probe row(s) survived', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map WHERE id = 964;
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY G2: card 964 did not come back after the rollback'; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map;
  IF n <> 726 THEN RAISE EXCEPTION 'VERIFY G3: address_row_map holds % rows, expected 726', n; END IF;

  -- The estate is where it should be: exactly one violating manifest, and it is not 834742.
  SELECT count(DISTINCT r.white_manifest_number) INTO n
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.image_url <> 'pending'
     AND EXISTS (SELECT 1 FROM derm.address_row_map r2
                  WHERE r2.white_manifest_number = r.white_manifest_number
                    AND r2.image_url = r.image_url AND r2.image_url <> 'pending'
                    AND r2.page <> r.page);
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY H: % violating white manifest(s), expected exactly 1', n; END IF;

  RAISE NOTICE 'VERIFY ok: the defect shape is still refused, and ticket-833049 is repairable again';
END $do$;

SET CONSTRAINTS ALL DEFERRED;

COMMIT;
