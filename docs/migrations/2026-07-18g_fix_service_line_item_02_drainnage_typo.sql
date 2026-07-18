-- 2026-07-18g — Fix the "Drainnage" typo in our canonical catalog (code 02)
--
-- CONTEXT: the Field Portal receipt was showing "Warranty of Drainnage" (double-n) on 63 work
-- orders. Fred asked whether the typo was in our CURRENT 01-27 line items or only in historical
-- data ("if not leave them they're a thing of the past").
--
-- FINDING — the typo was OURS, not Jobber's. Compared all 27 codes in
-- public.service_line_items against Jobber's live catalog (GraphQL productOrServices, 62 items):
--   * 25 of 27 codes matched exactly.
--   * code 02 DIFFERED: ours "…Warranty of Drainnage"  vs  Jobber "…Warranty of Drainage".
--     Jobber (gid://Jobber/ProductOrService/48304203) is CORRECT and is source of truth, so our
--     warehouse copy was the stale/wrong one. Jobber's catalog contains ZERO typo entries.
--   * code 13 also differs — ours "Auxiliary Line Cleaning" vs Jobber "Aux Cleaning". That is a
--     WORDING difference, not a typo, so it is deliberately NOT changed here. Flagged to Fred.
--
-- WHAT: one-row UPDATE bringing code 02's title in line with Jobber.
--       `title` is reference/display only — the taxonomy join uses `code` + `service_kind`
--       (unchanged, still 'Pumping'), so no view, receipt or report changes behaviour.
--
-- DELIBERATELY NOT DONE (Fred: "leave them they're a thing of the past"):
--   * The 66 historical visit line items + 14 issued invoice lines carrying "Drainnage".
--     These are copies made when the work happened; rewriting them would rewrite billing history.
--   * "Lyft station" (13 spellings, last used 2026-05-19) and "Auxiliar" (last used 2026-04-22).
--     Neither exists in the catalog — codes 04/11 correctly say "Lift Station" and code 13 says
--     "Auxiliary"/"Aux". Historical only, nothing generates them any more.
--
-- ⚠ STILL LIVE, NOT ACTIONED — 4 stale $0.00 line items on 3 active jobs still carry the old
--   typo'd text and can still be copied onto new visits (most recent occurrence 2026-07-14):
--     job 99900631 (043-MIL Mila)              line_item 82398  $0.00
--     job 99900797 (152-DAV Davinci)           line_items 82519, 82520  $0.00
--     job 99900837 (186-PV Pura Vida Coconut)  line_item 82560  $0.00
--   Each of those jobs ALREADY has a correctly-spelled, properly-priced sibling
--   ($1,620 / $435 / $700), so the typo'd rows are dead duplicates. Clearing them is a DELETE in
--   Jobber, not a rename — awaiting Fred's explicit go-ahead.
--
-- VERIFIED after apply: service_line_items has 0 rows matching 'Drainnage' and 0 matching
--   'Lyft station'; code 02 service_kind still 'Pumping'.

UPDATE public.service_line_items
   SET title      = '02 - Service Agreement - Pumping - Grease Trap, Tank Cleaning & Warranty of Drainage',
       updated_at = now()
 WHERE code = '02'
   AND title LIKE '%Drainnage%';
