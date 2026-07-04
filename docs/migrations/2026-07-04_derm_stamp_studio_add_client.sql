-- 2026-07-04_derm_stamp_studio_add_client.sql
-- DERM Stamp Studio: add a client to a sheet that was missed (visit never linked).
-- Lets the operator drop an extra code card onto a sheet — either an existing
-- roster client (matched_client_id) or a free-text custom code (manual_code) —
-- as a real derm.address_row_map row (source='stamp-studio'), so it behaves like
-- every other card (placement/export/completed). Additive/isolated.
-- Audit Rule 8: N/A (derm-schema app tooling table); opt-out documented here.

BEGIN;

-- Free-text custom code (when the client isn't in the roster).
ALTER TABLE derm.address_row_map ADD COLUMN IF NOT EXISTS manual_code text;

-- Roster for the "Add client" picker.
CREATE OR REPLACE VIEW derm.v_stamp_clients AS
SELECT c.id,
       c.client_code,
       c.name,
       (SELECT p.address FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1) AS address,
       c.status
FROM public.clients c
WHERE c.client_code IS NOT NULL
ORDER BY c.client_code;

-- Picker view: manual rows (matched OR custom) now count too.
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
WITH agg AS (
  SELECT r.dump_folder,
         max(r.white_manifest_number)                            AS white_manifest_number,
         count(DISTINCT r.page)                                  AS page_count,
         count(*)                                                AS total_rows,
         count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched_rows,
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

-- Card view: roster clients (matched) OR manual custom codes; flag manual adds.
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
SELECT r.id,
       r.dump_folder,
       r.white_manifest_number,
       r.page,
       r.row_index,
       r.image_url,
       r.facility_name_read,
       r.address_read,
       COALESCE(c.client_code, r.manual_code)                 AS client_code,
       COALESCE(c.name, r.manual_code)                        AS client_name,
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
       (r.stamp_placed_at IS NOT NULL)     AS placed,
       (r.source = 'stamp-studio')         AS is_manual
FROM derm.address_row_map r
LEFT JOIN public.clients c ON c.id = r.matched_client_id
WHERE r.white_manifest_number IS NOT NULL
  AND ((r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL) OR r.manual_code IS NOT NULL);

-- Add a client card to a sheet page (roster client OR free-text custom code).
CREATE OR REPLACE FUNCTION derm.add_sheet_client(
  p_dump_folder text, p_page integer,
  p_client_id bigint DEFAULT NULL, p_custom_code text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_wm text; v_img text; v_next int; v_fac text; v_addr text; v_id bigint;
BEGIN
  IF p_client_id IS NULL AND (p_custom_code IS NULL OR btrim(p_custom_code) = '') THEN
    RAISE EXCEPTION 'provide p_client_id or a non-empty p_custom_code';
  END IF;
  SELECT max(white_manifest_number) INTO v_wm FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_wm IS NULL THEN RAISE EXCEPTION 'unknown sheet %', p_dump_folder; END IF;
  SELECT min(image_url) INTO v_img FROM derm.address_row_map WHERE dump_folder = p_dump_folder AND page = p_page;
  IF v_img IS NULL THEN
    SELECT min(image_url) INTO v_img FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  END IF;
  SELECT coalesce(max(row_index), 0) + 1 INTO v_next FROM derm.address_row_map WHERE dump_folder = p_dump_folder AND page = p_page;
  IF p_client_id IS NOT NULL THEN
    SELECT c.name, (SELECT p.address FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1)
      INTO v_fac, v_addr FROM public.clients c WHERE c.id = p_client_id;
    IF v_fac IS NULL THEN RAISE EXCEPTION 'unknown client id %', p_client_id; END IF;
  ELSE
    v_fac := btrim(p_custom_code);
  END IF;
  INSERT INTO derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     facility_name_read, address_read, matched_client_id, manual_code,
     assignment_status, confidence, source, flags, created_at, updated_at)
  VALUES
    (p_dump_folder, v_wm, p_page, v_next, v_img,
     v_fac, v_addr, p_client_id, CASE WHEN p_client_id IS NULL THEN btrim(p_custom_code) END,
     'matched', 'high', 'stamp-studio', '{"manual_add":true}'::jsonb, now(), now())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Remove a manually-added card (guarded to manual rows only).
CREATE OR REPLACE FUNCTION derm.remove_sheet_client(p_row_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  DELETE FROM derm.address_row_map WHERE id = p_row_id AND source = 'stamp-studio';
  IF NOT FOUND THEN RAISE EXCEPTION 'row % is not a manually-added card (cannot remove)', p_row_id; END IF;
END $$;

GRANT SELECT ON derm.v_stamp_clients, derm.v_stamp_sheets, derm.v_stamp_rows TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.add_sheet_client(text, integer, bigint, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.remove_sheet_client(bigint) TO anon, authenticated;

COMMIT;
