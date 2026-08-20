-- ============================================================================
-- 2026-08-20 15:30 ET  One row per SUBMISSION, so the GDO card stops disappearing
-- ============================================================================
-- Fred, on /visits/6617: the GDO Online Report section "looks awful, it's showing multiple GDO",
-- says BOTH "No GDO Online Report on record for this visit yet" AND "This visit already has a
-- report on record", and shows no evidence images.
--
-- 🛑 THE VIEW'S DOCUMENTED GRAIN HAS NEVER MATCHED ITS ACTUAL GRAIN, AND THE APP WAS BUILT TO THE
-- DOCUMENTATION. Both app docs describe it as "one row per live filing":
--     DERM Tracker/docs/03-data-model.md:77   "one row per live, non dry-run ... filing"
--     DERM Tracker/docs/06-features-and-routes.md:158  "one row per live filing"
-- It was actually one row per (filing x GDO permit), because it joined
-- v_derm_portal_fields on visit_id ALONE and that view is keyed per visit AND permit. The app
-- therefore fetches it with .maybeSingle() - correct for the documented grain, and supabase-js
-- rejects anything over one row, so `data` comes back NULL and the card takes its EMPTY branch.
--
-- Visit 6617 (043-MIL Mila) has TWO permits, so it returned 5 submissions x 2 permits = 10 rows.
-- Meanwhile derm.visit_gdo_manual_eligibility returns exactly one row, works fine, and correctly
-- reports already_filed - which is why the page contradicts itself.
--
-- ⚠ THIS IS NOT A NEW BUG AND IT IS NOT CAUSED BY THE 2026-08-19 MANUAL-FILING WORK. 6617 has had
-- two permits all along, so the view returned 2 rows from the FIRST submission on 2026-08-07 and
-- the card has been broken ever since. Before 08-19 the section rendered only when a report
-- existed, so the failure was SILENT - the section simply did not appear. The 08-19 change made the
-- section always render, which turned a twelve-day-old silent failure into a visible, contradictory
-- one. Louder, not newer.
--
-- THE FIX: a LATERAL that returns AT MOST ONE field row per submission, matched on the submission's
-- OWN gdo_id. A submission already carries gdo_id and manifest_id, so matching on visit alone was
-- always wrong - it paired every filing with every permit at the property, including permits that
-- filing had nothing to do with.
--
-- Measured before applying (11 live submissions fleet-wide):
--     current view rows                                 16
--     proposed view rows                                11   <- exactly one per submission
--     submissions with a NULL gdo_id                     0
--     submissions that would LOSE their field values      0
-- Per visit: the six that render today (6036, 6216, 6298, 6719, 6741, 7456) stay at 1 row each and
-- are byte-identical; 6617 goes 10 -> 5.
--
-- ⚠ THE VIEW FIX ALONE DOES NOT FIX THE SCREEN. 6617 still returns 5 rows - one per real filing -
-- and .maybeSingle() rejects 5 exactly as it rejects 10. The app must stop asking for a single row
-- and render one block per GDO permit. That is the UI half and it ships separately.
--
-- LATERAL + LIMIT 1 rather than a plain AND: a submission with a NULL gdo_id would otherwise match
-- every permit and fan out again. There are none today, so this costs nothing now and makes the
-- one-row-per-submission grain true by construction rather than true by luck.
--
-- No DB-side dependents (pg_depend: 0 dependent views). Column list, order and names unchanged, as
-- CREATE OR REPLACE VIEW requires. Audit rule 8: a view, no triggers.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW derm.visit_gdo_report AS
 SELECT s.visit_id,
    s.status,
    s.portal_confirmation,
    s.failure_reason,
    s.retryable,
    s.attempted_at,
    s.run_id,
    s.screenshot_path,
    s.screenshot_missing_reason,
    s.manifest_id,
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
    s.filed_by_email,
    s.run_id ~~ 'manual-%'::text AS is_manual
   FROM derm_portal_submissions s
     LEFT JOIN LATERAL ( SELECT f2.*
           FROM v_derm_portal_fields f2
          WHERE f2.visit_id = s.visit_id
            AND (s.gdo_id IS NULL OR f2.gdo_id = s.gdo_id)
          ORDER BY (f2.gdo_id IS DISTINCT FROM s.gdo_id), f2.gdo_id
         LIMIT 1) f ON true
  WHERE s.dry_run IS NOT TRUE;

COMMIT;
