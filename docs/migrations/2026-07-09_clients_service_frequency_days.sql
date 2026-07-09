-- 2026-07-09 — customer.clients: add service_frequency_days (Field Portal frequency display)
--
-- WHY (Fred, ref 152-DAV): the Field Portal "GDO Permits & Frequency" section only renders the pump
-- frequency INSIDE a GDO-permit row. SA clients with NO GDO permit (32 active SA clients, incl.
-- 152-DAV) therefore showed "No permits on file" and their (correct) frequency was invisible — even
-- though jobs.frequency_days matches Jobber's "Frequency" custom field (full audit 2026-07-09:
-- 153/153 active SA jobs match, 0 mismatches). This field exposes the client's current SA frequency so
-- the FP can show it even without a GDO permit.
--
-- service_frequency_days = max(frequency_days) of the client's non-archived "Service Agreement" jobs
-- with frequency_days > 0 (jobs.frequency_days is Jobber-synced from the Frequency custom field).
-- Backup: backups/2026-07-09_customer_clients_before_service_freq.sql
-- Applied via Management API by the Building Apps session 2026-07-09; verified 152-DAV=60, 244-URI=30.

CREATE OR REPLACE VIEW customer.clients AS
 SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN sc_gt.equipment_size_gallons IS NOT NULL THEN sc_gt.equipment_size_gallons::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN sc_gt.equipment_size_gallons IS NOT NULL THEN sc_gt.equipment_size_gallons::text || ' gal'::text
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE j.client_id = c.id AND j.title ~~* '%Service Agreement%'::text AND j.job_status <> 'archived'::text AND j.frequency_days > 0) AS service_frequency_days
   FROM clients c
     LEFT JOIN client_groups cg ON cg.id = c.group_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'GT'::text
     LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;
