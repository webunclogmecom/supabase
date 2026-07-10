-- 2026-07-10_fp_blackout_v2_1_extents.sql
-- LEAK FIX (Fred caught it live on m1309/152-DAV: co-clients Fresko + JZ Steak House visible below
-- Davinci's row). ROOT CAUSE: v2 computed the blackout span [blocks_top..blocks_bottom] from the
-- MIN/MAX of BANDED CARDS on the page — but ticket-* folders only have cards for LINKED clients
-- (no full OCR roster), and same-page cards can carry misaligned stamp_page values, so physical
-- co-client rows below the last banded card fell OUTSIDE the blacked span. 238/377 derivatives were
-- under-covered (audited vs the fleet-measured full-roster extents) — ALL pulled (ledger + files;
-- FP fell back to "Coming soon").
-- FIX: persist the vision-fleet's FULL-ROSTER extent per page (all 6/5 slots incl. EMPTY ones) in
-- derm.page_block_extents; fn_blackout_targets now blacks [LEAST(extent.top, bands) .. GREATEST(
-- extent.bottom, bands)] minus the own band, and EMITS NO TARGET when a page has no measured extent
-- (new pages generate only after a measurement pass — documented rerun). ADR-010: measurement
-- metadata table, audit opt-out (machine-written).
BEGIN;
CREATE TABLE IF NOT EXISTS derm.page_block_extents (
  dump_folder text NOT NULL,
  effective_page int NOT NULL,
  top_pct numeric NOT NULL,
  bottom_pct numeric NOT NULL,
  source text NOT NULL DEFAULT 'ocr-fleet-2026-07-10',
  measured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_folder, effective_page)
);
ALTER TABLE derm.page_block_extents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON derm.page_block_extents FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON derm.page_block_extents TO service_role;
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct) VALUES
('backfill-829201', 1, 25.500, 65.900),
('backfill-829201', 2, 24.100, 64.600),
('derm/1158', 1, 28.000, 60.100),
('derm/1171', 1, 27.400, 60.800),
('derm/1173', 1, 27.800, 61.600),
('derm/1187', 1, 23.600, 58.800),
('derm/1192', 1, 27.600, 60.900),
('derm/1194', 1, 25.000, 63.000),
('derm/1194', 2, 24.700, 63.100),
('derm/1194', 3, 25.500, 63.600),
('derm/1208', 1, 27.100, 61.400),
('derm/1208', 2, 27.000, 60.400),
('derm/1218', 1, 28.500, 63.100),
('derm/1218', 2, 29.000, 63.500),
('derm/1218', 3, 25.900, 66.300),
('derm/1218', 4, 25.100, 63.300),
('derm/1236', 1, 28.800, 63.400),
('derm/1241', 1, 29.400, 63.600),
('derm/1246', 1, 27.500, 60.900),
('derm/1252', 1, 27.800, 61.500),
('ticket-296623', 1, 28.000, 60.800),
('ticket-308684', 1, 22.900, 66.400),
('ticket-308684', 2, 20.400, 61.900),
('ticket-308792', 1, 29.000, 61.100),
('ticket-308792', 2, 28.700, 61.700),
('ticket-826114', 1, 27.800, 61.200),
('ticket-826114', 2, 28.600, 62.000),
('ticket-829216', 2, 28.300, 61.500),
('ticket-829216', 3, 28.500, 61.800),
('ticket-829216', 4, 27.400, 60.800),
('ticket-829322', 1, 25.100, 63.900),
('ticket-829322', 2, 25.400, 63.900),
('window10-sheet1', 1, 29.500, 64.600),
('window10-sheet10', 1, 29.200, 61.800),
('window10-sheet2', 1, 31.900, 68.200),
('window10-sheet3', 1, 26.600, 60.100),
('window10-sheet4', 1, 27.900, 60.500),
('window10-sheet4', 2, 27.600, 59.400),
('window10-sheet5', 1, 28.400, 61.500),
('window10-sheet7', 1, 28.200, 61.300),
('window10-sheet8', 1, 27.800, 60.600),
('window10-sheet9', 1, 27.800, 60.500),
('window11-sheet1', 1, 27.700, 60.600),
('window11-sheet10', 1, 27.800, 60.400),
('window11-sheet2', 1, 27.600, 60.400),
('window11-sheet3', 1, 27.600, 60.300),
('window11-sheet4', 1, 27.700, 60.200),
('window11-sheet5', 1, 27.300, 60.100),
('window11-sheet6', 1, 27.700, 60.600),
('window11-sheet7', 1, 28.000, 60.900),
('window11-sheet8', 1, 28.600, 61.400),
('window11-sheet9', 1, 27.500, 60.400),
('window12-sheet10', 1, 28.000, 62.300),
('window12-sheet11', 1, 28.200, 61.400),
('window12-sheet2', 1, 27.600, 61.000),
('window12-sheet2', 2, 28.500, 62.600),
('window12-sheet3', 1, 26.900, 61.200),
('window12-sheet4', 1, 27.000, 61.700),
('window12-sheet5', 1, 28.200, 61.100),
('window12-sheet6', 1, 28.800, 64.300),
('window12-sheet7', 1, 27.300, 60.400),
('window12-sheet8', 1, 25.300, 59.700),
('window12-sheet9', 1, 27.300, 60.500),
('window13-sheet1', 1, 27.900, 60.900),
('window13-sheet1', 2, 27.400, 60.000),
('window13-sheet2', 1, 27.200, 60.700),
('window13-sheet3', 1, 29.500, 65.400),
('window13-sheet4', 1, 27.700, 60.800),
('window13-sheet5', 1, 29.100, 62.700),
('window13-sheet6', 1, 28.600, 61.900),
('window13-sheet7', 1, 27.500, 60.400),
('window3-sheet3', 1, 27.800, 60.200),
('window3-sheet3', 2, 28.600, 62.700),
('window3-sheet4', 1, 25.600, 61.700),
('window3-sheet4', 2, 28.000, 61.300),
('window3-sheet5', 1, 28.300, 62.000),
('window3-sheet5', 2, 28.800, 62.300),
('window3-sheet5', 3, 28.900, 62.500),
('window4-sheet1', 1, 28.100, 62.200),
('window4-sheet1', 2, 28.000, 61.300),
('window4-sheet2', 1, 28.200, 62.100),
('window4-sheet2', 2, 28.300, 61.800),
('window4-sheet3', 1, 27.300, 59.900),
('window4-sheet3', 2, 27.500, 60.200),
('window4-sheet4', 1, 28.100, 61.200),
('window4-sheet5', 1, 28.900, 62.100),
('window4-sheet5', 2, 29.000, 61.800),
('window4-sheet6', 1, 28.100, 60.700),
('window5-sheet1', 1, 20.900, 57.300),
('window5-sheet2', 1, 27.600, 61.400),
('window5-sheet3', 2, 28.000, 61.000),
('window5-sheet4', 1, 27.800, 61.600),
('window5-sheet5', 1, 27.000, 59.700),
('window5-sheet5', 2, 28.300, 62.300),
('window5-sheet6', 1, 24.500, 60.400),
('window5-sheet6', 2, 28.000, 61.900),
('window5-sheet7', 1, 27.700, 60.900),
('window6-sheet1', 1, 28.400, 61.700),
('window6-sheet2', 1, 27.100, 60.300),
('window6-sheet3', 1, 28.600, 62.200),
('window6-sheet4', 1, 27.600, 60.600),
('window6-sheet5', 1, 28.200, 61.700),
('window6-sheet6', 1, 25.100, 58.700),
('window6-sheet7', 1, 27.700, 60.600),
('window6-sheet8', 1, 27.000, 60.200),
('window6-sheet8', 2, 27.100, 60.600),
('window7-sheet1', 1, 27.500, 60.300),
('window7-sheet2', 1, 28.000, 60.900),
('window7-sheet3', 1, 27.300, 58.900),
('window7-sheet4', 1, 27.500, 61.100),
('window7-sheet5', 1, 27.300, 61.100),
('window7-sheet6', 1, 27.700, 61.300),
('window8-sheet1', 1, 27.400, 61.900),
('window8-sheet1', 2, 27.600, 61.100),
('window8-sheet2', 1, 28.600, 63.000),
('window8-sheet2', 2, 27.300, 60.500),
('window8-sheet3', 1, 27.900, 60.100),
('window8-sheet3', 2, 29.500, 62.800),
('window8-sheet4', 1, 27.700, 61.000),
('window8-sheet5', 1, 28.400, 63.300),
('window8-sheet6', 1, 28.900, 63.300),
('window9-sheet1', 1, 27.200, 60.100),
('window9-sheet2', 1, 27.400, 60.300),
('window9-sheet3', 1, 27.800, 60.400),
('window9-sheet4', 1, 29.100, 64.000),
('window9-sheet5', 1, 27.200, 60.300),
('window9-sheet6', 1, 27.900, 60.500)
ON CONFLICT (dump_folder, effective_page) DO UPDATE SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct;

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
           LEAST(e.top_pct,
                 (SELECT min(b3.band_y0_pct) FROM derm.v_stamp_row_bands b3
                   WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page)) AS btop,
           GREATEST(e.bottom_pct,
                 (SELECT max(b4.band_y1_pct) FROM derm.v_stamp_row_bands b4
                   WHERE b4.dump_folder = l.dump_folder AND b4.effective_page = l.effective_page)) AS bbot
    FROM live l
    JOIN derm.page_block_extents e
      ON e.dump_folder = l.dump_folder AND e.effective_page = l.effective_page   -- HARD GATE: measured pages only
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
  LEFT JOIN derm.redacted_manifest_errors e2 ON e2.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e2.manifest_id IS NULL OR e2.next_retry_at <= now())
  ORDER BY e2.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$fn$;
REVOKE ALL ON FUNCTION derm.fn_blackout_targets(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_blackout_targets(int) TO service_role;
COMMIT;
