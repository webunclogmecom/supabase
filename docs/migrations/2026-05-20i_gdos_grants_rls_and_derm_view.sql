-- 2026-05-20i_gdos_grants_rls_and_derm_view.sql
--
-- Phase 3 prep: expose public.gdos to the DERM Tracker (anon) with
-- column-scoped UPDATE — ops can edit location_label / property_id /
-- notes / status only; cannot tamper with gdo_number / client_id /
-- timestamps. Also wire derm_manifests.gdo_id into the anon write
-- surface so manifest entry can assign a GDO, and create derm.gdos
-- view for app reads.
--
-- Security note (and broader follow-up): Supabase's defaults grant anon
-- broad TABLE-LEVEL INSERT/UPDATE/DELETE on most public.* tables. Plain
-- column-level GRANT is meaningless without first REVOKEing the table
-- privilege. Discovered today when smoke-testing gdo_number tampering:
-- column-level GRANT (location_label) appeared to work but anon was
-- still able to PATCH gdo_number to 'HACKED' (verified in DB).
-- Pattern for this and future writable-by-anon tables:
--   1. REVOKE INSERT, UPDATE, DELETE FROM anon, authenticated
--   2. GRANT SELECT (or specific cols) back
--   3. GRANT UPDATE (specific_cols_only) back
--   4. RLS policy enforces row-level scope on top
-- A separate audit pass should sweep all public.* tables with sensitive
-- columns (clients, derm_manifests, visits, properties, etc.) and verify
-- the same lockdown.
--
-- Audit (Rule 8): no schema changes that need triggers — only grants
-- and a view. gdos already has audit_gdos from 2026-05-20g.

BEGIN;

-- 1. Lock down public.gdos write surface
--    Default Supabase grants table-level INSERT/UPDATE/DELETE on every
--    public.* table to anon + authenticated. Revoke + re-grant scoped.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.gdos FROM anon, authenticated;
GRANT UPDATE (location_label, property_id, notes, status)
  ON public.gdos TO anon, authenticated;

ALTER TABLE public.gdos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_gdos" ON public.gdos
  AS PERMISSIVE FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "anon_update_gdo_labels" ON public.gdos
  AS PERMISSIVE FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

-- 2. derm_manifests.gdo_id → anon UPDATE
--    Add gdo_id to the existing column-grant surface (derm_required +
--    other DERM Tracker writeable columns are already granted in 2026-05-19c
--    and 2026-05-18a). Plus add to RLS — but the existing
--    anon_update_visit_derm_required policy was on visits, not derm_manifests;
--    derm_manifests has its own anon_update_derm_manifests policy from
--    2026-05-18a which already allows updates.
GRANT UPDATE (gdo_id) ON public.derm_manifests TO anon, authenticated;

-- 3. derm.gdos view — DERM Tracker reads here (mirrors derm.visits,
--    derm.manifests pattern). Adds the friendly client_name and
--    manifest_count rollup.
CREATE OR REPLACE VIEW derm.gdos AS
SELECT
  g.id,
  g.client_id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                                       AS client_name,
  g.gdo_number,
  g.location_label,
  g.property_id,
  g.permit_expiration::text                 AS permit_expiration,
  g.permit_document_path,
  g.status,
  g.notes,
  g.created_at::text                        AS created_at,
  g.updated_at::text                        AS updated_at,
  (SELECT COUNT(*) FROM public.derm_manifests dm WHERE dm.gdo_id = g.id) AS manifest_count
FROM public.gdos g
JOIN public.clients c ON c.id = g.client_id;

GRANT SELECT ON derm.gdos TO anon, authenticated;
GRANT ALL    ON derm.gdos TO service_role;

COMMIT;

-- Verification (smoke):
--   PATCH /rest/v1/gdos?id=eq.X with {"location_label":"Bar"}  → 204 OK
--   PATCH /rest/v1/gdos?id=eq.X with {"gdo_number":"HACK"}    → 401 permission denied
--   PATCH /rest/v1/gdos?id=eq.X with {"client_id":999}        → 401
--   POST  /rest/v1/gdos {...}                                  → 401
--   DELETE /rest/v1/gdos?id=eq.X                               → 401
--   SELECT /rest/v1/gdos?client_id=eq.369                      → 200, 3 rows
