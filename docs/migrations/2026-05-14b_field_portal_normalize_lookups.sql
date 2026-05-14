-- ====================================================================
-- Field Portal additions — normalize text lookups into canonical tables
-- ====================================================================
-- Follow-up to 2026-05-14_field_portal_canonical_additions.sql.
--
-- The first migration introduced 3 free-text columns that violate
-- rule 6 (reference all data; never copy):
--   - clients.group_name              (multiple clients share "Pura Vida")
--   - properties.default_disposal_facility (2 known sites repeat across all properties)
--   - derm_manifests.disposal_facility     (same 2 sites repeat per manifest)
--
-- This migration:
--   1. Creates canonical lookup tables `client_groups` and `disposal_facilities`
--   2. Drops the 3 denormalized TEXT columns (safe — no app reads them yet)
--   3. Adds FK columns alongside (_id BIGINT REFERENCES lookup_table)
--   4. Seeds the 2 known disposal facilities (Homestead Dump, SD-WWTP)
--   5. Updates vw_client_work_orders to JOIN through to facility name
--
-- Idempotent + additive forward (drops are guarded by IF EXISTS on
-- columns that only existed since the prior migration, so re-running
-- is safe).
-- ====================================================================

BEGIN;

-- 0. Drop dependent view so we can ALTER the underlying columns. -----
-- Recreated at the end of this migration with the new JOIN path.
DROP VIEW IF EXISTS public.vw_client_work_orders;


-- 1. Canonical lookup table: disposal_facilities ----------------------
CREATE TABLE IF NOT EXISTS public.disposal_facilities (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  name            text NOT NULL UNIQUE,
  facility_type   text NOT NULL CHECK (facility_type IN ('DERM','WWTP','DUMP','OTHER')),
  address         text,
  city            text,
  state           text,
  zip             text,
  latitude        numeric,
  longitude       numeric,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE public.disposal_facilities IS
  'Canonical lookup for waste disposal facilities (DUMP sites, WWTP plants, etc.). FKd from properties.default_disposal_facility_id and derm_manifests.disposal_facility_id.';

DROP TRIGGER IF EXISTS disposal_facilities_touch_updated_at ON public.disposal_facilities;
CREATE TRIGGER disposal_facilities_touch_updated_at
  BEFORE UPDATE ON public.disposal_facilities
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- 2. Canonical lookup table: client_groups ----------------------------
CREATE TABLE IF NOT EXISTS public.client_groups (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  name        text NOT NULL UNIQUE,
  notes       text,
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  updated_at  timestamptz NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE public.client_groups IS
  'Canonical lookup for brand / corporate parent (e.g. "Pura Vida" parent of 12 PV locations). FKd from clients.group_id. Future-expandable for logo, billing contact, contract terms, etc.';

DROP TRIGGER IF EXISTS client_groups_touch_updated_at ON public.client_groups;
CREATE TRIGGER client_groups_touch_updated_at
  BEFORE UPDATE ON public.client_groups
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- 3. Replace denormalized TEXT cols with FK cols ----------------------
ALTER TABLE public.clients
  DROP COLUMN IF EXISTS group_name,
  ADD COLUMN IF NOT EXISTS group_id bigint REFERENCES public.client_groups(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.clients.group_id IS
  'Optional FK to client_groups for brand/parent grouping. NULL when the client has no group.';

CREATE INDEX IF NOT EXISTS idx_clients_group_id ON public.clients(group_id) WHERE group_id IS NOT NULL;

ALTER TABLE public.properties
  DROP COLUMN IF EXISTS default_disposal_facility,
  ADD COLUMN IF NOT EXISTS default_disposal_facility_id bigint REFERENCES public.disposal_facilities(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.properties.default_disposal_facility_id IS
  'FK to disposal_facilities. Default dump site for this property''s waste. Per-manifest override lives in derm_manifests.disposal_facility_id.';

CREATE INDEX IF NOT EXISTS idx_properties_disposal_fac ON public.properties(default_disposal_facility_id) WHERE default_disposal_facility_id IS NOT NULL;

ALTER TABLE public.derm_manifests
  DROP COLUMN IF EXISTS disposal_facility,
  ADD COLUMN IF NOT EXISTS disposal_facility_id bigint REFERENCES public.disposal_facilities(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.derm_manifests.disposal_facility_id IS
  'FK to disposal_facilities. Which dump site was used for this specific manifest.';

CREATE INDEX IF NOT EXISTS idx_manifests_disposal_fac ON public.derm_manifests(disposal_facility_id) WHERE disposal_facility_id IS NOT NULL;


-- 4. Seed known disposal facilities (per memory: 2 sites known today)
INSERT INTO public.disposal_facilities (name, facility_type, latitude, longitude, status, notes)
VALUES
  ('Homestead Dump',      'DUMP', 25.5473, -80.3435, 'ACTIVE', 'Primary southern dump site for grease-trap waste.'),
  ('South District WWTP', 'WWTP', 25.5509, -80.3470, 'ACTIVE', 'Wastewater treatment plant, ~5 min north of Homestead Dump.')
ON CONFLICT (name) DO NOTHING;


-- 5. RLS + grants on new lookup tables --------------------------------
DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['disposal_facilities', 'client_groups'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('DROP POLICY IF EXISTS portal_public_read ON public.%I', tbl);
    EXECUTE format(
      'CREATE POLICY portal_public_read ON public.%I FOR SELECT TO anon, authenticated USING (true)',
      tbl
    );
  END LOOP;
END $$;

GRANT SELECT ON public.disposal_facilities, public.client_groups TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.disposal_facilities, public.client_groups TO service_role;


-- 6. Update vw_client_work_orders to JOIN through to facility name ---
-- Same column shape as before — the view still exposes disposal_facility as
-- a text NAME (joined through the FK). Adds disposal_facility_id for clients
-- that want the FK itself.
CREATE OR REPLACE VIEW public.vw_client_work_orders
WITH (security_invoker = true) AS
SELECT
  v.id,
  v.client_id,
  v.visit_date,
  v.service_type,
  CASE WHEN v.start_at IS NOT NULL
       THEN to_char(v.start_at AT TIME ZONE 'America/New_York', 'FMHH12:MI AM')
  END AS visit_time,
  v.start_at,
  v.completed_at,
  v.duration_minutes,
  (
    SELECT string_agg(e.full_name, ', ' ORDER BY e.full_name)
      FROM public.visit_assignments va
      JOIN public.employees e ON e.id = va.employee_id
     WHERE va.visit_id = v.id
  ) AS driver,
  veh.id      AS vehicle_id,
  veh.name    AS truck,
  veh.decal_number AS decal,
  COALESCE(v.manhole_count, prop.grease_trap_manhole_count) AS manholes,
  v.manhole_breakdown,
  v.ticket_number,
  v.trap_condition_notes,
  v.title     AS notes,
  dm.white_manifest_number       AS derm_manifest_number,
  dm.yellow_ticket_number        AS derm_ticket_number,
  dm.wwtp_receipt_number,
  dm.wwtp_receipt_document_path,
  dm.wwtp_ticket_number,
  COALESCE(df_manifest.name, df_property.name) AS disposal_facility,
  COALESCE(dm.disposal_facility_id, prop.default_disposal_facility_id) AS disposal_facility_id,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at
FROM public.visits v
LEFT JOIN public.vehicles   veh  ON veh.id  = v.vehicle_id
LEFT JOIN public.properties prop ON prop.id = v.property_id
LEFT JOIN public.disposal_facilities df_property ON df_property.id = prop.default_disposal_facility_id
LEFT JOIN LATERAL (
  SELECT dm_inner.*
    FROM public.derm_manifests dm_inner
    JOIN public.manifest_visits mv ON mv.manifest_id = dm_inner.id
   WHERE mv.visit_id = v.id
   ORDER BY dm_inner.service_date DESC NULLS LAST
   LIMIT 1
) dm ON TRUE
LEFT JOIN public.disposal_facilities df_manifest ON df_manifest.id = dm.disposal_facility_id
WHERE v.visit_status = 'completed'
  AND v.client_id IS NOT NULL;

COMMIT;
