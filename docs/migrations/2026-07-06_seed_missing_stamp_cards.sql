-- 2026-07-06_seed_missing_stamp_cards.sql
-- Fred (#3): "linked-manifests-without-card" — clients that ARE linked (manifest +
-- visit) on a ticket but have NO card in the Stamp app, so the facility can't be
-- seen/stamped. Investigation found this was really ONE whole un-ingested sheet
-- plus one straggler:
--   * #829201 (dump Jun 23-Jul 4) — 10 client-manifests + address images in DERM,
--     but ZERO rows in derm.address_row_map (the OCR pipeline never ingested it),
--     so the sheet didn't appear in Stamp at all.
--   * #824713 / 215-G7 — created by today's manifest-filing (215-G7 had no OCR card).
-- Confirmed fleet-wide: #829201 is the ONLY fully un-ingested sheet; 215-G7 the only
-- straggler. After this, `linked-manifests-without-card` = 0.
--
-- FIX (additive, no compliance records created — the manifests already exist):
--   A) #829201 — seed 10 unplaced cards (one per client-manifest) on a new
--      dump_folder 'backfill-829201', image_url = the manifest's public
--      derm_address_url (verified HTTP 200). v_stamp_sheets shows 2 address pages
--      (address_1 + address_2, from the manifests) — the cards are a page-agnostic
--      pool, placeable on either. Live-verified: /829201 renders 10 LINKED cards.
--   B) any already-ingested sheet with a linked-but-cardless client (215-G7 on
--      #824713) — seed a card copying dump_folder + image_url from that sheet's
--      existing rows.
-- source='linked-backfill'. Backup: backups/2026-07-06_seed_missing_cards_backup.json
-- (the 11 seeded row ids). Re-runnable (NOT EXISTS guards skip already-carded clients).

BEGIN;
-- A) #829201 (never ingested -> seed from manifest address image)
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   facility_name_read, matched_client_id, matched_manifest_id,
   assignment_status, confidence, source, flags, created_at, updated_at)
SELECT 'backfill-829201', dm.white_manifest_number, 1,
   row_number() OVER (ORDER BY dm.id),
   dm.derm_address_url, NULL, dm.client_id, dm.id,
   'matched','high','linked-backfill',
   '{"linked_card_backfill":true,"sheet_not_ingested":true}'::jsonb, now(), now()
FROM public.derm_manifests dm
WHERE dm.white_manifest_number='829201' AND dm.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                   WHERE r.white_manifest_number='829201' AND r.matched_client_id=dm.client_id);

-- B) already-ingested sheets with a linked-but-cardless client (e.g. 824713/215-G7)
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   facility_name_read, matched_client_id, matched_manifest_id,
   assignment_status, confidence, source, flags, created_at, updated_at)
SELECT
  (SELECT min(a.dump_folder) FROM derm.address_row_map a WHERE a.white_manifest_number=dm.white_manifest_number),
  dm.white_manifest_number, 1,
  (SELECT coalesce(max(a.row_index),0)+1 FROM derm.address_row_map a WHERE a.white_manifest_number=dm.white_manifest_number),
  (SELECT min(a.image_url) FROM derm.address_row_map a WHERE a.white_manifest_number=dm.white_manifest_number),
  NULL, dm.client_id, dm.id,
  'matched','high','linked-backfill','{"linked_card_backfill":true}'::jsonb, now(), now()
FROM public.derm_manifests dm
WHERE dm.deleted_at IS NULL
  AND dm.white_manifest_number IN (SELECT DISTINCT white_manifest_number FROM derm.address_row_map WHERE white_manifest_number IS NOT NULL)
  AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id=dm.id)
  AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                   WHERE r.white_manifest_number=dm.white_manifest_number AND r.matched_client_id=dm.client_id);
COMMIT;
