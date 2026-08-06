-- 2026-08-06_1930_gdo_report_submitted_fields.sql
--
-- WHAT: add the SUBMITTED FIELD VALUES to derm.visit_gdo_report, so the DERM Tracker can show
--       what we filed beside the evidence screenshot.
--
-- WHY: Fred, 2026-08-06, looking at the county's Preview page in the evidence photo: "can you put
--      the data of the image on the right side of where the image is placed".
--
-- ⚠ THE DATA IS NOT READ OUT OF THE IMAGE. Every field on that Preview page is something we sent,
--   so it is rendered from our own record. No OCR, nothing inferred from pixels. If the two ever
--   disagree, that disagreement is a real finding and must stay visible - which it cannot be if we
--   transcribe the picture into the panel.
--
-- ⚠ SOURCE IS v_derm_portal_fields, NOT v_derm_portal_queue. The queue view EXCLUDES already-reported
--   visits by design, so it is empty for exactly the visits this panel is for. Measured: visit 6719
--   is in _fields (1) and not in _queue (0). Using the queue here would render a blank panel on every
--   filed report and look like missing data.
--
-- ⚠ v_derm_portal_fields is NOT granted to `authenticated`. It is reached through this owner-rights
--   view in the derm schema (the standard schema-per-app laundering), so no new grant is opened on
--   the base view itself.
--
-- Fields map to the county form as: client_name = Facility Name, address/city/zip = Facility Address,
-- visit_date = Date Cleaned, ticket_number = the dump ticket filed. The Company Name/Address/Phone and
-- Liquid Waste Transporter # on that form are OUR constants (UNCLOGME LLC, transporter 1133) and are
-- deliberately NOT stored per-visit, so they are not surfaced here as if they were per-visit data.

BEGIN;

CREATE OR REPLACE VIEW derm.visit_gdo_report AS
SELECT
  s.visit_id,
  s.status,
  s.portal_confirmation,
  s.failure_reason,
  s.retryable,
  s.attempted_at,
  s.run_id,
  s.screenshot_path,
  s.screenshot_missing_reason,
  s.manifest_id,
  -- submitted field values (appended; CREATE OR REPLACE VIEW only permits adding at the end)
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
  f.disposal_facility
FROM public.derm_portal_submissions s
LEFT JOIN public.v_derm_portal_fields f ON f.visit_id = s.visit_id
WHERE s.dry_run IS NOT TRUE;

COMMENT ON VIEW derm.visit_gdo_report IS
  'Live (non dry-run) GDO Online Report per visit, plus the field values we submitted, for the DERM '
  'Tracker visit page. Dry-run rows are excluded: they are test artefacts against a separate QA queue '
  'and would read as real filings. The submitted fields come from v_derm_portal_fields (which retains '
  'reported visits), NOT v_derm_portal_queue (which excludes them). LEFT JOIN on purpose: a report '
  'must still render if its manifest link is later changed.';

GRANT SELECT ON derm.visit_gdo_report TO authenticated;
GRANT SELECT ON derm.visit_gdo_report TO service_role;

DO $$
DECLARE r record; n int;
BEGIN
  -- (a) the panel must actually populate for the filed visit
  SELECT * INTO r FROM derm.visit_gdo_report WHERE visit_id = 6719;
  IF r.client_name IS NULL OR r.address IS NULL OR r.gdo_number IS NULL OR r.visit_date IS NULL THEN
    RAISE EXCEPTION 'submitted fields are NULL for visit 6719 - panel would render blank (name=% addr=% gdo=% date=%)',
      r.client_name, r.address, r.gdo_number, r.visit_date;
  END IF;

  -- (b) CONTROL: the values must match the county Preview page Fred screenshotted.
  --     Without this, any join returning *some* row would pass (a).
  IF r.client_name NOT ILIKE '%CLAUDIE%' THEN
    RAISE EXCEPTION 'facility name is % - expected the Claudie record shown on the portal preview', r.client_name;
  END IF;
  IF r.visit_date <> DATE '2026-07-23' THEN
    RAISE EXCEPTION 'date cleaned is %, the portal preview shows 07/23/2026', r.visit_date;
  END IF;

  -- (c) still exactly the 3 live reports, dry-runs still hidden
  SELECT count(*) INTO n FROM derm.visit_gdo_report;
  IF n <> 3 THEN RAISE EXCEPTION 'expected 3 live reports, view returned %', n; END IF;

  -- (d) the app can still read it
  IF NOT has_table_privilege('authenticated','derm.visit_gdo_report','SELECT') THEN
    RAISE EXCEPTION 'authenticated lost SELECT on the report view';
  END IF;

  RAISE NOTICE 'OK: submitted fields populate and match the portal preview (% / % / %)',
    r.client_name, r.address, r.visit_date;
END $$;

COMMIT;
