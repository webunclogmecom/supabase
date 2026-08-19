-- ============================================================================
-- 2026-08-19 16:15 ET  Surface WHO filed a GDO report, and whether by hand
-- ============================================================================
-- The DERM App's "GDO Online Report" card renders derm.visit_gdo_report. Now that a report can
-- also be recorded by a person (fn_record_manual_gdo_report, 53efff6 / 8692d90), the card has to
-- be able to say WHICH it was and WHO did it - otherwise a hand-filed report is indistinguishable
-- from one of John's RPA runs, and the confirmation number is the only trace of a human decision.
--
-- CREATE OR REPLACE, never DROP + CREATE: dropping discards the grants (authenticated SELECT,
-- service_role SELECT) and the app would go blank with no error anyone would attribute to this.
-- OR REPLACE also forbids changing existing columns, so both new ones are APPENDED at the end.
--
-- is_manual derives from the run_id prefix rather than from filed_by_email being non-null,
-- because the prefix is the same thing the dry-run guard and the RPC key on. One rule, one place.
-- (The 29 pre-cutoff backfill rows will carry a filer email; the ~5 bot rows never will.)
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
    (s.run_id LIKE 'manual-%') AS is_manual
   FROM derm_portal_submissions s
     LEFT JOIN v_derm_portal_fields f ON f.visit_id = s.visit_id
  WHERE s.dry_run IS NOT TRUE;

COMMIT;
