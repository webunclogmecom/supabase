-- ============================================================
-- ops.clients — THE ONE SOURCE OF TRUTH
-- ============================================================
-- This is the canonical client table that merges data from:
--   1. Airtable (airtable_clients)  — service details, compliance, scheduling
--   2. Jobber (jobber_clients)      — contact info, billing, balance
--   3. Samsara (samsara.addresses)  — GPS coordinates, geofence
--   4. QuickBooks (future)          — accounting/invoicing
--
-- Design principles:
--   - Each row = one real-world client/location
--   - Foreign keys link back to source system records
--   - COALESCE merge priority: Airtable > Jobber > Samsara
--   - Every field has a clear owner (which source is authoritative)
--   - Safe to rebuild from scratch (idempotent)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS ops;

-- Drop and recreate for clean rebuild
DROP TABLE IF EXISTS ops.clients CASCADE;

CREATE TABLE ops.clients (
  id                    BIGSERIAL PRIMARY KEY,

  -- === IDENTITY ===
  client_code           TEXT,                     -- 3-digit prefix: "009", "041", etc.
  canonical_name        TEXT NOT NULL,             -- Clean name without code prefix
  display_name          TEXT,                      -- Full display: "009-CN Casa Neos"

  -- === STATUS ===
  status                TEXT,                      -- ACTIVE, RECURRING, PAUSED, INACTIVE
  overall_status        TEXT,                      -- On Time, GT Late, CL Late, GT-CL Late, etc.

  -- === ADDRESS (merged, Airtable > Jobber > Samsara) ===
  address_line1         TEXT,
  city                  TEXT,
  state                 TEXT,
  zip_code              TEXT,
  county                TEXT,
  zone                  TEXT,                      -- Airtable zone: NMB, MIA, etc.
  latitude              NUMERIC(10,7),
  longitude             NUMERIC(10,7),

  -- === CONTACT (from Jobber primarily) ===
  email                 TEXT,
  phone                 TEXT,
  accounting_email      TEXT,                      -- From Airtable
  operation_email       TEXT,                      -- From Airtable

  -- === SERVICE DETAILS (from Airtable — authoritative) ===
  service_type          TEXT[],                    -- {Grease Trap, Drain Cleaning, AUX Cleaning}
  truck                 TEXT[],                    -- {INT, TOY, KEN}
  gt_frequency_days     INTEGER,                   -- Grease trap service frequency in days
  cl_frequency_days     INTEGER,                   -- Drain cleaning frequency in days
  gt_price_per_visit    NUMERIC(10,2),
  cl_price_per_visit    NUMERIC(10,2),
  gt_size_gallons       NUMERIC,                   -- Grease trap capacity
  gt_status             TEXT,                      -- Current GT compliance status
  cl_status             TEXT,                      -- Current CL compliance status
  gt_last_visit         DATE,
  gt_next_visit         DATE,
  cl_last_visit         DATE,
  cl_next_visit         DATE,
  gt_total_per_year     NUMERIC(10,2),

  -- === COMPLIANCE (from Airtable) ===
  gdo_number            TEXT,                      -- Grease Disposal Order #
  gdo_expiration_date   DATE,
  contract_warranty     TEXT,                      -- Contract/warranty info

  -- === SCHEDULING (from Airtable) ===
  days_of_week          TEXT,                      -- Preferred service days
  hours_in_out          TEXT,                      -- Access hours

  -- === FINANCIAL (from Jobber) ===
  balance               NUMERIC(10,2),             -- Outstanding balance

  -- === FOREIGN KEYS TO SOURCE SYSTEMS ===
  airtable_record_id    TEXT UNIQUE,               -- → public.airtable_clients.record_id
  jobber_client_id      TEXT UNIQUE,               -- → public.jobber_clients.id
  samsara_address_id    TEXT UNIQUE,               -- → samsara.addresses.id
  qb_customer_id        TEXT UNIQUE,               -- → public.quickbooks_customers.qb_id (future)

  -- === SAMSARA GEOFENCE ===
  geofence_radius_meters NUMERIC,
  geofence_type         TEXT,                      -- circle, polygon

  -- === META ===
  data_sources          TEXT[],                    -- Which systems have this client: {airtable, jobber, samsara}
  match_method          TEXT,                      -- How the cross-match was made
  match_confidence      NUMERIC(3,2),              -- 0.00-1.00
  notes                 TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

-- === INDEXES ===
CREATE INDEX idx_ops_clients_code ON ops.clients(client_code);
CREATE INDEX idx_ops_clients_status ON ops.clients(status);
CREATE INDEX idx_ops_clients_zone ON ops.clients(zone);
CREATE INDEX idx_ops_clients_canonical ON ops.clients(canonical_name);
CREATE INDEX idx_ops_clients_display ON ops.clients(display_name);

-- === COMMENTS ===
COMMENT ON TABLE ops.clients IS 'Canonical client table — single source of truth merging Airtable, Jobber, Samsara, and QuickBooks';
COMMENT ON COLUMN ops.clients.client_code IS '3-digit code prefix from Samsara/Airtable naming convention (e.g., 009)';
COMMENT ON COLUMN ops.clients.canonical_name IS 'Cleaned client name without code prefix or abbreviation';
COMMENT ON COLUMN ops.clients.status IS 'Normalized from Airtable active_inactive: ACTIVE, RECURRING, PAUSED, INACTIVE';
COMMENT ON COLUMN ops.clients.data_sources IS 'Array of source systems: airtable, jobber, samsara, quickbooks';
