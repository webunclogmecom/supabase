-- 2026-07-04_stamp_write_rpc_hardening.sql
-- Security hardening from the 2026-07-04 adversarial audit (apply AFTER the app
-- ships the x-stamp-key header — the app build precedes this migration):
--  (1) All Stamp Studio write RPCs now require the request header
--      x-stamp-key: sk_derm_stamp_7f2c91ae4b when called through PostgREST.
--      Rationale: the anon key is shared across ALL public app bundles, so
--      anyone holding it (from any app) could previously call these SECURITY
--      DEFINER writers — including link_row_visit into the canonical compliance
--      table public.manifest_visits. The key ships in the stamp app bundle
--      (same trust tier as the obscure URL) but eliminates the
--      shared-anon-key-from-elsewhere vector. Direct SQL (Management API /
--      psql, no request.headers GUC) stays allowed for admin scripts.
--  (2) link_row_visit: close the NULL-client guard bypass — a row with no
--      matched_client_id could previously link ANY visit (cross-client check
--      was skipped). Now such rows refuse to link.
-- Read views/grants unchanged.

BEGIN;

-- Gate helper -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm._require_stamp_key()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_headers text; v_key text;
BEGIN
  v_headers := current_setting('request.headers', true);
  IF v_headers IS NULL OR v_headers = '' THEN
    RETURN;  -- direct SQL (not PostgREST): admin scripts stay allowed
  END IF;
  v_key := v_headers::jsonb->>'x-stamp-key';
  IF v_key IS DISTINCT FROM 'sk_derm_stamp_7f2c91ae4b' THEN
    RAISE EXCEPTION 'unauthorized: stamp-studio write key required';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION derm._require_stamp_key() FROM anon, authenticated;

-- 1. set_stamp_position ---------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.set_stamp_position(
  p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
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

-- 2. clear_stamp_position -------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.clear_stamp_position(p_row_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     SET stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_page = NULL,
         stamp_placed_at = NULL, stamp_placed_by = NULL
   WHERE id = p_row_id;
END $$;

-- 3. set_sheet_completed ----------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
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

-- 4. add_sheet_client -------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.add_sheet_client(
  p_dump_folder text, p_page integer,
  p_client_id bigint DEFAULT NULL, p_custom_code text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_wm text; v_img text; v_next int; v_fac text; v_addr text; v_id bigint;
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

-- 5. remove_sheet_client -----------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.remove_sheet_client(p_row_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
  DELETE FROM derm.address_row_map WHERE id = p_row_id AND source = 'stamp-studio';
  IF NOT FOUND THEN RAISE EXCEPTION 'row % is not a manually-added card (cannot remove)', p_row_id; END IF;
END $$;

-- 6. set_row_band -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.set_row_band(p_row_id bigint, p_y0 numeric, p_y1 numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_y0 < 0 OR p_y1 > 100 OR p_y0 >= p_y1 THEN
    RAISE EXCEPTION 'invalid band (y0=%, y1=%)', p_y0, p_y1;
  END IF;
  UPDATE derm.address_row_map
     SET band_y0_pct = round(p_y0, 3), band_y1_pct = round(p_y1, 3),
         band_source = 'manual', band_set_at = now(),
         band_set_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $$;

-- 7. set_row_reviewed ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.set_row_reviewed(p_row_id bigint, p_reviewed boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     SET reviewed_at = CASE WHEN p_reviewed THEN now() END,
         reviewed_by = CASE WHEN p_reviewed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $$;

-- 8. link_row_visit (+ NULL-client guard fix) ----------------------------------------
CREATE OR REPLACE FUNCTION derm.link_row_visit(p_row_id bigint, p_visit_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_mid bigint; v_cid bigint; v_vcid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  SELECT matched_manifest_id, matched_client_id INTO v_mid, v_cid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest for this client on this sheet — file it in DERM Tracker first', p_row_id;
  END IF;
  -- FIX: a row with no matched client must never link a visit (previously the
  -- cross-client guard was silently skipped when v_cid IS NULL).
  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'row % has no matched client — cannot link a visit', p_row_id;
  END IF;
  SELECT client_id INTO v_vcid FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN RAISE EXCEPTION 'visit % not found / deleted', p_visit_id; END IF;
  IF v_vcid <> v_cid THEN
    RAISE EXCEPTION 'visit % belongs to a different client than row %', p_visit_id, p_row_id;
  END IF;
  INSERT INTO public.manifest_visits (manifest_id, visit_id)
  VALUES (v_mid, p_visit_id)
  ON CONFLICT DO NOTHING;
END $$;

COMMIT;
