-- 2026-05-25f_customer_views_public_id.sql
--
-- IDOR fix Layer 1 (cont): switch every customer.* view that surfaces a
-- visit-derived UUID from the predictable customer.uuid_from_bigint(v.id)
-- pattern to the random visits.public_id added in 2026-05-25e.
--
-- VIEWS AFFECTED
--   customer.work_orders      — id column was bigint→fake-uuid, now public_id (TEXT)
--   customer.wo_photos        — work_order_id column rewired via JOIN visits
--   customer.inspection_items — same
--   customer.recommendations  — same
--   customer.scheduled_visits — same
--
-- TYPE CHANGE
-- The `id` and `work_order_id` columns change from UUID to TEXT. Downstream
-- consumers (Field Portal) treat both as strings, so no TypeScript change is
-- needed beyond updating the URL route param shape and replacing the visit
-- detail SELECT with the RPC introduced in 2026-05-25g.
--
-- IDEMPOTENT (Rule 5): CREATE OR REPLACE VIEW. Re-runnable.
--
-- AUDIT (Rule 8): views are not audited. Definition captured here + git.

BEGIN;

-- ============================================================
-- DROP — PG doesn't allow CREATE OR REPLACE VIEW to change a column's
-- data type (id UUID → TEXT). Drop and recreate each view that has a
-- visit-derived id column changing type.
-- ============================================================
DROP VIEW IF EXISTS customer.wo_photos        CASCADE;
DROP VIEW IF EXISTS customer.inspection_items CASCADE;
DROP VIEW IF EXISTS customer.recommendations  CASCADE;
DROP VIEW IF EXISTS customer.scheduled_visits CASCADE;
DROP VIEW IF EXISTS customer.work_orders      CASCADE;

-- ============================================================
-- 1. customer.work_orders — id is now visits.public_id
-- ============================================================
CREATE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    ( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
    COALESCE(
      v.manhole_count,
      NULLIF(prop.grease_trap_manhole_count, 0),
      NULLIF((SELECT grease_trap_manhole_count FROM properties prim
              WHERE prim.client_id = v.client_id AND prim.is_primary = true LIMIT 1), 0)
    ) AS manholes,
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
        CASE
            WHEN dm.id IS NULL THEN NULL::text
            WHEN (( SELECT count(*) AS count
               FROM derm_manifests dm2
              WHERE dm2.white_manifest_number = dm.white_manifest_number AND dm.white_manifest_number IS NOT NULL)) > 1 THEN NULL::text
            ELSE dm.derm_address_url
        END AS derm_manifest_url,
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
        END AS manifest_jurisdiction
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
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true;

-- ============================================================
-- 2. customer.wo_photos — work_order_id now sources from v.public_id
-- ============================================================
CREATE VIEW customer.wo_photos AS
 SELECT customer.uuid_from_bigint(pl.id) AS id,
    v.public_id AS work_order_id,
    pc.service_phase AS variant,
    customer.public_url(ph.storage_path) AS url,
    pl.caption,
    (row_number() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS "position",
    customer.thumbnail_url(ph.storage_path, 400) AS thumbnail_url
   FROM photo_links pl
     JOIN photos ph ON ph.id = pl.photo_id
     JOIN photo_classifications pc ON pc.photo_link_id = pl.id
     JOIN visits v ON v.id = pl.entity_id
  WHERE pl.entity_type = 'visit'::text
    AND (pc.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'extra'::text]));

-- ============================================================
-- 3. customer.inspection_items — same
-- ============================================================
CREATE VIEW customer.inspection_items AS
 WITH iv AS (
         SELECT i.id,
            i.is_valve_closed,
            i.has_issue,
            i.issue_note,
            ( SELECT v.id
                   FROM visits v
                  WHERE v.vehicle_id = i.vehicle_id AND v.visit_date = i.shift_date
                  ORDER BY (v.visit_status = 'completed'::text) DESC, v.id
                 LIMIT 1) AS visit_id
           FROM inspections i
          WHERE i.inspection_type = 'POST'::text
        )
 SELECT id,
    work_order_id,
    label,
    value,
    is_positive,
    "position"
   FROM ( SELECT md5('insp-valve-'::text || iv.id::text)::uuid AS id,
            (SELECT v.public_id FROM visits v WHERE v.id = iv.visit_id) AS work_order_id,
            'Valve closed'::text AS label,
            COALESCE(iv.is_valve_closed, false) AS value,
            true AS is_positive,
            0 AS "position"
           FROM iv
          WHERE iv.visit_id IS NOT NULL AND iv.is_valve_closed IS NOT NULL
        UNION ALL
         SELECT md5('insp-issue-'::text || iv.id::text)::uuid AS md5,
            (SELECT v.public_id FROM visits v WHERE v.id = iv.visit_id) AS work_order_id,
                CASE
                    WHEN iv.has_issue THEN COALESCE(iv.issue_note, 'Issue reported'::text)
                    ELSE 'No issues'::text
                END AS "case",
            NOT COALESCE(iv.has_issue, false),
            true,
            1
           FROM iv
          WHERE iv.visit_id IS NOT NULL AND iv.has_issue IS NOT NULL) sub;

-- ============================================================
-- 4. customer.recommendations — work_order_id sources from v.public_id
-- ============================================================
CREATE VIEW customer.recommendations AS
 SELECT customer.uuid_from_bigint(vr.id) AS id,
    v.public_id AS work_order_id,
    vr.label,
    vr.is_needed AS needed,
    vr."position"
   FROM visit_recommendations vr
   JOIN visits v ON v.id = vr.visit_id;

-- ============================================================
-- 5. customer.scheduled_visits — id sources from v.public_id
-- ============================================================
CREATE VIEW customer.scheduled_visits AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date AS scheduled_date,
    NULL::text AS scheduled_window,
    v.service_type,
    v.title AS notes,
    v.visit_status AS status,
    v.created_at
   FROM visits v
  WHERE v.visit_status = 'scheduled'::text AND v.client_id IS NOT NULL;

-- ============================================================
-- Re-grant SELECT on every view (DROP VIEW cascades and discards grants).
-- Without this the anon role gets 401 on the Field Portal.
-- ============================================================
GRANT SELECT ON customer.work_orders      TO anon, authenticated;
GRANT SELECT ON customer.wo_photos        TO anon, authenticated;
GRANT SELECT ON customer.inspection_items TO anon, authenticated;
GRANT SELECT ON customer.recommendations  TO anon, authenticated;
GRANT SELECT ON customer.scheduled_visits TO anon, authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Type of customer.work_orders.id should now be TEXT:
--    SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='customer' AND table_name='work_orders' AND column_name='id';
--    Expected: text
--
-- 2. Sample row should have a 10-char base62 id:
--    SELECT id FROM customer.work_orders ORDER BY visit_date DESC LIMIT 3;
--
-- 3. customer.wo_photos.work_order_id should match a corresponding
--    customer.work_orders.id (test by JOIN):
--    SELECT wp.work_order_id, wo.id, wo.id IS NULL AS broken_join
--    FROM customer.wo_photos wp LEFT JOIN customer.work_orders wo ON wo.id = wp.work_order_id
--    LIMIT 10;
--    Expected: broken_join = false on all rows.
