-- ============================================================================
-- 2026-08-24_1440  The health view stops saying "cannot be checked" and checks
-- ============================================================================
--
-- 2026-08-24_1210 shipped derm.v_stamp_placement_health with an honest hole in it: 23 folders
-- carrying 205 placed stamps across several images were reported SHIFT_BLIND, meaning a MIDDLE
-- image deletion would move every stamp onto the wrong page with every bound check still reading
-- clean. That is the dangerous direction, because stamp_page selects the page the Field Portal
-- redaction is built from, so the failure is a wrongly-redacted regulator-facing document rather
-- than a blank one.
--
-- 2026-08-24_1410 added the witness (derm.address_row_map.stamp_image_url) and backfilled it for
-- all 645 placed stamps. The hole can now be closed rather than described.
--
-- ---------------------------------------------------------------------------
-- WHAT CHANGES
-- ---------------------------------------------------------------------------
--
--   SHIFT_BLIND            REMOVED. Superseded by a real check, not by a decision to stop worrying.
--   STAMP_IMAGE_MOVED      NEW, severity 1. The image now at this stamp's ordinal is not the image
--                          the stamp was placed on. Catches the middle-image deletion that every
--                          bound check misses.
--   NO_WITNESS             NEW, severity 3. A placed stamp with no witness: the honest residue.
--                          Zero today, and it stays zero unless something writes stamp_placed_at
--                          in a way that bypasses trg_ac_stamp_witness.
--
-- ⚠ THE BACKFILL DERIVED EACH WITNESS FROM ITS OWN ORDINAL, so today the two agree BY
-- CONSTRUCTION and STAMP_IMAGE_MOVED cannot fire on historical data. **This arm does not
-- retrospectively validate anything.** It detects DIVERGENCE FROM THIS MOMENT ON. That is the
-- honest claim and it is worth stating plainly, because a reader seeing "0 rows" could otherwise
-- conclude the 23 folders were checked and found correct. They were not. They were frozen.
--
-- ⚠ In normal operation the arm should also stay empty because derm.fn_reconcile_stamp_pages()
-- repairs the ordinal automatically when the DERM Tracker changes a ticket's images. It fires when
-- the list moves for a reason the reconcile trigger does not see -- a storage eTag change, an edit
-- to address_row_map.page or image_url, or an all-or-nothing reconcile that refused.
--
-- ADR 010 rule 8: NOT APPLICABLE. One view replaced; no table, column or row is touched.
-- ============================================================================

BEGIN;

-- CREATE OR REPLACE cannot add a column in the middle of the list, so the view is dropped and
-- rebuilt. Nothing depends on it (it is one day old and read by people, not by objects), and the
-- grants are re-applied below. Asserted after the fact.
DROP VIEW IF EXISTS derm.v_stamp_placement_health;

CREATE VIEW derm.v_stamp_placement_health AS
WITH folder AS (
  SELECT a.dump_folder,
         max(a.white_manifest_number)                                    AS white_manifest_number,
         count(*) FILTER (WHERE a.stamp_placed_at IS NOT NULL)           AS stamps,
         count(*) FILTER (WHERE a.stamp_placed_at IS NOT NULL
                            AND coalesce(a.stamp_page, a.page) > 1)      AS stamps_above_1,
         max(a.stamp_placed_at)                                          AS last_stamp_at
    FROM derm.address_row_map a
   GROUP BY a.dump_folder
  HAVING count(*) FILTER (WHERE a.stamp_placed_at IS NOT NULL) > 0
), img AS (
  SELECT f.*,
         coalesce(array_length(derm.ticket_page_images(f.white_manifest_number), 1), 0) AS n_images,
         derm.ticket_page_images(f.white_manifest_number)                                AS images
    FROM folder f
), ev AS (
  SELECT i.*,
         (SELECT count(*) FROM derm.address_row_map a
           WHERE a.dump_folder = i.dump_folder
             AND a.stamp_placed_at IS NOT NULL
             AND (a.stamp_page IS NULL OR a.stamp_page < 1 OR a.stamp_page > i.n_images)) AS orphan_stamps,
         -- THE ARM THAT SEES A SHIFT: the image at this ordinal is not the one stamped on
         (SELECT count(*) FROM derm.address_row_map a
           WHERE a.dump_folder = i.dump_folder
             AND a.stamp_placed_at IS NOT NULL
             AND a.stamp_image_url IS NOT NULL
             AND a.stamp_page BETWEEN 1 AND i.n_images
             AND i.images[a.stamp_page] IS DISTINCT FROM a.stamp_image_url)                AS moved_stamps,
         (SELECT count(*) FROM derm.address_row_map a
           WHERE a.dump_folder = i.dump_folder
             AND a.stamp_placed_at IS NOT NULL
             AND a.stamp_image_url IS NULL)                                                AS no_witness,
         (SELECT count(*) FROM derm.address_sheet_row_reads rr
           WHERE rr.dump_folder = i.dump_folder AND rr.page > i.n_images)                   AS orphan_row_reads,
         (SELECT count(*) FROM derm.address_sheet_scan_reads sr
           WHERE sr.dump_folder = i.dump_folder
             AND sr.image_url IS NOT NULL
             AND (sr.page > i.n_images OR i.images[sr.page] IS DISTINCT FROM sr.image_url)) AS moved_scan_reads,
         (SELECT s.completed FROM derm.stamp_sheet_status s WHERE s.dump_folder = i.dump_folder) AS completed
    FROM img i
)
SELECT dump_folder,
       white_manifest_number,
       CASE
         WHEN orphan_stamps > 0 OR moved_stamps > 0 OR orphan_row_reads > 0 OR moved_scan_reads > 0
           THEN 'ATTENTION'
         WHEN no_witness > 0 THEN 'NO_EVIDENCE'
       END                                                                        AS verdict,
       -- 1 = a placed stamp is on the wrong image, or on none. MUST BE EMPTY.
       -- 2 = the page map is stale. Inert while the image set holds, misleading once it moves.
       -- 3 = coverage: this stamp cannot be checked.
       CASE
         WHEN orphan_stamps > 0 OR moved_stamps > 0                THEN 1
         WHEN moved_scan_reads > 0 OR orphan_row_reads > 0         THEN 2
         ELSE 3
       END                                                                        AS severity,
       CASE
         WHEN orphan_stamps > 0    THEN 'STAMP_PAGE_PAST_END'
         WHEN moved_stamps > 0     THEN 'STAMP_IMAGE_MOVED'
         WHEN moved_scan_reads > 0 THEN 'SCAN_READ_IMAGE_MOVED'
         WHEN orphan_row_reads > 0 THEN 'ROW_READ_PAST_END'
         WHEN no_witness > 0       THEN 'NO_WITNESS'
       END                                                                        AS reason,
       n_images, stamps, stamps_above_1,
       orphan_stamps, moved_stamps, no_witness, orphan_row_reads, moved_scan_reads,
       coalesce(completed, false)                                                 AS completed,
       (coalesce(completed, false) AND (orphan_stamps > 0 OR moved_stamps > 0))   AS complete_but_unrenderable,
       last_stamp_at,
       CASE
         WHEN orphan_stamps > 0 AND n_images = 0 THEN
           'Every address image has been removed from this ticket''s manifests, so no stamp can be '
           'drawn. Either re-attach the image in the DERM Tracker, or clear the stamps. Do NOT '
           'hand-edit stamp_page.'
         WHEN orphan_stamps > 0 THEN
           'These stamps index past the end of derm.ticket_page_images(). '
           'derm.fn_reconcile_stamp_pages() refused because at least one stamp''s witnessed image '
           'is no longer on the ticket -- it is all-or-nothing on purpose. Re-attach the missing '
           'image, or clear those stamps and let the resolver re-place them. Repair pattern: '
           'docs/migrations/2026-08-24_1123_repair_833395_page_renumber.sql.'
         WHEN moved_stamps > 0 THEN
           'The image at this stamp''s page is NOT the image it was placed on, so the Studio draws '
           'it over the wrong sheet and the Field Portal redaction is built from the wrong page. '
           'This is the dangerous direction. Run derm.fn_reconcile_stamp_pages(<white#>): it will '
           'put the ordinal back from the witness, or refuse and leave this row here.'
         WHEN moved_scan_reads > 0 THEN
           'A recorded sheet-number read names a different file than the one now at that position, '
           'so derm.fn_sheet_image_position is answering from a stale page map. Re-run '
           'ocr-address-sheet-number for this folder.'
         WHEN orphan_row_reads > 0 THEN
           'OCR row reads are keyed to an image position this ticket no longer has. Inert today, '
           'but they will be read as describing a DIFFERENT page if an image is re-attached.'
         WHEN no_witness > 0 THEN
           'A placed stamp with no stamp_image_url, so it cannot be followed if the image list '
           'moves. Something wrote stamp_placed_at without trg_ac_stamp_witness firing. Investigate '
           'the writer -- do not backfill the witness from the ordinal on a folder in this state.'
       END                                                                        AS what_to_do
  FROM ev
 WHERE orphan_stamps > 0 OR moved_stamps > 0 OR no_witness > 0
    OR orphan_row_reads > 0 OR moved_scan_reads > 0;

COMMENT ON VIEW derm.v_stamp_placement_health IS
  'Watch list for DERM stamp placement. **severity 1 must be EMPTY**: a stamp on the wrong image, '
  'or on none. Severity 2 is a stale page map, inert until the image set moves. Severity 3 is a '
  'placed stamp with no witness and therefore uncheckable. ⚠ The witness was backfilled from each '
  'stamp''s own ordinal on 2026-08-24, so STAMP_IMAGE_MOVED detects divergence FROM THAT MOMENT '
  'ON and does not retrospectively validate the historical mapping. '
  'See docs/migrations/2026-08-24_1440_health_reads_the_witness.sql.';

REVOKE ALL ON derm.v_stamp_placement_health FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON derm.v_stamp_placement_health FROM anon';
  END IF;
END $$;
GRANT SELECT ON derm.v_stamp_placement_health TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_n int; v_reason text; v_moved int;
  c_a1 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_1.jpg';
  c_a2 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg';
BEGIN
  -- 1. severity 1 empty, and the 23 SHIFT_BLIND rows are gone because they are now checkable
  SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health WHERE severity = 1;
  IF v_n <> 0 THEN RAISE EXCEPTION 'severity 1 is not empty: % folders', v_n; END IF;

  IF EXISTS (SELECT 1 FROM derm.v_stamp_placement_health WHERE reason = 'SHIFT_BLIND') THEN
    RAISE EXCEPTION 'SHIFT_BLIND still exists, so the view was not replaced';
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health WHERE reason = 'NO_WITNESS';
  IF v_n <> 0 THEN RAISE EXCEPTION '% folders have a placed stamp with no witness', v_n; END IF;

  -- the known severity 2 must survive: this file must not have quietly widened anything
  IF NOT EXISTS (SELECT 1 FROM derm.v_stamp_placement_health
                  WHERE severity = 2 AND dump_folder = 'ticket-310607') THEN
    RAISE EXCEPTION 'the documented ticket-310607 severity-2 finding disappeared';
  END IF;

  -- 2. POSITIVE CONTROL for the new arm. Manufacture a genuine middle-image shift: give the
  --    ticket two images with the stamped one at position 2, blind the reconcile, then remove the
  --    first image. Every bound check still reads clean -- stamp_page 2 is in range for a
  --    2-image... no: after removal there is 1 image, so use a 3-image setup where the ordinal
  --    stays IN RANGE. That is the case the old view could not see.
  DECLARE v_sev int; v_orph int;
  BEGIN
    BEGIN
      -- three images: [a1, a2, a1-copy] is not possible with distinct eTags, so instead put the
      -- stamped image at position 2 of two, then delete the OTHER one and re-add it as extra so
      -- the count returns to 2 with the order reversed. Ordinal stays in range, image differs.
      UPDATE derm.address_row_map SET image_url = c_a1, stamp_page = 2
       WHERE white_manifest_number = '833395';
      UPDATE public.derm_manifests
         SET derm_address_url = c_a1, derm_address_extra_urls = ARRAY[c_a2]
       WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395';
      -- witness still says a2, and a2 is at position 2 -> healthy
      SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health
       WHERE dump_folder = 'ticket-833395' AND severity = 1;
      IF v_n <> 0 THEN RAISE EXCEPTION 'setup is already dirty (% rows)', v_n; END IF;

      -- now reverse the order WITHOUT changing the count: a2 becomes position 1, so the stamp at
      -- ordinal 2 now addresses a1. In range, wrong image. This is the middle-deletion shape.
      UPDATE derm.address_row_map SET image_url = c_a2 WHERE white_manifest_number = '833395';
      SELECT severity, reason, moved_stamps, orphan_stamps
        INTO v_sev, v_reason, v_moved, v_orph
        FROM derm.v_stamp_placement_health WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    IF v_sev IS DISTINCT FROM 1 OR v_reason IS DISTINCT FROM 'STAMP_IMAGE_MOVED' THEN
      RAISE EXCEPTION 'CONTROL FAILED: an in-range shift onto the wrong image reported severity %, reason %',
        coalesce(v_sev::text, 'NULL'), coalesce(v_reason, 'NULL');
    END IF;
    IF coalesce(v_orph, 0) <> 0 THEN
      RAISE EXCEPTION 'CONTROL INVALID: the probe also produced % orphan stamps, so it did not isolate the shift arm', v_orph;
    END IF;
    RAISE NOTICE 'CONTROL OK: an in-range shift onto the wrong image reports severity 1 STAMP_IMAGE_MOVED with 0 orphans -- the case the old view could not see';
  END;

  -- 3. the probe left nothing behind
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE white_manifest_number = '833395'
                AND (stamp_page <> 1 OR image_url IS DISTINCT FROM c_a2
                     OR stamp_image_url IS DISTINCT FROM c_a2)) THEN
    RAISE EXCEPTION 'the rolled-back control leaked a card change';
  END IF;
  IF EXISTS (SELECT 1 FROM public.derm_manifests
              WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395'
                AND (derm_address_url IS DISTINCT FROM c_a2
                     OR coalesce(derm_address_extra_urls, '{}') <> '{}')) THEN
    RAISE EXCEPTION 'the rolled-back control leaked a manifest change';
  END IF;

  -- 4. the drop-and-rebuild must not have lost the grants
  IF NOT has_table_privilege('authenticated', 'derm.v_stamp_placement_health', 'SELECT')
     OR NOT has_table_privilege('service_role', 'derm.v_stamp_placement_health', 'SELECT') THEN
    RAISE EXCEPTION 'the rebuilt view lost a grant';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     AND has_table_privilege('anon', 'derm.v_stamp_placement_health', 'SELECT') THEN
    RAISE EXCEPTION 'anon can read the rebuilt view -- ALTER DEFAULT PRIVILEGES struck again';
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health;
  RAISE NOTICE 'OK: severity 1 empty, SHIFT_BLIND retired, % rows on the list', v_n;
END $$;

COMMIT;
