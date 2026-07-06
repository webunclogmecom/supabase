-- 2026-07-06_dedup_ocr_stamp_cards.sql
-- Fred: some manifests show TOO MANY visit cards in Stamp Studio — e.g. #822919
-- showed 12 cards for 7 facilities; #825450 also duplicated. Root cause: the OCR
-- flywheel (source='claude-vision-v1') ingests one address_row_map row per
-- (page, facility). On a multi-page address sheet whose pages repeat the same
-- facilities (near-duplicate scans — page 1 and page 2 of derm/52 have DIFFERENT
-- eTags so the eTag/byte dedup never collapsed them, but they list the same
-- facilities), the SAME (ticket, client) gets a card on BOTH pages → a duplicate
-- card. A Stamp card = ONE facility line on the sheet; a (white_manifest_number,
-- matched_client_id) pair must therefore be a single card.
--
-- FLEET AUDIT (Fred's "check always if this is happening to other manifests"):
-- 10 duplicate (ticket, client) pairs fleet-wide, ALL source='claude-vision-v1':
--   * 822919 — 5 pairs (026-HAP, 033-LG, 034-LG, 114-CI, 204-JCC), all unplaced
--   * 825450 — 3 pairs (clients 10, 290, 325), the placed copy kept, unplaced dup dropped
--   * 305031 — 1 pair (022-GRO): BOTH copies are PLACED by Yannick, one per physical
--     page (derm/251/address.jpg + address_p2.jpg). NOT auto-removed — never delete a
--     placed stamp. Flagged for Yannick to confirm whether the facility truly appears
--     on both pages or one placement should be cleared.
--   * (a null-ticket 010-CS pair on separate sheets is NOT a real dup — different
--     dump_folders — and has no white_manifest_number, so it is not a visible card.)
--
-- FIX: delete only the UNPLACED duplicate extras, keeping exactly one card per
-- (ticket, client). Keeper rule = placed first, then a row that already has a
-- band, then lowest id. 8 rows removed; placed-card count unchanged (231 -> 231);
-- 822919 12 -> 7 cards (v_stamp_rows confirms 7/7), 825450 -> 7. Junction/OCR
-- table (derm.address_row_map, my lane) — hard-delete is fine here (not business
-- data; the rows are re-derivable from the OCR). Backup of the 8 full rows:
-- backups/2026-07-06_dedup_ocr_cards_backup.json.
--
-- NOTE (not a bug — for the record): the OTHER manifests Fred flagged as "missing"
-- (#820615, #822415, #822621) are NOT missing any facility. Every facility has a
-- card. A Stamp card counts FACILITIES (one line on the address sheet); DERM counts
-- VISITS. When one facility was serviced twice on a ticket (e.g. 139-LTG=2 visits,
-- 025-GRO=2, 148-MOR=2, 084-ULT=2) it is still ONE line = ONE card but TWO DERM
-- visits — so cards <= DERM visits by design. The card's Link popover lists all of
-- that facility's linked visits. No data change needed for those.
--
-- Re-runnable equivalent (idempotent — a second run deletes nothing):

WITH ranked AS (
  SELECT r.id,
         count(*) OVER (PARTITION BY r.white_manifest_number, r.matched_client_id) AS grp,
         row_number() OVER (PARTITION BY r.white_manifest_number, r.matched_client_id
           ORDER BY (r.stamp_placed_at IS NOT NULL) DESC,
                    (r.band_y0_pct IS NOT NULL) DESC,
                    r.id ASC) AS rn
  FROM derm.address_row_map r
  WHERE r.matched_client_id IS NOT NULL
    AND r.white_manifest_number IS NOT NULL
)
DELETE FROM derm.address_row_map t
USING ranked k
WHERE t.id = k.id
  AND k.grp > 1
  AND k.rn > 1
  AND t.stamp_placed_at IS NULL;

-- FOLLOW-UP (flywheel prevention, deferred): the OCR loader (build_batch_wf/03_load)
-- should collapse (white_manifest_number, matched_client_id) to a single row at
-- ingest (keeping any placed one) so multi-page/near-dup sheets can't re-introduce
-- duplicate cards. Until then, re-run the block above periodically.
