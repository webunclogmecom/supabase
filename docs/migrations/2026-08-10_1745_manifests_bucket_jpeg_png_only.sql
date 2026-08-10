-- 2026-08-10_1745_manifests_bucket_jpeg_png_only.sql
--
-- WHAT: restrict the `manifests` bucket to image/jpeg + image/png.
--
-- WHY: Fred, 2026-08-10: "we need to make the DERM App, when someone uploads the derm it has to be a
--      format a decoder can read, which i guess would be png and jpeg right?" Yes, and this is the
--      DB half of that. The app half (a narrowed `accept` plus client-side validation plus
--      orientation normalisation) ships alongside in the DERM Tracker.
--
-- THE DECODER IS THE CONSTRAINT. `redact-manifest-sheet` decodes with ImageScript, which reads
--   JPEG / PNG / TIFF / GIF and **not WebP**. A WebP sheet is therefore unredactable, and because the
--   Field Portal serves only the REDACTED copy of a shared sheet, an unredactable source means the
--   customer sees a DOCUMENTED chip and no image. That is exactly what happened to ticket 310607:
--   4 manifests, 4 clients, `Unsupported image type`, from 2026-08-03 until today.
--
-- MEASURED BEFORE RESTRICTING (711 objects in the bucket):
--     image/jpeg ......... 702
--     image/png .......... 6
--     image/webp ......... 2    <- both derm/1667/, the stuck ticket, now superseded by .jpg
--     application/pdf .... 1    <- orphaned: NO manifest row references it
--   So 708 of 711 already comply and nothing in use is excluded.
--
-- ⚠ WHAT THE OLD LIST ACTUALLY ALLOWED, which is worse than it reads. `image/*` admitted WebP (the
--   bug), and also **image/svg+xml on a PUBLIC bucket**, which is a stored-XSS shape. `video/*` on a
--   bucket of scanned compliance forms was never meaningful. Narrowing removes all three.
--
-- ⚠ EXISTING OBJECTS ARE NOT AFFECTED. allowed_mime_types gates new uploads only, so the orphaned
--   PDF and the two superseded WebP files stay reachable. This is deliberate: they are evidence of
--   what happened, and deleting compliance artefacts to make a config tidy is the wrong trade.
--
-- ⚠ FORMAT IS ONLY HALF THE HAZARD. A perfectly valid JPEG can still carry an EXIF orientation flag,
--   and the Stamp Studio places bands on the BROWSER-DISPLAYED (rotated) image while the decoder
--   sees the stored pixels. `derm/1691/address_1.JPG` was exactly that (orientation 8, stored
--   1264x1576, displayed 1576x1264) and the function refused it rather than draw boxes in the wrong
--   place. A mime allow-list cannot express that. **The app must also normalise orientation at
--   upload** (decode, apply EXIF, re-encode with no orientation tag), which is the other half of the
--   DERM Tracker change. Do not read this migration as having closed the rotation case.
--
-- WRITERS CHECKED: only `redact-manifest-sheet` writes to this bucket from the edge functions, and
--   it uploads image/jpeg. `get-derm-doc` and `send-derm-email` only read. The other writer is the
--   DERM Tracker app (51 objects under contact@unclogme.com). Nothing uploads PDFs here.
--
-- AUDIT (ADR 010): storage.buckets is Supabase-managed infrastructure config with no audit trigger.
--   This file is the record.

BEGIN;

UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['image/jpeg', 'image/png']
 WHERE id = 'manifests';

DO $$
DECLARE b record; n int;
BEGIN
  SELECT * INTO b FROM storage.buckets WHERE id = 'manifests';
  IF b.id IS NULL THEN RAISE EXCEPTION 'bucket manifests does not exist - wrong project?'; END IF;

  -- (a) the narrowing landed, and BOTH formats survived
  IF NOT ('image/jpeg' = ANY(b.allowed_mime_types)) THEN
    RAISE EXCEPTION 'image/jpeg was dropped - 702 objects and every redaction output are jpeg'; END IF;
  IF NOT ('image/png' = ANY(b.allowed_mime_types)) THEN
    RAISE EXCEPTION 'image/png was dropped - 6 live sheet sources are png'; END IF;
  IF array_length(b.allowed_mime_types, 1) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 allowed types, got %', b.allowed_mime_types; END IF;

  -- (b) the size cap and visibility are unchanged; this migration is about format only
  IF b.file_size_limit <> 52428800 THEN
    RAISE EXCEPTION 'file_size_limit changed to % - not this migration''s business', b.file_size_limit; END IF;

  -- (c) CONTROL: prove the UPDATE was scoped. An unscoped UPDATE satisfies (a) and (b) while
  --     silently rewriting every other bucket.
  SELECT count(*) INTO n FROM storage.buckets
   WHERE id <> 'manifests'
     AND allowed_mime_types @> ARRAY['image/jpeg','image/png']
     AND array_length(allowed_mime_types, 1) = 2;
  IF n <> 1 THEN
    -- exactly ONE other bucket legitimately carries this list: rpa-evidence (2026-08-06_2210).
    RAISE EXCEPTION 'CONTROL FAILED: % other buckets match the new list, expected exactly 1 (rpa-evidence)', n;
  END IF;

  -- (d) existing objects are untouched
  SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'manifests';
  IF n < 700 THEN RAISE EXCEPTION 'manifests object count collapsed to % - something deleted objects', n; END IF;

  -- (e) every LIVE sheet source is now a format the decoder can read
  SELECT count(*) INTO n
    FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL
     AND (m.derm_address_url ~* '\.(webp|svg|pdf|heic|heif|bmp)$'
       OR m.derm_manifest_url ~* '\.(webp|svg|pdf|heic|heif|bmp)$');
  IF n <> 0 THEN
    RAISE EXCEPTION '% live manifest(s) still reference an undecodable source', n;
  END IF;

  RAISE NOTICE 'OK: manifests restricted to %, % objects intact, 0 undecodable live sources',
    b.allowed_mime_types, (SELECT count(*) FROM storage.objects WHERE bucket_id='manifests');
END $$;

COMMIT;
