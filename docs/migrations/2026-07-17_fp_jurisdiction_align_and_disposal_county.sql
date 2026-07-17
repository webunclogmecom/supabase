-- 2026-07-17 · FP jurisdiction rule aligned to the DERM app + disposal_county exposed
--                + ticket 306859 corrected to Broward
-- ---------------------------------------------------------------------------
-- WHY. Fred could not find "the Miami-Dade-county-with-Broward-receipt" tickets in the DERM app.
-- He was right: they do not exist as Miami-Dade there. The two views derived jurisdiction with
-- OPPOSITE precedence, and the Field Portal's was wrong:
--
--   derm.manifests        (DERM app):  yellow wins  -> 'broward'   ✔ correct
--   customer.work_orders  (FP):        white  wins  -> 'dade'      ✘ wrong
--
-- 64 live manifest rows carry the SAME number in BOTH columns (a data-entry artifact of the
-- Broward flow). For those, the DERM app said broward and the FP said dade. 6 tickets / 60 FP
-- work orders were affected: 296524, 298064, 300373, 302279, 303478, 305031.
--
-- NOTE: an earlier analysis of mine reported "73 work orders mis-tagged Miami-Dade". That was
-- wrong - it was built off the FP's broken rule without cross-checking the DERM app. Only ONE
-- manifest was genuinely mis-filed (306859, below); the rest was this view disagreement.

-- 1. Ticket 306859 -> Broward. It is a Broward EPD receipt (dumped at Water and Wastewater
--    Services, facility 3) but only the WHITE column was filled, so BOTH views said 'dade'.
--    We ADD the yellow number and KEEP white, matching exactly how the other 6 Broward tickets
--    are stored (white = yellow = the number). White is NOT nulled on purpose:
--    derm.v_stamp_rows keys on white_manifest_number (14 stamp rows) and 13 redacted FP docs
--    hang off this ticket; nulling it would break the Stamp Studio linkage and the blackout docs.
--    Backup: backups/2026-07-17_derm_306859_yellow_before.json
UPDATE public.derm_manifests
SET    yellow_ticket_number = '306859'
WHERE  white_manifest_number = '306859'
  AND  deleted_at IS NULL
  AND  yellow_ticket_number IS NULL;
-- Applied 2026-07-17: 14 rows. Verified: derm.manifests now shows "Broward #306859"
-- (jurisdiction=broward) and derm.v_stamp_rows still returns 14 rows for white#=306859.

-- 2. customer.work_orders: align manifest_jurisdiction to the DERM app (yellow wins), and
--    ADD disposal_county. Grafted onto the LIVE definition; new view columns must be appended
--    last, so disposal_county goes at the end of the select list.
--    Backup: backups/2026-07-17_customer_work_orders_before_jurisdiction.sql
--
--    BEFORE:  CASE WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'
--                  WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'
--                  ELSE NULL END AS manifest_jurisdiction
--
--    AFTER (identical to derm.manifests):
--             CASE WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'
--                  WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'
--                  ELSE NULL END AS manifest_jurisdiction
--
--    ADDED (same shape as the existing disposal_facility expression):
--             ( SELECT df2.county FROM disposal_facilities df2
--                WHERE df2.id = dm.disposal_facility_id) AS disposal_county
--
--    disposal_facilities.county already stores 'Miami-Dade' / 'Broward', which is exactly the
--    display string the Field Portal needs - no mapping required in the app.
--
-- VERIFIED after: FP vs DERM app jurisdiction = 537/537 AGREE, 0 disagree (was 60 disagreeing).
-- disposal_county is fully consistent with facility + jurisdiction:
--   Miami-Dade / South District WWTP / dade            = 441
--   Broward    / Water and Wastewater Services/broward =  96
--   null (no linked manifest)                          =   9
-- Integrity unchanged: services 546, FOG 519, WWTP 517, decal 502. (Row count 545 -> 546 is live
-- data: 8 visits completed since yesterday. Scalar subqueries cannot fan out rows.)
-- Diffed live-vs-backup: the ONLY changes are the jurisdiction CASE and the appended
-- disposal_county, so the decal expression, services fallback and derm redaction joins are intact.

-- (The CREATE OR REPLACE VIEW customer.work_orders AS ... full body was applied from the live
--  definition with only the two edits above; see the backup file for the previous body.)

-- FOLLOW-UP (app, Building Apps): add a "DISPOSAL COUNTY" row under "DISPOSAL FACILITY" in the
-- Grease Trap Details card, reading the new customer.work_orders.disposal_county
-- ("Miami-Dade" / "Broward"). Spec sent to the BA session 2026-07-17.
