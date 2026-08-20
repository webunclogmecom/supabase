-- ============================================================================
-- 2026-08-20_1635  ticket-832996: fit the roster, then open the gate. 5 clients.
-- ============================================================================
--
-- These 5 clients have had a BLANK "DERM FOG eManifest" card in the Field Portal
-- since 2026-08-19 20:57 UTC. derm.v_blackout_blocked_sheets (shipped 2026-08-19_2320
-- for exactly this) has been naming the folder for ~23 hours.
--
-- 🛑 THE ORDER OF THE TWO HALVES IS THE WHOLE POINT AND THEY MUST NEVER SHIP APART.
-- 2026-08-19_2355 PART 0: an extent does not redact anything, it OPENS THE GATE onto
-- whatever bands already exist, and a DERIVED band is a stamp-midpoint heuristic that
-- does not sit on the printed rules. Adding an extent to a derived-band sheet is the
-- UNSAFE act. So PART 1 fixes the bands and PART 2 opens the gate, in one transaction.
--
-- WHY THIS SHEET WAS SAFE TO FIT (all four checked, none assumed)
--
-- 1. READ BY EYE, which is the only page-identity check that exists for a derm-link
--    sheet (the automatic one is scoped to source='claude-vision-v1' and these rows are
--    'derm-link', so it is inert here). Section B carries EXACTLY FIVE printed slots and
--    all five are matched, in the same order top to bottom:
--        GDO-08422  214-MYK Myka Brickell FT LLC   777 Brickell Avenue, Miami 33131
--                   137-BB  Bagel Boss Aventura    18549 W Dixie Hwy, Aventura 33180
--        GDO-02345  003-BC  Bagel Cove             19003 Biscayne Boulevard, Miami 33180
--        GDO-01861  193-FRK Fresko Bakery          19062 NE 29th Avenue, Miami 33180
--        GDO-09017  033-LG  La Granja Allapattah   3333 NW 17th Avenue, Miami 33142
--    NO printed-but-unrowed facility. That is the shape that leaked 165-LPB's identity
--    onto 004-BAO's document on ticket-310590, and it is absent here.
--
-- 2. Every stamp falls strictly inside its fitted slot, with 24-41% clearance from the
--    nearest boundary. A human placed each stamp on that client's own printed row.
--
-- 3. Every boundary below inks at 1.000, i.e. a full-width printed rule. Nothing in the
--    fit used ink; this is independent corroboration.
--
-- 4. ⚠ THE FITTER'S FIRST ANSWER WAS WRONG AND THE IMAGE CAUGHT IT. It proposed a
--    6-slot chain starting at 16.091, which would have made the extent 16.091/66.782 and
--    blacked a band of the transporter-information header as if it were an empty roster
--    slot. 16.091 inks at 0.779 while every real roster boundary inks at 1.000, and the
--    scan shows it sits in Section A, above "B: Origination of Waste". The roster is
--    24.517 to 66.782, five slots, five clients, no empty slot.
--    ⇒ An automatic tiling fit is a proposal. The sheet is the evidence.
--
-- Fitted tiling, gaps 9.25 / 7.46 / 8.15 / 8.70 / 8.70 (slot 2 is genuinely shorter on
-- the paper; its address line is squeezed):
--
--   row  client    stamp    old (derived)      new (fitted)       clearance
--   977  214-MYK   26.75    21.720 -> 31.780   24.517 -> 33.771   24%
--   975  137-BB    36.81    31.780 -> 40.380   33.771 -> 41.229   41%
--   974  003-BC    43.96    40.380 -> 48.270   41.229 -> 49.378   34%
--   973  193-FRK   52.59    48.270 -> 57.000   49.378 -> 58.080   37%
--   976  033-LG    61.41    57.000 -> 65.830   58.080 -> 66.782   38%
--
-- ⚠ The old derived bands were NOT serving anything: with no extent the gate was shut,
--   so nothing was ever generated from them. Nothing is being withdrawn or corrected
--   here; this sheet is being published for the first time.
--
-- ⚠ The order gate in fn_blackout_targets compares rank-by-stamp_y against
--   rank-by-row_index and these rows disagree (row_index 5,3,2,1,4 against stamp order
--   1..5). It does NOT exclude them, because that gate is scoped to
--   source='claude-vision-v1' and these are 'derm-link'. Noted so nobody "fixes" the
--   row_index values and changes behaviour on a sheet that is now correct.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1  The printed rules, then the bands. MUST precede PART 2.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
  ('ticket-832996', 1, 24.517, 1.000, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 33.771, 1.000, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 41.229, 1.000, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 49.378, 1.000, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 58.080, 1.000, 'claude-tilingfit-2026-08-20'),
  ('ticket-832996', 1, 66.782, 1.000, 'claude-tilingfit-2026-08-20')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

UPDATE derm.address_row_map SET band_y0_pct=24.517, band_y1_pct=33.771, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=977;  -- 214-MYK
UPDATE derm.address_row_map SET band_y0_pct=33.771, band_y1_pct=41.229, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=975;  -- 137-BB
UPDATE derm.address_row_map SET band_y0_pct=41.229, band_y1_pct=49.378, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=974;  -- 003-BC
UPDATE derm.address_row_map SET band_y0_pct=49.378, band_y1_pct=58.080, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=973;  -- 193-FRK
UPDATE derm.address_row_map SET band_y0_pct=58.080, band_y1_pct=66.782, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=976;  -- 033-LG

-- ---------------------------------------------------------------------------
-- PART 2  Only now, open the gate. Bounds are the printed roster, first boundary
--         to last, so an empty slot would still be covered. There is none here.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at) VALUES
  ('ticket-832996', 1, 24.517, 66.782, 'claude-tilingfit-2026-08-20', now())
ON CONFLICT (dump_folder, effective_page) DO UPDATE
  SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
      source = EXCLUDED.source, measured_at = EXCLUDED.measured_at;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_n int; v_unbound int; v_stampout int; v_overlap int; v_outside int;
        v_derived int; v_blocked int;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-832996' AND band_source='claude-tilingfit-2026-08-20';
  IF v_n <> 5 THEN RAISE EXCEPTION 'expected 5 bands, found %', v_n; END IF;

  -- no row on this page may still be derived, or the extent opens onto a heuristic
  SELECT count(*) INTO v_derived FROM derm.address_row_map r
   WHERE r.dump_folder='ticket-832996'
     AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL);
  IF v_derived <> 0 THEN RAISE EXCEPTION '% rows on this sheet are still derived; the extent must not be opened', v_derived; END IF;

  SELECT count(*) INTO v_unbound FROM derm.address_row_map r
   WHERE r.dump_folder='ticket-832996'
     AND ( NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y0_pct)
        OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y1_pct) );
  IF v_unbound <> 0 THEN RAISE EXCEPTION '% edges are not detected rules', v_unbound; END IF;

  SELECT count(*) INTO v_stampout FROM derm.address_row_map r
   WHERE r.dump_folder='ticket-832996'
     AND NOT (r.stamp_y_pct > r.band_y0_pct AND r.stamp_y_pct < r.band_y1_pct);
  IF v_stampout <> 0 THEN RAISE EXCEPTION '% stamps fall outside their own band', v_stampout; END IF;

  SELECT count(*) INTO v_overlap FROM derm.address_row_map r
   JOIN derm.address_row_map q ON q.dump_folder=r.dump_folder
    AND COALESCE(q.stamp_page,q.page)=COALESCE(r.stamp_page,r.page) AND q.id<>r.id
    AND q.band_y0_pct < r.band_y1_pct AND q.band_y1_pct > r.band_y0_pct
   WHERE r.dump_folder='ticket-832996';
  IF v_overlap <> 0 THEN RAISE EXCEPTION '% bands overlap a sibling', v_overlap; END IF;

  SELECT count(*) INTO v_outside FROM derm.address_row_map r
   JOIN derm.page_block_extents e ON e.dump_folder=r.dump_folder
    AND e.effective_page=COALESCE(r.stamp_page,r.page)
   WHERE r.dump_folder='ticket-832996'
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_outside <> 0 THEN RAISE EXCEPTION '% bands fall outside the extent', v_outside; END IF;

  -- the point of the exercise: this folder must no longer be blocked
  SELECT count(*) INTO v_blocked FROM derm.v_blackout_blocked_sheets WHERE dump_folder='ticket-832996';
  IF v_blocked <> 0 THEN RAISE EXCEPTION 'ticket-832996 is still reported as blocked'; END IF;

  RAISE NOTICE 'OK: 5 bands fitted and the gate opened; ticket-832996 no longer blocked';
END $$;

COMMIT;
