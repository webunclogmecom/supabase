-- 2026-05-25a_customer_work_orders_manholes_fallback.sql
--
-- Adds property-level fallback for the `manholes` column in
-- `customer.work_orders` so Field Portal displays a number instead of "—"
-- when the per-visit override isn't set but the property's default is.
--
-- Before:  v.manhole_count AS manholes
-- After:   COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0)) AS manholes
--
-- Why this is needed:
--   - Admin Review can set visits.manhole_count as a per-visit override.
--   - As of 2026-05-25 ZERO visits in the entire DB have that column set
--     (Admin Review's per-visit manhole feature has never been exercised).
--   - The Field Portal therefore renders "—" for every visit, even though
--     108/516 properties already have a real grease_trap_manhole_count
--     entered.
--   - This view-only change exposes the property-default as a fallback.
--     Per-visit override still wins when present, so the new behavior
--     doesn't change anything Admin Review users will eventually set.
--
-- Impact (measured 2026-05-25, derm.unclogme.app session):
--   - 425 eligible visits (completed + derm_required + has client_id)
--   - 0   currently have v.manhole_count set
--   - 57  visits will start showing the property default after this fix
--   - 368 visits will still show "—" because their property's
--         grease_trap_manhole_count is NULL or 0
--           ↳ This is an ops backfill gap, not a view bug. Yannick can
--             enter the missing counts via Admin Review (60 GT clients
--             are missing the value as of today).
--
-- Why NULLIF(prop.grease_trap_manhole_count, 0):
--   - 0 is the unset sentinel today (input type=number on Admin Review
--     defaults to 0; 408 of 516 properties sit at 0, and a 100% spot-check
--     of 8 random GT-client properties with manhole=0 found all of them
--     were real active restaurants, so 0 ≠ "no manholes physically", it
--     just means "not entered yet").
--   - Treating 0 as NULL via NULLIF prevents FP from rendering a misleading
--     "0" for clients whose count was never entered.
--
-- NOT touching `manhole_breakdown`:
--   - properties has no manhole_breakdown column (only the count). Nothing
--     to fall back to.
--   - visits.manhole_breakdown also has 0 non-null rows in the entire DB.
--
-- Audit (Rule 8): views are not audited (only tables are). This migration
--   is captured by the file itself + git history. The pg_get_viewdef of
--   customer.work_orders after this commit is the authoritative
--   definition.
--
-- Idempotent (Rule 5): CREATE OR REPLACE VIEW. Re-runnable, exact-string
--   equivalent each time.
--
-- Verification:
--   After apply, the following 5 visits should return prop_default
--   (instead of NULL) via customer.work_orders.manholes:
--     v4901 → 6   (111-YC Yann Couvreur, property 66)
--     v5128 → 10  (043-MIL Mila, property 51)
--     v4710 → 3   (033-LG La Granja Allapattah, property 67)
--     v5132 → 4   (154-PV Pura Vida Fisher Island, property 192)
--     v5130 → 3   (001-VIN Vincenzos Pizzeria, property 92)
--   And a counter-example (visit 1769, client 384 025-GRO Grove Kosher)
--   should still return NULL because v.property_id points to a property
--   with grease_trap_manhole_count IS NULL.

BEGIN;

CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT customer.uuid_from_bigint(v.id) AS id,
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
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0)) AS manholes,
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

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION (paste-ready)
-- ============================================================
-- SELECT v.id, v.visit_date, v.manhole_count AS visit_override,
--        prop.grease_trap_manhole_count AS prop_default,
--        wo.manholes AS view_returns
-- FROM visits v
-- JOIN customer.work_orders wo ON wo.id = customer.uuid_from_bigint(v.id)
-- LEFT JOIN properties prop ON prop.id = v.property_id
-- WHERE v.id IN (4901, 5128, 4710, 5132, 5130, 1769)
-- ORDER BY v.id;
--
-- Expected:
--   1769  | NULL | NULL | NULL  ← counter-case (prop has no default)
--   4710  | NULL | 3    | 3
--   4901  | NULL | 6    | 6
--   5128  | NULL | 10   | 10
--   5130  | NULL | 3    | 3
--   5132  | NULL | 4    | 4
