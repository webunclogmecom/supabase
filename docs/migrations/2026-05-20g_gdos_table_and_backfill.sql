-- 2026-05-20g_gdos_table_and_backfill.sql
--
-- New first-class GDO entity per Fred 2026-05-20:
-- "we're gonna work by how many GDO's a client has, because remember the
--  same client can have multiple locations, like Casa Neos, has 3 locations
--  (Bar, Kitchen and Lounge)."
--
-- The architectural gap this fixes:
--   - service_configs.permit_number is TEXT — Casa Neos had all 3 GDOs
--     comma-jammed into one cell ('GDO-10877, GDO-15062, GDO-16389')
--   - derm_manifests linked to client_id only — no way to attribute a
--     specific manifest to "the Bar location" vs "the Kitchen location"
--   - The 10 unsynced AT clients (207-BAR Casa Neos BAR + 216-220 WYN +
--     others) are actually separate GDOs/locations of existing Jobber
--     clients, not new Jobber clients
--
-- This migration:
--   1. Creates public.gdos { id, client_id FK, gdo_number, location_label,
--      property_id FK, permit_expiration, permit_document_path, status,
--      notes, created_at, updated_at }
--   2. Adds derm_manifests.gdo_id (nullable, FK to gdos.id)
--   3. Backfills 104 GDOs from service_configs.permit_number — splits on
--      comma so Casa Neos gets 3 separate rows. Skips 47 garbage rows
--      with "BW"/"bw"/"Bw" (Broward shorthand misfiled as permit_number)
--      and "Not available" placeholders.
--   4. Auto-links 605 of 937 derm_manifests to their (unique) GDO where
--      the client has exactly one GDO. 14 multi-GDO manifests (Casa Neos)
--      stay NULL pending ops to pick Bar/Kitchen/Lounge via DERM Tracker.
--      317 manifests stay NULL because their clients are Broward-only
--      (yellow_ticket_number, no GDO).
--
-- 3NF check (Rule 2):
--   gdos.client_id depends only on the GDO (whole key) — OK.
--   derm_manifests.client_id IS transitively dependent on derm_manifests.gdo_id
--     via gdos.client_id, BUT we keep it during transition (nullable gdo_id
--     means we still need client_id as the only client pointer for ~330 rows).
--     Once Edge Function + DERM Tracker fully populate gdo_id, drop client_id
--     in a follow-up migration.
--
-- Audit (Rule 8): gdos has audit_gdos trigger (compliance + human-editable).
--   derm_manifests already audited — column add is auto-captured.
--
-- NEXT PHASES (NOT in this migration — separate work):
--   Phase 2: webhook-airtable Edge Function changes
--     - Resolve gdo_id from AT 'GDO Number (from Clients)' lookup
--     - For multi-GDO AT clients (Casa Neos BAR / Bar locations), map AT
--       Client GID to a specific GDO via a new entity_source_links row
--       (entity_type='gdo')
--   Phase 3: DERM Tracker UI changes
--     - Show location_label / GDO selector in visit detail
--     - Manifest entry form: GDO dropdown for multi-GDO clients
--     - Re-link orphan id 959 (Casa Neos BAR) once the BAR-specific GDO
--       is identified

BEGIN;

-- 1. Create public.gdos
CREATE TABLE public.gdos (
  id                    BIGSERIAL PRIMARY KEY,
  client_id             BIGINT NOT NULL REFERENCES public.clients(id) ON DELETE RESTRICT,
  gdo_number            TEXT   NOT NULL,
  location_label        TEXT,
  property_id           BIGINT REFERENCES public.properties(id) ON DELETE SET NULL,
  permit_expiration     DATE,
  permit_document_path  TEXT,
  status                TEXT NOT NULL DEFAULT 'ACTIVE'
                          CHECK (status IN ('ACTIVE', 'EXPIRED', 'INACTIVE')),
  notes                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT gdos_client_gdo_unique UNIQUE (client_id, gdo_number)
);

CREATE INDEX idx_gdos_client_id  ON public.gdos(client_id);
CREATE INDEX idx_gdos_gdo_number ON public.gdos(gdo_number);

CREATE TRIGGER trg_gdos_updated_at
  BEFORE UPDATE ON public.gdos
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER audit_gdos
  AFTER INSERT OR UPDATE OR DELETE ON public.gdos
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 2. derm_manifests.gdo_id
ALTER TABLE public.derm_manifests
  ADD COLUMN gdo_id BIGINT REFERENCES public.gdos(id) ON DELETE SET NULL;
CREATE INDEX idx_derm_manifests_gdo_id ON public.derm_manifests(gdo_id);

-- 3. Backfill gdos
INSERT INTO public.gdos (client_id, gdo_number, permit_expiration, permit_document_path)
SELECT
  sc.client_id,
  TRIM(unnested) AS gdo_number,
  sc.permit_expiration,
  sc.permit_document_path
FROM public.service_configs sc
CROSS JOIN LATERAL UNNEST(string_to_array(sc.permit_number, ',')) AS unnested
WHERE sc.permit_number IS NOT NULL
  AND TRIM(unnested) ILIKE 'GDO-%'
ON CONFLICT (client_id, gdo_number) DO NOTHING;

-- 4. Auto-link derm_manifests.gdo_id for single-GDO clients
UPDATE public.derm_manifests dm
SET gdo_id = sub.gdo_id
FROM (
  SELECT g.client_id, MIN(g.id) AS gdo_id
  FROM public.gdos g
  GROUP BY g.client_id
  HAVING COUNT(*) = 1
) sub
WHERE dm.client_id = sub.client_id AND dm.gdo_id IS NULL;

COMMIT;

-- Verification:
--   SELECT COUNT(*) FROM public.gdos;
--   -- expect 104 (102 single-GDO clients + 3 for Casa Neos - 1 for the
--   -- ON CONFLICT case)
--
--   SELECT gdo_number FROM public.gdos WHERE client_id=369 ORDER BY gdo_number;
--   -- expect GDO-10877, GDO-15062, GDO-16389
--
--   SELECT COUNT(*) FILTER (WHERE gdo_id IS NOT NULL) AS linked,
--          COUNT(*) FILTER (WHERE gdo_id IS NULL) AS unlinked
--   FROM public.derm_manifests;
--   -- expect linked=605, unlinked=332 (317 Broward + 14 multi-GDO + 1 orphan)
