-- 2026-08-03 — Reclassify line item 28 (Dump Offload) as a SERVICE CALL item
--
-- WHY (Fred, 2026-08-03, verbatim):
--   "on the calendar app when adding a new visit as SC, we need to show all the line items for SC,
--    and the new line item 28, which a dump visit, that is also a SC line item."
--
-- Code 28 was added 2026-07-21 as `reason='Disposal'`, `schedulable=false`. Those two values
-- excluded it from the Calendar's New Visit picker TWICE over:
--   * ops.client_service_options filters `sli.schedulable = true`
--   * every other Service Call code carries `reason='Service Call'`
-- Fred's statement is the classification decision: a dump offload IS a Service Call. This migration
-- makes the data agree with that.
--
-- `service_kind` deliberately STAYS 'Dump Offload'. `reason` classifies SA / SC / fee / other;
-- `service_kind` describes the work. Only the classification was wrong.
--
-- AUDIT: opt-out. `public.service_line_items` is a small reference/catalogue table, not
-- customer/billing/DERM data, and this is a one-row classification correction. No trigger added.
--
-- ── BLAST RADIUS, MEASURED BEFORE APPLYING (do not repeat this change blind) ────────────────────
--   `schedulable` is read by 3 functions (ops.create_visit_request, ops.update_visit_request,
--     public.ripple_reschedule_visit) and 4 views (client.service_line_items,
--     ops.client_service_options, ops.service_line_items, ops.v_calendar_visit). All of them
--     SHOULD now see 28 — that is the point of the change.
--   0 functions key on the literal 'Disposal', so nothing loses a branch.
--   ops.fn_service_group('Disposal','Dump Offload',NULL) and ('Service Call','Dump Offload',NULL)
--     BOTH return NULL, so SA chip colouring (the third colour system in the Visit Calendar) is
--     untouched. This was checked precisely because that view drives a colour system.
--   51 line_items already carry code 28, so it is live in Jobber, not a dormant code.
--
-- ⚠ THE ONE REAL HAZARD, CHECKED: the SA visit generator's JOB_PREDICATE keys on
--   `service_line_items.reason IN ('Service Agreement','Service Call') AND code <> '08'`.
--   Flipping 28 to 'Service Call' therefore makes it count as a physical service for visit-gen.
--   Measured BEFORE and AFTER: **0 non-archived SA jobs carry code 28**, so no agreement can start
--   generating dump visits as a side effect of this change.
--   🛑 IF AN SA JOB EVER GAINS A CODE-28 LINE ITEM, RE-RUN THAT CHECK — it would then generate
--   recurring visits, which is almost certainly not intended for a dump offload.

BEGIN;

UPDATE public.service_line_items
   SET reason      = 'Service Call',
       schedulable = true
 WHERE code = '28';

-- Assertion with a POSITIVE CONTROL: 28 must now be selectable, and the pre-existing SC codes must
-- still be there (a sweep that only checks 28 cannot tell "fixed" from "wiped the rest").
DO $$
DECLARE
  v_28  int;
  v_all int;
  v_sa_with_28 int;
BEGIN
  SELECT count(*) INTO v_28
    FROM public.service_line_items
   WHERE code = '28' AND reason = 'Service Call' AND schedulable AND active;

  SELECT count(*) INTO v_all
    FROM public.service_line_items
   WHERE reason = 'Service Call' AND schedulable AND active;

  SELECT count(*) INTO v_sa_with_28
    FROM public.jobs j
   WHERE j.title ILIKE 'Service Agreement%'
     AND j.job_status <> 'archived'
     AND EXISTS (SELECT 1 FROM public.line_items li
                  WHERE li.job_id = j.id
                    AND lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0') = '28');

  IF v_28 <> 1 THEN
    RAISE EXCEPTION 'code 28 is not a selectable Service Call item after the update';
  END IF;
  IF v_all < 17 THEN
    RAISE EXCEPTION 'expected at least 17 selectable SC items, found % — the other codes regressed', v_all;
  END IF;
  IF v_sa_with_28 <> 0 THEN
    RAISE EXCEPTION 'an SA job now carries code 28 (%) — visit-gen would generate dump visits', v_sa_with_28;
  END IF;

  RAISE NOTICE 'OK: 28 selectable, % SC items total, 0 SA jobs carry it', v_all;
END $$;

COMMIT;

-- APPLIED to Prod 2026-08-03. Verified after: 17 selectable SC codes
-- (09,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,28); SA jobs carrying 28 = 0.
--
-- APP-SIDE COUNTERPART (Visit Calendar, same cycle):
--   The New Visit SC flow previously offered ONLY the services already attached to that job, because
--   ops.client_service_options builds `services` from `line_items WHERE li.job_id = j.id`. Fred asked
--   for ALL SC line items, so the app now reads the full catalogue from ops.service_line_items
--   (already granted SELECT to `authenticated`). Safe at the write layer: create_calendar_visit does
--   NOT validate that the chosen services belong to the job — it only requires >= 1 service and an
--   active job for the client. Documented in Building Apps/Visit Calendar/docs/08-changelog.md.
