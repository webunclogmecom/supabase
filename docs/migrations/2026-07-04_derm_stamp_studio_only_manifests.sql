-- 2026-07-04_derm_stamp_studio_only_manifests.sql
-- DERM Stamp Studio: only show real DERM Address sheets (a white_manifest_number).
-- The 2 no-ticket sheets (dump_folder window10-sheet6, window12-sheet1) have a NULL
-- white_manifest_number and were showing as confusing "window10-sheet6 / no date"
-- entries. Per Fred, exclude them from both stamp views. Additive/idempotent
-- (CREATE OR REPLACE); base table derm.address_row_map is untouched (rows still exist,
-- just not surfaced by these app views). Drops the picker from 92 -> 90 sheets.

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
WITH agg AS (
  SELECT r.dump_folder,
         max(r.white_manifest_number)                            AS white_manifest_number,
         count(DISTINCT r.page)                                  AS page_count,
         count(*)                                                AS total_rows,
         count(*) FILTER (WHERE r.matched_client_id IS NOT NULL) AS matched_rows,
         count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL)   AS placed_rows
  FROM derm.address_row_map r
  WHERE r.white_manifest_number IS NOT NULL        -- only real DERM Address sheets
  GROUP BY r.dump_folder
),
pages AS (
  SELECT dump_folder, array_agg(image_url ORDER BY page) AS page_image_urls
  FROM (SELECT dump_folder, page, min(image_url) AS image_url
        FROM derm.address_row_map
        WHERE white_manifest_number IS NOT NULL
        GROUP BY dump_folder, page) d
  GROUP BY dump_folder
)
SELECT a.dump_folder,
       a.white_manifest_number,
       (SELECT min(m.service_date) FROM public.derm_manifests m
          WHERE m.white_manifest_number = a.white_manifest_number) AS service_date,
       a.page_count,
       p.page_image_urls,
       a.total_rows,
       a.matched_rows,
       a.placed_rows
FROM agg a LEFT JOIN pages p USING (dump_folder);

CREATE OR REPLACE VIEW derm.v_stamp_rows AS
SELECT r.id,
       r.dump_folder,
       r.white_manifest_number,
       r.page,
       r.row_index,
       r.image_url,
       r.facility_name_read,
       r.address_read,
       c.client_code,
       c.name AS client_name,
       (SELECT min(m.service_date) FROM public.derm_manifests m
          WHERE m.white_manifest_number = r.white_manifest_number) AS service_date,
       r.assignment_status,
       r.confidence,
       r.stamp_x_pct,
       r.stamp_y_pct,
       r.stamp_page,
       6.0::numeric AS guess_x_pct,
       round((40 + (r.row_index - 0.5)
              * (52.0 / NULLIF(max(r.row_index) OVER (PARTITION BY r.dump_folder, r.page), 0)))::numeric, 3) AS guess_y_pct,
       (r.stamp_placed_at IS NOT NULL) AS placed
FROM derm.address_row_map r
JOIN public.clients c ON c.id = r.matched_client_id
WHERE r.matched_client_id IS NOT NULL
  AND c.client_code IS NOT NULL
  AND r.white_manifest_number IS NOT NULL;         -- only real DERM Address sheets

GRANT SELECT ON derm.v_stamp_sheets, derm.v_stamp_rows TO anon, authenticated;

COMMIT;
