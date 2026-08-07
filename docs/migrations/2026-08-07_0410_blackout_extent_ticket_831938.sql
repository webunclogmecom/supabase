-- 2026-08-07_0410_blackout_extent_ticket_831938.sql
--
-- WHAT: add the measured Section-B page extents for dump_folder 'ticket-831938' (generated sheet
--       1081, pages 1 and 2), so the FP blackout pipeline can produce the per-client redacted copy.
--
-- WHY: Fred, 2026-08-07: on https://fp.unclogme.app/110-cla/visit/PtBzoCIcyh the
--      "DERM FOG eManifest DERM 831938" image is not showing.
--
-- ROOT CAUSE (measured, not inferred). `customer.work_orders.derm_manifest_url` is NULL for that
--   work order while `manifest_number` is populated, which is why the card renders the number with
--   no image. The FOG card serves a server-side REDACTED copy, never the raw sheet, because 831938
--   is a SHARED 8-client dump ticket (008-CV, 035-LG, 042-MT, 061-TCE, 062-TCE, 087-BB, 091-SB,
--   110-CLA all point at manifests/derm/1680/address_*.JPG). No redacted copy exists, so the view
--   has nothing to hand out.
--
--   `derm.fn_blackout_targets()` returned 0 rows GLOBALLY. The refusing gate is the INNER JOIN at
--   its `geo` CTE:
--       JOIN derm.page_block_extents e
--         ON e.dump_folder = l.dump_folder AND e.effective_page = l.effective_page  -- HARD GATE
--   and `derm.page_block_extents` had ZERO rows for 'ticket-831938'.
--   ⇒ The gate is behaving exactly as designed and fail-closed. This is not a code defect; the
--     measurement pass simply never ran for this sheet. Every one of the 140 extents in the table
--     came from a dated MANUAL pass (ocr-fleet-2026-07-10, vision-repair-2026-07-11,
--     claude-linesnap-2026-07-28, generated-form-rules-2026-08-03...). There is no automated path.
--
-- 🛑 WHY THE EXTENT CANNOT BE DERIVED FROM THE BANDS, WHICH IS THE TEMPTING SHORTCUT.
--   The function computes
--       btop = LEAST   (e.top_pct,    min(band_y0_pct))
--       bbot = GREATEST(e.bottom_pct, max(band_y1_pct))
--   so seeding the extent FROM the bands is an algebraic no-op and blacks out only the rows that
--   happen to be stamped. PAGE 2 OF THIS VERY SHEET IS THE PROOF: it has 5 printed roster slots,
--   only 3 of them filled (061-TCE, 062-TCE, 042-MT), and its bands stop at 47.860 while the
--   printed block runs to roughly 64%. A band-derived extent would leave slots 4 and 5 outside the
--   blacked region. They are empty today so nothing leaks today, but that is luck, not a control.
--   This is the v2 leak Fred caught on 2026-07-10, and the reason the extent is a separate,
--   measured input covering ALL slots including the empty ones.
--
-- HOW THESE NUMBERS WERE OBTAINED. Both page images were downloaded and READ BY EYE, and the
--   band table was checked against what the paper actually shows before anything was written:
--     page 1 (924x732, sheet 1081-1): 5 slots, all filled.
--       25.840-33.760 091-SB · 33.760-41.100 110-CLA (GDO-12517 Claudie) · 41.100-48.145 087-BB
--       48.145-55.925 008-CV · 55.925-64.155 035-LG
--     page 2 (940x712, sheet 1081-2): 5 slots, 3 filled.
--       25.840-33.760 061-TCE · 33.760-41.100 062-TCE · 41.100-47.860 042-MT · 2 slots EMPTY
--   Slot order and occupancy match the printed sheets exactly, so the band geometry is trusted.
--   The chosen extent 25.8 / 64.4 is the same geometry as the existing
--   'generated-form-rules-2026-08-03' precedent (top_pct 25.8, bottom_pct 64.4 on page 1) and it
--   brackets every observed band on both pages. Page 2 deliberately uses the SAME bottom as page 1
--   rather than the precedent's 63.7, because 1081-1 and 1081-2 are the same generated 5-slot
--   template: the block ends in the same place whether or not the last slots are filled.
--   ⚠ Wider is fail-SAFE here: a larger [btop,bbot] blacks out MORE, and the viewing client's own
--     band is always carved back out, so it can never hide the row the customer is entitled to see.
--
-- ⚠ THIS FIXES ONE TICKET. 18 stamped folders have no extent and serve NOTHING; 39 work orders
--   across 37 clients currently have a linked manifest and a NULL derm_manifest_url, from
--   2026-07-09 to 2026-08-02. Two of them (ticket-310590, ticket-310607) were stamped on
--   2026-08-06 and reported as verified 8/8 and 4/4 - the STAMPING was verified, the customer-facing
--   result was not. Nothing alerts on this. See the follow-up note in WORKING-NOW.md.
--
-- AUDIT (ADR 010): derm.page_block_extents carries no audit trigger (measurement metadata, not
--   business data). This file is the record. Rows are keyed (dump_folder, effective_page).

BEGIN;

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES ('ticket-831938', 1, 25.8, 64.4, 'generated-form-rules-2026-08-07', now()),
       ('ticket-831938', 2, 25.8, 64.4, 'generated-form-rules-2026-08-07', now())
ON CONFLICT (dump_folder, effective_page) DO NOTHING;

DO $$
DECLARE r record; n int;
BEGIN
  -- (a) both pages present
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE dump_folder='ticket-831938';
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 extents for ticket-831938, found %', n; END IF;

  -- (b) 🛑 THE SAFETY ASSERTION. The extent must BRACKET every band on its page, or the redaction
  --     would leave part of the roster visible. This is the check that would have caught the v2 leak.
  FOR r IN
    SELECT b.effective_page, min(b.band_y0_pct) AS lo, max(b.band_y1_pct) AS hi
      FROM derm.v_stamp_row_bands b
     WHERE b.dump_folder='ticket-831938'
     GROUP BY b.effective_page
  LOOP
    SELECT * INTO STRICT r FROM (
      SELECT r.effective_page, r.lo, r.hi,
             e.top_pct, e.bottom_pct
        FROM derm.page_block_extents e
       WHERE e.dump_folder='ticket-831938' AND e.effective_page = r.effective_page
    ) x;
    IF r.top_pct > r.lo THEN
      RAISE EXCEPTION 'page %: extent top %% (%) is BELOW the first band (%) - rows above it would stay visible',
        r.effective_page, r.top_pct, r.lo;
    END IF;
    IF r.bottom_pct < r.hi THEN
      RAISE EXCEPTION 'page %: extent bottom %% (%) is ABOVE the last band (%) - rows below it would stay visible',
        r.effective_page, r.bottom_pct, r.hi;
    END IF;
  END LOOP;

  -- (c) 110-CLA's own row must still be inside the block, so it is carved back out and stays visible
  SELECT count(*) INTO n
    FROM derm.v_stamp_row_bands b
    JOIN derm.address_row_map am ON am.id = b.id
    JOIN public.clients c ON c.id = am.matched_client_id
    JOIN derm.page_block_extents e
      ON e.dump_folder = b.dump_folder AND e.effective_page = b.effective_page
   WHERE b.dump_folder='ticket-831938' AND c.client_code='110-CLA'
     AND b.band_y0_pct >= e.top_pct AND b.band_y1_pct <= e.bottom_pct;
  IF n <> 1 THEN
    RAISE EXCEPTION '110-CLA band is not inside the measured block (matched % rows) - the customer would see nothing', n;
  END IF;

  -- (d) the gate now opens: blackout targets must appear for this ticket
  SELECT count(*) INTO n FROM derm.fn_blackout_targets(50) WHERE ticket_key = '831938';
  IF n = 0 THEN
    RAISE EXCEPTION 'fn_blackout_targets still returns nothing for 831938 - another gate is refusing';
  END IF;

  -- (e) CONTROL: prove (d) is not vacuously true. A folder that still has no extent must still
  --     return nothing, or the function is not gating on extents at all and (d) proved nothing.
  SELECT count(*) INTO n FROM derm.fn_blackout_targets(50) WHERE ticket_key = '310590';
  IF n <> 0 THEN
    RAISE EXCEPTION 'CONTROL FAILED: 310590 has no extent yet still yielded a target - the gate is not what I think it is';
  END IF;

  RAISE NOTICE 'OK: extents added for both pages, all bands bracketed, 110-CLA preserved, % target(s) queued',
    (SELECT count(*) FROM derm.fn_blackout_targets(50) WHERE ticket_key='831938');
END $$;

COMMIT;
