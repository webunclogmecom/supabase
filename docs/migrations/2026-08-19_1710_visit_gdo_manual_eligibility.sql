-- ============================================================================
-- 2026-08-19 17:10 ET  One place that decides whether a visit can be filed by hand
-- ============================================================================
-- The DERM App needs to know three things about a code-27 visit with no filing: should the
-- "GDO Online Report" card appear at all, may a person record a manual filing, and if not, why not.
--
-- 🛑 THE APP MUST NOT RE-DERIVE THIS. fn_record_manual_gdo_report already encodes the rules. If the
-- app decides "show the form" with its own copy of them, the two drift, and the failure is the worst
-- shape available: a form that looks usable and rejects every submission, or worse, a form that is
-- hidden on a visit that could legitimately be filed. One rule, one place - the same reason the
-- already-reported predicate was pulled from v_derm_portal_queue rather than reinvented.
--
-- ⚠ WHY has_code27 IS QUERIED AND NOT READ OFF THE PAGE. Visit 5786 carries a real
-- '27 - GDO Online Reporting' line item at $0.00 and the visit page renders NO "Line items" block
-- for it, while 6036 (the same item at $15.00) renders one. Anything keyed off what the UI happens
-- to show would have hidden the card on exactly the visit that needs it. Measured both, they differ.
--
-- The name match mirrors the RPC exactly, including the legacy 'GDO Report%' spelling, so a visit
-- can never be eligible here and refused there.
--
-- blocked_reason is written for a person to read in a disabled-button tooltip. It is ordered by
-- severity, not by the order the RPC checks things, because the first thing a human can DO about it
-- is what matters: link the manifest, then worry about the rest.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW derm.visit_gdo_manual_eligibility AS
SELECT
  v.id AS visit_id,
  EXISTS (SELECT 1 FROM public.line_items li
           WHERE li.visit_id = v.id
             AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%')) AS has_code27,
  EXISTS (SELECT 1 FROM public.derm_portal_submissions s
           WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
             AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))            AS already_filed,
  EXISTS (SELECT 1 FROM public.derm_portal_submissions s
           WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
             AND s.status <> 'SUCCESS' AND s.portal_confirmation IS NULL)                AS has_failed_attempt,
  (v.visit_date >= public.rpa_launch_cutoff())                                           AS post_cutoff,
  EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)              AS has_manifest_link,
  CASE
    WHEN v.visit_status <> 'completed' THEN 'This visit is not completed yet.'
    WHEN NOT EXISTS (SELECT 1 FROM public.line_items li
                      WHERE li.visit_id = v.id
                        AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%'))
      THEN 'This visit has no GDO Online Reporting line item.'
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                  WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
                    AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
      THEN 'This visit already has a report on record.'
    WHEN v.visit_date >= public.rpa_launch_cutoff()
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)
      THEN 'Link the manifest first. Without it, recording a filing here would not stop the bot filing this visit again.'
    ELSE NULL
  END AS blocked_reason,
  (
    v.visit_status = 'completed'
    AND EXISTS (SELECT 1 FROM public.line_items li
                 WHERE li.visit_id = v.id
                   AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%'))
    AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
                       AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
    AND (v.visit_date < public.rpa_launch_cutoff()
         OR EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id))
  ) AS can_record_manual
FROM public.visits v
WHERE v.deleted_at IS NULL;

GRANT SELECT ON derm.visit_gdo_manual_eligibility TO authenticated, service_role;

COMMIT;
