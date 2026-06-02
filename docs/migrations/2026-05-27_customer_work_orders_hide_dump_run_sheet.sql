-- 2026-05-27_customer_work_orders_hide_dump_run_sheet.sql
--
-- Replaces the Path C visibility gate on customer.work_orders.derm_manifest_url
-- (the DERM "address" PDF). The previous gate, in 2026-05-20j → 2026-05-21a →
-- 2026-05-25b → 2026-05-25f, predicates on whether MULTIPLE rows of
-- public.derm_manifests share a white_manifest_number. That predicate is
-- structurally wrong now that DERM Tracker (live since 2026-05-18) writes
-- ONE derm_manifests row per physical dump-run sheet and links multiple
-- clients' visits via manifest_visits.
--
-- CONCRETE LEAK (verified Prod 2026-05-27):
--   visit 5079, client 369 (009-CN Casa Neos), GT on 2026-05-12
--   manifest 1043 (white_manifest_number = 824273) writes the address PDF
--   to derm/1043/address.jpg — a MULTI-CLIENT dump-run sheet listing other
--   clients on the same dump. manifest_visits(1043) links only 009-CN's own
--   visits (5079 GT + 5082 CL). Old gate: COUNT(*) over derm_manifests where
--   white_manifest_number='824273' = 1 → predicate false → address PDF
--   EXPOSED to the customer. Privacy leak.
--
-- ROOT CAUSE: the visibility gate based on `derm_manifests` row shape is
-- fundamentally fragile because PDF CONTENT (multi-client roster vs single-
-- client receipt) is decoupled from row count. The DERM Tracker UI doesn't
-- emit a per-client redacted sheet, so any address PDF MAY contain other
-- clients' info. The safest invariant is: "never expose the address PDF to a
-- customer."
--
-- DECISION — option 1, stop-the-bleed (Fred 2026-05-27):
--   Always hide derm_manifest_url (in this view ← derm_manifests.derm_address_url
--   in the table). Keep wwtp_receipt_url (← derm_manifests.derm_manifest_url
--   in the table) visible — that's the per-dump white-manifest form which
--   does NOT name other clients (it's the waste-hauler/quantity/facility
--   receipt), so it's safe-by-design.
--
--   Customer still gets useful proof of dump (manifest number, jurisdiction,
--   wwtp_receipt_url). They lose the address sheet, which they shouldn't see.
--
-- PROPER LONG-TERM FIX (option 2, deferred — see ADR 017):
--   Add `derm_manifests.is_multi_client_sheet BOOLEAN`, set by DERM Tracker
--   when the user files >1 client on the same physical sheet. Gate this view
--   on that column. Requires a DB shape change + DERM Tracker UI change +
--   backfill. Not in this migration.
--
-- AUDIT (Rule 8): view-only change, no triggers needed. derm_manifests +
-- manifest_visits + visits remain audited (full-row JSONB captures any
-- column).
--
-- IDEMPOTENT (Rule 5): CREATE OR REPLACE VIEW. Re-runnable.
--
-- NOTE on column-type compatibility:
--   2026-05-25f used DROP + CREATE because the id column type changed
--   (uuid → text via visits.public_id). This migration changes ONLY the
--   CASE expression for derm_manifest_url, which is already text (NULL::text
--   vs dm.derm_address_url which is text). No type drift, so CREATE OR
--   REPLACE is safe.

BEGIN;

CREATE OR REPLACE VIEW customer.work_orders AS
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
    -- Path C v2 (2026-05-27): always hide the DERM "address" PDF because it
    -- may be a multi-client dump-run sheet. Previous row-count predicate
    -- (count > 1 over derm_manifests sharing white_manifest_number) didn't
    -- match the real-world data shape DERM Tracker produces (one row per
    -- physical sheet, multiple manifest_visits per row). See migration
    -- header + ADR 017 for the long-term fix (multi-client sheet flag).
    NULL::text AS derm_manifest_url,
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

-- Defensive re-grant (CREATE OR REPLACE shouldn't drop grants, but
-- 2026-05-25h showed grants ARE fragile; cheap insurance).
GRANT SELECT ON customer.work_orders TO anon, authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Visit 5079 (009-CN, 2026-05-12) should no longer expose the address PDF:
--    SELECT id, derm_manifest_number, derm_manifest_url, wwtp_receipt_url
--    FROM customer.work_orders
--    WHERE client_id::text = customer.uuid_from_bigint(369)::text
--      AND visit_date = '2026-05-12';
--    Expected: derm_manifest_url IS NULL, wwtp_receipt_url IS NOT NULL.
--
-- 2. Aggregate shape — derm_manifest_url should always be NULL now,
--    wwtp_receipt_url unchanged:
--    SELECT COUNT(*) FILTER (WHERE derm_manifest_url IS NOT NULL) AS exposed_addrs,
--           COUNT(*) FILTER (WHERE wwtp_receipt_url IS NOT NULL)  AS exposed_manifs,
--           COUNT(*) AS total
--    FROM customer.work_orders;
--    Expected: exposed_addrs = 0, exposed_manifs unchanged (~399 pre-migration).
--
-- 3. Live view definition cross-check:
--    SELECT pg_get_viewdef('customer.work_orders'::regclass, true);
--    Expected: the derm_manifest_url column expression is `NULL::text` (no CASE).
