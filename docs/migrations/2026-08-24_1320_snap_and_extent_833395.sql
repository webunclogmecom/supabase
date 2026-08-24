-- ============================================================================
-- 2026-08-24_1320  ticket-833395: detect the printed rules, snap the 3 bands onto
--                  them, then add the extent -- in that order, in one migration
-- ============================================================================
--
-- Fred: "yes do the snap-then-extent for 833395."
--
-- Once 833395 was auto-stamped this morning it entered the blackout lane, and
-- derm.v_blackout_blocked_sheets named it immediately: blocker 'needs_snap_then_extent',
-- 3 clients with a blank FOG card in the Field Portal. This is that work.
--
-- ---------------------------------------------------------------------------
-- PART 0.  THE DERIVED BANDS WOULD HAVE LEAKED. THIS IS NOT A PRECISION EXERCISE.
-- ---------------------------------------------------------------------------
--
-- The 2026-08-19 rule says an extent does not redact anything: it opens the gate onto whatever
-- bands already exist, and a DERIVED band is a stamp-midpoint heuristic that is not on the paper.
-- On this sheet that is not a theoretical risk, it is a measured leak.
--
--   client    DERIVED band        what it actually covers
--   242-WYN   18.795 - 40.805     starts above the roster; ENDS mid-row-3, cutting off its own
--                                 "GDO-16146 242-WYN Wynd 28 - Pari Pari" line
--   069-TCE   40.805 - 55.925     **starts INSIDE printed slot 3 (39.848 - 47.445)**, so its
--                                 served document would carry GDO-16146, "242-WYN Wynd 28 - Pari
--                                 Pari" and "127 Northwest 27th Street suite 105, Miami, Florida,
--                                 33127" -- another client's facility and street address
--   032-LG    55.925 - 64.155     roughly right by luck, both edges off the printed rules
--
-- That is the same shape as the 226-JER leak repaired in 2026-08-21_0651. PART 5 asserts it, so
-- the claim is a test rather than a sentence.
--
-- ---------------------------------------------------------------------------
-- PART 1.  WHY THIS SHEET NEEDED A NEW IDEA: THE BAND GRAIN IS THE PERMIT GRAIN
-- ---------------------------------------------------------------------------
--
-- Every band repaired before today covered ONE printed slot. This is the first sheet where a
-- correct band spans THREE, and it follows directly from 2026-08-24_0450: a generated sheet prints
-- one row per ACTIVE GDO permit, and 242-WYN (Wynd 28) holds three.
--
--   printed slot   boundaries         occupant
--     1            24.309 - 32.942    GDO-13814  242-WYN Wynd 28 - Pasta
--     2            32.942 - 39.848    GDO-14760  242-WYN Wynd 28 - Nino Gordo
--     3            39.848 - 47.445    GDO-16146  242-WYN Wynd 28 - Pari Pari
--     4            47.445 - 55.456    GDO-11529  069-TCE The carrot express Downtown
--     5            55.456 - 63.605    GDO-11532  032-LG La Granja 36th St
--
-- So 242-WYN's band is 24.309 - 47.445, covering all three of ITS OWN facilities. That is correct
-- and required: they are its permits, and blacking two of them would hide the client's own
-- compliance record from itself. The important half is the other direction -- 069-TCE and 032-LG
-- must see NONE of rows 1 to 3, which is exactly what the derived bands got wrong.
--
-- ⚠ A "one band = one printed slot" check would FAIL this sheet correctly-shaped band. Any future
-- band-geometry check must read the permit grain (derm.v_sheet_printed_rows), not assume one slot
-- per client.
--
-- ---------------------------------------------------------------------------
-- PART 2.  PROVENANCE OF THE NUMBERS
-- ---------------------------------------------------------------------------
--
-- The page had NEVER been scanned: derm.page_rule_scans held no row for it and
-- derm.page_row_rules held no rules, which is why the bands were still derived.
--
-- Detected with scripts/probes/derm_band_review/detect.js (runlen-v2), the run-length detector
-- described in 2026-08-21_0736: score each scanline by the longest contiguous horizontal run of
-- dark pixels across the full form width. 932x724 image, skew -0.005 (not saturated), 15 rules,
-- pitch 8.011. Every boundary below measured run 1.000 except where noted.
--
-- Then RENDERED with the detected rules drawn over the scan and read by eye
-- (scripts/probes/derm_band_review/annotate.js). Every one of the six boundaries sits exactly on a
-- printed horizontal line. The detector supplies the VALUE; looking supplies the judgement.
--
-- ⚠ ONE JUDGEMENT CALL, RECORDED RATHER THAN HIDDEN: the roster-bottom boundary at 63.605 measured
-- run 0.515, below the 0.80 full-width threshold, so the detector classed it 'part'. It is a real
-- full-width printed rule -- the "Total Waste this Load" boxes on the right interrupt the run. It
-- is stored as kind='boundary' with kind_confirmed=true, and it is the ONLY confirmed-by-eye
-- classification on this page. It is also safe on the weaker test that matters: it lands in
-- whitespace between 032-LG's address line and "Attach Additional Sheets".
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): derm.page_row_rules, derm.page_rule_scans and derm.page_block_extents
-- carry NO audit trigger and this migration does not add one -- they are machine-written geometry
-- measurements, re-derivable by re-running the detector, holding no client data. All three writes
-- here are INSERTs, so nothing is destroyed. The band UPDATE lands on derm.address_row_map, which
-- IS audited, so the pre-snap derived values are recoverable from audit.logs.old_row.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 3.  Record the scan and the rules
-- ---------------------------------------------------------------------------

INSERT INTO derm.page_rule_scans
  (dump_folder, effective_page, source_url, image_w, image_h, skew,
   n_rules, n_boundaries, pitch_pct, grade, detail, source, source_etag, skew_saturated)
VALUES
  ('ticket-833395', 1,
   'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg',
   932, 724, -0.005, 15, 6, 8.011, 'OK',
   '6 roster boundaries, pitch 8.011. The 63.605 roster-bottom boundary measured run 0.515 (the '
   'Total Waste boxes interrupt the run) and was confirmed as a printed full-width rule by eye.',
   'runlen-v2-2026-08-21',
   derm._img_etag('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg'),
   false)
ON CONFLICT (dump_folder, effective_page, source) DO UPDATE
  SET source_url = EXCLUDED.source_url, image_w = EXCLUDED.image_w, image_h = EXCLUDED.image_h,
      skew = EXCLUDED.skew, n_rules = EXCLUDED.n_rules, n_boundaries = EXCLUDED.n_boundaries,
      pitch_pct = EXCLUDED.pitch_pct, grade = EXCLUDED.grade, detail = EXCLUDED.detail,
      source_etag = EXCLUDED.source_etag, skew_saturated = EXCLUDED.skew_saturated,
      scanned_at = now();

INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, ink_frac, run_frac, kind, kind_confirmed, source)
VALUES
  ('ticket-833395', 1, 11.878, 0.795, 0.976, 'header-footer', false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 21.823, 0.542, 0.409, 'header-footer', false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 24.309, 0.983, 1.000, 'boundary',      false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 28.453, 0.188, 0.408, 'divider',       false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 32.942, 0.864, 1.000, 'boundary',      false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 36.395, 0.342, 0.409, 'divider',       false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 39.848, 0.709, 1.000, 'boundary',      false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 43.301, 0.393, 0.410, 'divider',       false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 47.445, 0.988, 1.000, 'boundary',      false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 51.243, 0.169, 0.409, 'divider',       false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 55.456, 0.981, 1.000, 'boundary',      false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 59.323, 0.302, 0.409, 'divider',       false, 'runlen-v2-2026-08-21'),
  -- confirmed by eye; see PART 2
  ('ticket-833395', 1, 63.605, 0.723, 0.515, 'boundary',      true,  'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 66.920, 0.926, 0.406, 'header-footer', false, 'runlen-v2-2026-08-21'),
  ('ticket-833395', 1, 69.337, 0.553, 0.406, 'header-footer', false, 'runlen-v2-2026-08-21')
ON CONFLICT (dump_folder, effective_page, rule_pct, source) DO UPDATE
  SET ink_frac = EXCLUDED.ink_frac, run_frac = EXCLUDED.run_frac,
      kind = EXCLUDED.kind, kind_confirmed = EXCLUDED.kind_confirmed, detected_at = now();

-- ---------------------------------------------------------------------------
-- PART 4.  SNAP the bands. Every edge is one of the boundaries above.
-- ---------------------------------------------------------------------------

UPDATE derm.address_row_map a
   SET band_y0_pct = v.y0, band_y1_pct = v.y1,
       band_source = 'runlen-snap-2026-08-24', band_set_at = now(), band_set_by = 'claude-snap'
  FROM (VALUES
          ('242-WYN', 24.309::numeric, 47.445::numeric),   -- printed slots 1-3, one per GDO permit
          ('069-TCE', 47.445::numeric, 55.456::numeric),   -- printed slot 4
          ('032-LG',  55.456::numeric, 63.605::numeric)    -- printed slot 5
       ) AS v(code, y0, y1)
  JOIN public.clients c ON c.client_code = v.code
 WHERE a.white_manifest_number = '833395'
   AND a.matched_client_id = c.id;

-- ---------------------------------------------------------------------------
-- PART 5.  VERIFY the bands BEFORE opening the gate. The extent is PART 6.
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_n int; v_txt text;
BEGIN
  ------------------------------------------------------------------------
  -- 5.1  Every band edge must BE a recorded slot boundary. This is the one check
  --      that fails on a derived band, on a uniformly shifted tiling, and on a
  --      partly-stamped roster. "Bands tile contiguously" does not.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a
   WHERE a.white_manifest_number = '833395'
     AND (NOT EXISTS (SELECT 1 FROM derm.page_row_rules r
                       WHERE r.dump_folder = 'ticket-833395' AND r.effective_page = 1
                         AND r.kind = 'boundary' AND r.rule_pct = a.band_y0_pct)
       OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules r
                       WHERE r.dump_folder = 'ticket-833395' AND r.effective_page = 1
                         AND r.kind = 'boundary' AND r.rule_pct = a.band_y1_pct));
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% band edges do not sit on a detected slot boundary', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 5.2  CONTROL. The pre-snap DERIVED bands must FAIL 5.1. Without this, 5.1 could
  --      be passing because it tests nothing. Rolled back in a subtransaction.
  ------------------------------------------------------------------------
  DECLARE v_fail int;
  BEGIN
    BEGIN
      UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL
       WHERE white_manifest_number = '833395';
      SELECT count(*) INTO v_fail
        FROM derm.v_stamp_row_bands b
       WHERE b.dump_folder = 'ticket-833395'
         AND (NOT EXISTS (SELECT 1 FROM derm.page_row_rules r
                           WHERE r.dump_folder = 'ticket-833395' AND r.effective_page = 1
                             AND r.kind = 'boundary' AND r.rule_pct = b.band_y0_pct)
           OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules r
                           WHERE r.dump_folder = 'ticket-833395' AND r.effective_page = 1
                             AND r.kind = 'boundary' AND r.rule_pct = b.band_y1_pct));
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_fail <> 3 THEN
      RAISE EXCEPTION 'CONTROL FAILED: only % of 3 derived bands fail the edge-on-rule test, so the test does not discriminate', v_fail;
    END IF;
    RAISE NOTICE 'CONTROL OK: all 3 derived bands fail the edge-on-rule test that the snapped bands pass';
  END;

  ------------------------------------------------------------------------
  -- 5.3  THE LEAK, asserted rather than described. 069-TCE's derived band began at
  --      40.805, inside printed slot 3 (39.848 - 47.445), which is 242-WYN's third
  --      permit row. Its served document would have carried another client's
  --      facility name and street address.
  ------------------------------------------------------------------------
  IF NOT (40.805 > 39.848 AND 40.805 < 47.445) THEN
    RAISE EXCEPTION 'the recorded leak arithmetic does not hold against the detected boundaries';
  END IF;

  ------------------------------------------------------------------------
  -- 5.4  Contiguous, monotonic, no overlap, and covering the whole roster.
  ------------------------------------------------------------------------
  SELECT string_agg(c.client_code || ':' || a.band_y0_pct || '-' || a.band_y1_pct, ' ' ORDER BY a.band_y0_pct)
    INTO v_txt
    FROM derm.address_row_map a JOIN public.clients c ON c.id = a.matched_client_id
   WHERE a.white_manifest_number = '833395';
  IF v_txt IS DISTINCT FROM
     '242-WYN:24.309-47.445 069-TCE:47.445-55.456 032-LG:55.456-63.605' THEN
    RAISE EXCEPTION 'bands do not tile the roster as intended: %', v_txt;
  END IF;

  ------------------------------------------------------------------------
  -- 5.5  Each stamp inside its OWN band. A human placed each stamp on that client's
  --      own printed row, so this is independent evidence for the assignment.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.address_row_map a
   WHERE a.white_manifest_number = '833395'
     AND NOT (a.stamp_y_pct > a.band_y0_pct AND a.stamp_y_pct < a.band_y1_pct);
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% stamps fall outside their own band', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 5.6  No band may contain another client's stamp.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a
    JOIN derm.address_row_map b ON b.white_manifest_number = a.white_manifest_number AND b.id <> a.id
   WHERE a.white_manifest_number = '833395'
     AND b.stamp_y_pct > a.band_y0_pct AND b.stamp_y_pct < a.band_y1_pct;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% bands contain another client''s stamp', v_n;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- PART 6.  Only now, the extent. It is bound to the printed ROSTER: the first and
--          last slot boundary. All five printed slots are occupied on this sheet
--          (three by 242-WYN), so roster and band envelope coincide -- that is a
--          fact about this sheet, NOT a rule. Where a roster has an empty slot the
--          extent must be WIDER than the bands.
-- ---------------------------------------------------------------------------

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source)
VALUES ('ticket-833395', 1, 24.309, 63.605, 'claude-rulesnap-2026-08-24')
ON CONFLICT (dump_folder, effective_page) DO UPDATE
  SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
      source = EXCLUDED.source, measured_at = now();

DO $$
DECLARE v_n int; v_top numeric; v_bot numeric;
BEGIN
  SELECT top_pct, bottom_pct INTO v_top, v_bot
    FROM derm.page_block_extents WHERE dump_folder = 'ticket-833395' AND effective_page = 1;

  -- the extent must never be narrower than the bands: narrowing is the leak direction
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE white_manifest_number = '833395'
     AND (band_y0_pct < v_top OR band_y1_pct > v_bot);
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% bands fall outside the extent, which would serve them unredacted', v_n;
  END IF;

  -- both extent edges are themselves detected boundaries
  IF NOT EXISTS (SELECT 1 FROM derm.page_row_rules WHERE dump_folder = 'ticket-833395'
                  AND effective_page = 1 AND kind = 'boundary' AND rule_pct = v_top)
     OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules WHERE dump_folder = 'ticket-833395'
                  AND effective_page = 1 AND kind = 'boundary' AND rule_pct = v_bot) THEN
    RAISE EXCEPTION 'an extent edge is not on a detected boundary';
  END IF;

  -- the folder must leave the blocked list
  IF EXISTS (SELECT 1 FROM derm.v_blackout_blocked_sheets WHERE dump_folder = 'ticket-833395') THEN
    RAISE EXCEPTION 'ticket-833395 is still blocked after the extent was added';
  END IF;

  -- and it must now be QUEUED for redaction, or the whole exercise produced nothing
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(50) t
   WHERE t::text LIKE '%833395%';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'expected 3 blackout targets for 833395, got % -- the gate is still refusing', v_n;
  END IF;

  RAISE NOTICE 'OK: 3 bands snapped onto printed boundaries, extent 24.309-63.605, 3 documents queued';
END $$;

COMMIT;
