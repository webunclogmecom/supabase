-- Blackout v2 geometry (Fred's manual examples): keep whole form visible, black only the other
-- clients' block region. blocks_top/blocks_bottom bound section B; black [top..own_y0]+[own_y1..bottom].
BEGIN;

ALTER TABLE derm.redacted_manifest_docs ADD COLUMN IF NOT EXISTS blocks_bottom numeric;

DROP FUNCTION IF EXISTS derm.fn_blackout_targets(int);
CREATE FUNCTION derm.fn_blackout_targets(p_limit int DEFAULT 3)
RETURNS TABLE (manifest_id bigint, client_id bigint, ticket_key text, source_url text,
               effective_page int, band_y0 numeric, band_y1 numeric,
               blocks_top numeric, blocks_bottom numeric, fingerprint text, old_url text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm', 'public'
AS $fn$
  WITH cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
                      LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                      WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT c2.id,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.stamp_y_pct)  AS yr,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.row_index)    AS rr
          FROM derm.address_row_map c2
          WHERE c2.dump_folder = r.dump_folder AND c2.source = 'claude-vision-v1'
            AND c2.stamp_y_pct IS NOT NULL AND c2.stamp_page = c2.page AND c2.page = r.page
        ) o WHERE o.id = r.id AND o.yr <> o.rr)
  ), best AS (
    SELECT DISTINCT ON (mid) * FROM cards
    ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), live AS (
    SELECT b.* FROM best b
    JOIN public.derm_manifests dm ON dm.id = b.mid AND dm.deleted_at IS NULL AND dm.client_id = b.cid
    WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = b.mid)
  ), geo AS (
    SELECT l.mid, l.cid, l.tkey, l.dump_folder,
           (derm.ticket_page_images(l.tkey))[l.effective_page] AS src,
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1,
           (SELECT min(b3.band_y0_pct) FROM derm.v_stamp_row_bands b3
             WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page) AS btop,
           (SELECT max(b4.band_y1_pct) FROM derm.v_stamp_row_bands b4
             WHERE b4.dump_folder = l.dump_folder AND b4.effective_page = l.effective_page) AS bbot
    FROM live l
    WHERE l.effective_page >= 1
      AND l.effective_page <= COALESCE(array_length(derm.ticket_page_images(l.tkey), 1), 0)
  ), ok AS (
    SELECT g.* FROM geo g
    WHERE g.src IS NOT NULL AND g.y1 > g.y0
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT mode() WITHIN GROUP (ORDER BY r5.image_url) AS ocr_img
          FROM derm.address_row_map r5
          WHERE r5.dump_folder = g.dump_folder AND r5.page = g.effective_page
            AND r5.image_url <> 'pending' AND r5.source = 'claude-vision-v1'
        ) oi
        WHERE oi.ocr_img IS NOT NULL
          AND derm._img_etag(oi.ocr_img) IS DISTINCT FROM derm._img_etag(g.src))
  ), fp AS (
    SELECT o.*, md5(coalesce(derm._img_etag(o.src), 'noetag') || '|' || o.y0 || '|' || o.y1 || '|' ||
                    coalesce(o.btop::text, 'x') || '|' || coalesce(o.bbot::text, 'x')) AS fprint
    FROM ok o
  )
  SELECT f.mid, f.cid, f.tkey, f.src, f.effective_page, f.y0, f.y1, f.btop, f.bbot, f.fprint, t.url
  FROM fp f
  LEFT JOIN derm.redacted_manifest_docs t ON t.manifest_id = f.mid
  LEFT JOIN derm.redacted_manifest_errors e ON e.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e.manifest_id IS NULL OR e.next_retry_at <= now())
  ORDER BY e.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$fn$;
REVOKE ALL ON FUNCTION derm.fn_blackout_targets(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_blackout_targets(int) TO service_role;

COMMIT;
