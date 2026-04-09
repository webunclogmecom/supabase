-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║                                                                      ║
-- ║   ops.* — UNCLOGME SINGLE SOURCE OF TRUTH                           ║
-- ║   Database Architecture Blueprint v2.0                               ║
-- ║                                                                      ║
-- ║   Date: 2026-04-01                                                   ║
-- ║   Author: Claude (System Architect)                                  ║
-- ║   For: Fred Zerpa & Yan Ayache                                       ║
-- ║   Deploy to: NEW Supabase project (clean install)                    ║
-- ║                                                                      ║
-- ╚══════════════════════════════════════════════════════════════════════╝
--
-- ┌──────────────────────────────────────────────────────────────────┐
-- │ ARCHITECTURE OVERVIEW                                            │
-- │                                                                  │
-- │ This is a CLEAN database deployed on a NEW Supabase project.     │
-- │ The existing Supabase project (infbofuilnqqviyjlwul) retains     │
-- │ all source mirror tables as raw data ingredients.                │
-- │                                                                  │
-- │ DATA SOURCES (synced from existing Supabase + APIs):             │
-- │   Jobber      → Clients, jobs, visits, invoices, quotes         │
-- │   Airtable    → CRM master, visits, DERM, inspections, routes   │
-- │   Samsara     → Vehicles, drivers, GPS, engine, fuel, odometer  │
-- │   Fillout     → Pre/post shift inspection forms                 │
-- │   Ramp        → Company expenses, corporate cards               │
-- │                                                                  │
-- │ NOT INCLUDED: QuickBooks (not actively used for payments)        │
-- │   Payments are tracked in Jobber (invoice paid_at status)        │
-- │                                                                  │
-- │ TABLES (15):                                                     │
-- │   ops.clients           — WHO we serve (491 merged)             │
-- │   ops.properties        — WHERE we serve them (367 locations)   │
-- │   ops.team_members      — WHO does the work (10 people)         │
-- │   ops.vehicles          — WHAT equipment (4 trucks)             │
-- │   ops.jobs              — WHAT work is ordered (507 orders)     │
-- │   ops.visits            — WHEN work was performed (3100 events) │
-- │   ops.invoices          — WHAT we billed (1583 invoices)        │
-- │   ops.quotes            — WHAT we proposed (171 quotes)         │
-- │   ops.line_items        — Service details per job/invoice       │
-- │   ops.expenses          — WHAT we spent (Ramp + driver reports) │
-- │   ops.inspections       — Truck pre/post shift checks (480)     │
-- │   ops.derm_manifests    — DERM compliance records (868)         │
-- │   ops.routes            — Daily route planning (135)            │
-- │   ops.past_due          — Outstanding balance tracking (45)     │
-- │   ops.entity_map        — Cross-reference audit trail (251)     │
-- │                                                                  │
-- │ VIEWS (7):                                                       │
-- │   ops.v_client_health          — Client compliance + financials │
-- │   ops.v_service_schedule       — Upcoming services by urgency   │
-- │   ops.v_compliance_dashboard   — GDO/GT/CL compliance           │
-- │   ops.v_fleet_daily            — Daily fleet utilization        │
-- │   ops.v_trips                  — Reconstructed truck trips      │
-- │   ops.v_shift_summary          — Daily shift recap              │
-- │   ops.v_revenue_summary        — Revenue by client/period       │
-- │                                                                  │
-- └──────────────────────────────────────────────────────────────────┘
--
-- DESIGN PRINCIPLES:
--   1. Every table has a BIGSERIAL primary key (ops-owned identity)
--   2. Source system FK columns are TEXT with UNIQUE constraints
--   3. All timestamps stored in UTC; display layer converts to EDT
--   4. All money uses NUMERIC(12,2)
--   5. Arrays for multi-value fields (service_type, truck, certifications)
--   6. Idempotent: safe to drop + recreate
--   7. No QuickBooks references — Jobber is payment authority
--   8. 4 trucks: Cloggy (126gal), David (1,800gal), Goliath (4,800gal), Moise (9,000gal)
--   9. Overnight ops: trucks work through midnight, use ±12h query windows
--  10. Work week: Sunday → Saturday
--
-- ════════════════════════════════════════════════════════════════════


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 0. SCHEMA + UTILITY FUNCTIONS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CREATE SCHEMA IF NOT EXISTS ops;

-- Extract 3-digit client code from name like "009-CN Casa Neos"
CREATE OR REPLACE FUNCTION ops.extract_code(name TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN name ~ '^[0-9]{3}\s*-' THEN substring(name from '^([0-9]{3})')
    ELSE NULL
  END
$$;

-- Extract clean name after code prefix + abbreviation
CREATE OR REPLACE FUNCTION ops.extract_clean_name(name TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN name ~ '^[0-9]{3}\s*-\s*[A-Z]{0,4}\s+'
      THEN trim(regexp_replace(name, '^[0-9]{3}\s*-\s*[A-Z]{0,4}\s+', ''))
    WHEN name ~ '^[0-9]{3}\s*-\s*'
      THEN trim(regexp_replace(name, '^[0-9]{3}\s*-\s*', ''))
    ELSE trim(name)
  END
$$;

-- Auto-update updated_at on row modification
CREATE OR REPLACE FUNCTION ops.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 1. ops.clients — WHO WE SERVE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources: airtable_clients (185, primary CRM), jobber_clients (364),
--          samsara.addresses (192 geofences)
-- Expected: ~491 merged rows
-- Build script: scripts/build_ops_clients.js
--
-- Airtable is the CRM master: service details, compliance, scheduling
-- Jobber adds: contact info (email, phone), billing balance
-- Samsara adds: GPS coordinates, geofence polygon

DROP TABLE IF EXISTS ops.clients CASCADE;

CREATE TABLE ops.clients (
  id                      BIGSERIAL PRIMARY KEY,

  -- Identity
  client_code             TEXT,                       -- 3-digit prefix: "009"
  canonical_name          TEXT NOT NULL,              -- Clean name: "Casa Neos"
  display_name            TEXT,                       -- Full display: "009-CN Casa Neos"

  -- Status
  status                  TEXT,                       -- ACTIVE | RECURRING | PAUSED | INACTIVE
  overall_status          TEXT,                       -- On Time | GT Late | CL Late | GT-CL Late

  -- Address (merge priority: Airtable > Jobber property > Samsara)
  address_line1           TEXT,
  city                    TEXT,
  state                   TEXT DEFAULT 'FL',
  zip_code                TEXT,
  county                  TEXT,                       -- Miami-Dade, Broward, Palm Beach
  zone                    TEXT,                       -- Service zone: NMB, MIAMI BEACH, BRO, DOWN, etc.
  latitude                NUMERIC(10,7),
  longitude               NUMERIC(10,7),

  -- Contact (from Jobber primarily)
  email                   TEXT,                       -- Primary contact email
  phone                   TEXT,                       -- Primary phone
  accounting_email        TEXT,                       -- Billing contact (from Airtable)
  operation_email         TEXT,                       -- Ops contact (from Airtable)

  -- Service Configuration (from Airtable — authoritative)
  service_type            TEXT[],                     -- {Grease Trap, Drain Cleaning, AUX Cleaning}
  truck                   TEXT[],                     -- Preferred truck: {INT, TOY, KEN, PET}
  gt_frequency_days       INTEGER,                    -- GT service interval (DERM: max 90 days)
  cl_frequency_days       INTEGER,                    -- CL (drain cleaning) interval
  gt_price_per_visit      NUMERIC(12,2),
  cl_price_per_visit      NUMERIC(12,2),
  gt_size_gallons         NUMERIC,                    -- Grease trap capacity (33 clients missing this!)
  gt_status               TEXT,                       -- Current GT compliance
  cl_status               TEXT,                       -- Current CL compliance
  gt_last_visit           DATE,
  gt_next_visit           DATE,
  cl_last_visit           DATE,
  cl_next_visit           DATE,
  gt_total_per_year       NUMERIC(12,2),              -- Annual GT revenue from this client

  -- Compliance (DERM)
  gdo_number              TEXT,                       -- Grease Disposal Order permit #
  gdo_expiration_date     DATE,                       -- GDO permit expiry
  contract_warranty       TEXT,                       -- Contract/warranty details

  -- Scheduling preferences
  days_of_week            TEXT,                       -- Preferred service days
  hours_in_out            TEXT,                       -- Access window: "8AM - 5PM"

  -- Financial (from Jobber)
  balance                 NUMERIC(12,2),              -- Outstanding balance

  -- Source System Foreign Keys
  airtable_record_id      TEXT UNIQUE,                -- → airtable_clients.record_id
  jobber_client_id        TEXT UNIQUE,                -- → jobber_clients.id
  samsara_address_id      TEXT UNIQUE,                -- → samsara.addresses.id

  -- Samsara geofence data
  geofence_radius_meters  NUMERIC,
  geofence_type           TEXT,                       -- circle | polygon

  -- Meta
  data_sources            TEXT[],                     -- {airtable, jobber, samsara}
  match_method            TEXT,                       -- How cross-system match was made
  match_confidence        NUMERIC(3,2),               -- 0.00–1.00
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_clients_code ON ops.clients(client_code);
CREATE INDEX idx_clients_status ON ops.clients(status);
CREATE INDEX idx_clients_zone ON ops.clients(zone);
CREATE INDEX idx_clients_name ON ops.clients(canonical_name);
CREATE INDEX idx_clients_county ON ops.clients(county);

COMMENT ON TABLE ops.clients IS 'Canonical client table. ~491 rows merging Airtable (185 CRM master) + Jobber (364 contacts) + Samsara (192 geofences).';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 2. ops.properties — WHERE WE SERVE THEM
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: jobber_properties (367 rows)
-- A client can have multiple service locations (chain restaurants: La Granja 5+,
-- Carrot Express 4+, Grove Kosher 4, Pura Vida 4+)

DROP TABLE IF EXISTS ops.properties CASCADE;

CREATE TABLE ops.properties (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT NOT NULL REFERENCES ops.clients(id),
  name                    TEXT,                       -- Property name/label
  street                  TEXT,
  city                    TEXT,
  state                   TEXT DEFAULT 'FL',
  postal_code             TEXT,
  country                 TEXT DEFAULT 'US',
  is_billing_address      BOOLEAN DEFAULT false,

  -- Source FK
  jobber_property_id      TEXT UNIQUE,                -- → jobber_properties.id

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_properties_client ON ops.properties(client_id);

COMMENT ON TABLE ops.properties IS 'Service locations per client. From jobber_properties (367). Chains like La Granja have 5+ properties.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 3. ops.team_members — WHO DOES THE WORK
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources: airtable_drivers_team (9, richest), samsara.drivers (7), jobber_users (25)
-- Includes owners, managers, admins, and field technicians
-- Access hierarchy: Dev (Fred/Yan) > Office (Aaron/Diego) > Field (techs)

DROP TABLE IF EXISTS ops.team_members CASCADE;

CREATE TABLE ops.team_members (
  id                      BIGSERIAL PRIMARY KEY,
  full_name               TEXT NOT NULL,
  first_name              TEXT,
  last_name               TEXT,
  role                    TEXT,                       -- Owner | Manager | Admin | Team Lead | Technician | Part-Time
  status                  TEXT DEFAULT 'ACTIVE',      -- ACTIVE | INACTIVE | DEACTIVATED
  shift                   TEXT,                       -- Day | Night | Both
  access_level            TEXT,                       -- dev | office | field (maps to access hierarchy)

  -- Contact
  email                   TEXT,
  phone                   TEXT,

  -- Employment
  hire_date               DATE,
  cdl_license             TEXT,
  certifications          TEXT[],                     -- CDL, OSHA, etc.
  emergency_contact       TEXT,

  -- Samsara driver info
  license_state           TEXT,
  driver_activation       TEXT,                       -- active | deactivated
  eld_settings            JSONB,                      -- ELD cycle/shift/restart/break config

  -- Source System FKs
  airtable_record_id      TEXT UNIQUE,                -- → airtable_drivers_team.record_id
  samsara_driver_id       TEXT UNIQUE,                -- → samsara.drivers.id
  jobber_user_id          TEXT UNIQUE,                -- → jobber_users.id

  -- Meta
  data_sources            TEXT[],
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE ops.team_members IS 'Canonical employee/driver table. 10 active team members. Access levels: dev > office > field.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 4. ops.vehicles — THE FLEET
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources: samsara.vehicles (3), airtable_vehicles (4)
-- 4 trucks total. Currently at 17% capacity — can serve 700+ clients.
--
-- ⚠️ CRITICAL: Vehicle names are people names!
--   "Moises" and "David" are TRUCKS, not drivers!
--
-- ┌──────────┬─────────────────────┬──────────┬───────────────────────────┐
-- │ Name     │ Vehicle             │ Capacity │ Primary Use               │
-- ├──────────┼─────────────────────┼──────────┼───────────────────────────┤
-- │ Cloggy   │ Toyota Tundra 2020  │ 126 gal  │ Day jobs, small resid.    │
-- │ David    │ International 2017  │ 1,800gal │ Night commercial          │
-- │ Goliath  │ Peterbilt 579 2019  │ 4,800gal │ Large commercial          │
-- │ Moise    │ Kenworth T880 2023  │ 9,000gal │ Newest, large commercial  │
-- └──────────┴─────────────────────┴──────────┴───────────────────────────┘

DROP TABLE IF EXISTS ops.vehicles CASCADE;

CREATE TABLE ops.vehicles (
  id                      BIGSERIAL PRIMARY KEY,
  name                    TEXT NOT NULL UNIQUE,       -- "Moise", "Cloggy", "David", "Goliath"
  short_code              TEXT,                       -- KEN, TOY, INT, PET
  make                    TEXT,                       -- KENWORTH, TOYOTA, INTERNATIONAL, PETERBILT
  model                   TEXT,                       -- T880, TUNDRA, MA025, 579
  year                    INTEGER,
  vin                     TEXT UNIQUE,
  license_plate           TEXT,

  -- Operational
  tank_capacity_gallons   NUMERIC NOT NULL,           -- 126, 1800, 4800, 9000
  primary_use             TEXT,                       -- Day jobs | Night commercial | Large commercial
  status                  TEXT DEFAULT 'ACTIVE',      -- ACTIVE | OUT_OF_SERVICE | RETIRED

  -- Samsara telemetry
  gateway_serial          TEXT,
  gateway_model           TEXT,
  camera_serial           TEXT,

  -- Source FKs
  samsara_vehicle_id      TEXT UNIQUE,                -- → samsara.vehicles.id (NULL for Goliath if not on Samsara)
  airtable_record_id      TEXT UNIQUE,                -- → airtable_vehicles.record_id

  -- Meta
  data_sources            TEXT[],
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE ops.vehicles IS '4 trucks. At 17% capacity — can serve 700+ clients. ⚠️ Names (Moises, David) are TRUCKS not drivers!';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 5. ops.jobs — WHAT WORK IS ORDERED
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: jobber_jobs (507 rows)
-- A job = a work order. Can be one-time or recurring.
-- Recurring jobs generate visits on a schedule.
-- Billing: per-visit or fixed-price.

DROP TABLE IF EXISTS ops.jobs CASCADE;

CREATE TABLE ops.jobs (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  property_id             BIGINT REFERENCES ops.properties(id),

  -- Identity
  job_number              TEXT,                       -- Jobber #: "10000275"
  title                   TEXT,                       -- "Service call", "Hydrojet Cleaning", "Grease Trap Pumping"
  instructions            TEXT,

  -- Classification
  job_type                TEXT,                       -- RECURRING | ONE_OFF
  billing_type            TEXT,                       -- VISIT_BASED | FIXED_PRICE
  service_category        TEXT,                       -- GT | CL | HYDROJET | CAMERA | EMERGENCY | OTHER
                                                      -- Derived from title when possible

  -- Status & scheduling
  job_status              TEXT,                       -- active | upcoming | completed | archived
  start_at                TIMESTAMPTZ,
  end_at                  TIMESTAMPTZ,
  completed_at            TIMESTAMPTZ,

  -- Financial
  total                   NUMERIC(12,2),
  invoiced_total          NUMERIC(12,2),
  uninvoiced_total        NUMERIC(12,2),

  -- Source FKs
  jobber_job_id           TEXT UNIQUE,                -- → jobber_jobs.id
  jobber_quote_id         TEXT,                       -- → jobber_quotes.id (if originated from quote)

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_jobs_client ON ops.jobs(client_id);
CREATE INDEX idx_jobs_status ON ops.jobs(job_status);
CREATE INDEX idx_jobs_type ON ops.jobs(job_type);
CREATE INDEX idx_jobs_start ON ops.jobs(start_at);

COMMENT ON TABLE ops.jobs IS 'Work orders from Jobber. 507 jobs: recurring GT/CL services + one-off emergency/hydrojet calls.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 6. ops.visits — WHEN/WHERE WORK WAS PERFORMED
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources: airtable_visits (3016, richest), jobber_visits (1636, scheduling)
-- ★ THIS IS THE CORE OPERATIONS TABLE ★
-- Every grease trap pump, every drain cleaning, every emergency call.
-- Cross-linked via airtable_visits.jobber_visit_id
--
-- Airtable visits have: visit_date, service_type (GT/CL), amount, truck, zone, DERM links
-- Jobber visits have: scheduling, completion timestamps, duration, driver assignment
--
-- Note: Unclogme runs overnight. A 10 PM job ends at 3 AM.
-- Always query with ±12h windows when filtering by date.

DROP TABLE IF EXISTS ops.visits CASCADE;

CREATE TABLE ops.visits (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  property_id             BIGINT REFERENCES ops.properties(id),
  job_id                  BIGINT REFERENCES ops.jobs(id),
  vehicle_id              BIGINT REFERENCES ops.vehicles(id),

  -- When
  visit_date              DATE NOT NULL,              -- Service date
  start_at                TIMESTAMPTZ,                -- Scheduled start
  end_at                  TIMESTAMPTZ,                -- Scheduled end
  completed_at            TIMESTAMPTZ,                -- Actual completion
  duration_minutes        INTEGER,                    -- From Jobber completion

  -- What
  title                   TEXT,
  instructions            TEXT,
  service_type            TEXT,                       -- GT | CL | AUX | HYDROJET | CAMERA | EMERGENCY
  visit_status            TEXT,                       -- COMPLETED | UPCOMING | UNSCHEDULED | CANCELLED | LATE
  is_complete             BOOLEAN DEFAULT false,

  -- Financial
  amount                  NUMERIC(12,2),              -- Amount charged for this visit

  -- Operational context
  truck                   TEXT,                       -- Truck name: "Cloggy 120", "David 2,000", "INT", "TOY"
  zone                    TEXT,                       -- Service zone
  completed_by            TEXT,                       -- Driver/team member name

  -- Compliance
  late_status             TEXT,                       -- Overdue indicator from Airtable
  late_status_gt_freq     TEXT,                       -- Late relative to GT frequency

  -- DERM manifest links
  derm_record_ids         TEXT[],                     -- Links to ops.derm_manifests

  -- GPS enrichment (populated by Samsara trip matching)
  actual_arrival_at       TIMESTAMPTZ,                -- GPS-confirmed arrival
  actual_departure_at     TIMESTAMPTZ,                -- GPS-confirmed departure
  gps_confirmed           BOOLEAN DEFAULT false,

  -- Source FKs
  airtable_record_id      TEXT UNIQUE,                -- → airtable_visits.record_id
  jobber_visit_id         TEXT UNIQUE,                -- → jobber_visits.id

  -- Meta
  data_sources            TEXT[],                     -- {airtable, jobber}
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_visits_client ON ops.visits(client_id);
CREATE INDEX idx_visits_date ON ops.visits(visit_date DESC);
CREATE INDEX idx_visits_status ON ops.visits(visit_status);
CREATE INDEX idx_visits_type ON ops.visits(service_type);
CREATE INDEX idx_visits_vehicle ON ops.visits(vehicle_id);
CREATE INDEX idx_visits_job ON ops.visits(job_id);
CREATE INDEX idx_visits_complete ON ops.visits(is_complete) WHERE NOT is_complete;

COMMENT ON TABLE ops.visits IS '★ CORE TABLE ★ Every service event. ~3100 rows merging airtable_visits (3016) + jobber_visits (1636). Overnight ops: ±12h query windows.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 7. ops.invoices — WHAT WE BILLED
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: jobber_invoices (1583 rows)
-- Jobber is the invoicing AND payment tracking system.
-- paid_at field indicates when payment was received.
-- No QuickBooks reconciliation needed.
--
-- Outstanding A/R: ~$132,749 (from company context)

DROP TABLE IF EXISTS ops.invoices CASCADE;

CREATE TABLE ops.invoices (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  job_id                  BIGINT REFERENCES ops.jobs(id),

  -- Identity
  invoice_number          TEXT,                       -- Jobber: "2148"
  subject                 TEXT,
  message                 TEXT,

  -- Financial
  subtotal                NUMERIC(12,2),
  tax_amount              NUMERIC(12,2),
  total                   NUMERIC(12,2),
  outstanding             NUMERIC(12,2),              -- Remaining unpaid balance
  deposit_amount          NUMERIC(12,2),

  -- Status & dates
  invoice_status          TEXT,                       -- draft | sent | awaiting_payment | paid | void | overdue | bad_debt
  due_date                DATE,
  sent_at                 TIMESTAMPTZ,
  paid_at                 TIMESTAMPTZ,                -- From Jobber — when payment was received

  -- Source FK
  jobber_invoice_id       TEXT UNIQUE,                -- → jobber_invoices.id

  -- Meta
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_invoices_client ON ops.invoices(client_id);
CREATE INDEX idx_invoices_status ON ops.invoices(invoice_status);
CREATE INDEX idx_invoices_due ON ops.invoices(due_date);
CREATE INDEX idx_invoices_number ON ops.invoices(invoice_number);
CREATE INDEX idx_invoices_outstanding ON ops.invoices(outstanding) WHERE outstanding > 0;

COMMENT ON TABLE ops.invoices IS 'Invoices from Jobber (1583). Payment tracking via paid_at. Outstanding A/R: ~$132K.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 8. ops.quotes — WHAT WE PROPOSED
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: jobber_quotes (171 rows)
-- Key pipeline: 5 high-value unsigned contracts (Casa Neos, Chima, etc.)

DROP TABLE IF EXISTS ops.quotes CASCADE;

CREATE TABLE ops.quotes (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  property_id             BIGINT REFERENCES ops.properties(id),

  quote_number            TEXT,
  title                   TEXT,
  message                 TEXT,

  subtotal                NUMERIC(12,2),
  tax_amount              NUMERIC(12,2),
  total                   NUMERIC(12,2),
  deposit_amount          NUMERIC(12,2),

  quote_status            TEXT,                       -- draft | awaiting_response | approved | rejected | converted
  sent_at                 TIMESTAMPTZ,
  approved_at             TIMESTAMPTZ,
  converted_to_job_at     TIMESTAMPTZ,

  -- Source FK
  jobber_quote_id         TEXT UNIQUE,                -- → jobber_quotes.id

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_quotes_client ON ops.quotes(client_id);
CREATE INDEX idx_quotes_status ON ops.quotes(quote_status);

COMMENT ON TABLE ops.quotes IS 'Sales quotes from Jobber (171). Pipeline includes 5 high-value unsigned contracts.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 9. ops.line_items — SERVICE DETAILS PER JOB/INVOICE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: jobber_line_items (⚠️ currently 0 rows — sync needs repair!)
-- Once fixed: details each service item within a job

DROP TABLE IF EXISTS ops.line_items CASCADE;

CREATE TABLE ops.line_items (
  id                      BIGSERIAL PRIMARY KEY,
  job_id                  BIGINT REFERENCES ops.jobs(id),
  invoice_id              BIGINT REFERENCES ops.invoices(id),

  name                    TEXT,                       -- Service name: "Grease Trap Pumping", "Hydro Jet"
  description             TEXT,
  quantity                NUMERIC(10,2),
  unit_price              NUMERIC(12,2),
  total_price             NUMERIC(12,2),
  taxable                 BOOLEAN DEFAULT false,

  -- Source FK
  jobber_line_item_id     TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_line_items_job ON ops.line_items(job_id);
CREATE INDEX idx_line_items_invoice ON ops.line_items(invoice_id);

COMMENT ON TABLE ops.line_items IS '⚠️ Jobber line_items sync = 0 rows. Fix Jobber sync to populate.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 10. ops.expenses — WHAT WE SPENT
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources:
--   1. Ramp (company expense management + corporate cards) — coming soon
--   2. fillout_post_shift_inspections (driver-reported shift expenses)
--
-- Categories: Fuel, Maintenance, Dump Fee, Supplies, Other

DROP TABLE IF EXISTS ops.expenses CASCADE;

CREATE TABLE ops.expenses (
  id                      BIGSERIAL PRIMARY KEY,
  expense_date            DATE NOT NULL,
  amount                  NUMERIC(12,2),
  description             TEXT,
  category                TEXT,                       -- Fuel | Maintenance | Dump Fee | Supplies | Tools | Other

  -- Context
  vendor_name             TEXT,                       -- Where the expense was incurred
  vehicle_id              BIGINT REFERENCES ops.vehicles(id),
  team_member_id          BIGINT REFERENCES ops.team_members(id),
  receipt_url             TEXT,                       -- Photo URL from Fillout or Ramp

  -- Ramp card info (when available)
  ramp_card_holder        TEXT,                       -- Who charged the card
  ramp_merchant           TEXT,                       -- Merchant name from Ramp

  -- Source FKs
  ramp_transaction_id     TEXT UNIQUE,                -- → Ramp API transaction ID
  fillout_submission_id   TEXT UNIQUE,                -- → fillout_post_shift_inspections.submission_id

  -- Meta
  data_sources            TEXT[],                     -- {ramp, fillout}
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_expenses_date ON ops.expenses(expense_date);
CREATE INDEX idx_expenses_vehicle ON ops.expenses(vehicle_id);
CREATE INDEX idx_expenses_category ON ops.expenses(category);
CREATE INDEX idx_expenses_member ON ops.expenses(team_member_id);

COMMENT ON TABLE ops.expenses IS 'Unified expenses from Ramp (corporate cards) + driver shift reports (Fillout).';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 11. ops.inspections — TRUCK PRE/POST SHIFT CHECKS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Sources: fillout_pre_shift (94), fillout_post_shift (150),
--          airtable_pre_post_inspection (239)
-- Every shift starts with PRE check and ends with POST check.
-- Tracks: sludge levels, fuel, water, valve, issues, DERM photos.
--
-- The sludge_delta (post - pre) tells you how much waste was collected.

DROP TABLE IF EXISTS ops.inspections CASCADE;

CREATE TABLE ops.inspections (
  id                      BIGSERIAL PRIMARY KEY,
  vehicle_id              BIGINT REFERENCES ops.vehicles(id),
  team_member_id          BIGINT REFERENCES ops.team_members(id),

  shift_date              DATE NOT NULL,
  inspection_type         TEXT NOT NULL,              -- PRE | POST
  submitted_at            TIMESTAMPTZ,

  -- Tank / fuel levels
  sludge_gallons          INTEGER,                    -- Sludge tank level at inspection
  water_gallons           INTEGER,                    -- Water tank (POST only)
  gas_level               TEXT,                       -- Full | 3/4 | 1/2 | 1/4 | Empty

  -- Condition
  valve_is_closed         BOOLEAN,
  has_issue               BOOLEAN DEFAULT false,
  issue_note              TEXT,

  -- Photos (URLs from Fillout/Airtable)
  photo_dashboard         TEXT,
  photo_cabin             TEXT,
  photo_front             TEXT,
  photo_back              TEXT,
  photo_left_side         TEXT,
  photo_right_side        TEXT,
  photo_boots             TEXT,
  photo_issue             TEXT,
  photo_sludge_level      TEXT,
  photo_water_level       TEXT,

  -- DERM compliance photos (POST only)
  photo_derm_manifest     TEXT,
  photo_derm_address      TEXT,

  -- Expense (POST only — driver-reported shift expenses)
  has_expense             BOOLEAN DEFAULT false,
  expense_note            TEXT,
  expense_amount          NUMERIC(12,2),
  photo_expense_receipt   TEXT,

  -- Source FKs
  fillout_submission_id   TEXT UNIQUE,                -- → fillout_*_shift_inspections.submission_id
  airtable_record_id      TEXT UNIQUE,                -- → airtable_pre_post_inspection.record_id

  -- Meta
  data_sources            TEXT[],
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_inspections_vehicle ON ops.inspections(vehicle_id);
CREATE INDEX idx_inspections_date ON ops.inspections(shift_date DESC);
CREATE INDEX idx_inspections_type ON ops.inspections(inspection_type);
CREATE INDEX idx_inspections_member ON ops.inspections(team_member_id);
CREATE INDEX idx_inspections_issues ON ops.inspections(has_issue) WHERE has_issue;

COMMENT ON TABLE ops.inspections IS 'Pre/post shift truck inspections. ~480 records. Sludge delta = POST - PRE = waste collected per shift.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 12. ops.derm_manifests — DERM COMPLIANCE RECORDS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: airtable_derm (868 rows)
-- Every GT service generates a DERM manifest (Miami-Dade county req.)
-- Manifest series: DADE = 481xxx, BROWARD = 294xxx
-- Must be sent to both client AND city
-- Non-compliance fines: $500–$3,000

DROP TABLE IF EXISTS ops.derm_manifests CASCADE;

CREATE TABLE ops.derm_manifests (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  visit_id                BIGINT,                     -- → ops.visits(id), resolved after visits built

  -- Dates
  service_date            DATE,
  dump_ticket_date        DATE,

  -- Document numbers
  white_manifest_num      TEXT,                       -- White manifest #
  yellow_ticket_num       TEXT,                       -- Yellow ticket #

  -- Document images
  manifest_images         JSONB,                      -- Array of attachment URLs
  address_images          JSONB,                      -- Array of attachment URLs

  -- Compliance flags
  sent_to_client          BOOLEAN DEFAULT false,
  sent_to_city            BOOLEAN DEFAULT false,

  -- Location context
  service_address         TEXT,
  service_city            TEXT,
  service_zip             TEXT,
  service_county          TEXT,                       -- DADE or BROWARD determines manifest series

  -- Source FK
  airtable_record_id      TEXT UNIQUE,                -- → airtable_derm.record_id

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_derm_client ON ops.derm_manifests(client_id);
CREATE INDEX idx_derm_date ON ops.derm_manifests(service_date DESC);
CREATE INDEX idx_derm_unsent_client ON ops.derm_manifests(sent_to_client) WHERE NOT sent_to_client;
CREATE INDEX idx_derm_unsent_city ON ops.derm_manifests(sent_to_city) WHERE NOT sent_to_city;

COMMENT ON TABLE ops.derm_manifests IS 'DERM compliance manifests (868). County-required. Non-compliance fines: $500-$3,000. DADE=481xxx, BROWARD=294xxx.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 13. ops.routes — DAILY ROUTE PLANNING
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: airtable_route_creation (135 rows)
-- Planning: which clients need GT/CL service, assigned to whom

DROP TABLE IF EXISTS ops.routes CASCADE;

CREATE TABLE ops.routes (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),

  gt_wanted_date          DATE,
  cl_wanted_date          DATE,
  status                  TEXT,                       -- Planned | In Progress | Completed | Cancelled
  assignee                TEXT,
  zone                    TEXT,

  -- Context (denormalized for planning efficiency)
  gt_next_visit           DATE,
  cl_next_visit           DATE,
  gt_frequency_days       INTEGER,
  gt_size_gallons         NUMERIC,
  hours_in                TEXT,
  hours_out               TEXT,
  preferred_days          TEXT,

  -- Source FK
  airtable_record_id      TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_routes_client ON ops.routes(client_id);
CREATE INDEX idx_routes_gt_date ON ops.routes(gt_wanted_date);
CREATE INDEX idx_routes_status ON ops.routes(status);

COMMENT ON TABLE ops.routes IS 'Route planning from Airtable (135). Daily service route optimization.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 14. ops.past_due — OUTSTANDING BALANCE TRACKING
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Source: airtable_past_due (45 rows)
-- Note: 77 clients (42%) are late on service = ~$130K locked ARR

DROP TABLE IF EXISTS ops.past_due CASCADE;

CREATE TABLE ops.past_due (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES ops.clients(id),
  amount_due              NUMERIC(12,2),
  status                  TEXT,                       -- Open | Contacted | Payment Plan | Resolved
  assignee                TEXT,
  note                    TEXT,
  last_modified           TIMESTAMPTZ,

  -- Source FK
  airtable_record_id      TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_past_due_client ON ops.past_due(client_id);
CREATE INDEX idx_past_due_status ON ops.past_due(status);

COMMENT ON TABLE ops.past_due IS 'Outstanding balances (45). 77 clients (42%) late = ~$130K locked ARR to recover.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 15. ops.entity_map — CROSS-REFERENCE AUDIT TRAIL
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- How client IDs were matched across Airtable, Jobber, Samsara
-- Kept for audit — ops.clients is the live lookup

DROP TABLE IF EXISTS ops.entity_map CASCADE;

CREATE TABLE ops.entity_map (
  id                      BIGSERIAL PRIMARY KEY,
  canonical_name          TEXT,

  -- Source system IDs
  airtable_record_id      TEXT,
  airtable_client_code    TEXT,
  jobber_client_id        TEXT,
  jobber_client_name      TEXT,
  samsara_address_id      TEXT,
  samsara_address_name    TEXT,

  -- Match metadata
  match_method            TEXT,                       -- code_exact | name_fuzzy | manual | unmatched
  match_confidence        NUMERIC(3,2),
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE ops.entity_map IS 'Audit trail: how client IDs were matched across systems. Not for live queries — use ops.clients.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ANALYTICS VIEWS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


-- ─── v_client_health ─────────────────────────────────────────────
-- One row per active/recurring client: compliance + financial status
CREATE OR REPLACE VIEW ops.v_client_health AS
SELECT
  c.id,
  c.client_code,
  c.canonical_name,
  c.status,
  c.zone,
  c.county,
  c.gt_frequency_days,
  c.gt_size_gallons,
  c.gt_last_visit,
  c.gt_next_visit,
  c.cl_last_visit,
  c.cl_next_visit,
  c.overall_status,
  c.gdo_number,
  c.gdo_expiration_date,
  c.balance,
  c.gt_price_per_visit,
  c.cl_price_per_visit,
  c.gt_total_per_year,
  -- Days since last GT service
  CASE WHEN c.gt_last_visit IS NOT NULL
    THEN CURRENT_DATE - c.gt_last_visit
  END as days_since_last_gt,
  -- Days until next GT service
  CASE WHEN c.gt_next_visit IS NOT NULL
    THEN c.gt_next_visit - CURRENT_DATE
  END as days_until_next_gt,
  -- GT overdue? (DERM max: 90 days)
  CASE
    WHEN c.gt_next_visit IS NOT NULL AND c.gt_next_visit < CURRENT_DATE THEN true
    ELSE false
  END as gt_overdue,
  -- GDO expiring within 30 days?
  CASE
    WHEN c.gdo_expiration_date IS NOT NULL
      AND c.gdo_expiration_date <= CURRENT_DATE + INTERVAL '30 days'
    THEN true
    ELSE false
  END as gdo_expiring_soon,
  -- Visit + invoice counts
  (SELECT COUNT(*) FROM ops.visits v WHERE v.client_id = c.id AND v.is_complete) as completed_visits,
  (SELECT COUNT(*) FROM ops.invoices i WHERE i.client_id = c.id AND i.invoice_status = 'paid') as paid_invoices,
  (SELECT COALESCE(SUM(i.outstanding), 0) FROM ops.invoices i WHERE i.client_id = c.id) as total_outstanding
FROM ops.clients c
WHERE c.status IN ('ACTIVE', 'RECURRING');

COMMENT ON VIEW ops.v_client_health IS 'Active client health: compliance gaps, financial status, visit history.';


-- ─── v_service_schedule ──────────────────────────────────────────
-- Upcoming GT + CL services sorted by urgency
CREATE OR REPLACE VIEW ops.v_service_schedule AS
SELECT
  c.id as client_id, c.client_code, c.canonical_name, c.zone, c.county,
  c.address_line1, c.city,
  'GT' as service_type,
  c.gt_next_visit as next_visit_date,
  c.gt_frequency_days as frequency_days,
  c.gt_size_gallons as trap_size,
  c.gt_price_per_visit as price,
  c.truck as preferred_truck,
  c.days_of_week, c.hours_in_out,
  CASE
    WHEN c.gt_next_visit < CURRENT_DATE - 14 THEN 'CRITICAL'
    WHEN c.gt_next_visit < CURRENT_DATE THEN 'OVERDUE'
    WHEN c.gt_next_visit <= CURRENT_DATE + 7 THEN 'THIS_WEEK'
    WHEN c.gt_next_visit <= CURRENT_DATE + 14 THEN 'NEXT_WEEK'
    ELSE 'SCHEDULED'
  END as urgency
FROM ops.clients c
WHERE c.status IN ('ACTIVE', 'RECURRING') AND c.gt_next_visit IS NOT NULL

UNION ALL

SELECT
  c.id, c.client_code, c.canonical_name, c.zone, c.county,
  c.address_line1, c.city,
  'CL', c.cl_next_visit, c.cl_frequency_days, NULL, c.cl_price_per_visit,
  c.truck, c.days_of_week, c.hours_in_out,
  CASE
    WHEN c.cl_next_visit < CURRENT_DATE - 14 THEN 'CRITICAL'
    WHEN c.cl_next_visit < CURRENT_DATE THEN 'OVERDUE'
    WHEN c.cl_next_visit <= CURRENT_DATE + 7 THEN 'THIS_WEEK'
    WHEN c.cl_next_visit <= CURRENT_DATE + 14 THEN 'NEXT_WEEK'
    ELSE 'SCHEDULED'
  END
FROM ops.clients c
WHERE c.status IN ('ACTIVE', 'RECURRING') AND c.cl_next_visit IS NOT NULL

ORDER BY next_visit_date ASC;

COMMENT ON VIEW ops.v_service_schedule IS 'Upcoming services by urgency. CRITICAL > OVERDUE > THIS_WEEK > NEXT_WEEK > SCHEDULED.';


-- ─── v_compliance_dashboard ──────────────────────────────────────
-- GDO permit + service frequency compliance
-- DERM requires quarterly pump-outs (90-day max)
-- ~30% of clients are serviced less often than required
CREATE OR REPLACE VIEW ops.v_compliance_dashboard AS
SELECT
  c.id as client_id, c.client_code, c.canonical_name, c.zone, c.city, c.county,
  -- GDO permit status
  c.gdo_number,
  c.gdo_expiration_date,
  CASE
    WHEN c.gdo_number IS NULL THEN 'NO_GDO'
    WHEN c.gdo_expiration_date < CURRENT_DATE THEN 'EXPIRED'
    WHEN c.gdo_expiration_date < CURRENT_DATE + 30 THEN 'EXPIRING_30D'
    WHEN c.gdo_expiration_date < CURRENT_DATE + 90 THEN 'EXPIRING_90D'
    ELSE 'VALID'
  END as gdo_status,
  -- GT service compliance (DERM max 90 days)
  c.gt_frequency_days,
  c.gt_last_visit,
  c.gt_next_visit,
  CASE
    WHEN c.gt_next_visit IS NULL THEN 'NO_SCHEDULE'
    WHEN c.gt_next_visit < CURRENT_DATE - 14 THEN 'CRITICAL_OVERDUE'
    WHEN c.gt_next_visit < CURRENT_DATE THEN 'OVERDUE'
    WHEN c.gt_next_visit < CURRENT_DATE + 7 THEN 'DUE_SOON'
    ELSE 'ON_TRACK'
  END as gt_compliance,
  -- DERM compliance risk: frequency > 90 days
  CASE
    WHEN c.gt_frequency_days > 90 THEN true
    ELSE false
  END as exceeds_derm_max,
  -- DERM manifest tracking
  (SELECT COUNT(*) FROM ops.derm_manifests dm WHERE dm.client_id = c.id) as total_manifests,
  (SELECT COUNT(*) FROM ops.derm_manifests dm WHERE dm.client_id = c.id AND NOT dm.sent_to_client) as unsent_to_client,
  (SELECT COUNT(*) FROM ops.derm_manifests dm WHERE dm.client_id = c.id AND NOT dm.sent_to_city) as unsent_to_city
FROM ops.clients c
WHERE c.status IN ('ACTIVE', 'RECURRING')
ORDER BY
  CASE
    WHEN c.gdo_expiration_date < CURRENT_DATE THEN 1
    WHEN c.gt_next_visit < CURRENT_DATE - 14 THEN 2
    WHEN c.gt_next_visit < CURRENT_DATE THEN 3
    WHEN c.gdo_expiration_date < CURRENT_DATE + 30 THEN 4
    ELSE 5
  END,
  c.gt_next_visit ASC NULLS LAST;

COMMENT ON VIEW ops.v_compliance_dashboard IS 'Compliance dashboard. DERM 90-day max. ~30% of clients at risk. Fines: $500-$3,000.';


-- ─── v_fleet_daily ───────────────────────────────────────────────
-- Daily fleet utilization from Samsara telemetry
-- Note: Goliath may not have Samsara data (samsara_vehicle_id NULL)
-- This view will be populated when connected to the source Supabase
CREATE OR REPLACE VIEW ops.v_fleet_daily AS
SELECT
  v.id as vehicle_id,
  v.name as vehicle_name,
  v.short_code,
  v.tank_capacity_gallons,
  v.status as vehicle_status,
  v.samsara_vehicle_id
FROM ops.vehicles v
ORDER BY v.name;
-- Full implementation with Samsara telemetry JOIN will be added
-- when the source database connection is established

COMMENT ON VIEW ops.v_fleet_daily IS 'Fleet utilization placeholder. Full telemetry view requires source DB connection.';


-- ─── v_shift_summary ─────────────────────────────────────────────
-- Daily shift recap: driver, truck, sludge delta, issues, expenses
CREATE OR REPLACE VIEW ops.v_shift_summary AS
SELECT
  COALESCE(pre.shift_date, post.shift_date) as shift_date,
  tm.full_name as driver_name,
  v.name as vehicle_name,
  pre.sludge_gallons as sludge_start,
  post.sludge_gallons as sludge_end,
  COALESCE(post.sludge_gallons, 0) - COALESCE(pre.sludge_gallons, 0) as sludge_collected,
  post.water_gallons,
  pre.gas_level as gas_start,
  post.gas_level as gas_end,
  pre.has_issue as pre_shift_issue,
  post.has_issue as post_shift_issue,
  pre.issue_note as pre_issue_note,
  post.issue_note as post_issue_note,
  post.has_expense,
  post.expense_note,
  post.expense_amount,
  pre.submitted_at as pre_submitted_at,
  post.submitted_at as post_submitted_at,
  CASE WHEN pre.id IS NULL THEN true ELSE false END as missing_pre_shift,
  CASE WHEN post.id IS NULL THEN true ELSE false END as missing_post_shift
FROM ops.inspections pre
FULL OUTER JOIN ops.inspections post
  ON pre.vehicle_id = post.vehicle_id
  AND pre.shift_date = post.shift_date
  AND pre.inspection_type = 'PRE'
  AND post.inspection_type = 'POST'
LEFT JOIN ops.team_members tm ON tm.id = COALESCE(pre.team_member_id, post.team_member_id)
LEFT JOIN ops.vehicles v ON v.id = COALESCE(pre.vehicle_id, post.vehicle_id)
WHERE (pre.inspection_type = 'PRE' OR pre.id IS NULL)
  AND (post.inspection_type = 'POST' OR post.id IS NULL)
ORDER BY COALESCE(pre.shift_date, post.shift_date) DESC;

COMMENT ON VIEW ops.v_shift_summary IS 'Shift recap: sludge_collected = POST - PRE. Flags missing inspections.';


-- ─── v_revenue_summary ───────────────────────────────────────────
-- Revenue by client, month, payment status
CREATE OR REPLACE VIEW ops.v_revenue_summary AS
SELECT
  c.id as client_id,
  c.client_code,
  c.canonical_name,
  c.zone,
  c.county,
  DATE_TRUNC('month', COALESCE(i.paid_at, i.due_date, i.created_at))::date as month,
  COUNT(*) as invoice_count,
  SUM(i.total) as total_billed,
  SUM(CASE WHEN i.invoice_status = 'paid' THEN i.total ELSE 0 END) as collected,
  SUM(i.outstanding) as outstanding
FROM ops.invoices i
JOIN ops.clients c ON c.id = i.client_id
GROUP BY c.id, c.client_code, c.canonical_name, c.zone, c.county,
         DATE_TRUNC('month', COALESCE(i.paid_at, i.due_date, i.created_at))::date
ORDER BY month DESC, total_billed DESC;

COMMENT ON VIEW ops.v_revenue_summary IS 'Revenue by client and month. Current total: ~$674K/year, targeting $200K+/month.';


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- AUTO-UPDATE TRIGGERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOR tbl IN
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'ops' AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%I_updated_at ON ops.%I;
       CREATE TRIGGER trg_%I_updated_at
         BEFORE UPDATE ON ops.%I
         FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();',
      tbl, tbl, tbl, tbl
    );
  END LOOP;
END $$;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DATA FLOW REFERENCE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
-- SOURCE                          → ops TABLE             → VIEW
-- ────────────────────────────────────────────────────────────────
-- airtable_clients (185)    ─┐
-- jobber_clients (364)      ─┼──→ ops.clients (491)  ──→ v_client_health
-- samsara.addresses (192)   ─┘                        ──→ v_compliance_dashboard
--                                                     ──→ v_service_schedule
--
-- jobber_properties (367)   ────→ ops.properties (367)
--
-- airtable_drivers_team (9) ─┐
-- samsara.drivers (7)       ─┼──→ ops.team_members    ──→ v_shift_summary
-- jobber_users (25)         ─┘
--
-- samsara.vehicles (3)      ─┐
-- airtable_vehicles (4)     ─┴──→ ops.vehicles (4)    ──→ v_fleet_daily
--
-- jobber_jobs (507)         ────→ ops.jobs (507)
--
-- airtable_visits (3016)    ─┐
-- jobber_visits (1636)      ─┴──→ ops.visits (~3100)  ──→ v_service_schedule
--
-- jobber_invoices (1583)    ────→ ops.invoices (1583)  ──→ v_revenue_summary
--
-- jobber_quotes (171)       ────→ ops.quotes (171)
--
-- jobber_line_items (0!)    ────→ ops.line_items       ** BLOCKED: sync broken **
--
-- Ramp API (TBD)            ─┐
-- fillout_post_shift (150)  ─┴──→ ops.expenses
--
-- fillout_pre_shift (94)    ─┐
-- fillout_post_shift (150)  ─┼──→ ops.inspections     ──→ v_shift_summary
-- airtable_pre_post (239)   ─┘
--
-- airtable_derm (868)       ────→ ops.derm_manifests   ──→ v_compliance_dashboard
--
-- airtable_route_creation   ────→ ops.routes (135)
--
-- airtable_past_due (45)    ────→ ops.past_due (45)
--
-- ════════════════════════════════════════════════════════════════════
-- END OF BLUEPRINT v2.0
-- ════════════════════════════════════════════════════════════════════
