-- 2026-08-10_1720_derm_source_repoint_webp_to_jpeg.sql
--
-- WHAT: repoint every reference to the two WebP DERM sheet sources at the JPEG copies that now sit
--       beside them, so redact-manifest-sheet can read them.
--
-- WHY: Fred, 2026-08-10: "fix the webp and exif ones too", and then "when someone uploads the derm
--      it has to be a format a decoder can read, which i guess would be png and jpeg right?" - yes.
--      ImageScript (the decoder in redact-manifest-sheet) reads JPEG/PNG/TIFF/GIF and NOT WebP, so
--      ticket 310607 recorded `Unsupported image type` for all 4 of its manifests and served its
--      clients a DOCUMENTED chip with no image.
--
-- 🛑 WHY NORMALISE THE SOURCE INSTEAD OF TEACHING THE FUNCTION TO READ WEBP.
--   The alternative was a WebP decoder inside an edge function that runs on a ~2s CPU budget and
--   whose job is drawing opaque boxes onto customer-facing compliance documents. Normalising the
--   source needs NO change to that function, so the already-verified redaction path is reused
--   unaltered. It also fixes the file for every OTHER consumer (the FP preview and download, the
--   email attachment, the PDF service), not just redaction.
--   The bucket is being restricted to image/jpeg + image/png in the same cycle, so this cannot recur.
--
-- ⚠ THE SAME PASS ALSO FIXED AN EXIF CASE, WHICH NEEDED NO SQL AT ALL.
--   derm/1691/address_1.JPG (ticket 832194 page 1) carried EXIF orientation 8: stored 1264x1576,
--   displayed 1576x1264. The Stamp Studio bands were placed on the BROWSER-DISPLAYED image, so the
--   function refused it rather than draw boxes against the unrotated pixels. It was rewritten in
--   place with the rotation baked in and the orientation tag stripped, so it is now 1576x1264 with
--   orientation 1 and the bands apply directly. Same path, same extension, no reference to update.
--   ⇒ I deliberately did NOT add orientation-8 handling to the function. ImageScript's
--     Image.rotate(a) delegates to framebuffer.rotate(360 - a) and then into WASM, so the direction
--     is two layers down and I had no Deno available to prove it. Guessing the direction inside the
--     one function that can expose another client's row is not a trade worth making.
--
-- SURVEY BEFORE ACTING: all 101 distinct sheet sources referenced by live manifests were probed for
--   both hazards. Exactly 3 objects were affected, and they are the 3 handled here and above; there
--   are no other latent failures. (Control: the probe did detect the orientation-8 file, so its zero
--   for every other file is a real zero.)
--
-- 🛑 THREE TABLES REFERENCE THESE URLS, NOT ONE. Missing any of them breaks something quietly:
--     public.derm_manifests      4 rows  (derm_address_url + derm_manifest_url)
--     derm.receipt_doc_class     1 row   <- keyed BY URL. Left behind, the WWTP receipt card would
--                                           silently stop rendering, because the Field Portal only
--                                           serves a receipt whose URL is classified safe.
--     derm.address_row_map       3 rows  (image_url, used by the page-identity gate)
--
-- AUDIT (ADR 010): public.derm_manifests carries audit_derm_manifests, so these UPDATEs are logged.
--   derm.address_row_map is also audited. derm.receipt_doc_class is classification metadata and is
--   not audited; this file is its record.

BEGIN;

UPDATE public.derm_manifests
   SET derm_address_url  = replace(derm_address_url,  '/1667/address_1.webp',  '/1667/address_1.jpg'),
       derm_manifest_url = replace(derm_manifest_url, '/1667/manifest_1.webp', '/1667/manifest_1.jpg')
 WHERE derm_address_url LIKE '%/1667/address_1.webp'
    OR derm_manifest_url LIKE '%/1667/manifest_1.webp';

UPDATE derm.receipt_doc_class
   SET url = replace(url, '/1667/manifest_1.webp', '/1667/manifest_1.jpg')
 WHERE url LIKE '%/1667/manifest_1.webp';

UPDATE derm.address_row_map
   SET image_url = replace(image_url, '/1667/address_1.webp', '/1667/address_1.jpg')
 WHERE image_url LIKE '%/1667/address_1.webp';

DO $$
DECLARE n int; cls text;
BEGIN
  -- (a) nothing anywhere still points at a .webp
  SELECT (select count(*) from public.derm_manifests
            where derm_address_url like '%.webp' or derm_manifest_url like '%.webp')
       + (select count(*) from derm.receipt_doc_class where url like '%.webp')
       + (select count(*) from derm.address_row_map where image_url like '%.webp')
    INTO n;
  IF n <> 0 THEN RAISE EXCEPTION '% reference(s) still point at a .webp', n; END IF;

  -- (b) the repoint actually landed on all four manifests
  SELECT count(*) INTO n FROM public.derm_manifests
   WHERE derm_address_url LIKE '%/1667/address_1.jpg';
  IF n <> 4 THEN RAISE EXCEPTION 'expected 4 manifests on the new address jpg, got %', n; END IF;

  -- (c) 🛑 the receipt classification MUST have followed the rename, or the FP hides the receipt
  SELECT class INTO cls FROM derm.receipt_doc_class WHERE url LIKE '%/1667/manifest_1.jpg';
  IF cls IS DISTINCT FROM 'receipt' THEN
    RAISE EXCEPTION 'receipt classification did not follow the rename (got %) - the WWTP card would go blank', cls;
  END IF;

  -- (d) CONTROL: prove (a) is not vacuous. Some rows DID have to move, so the counts must be
  --     non-zero on the new side. A migration that matched nothing would also satisfy (a).
  SELECT (select count(*) from public.derm_manifests where derm_address_url like '%/1667/%.jpg')
       + (select count(*) from derm.receipt_doc_class where url like '%/1667/%.jpg')
       + (select count(*) from derm.address_row_map where image_url like '%/1667/%.jpg')
    INTO n;
  IF n <> 4 + 1 + 3 THEN
    RAISE EXCEPTION 'CONTROL: expected 8 rows now on the jpg urls (4 manifests + 1 class + 3 row-map), got %', n;
  END IF;
  -- ⚠ First run of this file aborted here expecting 7: I transcribed the row-map count as 2 when the
  --   survey had said 3. The abort was the control working, not a data problem. Verified against the
  --   survey before changing the number rather than bumping it until it passed.

  RAISE NOTICE 'OK: 310607 repointed to jpeg across manifests, receipt class and row map';
END $$;

COMMIT;
