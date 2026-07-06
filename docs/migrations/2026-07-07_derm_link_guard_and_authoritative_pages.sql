-- 2026-07-07_derm_link_guard_and_authoritative_pages.sql
-- Fred: Stamp still inconsistent with the DERM app — #826114 shows 2 cards vs
-- "8 visits" in DERM, and #826477 still shows 2 pages after he deleted the extra
-- address images in DERM. Audit findings (both with receipts):
--
--   (1) #826114's "8 visits" are 6 CROSS-CLIENT links made TODAY (07-06 20:53-54,
--       app_source='derm-tracker'): Yannick batch-linked 7 different clients'
--       visits (017-FIA, 025-GRO, 032-LG, 059-SK, 199-STK, 192-FRK + 031-KRU's own)
--       onto 031-KRU's single manifest. Stamp is per-facility (correctly), so it
--       showed 2 cards. This is the SAME class as the 19 mis-links remediated
--       on 07-06 — being actively re-created because NO writer path guards it.
--       PERMANENT FIX: a BEFORE trigger on public.manifest_visits that REJECTS a
--       link whose visit belongs to a different client than the manifest, with an
--       actionable error. All legit writers are same-client by construction
--       (handleVisit/backfills match client+date; the Stamp RPCs already guard).
--   (2) #826477 stale page: derm.ticket_page_images treated OCR pages as
--       unconditionally authoritative and only APPENDED live manifest images, so
--       an image deleted in DERM kept showing. PERMANENT FIX: when the ticket's
--       live manifests carry >=1 address image, the manifest set is AUTHORITATIVE:
--       OCR pages are kept (in OCR page order, preserving stamp_page semantics)
--       ONLY if their content (eTag) is still in the live manifest set; then
--       manifest-only images are appended. OCR pages are the fallback only when
--       the manifests carry no images. Adversarially verified (3-agent workflow):
--       full-fleet simulation shows EXACTLY ONE page-list diff (826477 2->1, the
--       intended fix; zero placed stamps on the dropped page). A draft intra-OCR
--       dedupe was REMOVED as a review blocker (it would have collapsed 824713
--       p1/p2 — same eTag, 2 placed stamps on p2 — shifting stamp_page indexes).
--       OCR pages append unconditionally in page order; only staleness gates.
--
-- NOTES from the review (documented, no action):
--   * The guard also blocks the same-address sibling class going forward
--     (139/144-LTG, 192/193-FRK) — Fred ruled these SEPARATE facilities
--     (different manholes + GDO), so the guard-compatible path IS the correct
--     one: file the sibling's own manifest, link there. Existing rows untouched
--     (guard fires on INSERT/UPDATE only; 815064 stays pending Diego).
--   * Restore runbooks: replaying a backup containing an old cross-client pair
--     now raises (BEFORE triggers precede ON CONFLICT) — filter those pairs out.
--   * Latent follow-up: stamp_page is a positional index into the page list; any
--     FUTURE page-dropping change must remap stamp_page (or make stamps
--     content-anchored). Zero rows affected today.
--
-- @Supabase (session 1): adds BEFORE INSERT/UPDATE trigger trg_aa_link_same_client
-- on public.manifest_visits (shared table). It only validates + raises; writes
-- nothing. If you ever need a sanctioned cross-client link, session note + drop.

BEGIN;

-- 1) same-client guard on manifest_visits ------------------------------------
CREATE OR REPLACE FUNCTION public.fn_manifest_visit_same_client()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_mcid bigint; v_vcid bigint; v_wm text; v_mcode text; v_vcode text;
BEGIN
  SELECT dm.client_id, dm.white_manifest_number INTO v_mcid, v_wm
    FROM public.derm_manifests dm WHERE dm.id = NEW.manifest_id;
  SELECT v.client_id INTO v_vcid FROM public.visits v WHERE v.id = NEW.visit_id;
  IF v_mcid IS NULL OR v_vcid IS NULL OR v_mcid = v_vcid THEN
    RETURN NEW;
  END IF;
  SELECT client_code INTO v_mcode FROM public.clients WHERE id = v_mcid;
  SELECT client_code INTO v_vcode FROM public.clients WHERE id = v_vcid;
  RAISE EXCEPTION USING
    errcode = 'P0001',
    message = format(
      'cross-client link rejected: visit %s belongs to %s but manifest %s (ticket %s) belongs to %s — file/select %s''s own manifest on this ticket instead',
      NEW.visit_id, coalesce(v_vcode, v_vcid::text), NEW.manifest_id,
      coalesce(v_wm, '?'), coalesce(v_mcode, v_mcid::text), coalesce(v_vcode, v_vcid::text)),
    hint = 'Each facility gets its own manifest per ticket. In DERM Tracker, add the manifest for this client on the same white manifest number, then link the visit there.';
END $$;

DROP TRIGGER IF EXISTS trg_aa_link_same_client ON public.manifest_visits;
CREATE TRIGGER trg_aa_link_same_client
BEFORE INSERT OR UPDATE OF manifest_id, visit_id ON public.manifest_visits
FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_visit_same_client();

-- 2) pages: live manifest images are authoritative ----------------------------
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

  -- OCR pages first, appended UNCONDITIONALLY in page order (review blocker:
  -- an intra-OCR dedupe here would collapse 824713 p1/p2 — same eTag, 2 PLACED
  -- stamps on p2 — onto the wrong image; existing stamp_page indexes must never
  -- move). The ONLY gate is staleness: when the manifests HAVE images, an OCR
  -- page survives only if its content is still in that live set.
  FOR r IN
    SELECT p.image_url AS img, derm._img_etag(p.image_url) AS etag
    FROM (SELECT DISTINCT ON (page) page, image_url
          FROM derm.address_row_map
          WHERE white_manifest_number = p_wm AND image_url <> 'pending'
          ORDER BY page, image_url) p
    ORDER BY p.page
  LOOP
    IF v_m_etags IS NOT NULL AND (r.etag IS NULL OR NOT (r.etag = ANY(v_m_etags))) THEN
      CONTINUE;  -- manifests are authoritative and no longer carry this content
    END IF;
    v_imgs := v_imgs || r.img;
    IF r.etag IS NOT NULL THEN v_etags := v_etags || r.etag; END IF;
  END LOOP;

  -- append manifest images whose content isn't already shown
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
