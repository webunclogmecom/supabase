-- 2026-08-02_2226  customer.gdo_reports: expose whether a LIVE GDO filing screenshot exists
--
-- Fred: "for the live data we need to put at the end the reports, it needs to be referenced to the
-- visits ... it's own section called 'Online Report'" + "We don't need dry-runs data tbh."
-- Target app confirmed with Fred: the FIELD PORTAL (customer-facing).
--
-- -- WHAT THIS IS -------------------------------------------------------------
-- The GDO RPA bot (John's Railway deployment) files our Grease Discharge Operating reports on the
-- Miami-Dade DERM portal and posts back one JPEG per attempt into storage bucket `rpa-evidence`
-- (the only PRIVATE bucket), plus a row in public.derm_portal_submissions.
-- The Field Portal will render that screenshot as proof of filing, per visit.
--
-- -- 🛑 THE SECURITY POINT THAT SHAPES THIS MIGRATION -------------------------
-- The bucket holds TWO KINDS of screenshot and they are NOT equally safe. Verified by opening one
-- of each rather than by reading the code:
--   LIVE  (`<visit_id>/<run_id>.jpg`)  -> the county's bare "Report Submitted" confirmation page.
--                                         Contains NO client data. Customer-safe.
--   DRY-RUN (`<visit_id>/dryrun.jpg`)  -> the full Preview FORM: facility name, facility address,
--                                         facility phone, our transporter #, our company address
--                                         and phone. Serving one to a customer would leak ANOTHER
--                                         facility's details.
-- ⇒ "we don't need dry-runs" is therefore a SECURITY REQUIREMENT, not a preference. Every path that
--   serves an image must filter `dry_run = false AND status = 'SUCCESS'`.
--
-- -- WHY A NEW COLUMN RATHER THAN REUSING `reported` --------------------------
-- The existing lateral admits `status='SUCCESS' OR portal_confirmation IS NOT NULL`. Today all 2
-- live rows are SUCCESS-with-screenshot, so `reported` and "has an image" coincide exactly (2 of 84)
-- -- and that coincidence is precisely the trap. A future LIVE non-SUCCESS row carrying a
-- confirmation string would set `reported = true` with NO image, and a UI keyed on `reported` would
-- render a broken card. Measured today: live rows 2, live non-SUCCESS 0. Zero today is not an
-- invariant, so the column is explicit.
--
-- The raw `screenshot_path` is deliberately NOT exposed. The path alone is useless (private bucket)
-- but publishing it invites a client-side fetch; the signed URL is minted server-side instead, by
-- the edge function, which re-checks the live-only filter itself.
--
-- PROBED rolled back before applying:
--   cols  -> visit_id, client_id, visit_date, reported, reported_at, confirmation, has_report_image
--   84 rows | has_report_image true on 2 | reported true on 2 (visits 6298 111-YC, 6036 041-MB)
--   grants intact: authenticated, postgres
-- APPEND-ONLY column add, so CREATE OR REPLACE VIEW accepts it (42P16 otherwise) and grants survive.
--
-- ADR 010 rule 8: view only, no table/column change on a base table -> no audit-trigger decision.
-- (public.derm_portal_submissions itself already carries the audit trigger.)
--
-- ⚠ Do NOT add `security_invoker` to this view. It is owner-rights on purpose so the Field Portal
-- can read it without holding a grant on public.derm_portal_submissions (which is granted to
-- service_role/postgres/yannick_readonly ONLY). See CLAUDE.md "Grants, views and functions".

BEGIN;

CREATE OR REPLACE VIEW customer.gdo_reports AS
 SELECT v.id AS visit_id,
    v.client_id,
    v.visit_date,
    s.visit_id IS NOT NULL AS reported,
    s.created_at AS reported_at,
    s.portal_confirmation AS confirmation,
    -- Explicit, and COALESCEd so it is a clean boolean rather than NULL on the no-filing rows.
    COALESCE(s.status = 'SUCCESS'::text AND s.screenshot_path IS NOT NULL, false) AS has_report_image
   FROM visits v
     LEFT JOIN LATERAL ( SELECT s_1.visit_id, s_1.created_at, s_1.portal_confirmation,
                                s_1.status, s_1.screenshot_path
           FROM derm_portal_submissions s_1
          WHERE s_1.visit_id = v.id AND NOT s_1.dry_run
            AND (s_1.status = 'SUCCESS'::text OR s_1.portal_confirmation IS NOT NULL)
          ORDER BY s_1.created_at DESC
         LIMIT 1) s ON true
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

COMMIT;
