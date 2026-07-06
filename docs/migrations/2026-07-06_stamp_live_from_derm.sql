-- 2026-07-06_stamp_live_from_derm.sql  (rev 2 — post adversarial review)
-- Fred: Stamp is missing manifests (#826114: 2 linked manifests + images in DERM,
-- ZERO Stamp rows), missing images that DERM adds/deletes continuously, and missing
-- linked visits as cards. Root cause: the sheet list AND the cards were driven by
-- the OCR table (derm.address_row_map) — anything Yannick files/links/uploads in
-- DERM Tracker AFTER OCR ingest could be invisible, and static backfills (829201)
-- can't keep up with live work.
--
-- FLIP THE MODEL — Stamp reads DERM live; OCR is only a placement hint:
--   1. derm.ticket_page_images(p_wm) — page list keyed by TICKET (not folder):
--      OCR pages first, then live manifest address images, eTag-deduped. Images
--      added/deleted in DERM reflect on refresh. (NULL-eTag hardening included.)
--   2. derm.v_stamp_sheets — one sheet per ticket sourced from LIVE
--      public.derm_manifests (UNION legacy OCR tickets). A ticket with zero OCR
--      rows now appears (dump_folder = 'ticket-<wm>'). Counts = VISIBLE cards.
--   3. derm.v_stamp_rows — visibility rule: show ONLY cards that are
--      (a) matched to a FILED-AND-LIVE DERM manifest (deleted_at IS NULL) — review
--          rev: "has >=1 linked visit" would hide filed-but-unlinked manifests
--          (Yannick's real work: 009-CN/822919, 5 facilities each on 294999 +
--          826477) and invite DUPLICATE filing via "+ Add client";
--      (b) already PLACED (Yannick's stamps are never hidden); or
--      (c) manual custom-code adds (manual_code).
--      Hidden: 17 unlinked+unplaced OCR reads with no live manifest. Not deleted.
--      Rows pointing at soft-deleted manifests stay hidden unless placed (that is
--      what the mislink fixes intended).
--   4. trg_zz_card_from_link AFTER INSERT ON public.manifest_visits — linking a
--      visit in DERM Tracker materializes the card in Stamp instantly; if a card
--      already exists it just resolves its manifest. SECURITY DEFINER; INSERT
--      guarded against unique_violation (a trigger failure must never abort the
--      user's link write).
--   5. Hardened derm.fn_resolve_card_manifest to SECURITY DEFINER (it fires on
--      public.derm_manifests writes and UPDATEs derm.address_row_map — anon is
--      SELECT-only there, so an anon PATCH touching deleted_at/wm/client_id would
--      have failed 42501; latent landmine from the 993bf49 migration).
--   6. Backfill: cards for FILED manifests without one (review rev: not just
--      linked ones) — 3 rows: 298064/010-CS (filed, unlinked, invisible),
--      826114/031-KRU + 826114/139-LTG.
--   7. Ghost cleanup: DELETE address_row_map row 596 (112-YA on 815833) — the
--      exact create-then-orphan ghost from the OLD "+ Add client" flow Fred
--      reported (unplaced, matched to NO manifest); the deferred flow shipped
--      today can no longer create these. Backed up.
--
-- App contract preserved (verified in the live bundle + by the review): sheets =
-- select * from v_stamp_sheets order by service_date desc limit 500; rows =
-- select * from v_stamp_rows where dump_folder=eq.<sheet.dump_folder>. Column
-- lists/orders/types unchanged (CREATE OR REPLACE verified compatible). Every
-- existing sheet keeps its dump_folder. No ticket spans two folders.
--
-- Post-apply acceptance (re-run at COMMIT time): 485 visible cards / 17 hidden
-- (all OCR noise, none placed, none manual); all 239 placed rows visible;
-- #822919 -> 7 cards (009-CN surfaces as NOT LINKED on a completed sheet — real
-- work to stamp, NOT to re-add), #825450 -> 7, #294999 -> 5 (was 0), #826114
-- appears with 2 cards + its images.
--
-- Known quirks (documented, no action): 305031/022-GRO has 2 PLACED rows (real
-- double stamp, flagged earlier); matched_rows == total_rows by construction now.
-- Follow-up candidate: a card-materializer trigger on derm_manifests INSERT if
-- DERM Tracker starts filing without linking regularly.
--
-- @Supabase (session 1): adds trigger trg_zz_card_from_link on public.manifest_visits
-- (AFTER INSERT; writes only derm.address_row_map — my lane). Audit triggers unaffected.

BEGIN;

-- 1) ticket-keyed page list ---------------------------------------------------
CREATE OR REPLACE FUNCTION derm.ticket_page_images(p_wm text)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE
  v_imgs  text[];
  v_etags text[];
  r record;
BEGIN
  -- OCR pages first (one image per page, ordered) + their eTags
  SELECT array_agg(image_url ORDER BY page), array_agg(derm._img_etag(image_url) ORDER BY page)
    INTO v_imgs, v_etags
  FROM (SELECT DISTINCT ON (page) page, image_url
        FROM derm.address_row_map
        WHERE white_manifest_number = p_wm AND image_url <> 'pending'
        ORDER BY page, image_url) p;
  v_imgs  := coalesce(v_imgs,  '{}');
  v_etags := array_remove(coalesce(v_etags, '{}'), NULL);  -- a NULL eTag must not poison the ANY() test

  -- append LIVE manifest address images whose content (eTag) isn't already shown
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
GRANT EXECUTE ON FUNCTION derm.ticket_page_images(text) TO anon, authenticated;

-- 2) sheets: live from DERM ---------------------------------------------------
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
WITH tickets AS (
  SELECT DISTINCT white_manifest_number AS wm
    FROM public.derm_manifests WHERE deleted_at IS NULL AND white_manifest_number IS NOT NULL
  UNION
  SELECT DISTINCT white_manifest_number
    FROM derm.address_row_map WHERE white_manifest_number IS NOT NULL
), folder AS (
  SELECT white_manifest_number AS wm, min(dump_folder) AS f
    FROM derm.address_row_map WHERE white_manifest_number IS NOT NULL GROUP BY 1
), vis AS (   -- VISIBLE cards only (same rule as v_stamp_rows)
  SELECT r.white_manifest_number AS wm,
         count(*) AS total,
         count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched,
         count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed
  FROM derm.address_row_map r
  LEFT JOIN public.clients c ON c.id = r.matched_client_id
  WHERE r.white_manifest_number IS NOT NULL
    AND ((r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL) OR r.manual_code IS NOT NULL)
    AND (   r.stamp_placed_at IS NOT NULL
         OR r.manual_code IS NOT NULL
         OR (r.matched_manifest_id IS NOT NULL AND EXISTS (
               SELECT 1 FROM public.derm_manifests m
                WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))
  GROUP BY 1
)
SELECT
  COALESCE(folder.f, 'ticket-' || t.wm)                            AS dump_folder,
  t.wm                                                             AS white_manifest_number,
  (SELECT min(m.service_date) FROM public.derm_manifests m
     WHERE m.white_manifest_number = t.wm AND m.deleted_at IS NULL) AS service_date,
  COALESCE(array_length(spi.imgs, 1), 0)::bigint                   AS page_count,
  spi.imgs                                                         AS page_image_urls,
  COALESCE(vis.total,   0)::bigint                                 AS total_rows,
  COALESCE(vis.matched, 0)::bigint                                 AS matched_rows,
  COALESCE(vis.placed,  0)::bigint                                 AS placed_rows,
  COALESCE(s.completed, false)                                     AS completed,
  s.completed_at,
  COALESCE(
    (SELECT max(m.dump_ticket_date) FROM public.derm_manifests m
       WHERE m.white_manifest_number = t.wm AND m.deleted_at IS NULL),
    (SELECT max(m.service_date) FROM public.derm_manifests m
       WHERE m.white_manifest_number = t.wm AND m.deleted_at IS NULL)) AS dump_date
FROM tickets t
LEFT JOIN folder ON folder.wm = t.wm
LEFT JOIN vis    ON vis.wm    = t.wm
LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = COALESCE(folder.f, 'ticket-' || t.wm)
CROSS JOIN LATERAL (SELECT derm.ticket_page_images(t.wm) AS imgs) spi;
GRANT SELECT ON derm.v_stamp_sheets TO anon, authenticated;

-- 3) rows: live-DERM-manifest OR placed OR manual-code -------------------------
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
SELECT r.id,
    r.dump_folder,
    r.white_manifest_number,
    r.page,
    r.row_index,
    r.image_url,
    r.facility_name_read,
    r.address_read,
    COALESCE(c.client_code, r.manual_code) AS client_code,
    COALESCE(c.name, r.manual_code)        AS client_name,
    (SELECT min(m.service_date) FROM public.derm_manifests m
       WHERE m.white_manifest_number = r.white_manifest_number
         AND m.deleted_at IS NULL) AS service_date,
    r.assignment_status,
    r.confidence,
    r.stamp_x_pct,
    r.stamp_y_pct,
    r.stamp_page,
    6.0 AS guess_x_pct,
    round(40::numeric + (r.row_index::numeric - 0.5) * (52.0 / NULLIF(r.mx, 0)::numeric), 3) AS guess_y_pct,
    r.stamp_placed_at IS NOT NULL AS placed,
    r.source = 'stamp-studio'::text AS is_manual,
    r.matched_client_id,
    r.matched_manifest_id,
    r.band_y0_pct,
    r.band_y1_pct,
    r.band_source,
    r.reviewed_at IS NOT NULL AS reviewed,
    r.matched_manifest_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = r.matched_manifest_id) AS visit_linked,
    (SELECT count(*) FROM public.manifest_visits mv
       WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count
FROM (SELECT a.*, max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
        FROM derm.address_row_map a) r     -- window over ALL rows so guesses don't shift
LEFT JOIN public.clients c ON c.id = r.matched_client_id
WHERE r.white_manifest_number IS NOT NULL
  AND ((r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL) OR r.manual_code IS NOT NULL)
  AND (   r.stamp_placed_at IS NOT NULL                    -- placed = Yannick's work, always shown
       OR r.manual_code IS NOT NULL                        -- manual custom-code adds
       OR (r.matched_manifest_id IS NOT NULL AND EXISTS (  -- filed-and-live DERM manifest
             SELECT 1 FROM public.derm_manifests m
              WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)));
GRANT SELECT ON derm.v_stamp_rows TO anon, authenticated;

-- 4) link -> card materializer -------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_card_from_link()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_wm text; v_cid bigint; v_folder text; v_img text; v_next int;
BEGIN
  SELECT white_manifest_number, client_id INTO v_wm, v_cid
    FROM public.derm_manifests WHERE id = NEW.manifest_id AND deleted_at IS NULL;
  IF v_wm IS NULL OR v_cid IS NULL THEN RETURN NULL; END IF;

  IF EXISTS (SELECT 1 FROM derm.address_row_map r
              WHERE r.white_manifest_number = v_wm AND r.matched_client_id = v_cid) THEN
    UPDATE derm.address_row_map
       SET matched_manifest_id = NEW.manifest_id
     WHERE white_manifest_number = v_wm AND matched_client_id = v_cid
       AND matched_manifest_id IS NULL;
    RETURN NULL;
  END IF;

  SELECT min(dump_folder) INTO v_folder FROM derm.address_row_map WHERE white_manifest_number = v_wm;
  v_folder := COALESCE(v_folder, 'ticket-' || v_wm);
  v_img := (derm.ticket_page_images(v_wm))[1];
  IF v_img IS NULL THEN
    SELECT derm_address_url INTO v_img FROM public.derm_manifests WHERE id = NEW.manifest_id;
  END IF;
  SELECT COALESCE(max(row_index), 0) + 1 INTO v_next
    FROM derm.address_row_map WHERE dump_folder = v_folder AND page = 1;

  BEGIN
    INSERT INTO derm.address_row_map
      (dump_folder, white_manifest_number, page, row_index, image_url,
       matched_client_id, matched_manifest_id, assignment_status, confidence, source, flags)
    VALUES
      (v_folder, v_wm, 1, v_next, COALESCE(v_img, 'pending'),
       v_cid, NEW.manifest_id, 'matched', 'high', 'derm-link', '{"card_from_link":true}'::jsonb);
  EXCEPTION WHEN unique_violation THEN
    NULL;  -- concurrent link materialized it first; never abort the user's link write
  END;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zz_card_from_link ON public.manifest_visits;
CREATE TRIGGER trg_zz_card_from_link
AFTER INSERT ON public.manifest_visits
FOR EACH ROW EXECUTE FUNCTION derm.fn_card_from_link();

-- 5) harden the existing manifest->card resolver (runs from app-role triggers)
ALTER FUNCTION derm.fn_resolve_card_manifest() SECURITY DEFINER SET search_path = derm, public;

-- 6) backfill: cards for FILED live manifests without one (3 rows:
--    298064/010-CS filed-unlinked, 826114/031-KRU, 826114/139-LTG)
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, assignment_status, confidence, source, flags)
SELECT
  COALESCE((SELECT min(a.dump_folder) FROM derm.address_row_map a
             WHERE a.white_manifest_number = dm.white_manifest_number), 'ticket-' || dm.white_manifest_number),
  dm.white_manifest_number, 1,
  row_number() OVER (PARTITION BY dm.white_manifest_number ORDER BY dm.id)
    + COALESCE((SELECT max(a.row_index) FROM derm.address_row_map a
                 WHERE a.white_manifest_number = dm.white_manifest_number AND a.page = 1), 0),
  COALESCE((derm.ticket_page_images(dm.white_manifest_number))[1], dm.derm_address_url, 'pending'),
  dm.client_id, dm.id, 'matched', 'high', 'derm-link', '{"card_from_link":true,"backfill":true}'::jsonb
FROM public.derm_manifests dm
WHERE dm.deleted_at IS NULL AND dm.white_manifest_number IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                   WHERE r.white_manifest_number = dm.white_manifest_number
                     AND r.matched_client_id = dm.client_id);

-- 7) ghost cleanup: the old Add-client flow's orphan (Fred's repro; backed up)
DELETE FROM derm.address_row_map
 WHERE id = 596 AND source = 'stamp-studio' AND stamp_placed_at IS NULL
   AND matched_manifest_id IS NULL AND manual_code IS NULL;

COMMIT;
