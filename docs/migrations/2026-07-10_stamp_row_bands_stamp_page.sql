-- 2026-07-10_stamp_row_bands_stamp_page.sql   ⚠ APPLY BEFORE 2026-07-10_fp_blackout_redaction.sql
-- FP Blackout prerequisite — fixes Stamp Studio known-issue #3 + hardens band geometry for the first
-- real band consumer (the redaction pipeline). Two changes to derm.v_stamp_row_bands (0 consumers
-- verified live; grants preserved by CREATE OR REPLACE; existing columns unchanged, one appended):
--
-- 1. NEIGHBOR WINDOW keyed to the page the stamp was PLACED on: PARTITION BY (dump_folder,
--    COALESCE(stamp_page, page)) — was (dump_folder, page) = the OCR page, wrong for the 50 placed
--    cards whose stamp sits on a different page image (e.g. backfilled cards carry page=1, stamps on
--    the 2nd address sheet). All 511 placed cards have stamp_page today; COALESCE covers legacy NULLs.
-- 2. CLAMPED half-extents (adversarial-review blocker fix, wf_511c398b): raw midpoint extents let a
--    band swallow neighboring rows (single-stamp pages got ±6% = ~2 rows; edge stamps mirrored the
--    inner gap unbounded). Each half-extent is now capped at 0.75 × the partition's MEDIAN stamp gap
--    (≈ 1.5 × the median half-gap; fallback 6 when a page has < 2 stamps). Keeps midpoints where
--    spacing is regular, stops pathological overshoot where it isn't.
-- + APPENDED column effective_page = COALESCE(stamp_page, page): the 1-based index into
--   derm.ticket_page_images(ticket_key) that the band belongs to (consumers need to know WHICH image).
-- ADR-010: view-only, no audit implication.

CREATE OR REPLACE VIEW derm.v_stamp_row_bands AS
 WITH pts AS (
         SELECT r.id,
            r.dump_folder,
            r.page,
            r.row_index,
            r.stamp_y_pct,
            r.band_y0_pct AS manual_y0,
            r.band_y1_pct AS manual_y1,
            COALESCE(r.stamp_page, r.page) AS eff_page,
            lag(r.stamp_y_pct) OVER w AS prev_y,
            lead(r.stamp_y_pct) OVER w AS next_y
           FROM derm.address_row_map r
          WHERE r.stamp_y_pct IS NOT NULL
          WINDOW w AS (PARTITION BY r.dump_folder, COALESCE(r.stamp_page, r.page) ORDER BY r.stamp_y_pct)
        ), gaps AS (      -- per-partition median stamp gap -> half-extent cap
         SELECT dump_folder, eff_page,
                (percentile_cont(0.5) WITHIN GROUP (ORDER BY (stamp_y_pct - prev_y)))::numeric AS med_gap
           FROM pts WHERE prev_y IS NOT NULL
          GROUP BY dump_folder, eff_page
        ), der AS (
         SELECT p.id, p.dump_folder, p.page, p.row_index, p.stamp_y_pct,
            p.manual_y0, p.manual_y1, p.eff_page,
            round(GREATEST(0::numeric, p.stamp_y_pct - LEAST(
                CASE WHEN p.prev_y IS NULL
                     THEN COALESCE((p.next_y - p.stamp_y_pct) / 2::numeric, 6::numeric)
                     ELSE (p.stamp_y_pct - p.prev_y) / 2::numeric END,
                COALESCE(0.75 * g.med_gap, 6::numeric))), 3) AS derived_y0,
            round(LEAST(100::numeric, p.stamp_y_pct + LEAST(
                CASE WHEN p.next_y IS NULL
                     THEN COALESCE((p.stamp_y_pct - p.prev_y) / 2::numeric, 6::numeric)
                     ELSE (p.next_y - p.stamp_y_pct) / 2::numeric END,
                COALESCE(0.75 * g.med_gap, 6::numeric))), 3) AS derived_y1
           FROM pts p
           LEFT JOIN gaps g ON g.dump_folder = p.dump_folder AND g.eff_page = p.eff_page
        )
 SELECT id,
    dump_folder,
    page,
    row_index,
    stamp_y_pct,
    derived_y0 AS derived_band_y0_pct,
    derived_y1 AS derived_band_y1_pct,
    COALESCE(manual_y0, derived_y0) AS band_y0_pct,
    COALESCE(manual_y1, derived_y1) AS band_y1_pct,
    manual_y0 IS NOT NULL OR manual_y1 IS NOT NULL AS band_is_manual,
    eff_page AS effective_page
   FROM der;
