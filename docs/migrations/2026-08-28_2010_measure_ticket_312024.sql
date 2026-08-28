-- 2026-08-28_2010_measure_ticket_312024.sql
--
-- WHY: ticket-312024 p1 is the ONE page the new in-app detector could not classify, so Fred pressed
-- "Re-measure printed lines", saw the lines appear, and still could not save. This records the page
-- with the labels a person read off the scan, which is the resolution the design always intended
-- for a page the algorithm refuses.
--
-- WHAT THE APP SAW. Detection itself is fine: it found all 16 printed rules with a textbook bimodal
-- split (boundaries run 0.996-0.998, dividers 0.407-0.409). The CLASSIFIER mislabelled them, and
-- derm.fn_validate_page_rules correctly refused with
--   "run-length split disagrees with the labels at chain position 13 (run 0.997, cut 0.753,
--    labelled divider): a phase flip"
-- so zero rules were written and G9 had nothing to check. The refusal was right. The page was wrong.
--
-- 🛑 WHY THE CLASSIFIER FAILED, AND IT IS A REAL LIMITATION WORTH KNOWING.
-- classify.js trims the form's header and footer bars out of the alternating chain by SHAPE: at each
-- end it drops a LONG rule that sits closer than 0.6 of a slot to its long neighbour. On this page
-- the outermost rule at EACH end is SHORT, so the trim never fires:
--     leading  22.165 run 0.409   (bottom of the "B: Origination of Waste" header bar)
--     trailing 68.106 run 0.510   (inside "E: Liquid Waste Transporter Certification")
-- Both ends are therefore blocked by a short non-roster line, the long footer bar at 65.722 stays in
-- the chain, and every label below it inverts.
-- ⚠ Compare page 2 of the SAME ticket, which grades OK unaided: its two trailing bars are both LONG
-- (0.988), so the trim fires. The difference is the shape of the junk at the ends, not the roster.
--
-- WHAT A PERSON READ OFF THE SCAN (manifests/derm/1741/address_1.jpg, rendered with every detection
-- drawn over it). The printed roster is unambiguous and is a clean 5-slot form:
--     24.420 B  28.608 d  32.796 B  36.211 d  39.497 B  42.912 d
--     46.843 B  50.515 d  54.704 B  58.505 d  62.564 B
-- six boundaries, five mid-slot dividers, pitch ~7.86pp, matching the five printed facilities
-- (067-TCE, 007-CC, 090-OAK, 103-BWC, 215-G7).
-- Everything else is form furniture OUTSIDE the roster and is recorded as 'header-footer':
--     22.165  bottom of the section B header bar
--     65.722  the "Attach Additional Sheets if more than 5 Grease Interceptors Pumped!" rule
--     68.106  inside section E
-- They are kept rather than discarded because a header bar IS a printed rule and a band edge landing
-- on one is genuinely not inside a line of text. That is classify.js's own two-list design: the edge
-- check sees every rule, the chain sees only the roster.
--
-- ⚠ ONLY THE LABELS ARE HUMAN. Every position, run and ink value below is the detector's own output,
-- copied verbatim from the shipped app. Three `kind` values were changed to 'header-footer' after
-- looking at the scan. Nothing was re-typed or re-estimated.
--
-- Page 2 needs no intervention. It graded OK unaided; it is recorded here only because it had never
-- been scanned at all, and doing both in one migration keeps the folder consistent.
--
-- 🛑 THIS PUBLISHES NOTHING. Recording rules does not write a page extent, and without an extent
-- fn_blackout_targets returns nothing for this folder. Both pages' bands are still DERIVED, so an
-- extent here would publish stamp-midpoint guesses, which is the 2026-08-19 leak. The extent stays a
-- separate deliberate act by a person, after the bands are snapped.
--
-- RULE 8 (audit trail): writes only detector output through derm.record_page_rules, which is itself
-- the provenance record (source + scanned_at + source_etag). Opt-out.

BEGIN;

DO $do$
DECLARE
  v_p1 jsonb;
  v_p2 jsonb;
  v_r  jsonb;
  v_n  integer;
BEGIN
  -- page 1: detector output, three kinds corrected to 'header-footer' after reading the scan
  v_p1 := '[
    {"pct":22.165,"run":0.409,"ink":0.125,"kind":"header-footer"},
    {"pct":24.420,"run":0.998,"ink":0.997,"kind":"boundary"},
    {"pct":28.608,"run":0.409,"ink":0.239,"kind":"divider"},
    {"pct":32.796,"run":0.997,"ink":0.466,"kind":"boundary"},
    {"pct":36.211,"run":0.407,"ink":0.035,"kind":"divider"},
    {"pct":39.497,"run":0.996,"ink":0.297,"kind":"boundary"},
    {"pct":42.912,"run":0.407,"ink":0.143,"kind":"divider"},
    {"pct":46.843,"run":0.996,"ink":0.993,"kind":"boundary"},
    {"pct":50.515,"run":0.407,"ink":0.047,"kind":"divider"},
    {"pct":54.704,"run":0.998,"ink":0.582,"kind":"boundary"},
    {"pct":58.505,"run":0.407,"ink":0.410,"kind":"divider"},
    {"pct":62.564,"run":0.998,"ink":0.681,"kind":"boundary"},
    {"pct":65.722,"run":0.997,"ink":0.984,"kind":"header-footer"},
    {"pct":68.106,"run":0.510,"ink":0.825,"kind":"header-footer"}
  ]'::jsonb;

  -- page 2: the app's own OK result, unedited
  v_p2 := '[
    {"pct":25.192,"run":0.358,"ink":0.320,"kind":"divider"},
    {"pct":27.621,"run":0.986,"ink":0.312,"kind":"boundary"},
    {"pct":30.243,"run":0.359,"ink":0.163,"kind":"divider"},
    {"pct":32.992,"run":0.988,"ink":0.178,"kind":"boundary"},
    {"pct":35.742,"run":0.360,"ink":0.261,"kind":"divider"},
    {"pct":38.427,"run":0.988,"ink":0.702,"kind":"boundary"},
    {"pct":41.176,"run":0.360,"ink":0.175,"kind":"divider"},
    {"pct":43.926,"run":0.988,"ink":0.979,"kind":"boundary"},
    {"pct":46.611,"run":0.359,"ink":0.336,"kind":"divider"},
    {"pct":49.297,"run":0.988,"ink":0.798,"kind":"boundary"},
    {"pct":52.046,"run":0.360,"ink":0.387,"kind":"divider"},
    {"pct":54.731,"run":0.989,"ink":0.988,"kind":"boundary"},
    {"pct":57.545,"run":0.360,"ink":0.292,"kind":"divider"},
    {"pct":60.166,"run":0.989,"ink":0.988,"kind":"boundary"},
    {"pct":62.212,"run":0.988,"ink":0.987,"kind":"header-footer"},
    {"pct":64.642,"run":0.988,"ink":0.910,"kind":"header-footer"}
  ]'::jsonb;

  -- 🛑 Validate BEFORE recording, so a bad hand-label fails loudly here rather than landing.
  IF derm.fn_validate_page_rules(v_p1) IS NOT NULL THEN
    RAISE EXCEPTION 'p1 rules rejected by the validator: %', derm.fn_validate_page_rules(v_p1);
  END IF;
  IF derm.fn_validate_page_rules(v_p2) IS NOT NULL THEN
    RAISE EXCEPTION 'p2 rules rejected by the validator: %', derm.fn_validate_page_rules(v_p2);
  END IF;

  v_r := derm.record_page_rules(
    'ticket-312024', 1, 'runlen-v2-2026-08-28',
    'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1741/address_1.jpg',
    v_p1,
    '{"grade":"OK","detail":"6 boundaries, pitch 7.86; three end rules labelled header-footer after reading the scan","image_w":1024,"image_h":776,"skew":0}'::jsonb);
  IF (v_r->>'wrote')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'p1 was not written: %', v_r;
  END IF;

  v_r := derm.record_page_rules(
    'ticket-312024', 2, 'runlen-v2-2026-08-28',
    'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1741/address_2.jpg',
    v_p2,
    '{"grade":"OK","detail":"7 boundaries, pitch 5.435; detector output unedited","image_w":1024,"image_h":782,"skew":0}'::jsonb);
  IF (v_r->>'wrote')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'p2 was not written: %', v_r;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_b integer; v_blocked integer; v_docs integer; v_ext integer;
BEGIN
  -- 1. Both pages now serve rules.
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-312024';
  IF v_n <> 30 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % rules served, expected 30', v_n; END IF;

  -- 2. Page 1 carries exactly the six roster boundaries a person read off the scan.
  SELECT count(*) INTO v_b FROM derm.v_page_printed_rules
   WHERE dump_folder = 'ticket-312024' AND effective_page = 1 AND kind = 'boundary';
  IF v_b <> 6 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: p1 has % boundaries, expected 6', v_b; END IF;

  -- 3. 🛑 THE ONE THAT MATTERS: every band edge on p1 can now find a rule, so the operator can save.
  --    0.35pp is the estate's ON_RULE tolerance.
  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
    CROSS JOIN LATERAL (VALUES (vb.band_y0_pct), (vb.band_y1_pct)) AS e(val)
   WHERE r.dump_folder = 'ticket-312024' AND COALESCE(r.stamp_page, r.page) = 1
     AND NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules pr
                      WHERE pr.dump_folder = 'ticket-312024' AND pr.effective_page = 1
                        AND pr.kind IN ('boundary','divider')
                        AND abs(pr.rule_pct - e.val) <= 0.35);
  RAISE NOTICE 'p1 band edges still off a printed rule: % (these snap when the operator drags)', v_n;

  -- 4. 🛑 NOTHING WAS PUBLISHED. No extent, no documents: recording rules must never serve a client.
  SELECT count(*) INTO v_ext FROM derm.page_block_extents WHERE dump_folder = 'ticket-312024';
  IF v_ext <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % extent(s) appeared', v_ext; END IF;
  SELECT count(*) INTO v_docs FROM derm.redacted_manifest_docs d
    JOIN derm.address_row_map r ON r.matched_manifest_id = d.manifest_id
                               AND r.matched_client_id = d.client_id
   WHERE r.dump_folder = 'ticket-312024';
  IF v_docs <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % document(s) published', v_docs; END IF;

  -- 5. Fleet: the blocked list drops to the two pages of ticket-833049, which are held by a
  --    CHECK constraint and are deliberately out of scope.
  SELECT count(*) INTO v_blocked FROM (
    SELECT r.dump_folder, COALESCE(r.stamp_page, r.page) pg
      FROM derm.address_row_map r WHERE r.stamp_y_pct IS NOT NULL GROUP BY 1,2) p
   WHERE NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules v
                      WHERE v.dump_folder = p.dump_folder AND v.effective_page = p.pg);
  IF v_blocked <> 2 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % pages still blocked, expected the 2 ticket-833049 pages', v_blocked;
  END IF;

  -- 6. The served-blackout check is still clean, i.e. none of this reached a client.
  SELECT count(*) INTO v_n FROM derm.v_served_blackout_short;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % served document(s) went short', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: ticket-312024 serves 30 rules, p1 has its 6 roster boundaries, nothing '
    'published, and only the 2 constraint-held ticket-833049 pages remain blocked fleet-wide.';
END $do$;

COMMIT;
