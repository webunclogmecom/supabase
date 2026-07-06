-- 2026-07-06_derm_cross_client_mislink_cluster_fix.sql
-- Yannick's Stamp Studio review surfaced manifests showing the wrong / missing
-- visit cards. Root cause = a fleet-wide class of CROSS-CLIENT mis-links:
-- manifest_visits rows where derm_manifests.client_id <> visits.client_id (a
-- manifest holding another client's visit). A fleet sweep found 19 such links.
-- The visit.client_id is Jobber-trusted (ground truth), so the MANIFEST is the
-- mis-attributed side. This migration fixes the CLEAR, Yannick/Fred-flagged
-- cluster (6 links across 5 tickets); the remaining fleet links are being
-- audited separately, and the same-address sibling pairs (139/144-LTG identical
-- address, 192/193-FRK adjacent units) are FLAGGED for Fred (possible one
-- physical location under two Jobber codes -- not auto-fixed).
--
-- Adversarially verified before applying (3-skeptic workflow -> GO_WITH_CORRECTIONS,
-- 0 blockers). Corrections it caught and that are baked in below:
--   * doc URLs are NOT inherited by fn_derm_inherit_ticket_fields (only dump_date
--     + facility) -> the 2 new manifests copy derm_manifest_url/derm_address_url/
--     derm_address_extra_urls from a doc-bearing ticket sibling, else they'd be P1
--     'has_number_no_pdfs' gaps.
--   * client 93 had TWO cards (246 + 410) -> re-point BOTH.
--   * derm_manifests.id is GENERATED ALWAYS AS IDENTITY -> never supply id.
--   * card 104 (matched_client_id NULL) won't auto-resolve -> set client+manifest
--     manually; card 266 (client already matched) DOES auto-resolve via
--     trg_resolve_card_manifest -> leave it to the trigger.
-- Backup (before-state of all touched rows): backups/2026-07-06_mislink_cluster_fix_backup.json
--
-- WHAT WAS WRONG -> FIX (all wrapped in one DO-block transaction):
--   #825666  m1192 (013-DIM) held 224-MP's v5139  -> file 224-MP manifest, move v5139, point card 104.
--   #822621  m295  (phantom 93) held 150-KOS v1773 -> re-point m295 client 93->336, point card 246.
--   #817533  m574  (phantom 93) held 150-KOS v1402 -> re-point m574 client 93->336, point card 410.
--   #822415  m121  (025-GRO) held 150-KOS v1773 (double-linked; its home is #822621 where the KOSH
--                   card lives) -> DELETE the spurious link. m946 (148-MOR) held 016-FIA v1614 ->
--                   file 016-FIA manifest, move v1614 (card 266 auto-resolves).
--   #824949  m1058 (082-TFC) held 221-YAS v5101 + 222-SPE v5100 -> move each to its own (already
--                   existing, empty) manifest m1050 / m1120 (cards 165/164 already matched -> light up).
--
-- Post-verify (all passed): 0 cross-client links remain on the 5 tickets; phantom
-- client 93 = 0 live manifests + 0 cards; every moved visit on exactly 1 manifest;
-- all 6 cards resolve. Audit triggers fired (app_source='sql').
--
-- Re-runnable? NO (one-time data correction; new manifest ids were 1290/1291).
-- The actual applied logic is scripts-equivalent to the DO block below.

BEGIN;
DO $$
DECLARE n1 bigint; n2 bigint; sib1 public.derm_manifests%ROWTYPE; sib2 public.derm_manifests%ROWTYPE;
BEGIN
  -- M1 #825666 224-MP
  SELECT * INTO sib1 FROM public.derm_manifests
    WHERE white_manifest_number='825666' AND deleted_at IS NULL AND derm_manifest_url IS NOT NULL ORDER BY id LIMIT 1;
  INSERT INTO public.derm_manifests
    (white_manifest_number, client_id, service_date, derm_manifest_url, derm_address_url,
     derm_address_extra_urls, wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES ('825666', 459, DATE '2026-05-26', sib1.derm_manifest_url, sib1.derm_address_url,
     COALESCE(sib1.derm_address_extra_urls,'{}'::text[]), sib1.wwtp_receipt_document_path,
     sib1.disposal_facility_id, sib1.dump_ticket_date)
    RETURNING id INTO n1;
  DELETE FROM public.manifest_visits WHERE manifest_id=1192 AND visit_id=5139;
  INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (n1, 5139) ON CONFLICT DO NOTHING;
  UPDATE derm.address_row_map SET matched_client_id=459, matched_manifest_id=n1 WHERE id=104;

  -- M2 phantom 93 -> 150-KOS (336): m295 (#822621) + m574 (#817533); re-point BOTH cards
  UPDATE public.derm_manifests SET client_id=336 WHERE id IN (295,574);
  UPDATE derm.address_row_map SET matched_client_id=336 WHERE id IN (246,410);

  -- M3 #822415: drop spurious 150-KOS link; file 016-FIA + move v1614 (card 266 auto-resolves)
  DELETE FROM public.manifest_visits WHERE manifest_id=121 AND visit_id=1773;
  SELECT * INTO sib2 FROM public.derm_manifests
    WHERE white_manifest_number='822415' AND deleted_at IS NULL AND derm_manifest_url IS NOT NULL ORDER BY id LIMIT 1;
  INSERT INTO public.derm_manifests
    (white_manifest_number, client_id, service_date, derm_manifest_url, derm_address_url,
     derm_address_extra_urls, wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES ('822415', 319, DATE '2026-04-22', sib2.derm_manifest_url, sib2.derm_address_url,
     COALESCE(sib2.derm_address_extra_urls,'{}'::text[]), sib2.wwtp_receipt_document_path,
     sib2.disposal_facility_id, sib2.dump_ticket_date)
    RETURNING id INTO n2;
  DELETE FROM public.manifest_visits WHERE manifest_id=946 AND visit_id=1614;
  INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (n2, 1614) ON CONFLICT DO NOTHING;

  -- M4 #824949: move 221-YAS/222-SPE visits to their own (empty) manifests off 082-TFC
  DELETE FROM public.manifest_visits WHERE manifest_id=1058 AND visit_id=5100;
  INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1120, 5100) ON CONFLICT DO NOTHING;
  DELETE FROM public.manifest_visits WHERE manifest_id=1058 AND visit_id=5101;
  INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1050, 5101) ON CONFLICT DO NOTHING;
END $$;
COMMIT;

-- FOLLOW-UP: phantom client 93 "Panino  Kosher" (client_code NULL, 0 visits, now 0 manifests)
-- should be deactivated/merged -- flagged to Fred. Remaining 13 fleet cross-client links + the
-- OCR card-match audit tracked separately (2026-07-06 OCR feature audit).
