CREATE OR REPLACE FUNCTION derm.save_page_geometry(p_dump_folder text, p_effective_page integer, p_bands jsonb, p_top_pct numeric DEFAULT NULL::numeric, p_bottom_pct numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_bad   text;
  v_rows  integer;
  v_actor text;
  v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  SELECT string_agg(code || ': ' || detail, E'\n' ORDER BY code) INTO v_bad
    FROM derm._page_geometry_violations(p_dump_folder, p_effective_page, p_bands, p_top_pct, p_bottom_pct);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION E'page geometry refused:\n%', v_bad;
  END IF;

  v_actor := derm._actor('stamp-studio');

  UPDATE derm.address_row_map r
     SET band_y0_pct = round((e->>'y0')::numeric, 3),
         band_y1_pct = round((e->>'y1')::numeric, 3),
         band_source = 'manual', band_set_at = now(), band_set_by = v_actor
    FROM jsonb_array_elements(p_bands) e
   WHERE r.id = (e->>'row_id')::bigint
     -- do not write a row whose value did not move: a no-op UPDATE would re-stale the blackout
     -- fingerprint and republish a customer document for nothing.
     AND (r.band_y0_pct IS DISTINCT FROM round((e->>'y0')::numeric, 3)
       OR r.band_y1_pct IS DISTINCT FROM round((e->>'y1')::numeric, 3));
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF p_top_pct IS NOT NULL THEN
    INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
    VALUES (p_dump_folder, p_effective_page, round(p_top_pct,3), round(p_bottom_pct,3),
            'stamp-studio:' || v_actor, now())
    ON CONFLICT (dump_folder, effective_page) DO UPDATE
       SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
           source = EXCLUDED.source, measured_at = EXCLUDED.measured_at
     WHERE derm.page_block_extents.top_pct IS DISTINCT FROM EXCLUDED.top_pct
        OR derm.page_block_extents.bottom_pct IS DISTINCT FROM EXCLUDED.bottom_pct;
  END IF;

  -- Tell the caller the truth about what happens next, rather than just "ok". A folder can be
  -- perfectly measured and still publish nothing, and the operator must be able to see that.
  SELECT blocker INTO v_block FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder = p_dump_folder LIMIT 1;

  RETURN jsonb_build_object(
    'saved_bands', v_rows,
    'extent_written', (p_top_pct IS NOT NULL),
    'folder_still_blocked_by', v_block,
    -- âš  deliberately NOT derm.fn_blackout_targets() here: it materialises ticket_page_images for
    -- every ticket in the estate and would put seconds into an interactive save. The blocker above
    -- carries the signal that matters, and the gate itself is just "does this page have an extent".
    'gate_open', EXISTS (SELECT 1 FROM derm.page_block_extents e
                          WHERE e.dump_folder = p_dump_folder AND e.effective_page = p_effective_page)
  );
END $function$
