-- 2026-05-16a_customer_clients_include_paused_inactive.sql
--
-- Field Portal UX decision 2026-05-16 (Fred):
-- Allow PAUSED + INACTIVE clients to log in and view their historical service
-- in read-only mode. Previously the view filtered to ACTIVE+RECURRING only, so
-- a PAUSED/INACTIVE customer hitting the login page with their real client_code
-- got "Invalid code" — confusing, because the code IS valid; the relationship
-- just isn't current.
--
-- Changes (purely additive — no breaking changes to existing Lovable code):
--   1. New column `status` (text): one of 'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE'.
--      Lovable will use this to render a banner ("Account paused / inactive —
--      read-only history") and disable any write affordances.
--   2. New column `is_active` (boolean): convenience flag = status IN ('ACTIVE','RECURRING').
--      Lovable can use this to gate UI without parsing the string.
--   3. Removed the WHERE filter on c.status. All 4 statuses now flow through.
--
-- Reachable-via-slug delta: +24 clients (19 INACTIVE + 5 PAUSED that have client_code).
-- All other downstream views (customer.work_orders, customer.wo_photos, etc.)
-- already join via client_id without filtering on status, so historical data
-- becomes visible automatically.
--
-- No new grants needed (anon SELECT already in place).
-- No types regeneration required (supabase-js tolerates extra columns).
--
-- Coordinated with Lovable: see docs/lovable-field-portal-prod-switch.md
-- step 8 for the banner UI instructions.

-- NOTE: PostgreSQL CREATE OR REPLACE VIEW cannot reorder existing columns.
-- New columns must be APPENDED at the end. status + is_active land after
-- the existing trailing column (created_at).

BEGIN;

CREATE OR REPLACE VIEW customer.clients AS
SELECT
  customer.uuid_from_bigint(c.id) AS id,
  lower(c.client_code) AS slug,
  c.name,
  c.client_code,
  cg.name AS group_name,
  p.address AS address1,
  NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text,
    NULLIF(p.city, ''::text),
    NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text)
  )), ''::text) AS address2,
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
  sc_gt.permit_document_path AS gdo_permit_url,
  p.access_notes,
  c.created_at,
  -- NEW (appended for CREATE OR REPLACE compatibility):
  c.status,                                                                  -- 'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE'
  (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AS is_active   -- convenience boolean for Lovable
FROM clients c
  LEFT JOIN client_groups cg ON cg.id = c.group_id
  LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
  LEFT JOIN service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'GT'::text
  LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;
-- (status filter removed; was: WHERE c.status = ANY (ARRAY['ACTIVE','RECURRING']))

COMMIT;
