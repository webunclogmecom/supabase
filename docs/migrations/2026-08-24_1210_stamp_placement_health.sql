-- ============================================================================
-- 2026-08-24_1210  derm.v_stamp_placement_health: name a broken stamp placement
--                  before a person has to notice it in the app
-- ============================================================================
--
-- Fred, after 833395 showed "3/3 stamped" over a blank sheet: "anything else about that so that
-- feature is working correctly from now on every time I check? I don't want to check and see like
-- 833395."
--
-- This is the watch list. Sibling of derm.v_blackout_blocked_sheets and derm.v_band_edges_off_rule.
-- **Empty ATTENTION is healthy.**
--
-- ---------------------------------------------------------------------------
-- PART 0.  WHAT IT WATCHES, AND WHY THE 833395 SHAPE WAS INVISIBLE
-- ---------------------------------------------------------------------------
--
-- derm.address_row_map.stamp_page is an ORDINAL INTO derm.ticket_page_images(white#), a list
-- recomputed from the ticket's live manifest images on every call. Removing an image in the DERM
-- Tracker shortens that list, and every stamp below the removed page keeps an index that now points
-- somewhere else, or nowhere. `stamp_placed_at` stays set throughout, so the Studio's counter and
-- the Studio's renderer read different columns and disagree: "3/3 stamped", nothing drawn.
--
-- Nothing in this database could answer "is this stamp still on a page that exists". Now something
-- can.
--
-- ---------------------------------------------------------------------------
-- PART 1.  THREE VERDICTS, NEVER TWO -- and here that rule has teeth
-- ---------------------------------------------------------------------------
--
-- The house rule from scripts/checks/never-executed.mjs: RAN / NEVER / NO EVIDENCE, and collapsing
-- NO EVIDENCE into "fine" is the false all-clear this estate keeps paying for.
--
-- It matters more here than anywhere it has been applied so far, because the dangerous case is the
-- one this view CANNOT see:
--
--   * Deleting the LAST image leaves an index past the end. Caught, loudly (STAMP_PAGE_PAST_END).
--     That is the 833395 shape and it is the MILD one: the document goes blank.
--   * Deleting a MIDDLE image on a folder with three or more leaves every index IN RANGE and
--     pointing at the WRONG PAGE. Every bound check reads clean. Because stamp_page is also
--     `effective_page` in derm.v_stamp_row_bands, and therefore the page selector in
--     derm.fn_blackout_targets, that produces a customer-facing redaction built from the wrong
--     page rather than a blank card. **That is a silently wrong regulator-facing document.**
--
-- MEASURED 2026-08-24: **23 folders carry 205 placed stamps across more than one live image with no
-- per-image evidence at all** (no derm.address_sheet_scan_reads row carrying an image_url), and 100
-- of those stamps sit above ordinal 1. Worst: window3-sheet5 (3 images, 14 stamps, 9 above
-- ordinal 1), window8-sheet3 (2 images, 12 stamps), window4-sheet5 (2 images, 11 stamps).
--
-- Those 23 folders are reported as SHIFT_BLIND under verdict NO_EVIDENCE. **They are not known to
-- be wrong. They are known to be un-checkable.** The fix for them is a witness column recording
-- WHICH IMAGE each stamp was placed on at placement time; that is a separate change and this view
-- gains a STAMP_IMAGE_MOVED arm the day it lands. Until then the honest statement is printed in the
-- view itself rather than left in a migration nobody re-reads.
--
-- ⚠ A NOTE ON THE POSITIVE CONTROL, because the obvious one is wrong. Replaying 833395's broken
-- window by resetting only stamp_page does NOT reproduce a re-derivation failure: during the real
-- outage derm.fn_sheet_image_position('ticket-833395',1) returned 2, matching the stored
-- stamp_page=2 exactly, so any arm that re-derives the expected page was SILENT. The same stale
-- reading produced both the stored value and the value it would be checked against. The true
-- control is 3 rows of STAMP_PAGE_PAST_END, and PART 4 asserts exactly that.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): NOT APPLICABLE. This migration creates one VIEW and changes no table,
-- adds no column and writes no row. Nothing to opt in or out of. The underlying
-- derm.address_row_map already carries its audit trigger.
--
-- Grants mirror the sibling detector derm.v_blackout_blocked_sheets (authenticated + service_role
-- read), with PUBLIC and anon explicitly revoked -- Supabase's ALTER DEFAULT PRIVILEGES hands out
-- grants nobody wrote, so a new object in an exposed schema must be checked, not assumed.
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_placement_health AS
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
         (SELECT count(*) FROM derm.address_sheet_scan_reads sr
           WHERE sr.dump_folder = i.dump_folder AND sr.image_url IS NOT NULL)            AS reads_with_url,
         -- a stamp addressing an image the ticket does not have
         (SELECT count(*) FROM derm.address_row_map a
           WHERE a.dump_folder = i.dump_folder
             AND a.stamp_placed_at IS NOT NULL
             AND (a.stamp_page IS NULL OR a.stamp_page < 1 OR a.stamp_page > i.n_images)) AS orphan_stamps,
         -- an OCR row read keyed past the live image count
         (SELECT count(*) FROM derm.address_sheet_row_reads rr
           WHERE rr.dump_folder = i.dump_folder AND rr.page > i.n_images)                 AS orphan_row_reads,
         -- a scan read whose recorded file is no longer the file at that ordinal
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
         WHEN orphan_stamps > 0 OR orphan_row_reads > 0 OR moved_scan_reads > 0 THEN 'ATTENTION'
         WHEN n_images > 1 AND reads_with_url = 0                                THEN 'NO_EVIDENCE'
       END                                                                        AS verdict,
       -- 1 = a placed stamp cannot be drawn at all. MUST BE EMPTY.
       -- 2 = the page map is stale. Inert while the image set holds, misleading the moment it moves.
       -- 3 = coverage: this folder cannot be checked (see the view comment).
       CASE
         WHEN orphan_stamps > 0                                   THEN 1
         WHEN moved_scan_reads > 0 OR orphan_row_reads > 0        THEN 2
         ELSE 3
       END                                                                        AS severity,
       CASE
         WHEN orphan_stamps > 0    THEN 'STAMP_PAGE_PAST_END'
         WHEN moved_scan_reads > 0 THEN 'SCAN_READ_IMAGE_MOVED'
         WHEN orphan_row_reads > 0 THEN 'ROW_READ_PAST_END'
         WHEN n_images > 1 AND reads_with_url = 0 THEN 'SHIFT_BLIND'
       END                                                                        AS reason,
       n_images, stamps, stamps_above_1,
       orphan_stamps, orphan_row_reads, moved_scan_reads,
       coalesce(completed, false)                                                 AS completed,
       (coalesce(completed, false) AND orphan_stamps > 0)                         AS complete_but_unrenderable,
       last_stamp_at,
       CASE
         WHEN orphan_stamps > 0 AND n_images = 0 THEN
           'Every address image has been removed from this ticket''s manifests, so no stamp can be '
           'drawn. Either re-attach the image in the DERM Tracker, or clear the stamps. Do NOT '
           'hand-edit stamp_page.'
         WHEN orphan_stamps > 0 THEN
           'An address image was removed or reordered, so these stamps index past the end of the '
           'list derm.ticket_page_images() now returns. The Studio will count them and draw none. '
           'Repair pattern: docs/migrations/2026-08-24_1123_repair_833395_page_renumber.sql -- fix '
           'the scan/row reads to the new positions, point address_row_map.image_url at the '
           'surviving file, then CLEAR the stamps and let the resolver re-place them. Never '
           'hand-edit the coordinates.'
         WHEN moved_scan_reads > 0 THEN
           'A recorded sheet-number read names a different file than the one now at that position, '
           'so derm.fn_sheet_image_position is answering from a stale page map. Re-run '
           'ocr-address-sheet-number for this folder, or renumber the reads to match.'
         WHEN orphan_row_reads > 0 THEN
           'OCR row reads are keyed to an image position this ticket no longer has. They are inert '
           'today but will be read as describing a DIFFERENT page if an image is re-attached.'
         WHEN n_images > 1 AND reads_with_url = 0 THEN
           'NOT a defect: this folder cannot be checked. It has several images and no per-image '
           'evidence, so removing a MIDDLE image would move every stamp onto the wrong page with '
           'every bound check still reading clean -- and stamp_page selects the page the Field '
           'Portal redaction is built from. Closing this needs the placement-time witness column, '
           'or a run of ocr-address-sheet-number over the folder.'
       END                                                                        AS what_to_do
  FROM ev
 WHERE orphan_stamps > 0 OR orphan_row_reads > 0 OR moved_scan_reads > 0
    OR (n_images > 1 AND reads_with_url = 0);

COMMENT ON VIEW derm.v_stamp_placement_health IS
  'Watch list for DERM stamp placement. **verdict=ATTENTION must be EMPTY**; anything there is a '
  'stamp the Studio will count but not draw, or a stale page map. verdict=NO_EVIDENCE is the '
  'COVERAGE STATEMENT, not a backlog: those folders have several images and no per-image evidence, '
  'so a middle-image deletion would silently move stamps onto the wrong page and no check here '
  'would see it. Never read an empty ATTENTION as "all placements are correct" while NO_EVIDENCE '
  'rows exist. See docs/migrations/2026-08-24_1210_stamp_placement_health.sql.';

REVOKE ALL ON derm.v_stamp_placement_health FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON derm.v_stamp_placement_health FROM anon';
  END IF;
END $$;
GRANT SELECT ON derm.v_stamp_placement_health TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- PART 4.  VERIFY
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_s1 int; v_s2 int; v_s3 int; v_stamps int; v_reason text; v_orph int; v_n int; v_txt text;
BEGIN
  ------------------------------------------------------------------------
  -- 4.1  SEVERITY 1 -- a placed stamp that cannot be drawn -- must be empty.
  --      833395 was repaired at 11:25 ET today; this is what says it stayed repaired.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_s1 FROM derm.v_stamp_placement_health WHERE severity = 1;
  IF v_s1 <> 0 THEN
    SELECT string_agg(dump_folder || ' (' || orphan_stamps || ' orphans)', ', ')
      INTO v_txt FROM derm.v_stamp_placement_health WHERE severity = 1;
    RAISE EXCEPTION 'severity 1 is not empty: %', v_txt;
  END IF;

  ------------------------------------------------------------------------
  -- 4.2  SEVERITY 2 -- the detector's FIRST CATCH, found on its first run.
  --      ticket-310607's sheet-number read names derm/1667/address_1.WEBP while the
  --      live manifest image is address_1.JPG. Both files are in storage: the webp
  --      was read 2026-08-05 12:26 and a 307KB jpg replaced it 2026-08-10 11:38, so
  --      this is residue of a format change, not a wrong document.
  --      INERT TODAY, and the reason it is inert is worth knowing: that read's
  --      sheet_no_read is "1078" with no "-N" page suffix, so it never enters
  --      fn_sheet_image_position's page map at all, and the folder has one image with
  --      all four stamps on page 1. It becomes misleading the moment a second image
  --      is attached. Fix by re-running ocr-address-sheet-number for the folder, which
  --      OBSERVES the current file rather than editing the record of the old one.
  --      Fleet-wide there is exactly one .webp read, so this is a one-off.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_s2 FROM derm.v_stamp_placement_health WHERE severity = 2;
  IF v_s2 <> 1 THEN
    RAISE EXCEPTION 'expected exactly the 1 known severity-2 folder (ticket-310607), found %', v_s2;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.v_stamp_placement_health
                  WHERE severity = 2 AND dump_folder = 'ticket-310607'
                    AND reason = 'SCAN_READ_IMAGE_MOVED') THEN
    RAISE EXCEPTION 'the severity-2 row is not the documented ticket-310607 finding';
  END IF;

  ------------------------------------------------------------------------
  -- 4.3  SEVERITY 3 must NOT be zero. If it were, the three-verdict design would be
  --      decoration and the coverage claim would be untested.
  ------------------------------------------------------------------------
  SELECT count(*), coalesce(sum(stamps), 0) INTO v_s3, v_stamps
    FROM derm.v_stamp_placement_health WHERE reason = 'SHIFT_BLIND';
  IF v_s3 < 1 THEN
    RAISE EXCEPTION 'no SHIFT_BLIND folders found, so the coverage arm is untested';
  END IF;
  RAISE NOTICE 'coverage: % folders / % stamps cannot be checked (SHIFT_BLIND)', v_s3, v_stamps;

  ------------------------------------------------------------------------
  -- 4.4  POSITIVE CONTROL. Recreate 833395's broken state and require the view to
  --      name it. A watch list that has never fired is an untested instrument.
  --      Rolled back in a subtransaction; PL/pgSQL variables survive the abort.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.address_row_map SET stamp_page = 2 WHERE white_manifest_number = '833395';
      SELECT count(*), max(reason), max(orphan_stamps)
        INTO v_n, v_reason, v_orph
        FROM derm.v_stamp_placement_health
       WHERE dump_folder = 'ticket-833395' AND severity = 1;
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    IF v_n <> 1 OR v_reason IS DISTINCT FROM 'STAMP_PAGE_PAST_END' OR v_orph <> 3 THEN
      RAISE EXCEPTION 'CONTROL FAILED: replaying the 833395 break gave % rows, reason %, % orphans (expected 1 / STAMP_PAGE_PAST_END / 3)',
        v_n, coalesce(v_reason, 'NULL'), coalesce(v_orph, -1);
    END IF;
    RAISE NOTICE 'CONTROL OK: the 833395 break reports as severity 1 STAMP_PAGE_PAST_END, 3 orphan stamps';
  END;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE white_manifest_number = '833395' AND stamp_page IS DISTINCT FROM 1;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'the rolled-back control leaked a stamp_page change onto 833395';
  END IF;

  ------------------------------------------------------------------------
  -- 4.5  The repaired folder must not be reported at all. Without this, 4.4 would
  --      still pass on a view that returns every folder unconditionally.
  ------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM derm.v_stamp_placement_health WHERE dump_folder = 'ticket-833395') THEN
    RAISE EXCEPTION 'the repaired 833395 is still on the worklist';
  END IF;

  RAISE NOTICE 'OK: severity 1 empty, 1 known severity-2, % coverage rows', v_s3;
END $$;

COMMIT;
