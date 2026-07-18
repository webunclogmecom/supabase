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
-- ⚠ CORRECTED SAME NIGHT (2026-07-18 full audit — see docs/audits/2026-07-18_qty0_line_item_residue_audit.md):
--   The block that stood here called the 4 qty-0 typo'd lines on jobs 99900631/99900797/99900837
--   "dead duplicates ... clearing them is a DELETE in Jobber". THAT WAS WRONG and would have been
--   destructive: the live id-level probe showed those objects are the LINKED per-visit override
--   line items of pushed visits — Jobber renders a visit-scoped line at quantity 0 in the
--   job-scope connection while the owning visit reads the SAME id at qty 1 (no VisitLineItem type
--   exists; visit and job lines are shared JobLineItem objects). Deleting them would strip lines
--   off live visits. Their "Drainnage" text is OUR OWN pushed rows (the Calendar picker's old
--   catalog title), which this migration's catalog fix stops generating. NEVER delete a qty-0
--   job-scope line by quantity alone — required predicate: qty-0 AND linked to no visit
--   (quantityFilter:ALL) AND no invoice back-ref. Only 2 truly orphaned deletable lines exist
--   fleet-wide (job 99900635 / 045-NU: 215806562 $465 + 215806563 $9.99), gated on Fred.
--
-- VERIFIED after apply: service_line_items has 0 rows matching 'Drainnage' and 0 matching
--   'Lyft station'; code 02 service_kind still 'Pumping'.

UPDATE public.service_line_items
   SET title      = '02 - Service Agreement - Pumping - Grease Trap, Tank Cleaning & Warranty of Drainage',
       updated_at = now()
 WHERE code = '02'
   AND title LIKE '%Drainnage%';
