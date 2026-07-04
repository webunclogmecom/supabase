-- 2026-07-04_derm_stamp_derived_bands.sql
-- DERM Stamp Studio: auto-derive each row's redaction BAND from the placed points,
-- passively (no extra manual step during stamping). Live-computed view — always
-- current, no trigger, no stored staleness. band_y0/y1_pct columns remain for
-- MANUAL overrides, which are coalesced on top. Additive read view only.
--
-- Band math: bands are the CONTIGUOUS midpoints between consecutive rows' stamp_y
-- points (sorted top->bottom within a page), so row i's bottom == row i+1's top
-- (no gaps, no overlaps). The first row's top / last row's bottom extrapolate by
-- half the adjacent gap (or a 6% default when a page has a single placed row).
--
-- IMPORTANT (privacy): a DERIVED band is a provisional seed. It must NOT drive
-- customer-facing raw-sheet redaction on a multi-client sheet without human
-- confirmation (uneven row heights can clip/miss). band_is_manual = false flags
-- that; the FP redaction (Wave 3) gates on a human-confirmed (manual) band.

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_row_bands AS
WITH pts AS (
  SELECT r.id, r.dump_folder, r.page, r.row_index, r.stamp_y_pct,
         r.band_y0_pct AS manual_y0, r.band_y1_pct AS manual_y1,
         LAG(r.stamp_y_pct)  OVER w AS prev_y,
         LEAD(r.stamp_y_pct) OVER w AS next_y
  FROM derm.address_row_map r
  WHERE r.stamp_y_pct IS NOT NULL
  WINDOW w AS (PARTITION BY r.dump_folder, r.page ORDER BY r.stamp_y_pct)
),
der AS (
  SELECT id, dump_folder, page, row_index, stamp_y_pct, manual_y0, manual_y1,
         round(GREATEST(0,
           CASE WHEN prev_y IS NULL
                THEN stamp_y_pct - COALESCE((next_y - stamp_y_pct) / 2, 6)
                ELSE (prev_y + stamp_y_pct) / 2 END)::numeric, 3) AS derived_y0,
         round(LEAST(100,
           CASE WHEN next_y IS NULL
                THEN stamp_y_pct + COALESCE((stamp_y_pct - prev_y) / 2, 6)
                ELSE (stamp_y_pct + next_y) / 2 END)::numeric, 3) AS derived_y1
  FROM pts
)
SELECT id, dump_folder, page, row_index, stamp_y_pct,
       derived_y0                         AS derived_band_y0_pct,
       derived_y1                         AS derived_band_y1_pct,
       COALESCE(manual_y0, derived_y0)    AS band_y0_pct,   -- effective (manual wins)
       COALESCE(manual_y1, derived_y1)    AS band_y1_pct,
       (manual_y0 IS NOT NULL OR manual_y1 IS NOT NULL) AS band_is_manual
FROM der;

GRANT SELECT ON derm.v_stamp_row_bands TO anon, authenticated;

COMMIT;
