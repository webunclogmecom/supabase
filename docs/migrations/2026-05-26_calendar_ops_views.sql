-- 2026-05-26_calendar_ops_views.sql
--
-- Visit Calendar Lovable app wiring — Phase 2 of the migration started
-- in 2026-05-23a_visit_calendar_ops_wiring.sql (which already created
-- ops schema + 5 base 1:1 mirror views + added service_configs.property_id).
--
-- This adds the denormalized read surface the Calendar app actually
-- consumes: one row per scheduled/completed visit, with every field the
-- monthly grid card + visit drawer + truck/driver filters need joined in.
--
-- Architecture (per CLAUDE.md rule 3b — schema-per-app):
--   Visit Calendar reads from ops.* ONLY. Never touches public.* directly.
--   sidebar already wired (2026-05-23a) to ops.v_service_due. Calendar grid
--   + drawer + filters will switch from REAL_DATA mock to ops.v_calendar_visit.
--
-- 3NF check (Rule 2):
--   ops.v_calendar_visit is a VIEW. Read-only denorm of canonical 3NF
--   tables; no storage, no duplication of source-of-truth. Computed columns
--   (late_status, amount) derive from canonical rows on read. Compliant.
--
-- Audit (Rule 8): views aren't audited (read-only).
--
-- Source-of-truth (Rule 4): joins Jobber-sourced visits/clients/properties
-- + Samsara-sourced vehicles + canonical service_configs/gdos. Zero new
-- source columns. zone abbreviations stay client-side (Lovable ZONE_ABBR
-- map at line 41) since they're presentation, not data.
--
-- Idempotent (Rule 5): CREATE OR REPLACE VIEW. Re-runnable.
--
-- AFTER THIS MIGRATION:
--   1. Verify anon SELECT works through PostgREST with Accept-Profile: ops
--   2. Surface Lovable wiring prompt (separate step) with field mapping doc
--
-- ============================================================
-- DESIGN: ops.v_calendar_visit
--   One row per row in public.visits. Carries:
--   • visit identity + state (id, public_id, visit_date, visit_status, dates)
--   • service (service_type, amount derived from service_configs.price_per_visit)
--   • client (code, name, status)
--   • property (zone, address, city, county, hours, days, manholes, geo)
--   • service config (frequency_days, equipment_size_gallons)
--   • GDO permit (gdo_number, gdo_expiration, gdo_max_frequency_days)
--   • vehicle (truck_name, vehicle_status)
--   • assignment (driver_name — first employee assigned to the visit)
--   • computed: late_status using per-(client, service_type) frequency
--     window: 'late' | 'will_be_late' | 'on_time' | NULL
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW ops.v_calendar_visit AS
WITH
-- Per-(client, service_type) last completed visit BEFORE the current visit row.
-- This is the anchor for the late_status due-date calculation.
last_completed AS (
  SELECT
    v.id AS visit_id,
    (
      SELECT MAX(prev.visit_date)
      FROM public.visits prev
      WHERE prev.client_id = v.client_id
        AND prev.service_type = v.service_type
        AND prev.visit_status = 'completed'
        AND prev.visit_date < v.visit_date
    ) AS last_completed_date
  FROM public.visits v
),
-- First employee assigned to each visit (visit_assignments has no
-- driver/helper distinction yet; lowest employee_id wins as a stable pick).
first_assignment AS (
  SELECT DISTINCT ON (va.visit_id)
    va.visit_id,
    va.employee_id
  FROM public.visit_assignments va
  ORDER BY va.visit_id, va.employee_id
),
-- Observed cadence per (client, service_type): median gap between consecutive
-- COMPLETED visits. This is our fallback when service_configs.frequency_days
-- is missing or NULL. Filters gaps to 5..200 days to drop one-off + outliers.
-- One-off jobs (only one completed visit ever) yield NO row here → frequency
-- stays NULL → drawer correctly shows "—".
observed_cadence AS (
  SELECT
    client_id,
    service_type,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_since_prev)::int AS median_gap_days
  FROM (
    SELECT
      client_id,
      service_type,
      visit_date - LAG(visit_date) OVER (PARTITION BY client_id, service_type ORDER BY visit_date) AS days_since_prev
    FROM public.visits
    WHERE visit_status = 'completed'
      AND service_type IN ('GT','CL','WD')
  ) AS gaps
  WHERE days_since_prev BETWEEN 5 AND 200
  GROUP BY client_id, service_type
),
-- Observed avg price per (client, service_type) from line_items on completed
-- invoices. Pure heuristic, used only when sc.price_per_visit is NULL. Weak
-- signal for clients with multi-line invoices — fall back to median per visit.
observed_price AS (
  SELECT
    v.client_id,
    v.service_type,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY li.total_price)::numeric(12,2) AS median_line_price
  FROM public.visits v
  JOIN public.line_items li ON li.invoice_id = v.invoice_id
  WHERE v.invoice_id IS NOT NULL
    AND v.visit_status = 'completed'
    AND v.service_type IN ('GT','CL','WD')
    AND li.total_price > 0
  GROUP BY v.client_id, v.service_type
)
SELECT
  -- ====== visit ======
  v.id,
  v.public_id,
  v.client_id,
  v.property_id,
  v.vehicle_id,
  v.job_id,
  v.visit_date,
  v.visit_status,
  v.service_type,
  v.start_at,
  v.end_at,
  v.completed_at,
  v.duration_minutes,
  v.title,
  v.derm_required,
  v.is_gps_confirmed,
  v.manhole_count,
  v.ticket_number,
  v.created_at AS visit_created_at,
  v.updated_at AS visit_updated_at,

  -- ====== service amount (recurring contract price + observed fallback) ======
  -- 3-level COALESCE (fixed 2026-05-26):
  --   1. service_configs.price_per_visit — AT-contracted recurring price
  --   2. observed_price.median_line_price — median line_item.total_price across
  --      completed invoices for this (client, service_type). Heuristic but
  --      better than blank for clients without AT contracts.
  --   3. NULL — true one-off; drawer shows "—" and daily totals exclude.
  -- We do NOT sum the visit's own invoice (Jobber bundles multi-visit invoices,
  -- which would over-count — see Aromas del Peru May case).
  COALESCE(
    sc.price_per_visit,
    op.median_line_price
  )::numeric(12,2) AS amount,

  -- ====== client ======
  c.client_code,
  c.name              AS client_name,
  c.status            AS client_status,
  c.group_id          AS client_group_id,

  -- ====== property (always pick the visit's property_id; fall back to primary) ======
  COALESCE(prop.zone,        primary_prop.zone)        AS zone,
  COALESCE(prop.address,     primary_prop.address)     AS address,
  COALESCE(prop.city,        primary_prop.city)        AS city,
  COALESCE(prop.state,       primary_prop.state)       AS state,
  COALESCE(prop.zip,         primary_prop.zip)         AS zip,
  COALESCE(prop.county,      primary_prop.county)      AS county,
  COALESCE(prop.access_hours_start, primary_prop.access_hours_start) AS access_hours_start,
  COALESCE(prop.access_hours_end,   primary_prop.access_hours_end)   AS access_hours_end,
  COALESCE(prop.access_days, primary_prop.access_days) AS access_days,
  COALESCE(prop.latitude,    primary_prop.latitude)    AS latitude,
  COALESCE(prop.longitude,   primary_prop.longitude)   AS longitude,
  COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,

  -- ====== service_configs (per client + service_type) + observed fallback ======
  -- COALESCE: AT-contract value first, then observed cadence from completed
  -- visit history. If both NULL → genuine one-off visit, drawer shows "—".
  COALESCE(sc.frequency_days, oc.median_gap_days) AS frequency_days,
  -- equipment_size: contract value only. Observed history doesn't carry trap
  -- size. If missing for GT visits, defer to inspections.tank_capacity_gallons
  -- in a future iteration.
  sc.equipment_size_gallons,
  sc.first_visit         AS sc_first_visit,
  sc.last_visit          AS sc_last_visit,
  sc.stop_date           AS sc_stop_date,
  sc.material_type,

  -- ====== GDO permit (per property) ======
  g.gdo_number,
  g.permit_expiration    AS gdo_expiration,
  g.max_frequency_days   AS gdo_max_frequency_days,
  g.permit_document_path AS gdo_document_path,
  g.status               AS gdo_status,

  -- ====== vehicle ======
  veh.name               AS truck_name,
  veh.status             AS vehicle_status,
  veh.grease_tank_capacity_gallons,
  veh.fuel_tank_capacity_gallons,

  -- ====== assignment ======
  emp.id                 AS driver_id,
  emp.full_name          AS driver_name,
  emp.role               AS driver_role,

  -- ====== late_status (Lovable's red/orange/none rule, per client+service_type) ======
  -- Rule (from Lovable index.tsx late_status logic):
  --   reference = last completed visit date for THIS client+service_type strictly before v.visit_date
  --   due_date  = reference + service_configs.frequency_days
  --   if due_date < today                 → 'late'
  --   elsif due_date < v.visit_date       → 'will_be_late'
  --   else                                → 'on_time'
  -- Skip when visit already completed (NULL).
  -- late_status uses the SAME COALESCEd frequency the drawer shows, so
  -- visits whose freq came from observed cadence also get correct red/orange.
  CASE
    WHEN v.visit_status = 'completed' THEN NULL
    WHEN lc.last_completed_date IS NULL THEN NULL
    WHEN COALESCE(sc.frequency_days, oc.median_gap_days) IS NULL THEN NULL
    WHEN (lc.last_completed_date + COALESCE(sc.frequency_days, oc.median_gap_days) * INTERVAL '1 day')::date < CURRENT_DATE THEN 'late'
    WHEN (lc.last_completed_date + COALESCE(sc.frequency_days, oc.median_gap_days) * INTERVAL '1 day')::date < v.visit_date THEN 'will_be_late'
    ELSE 'on_time'
  END AS late_status,

  -- ====== last completed (exposed for client to compute "GT Last Visit" displays) ======
  lc.last_completed_date AS last_completed_date

FROM public.visits v

JOIN public.clients c
  ON c.id = v.client_id

-- visit's own property (if set)
LEFT JOIN public.properties prop
  ON prop.id = v.property_id
-- fallback: client's primary property
LEFT JOIN public.properties primary_prop
  ON primary_prop.client_id = v.client_id
 AND primary_prop.is_primary = true

-- service_configs row for THIS visit's (client, service_type)
LEFT JOIN public.service_configs sc
  ON sc.client_id    = v.client_id
 AND sc.service_type = v.service_type

-- ACTIVE GDO — exactly one row per visit (Casa Neos / Pura Vida have multi-GDO
-- clients; a naive LEFT JOIN duplicates the visit row). Resolution:
--   1. If visit has property_id, pick the GDO bound to THAT property
--   2. Else fall back to any ACTIVE GDO for the client (deterministic by lowest id)
LEFT JOIN LATERAL (
  SELECT g0.gdo_number, g0.permit_expiration, g0.max_frequency_days,
         g0.permit_document_path, g0.status
  FROM public.gdos g0
  WHERE g0.status = 'ACTIVE'
    AND (
      (v.property_id IS NOT NULL AND g0.property_id = v.property_id)
      OR (v.property_id IS NULL  AND g0.client_id   = v.client_id)
    )
  ORDER BY g0.id
  LIMIT 1
) g ON true

-- vehicle
LEFT JOIN public.vehicles veh
  ON veh.id = v.vehicle_id

-- first assigned employee (LATERAL via CTE)
LEFT JOIN first_assignment fa
  ON fa.visit_id = v.id
LEFT JOIN public.employees emp
  ON emp.id = fa.employee_id

-- last completed precomputed per visit
LEFT JOIN last_completed lc
  ON lc.visit_id = v.id

-- observed cadence fallback (per client + service_type)
LEFT JOIN observed_cadence oc
  ON oc.client_id    = v.client_id
 AND oc.service_type = v.service_type

-- observed median price fallback
LEFT JOIN observed_price op
  ON op.client_id    = v.client_id
 AND op.service_type = v.service_type;

-- ============================================================
-- ops.v_calendar_truck — dropdown source for "All trucks" filter
-- ============================================================
-- Mirrors public.vehicles. Calendar filter currently shows all 4 trucks;
-- if we want to hide INACTIVE Goliath, the Lovable client filters on
-- status='ACTIVE'. Doing it in the view would also be valid; leaving full
-- list so Yannick's UI controls the policy.
CREATE OR REPLACE VIEW ops.v_calendar_truck AS
SELECT
  id, name, status,
  make, model, year,
  grease_tank_capacity_gallons,
  fuel_tank_capacity_gallons,
  license_plate, decal_number,
  notes,
  created_at, updated_at
FROM public.vehicles
ORDER BY
  CASE status WHEN 'ACTIVE' THEN 0 ELSE 1 END,
  name;

-- ============================================================
-- ops.v_calendar_driver — dropdown source for "Driver" select
-- ============================================================
-- Drawer's Driver select currently uses REAL_DATA.drivers (mocked).
-- Filter to employees with active status. Role filter intentionally
-- omitted — Prod data has all employees tagged 'Office' due to Jobber
-- mapping; let the UI pick the relevant subset.
CREATE OR REPLACE VIEW ops.v_calendar_driver AS
SELECT
  id, full_name, role, status, shift, phone, email
FROM public.employees
WHERE status = 'ACTIVE'
ORDER BY full_name;

-- ============================================================
-- GRANTS — anon + authenticated SELECT on the new views
-- (matches existing ops.* anon-permissive pattern from 2026-05-23a)
-- ============================================================
GRANT SELECT ON ops.v_calendar_visit  TO anon, authenticated;
GRANT SELECT ON ops.v_calendar_truck  TO anon, authenticated;
GRANT SELECT ON ops.v_calendar_driver TO anon, authenticated;

COMMIT;

-- ============================================================
-- VERIFY (post-migration; run via Management API SQL)
-- ============================================================
--   1. Row count: SELECT count(*) FROM ops.v_calendar_visit;
--                 (expect: matches public.visits, 974 today)
--
--   2. May 2026 rendering check (matches Calendar's expected ~146):
--      SELECT count(*) FROM ops.v_calendar_visit
--      WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
--
--   3. Late-status sample:
--      SELECT id, visit_date, service_type, client_name, late_status,
--             last_completed_date, frequency_days
--      FROM ops.v_calendar_visit
--      WHERE late_status IN ('late','will_be_late')
--      LIMIT 10;
--
--   4. Truck filter source:
--      SELECT id, name, status FROM ops.v_calendar_truck;
--      (expect: Moises/Cloggy/David ACTIVE, Goliath INACTIVE)
--
--   5. Anon REST smoke:
--      curl 'https://wbasvhvvismukaqdnouk.supabase.co/rest/v1/v_calendar_visit?limit=1' \
--           -H 'apikey: <anon>' -H 'Accept-Profile: ops'
--      (expect: HTTP 200 with one row containing all the columns above)
