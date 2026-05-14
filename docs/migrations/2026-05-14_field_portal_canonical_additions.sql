-- ====================================================================
-- Field Portal — canonical schema additions
-- ====================================================================
-- Add the canonical columns + tables needed so Yannick's customer
-- portal can query our DB directly (instead of his denormalized Lovable
-- Cloud shapes). Apply to Field Portal Sandbox (klgtrdwrasrlxbmfyvdh)
-- first. Same migration applies cleanly to Prod later — it's additive
-- only, no drops or renames.
--
-- All additions follow CLAUDE.md rules:
--   - 3NF (each column depends on the row's PK, nothing else)
--   - Source-agnostic naming (no jobber_*/airtable_* prefixes)
--   - TIMESTAMPTZ for time, NUMERIC for money (n/a here)
--   - Idempotent (IF NOT EXISTS / CREATE OR REPLACE)
-- ====================================================================

BEGIN;

-- 1. ALTER existing canonical tables (additive columns) -----------------

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS group_name text;
COMMENT ON COLUMN public.clients.group_name IS
  'Corporate parent / brand grouping (e.g. "Pura Vida" for the 12 PV locations). Free-form, no FK.';

ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS default_disposal_facility text,
  ADD COLUMN IF NOT EXISTS access_notes              text;
COMMENT ON COLUMN public.properties.default_disposal_facility IS
  'Typical dump site for this property''s waste. Override per-manifest in derm_manifests.disposal_facility. Free-form (e.g. "Homestead Dump", "SD-WWTP").';
COMMENT ON COLUMN public.properties.access_notes IS
  'Free-form access instructions beyond the structured access_hours_* / access_days fields.';

ALTER TABLE public.service_configs
  ADD COLUMN IF NOT EXISTS material_type           text,
  ADD COLUMN IF NOT EXISTS permit_document_path    text;
COMMENT ON COLUMN public.service_configs.material_type IS
  'Type of waste the GT/CL/LS service handles, e.g. "FOG", "wastewater", "gray water". Free-form for now; promote to CHECK constraint when values stabilize.';
COMMENT ON COLUMN public.service_configs.permit_document_path IS
  'Supabase Storage path to the permit PDF (e.g. "permits/<client_code>/gdo.pdf"). Browser builds the public URL from this.';

ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS decal_number text;
COMMENT ON COLUMN public.vehicles.decal_number IS
  'DERM/permit sticker number affixed to the truck. Displayed to customers on the work-order detail.';

ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS manhole_count        integer,
  ADD COLUMN IF NOT EXISTS manhole_breakdown    text,
  ADD COLUMN IF NOT EXISTS ticket_number        text,
  ADD COLUMN IF NOT EXISTS trap_condition_notes text;
COMMENT ON COLUMN public.visits.manhole_count IS
  'Per-visit count of manholes serviced. Differs from properties.grease_trap_manhole_count (the total at the property) — a visit may service only some manholes.';
COMMENT ON COLUMN public.visits.manhole_breakdown IS
  'Per-visit free-form notes on which manholes were serviced and observations.';
COMMENT ON COLUMN public.visits.ticket_number IS
  'Internal job-side ticket number; complementary to job_id / invoice_id which are FK references.';
COMMENT ON COLUMN public.visits.trap_condition_notes IS
  'Driver assessment of trap state for this visit (e.g. "heavy grease, baffle damaged").';

ALTER TABLE public.derm_manifests
  ADD COLUMN IF NOT EXISTS wwtp_receipt_number        text,
  ADD COLUMN IF NOT EXISTS wwtp_receipt_document_path text,
  ADD COLUMN IF NOT EXISTS wwtp_ticket_number         text,
  ADD COLUMN IF NOT EXISTS disposal_facility          text;
COMMENT ON COLUMN public.derm_manifests.wwtp_receipt_number IS
  'WWTP-side disposal receipt number, complementary to white_manifest_number (which is the DERM document) and yellow_ticket_number (the dump-side ticket).';
COMMENT ON COLUMN public.derm_manifests.wwtp_receipt_document_path IS
  'Supabase Storage path to the WWTP receipt PDF.';
COMMENT ON COLUMN public.derm_manifests.disposal_facility IS
  'Which dump site was used for this manifest (overrides properties.default_disposal_facility for this specific visit).';


-- 2. NEW canonical table: visit_recommendations -----------------------
CREATE TABLE IF NOT EXISTS public.visit_recommendations (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  visit_id    bigint NOT NULL REFERENCES public.visits(id) ON DELETE CASCADE,
  label       text   NOT NULL,
  is_needed   boolean NOT NULL DEFAULT FALSE,
  position    integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  updated_at  timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (visit_id, label)
);
COMMENT ON TABLE public.visit_recommendations IS
  'Per-visit follow-up recommendations from the field operator (e.g. "Replace baffle", "Schedule additional pumping"). Surfaced to the client in the customer portal.';

CREATE INDEX IF NOT EXISTS idx_visit_recommendations_visit_id
  ON public.visit_recommendations(visit_id);

-- Shared updated_at trigger function (idempotent)
CREATE OR REPLACE FUNCTION public.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS visit_recommendations_touch_updated_at ON public.visit_recommendations;
CREATE TRIGGER visit_recommendations_touch_updated_at
  BEFORE UPDATE ON public.visit_recommendations
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- 3. Convenience views (read-optimized for the customer portal) -------

-- vw_client_work_orders: one row per completed visit, pre-joined.
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
  COALESCE(dm.disposal_facility, prop.default_disposal_facility) AS disposal_facility,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at
FROM public.visits v
LEFT JOIN public.vehicles   veh  ON veh.id  = v.vehicle_id
LEFT JOIN public.properties prop ON prop.id = v.property_id
LEFT JOIN LATERAL (
  SELECT dm_inner.*
    FROM public.derm_manifests dm_inner
    JOIN public.manifest_visits mv ON mv.manifest_id = dm_inner.id
   WHERE mv.visit_id = v.id
   ORDER BY dm_inner.service_date DESC NULLS LAST
   LIMIT 1
) dm ON TRUE
WHERE v.visit_status = 'completed'
  AND v.client_id IS NOT NULL;

COMMENT ON VIEW public.vw_client_work_orders IS
  'One row per completed visit, with truck/driver/DERM/disposal pre-resolved. Use for the customer portal''s work-order list and detail pages.';

-- vw_client_permits: one row per active permit (GT only today, generalizable).
CREATE OR REPLACE VIEW public.vw_client_permits
WITH (security_invoker = true) AS
SELECT
  sc.id,
  sc.client_id,
  sc.service_type,
  CASE sc.service_type
    WHEN 'GT' THEN 'Grease Trap'
    WHEN 'CL' THEN 'Cleaning'
    WHEN 'WD' THEN 'Water Discharge'
    WHEN 'LS' THEN 'Lift Station'
  END AS service_label,
  sc.permit_number,
  sc.permit_expiration,
  sc.frequency_days,
  CASE
    WHEN sc.frequency_days IS NULL THEN NULL
    WHEN sc.frequency_days <= 35   THEN 'Monthly'
    WHEN sc.frequency_days <= 95   THEN 'Quarterly'
    WHEN sc.frequency_days <= 185  THEN 'Semi-annually'
    WHEN sc.frequency_days <= 380  THEN 'Annually'
    ELSE 'Every ' || sc.frequency_days || ' days'
  END AS frequency_label,
  sc.equipment_size_gallons,
  sc.material_type,
  sc.permit_document_path
FROM public.service_configs sc
JOIN public.clients c ON c.id = sc.client_id
WHERE sc.permit_number IS NOT NULL
  AND sc.permit_number <> ''
  AND c.status IN ('ACTIVE', 'RECURRING');

COMMENT ON VIEW public.vw_client_permits IS
  'One row per active permit, with frequency label pre-computed. Use for the customer portal''s Permits section.';


-- 4. RLS: permissive public read on canonical tables the portal queries
DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'clients', 'client_contacts', 'properties', 'service_configs',
    'visits', 'visit_assignments', 'vehicles', 'employees',
    'derm_manifests', 'manifest_visits', 'inspections',
    'photos', 'photo_links', 'visit_recommendations'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('DROP POLICY IF EXISTS portal_public_read ON public.%I', tbl);
    EXECUTE format(
      'CREATE POLICY portal_public_read ON public.%I FOR SELECT TO anon, authenticated USING (true)',
      tbl
    );
  END LOOP;
END $$;


-- 5. Grants -----------------------------------------------------------
GRANT SELECT ON
  public.vw_client_work_orders,
  public.vw_client_permits,
  public.visit_recommendations
TO anon, authenticated;

GRANT INSERT, UPDATE, DELETE ON public.visit_recommendations TO service_role;

COMMIT;

-- 6. Verify -----------------------------------------------------------
-- Run after commit:
--   SELECT COUNT(*) FROM public.vw_client_work_orders;
--   SELECT COUNT(*) FROM public.vw_client_permits;
--   SELECT column_name FROM information_schema.columns
--     WHERE table_schema='public' AND table_name='visits'
--       AND column_name IN ('manhole_count','manhole_breakdown','ticket_number','trap_condition_notes');
