-- 2026-07-06_backfill_missing_linked_cards.sql
-- Fred: the Stamp app should show a card for every visit we have LINKED in the DB
-- (some were missing — e.g. a page's facilities that the OCR never ingested, so
-- a linked facility had no card to place). Backfilled: for each ticket, every
-- LINKED manifest client-entry (its manifest has a manifest_visits row) that had
-- NO address_row_map row now gets an unplaced card, matched to its client +
-- manifest, on page 1 (page is arbitrary — unplaced cards are a page-agnostic
-- pool now; the operator places them on whichever image). 16 rows created.
-- Additive + idempotent; does NOT touch any placed (stamp_placed_at) row.
-- Backup: backups/2026-07-06_missing_linked_cards_backfill.json (the 16 entries).
-- Re-runnable equivalent:

INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   facility_name_read, matched_client_id, matched_manifest_id,
   assignment_status, confidence, agent_agreement, flags, source)
SELECT
  (SELECT min(dump_folder) FROM derm.address_row_map a WHERE a.white_manifest_number = dm.white_manifest_number),
  dm.white_manifest_number,
  1,
  (SELECT coalesce(max(row_index),0)+1 FROM derm.address_row_map a
     WHERE a.dump_folder = (SELECT min(dump_folder) FROM derm.address_row_map b WHERE b.white_manifest_number = dm.white_manifest_number)
       AND a.page = 1),
  (SELECT min(image_url) FROM derm.address_row_map a WHERE a.white_manifest_number = dm.white_manifest_number),
  NULL, dm.client_id, dm.id,
  'matched', 'high', 'linked-backfill', '{"linked_card_backfill":true}'::jsonb, 'linked-backfill'
FROM public.derm_manifests dm
WHERE dm.deleted_at IS NULL
  AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = dm.id)
  AND dm.white_manifest_number IN (SELECT DISTINCT white_manifest_number FROM derm.address_row_map)
  AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                   WHERE r.white_manifest_number = dm.white_manifest_number
                     AND r.matched_client_id = dm.client_id);
