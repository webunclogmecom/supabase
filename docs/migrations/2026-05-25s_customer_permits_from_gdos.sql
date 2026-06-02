-- 2026-05-25s_customer_permits_from_gdos.sql
--
-- Phase 3 of the GDO migration plan: recompose customer.permits to read from
-- public.gdos (canonical) instead of public.service_configs (legacy). Surface
-- max_frequency_days + permit_expiration + location_label, and compute the
-- compliance flag over_gdo_max so Field Portal can show "OVERDUE per DERM".
--
-- BACKGROUND
-- The pre-Phase-2 customer.permits view read permit_number from
-- service_configs.permit_number, which the webhook-airtable Edge Function
-- duplicated across every service_config for a client. That conflated
-- multi-permit properties (e.g. Casa Neos's 3 permits across kitchens / bars
-- / lounge all collapsed into one row repeated 3x).
--
-- Phase 2 (2026-05-25l..r) populated public.gdos with one row per
-- DERM permit, so the canonical source-of-truth now lives there.
--
-- CONSUMERS
-- - Field Portal (`usePermits(clientId)` hook). The Field Portal sandbox
--   reads from a clone of Prod's customer schema, so this change won't
--   reach Field Portal until Fred re-clones — safe to ship now.
-- - Internal Portal (Yannick's Lovable sandbox refreshed from Prod 5x/day).
--
-- BACKWARD COMPATIBILITY
-- Keep every column the live view exposed today:
--   id, client_id, permit_number, area, frequency, permit_url, position
-- Add new columns:
--   property_id, location_label, permit_expiration, max_frequency_days,
--   over_gdo_max
-- One semantic shift on `frequency`: it now reflects the DERM-mandated
-- maximum (g.max_frequency_days), not the client's subscription interval
-- (sc.frequency_days). The old behavior was a webhook side-effect, not the
-- documented contract; the permit document literally states the max.
--
-- ROW GRANULARITY CHANGE
-- Old view: 1 row per (client, service_type with permit_number) — repeated
-- the same GDO across GT/CL/WD/LS rows for one client.
-- New view: 1 row per gdo (per property, per facility). Multi-permit
-- properties now expose distinct rows (Casa Neos: KITCHENS / BARS / LOUNGE).
--
-- IDEMPOTENT: CREATE OR REPLACE VIEW. Safe to re-run. Grants on the view
-- name are preserved.
-- AUDIT: views don't write to audit.logs; only underlying tables do. This
-- migration touches no rows.

BEGIN;

-- IMPORTANT: column ORDER must match the existing view exactly for the first
-- 7 columns (id, client_id, permit_number, area, frequency, permit_url,
-- position) so CREATE OR REPLACE doesn't fail with "cannot change name of
-- view column". New columns are appended at the end. If we ever want to
-- reorder, do DROP VIEW + CREATE (and re-grant — see notes below).
CREATE OR REPLACE VIEW customer.permits AS
SELECT
    customer.uuid_from_bigint(g.id)          AS id,
    customer.uuid_from_bigint(g.client_id)   AS client_id,
    g.gdo_number                              AS permit_number,
    'Grease Trap'::text                       AS area,
    CASE
        WHEN g.max_frequency_days IS NULL THEN NULL
        WHEN g.max_frequency_days <= 35  THEN 'Monthly'
        WHEN g.max_frequency_days <= 95  THEN 'Quarterly'
        WHEN g.max_frequency_days <= 185 THEN 'Semi-annually'
        WHEN g.max_frequency_days <= 380 THEN 'Annually'
        ELSE 'Every ' || g.max_frequency_days || ' days'
    END                                       AS frequency,
    g.permit_document_path                    AS permit_url,
    (row_number() OVER (
        PARTITION BY g.client_id
        ORDER BY g.property_id, g.gdo_number
    ) - 1)::int                               AS position,
    -- NEW columns appended (Phase 3):
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
    -- Compliance flag: TRUE when the latest completed visit at this
    -- property is older than the DERM-mandated max (or there are no
    -- completed visits at all). NULL when max_frequency_days is unknown.
    CASE
        WHEN g.max_frequency_days IS NULL THEN NULL
        ELSE COALESCE(
            (CURRENT_DATE - (
                SELECT MAX(v.visit_date)
                FROM public.visits v
                WHERE v.property_id = g.property_id
                  AND v.visit_status = 'completed'
            )) > g.max_frequency_days,
            TRUE  -- no completed visits ever -> overdue
        )
    END                                       AS over_gdo_max
FROM public.gdos g
JOIN public.clients c ON c.id = g.client_id
WHERE g.status = 'ACTIVE'
  AND c.status IN ('ACTIVE', 'RECURRING');

COMMIT;

-- VERIFICATION
--
-- 1. View exists with expected columns
--    SELECT column_name FROM information_schema.columns
--    WHERE table_schema='customer' AND table_name='permits' ORDER BY ordinal_position;
--    Expected: id, client_id, property_id, permit_number, location_label,
--              area, permit_expiration, max_frequency_days, frequency,
--              permit_url, over_gdo_max, position
--
-- 2. Casa Neos multi-permit case
--    SELECT permit_number, location_label, area, frequency, max_frequency_days,
--           permit_expiration::text, over_gdo_max, position
--    FROM customer.permits
--    WHERE client_id = customer.uuid_from_bigint(9)  -- 009-CN Casa Neos
--    ORDER BY position;
--    Expected: 3 rows
--      GDO-10877 KITCHENS Grease Trap "Quarterly" 60 2026-12-31 ...
--      GDO-15062 BARS     Grease Trap "Quarterly" 90 2026-12-31 ...
--      GDO-16389 LOUNGE   Grease Trap "Monthly"   30 2026-12-31 ...
--
-- 3. Row count comparison (informational)
--    SELECT COUNT(*) FROM customer.permits;
--    Pre-Phase-3 (when reading from service_configs): ~190
--    Post-Phase-3 (reading from gdos ACTIVE): 82 (matches gdos ACTIVE count)
--
-- 4. ACTIVE clients with no permit
--    SELECT c.client_code, c.name FROM public.clients c
--    WHERE c.status IN ('ACTIVE','RECURRING')
--      AND NOT EXISTS (SELECT 1 FROM customer.permits p
--                      WHERE p.client_id = customer.uuid_from_bigint(c.id))
--    ORDER BY c.client_code;
--    Note: many residential / non-Dade clients legitimately have no DERM permit;
--    just verify the list looks sane to Fred / ops.
