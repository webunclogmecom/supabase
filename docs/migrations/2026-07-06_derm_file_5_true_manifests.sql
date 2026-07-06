-- 2026-07-06_derm_file_5_true_manifests.sql
-- Fred approved (checked each on the DERM App / address image): file the manifest
-- for 5 clients that were serviced on a dump but had no manifest -- their visit was
-- sitting on a DIFFERENT client's manifest (cross-client mis-link). For each: create
-- a derm_manifests row for the true client (service_date = the visit's date;
-- white form / address sheet / disposal facility / dump date inherited from a
-- doc-bearing sibling on the same ticket; WWTP null -- none of these tickets have a
-- receipt yet), then MOVE the anchor visit onto it. The auto-resolve trigger points
-- any existing (ticket, client) card at the new manifest.
--
--   #816562  193-FRK Fresko Bakery      v1351 (2026-02-04)  off 192-FRK m712  -> new m1292
--   #824713  215-G7  Kitchen 35         v5088 (2026-05-13)  off 116-HIK m1032 -> new m1293 (no card yet)
--   #825906  034-LG  La Granja Calle 8  v5158 (2026-05-28)  off 214-MYK m1171 -> new m1294
--   #826661  214-MYK Myka Brickell      v5745 (2026-06-04)  off 032-LG m1189  -> new m1295
--   #827172  133-MUT Mutra              v5785 (2026-06-10)  off 055-PV m1213  -> new m1296
--
-- SKIPPED: #815064 (144-LTG) -- Fred sent it to Diego for a manual checkup.
-- Backup: backups/2026-07-06_file_5_manifests_backup.json (the moved manifest_visits rows).
-- Verified: each new manifest has exactly 1 visit; cross-client links now = 1 (only
-- the Diego one, 815064). 215-G7's m1293 has no card -> seeded via the 829201/missing-card
-- backfill (2026-07-06). Audited (app_source='sql'). One-time; new ids were 1292-1296.

BEGIN;
DO $mig$
DECLARE rec record; v_cid bigint; v_vdate date; sib public.derm_manifests%ROWTYPE; new_mid bigint;
BEGIN
  FOR rec IN SELECT * FROM (VALUES
    ('816562','193-FRK',1351,712),
    ('824713','215-G7',5088,1032),
    ('825906','034-LG',5158,1171),
    ('826661','214-MYK',5745,1189),
    ('827172','133-MUT',5785,1213)
  ) AS t(wm, code, vid, wrong_mid)
  LOOP
    SELECT id INTO v_cid FROM public.clients WHERE client_code=rec.code;
    SELECT visit_date INTO v_vdate FROM public.visits WHERE id=rec.vid::bigint;
    SELECT * INTO sib FROM public.derm_manifests
      WHERE white_manifest_number=rec.wm AND deleted_at IS NULL AND derm_manifest_url IS NOT NULL ORDER BY id LIMIT 1;
    INSERT INTO public.derm_manifests
      (white_manifest_number, client_id, service_date, derm_manifest_url, derm_address_url,
       derm_address_extra_urls, wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
      VALUES (rec.wm, v_cid, v_vdate, sib.derm_manifest_url, sib.derm_address_url,
       COALESCE(sib.derm_address_extra_urls,'{}'::text[]), sib.wwtp_receipt_document_path,
       sib.disposal_facility_id, sib.dump_ticket_date)
      RETURNING id INTO new_mid;
    DELETE FROM public.manifest_visits WHERE manifest_id=rec.wrong_mid::bigint AND visit_id=rec.vid::bigint;
    INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (new_mid, rec.vid::bigint) ON CONFLICT DO NOTHING;
  END LOOP;
END $mig$;
COMMIT;
