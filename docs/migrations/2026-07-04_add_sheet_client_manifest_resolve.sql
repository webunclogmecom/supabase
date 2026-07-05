-- 2026-07-04_add_sheet_client_manifest_resolve.sql
-- Fred bug report: a manually-added card (Add client) always showed
-- "No manifest — file in DERM Tracker" with no visit picker, even when the
-- client's manifest for that sheet EXISTS. Root cause: add_sheet_client never
-- set matched_manifest_id. Fix: resolve derm_manifests by
-- (white_manifest_number, client_id) at insert time (the pair is unique), and
-- backfill any existing manual rows the same way. Keeps the x-stamp-key gate.

BEGIN;

CREATE OR REPLACE FUNCTION derm.add_sheet_client(
  p_dump_folder text, p_page integer,
  p_client_id bigint DEFAULT NULL, p_custom_code text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_wm text; v_img text; v_next int; v_fac text; v_addr text; v_id bigint; v_mid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
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
    -- FIX: resolve this client's manifest for the sheet's ticket, if filed
    SELECT dm.id INTO v_mid FROM public.derm_manifests dm
     WHERE dm.white_manifest_number = v_wm AND dm.client_id = p_client_id
       AND dm.deleted_at IS NULL
     LIMIT 1;
  ELSE
    v_fac := btrim(p_custom_code);
  END IF;
  INSERT INTO derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     facility_name_read, address_read, matched_client_id, matched_manifest_id, manual_code,
     assignment_status, confidence, source, flags, created_at, updated_at)
  VALUES
    (p_dump_folder, v_wm, p_page, v_next, v_img,
     v_fac, v_addr, p_client_id, v_mid, CASE WHEN p_client_id IS NULL THEN btrim(p_custom_code) END,
     'matched', 'high', 'stamp-studio', '{"manual_add":true}'::jsonb, now(), now())
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Backfill existing manual rows (e.g. Fred's 044-MP test card) the same way.
UPDATE derm.address_row_map r
   SET matched_manifest_id = dm.id
  FROM public.derm_manifests dm
 WHERE r.source = 'stamp-studio'
   AND r.matched_manifest_id IS NULL
   AND r.matched_client_id IS NOT NULL
   AND dm.white_manifest_number = r.white_manifest_number
   AND dm.client_id = r.matched_client_id
   AND dm.deleted_at IS NULL;

COMMIT;
