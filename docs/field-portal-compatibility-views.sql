-- ====================================================================
-- Field Portal Sandbox — Compatibility view layer
-- ====================================================================
-- Lets Yannick's existing Lovable customer-portal frontend keep its
-- column shapes while source-of-truth lives in the canonical 27-table
-- schema. Apply this to Field Portal Sandbox (klgtrdwrasrlxbmfyvdh)
-- only. NOT for Prod — that's a separate migration cycle.
--
-- Architecture (after apply):
--   public.clients          = VIEW reshaping clients_canonical + property + service_config
--   public.permits          = VIEW over service_configs (permit_number IS NOT NULL)
--   public.scheduled_visits = VIEW over visits WHERE visit_status='scheduled'
--   public.work_orders      = VIEW over visits WHERE visit_status='completed' + joins
--   public.wo_photos        = VIEW over photos + photo_links (entity_type='visit')
--   public.client_access_photos = VIEW over photos + photo_links (entity_type='client'|'property')
--   public.inspection_items = VIEW exploding inspections rows into items
--   public.recommendations  = empty VIEW (no canonical equivalent yet)
--
--   public.clients_canonical = canonical clients table (renamed FROM public.clients)
--   public.visits, .properties, .service_configs, .vehicles, ...  = canonical tables
--
-- IDs: canonical uses BIGINT identity; frontend expects UUIDs.
-- portal.uuid_from_bigint(b) synthesizes a deterministic UUID. Reversible
-- via portal.bigint_from_uuid(u) for server-side writes.
-- ====================================================================

BEGIN;

-- 0. Helper functions ---------------------------------------------------
CREATE SCHEMA IF NOT EXISTS portal;

CREATE OR REPLACE FUNCTION portal.uuid_from_bigint(b bigint) RETURNS uuid
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT ('00000000-0000-0000-0000-' || lpad(b::text, 12, '0'))::uuid
$$;
COMMENT ON FUNCTION portal.uuid_from_bigint IS
  'Synthetic UUID from canonical BIGINT id. Reversible via portal.bigint_from_uuid.';

CREATE OR REPLACE FUNCTION portal.bigint_from_uuid(u uuid) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT NULLIF(right(replace(u::text, '-', ''), 12), '')::bigint
$$;
COMMENT ON FUNCTION portal.bigint_from_uuid IS
  'Reverse of portal.uuid_from_bigint. Returns the BIGINT id encoded in a synthetic UUID. ONLY safe on UUIDs that came from portal.uuid_from_bigint.';


-- 1. Rename canonical clients to avoid name conflict with the view -------
ALTER TABLE IF EXISTS public.clients RENAME TO clients_canonical;


-- 2. Permissive public read on canonical tables the views read from -----
-- (matches Yannick's existing portal RLS pattern: public read everywhere)
DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'clients_canonical', 'client_contacts', 'properties', 'service_configs',
    'visits', 'visit_assignments', 'vehicles', 'employees',
    'derm_manifests', 'manifest_visits', 'inspections',
    'photos', 'photo_links', 'entity_source_links'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('DROP POLICY IF EXISTS portal_public_read ON public.%I', tbl);
    EXECUTE format(
      'CREATE POLICY portal_public_read ON public.%I FOR SELECT TO anon, authenticated USING (true)',
      tbl
    );
  END LOOP;
END $$;


-- 3. Compatibility views ------------------------------------------------

-- public.clients
CREATE OR REPLACE VIEW public.clients
WITH (security_invoker = true) AS
SELECT
  portal.uuid_from_bigint(c.id) AS id,
  lower(c.client_code) AS slug,
  c.name,
  c.client_code,
  NULL::text AS group_name,
  p.address AS address1,
  CASE
    WHEN p.city IS NOT NULL OR p.state IS NOT NULL OR p.zip IS NOT NULL
    THEN trim(concat_ws(' ',
      trim(both ', ' FROM concat_ws(', ', NULLIF(p.city, ''), NULLIF(p.state, ''))),
      NULLIF(p.zip, '')
    ))
  END AS address2,
  CASE
    WHEN sc_gt.equipment_size_gallons IS NOT NULL
    THEN sc_gt.equipment_size_gallons::text || ' gal grease trap'
  END AS container_type,
  CASE
    WHEN sc_gt.equipment_size_gallons IS NOT NULL
    THEN sc_gt.equipment_size_gallons::text || ' gal'
  END AS trap_capacity,
  NULL::text AS material,
  NULL::text AS disposal_facility,
  NULL::text AS gdo_permit_url,
  CASE
    WHEN p.access_hours_start IS NOT NULL OR p.access_hours_end IS NOT NULL THEN
      'Access ' || COALESCE(p.access_hours_start, '00:00') || '-' || COALESCE(p.access_hours_end, '24:00') ||
      CASE WHEN p.access_days IS NOT NULL AND array_length(p.access_days, 1) > 0
           THEN ' on ' || array_to_string(p.access_days, ', ')
           ELSE '' END
  END AS access_notes,
  c.created_at
FROM public.clients_canonical c
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = TRUE
LEFT JOIN public.service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'GT'
WHERE c.status IN ('ACTIVE', 'RECURRING');


-- public.permits
CREATE OR REPLACE VIEW public.permits
WITH (security_invoker = true) AS
SELECT
  portal.uuid_from_bigint(sc.id) AS id,
  portal.uuid_from_bigint(sc.client_id) AS client_id,
  sc.permit_number,
  CASE sc.service_type
    WHEN 'GT' THEN 'Grease Trap'
    WHEN 'CL' THEN 'Cleaning'
    WHEN 'WD' THEN 'Water Discharge'
    WHEN 'LS' THEN 'Lift Station'
  END AS area,
  CASE
    WHEN sc.frequency_days IS NULL THEN NULL
    WHEN sc.frequency_days <= 35  THEN 'Monthly'
    WHEN sc.frequency_days <= 95  THEN 'Quarterly'
    WHEN sc.frequency_days <= 185 THEN 'Semi-annually'
    WHEN sc.frequency_days <= 380 THEN 'Annually'
    ELSE 'Every ' || sc.frequency_days || ' days'
  END AS frequency,
  NULL::text AS permit_url,
  (ROW_NUMBER() OVER (PARTITION BY sc.client_id ORDER BY sc.service_type, sc.id) - 1)::integer AS position
FROM public.service_configs sc
JOIN public.clients_canonical c ON c.id = sc.client_id
WHERE sc.permit_number IS NOT NULL
  AND sc.permit_number <> ''
  AND c.status IN ('ACTIVE', 'RECURRING');


-- public.scheduled_visits
CREATE OR REPLACE VIEW public.scheduled_visits
WITH (security_invoker = true) AS
SELECT
  portal.uuid_from_bigint(v.id) AS id,
  portal.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date AS scheduled_date,
  NULL::text AS scheduled_window,
  v.service_type,
  v.title AS notes,
  v.visit_status AS status,
  v.created_at
FROM public.visits v
WHERE v.visit_status = 'scheduled'
  AND v.client_id IS NOT NULL;


-- public.work_orders
CREATE OR REPLACE VIEW public.work_orders
WITH (security_invoker = true) AS
SELECT
  portal.uuid_from_bigint(v.id) AS id,
  portal.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date,
  CASE WHEN v.start_at IS NOT NULL
    THEN to_char(v.start_at AT TIME ZONE 'America/New_York', 'FMHH12:MI AM')
  END AS visit_time,
  (
    SELECT string_agg(e.full_name, ', ' ORDER BY e.full_name)
    FROM public.visit_assignments va
    JOIN public.employees e ON e.id = va.employee_id
    WHERE va.visit_id = v.id
  ) AS driver,
  veh.name AS truck,
  NULL::text AS decal,
  prop.grease_trap_manhole_count AS manholes,
  NULL::text AS manhole_breakdown,
  NULL::text AS ticket_number,
  NULL::text AS trap_condition,
  NULL::integer AS visit_num,
  NULL::integer AS visit_total,
  v.title AS notes,
  (
    SELECT dm.white_manifest_number FROM public.derm_manifests dm
    JOIN public.manifest_visits mv ON mv.manifest_id = dm.id
    WHERE mv.visit_id = v.id
    ORDER BY dm.service_date DESC NULLS LAST LIMIT 1
  ) AS derm_manifest_number,
  NULL::text AS derm_manifest_url,
  (
    SELECT dm.yellow_ticket_number FROM public.derm_manifests dm
    JOIN public.manifest_visits mv ON mv.manifest_id = dm.id
    WHERE mv.visit_id = v.id
    ORDER BY dm.dump_ticket_date DESC NULLS LAST LIMIT 1
  ) AS wwtp_receipt_number,
  NULL::text AS wwtp_receipt_url,
  NULL::text AS wwtp_ticket_number,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at
FROM public.visits v
LEFT JOIN public.vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN public.properties prop ON prop.id = v.property_id
WHERE v.visit_status = 'completed'
  AND v.client_id IS NOT NULL;


-- public.wo_photos
CREATE OR REPLACE VIEW public.wo_photos
WITH (security_invoker = true) AS
SELECT
  portal.uuid_from_bigint(pl.id) AS id,
  portal.uuid_from_bigint(pl.entity_id) AS work_order_id,
  COALESCE(NULLIF(pl.role, ''), 'after') AS variant,
  ph.storage_path AS url,
  pl.caption,
  (ROW_NUMBER() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS position
FROM public.photo_links pl
JOIN public.photos ph ON ph.id = pl.photo_id
WHERE pl.entity_type = 'visit';


-- public.client_access_photos
CREATE OR REPLACE VIEW public.client_access_photos
WITH (security_invoker = true) AS
WITH client_resolved AS (
  SELECT
    pl.id AS link_id,
    pl.caption,
    ph.storage_path,
    ph.created_at,
    COALESCE(
      CASE WHEN pl.entity_type = 'client' THEN pl.entity_id END,
      p.client_id
    ) AS client_id_resolved
  FROM public.photo_links pl
  JOIN public.photos ph ON ph.id = pl.photo_id
  LEFT JOIN public.properties p ON p.id = pl.entity_id AND pl.entity_type = 'property'
  WHERE pl.entity_type IN ('client', 'property')
)
SELECT
  portal.uuid_from_bigint(link_id) AS id,
  portal.uuid_from_bigint(client_id_resolved) AS client_id,
  storage_path AS url,
  caption,
  (ROW_NUMBER() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1)::integer AS position
FROM client_resolved
WHERE client_id_resolved IS NOT NULL;


-- public.inspection_items
-- Explode each POST inspection into per-check rows. Inspections are
-- linked to visits via vehicle_id + shift_date (no direct FK in canonical).
CREATE OR REPLACE VIEW public.inspection_items
WITH (security_invoker = true) AS
WITH iv AS (
  SELECT
    i.id,
    i.is_valve_closed,
    i.has_issue,
    i.issue_note,
    (
      SELECT v.id FROM public.visits v
      WHERE v.vehicle_id = i.vehicle_id
        AND v.visit_date = i.shift_date
      ORDER BY (v.visit_status = 'completed') DESC, v.id
      LIMIT 1
    ) AS visit_id
  FROM public.inspections i
  WHERE i.inspection_type = 'POST'
)
SELECT id, work_order_id, label, value, is_positive, position FROM (
  SELECT
    md5('insp-valve-' || iv.id::text)::uuid AS id,
    portal.uuid_from_bigint(iv.visit_id) AS work_order_id,
    'Valve closed' AS label,
    COALESCE(iv.is_valve_closed, FALSE) AS value,
    TRUE AS is_positive,
    0 AS position
  FROM iv
  WHERE iv.visit_id IS NOT NULL AND iv.is_valve_closed IS NOT NULL

  UNION ALL

  SELECT
    md5('insp-issue-' || iv.id::text)::uuid AS id,
    portal.uuid_from_bigint(iv.visit_id) AS work_order_id,
    CASE WHEN iv.has_issue THEN COALESCE(iv.issue_note, 'Issue reported')
         ELSE 'No issues' END AS label,
    NOT COALESCE(iv.has_issue, FALSE) AS value,
    TRUE AS is_positive,
    1 AS position
  FROM iv
  WHERE iv.visit_id IS NOT NULL AND iv.has_issue IS NOT NULL
) sub;


-- public.recommendations (empty until canonical equivalent exists)
CREATE OR REPLACE VIEW public.recommendations
WITH (security_invoker = true) AS
SELECT
  NULL::uuid AS id,
  NULL::uuid AS work_order_id,
  NULL::text AS label,
  NULL::boolean AS needed,
  NULL::integer AS position
WHERE FALSE;


-- 4. Grants -------------------------------------------------------------
GRANT USAGE ON SCHEMA portal TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal.uuid_from_bigint(bigint) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal.bigint_from_uuid(uuid)   TO authenticated, service_role;

GRANT SELECT ON
  public.clients,
  public.permits,
  public.scheduled_visits,
  public.work_orders,
  public.wo_photos,
  public.client_access_photos,
  public.inspection_items,
  public.recommendations
TO anon, authenticated;

COMMIT;

-- 5. Verify -------------------------------------------------------------
-- Run after the commit to confirm the views return data:
--   SELECT 'clients'             AS view, COUNT(*) AS n FROM public.clients
--   UNION ALL SELECT 'permits',           COUNT(*) FROM public.permits
--   UNION ALL SELECT 'scheduled_visits',  COUNT(*) FROM public.scheduled_visits
--   UNION ALL SELECT 'work_orders',       COUNT(*) FROM public.work_orders
--   UNION ALL SELECT 'wo_photos',         COUNT(*) FROM public.wo_photos
--   UNION ALL SELECT 'client_access_photos', COUNT(*) FROM public.client_access_photos
--   UNION ALL SELECT 'inspection_items',  COUNT(*) FROM public.inspection_items
--   UNION ALL SELECT 'recommendations',   COUNT(*) FROM public.recommendations;
