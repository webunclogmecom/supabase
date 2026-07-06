-- 2026-07-07_stamp_page_pick_mode.sql
-- Fred: #824713 in Stamp shows the first sheet ("DERM Address 311") TWICE.
-- Diagnosis: derm.ticket_page_images picks ONE image per OCR page with
-- DISTINCT ON (page) ... ORDER BY image_url — i.e. "smallest URL wins". On
-- 824713, page 1 holds 6 OCR rows with the real page-1 image (1041/address.jpg)
-- PLUS one synthesized card (id 607, 215-G7, source='linked-backfill' from the
-- 2026-07-06 missing-card seed) that carried the PAGE-2 image URL
-- (1041/address_p2.jpg). The URL-sort picked the stray one, so the page list
-- rendered [sheet2, sheet2, sheet1] — the second sheet twice, the real page-1
-- image demoted to a phantom page 3. Fleet census: 824713 page 1 is the ONLY
-- mixed-image page.
--
-- FIX (permanent):
--   1. Per-page pick becomes MAJORITY VOTE: mode() WITHIN GROUP (ORDER BY
--      image_url) — the image most rows on that page reference. A single stray
--      synthesized card (derm-link / linked-backfill / manual) can never
--      redefine a page again.
--   2. Data hygiene: row 607's image_url repointed to the page-1 image.
--   3. Stamp safety: NO stamp_page remap needed — the two placed stamps
--      (110-CLA, 214-MYK) are on stamp_page=2, and page 2's CONTENT is the same
--      sheet before and after ([.., sheet2, ..] -> [sheet1, sheet2]).
--      Fleet-simulated pre-apply: exactly ONE ticket's page list changes
--      (824713: 3 dup pages -> 2 distinct), page_count 3 -> 2.

BEGIN;

-- 2) data hygiene: the stray seeded card points at page 1's real image
UPDATE derm.address_row_map
   SET image_url = (SELECT r2.image_url FROM derm.address_row_map r2
                     WHERE r2.white_manifest_number = '824713' AND r2.page = 1
                       AND r2.source = 'claude-vision-v1' LIMIT 1)
 WHERE id = 607;

-- 1) majority-vote page pick
CREATE OR REPLACE FUNCTION derm.ticket_page_images(p_wm text)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE
  v_imgs    text[] := '{}';
  v_etags   text[] := '{}';
  v_m_etags text[];
  r record;
BEGIN
  -- the ticket's LIVE manifest image content set
  SELECT array_agg(DISTINCT e) INTO v_m_etags
  FROM (
    SELECT derm._img_etag(u) AS e
    FROM public.derm_manifests dm
    CROSS JOIN LATERAL unnest(
      array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls,'{}'::text[])), null)
    ) u
    WHERE dm.white_manifest_number = p_wm AND dm.deleted_at IS NULL
  ) s WHERE e IS NOT NULL;

  -- OCR pages first, appended UNCONDITIONALLY in page order (existing
  -- stamp_page indexes must never move). Per page, the image is the one MOST
  -- rows reference (mode) — not the URL-sort — so one stray synthesized card
  -- can't redefine a page. Only staleness gates a page out: when the manifests
  -- HAVE images, a page survives only if its content is still in that live set.
  FOR r IN
    SELECT p.img, derm._img_etag(p.img) AS etag
    FROM (SELECT page, mode() WITHIN GROUP (ORDER BY image_url) AS img
          FROM derm.address_row_map
          WHERE white_manifest_number = p_wm AND image_url <> 'pending'
          GROUP BY page) p
    ORDER BY p.page
  LOOP
    IF v_m_etags IS NOT NULL AND (r.etag IS NULL OR NOT (r.etag = ANY(v_m_etags))) THEN
      CONTINUE;  -- manifests are authoritative and no longer carry this content
    END IF;
    v_imgs := v_imgs || r.img;
    IF r.etag IS NOT NULL THEN v_etags := v_etags || r.etag; END IF;
  END LOOP;

  -- append LIVE manifest images whose content isn't already shown
  FOR r IN
    SELECT u AS img, derm._img_etag(u) AS etag
    FROM public.derm_manifests dm
    CROSS JOIN LATERAL unnest(
      array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls,'{}'::text[])), null)
    ) u
    WHERE dm.white_manifest_number = p_wm AND dm.deleted_at IS NULL
    GROUP BY u
    ORDER BY u
  LOOP
    IF r.etag IS NULL THEN CONTINUE; END IF;
    IF NOT (r.etag = ANY(v_etags)) THEN
      v_imgs  := v_imgs  || r.img;
      v_etags := v_etags || r.etag;
    END IF;
  END LOOP;
  RETURN v_imgs;
END $$;

COMMIT;
