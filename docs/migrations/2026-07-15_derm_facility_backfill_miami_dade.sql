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
