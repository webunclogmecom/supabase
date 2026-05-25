-- 2026-05-25b_customer_work_orders_primary_property_fallback.sql
--
-- Extends the COALESCE chain on customer.work_orders.manholes to fall back
-- to the client's `is_primary = true` property when `visits.property_id` is
-- NULL. Companion to 2026-05-25a, surfaced by cross-app integration tests
-- on 2026-05-25.
--
-- Before:
--   COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0)) AS manholes
--
-- After:
--   COALESCE(
--     v.manhole_count,
--     NULLIF(prop.grease_trap_manhole_count, 0),
--     NULLIF((SELECT grease_trap_manhole_count FROM properties
--             WHERE client_id = v.client_id AND is_primary = true LIMIT 1), 0)
--   ) AS manholes
--
-- Why this is needed:
--   - 324 of 425 eligible visits (76%) have `visits.property_id IS NULL`
--     because the Jobber sync code didn't backfill that column for historic
--     visits. Per CLAUDE.md rule 4, Jobber is canonical for visit identity,
--     so the source data is authoritative — `property_id IS NULL` means the
--     visit predates the property link being added to the sync.
--   - The 2026-05-25a fallback only helped the 100 visits whose property_id
--     was set. For the 324 null-property visits, the COALESCE bottomed out
--     at NULL and FP rendered "—" even though the client's primary property
--     had a known manhole count.
--   - For single-property clients, the primary IS the right inference for
--     visits with missing property_id (a one-to-one client→property map).
--   - For multi-property clients (e.g., Yann Couvreur has properties 66 +
--     519 at the same address), the primary's value is the safer default
--     than nothing — and visits with the CORRECT property_id still beat
--     this fallback because they land at the second COALESCE slot.
--
-- Impact (measured 2026-05-25 from cross-app integration test):
--   - 100 visits have property_id set → unchanged behavior
--   - 214 visits w/ NULL property_id + primary_property.gtmc > 0
--     → start showing the primary's manhole count
--   - 110 visits w/ NULL property_id + primary's gtmc = 0 or no primary
--     → still show "—" (data backfill needed for those, see followup)
--
-- Forward fix (ops follow-up, NOT in this migration):
--   324 UPDATEs to backfill `visits.property_id` from the client's primary
--   property, generating 324 audit rows on `visits`. Should be done in a
--   separate, explicit migration with Fred's go-ahead.
--
-- Idempotent (Rule 5): CREATE OR REPLACE VIEW. Re-runnable.
--
-- Audit (Rule 8): views aren't audited. Definition captured by this file +
-- git history. The `pg_get_viewdef('customer.work_orders')` after this
-- commit is the authoritative state.

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

COMMIT;
