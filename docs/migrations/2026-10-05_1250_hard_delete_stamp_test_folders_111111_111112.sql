-- HARD DELETE of the Stamp Studio test folders ticket-111111 and ticket-111112
--
-- Fred, 2026-10-05: "Remove the tests folders 111111 and 111112 even from the DB, a hard delete."
-- An explicit, named exception to rule 6 (never hard-delete): both are 112-YA test data (client 381,
-- the sanctioned test client). Their manifests 1939/1940 were soft-deleted on 2026-09-18, but the
-- Stamp cards 2978/2979 stayed, so the two folders kept showing in the Studio as "in progress".
--
-- WHAT GOES (44 rows, every DELETE pinned to primary keys with an exact row-count assertion; any
-- mismatch rolls the whole block back):
--   derm.address_row_map 2 (cards 2978, 2979) · derm.page_slots 5 · derm.page_row_rules 12 ·
--   derm.page_rule_scans 3 · derm.page_block_extents 2 · derm.address_sheet_row_reads 5 ·
--   derm.generated_measure_attempts 1 · derm.row_ocr_attempts 1 · derm.stamp_sheet_status 2 ·
--   derm.redacted_manifest_docs 2 · derm.receipt_doc_class 2 · derm.address_sheet_manifests 1 ·
--   public.manifest_visits 2 · public.derm_email_sends 2 (is_test sends 174, 175: their NOT NULL
--   NO ACTION FK would otherwise block the manifest delete) · public.derm_manifests 2 (1939, 1940).
-- Plus 8 storage files (6 in `manifests`, 2 in `GT - Visits Images`, 2,888,516 bytes) removed
-- through the Storage API after this commits (storage.protect_delete refuses a SQL delete).
--
-- BACKUP, taken first: backups/2026-10-05_stamp_test_folders_111111_111112.json (44 rows + the 8
-- file records) and backups/2026-10-05_stamp_test_folders_files/ (the 8 files). Seven of these
-- tables have NO audit trigger (page_row_rules, page_rule_scans, address_sheet_row_reads,
-- generated_measure_attempts, row_ocr_attempts, redacted_manifest_docs, receipt_doc_class), so for
-- those 26 rows the backup is the only restore path. The audited ones also get DELETE rows with
-- old_row in audit.logs. Never commit the backup (it holds test recipient addresses).
--
-- KEPT on purpose: visits 8107/8108 (test visits, already soft-deleted, not part of the folder),
-- derm.address_sheets 157/158 (#1119/#1120: the sheet-number ledger, so those numbers are never
-- reused), the existing audit.logs history, and ticket-111113 (manifest 1941, a third test folder,
-- live and completed, not named by Fred).
-- Triggers checked: the DELETE fires audit, trg_zz_dirty_on_card_change (both statuses already
-- completed=false, no-op) and the realtime cache invalidation only. Inventory and plan:
-- the 2026-10-05 Stamp Studio rework (Building Apps/DERM Stamp Studio/docs/08-changelog.md).

begin;

DO $$
DECLARE n int;
BEGIN
  -- Preflight: identity of the two manifests and the two cards
  IF (SELECT count(*) FROM public.derm_manifests
       WHERE (id, white_manifest_number) IN ((1939,'111111'),(1940,'111112'))
         AND client_id = 381 AND deleted_at IS NOT NULL) <> 2
  THEN RAISE EXCEPTION 'preflight: 1939/1940 are not the soft-deleted 112-YA test manifests'; END IF;
  IF (SELECT count(*) FROM derm.address_row_map
       WHERE (id, dump_folder) IN ((2978,'ticket-111111'),(2979,'ticket-111112'))) <> 2
  THEN RAISE EXCEPTION 'preflight: cards 2978/2979 not as inventoried'; END IF;
  -- Preflight: nothing new appeared that the inventory did not see
  IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder IN ('ticket-111111','ticket-111112') AND id NOT IN (2978,2979))
  OR EXISTS (SELECT 1 FROM derm.address_row_map WHERE matched_manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM derm.band_review WHERE row_id IN (2978,2979))
  OR EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads WHERE dump_folder IN ('ticket-111111','ticket-111112'))
  OR EXISTS (SELECT 1 FROM derm.sheet_number_ocr_attempts WHERE dump_folder IN ('ticket-111111','ticket-111112'))
  OR EXISTS (SELECT 1 FROM derm.manifest_visit_sheets WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM derm.manifest_document_detachments WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM derm.redacted_manifest_errors WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM public.derm_manifest_number_proposals WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM public.derm_portal_submissions WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM public.derm_portal_requeue WHERE manifest_id IN (1939,1940))
  OR EXISTS (SELECT 1 FROM public.lwt_filing_tickets WHERE manifest_id IN (1939,1940))
  THEN RAISE EXCEPTION 'preflight: a dependent row appeared since the 2026-10-05 inventory; re-inventory first'; END IF;

  DELETE FROM derm.address_row_map WHERE (id, dump_folder) IN ((2978,'ticket-111111'),(2979,'ticket-111112'));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'address_row_map: % (expected 2)', n; END IF;

  DELETE FROM derm.page_slots WHERE dump_folder = 'ticket-111112' AND effective_page = 1 AND slot_index IN (1,2,3,4,5);
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 5 THEN RAISE EXCEPTION 'page_slots: % (expected 5)', n; END IF;
  IF EXISTS (SELECT 1 FROM derm.page_slots WHERE dump_folder IN ('ticket-111111','ticket-111112'))
  THEN RAISE EXCEPTION 'page_slots: rows left for the folders'; END IF;

  DELETE FROM derm.page_row_rules
   WHERE (dump_folder, effective_page, source) IN (('ticket-111111',1,'template-v1-2026-09-14'),('ticket-111112',1,'human-v1-2026-09-15'));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 12 THEN RAISE EXCEPTION 'page_row_rules: % (expected 12)', n; END IF;

  DELETE FROM derm.page_rule_scans
   WHERE (dump_folder, effective_page, source) IN (('ticket-111111',1,'template-v1-2026-09-14'),('ticket-111112',1,'human-v1-2026-09-15'),('ticket-111112',1,'runlen-v2-2026-09-15'));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 3 THEN RAISE EXCEPTION 'page_rule_scans: % (expected 3)', n; END IF;

  DELETE FROM derm.page_block_extents WHERE (dump_folder, effective_page) IN (('ticket-111111',1),('ticket-111112',1));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'page_block_extents: % (expected 2)', n; END IF;

  DELETE FROM derm.address_sheet_row_reads WHERE dump_folder = 'ticket-111112' AND page = 1 AND row_index IN (1,2,3,4,5);
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 5 THEN RAISE EXCEPTION 'address_sheet_row_reads: % (expected 5)', n; END IF;

  DELETE FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-111111' AND page = 1;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'generated_measure_attempts: % (expected 1)', n; END IF;

  DELETE FROM derm.row_ocr_attempts WHERE ticket = '111112';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'row_ocr_attempts: % (expected 1)', n; END IF;

  DELETE FROM derm.stamp_sheet_status WHERE dump_folder IN ('ticket-111111','ticket-111112');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'stamp_sheet_status: % (expected 2)', n; END IF;

  DELETE FROM derm.redacted_manifest_docs WHERE (manifest_id, effective_page) IN ((1939,1),(1940,1));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'redacted_manifest_docs: % (expected 2)', n; END IF;

  DELETE FROM derm.receipt_doc_class WHERE url IN (
    'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1939/manifest_1.jpg',
    'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1940/manifest_1.jpg');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'receipt_doc_class: % (expected 2)', n; END IF;

  DELETE FROM derm.address_sheet_manifests WHERE (sheet_id, manifest_id) = (157, 1939);
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'address_sheet_manifests: % (expected 1)', n; END IF;

  DELETE FROM public.manifest_visits WHERE (manifest_id, visit_id) IN ((1939,8107),(1940,8108));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'manifest_visits: % (expected 2)', n; END IF;

  DELETE FROM public.derm_email_sends WHERE id IN (174,175) AND manifest_id IN (1939,1940) AND is_test;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'derm_email_sends: % (expected 2)', n; END IF;

  DELETE FROM public.derm_manifests
   WHERE (id, white_manifest_number) IN ((1939,'111111'),(1940,'111112')) AND client_id = 381 AND deleted_at IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 2 THEN RAISE EXCEPTION 'derm_manifests: % (expected 2)', n; END IF;
END $$;

commit;
