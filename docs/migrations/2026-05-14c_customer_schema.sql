-- ====================================================================
-- Customer Portal — schema-per-app architecture (multi-app foundation)
-- ====================================================================
-- Creates a dedicated `customer` schema for Yannick's customer-facing
-- portal. Establishes the pattern for ALL future apps: each app reads
-- from canonical via views in its own schema; canonical stays clean.
--
-- This migration:
--   1. CREATE SCHEMA customer
--   2. Helper fns in customer (uuid_from_bigint, bigint_from_uuid)
--   3. 8 views in customer matching Yannick's existing app shapes
--      (so frontend code is unchanged; one supabase-js config line flips)
--   4. DROP the 2 prior compat views from public (moved here)
--   5. DROP the permissive portal_public_read RLS policies from public
--      canonical tables (apps should NOT query canonical directly)
--   6. GRANT USAGE/SELECT on customer to anon + authenticated
--   7. Owner = postgres → views run as owner (security_invoker=false),
--      so they bypass canonical RLS. The customer schema IS the access
--      boundary; tenant isolation lives in the app layer (cookie+slug).
--
-- After applying: Supabase Dashboard → Settings → API → Exposed schemas
-- → add `customer`. Then Lovable adds `{ db: { schema: 'customer' } }`
-- to its supabase-js client.
-- ====================================================================

BEGIN;

-- 1. Create the customer schema --------------------------------------
CREATE SCHEMA IF NOT EXISTS customer;
COMMENT ON SCHEMA customer IS
  'Customer-facing portal access layer. All views read from canonical (public). App-layer tenant isolation via encrypted cookie + slug guard. Anon role can SELECT views, not canonical.';


-- 2. Helper functions ------------------------------------------------
CREATE OR REPLACE FUNCTION customer.uuid_from_bigint(b bigint) RETURNS uuid
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT ('00000000-0000-0000-0000-' || lpad(b::text, 12, '0'))::uuid
$$;
COMMENT ON FUNCTION customer.uuid_from_bigint IS
  'Deterministic synthetic UUID from canonical BIGINT id. Frontend uses UUIDs; canonical uses BIGINTs. Reversible via customer.bigint_from_uuid.';

CREATE OR REPLACE FUNCTION customer.bigint_from_uuid(u uuid) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT NULLIF(right(replace(u::text, '-', ''), 12), '')::bigint
$$;
COMMENT ON FUNCTION customer.bigint_from_uuid IS
  'Reverse of customer.uuid_from_bigint. ONLY safe on UUIDs that came from customer.uuid_from_bigint.';


-- 3. Drop prior compat views from public (moving them here) ---------
DROP VIEW IF EXISTS public.vw_client_work_orders CASCADE;
DROP VIEW IF EXISTS public.vw_client_permits     CASCADE;


-- 4. Drop the permissive portal_public_read policies from canonical
-- (apps no longer query canonical directly — they go through their schema)
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'clients','client_contacts','properties','service_configs','visits',
    'visit_assignments','vehicles','employees','derm_manifests',
    'manifest_visits','inspections','photos','photo_links',
    'visit_recommendations','disposal_facilities','client_groups'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS portal_public_read ON public.%I', tbl);
  END LOOP;
END $$;


-- 5. Views in customer schema ----------------------------------------
-- All views use security_invoker=false (the default) so they run as the
-- view owner (postgres) and bypass RLS on the underlying canonical
-- tables. The customer schema IS the access boundary.

-- customer.clients
CREATE OR REPLACE VIEW customer.clients AS
SELECT
  customer.uuid_from_bigint(c.id) AS id,
  lower(c.client_code) AS slug,
  c.name,
  c.client_code,
  cg.name AS group_name,
  p.address AS address1,
  NULLIF(trim(both ' ,' FROM concat_ws(', ',
    NULLIF(p.city, ''),
    NULLIF(concat_ws(' ', NULLIF(p.state,''), NULLIF(p.zip,'')), '')
  )), '') AS address2,
  CASE WHEN sc_gt.equipment_size_gallons IS NOT NULL
    THEN sc_gt.equipment_size_gallons::text || ' gal grease trap'
  END AS container_type,
  CASE WHEN sc_gt.equipment_size_gallons IS NOT NULL
    THEN sc_gt.equipment_size_gallons::text || ' gal'
  END AS trap_capacity,
  sc_gt.material_type AS material,
  df.name AS disposal_facility,
  sc_gt.permit_document_path AS gdo_permit_url,
  p.access_notes,
  c.created_at
FROM public.clients c
LEFT JOIN public.client_groups cg ON cg.id = c.group_id
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = TRUE
LEFT JOIN public.service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'GT'
LEFT JOIN public.disposal_facilities df ON df.id = p.default_disposal_facility_id
WHERE c.status IN ('ACTIVE','RECURRING');

COMMENT ON VIEW customer.clients IS
  'Customer-portal-shaped client row. One row per active client. Slug = lower(client_code) for routing.';


-- customer.permits
CREATE OR REPLACE VIEW customer.permits AS
SELECT
  customer.uuid_from_bigint(sc.id) AS id,
  customer.uuid_from_bigint(sc.client_id) AS client_id,
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
  sc.permit_document_path AS permit_url,
  (ROW_NUMBER() OVER (PARTITION BY sc.client_id ORDER BY sc.service_type, sc.id) - 1)::integer AS position
FROM public.service_configs sc
JOIN public.clients c ON c.id = sc.client_id
WHERE sc.permit_number IS NOT NULL
  AND sc.permit_number <> ''
  AND c.status IN ('ACTIVE','RECURRING');


-- customer.scheduled_visits
CREATE OR REPLACE VIEW customer.scheduled_visits AS
SELECT
  customer.uuid_from_bigint(v.id) AS id,
  customer.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date AS scheduled_date,
  NULL::text AS scheduled_window,
  v.service_type,
  v.title AS notes,
  v.visit_status AS status,
  v.created_at
FROM public.visits v
WHERE v.visit_status = 'scheduled'
  AND v.client_id IS NOT NULL;


-- customer.work_orders
CREATE OR REPLACE VIEW customer.work_orders AS
SELECT
  customer.uuid_from_bigint(v.id) AS id,
  customer.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date,
  CASE WHEN v.start_at IS NOT NULL
    THEN to_char(v.start_at AT TIME ZONE 'America/New_York', 'FMHH12:MI AM')
  END AS visit_time,
  (SELECT string_agg(e.full_name, ', ' ORDER BY e.full_name)
     FROM public.visit_assignments va
     JOIN public.employees e ON e.id = va.employee_id
    WHERE va.visit_id = v.id) AS driver,
  veh.name AS truck,
  veh.decal_number AS decal,
  v.manhole_count AS manholes,  -- NULL = "—" (not recorded), 0 = real zero. Don't fall back to property's total (that's a different concept: site total, not per-visit serviced).
  v.manhole_breakdown,
  v.ticket_number,
  v.trap_condition_notes AS trap_condition,
  ROW_NUMBER() OVER (
    PARTITION BY v.client_id, EXTRACT(YEAR FROM v.visit_date)
    ORDER BY v.visit_date
  )::integer AS visit_num,
  (SELECT
     CASE WHEN sc.frequency_days IS NULL THEN NULL
          ELSE GREATEST(1, ROUND(365.0 / sc.frequency_days))::integer
     END
   FROM public.service_configs sc
   WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
   LIMIT 1) AS visit_total,
  v.title AS notes,
  dm.white_manifest_number AS derm_manifest_number,
  NULL::text AS derm_manifest_url,
  dm.wwtp_receipt_number,
  dm.wwtp_receipt_document_path AS wwtp_receipt_url,
  dm.wwtp_ticket_number,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at
FROM public.visits v
LEFT JOIN public.vehicles veh ON veh.id = v.vehicle_id
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


-- customer.wo_photos
CREATE OR REPLACE VIEW customer.wo_photos AS
SELECT
  customer.uuid_from_bigint(pl.id) AS id,
  customer.uuid_from_bigint(pl.entity_id) AS work_order_id,
  COALESCE(NULLIF(pl.role, ''), 'after') AS variant,
  ph.storage_path AS url,
  pl.caption,
  (ROW_NUMBER() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS position
FROM public.photo_links pl
JOIN public.photos ph ON ph.id = pl.photo_id
WHERE pl.entity_type = 'visit';


-- customer.client_access_photos
CREATE OR REPLACE VIEW customer.client_access_photos AS
WITH resolved AS (
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
  customer.uuid_from_bigint(link_id) AS id,
  customer.uuid_from_bigint(client_id_resolved) AS client_id,
  storage_path AS url,
  caption,
  (ROW_NUMBER() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1)::integer AS position,
  created_at
FROM resolved
WHERE client_id_resolved IS NOT NULL;


-- customer.inspection_items
-- Explodes canonical inspections (POST only) into per-check rows.
-- Inspections link to visits by (vehicle_id, shift_date) match.
-- Currently maps the 2 canonical boolean checks; richer checklist
-- requires adding more canonical inspection columns (Option B in audit).
CREATE OR REPLACE VIEW customer.inspection_items AS
WITH iv AS (
  SELECT
    i.id, i.is_valve_closed, i.has_issue, i.issue_note,
    (SELECT v.id FROM public.visits v
      WHERE v.vehicle_id = i.vehicle_id AND v.visit_date = i.shift_date
      ORDER BY (v.visit_status = 'completed') DESC, v.id
      LIMIT 1) AS visit_id
  FROM public.inspections i
  WHERE i.inspection_type = 'POST'
)
SELECT id, work_order_id, label, value, is_positive, position FROM (
  SELECT
    md5('insp-valve-' || iv.id::text)::uuid AS id,
    customer.uuid_from_bigint(iv.visit_id) AS work_order_id,
    'Valve closed' AS label,
    COALESCE(iv.is_valve_closed, FALSE) AS value,
    TRUE AS is_positive,
    0 AS position
  FROM iv WHERE iv.visit_id IS NOT NULL AND iv.is_valve_closed IS NOT NULL
  UNION ALL
  SELECT
    md5('insp-issue-' || iv.id::text)::uuid,
    customer.uuid_from_bigint(iv.visit_id),
    CASE WHEN iv.has_issue
         THEN COALESCE(iv.issue_note, 'Issue reported')
         ELSE 'No issues' END,
    NOT COALESCE(iv.has_issue, FALSE),
    TRUE,
    1
  FROM iv WHERE iv.visit_id IS NOT NULL AND iv.has_issue IS NOT NULL
) sub;


-- customer.recommendations
CREATE OR REPLACE VIEW customer.recommendations AS
SELECT
  customer.uuid_from_bigint(vr.id) AS id,
  customer.uuid_from_bigint(vr.visit_id) AS work_order_id,
  vr.label,
  vr.is_needed AS needed,
  vr.position
FROM public.visit_recommendations vr;


-- 6. Grants ----------------------------------------------------------
GRANT USAGE ON SCHEMA customer TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION customer.uuid_from_bigint(bigint) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION customer.bigint_from_uuid(uuid)   TO authenticated, service_role;
GRANT SELECT ON
  customer.clients,
  customer.permits,
  customer.scheduled_visits,
  customer.work_orders,
  customer.wo_photos,
  customer.client_access_photos,
  customer.inspection_items,
  customer.recommendations
TO anon, authenticated, service_role;
-- service_role is required for server-fn `loginWithCode` calls (Yannick's
-- pattern uses the service-role admin client for the client_code lookup).
-- Without this grant, "Lookup failed: permission denied for view clients".

COMMIT;
