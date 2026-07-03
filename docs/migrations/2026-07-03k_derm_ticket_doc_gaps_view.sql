-- Migration: 2026-07-03k_derm_ticket_doc_gaps_view.sql
-- Author: Claude (Supabase session)
BEGIN;
-- Detection surface for DERM ticket documentation gaps (Fred, 2026-07-03, after the #827989
-- missing-page incident: 4 pages existed, 3 were stored; nothing could notice). Two signals:
--   pages_suspect  : many client rows share few stored address-sheet files (>5 rows per sheet
--                    is beyond one page's capacity -> a page is probably missing)
--   crossclient_links : manifest_visits rows whose visit belongs to a different client than the
--                    manifest row (the 087-BB pattern; should be ~0)
CREATE OR REPLACE VIEW ops.v_derm_ticket_doc_gaps AS
WITH per_row AS (
  SELECT coalesce(dm.white_manifest_number, dm.yellow_ticket_number) ticket, dm.id,
    array_remove(ARRAY[dm.derm_address_url],NULL) || coalesce(dm.derm_address_extra_urls,'{}') urls
  FROM derm_manifests dm WHERE dm.deleted_at IS NULL
    AND coalesce(dm.white_manifest_number, dm.yellow_ticket_number) IS NOT NULL),
per_tkt AS (
  SELECT ticket, count(DISTINCT id) n_rows, count(DISTINCT u) n_sheets
  FROM per_row LEFT JOIN LATERAL unnest(urls) u ON true GROUP BY ticket),
crossc AS (
  SELECT coalesce(dm.white_manifest_number, dm.yellow_ticket_number) ticket, count(*) n_cross
  FROM manifest_visits mv
  JOIN derm_manifests dm ON dm.id=mv.manifest_id AND dm.deleted_at IS NULL
  JOIN visits v ON v.id=mv.visit_id
  WHERE dm.client_id IS DISTINCT FROM v.client_id GROUP BY 1)
SELECT t.ticket, t.n_rows, t.n_sheets,
  round(t.n_rows::numeric/greatest(t.n_sheets,1),1) rows_per_sheet,
  (t.n_rows > 5*greatest(t.n_sheets,1)) pages_suspect,
  coalesce(c.n_cross,0) crossclient_links
FROM per_tkt t LEFT JOIN crossc c USING (ticket)
WHERE t.n_rows > 5*greatest(t.n_sheets,1) OR coalesce(c.n_cross,0) > 0
ORDER BY rows_per_sheet DESC, crossclient_links DESC;
COMMIT;