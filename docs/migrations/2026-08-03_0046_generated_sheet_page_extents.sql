-- 2026-08-03_0046  FP blackout: give GENERATED DERM address sheets a page extent
--
-- Fred: "why 041-MB, July 28, eFoG is pending? it's documented and it's one of the Generated
-- Address Manifest (+1000)" and "Specially if they have a GDO Online Report, they must have a
-- FoG eManifest."
--
-- -- THE BUG -------------------------------------------------------------------
-- The Field Portal's "DERM FOG eManifest" card renders customer.work_orders.derm_manifest_url,
-- which is derm.redacted_manifest_docs.url. No redacted doc existed for ANY manifest on a
-- generated sheet, so the card was a permanent placeholder. Root cause: derm.fn_blackout_targets
-- REQUIRES a derm.page_block_extents row, every one of the 137 existing rows came from a vision /
-- OCR pass, and generated sheets have never been through one. Measured before this migration:
--     extents for ticket-310429 / ticket-831325 .... 0
--     derm.fn_blackout_targets(50) ................. 0 rows  (nothing even queued)
--     live manifests on generated sheets ........... 9      (0 with a redacted doc)
-- Fred's invariant caught it: 111-YC's GDO-filed visit is on a SCANNED sheet and has its FOG;
-- 041-MB's is on generated sheet 1072 and does not.
--
-- -- 🛑 WHY 22.0 / 67.5, AND WHY WIDE IS THE SAFE DIRECTION ---------------------
-- Audited before writing this, then each finding independently re-verified:
-- redact-manifest-sheet paints TWO OPAQUE boxes, [blocks_top -> band_y0] and
-- [band_y1 -> blocks_bottom], via setUint32/copyWithin. That is a direct overwrite: never an
-- alpha blend, never an erase. blocks_top/blocks_bottom never feed the band values.
--   => WIDENING ONLY EVER ADDS BLACK. Confidentiality cost of over-width is ZERO; the only cost
--      is utility (hiding form furniture). It can never eat the client's own band.
--   => NARROWING IS THE LEAK. No box is ever drawn outside the extent, so a roster row above
--      blocks_top or below blocks_bottom is served to the customer AS-IS.
-- So the extent is deliberately generous. 22.0/67.5 sits INSIDE the measured envelope of real
-- sheets (top 20.4..31.9, bottom 57.3..68.2) at the conservative end of BOTH bounds, covers all
-- five printed slots, and stops short of section E/F so the certification block stays readable.
--
-- ⚠ THE EXTENT MUST COME FROM THE PRINTED FORM, NOT FROM THE CARDS. derm.v_stamp_row_bands is
-- built `WHERE r.stamp_y_pct IS NOT NULL`, so ONLY STAMPED rows contribute to the LEAST/GREATEST
-- safety floor in fn_blackout_targets. A row that is printed but unstamped is invisible to it —
-- which is exactly the leak class. Verified on sheet 1072 page 2: five printed slots, only two
-- stamped. A band-derived extent would have stopped at 41.85% and served everything below it.
--
-- ⚠ AND THIS IS THE SAME FOLDER CLASS AS THE ONE THAT LEAKED. The 2026-07-10 incident
-- (docs/migrations/2026-07-10_fp_blackout_v2_1_extents.sql: "LEAK FIX (Fred caught it live on
-- m1309/152-DAV: co-clients Fresko + JZ Steak House visible below Davinci's row)", 238/377
-- derivatives under-covered and pulled) was on `ticket-829216` — a ticket-* folder, and that
-- migration records the cause as "ticket-* folders only have cards for LINKED clients (no full
-- OCR roster)". ticket-310429 and ticket-831325 are that same class. Do not narrow these values.
--
-- ⚠ I ALSO CHECKED THE IMAGES RATHER THAN TRUSTING THE ARITHMETIC. My first plan was to derive
-- exact coordinates from derm.fn_generated_row_geometry, on the theory that we printed these
-- sheets so their geometry is known. Opening them killed that: they carry a CamScanner watermark
-- and visible skew, i.e. they are printed, hand-completed and SCANNED BACK, with the same
-- variability as any other sheet. Idealised coordinates could have landed off the real rows.
--
-- PROBED rolled back before applying:
--   3 extent rows (ticket-310429 p1+p2, ticket-831325 p1)
--   derm.fn_blackout_targets(50): 0 -> 9 targets, every one blocks 22.0..67.5,
--   band_inside_extent = true for all 9 (059-SK, 293-ALC, 224-MP, 072-TCE, 041-MB, 044-MP, ...)
--   the 137 vision-measured rows untouched
--
-- ON CONFLICT DO NOTHING is load-bearing: it guarantees this can never overwrite a real
-- measurement. If a vision pass later measures these pages, delete the synthetic rows first.
--
-- ADR 010 rule 8: derm.page_block_extents is a measurement/derivation table, not human-editable
-- business data, and carries no audit trigger — unchanged by this migration (no opt-in required).
--
-- ⚠ SEPARATE AND STILL OPEN, RAISED WITH FRED 2026-08-03: the `manifests` bucket is public=true
-- and the RAW multi-client sheets are fetchable unauthenticated at an enumerable path
-- (manifests/derm/<manifest_id>/address_1.jpeg; 2 real hits in 8 sequential guesses; 61 raw
-- sheets, 170 clients on shared sheets). This migration makes the REDACTED copy exist; it does
-- NOT close that bypass.

BEGIN;

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
SELECT DISTINCT r.dump_folder, r.stamp_page, 22.0, 67.5,
       'generated-form-geometry-2026-08-02', now()
  FROM derm.address_row_map r
  JOIN public.derm_manifests m ON m.id = r.matched_manifest_id AND m.deleted_at IS NULL
  JOIN derm.address_sheets s   ON s.sheet_no = m.derm_address_no
 WHERE EXISTS (SELECT 1 FROM derm.address_sheet_clients c WHERE c.sheet_id = s.id)  -- generated only
   AND r.stamp_page IS NOT NULL
ON CONFLICT (dump_folder, effective_page) DO NOTHING;

COMMIT;
