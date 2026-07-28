-- ============================================================================
-- 2026-07-28r — revoke anon SELECT on the Stamp-Studio-only views
-- ============================================================================
-- ⚠ STAGED, NOT YET APPLIED. Do not run until Building Apps confirms that a
-- SIGNED-IN Stamp Studio read arrives as `authenticated` (a user JWT in the
-- Authorization header, not the anon key). Fred, 2026-07-28: "land the narrow
-- revoke once BA confirms the session".
--
-- WHY THE WAIT IS NOT OPTIONAL: Building Apps measured the live app rendering
-- with ZERO session in storage. If no session is ever established, then a
-- signed-in read is still an ANON read, and this revoke takes Stamp Studio to
-- 0 rows for Yannick as well as for strangers. That is a near-certainty, not a
-- risk to accept blind — hence the confirmation gate.
--
-- WHAT THIS FIXES: Stamp Studio's client-side login gate does not hold. The SSR
-- HTML gates correctly, but after hydration the app renders anyway, so a
-- signed-out visitor at studio.unclogme.app sees real client names, addresses
-- and scanned sheets. Six Lovable build attempts failed to fix it and the
-- workspace-lock is paywalled, so we stop defending in the UI and defend at the
-- data layer instead.
--
-- SCOPE: only views Building Apps verified are Stamp-Studio-only (DERM Tracker
-- does not reference any of them). `authenticated` keeps SELECT throughout, so
-- signed-in staff are unaffected. Write RPCs are gated separately by
-- derm._require_stamp_key() and are deliberately untouched.
--
-- ⚠ v_stamp_sheets IS included even though it has no client_name/address column.
-- It exposes page_image_urls, and the `manifests` storage bucket is PUBLIC — the
-- scanned sheet itself lists every co-client's name and street address. A URL to
-- the image is as good as the data. "No PII column" is not "no PII".
--
-- ============================================================================
-- ⚠⚠ THIS DOES NOT CLOSE THE EXPOSURE. Two paths remain open afterwards:
--
-- 1. derm.manifests / manifest_health / manifest_number_proposals still grant
--    anon SELECT and still expose client_name, client_code and manifest image
--    URLs. DERM Tracker reads manifests + manifest_health as anon, so they
--    cannot be revoked until that app carries a session too. The anon key is
--    public in every Lovable bundle, so anyone can read these straight off the
--    REST API without going near Stamp Studio.
-- 2. The `manifests` storage bucket is PUBLIC and paths are predictable
--    (manifests/derm/<id>/address_1.jpg). Every DB grant here could be revoked
--    and the sheets would still be fetchable by URL. That is the pending
--    "DERM storage private + signed" item, and it is the real fix for the image
--    half of this.
--
-- So: report this as a reduction in surface, never as "the leak is closed".
-- ============================================================================
--
-- ROLLBACK (one line, if Studio goes to 0 rows for signed-in staff):
--   GRANT SELECT ON derm.v_stamp_rows, derm.v_stamp_sheets, derm.v_stamp_clients,
--                   derm.v_stamp_row_candidate_visits, derm.v_stamp_unlinked_visits
--     TO anon;
--
-- AUDIT (ADR 010): grant-only change, no data touched.
-- ============================================================================

begin;

revoke select on derm.v_stamp_rows                 from anon;  -- client_name, address_read, facility_name_read, image_url
revoke select on derm.v_stamp_sheets               from anon;  -- page_image_urls (public bucket)
revoke select on derm.v_stamp_clients              from anon;  -- client_code
revoke select on derm.v_stamp_unlinked_visits      from anon;  -- client_code, client_name
revoke select on derm.v_stamp_row_candidate_visits from anon;  -- no PII columns; revoked to keep the set coherent

commit;
