-- ============================================================================
-- 2026-08-20 17:20 ET  Eligibility must be answered PER PERMIT, not per visit
-- ============================================================================
-- Found in the smoke test straight after publishing the per-permit card.
--
-- Visit 6617 renders correctly now: GDO-14117 shows its SUCCESS with the portal screenshot, and
-- GDO-11024 shows its four ERROR_LOGIN_FAILED attempts. But there is **no "Record a manual filing"
-- button on 11024**, which is the one permit that actually needs one - it has never been filed and
-- the visit is 16 days old.
--
-- 🛑 THE VIEW AND THE FUNCTION DISAGREE AT THE PERMIT GRAIN. This is the same drift class that
-- derm.visit_gdo_manual_eligibility was created to prevent, reappearing one level down:
--   * fn_record_manual_gdo_report's duplicate check is PER PERMIT
--       (s.gdo_id IS NULL OR v_gdo IS NULL OR s.gdo_id = v_gdo)
--     so it ACCEPTS a manual filing for 11024 on 6617. Proven with a rolled-back probe on
--     2026-08-19: 11024 accepted, 14117 correctly refused.
--   * derm.visit_gdo_manual_eligibility.can_record_manual is PER VISIT and reads FALSE, because
--     already_filed is true - 14117 succeeded.
-- So the UI hides a button for an action the database would happily perform. The interface is
-- strictly more restrictive than the rule, which is the quieter half of the drift and the reason it
-- survived a passing agreement probe: that probe compared the VISIT-level view against the function
-- and both said "no", agreeing for different reasons.
--
-- THE FIX: answer it where the question is actually per-permit. derm.visit_gdo_our_record is already
-- one row per (visit, permit) and is already what the card maps over, so the columns are appended
-- there rather than inventing a third eligibility object. The predicate is copied from the
-- function's own duplicate check with v_gdo replaced by this row's gdo_id - one rule, one shape.
--
-- The visit-level view is deliberately LEFT ALONE. The app fetches it with .maybeSingle() and relies
-- on it being exactly one row per visit; changing its grain would break that the same way
-- visit_gdo_report's grain broke the card. It keeps answering the visit-level question ("may this
-- visit be filed at all"), which is still the right gate for a single-permit visit.
--
-- Verified before applying, on 6617:
--     GDO-11024   filed_for_this_permit = false   can_record_manual = true
--     GDO-14117   filed_for_this_permit = true    can_record_manual = false
--
-- Columns are APPENDED at the end: CREATE OR REPLACE VIEW may not rename or reorder existing ones.
-- Audit rule 8: a view, no triggers.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW derm.visit_gdo_our_record AS
 SELECT f.visit_id,
        f.manifest_id,
        f.gdo_id,
        f.client_code,
        f.client_name,
        f.address,
        f.city,
        f.zip,
        f.county,
        f.gdo_number,
        f.visit_date,
        f.ticket_number,
        f.jurisdiction,
        f.dump_ticket_date,
        f.disposal_facility,
        -- ---- appended 2026-08-20: the per-permit answer -------------------------------------
        EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                 WHERE s.visit_id = f.visit_id AND s.dry_run IS NOT TRUE
                   AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                   AND (s.gdo_id IS NULL OR f.gdo_id IS NULL OR s.gdo_id = f.gdo_id))
          AS filed_for_this_permit,
        (
          v.visit_status = 'completed'
          AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                           WHERE s.visit_id = f.visit_id AND s.dry_run IS NOT TRUE
                             AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                             AND (s.gdo_id IS NULL OR f.gdo_id IS NULL OR s.gdo_id = f.gdo_id))
        ) AS can_record_manual,
        CASE
          WHEN v.visit_status <> 'completed' THEN 'This visit is not completed yet.'
          WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                        WHERE s.visit_id = f.visit_id AND s.dry_run IS NOT TRUE
                          AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                          AND (s.gdo_id IS NULL OR f.gdo_id IS NULL OR s.gdo_id = f.gdo_id))
            THEN 'This permit already has a report on record.'
          ELSE NULL
        END AS blocked_reason,
        -- The row exists in v_derm_portal_fields by construction, so the bot can reach this
        -- (visit, permit) pair exactly when the visit is on or after the launch cutoff.
        (f.visit_date >= public.rpa_launch_cutoff()) AS suppresses_bot
   FROM public.v_derm_portal_fields f
   JOIN public.visits v ON v.id = f.visit_id;

GRANT SELECT ON derm.visit_gdo_our_record TO authenticated, service_role;

COMMIT;
