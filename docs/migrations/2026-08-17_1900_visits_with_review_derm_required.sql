-- 2026-08-17_1900_visits_with_review_derm_required.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Serena in Slack: she could not find the "Send email to City" option on a Happea's visit. The audit
-- (Fred, 2026-08-17) found two app-side defects; this migration unblocks the one that needs data.
--
-- D3: the Admin Review bundle contains the string `derm_required` ZERO times, so the app cannot know
-- that a visit is un-sendable. `send-visit-photos-email` refuses a non-DERM visit with
-- `not_derm_required` (correctly - the Field Portal publishes no Service Report for one, so there is
-- literally nothing to attach). Live example: visit 7755, 026-HAP, `derm_required = false`. Today
-- someone would classify its photos, be shown the Send button, click, and get the raw string
-- "Could not send: not_derm_required" after doing the work for nothing.
--
-- `public.visits_with_review` is what the queue and the visit page read, and it did not expose the
-- column. It does now. The app change (hide the button, explain why) rides on this.
--
-- ALSO: RE-POINTED TO v_visits_live -------------------------------------------------------------
-- Supabase CLAUDE.md lists this view under "Pending follow-up ... re-point these at v_visits_live
-- when touched", and it was still reading bare `visits`. Measured before changing it:
--     698 soft-deleted visits were visible through this view
--       2 of them are completed + review_status pending (vs 1,063 live)
--       0 soft-deleted completed visits have any photos
-- So the correction removes exactly 2 rows from the review queue, both of them visits that were
-- soft-deleted and should never have been reviewable. Small, and in the safe direction.
--
-- AUDIT (rule #8): a view. No table changed, nothing to opt in or out of. `public.visits` keeps its
-- own audit trigger.
--
-- The body below is pg_get_viewdef output with exactly two edits, both at anchors asserted to occur
-- exactly once: `FROM visits v` -> `FROM v_visits_live v`, and derm_required APPENDED as the LAST
-- select-list column.
--
-- ⚠ It has to be appended, not inserted next to the other visit columns: CREATE OR REPLACE VIEW
-- refuses to renumber an existing column (42P16 "cannot change name of view column"). DROP + CREATE
-- would allow it and is the wrong trade - DROP VIEW discards the grants, and this view carries
-- authenticated + service_role + yannick_readonly. Copied, not retyped (Supabase CLAUDE.md).

begin;

CREATE OR REPLACE VIEW public.visits_with_review AS
SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at,
    vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at,
    vr.bonus_decided_by,
    vr.bonus_denial_note,
    vr.quality_flag_note,
    v.public_id,
    COALESCE(vr.invoice_status, 'pending'::text) AS invoice_status,
    vr.invoice_decided_at,
    vr.invoice_decided_by,
    v.derm_required
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id;

commit;
