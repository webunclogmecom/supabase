-- 2026-07-12_fp_inspection_items_stop_shift_misattribution.sql
-- FIELD PORTAL work-order data-provenance fix (Fred/Yan, 2026-07-12).
--
-- BUG: customer.inspection_items attached a POST inspection to a customer work order by
-- (vehicle_id, visit_date) and took the min-id completed visit (LIMIT 1). But a POST inspection is a
-- PER-SHIFT record (truck + date + driver: valve-closed?, any-issue?, issue_note) with NO client/visit
-- link — so one arbitrary client per truck+date got the whole shift's valve/issue status printed on their
-- customer-facing page ("Valve closed: No / No issues: Yes"), and the "issue" item renders the raw
-- shift issue_note as a label -> a customer-facing leak vector. Confirmed on 087-BB: visit 1345 (Feb 3,
-- David) showed David's shift inspection #12; visit 3903 (May 12, Moises) showed nothing (that shift's
-- inspection attached to a different client). 65 customer work orders were affected.
--
-- FIX (Fred decision: "keep the Interceptor/Trap Inspection block, trap condition only"): stop surfacing
-- shift inspection items on customer work orders. There is no valid per-client mapping for a shift-level
-- POST inspection, so the view returns NO rows. The block's legit per-visit "Overall Trap Condition"
-- comes from customer.work_orders.trap_condition (visits.trap_condition_notes) and is unaffected, so the
-- FP renders a consistent "Interceptor / Trap Inspection -> Overall Trap Condition" block on every visit
-- with no shift data and no leak. Column shape (id/work_order_id/label/value/is_positive/position) is
-- preserved so the FP query keeps working (0 rows); CREATE OR REPLACE keeps grants (anon/authenticated
-- SELECT) + owner + owner-rights. Reversible: restore the prior definition from the repo/backup.
-- (Audit found the other 7 customer.* views correctly client/visit-scoped — no other provenance issues.)

CREATE OR REPLACE VIEW customer.inspection_items AS
SELECT
  NULL::uuid    AS id,
  NULL::text    AS work_order_id,
  NULL::text    AS label,
  NULL::boolean AS value,
  NULL::boolean AS is_positive,
  NULL::integer AS "position"
WHERE false;
