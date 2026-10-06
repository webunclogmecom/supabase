-- ============================================================================
-- 2026-10-06 · Hard delete of TEST manifest 111112 (public.derm_manifests 2018, client 112-YA)
-- ============================================================================
-- Fred, 2026-10-06: "anything related to manifest 111112 hard delete it". A test filing on the sanctioned test
-- client 112-YA (visit 8742): filed 12:17 ET from the DERM Tracker, soft-deleted 12:18:54 ET.
-- An explicit hard-delete instruction, so the soft-delete-only rule is set aside for these rows only.
-- Found by a sweep of every row in public, derm, ops, client, customer, raw, private for the text "111112" or
-- "/derm/2018/" (2 coincidental hits in vehicle_telemetry_readings, GPS digits, not touched):
--   public.manifest_visits         (8742, 2018)       1
--   derm.receipt_doc_class         manifest_1.jpg url 1
--   derm.address_row_map           ticket-111112      1   (the card made by trg_zz_card_from_link)
--   derm.page_rule_scans           ticket-111112      1   (the background measuring, FAILED)
--   derm.page_reference_attempts   ticket-111112      1
--   public.derm_manifests          id 2018            1
-- Storage objects manifests/derm/2018/manifest_1.jpg and address_1.jpg are removed through the Storage API
-- after this file. KEPT on purpose: audit.logs rows (the audit trail of the filing, the link and this delete).
-- Backup (local, not in git): backups/2026-10-06_manifest_111112_before_hard_delete.json + _photos/.
-- Visit 8742 is not changed (still DERM not required, locked, as set in the DERM Tracker at 11:58 ET).
-- ============================================================================
BEGIN;
DO $d$
DECLARE n int;
BEGIN
  IF (SELECT count(*) FROM public.derm_manifests WHERE id = 2018 AND white_manifest_number = '111112'
        AND client_id = 381 AND deleted_at IS NOT NULL) <> 1 THEN
    RAISE EXCEPTION 'manifest 2018 is not the soft-deleted 112-YA 111112; stop'; END IF;
  DELETE FROM public.manifest_visits WHERE manifest_id = 2018;  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'manifest_visits: % rows', n; END IF;
  DELETE FROM derm.receipt_doc_class WHERE url LIKE '%/manifests/derm/2018/%';  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'receipt_doc_class: % rows', n; END IF;
  DELETE FROM derm.address_row_map WHERE dump_folder = 'ticket-111112';  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'address_row_map: % rows', n; END IF;
  DELETE FROM derm.page_rule_scans WHERE dump_folder = 'ticket-111112';  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'page_rule_scans: % rows', n; END IF;
  DELETE FROM derm.page_reference_attempts WHERE dump_folder = 'ticket-111112';  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'page_reference_attempts: % rows', n; END IF;
  DELETE FROM public.derm_manifests WHERE id = 2018;  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'derm_manifests: % rows', n; END IF;
END
$d$;
COMMIT;
