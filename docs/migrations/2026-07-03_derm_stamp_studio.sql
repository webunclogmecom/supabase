-- 2026-07-03_derm_stamp_studio.sql
-- DERM Stamp Studio backend (new Lovable app). ADDITIVE + ISOLATED.
-- Adds manual stamp-coordinate columns to derm.address_row_map + read views
-- (v_stamp_sheets, v_stamp_rows) + write RPCs (set/clear_stamp_position).
-- Audit-trail check (Rule 8): N/A — derm.address_row_map is a derm-schema tooling
--   table (facility→client mapping for stamp placement), NOT a public.* business
--   table. No customer.*/billing/DERM-compliance write path. Opt-out documented here.
-- Coordinates are % of image (0..100), resolution-independent.

BEGIN;

-- 1. Coordinate columns (additive; nullable). One row already = one code (3NF ok).
ALTER TABLE derm.address_row_map
  ADD COLUMN IF NOT EXISTS stamp_x_pct     numeric(6,3),
  ADD COLUMN IF NOT EXISTS stamp_y_pct     numeric(6,3),
  ADD COLUMN IF NOT EXISTS stamp_page      integer,
  ADD COLUMN IF NOT EXISTS stamp_placed_at timestamptz,
  ADD COLUMN IF NOT EXISTS stamp_placed_by text;

-- 2. Picker view: one row per physical sheet (dump_folder).
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
WITH agg AS (
  SELECT r.dump_folder,
         max(r.white_manifest_number)                            AS white_manifest_number,
         count(DISTINCT r.page)                                  AS page_count,
         count(*)                                                AS total_rows,
         count(*) FILTER (WHERE r.matched_client_id IS NOT NULL) AS matched_rows,
         count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL)   AS placed_rows
  FROM derm.address_row_map r
  GROUP BY r.dump_folder
),
pages AS (
  SELECT dump_folder, array_agg(image_url ORDER BY page) AS page_image_urls
  FROM (SELECT dump_folder, page, min(image_url) AS image_url
        FROM derm.address_row_map GROUP BY dump_folder, page) d
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

-- 3. Card view: one row per stampable (matched, coded) facility line.
--    guess_* = template-based Auto-place seed (GDO column x; row-band y).
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
WHERE r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL;

-- 4. Write RPCs (SECURITY DEFINER so anon can persist via the API; RLS is off on
--    the table and the definer owns it). No manual updated_at (Rule 7).
CREATE OR REPLACE FUNCTION derm.set_stamp_position(
  p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  IF p_x_pct < 0 OR p_x_pct > 100 OR p_y_pct < 0 OR p_y_pct > 100 THEN
    RAISE EXCEPTION 'stamp percent out of range (x=%, y=%)', p_x_pct, p_y_pct;
  END IF;
  UPDATE derm.address_row_map
     SET stamp_x_pct = round(p_x_pct, 3),
         stamp_y_pct = round(p_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION derm.clear_stamp_position(p_row_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  UPDATE derm.address_row_map
     SET stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_page = NULL,
         stamp_placed_at = NULL, stamp_placed_by = NULL
   WHERE id = p_row_id;
END $$;

-- 5. Grants (mirror the derm-schema read exposure the other apps rely on).
GRANT SELECT ON derm.v_stamp_sheets, derm.v_stamp_rows TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.set_stamp_position(bigint, integer, numeric, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.clear_stamp_position(bigint) TO anon, authenticated;

COMMIT;
