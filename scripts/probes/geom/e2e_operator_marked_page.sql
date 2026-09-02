-- End-to-end probe: the exact sequence an operator performs in the Stamp Studio on a page the
-- detector could not read, driven against LIVE Prod and rolled back.
--
-- It exists because "the migration applied" says nothing about whether a person can now finish the
-- job. Fred's report was not "the function refuses", it was "I still could not save it", and only
-- the whole chain answers that.
--
--   1. mark the printed lines by hand              -> derm.record_page_rules  (human-v1-)
--   2. place the stamps                            -> derm.address_row_map
--   3. save the strips and the Section B boundary  -> derm.save_page_geometry
--
-- ticket-834489 is used because it holds 0 extents, 0 published documents and 0 rules, so nothing
-- it does could reach a customer even for the instant the subtransaction exists.
-- EVERYTHING IS ROLLED BACK, including the stamp placements: this probe must never leave a stamp
-- behind, because a stamp is a person's assertion about a compliance document.

DO $$
DECLARE
  v_res   jsonb;
  v_n     int;
  v_done  text := '';
  v_flag  text := '';
  v_top   numeric := 27.960;
  v_bot   numeric := 60.240;
BEGIN
  BEGIN
    ------------------------------------------------------------------ 1. the lines
    v_res := derm.record_page_rules(
      'ticket-834489', 1, 'human-v1-e2e', 'https://example.invalid/e2e.jpg',
      '[{"pct":27.960,"run":0.356,"ink":0.5,"kind":"boundary"},
        {"pct":33.340,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":38.720,"run":0.351,"ink":0.5,"kind":"boundary"},
        {"pct":44.100,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":49.480,"run":0.347,"ink":0.5,"kind":"boundary"},
        {"pct":54.860,"run":0.352,"ink":0.5,"kind":"boundary"},
        {"pct":60.240,"run":0.367,"ink":0.5,"kind":"boundary"}]'::jsonb,
      '{"grade":"OK","source_etag":"e2e"}'::jsonb);
    IF NOT (v_res->>'wrote')::boolean THEN
      RAISE EXCEPTION 'STEP 1 FAILED: the lines were refused: % / %', v_res->>'detail', v_res->>'hint';
    END IF;
    RAISE NOTICE 'step 1 OK: % lines recorded', v_res->>'rules_written';

    ------------------------------------------------------------------ 2. the stamps
    -- 1096 sits in printed row 1, 1095 in printed row 2, matching the handwriting on the scan
    -- (Pura Vida on the first line, The Moore on the second).
    UPDATE derm.address_row_map SET stamp_page = 1, stamp_x_pct = 13.0, stamp_y_pct = 30.500,
           stamp_placed_at = now(), stamp_placed_by = 'e2e-probe' WHERE id = 1096;
    UPDATE derm.address_row_map SET stamp_page = 1, stamp_x_pct = 13.0, stamp_y_pct = 36.000,
           stamp_placed_at = now(), stamp_placed_by = 'e2e-probe' WHERE id = 1095;

    ------------------------------------------------------------------ 3. strips + Section B
    -- Each strip is one printed row, its edges exactly on two lines recorded in step 1.
    v_res := derm.save_page_geometry('ticket-834489', 1,
      '[{"row_id":1096,"y0":27.960,"y1":33.340},
        {"row_id":1095,"y0":33.340,"y1":38.720}]'::jsonb,
      v_top, v_bot);
    IF (v_res->>'saved_bands')::int <> 2 THEN
      RAISE EXCEPTION 'STEP 3 FAILED: saved % bands, expected 2 (%)', v_res->>'saved_bands', v_res::text;
    END IF;
    IF NOT (v_res->>'extent_written')::boolean THEN
      RAISE EXCEPTION 'STEP 3 FAILED: no Section B boundary was written (%)', v_res::text;
    END IF;
    RAISE NOTICE 'step 3 OK: %', v_res::text;

    ------------------------------------------------------------------ 4. the guard grades it clean
    -- 🛑 NOT derm.v_band_edges_off_rule, and this cost a probe run to learn. That view reads
    -- v_band_edge_check, which INNER JOINs derm.redacted_manifest_docs, so on a folder that
    -- publishes nothing it is structurally EMPTY and reports zero for any geometry whatsoever.
    -- Its own control caught it: an edge nudged 1.56pp off a printed line was still not flagged.
    -- derm.check_page_geometry is what the Studio itself calls and needs no published document.
    SELECT count(*) INTO v_n FROM derm.check_page_geometry('ticket-834489', 1,
      '[{"row_id":1096,"y0":27.960,"y1":33.340},
        {"row_id":1095,"y0":33.340,"y1":38.720}]'::jsonb, v_top, v_bot);
    IF v_n <> 0 THEN
      SELECT string_agg(code || ': ' || hint, ' | ') INTO v_done
        FROM derm.check_page_geometry('ticket-834489', 1,
          '[{"row_id":1096,"y0":27.960,"y1":33.340},
            {"row_id":1095,"y0":33.340,"y1":38.720}]'::jsonb, v_top, v_bot);
      RAISE EXCEPTION 'STEP 4 FAILED: the saved geometry is refused by its own guard: %', v_done;
    END IF;

    -- CONTROL: the guard must be capable of firing on this very page, or the clean reading above
    -- proves nothing. Nudge one shared edge 1.56pp off its printed line.
    SELECT count(*) INTO v_n FROM derm.check_page_geometry('ticket-834489', 1,
      '[{"row_id":1096,"y0":27.960,"y1":34.900},
        {"row_id":1095,"y0":34.900,"y1":38.720}]'::jsonb, v_top, v_bot)
     WHERE code = 'G9_OFF_RULE';
    IF v_n = 0 THEN
      RAISE EXCEPTION 'STEP 4 CONTROL FAILED: an edge 1.56pp off a printed line was NOT flagged, so the clean reading above is untrusted';
    END IF;
    RAISE NOTICE 'step 4 OK: clean when the edges sit on the marked lines, % off-rule finding(s) when nudged', v_n;

    v_flag := 'ok';
    RAISE EXCEPTION 'ROLLBACK_PROBE' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  IF v_flag <> 'ok' THEN
    RAISE EXCEPTION 'PROBE DID NOT COMPLETE';
  END IF;

  -- nothing survived: no rules, no extent, and above all no stamp
  SELECT count(*) INTO v_n FROM derm.page_rule_scans
   WHERE dump_folder='ticket-834489' AND source='human-v1-e2e';
  IF v_n <> 0 THEN RAISE EXCEPTION 'LEAKED: % probe scan(s) survived', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder='ticket-834489';
  IF v_n <> 0 THEN RAISE EXCEPTION 'LEAKED: % extent(s) survived', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-834489' AND (stamp_placed_at IS NOT NULL OR band_y0_pct IS NOT NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'LEAKED: % stamp/band survived on a real card', v_n; END IF;

  RAISE NOTICE 'E2E PASS: mark lines -> place stamps -> save strips and Section B, all clean, nothing left behind.';
END $$;
