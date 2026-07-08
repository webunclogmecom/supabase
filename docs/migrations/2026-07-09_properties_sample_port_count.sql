-- 2026-07-09 — Add properties.sample_port_count + expose customer.work_orders.sample_ports
--
-- WHY: Yan asked for a "Sample Port #" field on the Field Portal visit page, directly
-- under "MANHOLES" (grease-trap sample port count, a location attribute). Modeled exactly
-- on the existing manhole-count chain (Fred-approved):
--   * property-level integer column (sibling to properties.grease_trap_manhole_count)
--   * entered in the Admin Review app (Job Review page) via the anon client
--   * displayed read-only in Field Portal via customer.work_orders
--
-- APPLIED via Management API by the Building Apps session 2026-07-09 (hybrid routing:
-- small additive DB change done here + verified). Backup of the pre-change view:
--   backups/2026-07-09_customer_work_orders_before_sampleport.sql
--
-- AUDIT (rule #8): public.properties is already in the audited set — adding a column is
-- automatically captured in the full-row JSONB; no trigger change needed.
-- 3NF (rule #2): sample_port_count depends only on the property (whole key), stored (not derived). OK.

-- 1. New column (nullable integer; NULL = "not recorded", mirrors grease_trap_manhole_count).
ALTER TABLE public.properties ADD COLUMN IF NOT EXISTS sample_port_count integer;

-- 2. Anon column-level UPDATE grant (mirrors the manhole grant). The existing row-level
--    RLS policy `properties_anon_update_manhole` (cmd UPDATE, roles {anon}, qual true)
--    already permits the row — this grant scopes anon to just this new column, like
--    grease_trap_manhole_count. Admin Review (anon publishable key) writes it.
GRANT UPDATE (sample_port_count) ON public.properties TO anon;

-- 3. Expose in customer.work_orders as `sample_ports`, using the SAME primary-property
--    fallback as `manholes` (a visit whose property_id is NULL still resolves the client's
--    primary property — e.g. 244-URI visit 6957). Appended as the last column (CREATE OR
--    REPLACE requires additions at the end of the select list).
CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM visit_team vt
             JOIN employees e2 ON e2.id = vt.employee_id
          WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
                    ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
         LIMIT 1) AS visit_total,
    v.title AS notes,
    dm.white_manifest_number AS derm_manifest_number,
    dm.fog_manifest_url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
    dm.derm_manifest_url AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'::text
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count FROM properties prim WHERE prim.client_id = v.client_id AND prim.is_primary = true LIMIT 1), 0)) AS sample_ports
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;
