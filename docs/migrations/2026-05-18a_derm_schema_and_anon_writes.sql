-- 2026-05-18a_derm_schema_and_anon_writes.sql
--
-- DERM Tracker — production wire-up.
-- Mirrors the customer.* per-app schema pattern shipped 2026-05-14
-- for Field Portal.
--
-- Sections:
--   1. CREATE SCHEMA derm + usage grants
--   2. 4 views: derm.visits, derm.manifests, derm.manifest_visits,
--      derm.disposal_facilities
--   3. SELECT grants + ALTER DEFAULT PRIVILEGES on views
--   4. Anon RLS read policy on public.disposal_facilities (currently
--      RLS-blocked despite GRANT — derm.disposal_facilities view would
--      have returned empty without this)
--   5. Anon INSERT/UPDATE grants + RLS policies on public.derm_manifests
--   6. Anon INSERT/DELETE grants + RLS policies on public.manifest_visits
--   7. Audit trigger opt-in on public.manifest_visits
--   8. Anon INSERT policy on storage.objects for path 'derm/*'
--
-- Audit opt-in per ADR 010 Rule 8 (CLAUDE.md):
--   * derm.* views — READ-ONLY, no audit needed (audit happens at
--     underlying public.* writes).
--   * public.manifest_visits — OPTING IN. Original ADR 010 exclusion
--     ("AT-sync-only, high churn, derivable") is superseded: DERM
--     Tracker introduces human-edit link/unlink, which Rule 8 mandates
--     be audited. Exclusion-list entry in ADR 010 already noted this
--     revisit at DERM Tracker build (2026-05-17 edit).
--   * public.derm_manifests — already audited (audit_derm_manifests).
--     Expanding the writer set from {service_role} → {service_role,
--     anon} does not change audit semantics.
--   * public.disposal_facilities — already audited. New read policy
--     doesn't affect that.
--
-- Ship-first-harden-later: anon writes accepted-risk for MVP. To be
-- revisited when Phase 2 auth ships across the apps.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS derm;
GRANT USAGE ON SCHEMA derm TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. View — derm.visits
-- Completed visits + denormalized client/property context + manifest flag.
-- LATERAL pick of the first non-billing property (28% of clients have >1).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  c.name AS client_name,
  COALESCE(p.address, '') AS address,
  COALESCE(p.county,  '') AS county,
  v.visit_date::text AS visit_date,
  NULL::text         AS technician,   -- placeholder; we don't expose driver names per app contract
  NULL::text         AS notes,        -- placeholder; visit-level notes come from `notes` table, not here
  v.created_at::text AS created_at,
  v.client_id,
  v.service_type,
  EXISTS (
    SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id
  ) AS has_manifest
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id
    AND p2.is_billing = false
  ORDER BY p2.id
  LIMIT 1
) p ON true
WHERE v.visit_status = 'completed';

-- ---------------------------------------------------------------------------
-- 3. View — derm.manifests
-- Manifest rows + denormalized client + disposal facility.
-- Column aliases keep compatibility with the Lovable app's existing data
-- contract; canonical fields are exposed alongside for the app to grow into.
--
-- KNOWN DATA GAP: disposal_facility_id is currently 100% NULL on all 1,018
-- manifest rows (audit 2026-05-18). The LEFT JOIN handles this — dump_location
-- will be NULL until DERM Tracker starts populating it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.manifests AS
SELECT
  dm.id,
  dm.white_manifest_number          AS manifest_number,
  'WHITE'::text                     AS manifest_type,
  dm.derm_manifest_url              AS manifest_photo_url,
  dm.derm_address_url               AS address_photo_url,
  dm.dump_ticket_date::text         AS dump_date,
  df.name                           AS dump_location,
  NULL::text                        AS driver_name,
  NULL::numeric                     AS gallons,
  dm.created_at::text               AS created_at,
  -- Canonical fields the app can grow into
  dm.client_id,
  c.name                            AS client_name,
  dm.service_date::text             AS service_date,
  dm.yellow_ticket_number,
  dm.wwtp_receipt_number,
  dm.wwtp_receipt_document_path,
  dm.wwtp_ticket_number,
  dm.disposal_facility_id,
  dm.sent_to_client,
  dm.sent_to_city,
  dm.updated_at::text               AS updated_at
FROM public.derm_manifests dm
LEFT JOIN public.clients c              ON c.id  = dm.client_id
LEFT JOIN public.disposal_facilities df ON df.id = dm.disposal_facility_id;

-- ---------------------------------------------------------------------------
-- 4. View — derm.manifest_visits
-- M:N bridge with visit context for "Attached visits" + "Attach visit" picker.
-- Same LATERAL property pick as derm.visits.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.manifest_visits AS
SELECT
  mv.manifest_id,
  mv.visit_id,
  v.visit_date::text AS visit_date,
  v.client_id,
  c.name             AS client_name,
  COALESCE(p.address, '') AS address,
  COALESCE(p.county,  '') AS county
FROM public.manifest_visits mv
JOIN public.visits v  ON v.id = mv.visit_id
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id
    AND p2.is_billing = false
  ORDER BY p2.id
  LIMIT 1
) p ON true;

-- ---------------------------------------------------------------------------
-- 5. View — derm.disposal_facilities
-- Reference for the dump-site picker. Filter by status='ACTIVE'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.disposal_facilities AS
SELECT id, name, facility_type, latitude, longitude
FROM public.disposal_facilities
WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- 6. View grants
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA derm TO anon, authenticated;
GRANT ALL    ON ALL TABLES IN SCHEMA derm TO service_role;

-- Auto-grant on future views in this schema
ALTER DEFAULT PRIVILEGES IN SCHEMA derm
  GRANT SELECT ON TABLES TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Read policies on public.disposal_facilities
-- RLS is enabled but had ZERO policies (audit 2026-05-18). Without these,
-- the derm.disposal_facilities view returns empty for anon AND authenticated.
-- Service_role bypasses RLS so this never tripped the AT sync.
-- ---------------------------------------------------------------------------
CREATE POLICY "anon_read_disposal_facilities"
  ON public.disposal_facilities
  FOR SELECT TO anon
  USING (true);

CREATE POLICY "authenticated_read_disposal_facilities"
  ON public.disposal_facilities
  FOR SELECT TO authenticated
  USING (true);

-- ---------------------------------------------------------------------------
-- 8. Anon write surface — public.derm_manifests
-- INSERT + UPDATE. No DELETE (Rule 6: no hard-deletes on business data).
-- ---------------------------------------------------------------------------
GRANT INSERT, UPDATE ON public.derm_manifests TO anon;

CREATE POLICY "anon_insert_derm_manifests"
  ON public.derm_manifests
  FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "anon_update_derm_manifests"
  ON public.derm_manifests
  FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 9. Anon write surface — public.manifest_visits
-- INSERT (attach visit to manifest) + DELETE (detach). DELETE is OK here
-- since the row IS the link — it's not destroying business data, it's
-- unlinking.
-- ---------------------------------------------------------------------------
GRANT INSERT, DELETE ON public.manifest_visits TO anon;

CREATE POLICY "anon_insert_manifest_visits"
  ON public.manifest_visits
  FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "anon_delete_manifest_visits"
  ON public.manifest_visits
  FOR DELETE TO anon
  USING (true);

-- ---------------------------------------------------------------------------
-- 10. Audit trigger opt-in — public.manifest_visits
-- Per Rule 8 (CLAUDE.md) / ADR 010 standing rule: human-edit surfaces must
-- explicitly opt in. The ADR 010 exclusion-list entry for this table noted
-- "revisit at DERM Tracker build" — this is that revisit.
-- ---------------------------------------------------------------------------
CREATE TRIGGER audit_manifest_visits
  AFTER INSERT OR UPDATE OR DELETE ON public.manifest_visits
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

COMMIT;

-- ---------------------------------------------------------------------------
-- 11. Storage policy — anon INSERT to GT - Visits Images, derm/* path
-- (Storage policies are RLS on storage.objects. Existing 4 policies are
-- authenticated-only.)
--
-- Run separately because storage.objects sits in a different lifecycle than
-- the public schema migration above, and Supabase sometimes treats storage
-- changes as a separate transaction in the Management API.
-- ---------------------------------------------------------------------------
BEGIN;

CREATE POLICY "Anon can upload to derm path in GT visit images"
  ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (
    bucket_id = 'GT - Visits Images'
    AND (storage.foldername(name))[1] = 'derm'
  );

COMMIT;
