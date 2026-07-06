-- 2026-07-06_827989_page4_backfill.sql
-- Fred: Stamp Studio showed 827989 as 3 pages; it has 4. Root cause: the 4th
-- signed page (found earlier, commit 5fb39bd) WAS uploaded — its image rides all
-- 19 manifests' derm_address_extra_urls as .../derm/1228/address_4_...jpg — but
-- its 5 facilities were never ingested into derm.address_row_map, so the stamp
-- tool had no page-4 rows to render (14 of 19 facilities present; 5 missing).
-- Fix: insert the 5 missing facility rows as page 4, matched to their (already
-- linked) manifests, pointing at the real address_4 image. Deterministic — the 5
-- are exactly the 827989 manifest client-entries absent from the row map (no OCR
-- needed). Idempotent (ON CONFLICT). Backup: backups/2026-07-06_827989_page4_backfill_backup.json
-- (page 4 had 0 rows before; revert = DELETE ... WHERE dump_folder='derm/1218' AND page=4).
-- address_row_map is audited; INSERTs logged. Verified live: v_stamp_sheets
-- page_count 3->4, total_rows 19; page-4 image HTTP 200; 5 cards render (all LINKED).

INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   facility_name_read, address_read, matched_client_id, matched_manifest_id,
   assignment_status, confidence, agent_agreement, flags, source)
VALUES
  ('derm/1218','827989',4,1,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg','Pamplemousse On the bay','910 West Avenue Miami Beach FL',278,1220,'matched','high','backfill','{"page4_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1218','827989',4,2,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg','The carrot express 71st Collins','7145 Collins Avenue Miami Beach FL',281,1223,'matched','high','backfill','{"page4_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1218','827989',4,3,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg','The carrot express Kendall','8880 Southwest 72nd Place Kendall FL',19,1219,'matched','high','backfill','{"page4_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1218','827989',4,4,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg','Pura Vida Flamingo','1504 Bay Road Miami Beach FL',339,1221,'matched','high','backfill','{"page4_backfill":true}'::jsonb,'page4-backfill'),
  ('derm/1218','827989',4,5,'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg','Cheeseteak','1522 Washington Avenue Miami Beach FL',468,1222,'matched','high','backfill','{"page4_backfill":true}'::jsonb,'page4-backfill')
ON CONFLICT (dump_folder, page, row_index) DO NOTHING;
