-- ============================================================================
-- 2026-08-24_1123  Repair ticket-833395 after an image deletion renumbered its pages
-- ============================================================================
--
-- Fred, hours after 833395 was auto-stamped: "i deleted one page of the DERM Addresses on the DERM
-- App, the one that wasn't stamped ... the stamps are lost ... somehow it shows like it's stamped
-- 3/3, but if i open it i don't see anything placed, like there is nothing."
--
-- ---------------------------------------------------------------------------
-- PART 0.  WHAT HAPPENED, AND WHY IT IS A CLASS OF DEFECT AND NOT A ONE-OFF
-- ---------------------------------------------------------------------------
--
-- `derm.address_row_map.stamp_page`, `derm.address_sheet_scan_reads.page` and
-- `derm.address_sheet_row_reads.page` are all ORDINALS INTO A COMPUTED LIST -- the list returned by
-- `derm.ticket_page_images(white#)`. **Nothing about an ordinal survives the list changing.**
--
-- `ticket_page_images` even says so. Its own comment reads:
--     "OCR pages first, appended UNCONDITIONALLY in page order (existing stamp_page indexes must
--      never move)."
-- and then, four lines below, the staleness gate does exactly what that comment forbids:
--     IF v_m_etags IS NOT NULL AND (r.etag IS NULL OR NOT (r.etag = ANY(v_m_etags))) THEN
--       CONTINUE;   -- <-- drops the page, and every later page slides down one
--
-- So when Fred removed `address_1.jpg` from the manifests in the DERM Tracker:
--   * the ticket's image list went from [address_1, address_2] to [address_2]
--   * the surviving image moved from position 2 to position 1
--   * the three stamps kept `stamp_page = 2`, which now addresses no image at all
--   * `stamp_placed_at` was still set on all three, so the Studio counted 3/3 and rendered nothing
--
-- **The count and the position come from different columns, so the app can be simultaneously right
-- that three stamps exist and unable to draw any of them.** That is the whole symptom.
--
-- FLEET SCAN before this file: 131 folders, exactly ONE (ticket-833395, 3 rows) has a stamp whose
-- `stamp_page` exceeds its live image count. Two folders have zero live images and zero stamps, so
-- they are inert. The corruption is contained; the mechanism is not. A durable fix for the ordinal
-- is being designed separately -- this file only makes 833395 correct again, and pins it.
--
-- ---------------------------------------------------------------------------
-- PART 1.  THE REPAIR IS PROVABLE, NOT A GUESS
-- ---------------------------------------------------------------------------
--
-- `derm.address_sheet_scan_reads` stores `image_url`, which is a STABLE identity, so each read can
-- be attributed to a specific file rather than to a position:
--
--   page 1   sheet_no_read "1093-2"   image_url .../derm/1735/address_1.jpg   <- DELETED reference
--   page 2   sheet_no_read "1093-1"   image_url .../derm/1735/address_2.jpg   <- SURVIVING
--
-- So the surviving image is sheet 1093's printed page 1, and it carries exactly the ticket's three
-- clients (242-WYN on printed rows 1-3, one per GDO permit, then 069-TCE on row 4 and 032-LG on
-- row 5). The row reads agree, 10 of 10. The deleted image was sheet 1093's printed page 2, which
-- holds five OTHER clients and no stamp of this ticket's -- which is why Fred could delete it
-- without appearing to lose anything.
--
-- ⚠ `derm.address_sheet_row_reads` has NO `image_url` column, so its rows can only be attributed by
-- position. They are attributed here by their agreement with the scan reads above, not independently.
--
-- ⚠ `address_1.jpg` is still IN STORAGE (its eTag still resolves); only the manifest reference was
-- removed. So it can come back, and the repair has to survive that.
--
-- ---------------------------------------------------------------------------
-- PART 2.  WHY THIS ALSO REWRITES address_row_map.page / image_url -- IT IS THE PIN
-- ---------------------------------------------------------------------------
--
-- The three cards currently say `page = 1` with `image_url` pointing at the DELETED `address_1.jpg`
-- (two of them) or the literal string 'pending' (one). Both are wrong: those cards are printed on
-- `address_2.jpg`.
--
-- Correcting them is not cosmetic. `ticket_page_images` builds its list by grouping
-- `address_row_map` on `page` and taking `mode(image_url)`, then appending live manifest images not
-- already present.
--
-- 🛑 BUT IT DOES NOTHING TODAY, AND THE FIRST VERSION OF THIS FILE CLAIMED OTHERWISE. Its control
-- failed and was right to. While `address_1.jpg` is absent from every live manifest, the staleness
-- gate discards it from the OCR loop no matter what the cards point at, so `address_2.jpg` reaches
-- position 1 through the manifest-append loop either way. **The control was measuring the gate, not
-- the pin.**
--
-- The pin matters in exactly ONE scenario, and it is a live one because `address_1.jpg` is still in
-- storage and can be re-referenced at any time:
--
--   address_1 re-added,      OCR loop yields page 1 -> address_1 (etag now live) -> position 1,
--   cards left stale         address_2 appended at position 2. THE STAMPS SILENTLY BREAK AGAIN.
--
--   address_1 re-added,      OCR loop yields page 1 -> address_2 -> position 1,
--   cards corrected          address_1 appended at position 2. The stamps do not move.
--
-- So PART 6 is insurance against a recurrence, not part of today's fix, and PART 8.3 proves it by
-- simulating the re-upload inside a rolled-back subtransaction instead of asserting it.
--
-- ---------------------------------------------------------------------------
-- PART 3.  RECOVERABILITY (rule 6)
-- ---------------------------------------------------------------------------
--
-- `derm.address_row_map` IS audited, so every UPDATE below is recoverable from `audit.logs.old_row`.
-- `derm.address_sheet_scan_reads` and `derm.address_sheet_row_reads` carry NO audit trigger
-- (verified: the audited `derm` set is address_row_map, address_sheet_manifests, address_sheets,
-- band_review, stamp_sheet_status). A DELETE there leaves no record of any kind, so the pre-repair
-- state of all five objects was written to
--     backups/derm_ticket_833395_pre_repair_2026-08-24.json
-- BEFORE this file was run. That file is the only restore path for the two read tables.
--
-- ADR 010 rule 8: no schema change here, so no trigger decision. Data repair only.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 4.  Preconditions. If any of these has moved, the repair is not the right one.
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_imgs text[]; v_n int; v_txt text;
BEGIN
  v_imgs := derm.ticket_page_images('833395');
  IF coalesce(array_length(v_imgs, 1), 0) <> 1 OR v_imgs[1] NOT LIKE '%/derm/1735/address_2.jpg' THEN
    RAISE EXCEPTION 'precondition failed: the ticket no longer has exactly one image (address_2). Got %', v_imgs;
  END IF;

  SELECT string_agg(page || '=' || sheet_no_read || '@' || right(image_url, 13), ' ' ORDER BY page)
    INTO v_txt FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-833395';
  IF v_txt IS DISTINCT FROM '1=1093-2@address_1.jpg 2=1093-1@address_2.jpg' THEN
    RAISE EXCEPTION 'precondition failed: scan reads are not the state this repair was written for: %', v_txt;
  END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE white_manifest_number = '833395' AND stamp_page = 2 AND stamp_placed_at IS NOT NULL;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'precondition failed: expected 3 orphaned stamps on page 2, found %', v_n;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- PART 5.  Drop the reads that describe the removed image, then renumber the survivor.
--          Delete first: the PKs are (dump_folder, page) and (dump_folder, page, row_index),
--          so 2 -> 1 collides while the old page 1 is still there.
--
--          Renumbering is not rewriting an observation. sheet_no_read, client_code_read,
--          confidence and image_url all stay exactly as OCR recorded them; only the POSITION
--          moves, and the position is a property of the ticket's image list, not of what was seen.
-- ---------------------------------------------------------------------------

DELETE FROM derm.address_sheet_row_reads  WHERE dump_folder = 'ticket-833395' AND page = 1;
DELETE FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-833395' AND page = 1;

UPDATE derm.address_sheet_row_reads  SET page = 1 WHERE dump_folder = 'ticket-833395' AND page = 2;
UPDATE derm.address_sheet_scan_reads SET page = 1 WHERE dump_folder = 'ticket-833395' AND page = 2;

-- ---------------------------------------------------------------------------
-- PART 6.  Point the cards at the image they are actually printed on (PART 2: this is the pin).
-- ---------------------------------------------------------------------------

UPDATE derm.address_row_map
   SET page = 1,
       image_url = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg'
 WHERE white_manifest_number = '833395';

-- ---------------------------------------------------------------------------
-- PART 7.  Clear the orphaned stamps and let the resolver re-place them.
--
--          Deliberately NOT a hand-edit of stamp_page from 2 to 1. Re-running the resolver makes
--          the machine re-derive page AND coordinates from the corrected evidence, so if any of the
--          reasoning above is wrong the result is a refusal rather than three stamps I placed by
--          hand at coordinates I chose. The clear is recoverable: address_row_map is audited.
-- ---------------------------------------------------------------------------

UPDATE derm.address_row_map
   SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL,
       stamp_placed_at = NULL, stamp_placed_by = NULL
 WHERE white_manifest_number = '833395';

DO $$
DECLARE v_sheet bigint;
BEGIN
  IF derm.fn_sheet_image_position('ticket-833395', 1) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'logical page 1 does not resolve to image position 1 after the renumber (got %)',
      derm.fn_sheet_image_position('ticket-833395', 1);
  END IF;
  IF derm.fn_sheet_image_position('ticket-833395', 2) IS NOT NULL THEN
    RAISE EXCEPTION 'logical page 2 still resolves to an image, but that page was removed from the ticket';
  END IF;
  IF derm.fn_sheet_rows_all_confirmed('833395', 131, 'ticket-833395') IS NOT TRUE THEN
    RAISE EXCEPTION 'the row reads no longer confirm sheet 1093 after the renumber';
  END IF;

  v_sheet := derm.fn_resolve_generated_sheet_for_ticket('833395');
  IF v_sheet IS DISTINCT FROM 131 THEN
    RAISE EXCEPTION 'resolver returned % instead of sheet 131', coalesce(v_sheet::text, 'NULL');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- PART 8.  VERIFY the end state, including the controls.
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_txt text; v_n int;
BEGIN
  -- 8.1  every stamp is back, on image position 1, at the same printed-row geometry as before.
  --      The y values are the ones measured on the paper this morning; if the repair moved a stamp
  --      to a different printed row this assertion is what says so.
  SELECT string_agg(c.client_code || '@p' || a.stamp_page || '/' || a.stamp_y_pct, ' ' ORDER BY a.stamp_y_pct)
    INTO v_txt
    FROM derm.address_row_map a JOIN public.clients c ON c.id = a.matched_client_id
   WHERE a.white_manifest_number = '833395';
  IF v_txt IS DISTINCT FROM '242-WYN@p1/29.800 069-TCE@p1/51.810 032-LG@p1/60.040' THEN
    RAISE EXCEPTION 'stamps did not come back where they belong: %', v_txt;
  END IF;

  -- 8.2  no stamp addresses an image the ticket does not have. This is the invariant the whole
  --      incident violated, asserted directly.
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a
   WHERE a.white_manifest_number = '833395'
     AND a.stamp_placed_at IS NOT NULL
     AND a.stamp_page > coalesce(array_length(derm.ticket_page_images('833395'), 1), 0);
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% stamps still point past the end of the image list', v_n;
  END IF;

  -- 8.3  CONTROL for PART 6: simulate the re-upload of address_1.jpg and show that the corrected
  --      cards are what keep the stamped image at position 1. Both legs run inside a subtransaction
  --      that is ROLLED BACK, so no manifest row is really touched; PL/pgSQL variables survive the
  --      abort, which is how the measurements get out.
  --
  --      Two legs are required. One leg alone cannot tell "the pin works" from "the position never
  --      moves anyway" -- which is precisely how the first version of this control passed nothing.
  DECLARE
    v_pinned int; v_stale int;
    c_a1 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_1.jpg';
    c_a2 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg';
  BEGIN
    BEGIN
      -- the re-upload: address_1 becomes a live manifest image again
      UPDATE public.derm_manifests
         SET derm_address_extra_urls = array_append(coalesce(derm_address_extra_urls, '{}'::text[]), c_a1)
       WHERE id = 1735;

      -- leg A: cards corrected (what PART 6 leaves behind)
      v_pinned := array_position(derm.ticket_page_images('833395'), c_a2);

      -- leg B: cards left stale, pointing at the re-uploaded image
      UPDATE derm.address_row_map SET image_url = c_a1 WHERE white_manifest_number = '833395';
      v_stale := array_position(derm.ticket_page_images('833395'), c_a2);

      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    IF v_pinned IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'CONTROL FAILED: even with corrected cards the stamped image sits at position %, so PART 6 does not protect a re-upload', v_pinned;
    END IF;
    IF v_stale IS NOT DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'CONTROL FAILED: stale cards leave the stamped image at position 1 too, so PART 6 changes nothing and the claim must be deleted';
    END IF;
    RAISE NOTICE 'CONTROL OK: on a re-upload, corrected cards keep the stamped image at position 1 while stale cards move it to %', v_stale;
  END;

  -- the probe must have left nothing behind
  IF EXISTS (SELECT 1 FROM public.derm_manifests
              WHERE id = 1735 AND coalesce(derm_address_extra_urls, '{}') <> '{}') THEN
    RAISE EXCEPTION 'the rolled-back probe leaked an extra_url onto manifest 1735';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE white_manifest_number = '833395' AND image_url NOT LIKE '%address_2.jpg') THEN
    RAISE EXCEPTION 'the rolled-back probe leaked a stale image_url onto the cards';
  END IF;

  -- 8.4  the reads are internally consistent: page 1's scan read is the surviving file.
  SELECT string_agg(page || '=' || sheet_no_read || '@' || right(image_url, 13), ' ' ORDER BY page)
    INTO v_txt FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-833395';
  IF v_txt IS DISTINCT FROM '1=1093-1@address_2.jpg' THEN
    RAISE EXCEPTION 'scan reads did not land where expected: %', v_txt;
  END IF;

  SELECT count(*) INTO v_n FROM derm.address_sheet_row_reads WHERE dump_folder = 'ticket-833395';
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'expected the 5 surviving row reads, found %', v_n;
  END IF;

  RAISE NOTICE 'OK: 833395 re-resolved onto sheet 1093, 3 stamps on image position 1, pin verified';
END $$;

COMMIT;
