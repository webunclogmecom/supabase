-- 2026-07-04_derm_stamp_sheet_status.sql
-- DERM Stamp Studio: per-sheet manual "Completed" status (like the calendar's
-- completed toggle). Sheet grain = dump_folder. New tiny status table + expose
-- `completed`/`completed_at` on v_stamp_sheets + set_sheet_completed RPC.
-- Additive/isolated. Audit Rule 8: N/A (derm-schema app tooling table, no
-- customer.*/billing/DERM-compliance write path); opt-out documented here.

BEGIN;

CREATE TABLE IF NOT EXISTS derm.stamp_sheet_status (
  dump_folder  text PRIMARY KEY,
  completed    boolean     NOT NULL DEFAULT false,
  completed_at timestamptz,
  completed_by text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- v_stamp_sheets: only real DERM Address sheets + expose completion status.
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
WITH agg AS (
  SELECT r.dump_folder,
         max(r.white_manifest_number)                            AS white_manifest_number,
         count(DISTINCT r.page)                                  AS page_count,
         count(*)                                                AS total_rows,
         count(*) FILTER (WHERE r.matched_client_id IS NOT NULL) AS matched_rows,
         count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL)   AS placed_rows
  FROM derm.address_row_map r
  WHERE r.white_manifest_number IS NOT NULL
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
       a.placed_rows,
       COALESCE(s.completed, false) AS completed,
       s.completed_at
FROM agg a
LEFT JOIN pages p USING (dump_folder)
LEFT JOIN derm.stamp_sheet_status s USING (dump_folder);

-- Toggle a sheet's completed status.
CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, p_completed,
          CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END,
          now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    completed    = EXCLUDED.completed,
    completed_at = CASE WHEN EXCLUDED.completed THEN now() ELSE NULL END,
    completed_by = CASE WHEN EXCLUDED.completed THEN EXCLUDED.completed_by ELSE NULL END,
    updated_at   = now();
END $$;

GRANT SELECT ON derm.v_stamp_sheets TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.set_sheet_completed(text, boolean) TO anon, authenticated;

COMMIT;
