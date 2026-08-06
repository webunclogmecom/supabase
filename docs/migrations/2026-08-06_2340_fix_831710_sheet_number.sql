-- 2026-08-06_2340 — ticket 831710's compliance record names the WRONG sheet. It is 1008.
--
-- Fred: "fix the 831710 sheet number its 1008."
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT IS WRONG
-- ─────────────────────────────────────────────────────────────────────────────
-- `public.derm_manifests(1679).derm_address_no = 1079`, and the manifest is linked to
-- `derm.address_sheets` id 67 (sheet_no 1079). Both are wrong.
--
-- VERIFIED BY EYE on the scan (manifests/derm/1679/address_1.JPG), not from a flag:
--   * "1008" is printed top-right. Ticket No 831710 is handwritten in section F.
--   * Section B prints THREE facilities:
--       row 1  GDO-12345  053-PV Pura Vida Edgewater, 1756 North Bayshore Drive
--       row 2  GDO-08422  214-MYK Myka Brickell FT LLC, 777 Brickell Avenue      <- our client
--       row 3  (no GDO)   057-SLS Bayshore Executive Plaza, 10800 Biscayne Boulevard
--   * So 214-MYK is row 2 of a shared 3-facility sheet, NOT the sole facility of a 1-row sheet.
--
-- HOW IT HAPPENED (measured): sheet 1079 was recorded 2026-08-03 22:39:03 with a roster of exactly
-- [214-MYK], and 28 seconds later the link and the stamp were written. The dump was 2026-08-02, so
-- the sheet did not exist when the driver did the work. The auto-place then put the stamp at
-- y = 29.800 (row 1, correct for a 1-row sheet, wrong for this paper); a human corrected it by hand
-- on 2026-08-04 to y = 37.830, which is row 2 and IS correct. The stamp is therefore already right
-- and this migration does not touch it.
--
-- ⚠ BOTH OF TODAY'S GUARDS REFUSE THIS PAIRING, AND NEITHER IS RETROACTIVE. The causality guard
-- (2026-08-04) and the sheet-number gate (2026-08-05) both post-date the link. `fn_resolve_...`
-- returns the EXISTING link before either guard is reached, so the row stayed wrong while every
-- check reported healthy: placed_rows = total_rows, completed, is_generated, filled_by_ai, and
-- `manifest_health` = fully_complete. Fixing the data is the only way to clear it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY THE LINK IS DELETED RATHER THAN REPOINTED
-- ─────────────────────────────────────────────────────────────────────────────
-- There is nothing to repoint it to: sheet 1008 has NO `address_sheets` row and cannot have one,
-- because that table begins at sheet_no 1064 (recording started 2026-07-28 20:23, migration
-- `2026-07-28o`). 1008 predates it. `derm_address_no` is a plain integer on `derm_manifests` with no
-- FK to `address_sheets`, so it can carry the true number without a sheet row (831220 and others sit
-- with NULL today), and that is exactly the honest state: we know which sheet the driver carried, we
-- have no record of having generated it.
--
-- 🛑 DELIBERATELY NOT DONE: back-recording an `address_sheets` row for 1008. It would require
-- backdating `created_at` past the causality guard, i.e. writing a false timestamp to make a check
-- pass. The right shape is a `printed_at` column, which is a separate change. Do not "finish the job"
-- by inventing that row.
--
-- ⚠ Rule 6 (never hard-delete business data) is respected: this deletes a FALSE ASSERTION, not a
-- business record. `derm.address_sheet_manifests` carries `audit_address_sheet_manifests`
-- (audit.log_change), so the removed row is recoverable from `audit.logs.old_row`. Verified present
-- before writing this.
--
-- ⚠ FREEING SHEET 1079 IS CORRECT, NOT COLLATERAL. Measured: 831710 is the ONLY link to it, and
-- 214-MYK has NO dump after 2026-08-03 (last is 831710 itself, 2026-08-02). So 1079 is a generated
-- sheet that was never carried on any filed paper. Unlinking returns it to the unclaimed pool where a
-- future 214-MYK ticket can legitimately claim it. Both guards prevent it being re-grabbed wrongly:
-- causality (created 2026-08-03 > every candidate's service date) and the sheet-number gate
-- (831710 reads 1008, 831220 reads 1063).
--
-- 3NF: no schema change. Audit: both tables touched are audited, so the correction is itself captured.

begin;

-- 1. The compliance record now names the sheet the driver actually carried.
update public.derm_manifests
   set derm_address_no = 1008
 where id = 1679
   and coalesce(white_manifest_number, yellow_ticket_number) = '831710'
   and derm_address_no is distinct from 1008;

-- 2. Remove the false link to sheet 1079.
delete from derm.address_sheet_manifests
 where manifest_id = 1679
   and sheet_id = (select id from derm.address_sheets where sheet_no = 1079);

commit;

-- VERIFY:
--   * derm_manifests(1679).derm_address_no = 1008
--   * zero rows in address_sheet_manifests for manifest 1679
--   * sheet 1079 has 0 links and still exists (not deleted)
--   * the stamp is UNCHANGED: page 1, y = 37.830 (row 2), placed_at 2026-08-03, and the folder stays
--     completed = true
--   * fn_resolve_generated_sheet_for_ticket('831710') returns NULL (it must NOT re-link to 1079)
--   * fn_resolve_generated_sheet_for_ticket('831220') still returns NULL (must not grab 1079 either)
--   * audit.logs holds the DELETE with the old row
