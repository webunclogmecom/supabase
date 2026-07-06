-- 2026-07-06_stamp_pages_from_manifest_images.sql
-- ROOT FIX (Fred): the Stamp app showed fewer pages than the DERM app for some
-- tickets (e.g. 827989 3-vs-4) because it built its page list from the OCR-
-- ingested rows (derm.address_row_map) instead of the manifest's own image list
-- (derm_manifests.derm_address_url + derm_address_extra_urls) that the DERM app
-- uses. Two DB sources => drift. Fix: derive the Stamp sheet's page images from
-- the manifest image list, so both apps read the same source and no page can be
-- missing. Cards still come from rows; a page with no rows shows the image so
-- Yannick can "+ Add client" onto it (the new modal).
--
-- Dedup is CONTENT-based (storage eTag), so path-drift copies of the SAME page
-- under different folders (e.g. 824949 folder 1044 vs 1057 — byte-identical,
-- same eTag) collapse to one page, while genuinely-distinct pages (826477's
-- 1178/address_1 vs 1173/address_1 — different eTags) are appended.
--
--   derm._img_etag(url)  -> resolves a public storage URL to its eTag
--                           (SECURITY DEFINER: anon can't read storage.objects).
--   derm.sheet_page_images(dump_folder) -> ordered page-image list =
--       row-map pages (kept in place, so existing cards' page numbers are
--       stable) + any manifest address image whose eTag isn't already present.
--   v_stamp_sheets.page_image_urls / page_count now come from that function.
--
-- Safe + additive: existing rows/cards/pages are never moved; only missing
-- pages are appended. Degrades gracefully (if storage isn't readable, eTag is
-- NULL and nothing is appended — same as before, no error). NOTE: sheets with
-- ZERO ingested rows (829201, 828837) don't appear here at all and still need
-- an initial ingest — out of scope for this view.

BEGIN;

CREATE OR REPLACE FUNCTION derm._img_etag(p_url text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = storage, public AS $$
  SELECT o.metadata->>'eTag'
  FROM storage.objects o
  WHERE o.bucket_id = split_part(replace(regexp_replace(p_url,'^.*/public/',''),'%20',' '),'/',1)
    AND o.name = substr(replace(regexp_replace(p_url,'^.*/public/',''),'%20',' '),
                        length(split_part(replace(regexp_replace(p_url,'^.*/public/',''),'%20',' '),'/',1)) + 2)
  LIMIT 1
$$;
REVOKE ALL ON FUNCTION derm._img_etag(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION derm.sheet_page_images(p_dump_folder text)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE
  v_imgs  text[];
  v_etags text[];
  v_wm    text;
  r record;
BEGIN
  -- existing row-map pages (one image per page, ordered by page) + their eTags
  SELECT array_agg(image_url ORDER BY page), array_agg(derm._img_etag(image_url) ORDER BY page)
    INTO v_imgs, v_etags
  FROM (SELECT DISTINCT ON (page) page, image_url
        FROM derm.address_row_map WHERE dump_folder = p_dump_folder
        ORDER BY page, image_url) p;
  v_imgs  := coalesce(v_imgs,  '{}');
  v_etags := coalesce(v_etags, '{}');
  SELECT max(white_manifest_number) INTO v_wm
    FROM derm.address_row_map WHERE dump_folder = p_dump_folder;

  -- append manifest address images whose content (eTag) isn't already shown
  FOR r IN
    SELECT u AS img, derm._img_etag(u) AS etag
    FROM public.derm_manifests dm
    CROSS JOIN LATERAL unnest(
      array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls,'{}'::text[])), null)
    ) u
    WHERE dm.white_manifest_number = v_wm AND dm.deleted_at IS NULL
    GROUP BY u
    ORDER BY u
  LOOP
    IF r.etag IS NULL THEN CONTINUE; END IF;               -- unverifiable content -> skip (avoid dup)
    IF NOT (r.etag = ANY(v_etags)) THEN
      v_imgs  := v_imgs  || r.img;
      v_etags := v_etags || r.etag;                        -- prevents appending the same page twice
    END IF;
  END LOOP;
  RETURN v_imgs;
END $$;
GRANT EXECUTE ON FUNCTION derm.sheet_page_images(text) TO anon, authenticated;

-- Re-point v_stamp_sheets: pages come from the manifest image list.
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 WITH agg AS (
         SELECT r.dump_folder,
            max(r.white_manifest_number) AS white_manifest_number,
            count(DISTINCT r.page) AS page_count,
            count(*) AS total_rows,
            count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched_rows,
            count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed_rows
           FROM derm.address_row_map r
          WHERE r.white_manifest_number IS NOT NULL
          GROUP BY r.dump_folder
        )
 SELECT a.dump_folder,
    a.white_manifest_number,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE m.white_manifest_number = a.white_manifest_number) AS service_date,
    COALESCE(array_length(spi.imgs, 1), a.page_count) AS page_count,
    spi.imgs AS page_image_urls,
    a.total_rows,
    a.matched_rows,
    a.placed_rows,
    COALESCE(s.completed, false) AS completed,
    s.completed_at,
    COALESCE(
      (SELECT max(m.dump_ticket_date) FROM derm_manifests m
        WHERE m.white_manifest_number = a.white_manifest_number AND m.deleted_at IS NULL),
      (SELECT max(m.service_date) FROM derm_manifests m
        WHERE m.white_manifest_number = a.white_manifest_number AND m.deleted_at IS NULL)
    ) AS dump_date
   FROM agg a
     LEFT JOIN derm.stamp_sheet_status s USING (dump_folder)
     CROSS JOIN LATERAL (SELECT derm.sheet_page_images(a.dump_folder) AS imgs) spi;
GRANT SELECT ON derm.v_stamp_sheets TO anon, authenticated;

COMMIT;
