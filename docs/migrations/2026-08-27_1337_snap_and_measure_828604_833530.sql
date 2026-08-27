-- 2026-08-27_1337_snap_and_measure_828604_833530.sql
--
-- WHY
-- ---
-- Fred, 2026-08-27: "yes clear those 7 now." Seven clients across two folders cannot be served a
-- redacted FOG sheet because neither page has ever had its printed roster measured, and
-- `derm.page_block_extents` is the gate:
--
--   ticket-833530  191-TEN, 307-LEP, 249-LOU        -- NO document at all; the one Fred opened with
--   ticket-828604  092-TCE, 104-PV, 110-CLA, 147-OST -- blocked on the extent alone
--
-- Both sheets were stamped by a person and marked complete, and neither could publish, because
-- completion says nothing about geometry. These two folders are the evidence for
-- `Building Apps/DERM Stamp Studio/docs/11-completion-gated-publish-spec.md`.
--
-- `derm.v_blackout_blocked_sheets` named both and told me which one each needed:
--   ticket-828604  blocker `needs_extent`            bands_derived 0, rows_ready 4
--   ticket-833530  blocker `needs_snap_then_extent`  bands_derived 3, rows_ready 3
--
-- 🛑 HANDWRITTEN PAD SHEETS, SO THE `printed rows == owned cards` GATE CANNOT ANSWER. I LOOKED AT
-- THE PAPER INSTEAD. The row OCR read 6 rows on each page and returned `client_code_read = NULL` at
-- LOW confidence for all 12: pad sheets carry no printed client codes. The code-matching check that
-- cleared `ticket-833813` this morning is unavailable here, and its silence is an EVIDENCE GAP, not
-- an all-clear.
--
-- What the OCR does establish is the COUNT: 6 printed slots per page, against 4 and 3 owned cards.
-- That leaves 2 and 3 UNOWNED slots, and a printed-but-unowned slot is exactly what made
-- `ticket-310590` p2 a real leak on 2026-08-19. Both pages were therefore rendered with the detected
-- boundaries drawn on and read by eye (2026-08-27):
--
--   ticket-828604  rows 1-4 filled: The Carrot Express / Pura Vida / Claudie / Maison Ostrow,
--                  matching 092-TCE / 104-PV / 110-CLA / 147-OST. Rows 5-6 GENUINELY EMPTY.
--                  (This is the sheet Fred drew his rectangle mockup on, so its filled rows are
--                  independently corroborated by his own screenshot.)
--   ticket-833530  rows 1-3 filled: Ten tends / Lenox-Excell Plumbing / Flip A Burger-Skinny Louis
--                  Wynwood, matching 191-TEN / 307-LEP / 249-LOU. Rows 4-6 GENUINELY EMPTY.
--
-- No printed-but-unowned facility on either page.
--
-- THE GEOMETRY
-- ------------
-- The v2 run-length detector, transported verbatim. Both pages came back as textbook alternation,
-- 7 full-width boundaries and 6 mid-slot dividers, with no under-scored boundary:
--
--   ticket-828604  28.177  33.564  39.088  44.475  49.862  55.387  60.773
--   ticket-833530  27.411  32.946  38.482  44.018  49.375  54.911  60.268
--
-- ✅ ONLY ONE PAGE NEEDS ITS RULES RECORDED. `ticket-828604` p1 was already scanned on 2026-08-23
-- (`runlen-v2-2026-08-21`, 19 rules) and today's run reproduced **all 19 to 3 decimals, max delta
-- 0.0000pp**. That is a reproducibility control on the detector, and it is why this migration does
-- NOT write a second, redundant scan for that page: its bands snap onto the rules already there.
-- Only `ticket-833530` gets a new scan and rule set.
--
-- 🛑 THE EXTENT DELIBERATELY REACHES FAR PAST THE BANDS, WHICH IS THE POINT ON THESE TWO PAGES.
--   ticket-828604  bands end 49.862, extent to 60.773  (2 empty slots covered)
--   ticket-833530  bands end 44.018, extent to 60.268  (3 empty slots covered)
-- Setting the extent to the band envelope would leave those empty slots BELOW the lower black box
-- and serve them. They are empty today, so nothing would leak today, but the extent is bound to the
-- printed roster and never to where the clients happen to sit. `2026-08-03_0046` is on record as
-- the leak the other reasoning caused.
--
-- ⚠ ticket-828604's four bands already existed (`claude-rulesnap-2026-08-20`) and sit 0.069pp off
-- the detected boundaries, inside the 0.35pp ON_RULE tolerance, so they were never wrong. They are
-- re-snapped anyway because on three of the four that 0.069pp is OUTWARD, into a neighbour's slot.
-- At 724px page height that is half a pixel and it leaks nothing, but exactly-on-rule is the
-- standard here and these documents regenerate in this migration regardless.
--
-- ⚠ NOT TOUCHED, ON PURPOSE: `ticket-312024` entered the worklist 90 minutes ago (9 clients, last
-- stamp 12:15 ET today). It is the folder whose image 2 is handwritten pad sheet 421 rather than
-- page 2 of generated sheet 1099, and CLAUDE.md records that the closed-world refusal there is the
-- system working. Measuring it is a separate question for Fred, not part of "clear those 7".
--
-- RULE 8 (audit trail): `derm.address_row_map` and `derm.page_block_extents` are both audited, so
-- the band and extent writes carry `old_row`. `page_row_rules` / `page_rule_scans` are regenerable
-- detector output and remain opt-out.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground this migration stands on has not moved.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  -- Every card must be stamped, or the whole-folder closed-world gate freezes the folder and
  -- measuring it publishes nothing. (ticket-830714 is in exactly that state and is left alone.)
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder IN ('ticket-828604','ticket-833530') AND stamp_placed_at IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PART 0: % card(s) have no stamp_placed_at; the folder is frozen and measuring it changes nothing', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder IN ('ticket-828604','ticket-833530');
  IF v_n <> 7 THEN RAISE EXCEPTION 'PART 0: expected 7 cards, found %', v_n; END IF;

  -- Neither page may already carry an extent.
  SELECT count(*) INTO v_n FROM derm.page_block_extents
   WHERE dump_folder IN ('ticket-828604','ticket-833530');
  IF v_n <> 0 THEN RAISE EXCEPTION 'PART 0: % extent(s) already exist', v_n; END IF;

  -- The 828604 boundaries this migration RELIES ON rather than re-recording. If they moved, the
  -- bands below would snap onto rules that are no longer what was measured.
  SELECT count(*) INTO v_n FROM derm.page_row_rules
   WHERE dump_folder='ticket-828604' AND effective_page=1
     AND source='runlen-v2-2026-08-21' AND kind='boundary'
     AND rule_pct IN (28.177,33.564,39.088,44.475,49.862,55.387,60.773);
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'PART 0: expected the 7 stored 828604 boundaries, found %', v_n;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- PART 1. Record the detector run for ticket-833530 (the only page that needs it).
-- ---------------------------------------------------------------------------
-- 🛑 source_etag is populated HERE, not left to a follow-up. Omitting it makes every band on the
-- page grade STALE before `edge_verdict` looks at an edge at all: the trap that cost a migration
-- earlier today (2026-08-27_1057 PART 0).
INSERT INTO derm.page_rule_scans
  (dump_folder, effective_page, source_url, image_w, image_h, skew, n_rules, n_boundaries,
   pitch_pct, grade, detail, source, scanned_at, source_etag)
VALUES
  ('ticket-833530', 1, 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1738/address_1.jpg', 724, 560, 0, 20, 7, 5.476, 'OK',
   'Handwritten pad sheet, 6 printed slots, 3 owned. Textbook alternation: 7 full-width boundaries and 6 mid-slot dividers, one per slot. Slots 4-6 confirmed EMPTY by eye 2026-08-27.',
   'runlen-v2-2026-08-27', now(), derm._img_etag('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1738/address_1.jpg'))
;

-- ---------------------------------------------------------------------------
-- PART 2. Its 20 detected rules, classified by alternation inside the roster.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, run_frac, ink_frac, kind, kind_confirmed, source, detected_at)
VALUES
  ('ticket-833530', 1, 11.607, 0.983, 0.983, 'header-footer', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 14.196, 0.983, 0.192, 'header-footer', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 25.000, 0.362, 0.571, 'unclassified', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 27.411, 0.982, 0.721, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 30.179, 0.360, 0.387, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 32.946, 0.982, 0.733, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 35.625, 0.363, 0.340, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 38.482, 0.983, 0.894, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 41.161, 0.367, 0.333, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 44.018, 0.983, 0.925, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 46.518, 0.362, 0.080, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 49.375, 0.983, 0.632, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 52.054, 0.363, 0.173, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 54.911, 0.985, 0.900, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 57.589, 0.363, 0.327, 'divider', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 60.268, 0.983, 0.210, 'boundary', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 62.411, 0.980, 0.871, 'header-footer', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 64.732, 0.982, 0.452, 'header-footer', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 76.696, 0.400, 0.716, 'unclassified', true, 'runlen-v2-2026-08-27', now()),
  ('ticket-833530', 1, 77.321, 0.980, 0.977, 'header-footer', true, 'runlen-v2-2026-08-27', now())
;

-- ---------------------------------------------------------------------------
-- PART 3. SNAP THE BANDS onto the detected boundaries. Bands first, extent second.
-- ---------------------------------------------------------------------------
-- 🛑 Order matters: the extent is what OPENS the gate. Adding it while any band is still derived
-- publishes that client from a stamp-midpoint guess, which is the 2026-08-19 leak. Bands are made
-- correct before the gate opens, never after.
--
-- Matched on (folder, page, stamp_y_pct) rather than by id, so the statement cannot attach a band
-- to a card whose stamp moved between the read and this write.
UPDATE derm.address_row_map r
   SET band_y0_pct = v.y0, band_y1_pct = v.y1,
       band_source = 'runlen-snap-2026-08-27', band_set_at = now(),
       band_set_by = 'claude-runlen-2026-08-27'
  FROM (VALUES
    ('ticket-828604', 1, 30.854::numeric, 28.177::numeric, 33.564::numeric),  -- 092-TCE
    ('ticket-828604', 1, 36.305::numeric, 33.564::numeric, 39.088::numeric),  -- 104-PV
    ('ticket-828604', 1, 41.487::numeric, 39.088::numeric, 44.475::numeric),  -- 110-CLA
    ('ticket-828604', 1, 46.668::numeric, 44.475::numeric, 49.862::numeric),  -- 147-OST
    ('ticket-833530', 1, 29.940::numeric, 27.411::numeric, 32.946::numeric),  -- 191-TEN
    ('ticket-833530', 1, 35.365::numeric, 32.946::numeric, 38.482::numeric),  -- 307-LEP
    ('ticket-833530', 1, 40.923::numeric, 38.482::numeric, 44.018::numeric)   -- 249-LOU
  ) AS v(folder, pg, stamp_y, y0, y1)
 WHERE r.dump_folder = v.folder
   AND COALESCE(r.stamp_page, r.page) = v.pg
   AND r.stamp_y_pct = v.stamp_y;

-- ---------------------------------------------------------------------------
-- PART 4. AND ONLY NOW THE EXTENT, spanning all six printed slots on each page.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES
  ('ticket-828604', 1, 28.177, 60.773, 'runlen-v2-2026-08-21', now()),
  ('ticket-833530', 1, 27.411, 60.268, 'runlen-v2-2026-08-27', now())
;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer;
BEGIN
  -- 1. All seven cards banded by this run.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder IN ('ticket-828604','ticket-833530') AND band_source = 'runlen-snap-2026-08-27';
  IF v_n <> 7 THEN RAISE EXCEPTION 'VERIFY 1 failed: % of 7 cards banded', v_n; END IF;

  -- 2. 🛑 EVERY BAND EDGE IS A RECORDED `boundary`. This is the check that fails on a derived band,
  --    on a uniformly shifted tiling, and on a partly-stamped roster, which is why it is the one
  --    that matters. Deliberately source-agnostic across runlen-v2 runs: 828604 snaps onto the
  --    2026-08-21 rules, 833530 onto today's.
  SELECT count(*) INTO v_bad FROM derm.address_row_map r
   WHERE r.dump_folder IN ('ticket-828604','ticket-833530')
     AND (NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                       WHERE p.dump_folder=r.dump_folder AND p.effective_page=COALESCE(r.stamp_page,r.page)
                         AND p.source LIKE 'runlen-v2-%' AND p.kind='boundary' AND p.rule_pct=r.band_y0_pct)
       OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                       WHERE p.dump_folder=r.dump_folder AND p.effective_page=COALESCE(r.stamp_page,r.page)
                         AND p.source LIKE 'runlen-v2-%' AND p.kind='boundary' AND p.rule_pct=r.band_y1_pct));
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % band edge(s) not on a detected boundary', v_bad; END IF;

  -- 3. Each stamp sits comfortably inside its own band (T1).
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE dump_folder IN ('ticket-828604','ticket-833530')
     AND NOT (stamp_y_pct > band_y0_pct + 0.5 AND stamp_y_pct < band_y1_pct - 0.5);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 3 failed: % stamp(s) not inside their band', v_bad; END IF;

  -- 4. 🛑 NO TWO CARDS OVERLAP. Gaps are safe; an overlap serves a neighbour's printed row.
  SELECT count(*) INTO v_bad FROM derm.address_row_map a
    JOIN derm.address_row_map b
      ON b.dump_folder=a.dump_folder AND COALESCE(b.stamp_page,b.page)=COALESCE(a.stamp_page,a.page)
     AND b.id < a.id AND a.band_y0_pct < b.band_y1_pct AND a.band_y1_pct > b.band_y0_pct
   WHERE a.dump_folder IN ('ticket-828604','ticket-833530');
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % overlapping band pair(s)', v_bad; END IF;

  -- 5. 🛑 THE EXTENT MUST REACH PAST THE LAST BAND, because both pages carry EMPTY printed slots
  --    below the last client. Equality would leave those slots outside the black box.
  SELECT count(*) INTO v_bad FROM derm.page_block_extents e
   WHERE e.dump_folder IN ('ticket-828604','ticket-833530')
     AND e.bottom_pct <= (SELECT max(r.band_y1_pct) FROM derm.address_row_map r
                           WHERE r.dump_folder=e.dump_folder
                             AND COALESCE(r.stamp_page,r.page)=e.effective_page);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % extent(s) stop at or above the last band, leaving empty printed slots served', v_bad;
  END IF;

  -- 6. And it contains every band.
  SELECT count(*) INTO v_bad FROM derm.page_block_extents e
    JOIN derm.address_row_map r ON r.dump_folder=e.dump_folder
     AND COALESCE(r.stamp_page,r.page)=e.effective_page
   WHERE e.dump_folder IN ('ticket-828604','ticket-833530')
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % band(s) outside the extent', v_bad; END IF;

  -- 7. THE POINT: all seven pairs are now publishable.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
    JOIN derm.address_row_map r ON r.matched_manifest_id=t.manifest_id AND r.matched_client_id=t.client_id
   WHERE r.dump_folder IN ('ticket-828604','ticket-833530');
  IF v_n <> 7 THEN RAISE EXCEPTION 'VERIFY 7 failed: % of 7 cards became blackout targets', v_n; END IF;

  -- 8. Neither folder is reported blocked any more. Scoped to these two on purpose: the worklist
  --    still legitimately holds ticket-312024, ticket-830714, ticket-833049, window4-sheet1 and
  --    window5-sheet3, none of which this migration touches.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder IN ('ticket-828604','ticket-833530');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 8 failed: % of the 2 folders still reported blocked', v_n; END IF;

  -- 9. Nothing else moved. Measured immediately before applying: 164 extents, 649 banded rows,
  --    24 rules on 828604 (19 runlen + 5 rulesnap). 833530 contributes 3 newly banded rows;
  --    828604's 4 were already banded and were re-snapped in place.
  SELECT count(*) INTO v_n FROM derm.page_block_extents;
  IF v_n <> 166 THEN RAISE EXCEPTION 'VERIFY 9 failed: extents % expected 166', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_y0_pct IS NOT NULL;
  IF v_n <> 652 THEN RAISE EXCEPTION 'VERIFY 9 failed: banded rows % expected 652', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.page_row_rules WHERE dump_folder='ticket-828604';
  IF v_n <> 24 THEN RAISE EXCEPTION 'VERIFY 9 failed: 828604 rules % expected 24 (unchanged)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 7 bands on detected boundaries, both extents span all 6 printed slots and reach past the last band, no overlaps, neither folder blocked, all 7 pairs publishable.';
END $do$;

COMMIT;
