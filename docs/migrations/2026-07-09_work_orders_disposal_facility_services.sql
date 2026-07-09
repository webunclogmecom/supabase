-- 2026-07-09 — customer.work_orders: add disposal_facility + services (Field Portal Service Work Order)
--
-- WHY (Fred, ref visit 152-DAV / bBSpATqruQ):
--   * disposal_facility — the ACTUAL dump facility for the visit (from the linked manifest's
--     disposal_facility_id -> disposal_facilities.name, e.g. "South District WWTP"), shown in the
--     Field Portal "Grease Trap Details" section instead of the client's default facility.
--   * services — the visit's line-item names WITHOUT prices, for a new "SERVICES" row in Visit
--     Details. Billing lines (credit card fee / discount / surcharge / convenience / gratuity) are
--     EXCLUDED, and the internal "NN - " code prefix is stripped for a clean customer-facing read.
--
-- Both source from views the query already reaches; the view runs as owner (security_invoker=false)
-- so anon reads them through the grant with no new table grants. Appended at the end of the SELECT
-- list (CREATE OR REPLACE requires additions at the end). Backup of the prior view:
--   backups/2026-07-09_customer_work_orders_before_facility_services.sql
-- Applied via Management API by the Building Apps session 2026-07-09; verified 152-DAV.

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
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS services
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
