-- ============================================================================
-- 2026-07-28s — stop `derm` being an anon-readable schema (leg 2 of 3)
-- ============================================================================
-- ⚠ STAGED, NOT APPLIED. Gate: Building Apps must confirm DERM Tracker's reads
-- arrive as `authenticated` (a user JWT whose role claim decodes to
-- authenticated, verified on the DATA request, not on getSession()). Same gate
-- that preceded 2026-07-28r for Stamp Studio, and for the same reason: if reads
-- are still anon, this takes the tool to 0 rows for staff, not just for strangers.
--
-- WHY: the vulnerability was never a UI gate. `derm` holds customer identity and
-- grants SELECT to anon, and the publishable key ships in every Lovable bundle
-- and is visible in page source. Confirmed live against the REST API with no
-- browser involved: derm.manifests?select=client_name returned real client names
-- to anon. 2026-07-28r closed the five Stamp-Studio-only views; this closes the
-- rest of the schema.
--
-- STILL LEAKING TODAY (11 of the 20 remaining objects carry identity):
--   manifests            client_name, client_code, manifest_photo_url, address_photo_url
--   manifest_health      client_name, manifest_photo_url, address_photo_url
--   manifest_visits      client_name, address
--   manifest_recipients  client_name
--   manifest_number_proposals  client_name, source_image_url, manifest_photo_url
--   gdo_report_status    client_code, client_name
--   gdos                 client_name
--   visits               client_name, address
--   address_row_map      image_url, facility_name_read, address_read   (the base TABLE)
--   v_orphan_manifests   client_code, client_name
--   v_stamp_linkage_gaps client_code, client_name
-- The remaining 9 carry no identity but are revoked too: once no anon consumer
-- exists, a partial revoke just leaves the next reader asking why anon can still
-- read half a schema.
--
-- ── WHY THIS IS SAFE — every consumer checked, not assumed ──────────────────
--   Field Portal (anon BY DESIGN, QR, no login) -> reads customer.* only.
--     PROVEN: customer.work_orders is postgres-owned with reloptions NULL (not
--     security_invoker), and the derm objects behind it (receipt_doc_class,
--     redacted_manifest_docs) are ALREADY not anon-readable. A rolled-back
--     `set role anon` probe returns 591 rows / 562 with a DERM sheet. Table
--     privileges ARE laundered through an owner-rights view.
--     ⚠ Note the asymmetry, learned the hard way on 2026-07-28h: table grants are
--     laundered through such a view, function EXECUTE is NOT.
--   get-derm-doc  -> edge fn on SERVICE_ROLE. It is the codebase's only public,
--     no-login, app-facing edge fn, so it was the one that had to be checked.
--   send-derm-email -> edge fn on SERVICE_ROLE.
--   DUMP Schedule (no auth) -> writes no DERM data at all (its CLAUDE.md forbids
--     it explicitly) and reaches the DB through a service_role edge fn.
--   GDO Slack bot -> service_role.
--   Stamp Studio -> authenticated since 2026-07-28r, verified in production.
--   DERM Tracker -> THE ONLY anon consumer left. Hence the gate.
--
-- anon holds NO INSERT/UPDATE/DELETE anywhere in derm (verified), so this is a
-- read-surface change only. The _require_stamp_key()-gated write RPCs and every
-- trigger function are untouched.
--
-- NOT IN SCOPE, deliberately: 4 anon-EXECUTABLE derm helpers remain
-- (fn_sheet_is_generated, fn_generated_sheet_slot, fn_generated_row_geometry,
-- normalize_facility). They return geometry/booleans, not customer data. Kept
-- separate so this migration stays one reversible idea.
--
-- ⚠ AND THIS STILL DOES NOT CLOSE THE EXPOSURE. The `manifests` storage bucket
-- is PUBLIC with predictable paths (manifests/derm/<id>/address_1.jpg), so the
-- scanned sheets — which list every co-client's name and street address — stay
-- fetchable by URL no matter what these grants say. Leg 3 (bucket private +
-- signed) is the only fix for the image half. See project_pending_derm_storage_private.
--
-- ROLLBACK: GRANT SELECT ON ALL TABLES IN SCHEMA derm TO anon;
-- AUDIT (ADR 010): grant-only change, no data touched.
-- ============================================================================

begin;

revoke select on all tables in schema derm from anon;

-- belt and braces: stop the Supabase default-privileges grant from silently
-- re-opening this on the NEXT table someone adds to derm. That default is how
-- derm.address_sheet_clients came out anon-readable on 2026-07-28 with no GRANT
-- written anywhere by anyone.
alter default privileges in schema derm revoke select on tables from anon;

commit;
