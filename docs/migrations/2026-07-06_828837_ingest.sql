-- 2026-07-06_828837_ingest.sql
-- 828837 (dump_ticket, Jun 30) had ZERO address_row_map rows — its single
-- address sheet (manifests/derm/1252/address_1.JPG, 4 facilities) was never
-- ingested, so it didn't appear in Stamp Studio at all. Its 4 manifest
-- client-entries are unambiguous and all on the one page, so backfill them
-- (matched to their manifests) so the sheet appears + is stampable.
-- Idempotent. Backup: backups/2026-07-06_828837_ingest_backup.json.
-- (829201 is the sibling zero-row case but has 2 pages / 10 clients with an
-- unknown page split -> needs a proper OCR pass, not a blind insert.)

INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   facility_name_read, address_read, matched_client_id, matched_manifest_id,
   assignment_status, confidence, agent_agreement, flags, source)
VALUES
  ('derm/1252','828837',1,1,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/address_1.JPG','Bagel Boss Boca Raton','22107 Powerline Road Boca Raton FL',301,1252,'matched','high','backfill','{"page_ingest_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1252','828837',1,2,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/address_1.JPG','Grove Kosher LLC (Boca Raton)','22191 Powerline Road Palms Plaza Boca Raton FL',357,1253,'matched','high','backfill','{"page_ingest_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1252','828837',1,3,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/address_1.JPG','Pura Vida Boca Park Plaza','5570 North Military Trail Boca Raton FL',255,1254,'matched','high','backfill','{"page_ingest_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1252','828837',1,4,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/address_1.JPG','Grove Kosher LLC (Delray Beach)','7351 West Atlantic Avenue Delray Beach FL',291,1255,'matched','high','backfill','{"page_ingest_backfill":true}'::jsonb,'page4-backfill')
ON CONFLICT (dump_folder, page, row_index) DO NOTHING;
