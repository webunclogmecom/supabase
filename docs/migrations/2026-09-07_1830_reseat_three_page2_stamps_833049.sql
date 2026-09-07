-- ============================================================================================
-- 2026-09-07_1830_reseat_three_page2_stamps_833049.sql
--
-- Move three stamps on ticket-833049 page 2 onto the client's OWN printed row. They currently sit
-- one printed row too low, which would have served two clients another company's compliance row.
--
-- WHY (Fred, 2026-09-07): "fix the three stamps then i'll draw the lines".
--
-- 🛑 WHAT WAS WRONG. All five page-2 cards still carry the template ladder
--       29.800 / 37.720 / 44.480 / 51.810 / 60.040
-- written by stamp-studio-ai on 2026-08-17. Fred proved that ladder does not fit this pad when he
-- re-placed the FIVE PAGE-1 CARDS off exactly those same values at 15:57-15:58 ET today
-- (audit.logs: 969 29.800->32.621, 968 37.720->37.925, 971 44.480->43.850, 972 51.810->49.224,
-- 970 60.040->54.804). Page 2 was never given the same treatment, so it kept the bad ladder.
--
-- Against the printed rules detected on address_2.jpg, the seating is:
--       slot 1  [27.921, 33.356]  Ceviche Inka     114-CI @ 29.800   CORRECT
--       slot 2  [33.356, 38.655]  AVA              168-AVA @ 37.720  CORRECT
--       slot 3  [38.655, 44.090]  Yaya             (nobody)          ORPHANED
--       slot 4  [44.090, 49.389]  LA Spaiolta      221-YAS @ 44.480  WRONG, that is Yaya's card
--       slot 5  [49.389, 54.823]  214 MYK Brickell 222-SPE @ 51.810  WRONG, that is Le Specialita's
--       slot 6  [54.823, 60.190]  (empty row)      214-MYK @ 60.040  WRONG
--
-- ⚠ EVERY GEOMETRY GUARD ACCEPTS THAT. G13 is the only check tying a band to its owner and it
-- passes, because the band would have been chosen BY the wrong stamp. G9 passes because each edge
-- IS a printed rule. CLAUDE.md already states this: "a tiling shifted by one whole slot satisfies
-- G7, G8 and G9 simultaneously". The one thing holding page 2 today is G9_NOT_MEASURED, and the
-- operator removes that by drawing the lines, which is the very next step. So this is not a
-- theoretical mis-seating: it is armed, and the intended workflow is the trigger.
--
-- PROVENANCE OF THE NUMBERS. The rules were detected with the estate's own run-length detector,
-- ported to Node so it runs without a browser (scripts/probes/rev/detect_node.js, transcribed from
-- scripts/probes/derm_band_review/detect-run.js, not rewritten). POSITIVE CONTROL: on page 1 of
-- this same folder it reproduces Fred's hand-drawn lines to within 0.236pp on all seven
-- boundaries. A detector with no control is an untested instrument; this one has one, on the
-- adjacent page of the same sheet.
--
-- The new y values are the DETECTED MID-SLOT DIVIDERS (41.372 / 46.807 / 52.174), which is the
-- convention Fred used himself: his five page-1 stamps sit within 0.27pp of that page's dividers.
-- They are printed lines on the paper, not arithmetic midpoints.
--
-- ⚠ THIS WRITES NO GEOMETRY. No page_row_rules, no bands, no extent. Fred draws the lines. Moving
-- a stamp cannot publish anything on its own, and deliberately leaving page 2 unmeasured keeps
-- G9_NOT_MEASURED in place until a person has looked at the page.
--
-- ⚠ stamp_placed_by is set to an honest machine label, NOT left as derm._actor's 'stamp-studio'
-- default. Over the Management API there is no JWT, so the RPC would have labelled this as a
-- Studio placement and a later reader would believe Fred did it by hand.
--
-- RULE 8: no schema change. derm.address_row_map is not audit-triggered itself, but audit.logs
-- carries these rows via the Studio's own writes; the change is recorded here and in PART 0.
-- ============================================================================================

BEGIN;

-- ============================================================================================
-- PART 0. PRECONDITIONS. Refuse to apply if the world is not what was measured.
-- ============================================================================================
DO $pre$
DECLARE
  v_n int;
  v_y numeric;
BEGIN
  -- 0.1 The three cards are where the measurement found them. If anything moved since, this
  --     migration's numbers describe a state that no longer exists.
  FOR v_n, v_y IN SELECT * FROM (VALUES (963, 44.480::numeric), (964, 51.810), (967, 60.040)) v LOOP
    IF NOT EXISTS (
      SELECT 1 FROM derm.address_row_map r
       WHERE r.id = v_n AND r.dump_folder = 'ticket-833049'
         AND r.stamp_page = 2 AND r.stamp_y_pct = v_y AND r.stamp_placed_by = 'stamp-studio-ai'
    ) THEN
      RAISE EXCEPTION 'PRE 0.1: card % is not at the measured position % on page 2 with the '
                      'stamp-studio-ai label; it has been touched since this was measured', v_n, v_y;
    END IF;
  END LOOP;

  -- 0.2 The two CORRECT cards are also where they were. They must not be touched, and if they
  --     have moved then the page is not the page that was measured.
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 966 AND stamp_y_pct = 29.800)
     OR NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 965 AND stamp_y_pct = 37.720) THEN
    RAISE EXCEPTION 'PRE 0.2: cards 966/965 are not at their measured positions';
  END IF;

  -- 0.3 Exactly five cards on page 2, so no sixth client has appeared that the seating ignores.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND COALESCE(stamp_page, page) = 2;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'PRE 0.3: page 2 holds % cards, expected 5', v_n;
  END IF;

  -- 0.4 Nothing is published and nothing is measured, so this cannot disturb a served document.
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.4: % extent row(s) exist', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT id FROM public.derm_manifests WHERE white_manifest_number='833049');
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.4: % published document(s) exist', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-833049' AND effective_page = 2;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.5: page 2 already carries % printed rule(s). This migration assumes it '
                    'is unmeasured, and the operator is about to draw the lines.', v_n;
  END IF;

  -- 0.6 No bands anywhere in the folder, so moving a stamp cannot orphan an override.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND (band_y0_pct IS NOT NULL OR band_y1_pct IS NOT NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.6: % card(s) already carry a manual band', v_n; END IF;

  RAISE NOTICE 'PRE OK: 3 cards on the stale ladder, 2 correct cards untouched, 0 rules, 0 bands, '
               '0 extents, 0 published documents.';
END
$pre$;

-- ============================================================================================
-- THE CHANGE. Through the sanctioned RPC, so the witness trigger and every other side effect
-- behave exactly as they do for a Studio placement.
--   963  221-YAS  Yaya              44.480 -> 41.372   (slot 4 -> slot 3, its own row)
--   964  222-SPE  LA Spaiolta       51.810 -> 46.807   (slot 5 -> slot 4)
--   967  214-MYK  214 MYK Brickell  60.040 -> 52.174   (slot 6 -> slot 5)
-- x is unchanged at 8, matching all five cards and both pages.
-- ============================================================================================
SELECT derm.set_stamp_position(963, 2, 8, 41.372);
SELECT derm.set_stamp_position(964, 2, 8, 46.807);
SELECT derm.set_stamp_position(967, 2, 8, 52.174);

-- Honest provenance. derm._actor falls back to 'stamp-studio' when there is no JWT, which over
-- this transport would misattribute a repair script to a person working in the app.
UPDATE derm.address_row_map
   SET stamp_placed_by = 'claude-reseat-2026-09-07'
 WHERE id IN (963, 964, 967);

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  B      numeric[] := ARRAY[27.921, 33.356, 38.655, 44.090, 49.389, 54.823, 60.190];
  v_n    int;
  v_txt  text;
BEGIN
  -- 1. EVERY client now sits in its OWN printed slot, in the order printed on the paper.
  --    width_bucket over the detected boundaries gives the printed row index directly.
  SELECT string_agg(c.client_code || '=' || width_bucket(r.stamp_y_pct, B), ' ' ORDER BY r.stamp_y_pct)
    INTO v_txt
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-833049' AND COALESCE(r.stamp_page, r.page) = 2;

  IF v_txt <> '114-CI=1 168-AVA=2 221-YAS=3 222-SPE=4 214-MYK=5' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: seating is "%", expected '
                    '"114-CI=1 168-AVA=2 221-YAS=3 222-SPE=4 214-MYK=5"', v_txt;
  END IF;

  -- 2. MUTATION CONTROL. The OLD values, against the SAME boundaries, must land in the wrong
  --    slots. Without this, VERIFY 1 would pass just as happily against boundaries that cannot
  --    discriminate anything, and the defect would be unproven.
  SELECT string_agg(code || '=' || width_bucket(y, B), ' ' ORDER BY y) INTO v_txt
    FROM (VALUES ('114-CI', 29.800::numeric), ('168-AVA', 37.720), ('221-YAS', 44.480),
                 ('222-SPE', 51.810), ('214-MYK', 60.040)) t(code, y);
  IF v_txt <> '114-CI=1 168-AVA=2 221-YAS=4 222-SPE=5 214-MYK=6' THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: the OLD ladder maps to "%", so it does not reproduce '
                    'the mis-seating and VERIFY 1 proves nothing', v_txt;
  END IF;

  -- 3. No two clients share a printed slot, and slot 3 is no longer orphaned.
  SELECT count(*) INTO v_n FROM (
    SELECT width_bucket(r.stamp_y_pct, B) AS slot
      FROM derm.address_row_map r
     WHERE r.dump_folder = 'ticket-833049' AND COALESCE(r.stamp_page, r.page) = 2
     GROUP BY 1 HAVING count(*) > 1) x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % slot(s) hold more than one client', v_n; END IF;

  -- 4. THE TWO CORRECT CARDS WERE NOT TOUCHED. A repair that quietly moves a good row is worse
  --    than one that fails.
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map
                  WHERE id = 966 AND stamp_y_pct = 29.800 AND stamp_placed_by = 'stamp-studio-ai')
     OR NOT EXISTS (SELECT 1 FROM derm.address_row_map
                  WHERE id = 965 AND stamp_y_pct = 37.720 AND stamp_placed_by = 'stamp-studio-ai') THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: card 966 or 965 was modified';
  END IF;

  -- 5. NOTHING BECAME PUBLISHABLE. No geometry was written, so page 2 is still unmeasured and
  --    the folder still cannot publish. This migration must not have moved that.
  SELECT count(*) INTO v_n FROM derm.page_row_rules
   WHERE dump_folder = 'ticket-833049' AND effective_page = 2;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % printed rule(s) were written', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % extent(s) were written', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND band_y0_pct IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % band(s) were written', v_n; END IF;

  IF derm.fn_sheet_publishable('ticket-833049') IS NULL THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the folder became publishable, which this migration must '
                    'not have caused';
  END IF;

  -- 6. All five stay on page 2 and keep a witness naming the page-2 scan. If a stamp's witness
  --    had moved to address_1 the redactor would later cut it from the wrong image.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND COALESCE(stamp_page, page) = 2
     AND (stamp_page <> 2 OR stamp_image_url NOT LIKE '%address_2%');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % page-2 card(s) lost their page or their address_2 witness', v_n;
  END IF;

  -- 7. Provenance is honest: the three moved cards say a script moved them.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE id IN (963, 964, 967) AND stamp_placed_by = 'claude-reseat-2026-09-07';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: only % of 3 cards carry the repair label', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: five clients in five distinct printed slots in printed order, '
               'the old ladder proven wrong by the same measurement, the two correct cards '
               'untouched, and nothing published or made publishable.';
END
$verify$;

COMMIT;
