-- 2026-07-15  DERM disposal-facility backfill: Miami-Dade manifests -> South District WWTP
--
-- Context (Fred + Yan, 2026-07-14/15): the DERM Tracker /upload County dropdown defaulted to
-- "Miami-Dade" but the facility auto-match only fired on a County *change*, so the default never
-- populated the disposal facility and many manifests were filed with disposal_facility_id NULL
-- (74% of all live rows; Yan flagged 009-CN / 824273). Fred asked for a backfill of the
-- provably-Miami-Dade ones. (The app-side root cause is fixed separately: County is now a required
-- field with no default, so picking it fires the facility auto-match. See DERM Tracker changelog
-- 2026-07-15.)
--
-- JURISDICTION FACT (why this is safe, not a guess):
--   A "white manifest number" IS a Miami-Dade DERM FOG eManifest. In the existing data the mapping
--   is unambiguous by number series:
--     * every row already set to SDWWTP (id 2, Miami-Dade) has an 8xxxxx white number  (103/103)
--     * every row already set to Water & Wastewater Services (id 3, Broward) has a 3xxxxx number (14/14)
--   Zero counter-examples. So an 8xxxxx white-only manifest is provably Miami-Dade -> SDWWTP (id 2),
--   which is exactly the facility the app itself auto-matches for Miami-Dade.
--
-- SCOPE:
--   IN  (backfilled): 294 rows / 67 tickets = white_manifest_number ~ '^8[0-9]{5}$' AND no yellow ticket.
--   OUT (left NULL, NOT Miami-Dade):
--     * 65 rows with a yellow_ticket_number (Broward -> would be id 3, a separate decision).
--     * 28 rows / 6 tickets on a 0xxxxx / 4xxxxx series (000068, 000195, 000388, 444849, 444980,
--       445331) with no proven facility mapping; ticket 444849 is a mixed Broward+Dade load.
--       These need a human to confirm the dump site before assignment.
--
-- SAFETY:
--   * Fills NULLs only; the WHERE clause never matches an already-set row, so it never overwrites
--     an explicit facility and is idempotent (Rule 5).
--   * derm_manifests is audited -> 294 audit.logs rows written (app_source='sql').
--   * Backup of the affected ids/old-values: backups/2026-07-15_derm_facility_backfill_miami_dade_before.json
--   * Rollback: UPDATE public.derm_manifests SET disposal_facility_id = NULL WHERE id = ANY(<ids in backup>);

UPDATE public.derm_manifests
SET    disposal_facility_id = 2            -- South District WWTP (Miami-Dade)
WHERE  deleted_at IS NULL
  AND  disposal_facility_id IS NULL
  AND  white_manifest_number ~ '^8[0-9]{5}$'
  AND  (yellow_ticket_number IS NULL OR yellow_ticket_number = '');
-- Applied to Prod 2026-07-15 via Management API: 294 rows. Verify: SDWWTP count 110 -> 404,
-- and zero remaining NULL-facility rows match the predicate above.


-- ============================================================================
-- ADDENDUM 2026-07-15 - receipt-confirmed classification audit + 1 correction
-- ============================================================================
-- Fred supplied two physical disposal receipts, which CONFIRM the number-series rule above:
--   * BROWARD  = "Broward County Water and Wastewater Services, Septage Receiving Facility,
--                 Pompano Beach" (DB facility id 3).  Example ticket 308792 -> 3xxxxx.
--                 (Its "Service Area: Dade County" + "Mix Load" prove a load can be COLLECTED
--                  in Dade but DUMPED at Broward, so client county does NOT decide the facility.)
--   * MIAMI-DADE = "South District Wastewater Treatment Plant, Miami-Dade Water & Sewer"
--                 (DB facility id 2).  Example receipt 829788 -> 8xxxxx.
--
-- Audit (series-vs-facility cross-tab over all live rows):
--   * All 294 backfilled rows (and all 397 SDWWTP rows) are 8xxxxx  -> Miami-Dade CONFIRMED, no undo.
--   * The 2xxxxx numbers (294999 Jan-02, 296524 Jan-23, 296623 Jan-26, 298064 Feb-13) are the
--     EARLIER part of the same sequential Broward receipt book that later reads 305031/306859/
--     308684/308792 -> so 2xxxxx = Broward too (definitely not Dade's 8xxxxx). Still NULL-facility;
--     left for a Broward (id 3) backfill decision along with the 39 both-3xxxxx NULL rows.
--   * 0xxxxx (000068/000195/000388) + 4xxxxx (444849/444980/445331) match neither facility's
--     format/sequence -> genuinely unclassifiable by number; need the physical receipt.
--
-- ONE mis-assignment found + corrected: ticket 308684 (7 rows) is a Broward 3xxxxx receipt with
-- Broward/Palm-Beach clients but was assigned SDWWTP (id 2). Corrected to Broward (id 3).
-- (Pre-existing, NOT from the backfill above.) Backup:
-- backups/2026-07-15_derm_308684_broward_reassign_before.json
UPDATE public.derm_manifests
SET    disposal_facility_id = 3            -- Water and Wastewater Services (Broward)
WHERE  deleted_at IS NULL
  AND  disposal_facility_id = 2
  AND  yellow_ticket_number = '308684'
  AND  (white_manifest_number IS NULL OR white_manifest_number = '');
-- Applied 2026-07-15: 7 rows. Post-fix: 0 series-vs-facility contradictions (SDWWTP all 8xxxxx,
-- Broward all 3xxxxx/2xxxxx); SDWWTP 397, Broward 36.


-- ============================================================================
-- ADDENDUM 2 (2026-07-15) - Broward NULL-facility backfill (Fred-approved: 39+26)
-- ============================================================================
-- After the jurisdiction audit above, the remaining NULL-facility Broward rows were filled to
-- Water and Wastewater Services (id 3):
--   * 39 rows = 3xxxxx (both fields)  -> Broward, confirmed by receipt series (ticket 308792 image).
--   * 26 rows = 2xxxxx                 -> Broward, same sequential receipt book (294999..298064).
-- Left NULL (unclassifiable by number, need the physical receipt): 28 rows / 6 tickets =
--   000068, 000195, 000388 (0xxxxx) + 444849, 444980, 445331 (4xxxxx).
-- Idempotent (fills NULLs only). Backup: backups/2026-07-15_derm_facility_backfill_broward_before.json
UPDATE public.derm_manifests
SET    disposal_facility_id = 3            -- Water and Wastewater Services (Broward)
WHERE  deleted_at IS NULL
  AND  disposal_facility_id IS NULL
  AND  (white_manifest_number ~ '^[23][0-9]{5}$' OR yellow_ticket_number ~ '^[23][0-9]{5}$');
-- Applied 2026-07-15: 65 rows. Final: SDWWTP 397, Broward 101, still-NULL 28 (the 0xxxxx/4xxxxx set),
-- 0 series-vs-facility contradictions on either facility.


-- ============================================================================
-- ADDENDUM 3 (2026-07-15) - the last 28 (0xxxxx/4xxxxx) resolved by READING the receipt images
-- ============================================================================
-- Read the on-file manifest scans (derm_manifest_url) for all 6 remaining tickets. ALL are
-- Miami-Dade South District WWTP receipts:
--   * 000068 / 000195 / 000388 = the "Miami-Dade County - South District WWTP - Black Point" form
--     (a low handwritten number went into our DB; the pre-printed ticket is a 4xxxxx, e.g. 445504).
--   * 444849 / 444980 / 445331 = the red-stamped "South District WWTP / Miami-Dade Water & Sewer"
--     form (same as the 8xxxxx book, just the earlier 4xxxxx receipt series).
-- => Miami-Dade SDWWTP has THREE historical receipt formats: 4xxxxx (early 2026), 8xxxxx (mid 2026),
--    and the Black-Point form. Broward stays 2xxxxx->3xxxxx. Backup:
-- backups/2026-07-15_derm_facility_backfill_md_receiptconfirmed_before.json
UPDATE public.derm_manifests
SET    disposal_facility_id = 2            -- South District WWTP (Miami-Dade)
WHERE  deleted_at IS NULL
  AND  disposal_facility_id IS NULL
  AND  (white_manifest_number ~ '^[04][0-9]{5}$' OR yellow_ticket_number ~ '^[04][0-9]{5}$');
-- Applied 2026-07-15: 28 rows. FINAL STATE: every live derm_manifests row now has a facility ->
-- SDWWTP 425, Broward 101, NULL 0, total 526.
