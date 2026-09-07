-- ============================================================================================
-- 2026-09-07_1730_unfreeze_ticket_833049.sql
--
-- Drop derm.page_block_extents' folder-specific freeze, so ticket-833049's 10 clients can finally
-- be served. Nothing is published by this migration: it only removes the block.
--
-- WHY (Fred, 2026-09-07): "yes remove the freeze".
--
-- 🛑 THE CONSTRAINT'S PREMISE HAS EXPIRED, AND THAT IS THE ONLY REASON THIS IS SAFE.
-- 2026-08-19_2355 PART 5 installed CHECK (dump_folder <> 'ticket-833049') because the folder's
-- page map was CORRUPT: derm.ticket_page_images emitted [address_1, address_1, address_2], so five
-- clients' redactions would have been cut from a page they are not printed on. Writing an extent
-- there would have DOUBLED the exposure rather than fixing it, which is why the note in CLAUDE.md
-- says do not drop it to "unblock" the folder. That note was correct when it was written.
--
-- It was repaired on 2026-09-03 (2026-09-03_1500, page 2 -> 1 with the stamp witness reconciled)
-- and the general defect behind it now has a REAL structural guard, trg_zz_page_image_injective
-- (2026-09-03_1510), which refuses the shape estate-wide at COMMIT. A folder-name CHECK is a
-- stopgap for a hole that is now closed properly, so it is the stopgap that goes, not the guard.
--
-- ⚠ WHAT THIS DOES NOT DO, deliberately. It writes NO extent. An extent is what opens the publish
-- gate, and every band in this folder is still DERIVED (a stamp-midpoint heuristic, not measured
-- from the paper). Adding an extent over derived bands IS the 2026-08-19 leak. The bands and the
-- extent must be written TOGETHER by derm.save_page_geometry, from lines a person drew on the scan,
-- which is what the Stamp Studio "Draw the bands" flow does. Fred does that; not this file.
--
-- ⚠ Page 2 of this folder has NO printed rules on record at all. It stays unpublishable after this
-- migration and the ordinary guards enforce that (G9_NOT_MEASURED refuses any band edit there),
-- so no new protection is needed for it and none is added.
--
-- RULE 8: no column change. derm.page_block_extents keeps its audit trigger
-- (audit_page_block_extents, added 2026-08-27). Dropping a CHECK is not an audited event, so
-- PART 0 below is the record of the state this was done in.
-- ============================================================================================

BEGIN;

-- ============================================================================================
-- PART 0. PRECONDITIONS. This migration REFUSES TO APPLY unless the corruption is still gone.
-- The whole safety argument is "the page map is correct now", so it is measured here rather than
-- asserted in prose. If anything has regressed, this aborts and the constraint stays.
-- ============================================================================================
DO $pre$
DECLARE
  v_imgs  text[];
  v_n     int;
  v_got   text[];
  v_want  text[];
  v_sheet text;
  v_pos   int;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 0.1 The image list is exactly two DISTINCT scans. A repeated entry is the corruption that
  --     froze this folder: two effective_pages resolving to the same physical scan.
  ------------------------------------------------------------------------------------------
  v_imgs := derm.ticket_page_images('833049');
  IF v_imgs IS NULL OR array_length(v_imgs, 1) <> 2 THEN
    RAISE EXCEPTION 'PRE 0.1: ticket_page_images(833049) has % entries, expected 2',
      coalesce(array_length(v_imgs, 1), 0);
  END IF;
  IF v_imgs[1] = v_imgs[2] THEN
    RAISE EXCEPTION 'PRE 0.1: the two page images are IDENTICAL (%). The original corruption is '
                    'back and the freeze must stay.', v_imgs[1];
  END IF;

  ------------------------------------------------------------------------------------------
  -- 0.2 No two distinct page values share an image, the invariant trg_zz_page_image_injective
  --     enforces. Measured on the DATA, because "a trigger exists" is a different claim from
  --     "the rows satisfy it".
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM (
    SELECT r.image_url FROM derm.address_row_map r
     WHERE r.white_manifest_number = '833049' AND r.image_url <> 'pending'
     GROUP BY r.image_url HAVING count(DISTINCT r.page) > 1) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.2: % image(s) are claimed by more than one page value', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 0.3 THE STRONG ONE. For each image position, the clients assigned to that effective_page
  --     must be the clients PRINTED on that scan. The chain is
  --       effective_page -> ticket_page_images[N] -> the scan read for that exact image_url
  --       -> the sheet number -> the roster read off the paper on 2026-09-03.
  --     A re-transposition scores ZERO here, which is the signature this exists to catch.
  ------------------------------------------------------------------------------------------
  FOR v_pos IN 1..2 LOOP
    SELECT s.sheet_no_read INTO v_sheet
      FROM derm.address_sheet_scan_reads s
     WHERE s.dump_folder = 'ticket-833049' AND s.image_url = v_imgs[v_pos];
    IF v_sheet IS NULL THEN
      RAISE EXCEPTION 'PRE 0.3: no sheet-number read names the image at position % (%)',
        v_pos, v_imgs[v_pos];
    END IF;

    v_want := CASE v_sheet
      WHEN '338' THEN ARRAY['029-JOS','082-TFC','083-SHUL','092-TCE','179-CIG']
      WHEN '387' THEN ARRAY['114-CI','168-AVA','214-MYK','221-YAS','222-SPE']
      ELSE NULL END;
    IF v_want IS NULL THEN
      RAISE EXCEPTION 'PRE 0.3: the image at position % reads as sheet "%", which is neither of '
                      'the two pads adjudicated on 2026-09-03 (338, 387)', v_pos, v_sheet;
    END IF;

    SELECT array_agg(c.client_code ORDER BY c.client_code) INTO v_got
      FROM derm.address_row_map r
      JOIN public.clients c ON c.id = r.matched_client_id
     WHERE r.dump_folder = 'ticket-833049'
       AND COALESCE(r.stamp_page, r.page) = v_pos;

    IF v_got IS DISTINCT FROM v_want THEN
      RAISE EXCEPTION 'PRE 0.3: effective_page % resolves to sheet %, whose printed roster is %, '
                      'but the cards there are %. The transposition is back and the freeze '
                      'must stay.', v_pos, v_sheet, v_want, coalesce(v_got, ARRAY[]::text[]);
    END IF;
  END LOOP;

  ------------------------------------------------------------------------------------------
  -- 0.4 Nothing is published for this folder, so removing the freeze cannot change what any
  --     client sees today. Guaranteed while the constraint stands, and asserted anyway.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT id FROM public.derm_manifests
                            WHERE white_manifest_number = '833049');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.4: % redacted document(s) already exist for 833049, which should be '
                    'impossible while the freeze stands', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.5: % extent row(s) already exist for ticket-833049', v_n;
  END IF;

  RAISE NOTICE 'PRE OK: two distinct scans, injective page map, both rosters match their sheet '
               'numbers, 0 extents, 0 published documents.';
END
$pre$;

-- ============================================================================================
-- THE CHANGE. One line.
-- ============================================================================================
ALTER TABLE derm.page_block_extents
  DROP CONSTRAINT page_block_extents_no_ticket_833049;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n     int;
  v_bands jsonb;
  v_short jsonb;
  v_top   numeric;
  v_bot   numeric;
  v_good  text;
  v_bad   text;
BEGIN
  -- 1. The constraint is gone, and no OTHER folder-name constraint is hiding on this table.
  --    A second stopgap would make "the freeze is removed" a false statement.
  SELECT count(*) INTO v_n FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname = 'derm' AND t.relname = 'page_block_extents'
     AND pg_get_constraintdef(c.oid) LIKE '%ticket-%';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % folder-specific constraint(s) still on page_block_extents',
      v_n;
  END IF;

  -- 2. THE CONTROL THAT MATTERS. Removing the freeze must not have weakened a single guard.
  --    Build the payload the drawn lines produce (5 strips, one per stamp), assert
  --    check_page_geometry accepts it, then REMOVE ONE ROW and assert it is refused.
  --    Without the negative half, "it returned null" is an untested instrument.
  SELECT min(rule_pct), max(rule_pct) INTO v_top, v_bot
    FROM derm.v_page_printed_rules
   WHERE dump_folder = 'ticket-833049' AND effective_page = 1;

  WITH lines AS (
    SELECT rule_pct, row_number() OVER (ORDER BY rule_pct) AS k
      FROM derm.v_page_printed_rules
     WHERE dump_folder = 'ticket-833049' AND effective_page = 1
  ), strips AS (
    SELECT a.rule_pct AS y0, b.rule_pct AS y1 FROM lines a JOIN lines b ON b.k = a.k + 1
  ), claimed AS (
    SELECT r.id, s.y0, s.y1
      FROM strips s
      JOIN derm.address_row_map r
        ON r.dump_folder = 'ticket-833049'
       AND COALESCE(r.stamp_page, r.page) = 1
       AND r.stamp_placed_at IS NOT NULL
       AND r.stamp_y_pct BETWEEN s.y0 AND s.y1
  )
  SELECT jsonb_agg(jsonb_build_object('row_id', id, 'y0', y0, 'y1', y1)),
         jsonb_agg(jsonb_build_object('row_id', id, 'y0', y0, 'y1', y1))
           FILTER (WHERE id <> (SELECT min(id) FROM claimed))
    INTO v_bands, v_short
    FROM claimed;

  IF v_bands IS NULL OR jsonb_array_length(v_bands) <> 5 THEN
    RAISE EXCEPTION 'VERIFY 2 SETUP FAILED: the drawn lines claim % strips, expected 5',
      coalesce(jsonb_array_length(v_bands), 0);
  END IF;

  v_good := derm.check_page_geometry('ticket-833049', 1, v_bands, v_top, v_bot);
  IF v_good IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the human-drawn geometry is refused: %', v_good;
  END IF;

  v_bad := derm.check_page_geometry('ticket-833049', 1, v_short, NULL, NULL);
  IF v_bad IS NULL OR v_bad NOT LIKE '%G6_MISSING_ROW%' THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: dropping a row from the payload was ACCEPTED, so the '
                    'guards are not running and the clean result above proves nothing. Got: %',
      coalesce(v_bad, '(null)');
  END IF;

  -- 3. Still nothing published. The freeze is lifted, not the safety.
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: this migration wrote % extent row(s); it must write none', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: freeze removed, guards proven live (good payload accepted, '
               'short payload refused with G6_MISSING_ROW), 0 extents written.';
END
$verify$;

COMMIT;
