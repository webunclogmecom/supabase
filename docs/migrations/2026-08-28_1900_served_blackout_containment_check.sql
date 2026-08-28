-- 2026-08-28_1900_served_blackout_containment_check.sql
--
-- 🛑 THIS MIGRATION EXISTS TO RETRACT A FINDING I REPORTED, AND TO ADD THE CHECK THAT WOULD HAVE
-- STOPPED ME MAKING IT.
-- ---------------------------------------------------------------------------
-- On 2026-08-28 I told Fred that 55 of the 166 pages carrying a page extent "violate containment
-- today and every one of them is SERVING", with 39 short by 2px or more, 19 by 10px or more and a
-- worst case of 43.4px on ticket-308792 p1. That claim is in the header of
-- `2026-08-28_1720_g8_semantic_message_and_subpixel_tolerance.sql` and in the DERM Stamp Studio
-- changelog.
--
-- **IT IS WRONG. THE REAL NUMBER IS ZERO.**
--
-- WHAT I DID: compared `page_block_extents.top_pct` against `min(v_stamp_row_bands.band_y0_pct)`
-- and concluded the black box starts below the topmost client's row, leaving a strip of that row
-- visible on everyone else's document.
--
-- WHAT I FAILED TO CHECK: `derm.fn_blackout_targets` does not hand the raw extent to the redactor.
-- It clamps, so the value the redactor receives as `blocks_top` already covers every band on the
-- page. Measured over all 654 served documents: `redacted_manifest_docs.header_y` equals
-- `min(band_y0_pct)` on every page where the stored extent is tighter than the bands. NOT ONE
-- served document was rendered from the raw stored extent.
--
-- PROVEN BY OUTCOME, NOT BY READING THE SQL. The 44 pages with an identifiable victim document had
-- their supposedly-exposed strip measured on the SERVED JPEG in a canvas: **blackFrac = 1.000 on
-- all 44**, i.e. the region is entirely black. There was nothing to see.
--
-- THE ONE RESIDUAL, AND IT IS NOT A LEAK: `derm/1246` p1, client 092-TCE, is the single served
-- document out of 654 whose `header_y` sits below the topmost band, by **0.074pp = 0.5 of a pixel**
-- on a 724px-tall document. Rendered at 6x with both positions marked, the two lines are
-- indistinguishable and the strip is the printed rule itself, not text. `maxRunFrac` 0.616 is the
-- signature of a horizontal printed rule; CLAUDE.md already records that ink alone cannot separate
-- a rule from a dense line of text, which is why it was looked at rather than computed.
--
-- 🛑 THE LESSON, AND IT IS ONE THIS REPO ALREADY WROTE DOWN. Every number I measured was correct.
-- The sentence I wrapped around them was not. CLAUDE.md: "the number is almost never the weak link;
-- the claim built on it is ... Instrument the inference." I measured STORED state and asserted
-- something about RENDERED output without checking the transform in between. The correct instrument
-- is the served document, and that is what this view now measures.
--
-- ⚠ WHAT DOES NOT CHANGE: `2026-08-28_1720` is still correct and stays. Its G8 message fix and its
-- 0.05pp sub-pixel tolerance are about the EDITOR guard, which compares the operator's submitted
-- extent against their submitted bands before anything is rendered. That guard is independent of
-- the render-time clamp and is still worth having. Only the "55 real cases" paragraph in its header
-- is retracted, by this file.
--
-- RULE 8 (audit trail): a view holds no state. Opt-out.

BEGIN;

-- ---------------------------------------------------------------------------
-- The check that measures what a CLIENT ACTUALLY RECEIVES.
-- Empty means healthy. A row means a served document's black box does not cover a row it should.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_served_blackout_short AS
WITH page_bands AS (
  SELECT r.dump_folder,
         COALESCE(r.stamp_page, r.page)  AS effective_page,
         r.matched_manifest_id,
         r.matched_client_id,
         MIN(vb.band_y0_pct) OVER (PARTITION BY r.dump_folder, COALESCE(r.stamp_page, r.page)) AS page_min_band,
         MAX(vb.band_y1_pct) OVER (PARTITION BY r.dump_folder, COALESCE(r.stamp_page, r.page)) AS page_max_band
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
)
SELECT DISTINCT
       pb.dump_folder,
       pb.effective_page,
       c.client_code,
       d.url,
       round(d.header_y, 3)                    AS served_box_top,
       round(pb.page_min_band, 3)              AS topmost_band,
       round(d.header_y - pb.page_min_band, 3) AS short_top_pp,
       round(d.blocks_bottom, 3)               AS served_box_bottom,
       round(pb.page_max_band, 3)              AS lowest_band,
       round(pb.page_max_band - d.blocks_bottom, 3) AS short_bottom_pp,
       d.generated_at
  FROM page_bands pb
  JOIN derm.redacted_manifest_docs d
    ON d.manifest_id = pb.matched_manifest_id
   AND d.client_id   = pb.matched_client_id
   AND d.effective_page = pb.effective_page
  LEFT JOIN public.clients c ON c.id = pb.matched_client_id
  -- 🛑 THE TOLERANCE IS ONE PIXEL, DERIVED PER PAGE, NOT A GUESSED CONSTANT. The redactor renders
  -- with round(H * pct / 100), so a difference smaller than a pixel cannot change a byte of the
  -- output. Scan heights across the fleet run 485 to 2492px, so one pixel is 0.206pp at the small
  -- end and 0.040pp at the large end: a single constant would be wrong at one end or the other.
  -- Live case: derm/1246 p1 is 724px tall, one pixel is 0.138pp, and its 0.074pp discrepancy is
  -- half a pixel. Looked at on the served document at 6x, the two positions are indistinguishable
  -- and the strip is the printed rule itself.
  CROSS JOIN LATERAL (
    SELECT COALESCE(100.0 / NULLIF(MAX(s.image_h), 0), 0.05) AS pp
      FROM derm.page_rule_scans s
     WHERE s.dump_folder = pb.dump_folder AND s.effective_page = pb.effective_page
  ) tol
 WHERE d.header_y      > pb.page_min_band + tol.pp
    OR d.blocks_bottom < pb.page_max_band - tol.pp;

COMMENT ON VIEW derm.v_served_blackout_short IS
'Rows where a PUBLISHED redacted document''s black box does not cover a band on its page, i.e. a '
'strip of another client''s row is left visible. EMPTY MEANS HEALTHY. '
'🛑 Read this, NEVER page_block_extents against v_stamp_row_bands: fn_blackout_targets clamps '
'blocks_top to cover every band, so 55 pages look like violations in the stored tables while all '
'654 served documents are correct. That mistake was made and retracted on 2026-08-28. '
'The 0.05pp tolerance is one pixel on a typical scan; the redactor rounds to integer pixels.';

GRANT SELECT ON derm.v_served_blackout_short TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_docs integer; v_stored integer;
BEGIN
  -- 1. THE RETRACTION, ASSERTED. The served estate is clean.
  SELECT count(*) INTO v_n FROM derm.v_served_blackout_short;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % served document(s) really are short: %', v_n,
      (SELECT string_agg(dump_folder||' p'||effective_page||' '||client_code||' '||short_top_pp, ', ')
         FROM derm.v_served_blackout_short);
  END IF;

  -- 2. 🛑 THE CONTROL. The view must actually SEE the served population, or "empty" proves nothing.
  SELECT count(*) INTO v_docs FROM derm.redacted_manifest_docs;
  IF v_docs < 500 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: only % served documents visible; the join is broken', v_docs;
  END IF;

  -- 3. 🛑 THE CONTROL THAT MAKES 1 MEANINGFUL. The stored tables STILL show the discrepancy, so the
  --    clean result above is the render-time clamp working, not the query failing to look.
  SELECT count(*) INTO v_stored FROM (
    SELECT e.dump_folder, e.effective_page
      FROM derm.page_block_extents e
      JOIN derm.address_row_map r ON r.dump_folder = e.dump_folder
                                 AND COALESCE(r.stamp_page, r.page) = e.effective_page
      JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
     GROUP BY 1,2, e.top_pct, e.bottom_pct
    HAVING e.top_pct > MIN(vb.band_y0_pct) OR e.bottom_pct < MAX(vb.band_y1_pct)) t;
  IF v_stored < 20 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: expected the stored-table discrepancy to persist (~55), got %',
      v_stored;
  END IF;

  -- 4. 🛑 DOES IT STILL BITE? With a ZERO tolerance the same join must produce rows, proving the
  --    clean result above is the one-pixel tolerance excluding sub-pixel noise and NOT a broken
  --    join quietly returning nothing.
  SELECT count(*) INTO v_n FROM (
    SELECT 1
      FROM derm.address_row_map r
      JOIN derm.v_stamp_row_bands vb ON vb.id = r.id
      JOIN derm.redacted_manifest_docs d ON d.manifest_id = r.matched_manifest_id
                                        AND d.client_id = r.matched_client_id
                                        AND d.effective_page = COALESCE(r.stamp_page, r.page)
     GROUP BY r.dump_folder, COALESCE(r.stamp_page, r.page), d.header_y
    HAVING d.header_y > MIN(vb.band_y0_pct)) t;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: at zero tolerance the check finds nothing, so its clean '
      'result proves only that the join is broken';
  END IF;

  RAISE NOTICE 'VERIFY ok: % served documents, 0 short at a one-pixel tolerance. The stored '
    'tables still show % pages where the extent is tighter than the bands, and that gap between '
    'stored and served is exactly what the retracted finding mistook for a leak.',
    v_docs, v_stored;
END $do$;

COMMIT;
