-- ============================================================================
-- UNCLOGME — CLEAN PRODUCTION DATABASE
-- ============================================================================
--
-- Target:   NEW Supabase project (wbasvhvvismukaqdnouk)
-- Created:  2026-04-03
-- Author:   Claude (System Architect) for Fred Zerpa & Yan Ayache
--
-- Design:   2NF/3NF normalized, all tables related, no orphans
-- Source:   Raw data lives in OLD Supabase (infbofuilnqqviyjlwul)
--
-- Tables (20):
--   clients              WHO we serve
--   properties           WHERE we serve them
--   service_configs      WHAT services per client (3NF: no repeating groups)
--   vehicles             WHAT equipment we use
--   employees            WHO does the work
--   jobs                 WHAT work is ordered
--   visits               WHEN work was performed
--   visit_assignments    WHO performed each visit (M:N)
--   invoices             WHAT we billed
--   quotes               WHAT we proposed
--   line_items           Service details per job/quote
--   inspections          Truck pre/post shift checks
--   expenses             WHAT we spent
--   derm_manifests       DERM compliance records
--   manifest_visits      DERM manifest <-> visit links (M:N)
--   routes               Daily route planning
--   receivables          Outstanding balance tracking
--   source_map           Cross-system ID audit trail
--   leads                Pre-client sales pipeline
--   sync_log             Nightly sync audit trail (system/ops)
--
-- Conventions:
--   - BIGSERIAL PKs (database-owned identity)
--   - Source system IDs stored as TEXT UNIQUE (for sync/upsert)
--   - All timestamps UTC; display layer converts to EDT
--   - All money NUMERIC(12,2)
--   - updated_at auto-managed by trigger
--   - Overnight ops: trucks work through midnight, use +/-12h query windows
--   - Work week: Sunday -> Saturday
--
-- ============================================================================


-- ============================================================================
-- 0. UTILITY FUNCTIONS
-- ============================================================================

-- Auto-update updated_at on row modification
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


-- ============================================================================
-- 1. clients — WHO WE SERVE
-- ============================================================================
-- Sources: airtable_clients (185), jobber_clients (364), samsara.addresses (192)
-- Expected: ~491 merged rows
-- Jobber is source of truth for contact/billing data
-- Airtable is CRM master for service details and compliance
-- Samsara adds GPS/geofence data

CREATE TABLE clients (
  id                      BIGSERIAL PRIMARY KEY,

  -- Identity
  client_code             TEXT,                       -- 3-digit Airtable prefix: "009"
  name                    TEXT NOT NULL,              -- Clean name: "Casa Neos"
  display_name            TEXT,                       -- Full display: "009-CN Casa Neos"
  status                  TEXT,                       -- ACTIVE | RECURRING | PAUSED | INACTIVE

  -- Address (priority: Jobber > Airtable > Samsara)
  address_line1           TEXT,
  city                    TEXT,
  state                   TEXT DEFAULT 'FL',
  zip_code                TEXT,
  county                  TEXT,                       -- Miami-Dade | Broward | Palm Beach
  zone                    TEXT,                       -- Service zone: NMB, MIAMI BEACH, BRO, DOWN, etc.
  latitude                NUMERIC(10,7),
  longitude               NUMERIC(10,7),

  -- Contact (from Jobber primarily)
  email                   TEXT,
  phone                   TEXT,
  accounting_email        TEXT,                       -- Billing contact (Airtable)
  operation_email         TEXT,                       -- Ops contact (Airtable)
  accounting_phone        TEXT,
  operation_phone         TEXT,
  city_email              TEXT,                       -- City/DERM contact email
  op_name                 TEXT,                       -- Operations contact name
  acct_name               TEXT,                       -- Accounting contact name

  -- Scheduling preferences
  days_of_week            TEXT[],                     -- Preferred service days
  hours_in                TEXT,                       -- Access window start
  hours_out               TEXT,                       -- Access window end

  -- Compliance (DERM)
  gdo_number              TEXT,                       -- Grease Disposal Order permit #
  gdo_expiration_date     DATE,
  gdo_frequency           INTEGER,                   -- GDO-mandated frequency in days

  -- Contract
  contract_warranty       TEXT[],
  signature_date          DATE,
  photo_location_gt       TEXT,                       -- Photo of GT location

  -- Financial (from Jobber)
  balance                 NUMERIC(12,2),

  -- Physical attributes (location-specific, not service-config)
  gt_size_gallons         NUMERIC,                   -- Grease trap capacity (33 clients missing!)

  -- Samsara geofence
  geofence_radius_meters  NUMERIC,
  geofence_type           TEXT,                       -- circle | polygon

  -- Source system FKs (for sync/upsert)
  airtable_record_id      TEXT UNIQUE,
  jobber_client_id        TEXT UNIQUE,
  samsara_address_id      TEXT UNIQUE,

  -- Meta
  data_sources            TEXT[],                     -- {airtable, jobber, samsara}
  match_method            TEXT,                       -- How cross-system match was made
  match_confidence        NUMERIC(3,2),
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_clients_code ON clients(client_code);
CREATE INDEX idx_clients_status ON clients(status);
CREATE INDEX idx_clients_zone ON clients(zone);
CREATE INDEX idx_clients_name ON clients(name);
CREATE INDEX idx_clients_county ON clients(county);

COMMENT ON TABLE clients IS 'Canonical client table. ~491 rows merged from Airtable (CRM) + Jobber (billing) + Samsara (geofence). Jobber is source of truth for contact data.';


-- ============================================================================
-- 2. properties — WHERE WE SERVE THEM
-- ============================================================================
-- Source: jobber_properties (367 rows)
-- Chains have multiple: La Granja 5+, Carrot Express 4+, Grove Kosher 4

CREATE TABLE properties (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  name                    TEXT,
  street                  TEXT,
  city                    TEXT,
  state                   TEXT DEFAULT 'FL',
  postal_code             TEXT,
  country                 TEXT DEFAULT 'US',
  is_billing_address      BOOLEAN DEFAULT false,

  -- Source FK
  jobber_property_id      TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_properties_client ON properties(client_id);

COMMENT ON TABLE properties IS 'Service locations per client. 367 rows from Jobber. 1 client -> many properties (chains like La Granja have 5+).';


-- ============================================================================
-- 3. service_configs — WHAT SERVICES PER CLIENT (3NF)
-- ============================================================================
-- Normalized from airtable_clients repeating groups:
--   gt_frequency, cl_frequency, wd_frequency
--   gt_price, cl_price, wd_price
--   gt_last_visit, cl_last_visit, etc.
--
-- Each client x service_type gets its own row.
-- Adding new service types (sump pump, grey water) = new rows, not schema changes.

CREATE TABLE service_configs (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  service_type            TEXT NOT NULL,              -- GT | CL | WD | AUX | SUMP | GREY_WATER | WARRANTY

  -- Scheduling
  frequency_days          INTEGER,                   -- Service interval in days (DERM max: 90 for GT)
  first_visit_date        DATE,
  last_visit              DATE,
  next_visit              DATE,
  next_visit_calculated   TEXT,                       -- Formula-derived next visit
  stop_date               DATE,                       -- Service discontinued date

  -- Pricing
  price_per_visit         NUMERIC(12,2),
  total_per_year          NUMERIC(12,2),              -- Actual annual revenue
  projected_year          NUMERIC(12,2),              -- Projected annual revenue

  -- Status
  status                  TEXT,                       -- On Time | Late | Critical | Paused
  visits_available        BOOLEAN DEFAULT true,       -- Can visits be scheduled?

  -- Data quality (Viktor: GT last_visit is computed, CL is manual, WD doesn't exist)
  data_quality            TEXT,                       -- computed | manual | synced
  schedule_notes          TEXT,                       -- Free-text like "Every 2nd Monday"

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE(client_id, service_type)
);

CREATE INDEX idx_svcconfig_client ON service_configs(client_id);
CREATE INDEX idx_svcconfig_type ON service_configs(service_type);
CREATE INDEX idx_svcconfig_next ON service_configs(next_visit);
CREATE INDEX idx_svcconfig_status ON service_configs(status);

COMMENT ON TABLE service_configs IS '3NF: one row per client per service type. Eliminates gt_*/cl_*/wd_* repeating groups. DERM max 90 days. EMERGENCY is visit-level only, not a service config.';


-- ============================================================================
-- 4. vehicles — THE FLEET
-- ============================================================================
-- Sources: samsara.vehicles (3), airtable_vehicles (4)
-- 4 trucks total. 17% capacity — can serve 700+ clients.
--
-- CRITICAL: Vehicle names are people names!
--   "Moise" and "David" are TRUCKS, not drivers!
--
-- Cloggy   | Toyota Tundra 2020  | 126 gal   | Day jobs
-- David    | International 2017  | 1,800 gal | Night commercial
-- Goliath  | Peterbilt 579 2019  | 4,800 gal | Large commercial
-- Moise    | Kenworth T880 2023  | 9,000 gal | Large commercial

CREATE TABLE vehicles (
  id                      BIGSERIAL PRIMARY KEY,
  name                    TEXT NOT NULL UNIQUE,       -- Moise, Cloggy, David, Goliath
  short_code              TEXT,                       -- KEN, TOY, INT, PET
  make                    TEXT,
  model                   TEXT,
  year                    INTEGER,
  vin                     TEXT UNIQUE,
  license_plate           TEXT,

  -- Operational
  tank_capacity_gallons   NUMERIC NOT NULL,
  primary_use             TEXT,                       -- Day jobs | Night commercial | Large commercial
  status                  TEXT DEFAULT 'ACTIVE',      -- ACTIVE | OUT_OF_SERVICE | RETIRED

  -- Samsara hardware
  gateway_serial          TEXT,
  gateway_model           TEXT,
  camera_serial           TEXT,

  -- Source FKs
  samsara_vehicle_id      TEXT UNIQUE,                -- NULL for Goliath (not on Samsara)
  airtable_record_id      TEXT UNIQUE,

  -- Meta
  data_sources            TEXT[],
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE vehicles IS '4 trucks at 17% capacity. Names are people names (Moise, David = TRUCKS not drivers). Goliath has no Samsara data.';


-- ============================================================================
-- 5. employees — WHO DOES THE WORK
-- ============================================================================
-- Sources: airtable_drivers_team (9), samsara.drivers (7), jobber_users (25)
-- Covers: owners, managers, admins, office staff, field technicians
--
-- Access hierarchy:
--   dev (Fred, Yan) > office (Aaron, Diego) > field (techs)
--   Field staff: NO access to financial/payment/client account data

CREATE TABLE employees (
  id                      BIGSERIAL PRIMARY KEY,
  full_name               TEXT NOT NULL,
  first_name              TEXT,
  last_name               TEXT,
  role                    TEXT,                       -- Owner | Manager | Admin | Team Lead | Technician | Part-Time | Office Manager
  status                  TEXT DEFAULT 'ACTIVE',      -- ACTIVE | INACTIVE | DEACTIVATED
  shift                   TEXT,                       -- Day | Night | Both
  access_level            TEXT,                       -- dev | office | field

  -- Contact
  email                   TEXT,
  phone                   TEXT,

  -- Employment
  hire_date               DATE,
  cdl_license             TEXT,
  certifications          TEXT[],
  emergency_contact       TEXT,

  -- Samsara driver info
  license_state           TEXT,
  driver_activation       TEXT,                       -- active | deactivated
  eld_settings            JSONB,

  -- Jobber user info
  is_account_owner        BOOLEAN DEFAULT false,
  is_account_admin        BOOLEAN DEFAULT false,

  -- Source system FKs
  airtable_record_id      TEXT UNIQUE,
  samsara_driver_id       TEXT UNIQUE,
  jobber_user_id          TEXT UNIQUE,
  fillout_display_name    TEXT,                       -- Name as shown in Fillout forms (for joining inspections)

  -- Meta
  data_sources            TEXT[],
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_employees_status ON employees(status);
CREATE INDEX idx_employees_role ON employees(role);
CREATE INDEX idx_employees_access ON employees(access_level);
CREATE INDEX idx_employees_fillout ON employees(fillout_display_name) WHERE fillout_display_name IS NOT NULL;

COMMENT ON TABLE employees IS 'All team members: 10 active. Access levels: dev > office > field. Field staff CANNOT access financial data.';


-- ============================================================================
-- 6. jobs — WHAT WORK IS ORDERED
-- ============================================================================
-- Source: jobber_jobs (507 rows)
-- A job = a work order. Can be recurring or one-off.
-- Recurring jobs generate visits on a schedule.

CREATE TABLE jobs (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
  property_id             BIGINT REFERENCES properties(id),

  -- Identity
  job_number              TEXT,
  title                   TEXT,
  instructions            TEXT,

  -- Classification
  job_type                TEXT,                       -- RECURRING | ONE_OFF
  billing_type            TEXT,                       -- VISIT_BASED | FIXED_PRICE
  service_category        TEXT,                       -- GT | CL | HYDROJET | CAMERA | EMERGENCY | OTHER

  -- Status & scheduling
  job_status              TEXT,                       -- active | upcoming | completed | archived
  start_at                TIMESTAMPTZ,
  end_at                  TIMESTAMPTZ,
  completed_at            TIMESTAMPTZ,

  -- Financial
  total                   NUMERIC(12,2),
  invoiced_total          NUMERIC(12,2),
  uninvoiced_total        NUMERIC(12,2),

  -- Relationships resolved post-population
  quote_id                BIGINT REFERENCES quotes(id),  -- Resolved from jobber_quote_id after quotes loaded

  -- Source FKs
  jobber_job_id           TEXT UNIQUE,
  jobber_quote_id         TEXT,                       -- Source audit: Jobber quote ID (resolved → quote_id FK)

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_jobs_client ON jobs(client_id);
CREATE INDEX idx_jobs_property ON jobs(property_id);
CREATE INDEX idx_jobs_status ON jobs(job_status);
CREATE INDEX idx_jobs_quote ON jobs(quote_id);
CREATE INDEX idx_jobs_type ON jobs(job_type);
CREATE INDEX idx_jobs_start ON jobs(start_at);

COMMENT ON TABLE jobs IS 'Work orders from Jobber (507). Recurring GT/CL services + one-off emergency/hydrojet calls.';


-- ============================================================================
-- 7. visits — WHEN/WHERE WORK WAS PERFORMED
-- ============================================================================
-- Sources: airtable_visits (3,016), jobber_visits (1,636)
-- THIS IS THE CORE OPERATIONS TABLE
-- ~1,400 gap = historical Airtable visits pre-Jobber adoption
-- Matching key: airtable_visits.jobber_visit_id = jobber_visits.id
--
-- Overnight ops: a 10 PM job ends at 3 AM. Always use +/-12h windows.

CREATE TABLE visits (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
  property_id             BIGINT REFERENCES properties(id),
  job_id                  BIGINT REFERENCES jobs(id),     -- nullable: ~18 orphans + historical AT visits
  vehicle_id              BIGINT REFERENCES vehicles(id),

  -- When
  visit_date              DATE NOT NULL,
  start_at                TIMESTAMPTZ,
  end_at                  TIMESTAMPTZ,
  completed_at            TIMESTAMPTZ,
  duration_minutes        INTEGER,

  -- What
  title                   TEXT,
  instructions            TEXT,
  service_type            TEXT,                       -- GT | CL | AUX | HYDROJET | CAMERA | EMERGENCY
  visit_status            TEXT,                       -- COMPLETED | UPCOMING | UNSCHEDULED | CANCELLED | LATE
  is_complete             BOOLEAN DEFAULT false,

  -- Financial
  amount                  NUMERIC(12,2),

  -- Operational context
  truck                   TEXT,                       -- Truck name from Airtable (denormalized for historical)
  zone                    TEXT,
  completed_by            TEXT,

  -- Compliance
  late_status             TEXT,
  late_status_gt_freq     TEXT,

  -- GPS enrichment (populated by Samsara trip matching)
  actual_arrival_at       TIMESTAMPTZ,
  actual_departure_at     TIMESTAMPTZ,
  gps_confirmed           BOOLEAN DEFAULT false,

  -- Relationships resolved post-population
  invoice_id              BIGINT REFERENCES invoices(id),  -- Resolved from jobber_invoice_id after invoices loaded

  -- Source FKs
  airtable_record_id      TEXT UNIQUE,
  jobber_visit_id         TEXT UNIQUE,
  jobber_invoice_id       TEXT,                       -- Source audit: Jobber invoice ID (resolved → invoice_id FK)

  -- Meta
  data_sources            TEXT[],
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_visits_client ON visits(client_id);
CREATE INDEX idx_visits_date ON visits(visit_date DESC);
CREATE INDEX idx_visits_status ON visits(visit_status);
CREATE INDEX idx_visits_type ON visits(service_type);
CREATE INDEX idx_visits_vehicle ON visits(vehicle_id);
CREATE INDEX idx_visits_job ON visits(job_id);
CREATE INDEX idx_visits_invoice ON visits(invoice_id);
CREATE INDEX idx_visits_incomplete ON visits(is_complete) WHERE NOT is_complete;

COMMENT ON TABLE visits IS 'CORE TABLE. Every service event. ~3,100 rows merged from Airtable (3,016) + Jobber (1,636). Overnight ops: +/-12h query windows.';


-- ============================================================================
-- 8. visit_assignments — WHO PERFORMED EACH VISIT (M:N)
-- ============================================================================
-- Source: jobber_visit_assignments (1,589 rows)
-- Night commercial visits often have 2-person crews (40% faster)
-- Day residential (Cloggy) usually 1 driver solo

CREATE TABLE visit_assignments (
  visit_id                BIGINT NOT NULL REFERENCES visits(id) ON DELETE CASCADE,
  employee_id             BIGINT NOT NULL REFERENCES employees(id) ON DELETE CASCADE,

  PRIMARY KEY (visit_id, employee_id)
);

CREATE INDEX idx_va_employee ON visit_assignments(employee_id);

COMMENT ON TABLE visit_assignments IS 'M:N junction. 2+ techs on large truck visits (David/Goliath/Moise). 1,589 assignments from Jobber.';


-- ============================================================================
-- 9. invoices — WHAT WE BILLED
-- ============================================================================
-- Source: jobber_invoices (1,583 rows)
-- Jobber is billing AND payment system. paid_at = when payment received.
-- No QuickBooks reconciliation needed.
-- 1 invoice can cover multiple visits (via job).
-- Outstanding A/R: ~$132,749

CREATE TABLE invoices (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
  job_id                  BIGINT REFERENCES jobs(id),

  -- Identity
  invoice_number          TEXT,
  subject                 TEXT,
  message                 TEXT,

  -- Financial
  subtotal                NUMERIC(12,2),
  tax_amount              NUMERIC(12,2),
  total                   NUMERIC(12,2),
  outstanding             NUMERIC(12,2),
  deposit_amount          NUMERIC(12,2),

  -- Status & dates
  invoice_status          TEXT,                       -- draft | sent | awaiting_payment | paid | void | overdue | bad_debt
  due_date                DATE,
  sent_at                 TIMESTAMPTZ,
  paid_at                 TIMESTAMPTZ,               -- Payment received date (from Jobber)

  -- Source FK
  jobber_invoice_id       TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_invoices_client ON invoices(client_id);
CREATE INDEX idx_invoices_job ON invoices(job_id);
CREATE INDEX idx_invoices_status ON invoices(invoice_status);
CREATE INDEX idx_invoices_due ON invoices(due_date);
CREATE INDEX idx_invoices_outstanding ON invoices(outstanding) WHERE outstanding > 0;

COMMENT ON TABLE invoices IS 'Invoices from Jobber (1,583). Payment via paid_at. Outstanding A/R: ~$132K. No QuickBooks needed.';


-- ============================================================================
-- 10. quotes — WHAT WE PROPOSED
-- ============================================================================
-- Source: jobber_quotes (171 rows)
-- Pipeline includes high-value unsigned contracts (Casa Neos, Chima, etc.)

CREATE TABLE quotes (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
  property_id             BIGINT REFERENCES properties(id),

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
  jobber_quote_id         TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_quotes_client ON quotes(client_id);
CREATE INDEX idx_quotes_status ON quotes(quote_status);

COMMENT ON TABLE quotes IS 'Sales quotes from Jobber (171). Pipeline: 5 high-value unsigned contracts.';


-- ============================================================================
-- 11. line_items — SERVICE DETAILS PER JOB/QUOTE
-- ============================================================================
-- Source: jobber_line_items (currently 0 rows — sync needs repair)
-- Hierarchy: line items belong to a job OR a quote (polymorphic in Jobber)
-- Invoice pulls line items from the parent job

CREATE TABLE line_items (
  id                      BIGSERIAL PRIMARY KEY,
  job_id                  BIGINT REFERENCES jobs(id),
  quote_id                BIGINT REFERENCES quotes(id),

  name                    TEXT,
  description             TEXT,
  quantity                NUMERIC(10,2),
  unit_price              NUMERIC(12,2),
  total_price             NUMERIC(12,2),
  taxable                 BOOLEAN DEFAULT false,

  -- Source FK
  jobber_line_item_id     TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW(),

  -- Must belong to either a job or a quote
  CONSTRAINT line_item_parent CHECK (job_id IS NOT NULL OR quote_id IS NOT NULL)
);

CREATE INDEX idx_lineitems_job ON line_items(job_id);
CREATE INDEX idx_lineitems_quote ON line_items(quote_id);

COMMENT ON TABLE line_items IS 'Service line items per job/quote. Currently 0 rows (Jobber sync broken). CHECK: must have job_id or quote_id.';


-- ============================================================================
-- 12. inspections — TRUCK PRE/POST SHIFT CHECKS
-- ============================================================================
-- Sources: fillout_pre_shift (95), fillout_post_shift (150),
--          airtable_pre_post_inspection (241)
-- Every shift: PRE check at start, POST check at end.
-- sludge_delta (POST - PRE) = waste collected per shift.
-- Shift = (shift_date, vehicle, employee) — not a formal entity.

CREATE TABLE inspections (
  id                      BIGSERIAL PRIMARY KEY,
  vehicle_id              BIGINT REFERENCES vehicles(id),
  employee_id             BIGINT REFERENCES employees(id),

  shift_date              DATE NOT NULL,
  inspection_type         TEXT NOT NULL,              -- PRE | POST
  submitted_at            TIMESTAMPTZ,

  -- Tank / fuel levels
  sludge_gallons          INTEGER,
  water_gallons           INTEGER,                   -- POST only
  gas_level               TEXT,                       -- Full | 3/4 | 1/2 | 1/4 | Empty

  -- Condition
  valve_is_closed         BOOLEAN,
  has_issue               BOOLEAN DEFAULT false,
  issue_note              TEXT,

  -- Photos (URLs)
  photo_dashboard         TEXT,
  photo_cabin             TEXT,
  photo_cabin_side_left   TEXT,
  photo_cabin_side_right  TEXT,
  photo_front             TEXT,
  photo_back              TEXT,
  photo_left_side         TEXT,
  photo_right_side        TEXT,
  photo_boots             TEXT,
  photo_remote            TEXT,
  photo_closed_valve      TEXT,
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
  fillout_submission_id   TEXT UNIQUE,
  airtable_record_id      TEXT UNIQUE,

  -- Meta
  data_sources            TEXT[],
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_inspections_vehicle ON inspections(vehicle_id);
CREATE INDEX idx_inspections_employee ON inspections(employee_id);
CREATE INDEX idx_inspections_date ON inspections(shift_date DESC);
CREATE INDEX idx_inspections_type ON inspections(inspection_type);
CREATE INDEX idx_inspections_issues ON inspections(has_issue) WHERE has_issue;

-- Prevent duplicate form submissions for same shift (Viktor recommendation)
CREATE UNIQUE INDEX idx_inspections_shift_unique
  ON inspections(shift_date, vehicle_id, employee_id, inspection_type)
  WHERE vehicle_id IS NOT NULL AND employee_id IS NOT NULL;

COMMENT ON TABLE inspections IS 'Pre/post shift truck inspections. ~480 records. Sludge delta = POST.sludge - PRE.sludge = waste collected.';


-- ============================================================================
-- 13. expenses — WHAT WE SPENT
-- ============================================================================
-- Sources: Ramp (company cards, TBD), Fillout post-shift (driver reports)
-- Always 1 expense -> 1 employee + 1 vehicle

CREATE TABLE expenses (
  id                      BIGSERIAL PRIMARY KEY,
  expense_date            DATE NOT NULL,
  amount                  NUMERIC(12,2),
  description             TEXT,
  category                TEXT,                       -- Fuel | Maintenance | Dump Fee | Supplies | Tools | Other

  -- Context
  vendor_name             TEXT,
  vehicle_id              BIGINT REFERENCES vehicles(id),
  employee_id             BIGINT REFERENCES employees(id),
  receipt_url             TEXT,

  -- Ramp card info (when available)
  ramp_card_holder        TEXT,
  ramp_merchant           TEXT,

  -- Source FKs
  ramp_transaction_id     TEXT UNIQUE,
  fillout_submission_id   TEXT UNIQUE,

  -- Meta
  data_sources            TEXT[],
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_expenses_date ON expenses(expense_date);
CREATE INDEX idx_expenses_vehicle ON expenses(vehicle_id);
CREATE INDEX idx_expenses_employee ON expenses(employee_id);
CREATE INDEX idx_expenses_category ON expenses(category);

COMMENT ON TABLE expenses IS 'Unified expenses from Ramp (corporate cards) + driver shift reports (Fillout). 1 expense = 1 employee + 1 vehicle.';


-- ============================================================================
-- 14. derm_manifests — DERM COMPLIANCE RECORDS
-- ============================================================================
-- Source: airtable_derm (868 rows)
-- Every GT service generates a DERM manifest (Miami-Dade county req.)
-- Manifest series: DADE = 481xxx, BROWARD = 294xxx
-- Non-compliance fines: $500-$3,000

CREATE TABLE derm_manifests (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),

  -- Dates
  service_date            DATE,
  dump_ticket_date        DATE,

  -- Document numbers
  white_manifest_num      TEXT,
  yellow_ticket_num       TEXT,

  -- Document images
  manifest_images         JSONB,
  address_images          JSONB,

  -- Compliance flags
  sent_to_client          BOOLEAN DEFAULT false,
  sent_to_city            BOOLEAN DEFAULT false,

  -- Location context
  service_address         TEXT,
  service_city            TEXT,
  service_zip             TEXT,
  service_county          TEXT,                       -- DADE | BROWARD (determines manifest series)

  -- Source FK
  airtable_record_id      TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_derm_client ON derm_manifests(client_id);
CREATE INDEX idx_derm_date ON derm_manifests(service_date DESC);
CREATE INDEX idx_derm_unsent_client ON derm_manifests(sent_to_client) WHERE NOT sent_to_client;
CREATE INDEX idx_derm_unsent_city ON derm_manifests(sent_to_city) WHERE NOT sent_to_city;

COMMENT ON TABLE derm_manifests IS 'DERM compliance manifests (868). County-required. Fines: $500-$3,000. DADE=481xxx, BROWARD=294xxx.';


-- ============================================================================
-- 15. manifest_visits — DERM MANIFEST <-> VISIT LINKS (M:N)
-- ============================================================================
-- Viktor confirmed: multi-trap clients can have 1 manifest -> N visits
-- and 1 visit can relate to N manifests. True M:N.

CREATE TABLE manifest_visits (
  manifest_id             BIGINT NOT NULL REFERENCES derm_manifests(id) ON DELETE CASCADE,
  visit_id                BIGINT NOT NULL REFERENCES visits(id) ON DELETE CASCADE,

  PRIMARY KEY (manifest_id, visit_id)
);

CREATE INDEX idx_mv_visit ON manifest_visits(visit_id);

COMMENT ON TABLE manifest_visits IS 'M:N junction: DERM manifests <-> visits. Multi-trap clients generate multiple manifests per visit.';


-- ============================================================================
-- 16. routes — DAILY ROUTE PLANNING
-- ============================================================================
-- Source: airtable_route_creation (135 rows)
-- Planning artifact ONLY — not a precursor to visits.
-- Diego uses this to plan which clients need service.
-- No FK to visits (confirmed by Viktor).

CREATE TABLE routes (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),

  gt_wanted_date          DATE,
  cl_wanted_date          DATE,
  status                  TEXT,                       -- Todo | In Progress | Done | Cancelled
  assignee                TEXT,
  zone                    TEXT,

  -- Source FK
  airtable_record_id      TEXT UNIQUE,

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_routes_client ON routes(client_id);
CREATE INDEX idx_routes_gt_date ON routes(gt_wanted_date);
CREATE INDEX idx_routes_status ON routes(status);

COMMENT ON TABLE routes IS 'Route planning from Airtable (135). Planning artifact — no FK to visits. Diego uses for daily scheduling.';


-- ============================================================================
-- 17. receivables — OUTSTANDING BALANCE TRACKING
-- ============================================================================
-- Source: airtable_past_due (45 rows)
-- 77 clients (42%) late on service = ~$130K locked ARR

CREATE TABLE receivables (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),

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

CREATE INDEX idx_receivables_client ON receivables(client_id);
CREATE INDEX idx_receivables_status ON receivables(status);

COMMENT ON TABLE receivables IS 'Outstanding balances (45). 42% of clients late = ~$130K locked ARR.';


-- ============================================================================
-- 18. source_map — CROSS-SYSTEM ID AUDIT TRAIL
-- ============================================================================
-- How client IDs were matched across Airtable, Jobber, Samsara
-- Audit/debug table — ops queries use clients table directly

CREATE TABLE source_map (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
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

CREATE INDEX idx_srcmap_client ON source_map(client_id);
CREATE INDEX idx_srcmap_method ON source_map(match_method);

COMMENT ON TABLE source_map IS 'Audit trail: how client IDs were matched across Airtable/Jobber/Samsara. Not for live queries — use clients table.';


-- ============================================================================
-- 19. leads — PRE-CLIENT SALES PIPELINE
-- ============================================================================
-- Prospects not yet converted to clients. When a lead converts,
-- a row is created in clients and lead.converted_client_id is set.
-- Sources: manual entry, website forms, referrals, Jobber requests.

CREATE TABLE leads (
  id                      BIGSERIAL PRIMARY KEY,
  converted_client_id     BIGINT REFERENCES clients(id),       -- NULL until converted

  -- Contact info
  contact_name            TEXT NOT NULL,
  company_name            TEXT,
  phone                   TEXT,
  email                   TEXT,
  address                 TEXT,
  city                    TEXT,
  state                   TEXT DEFAULT 'FL',
  zip                     TEXT,

  -- Pipeline
  lead_source             TEXT,                                 -- website | referral | jobber | cold_call | other
  lead_status             TEXT DEFAULT 'new',                   -- new | contacted | qualified | quoted | converted | lost
  assigned_to             TEXT,                                 -- employee handling the lead

  -- Service interest
  service_interest        TEXT[],                               -- {GT, CL, WD, AUX}
  estimated_value         NUMERIC(12,2),
  notes                   TEXT,

  -- Dates
  first_contact_at        TIMESTAMPTZ,
  last_contact_at         TIMESTAMPTZ,
  converted_at            TIMESTAMPTZ,                          -- when lead became a client
  lost_reason             TEXT,                                 -- why lead was lost (if status=lost)

  -- Source FK
  jobber_request_id       TEXT UNIQUE,                          -- if originated from Jobber

  created_at              TIMESTAMPTZ DEFAULT NOW(),
  updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_leads_status ON leads(lead_status);
CREATE INDEX idx_leads_converted ON leads(converted_client_id);
CREATE INDEX idx_leads_source ON leads(lead_source);

COMMENT ON TABLE leads IS 'Pre-client sales pipeline. Converts to clients table on close. FK to clients via converted_client_id.';


-- ============================================================================
-- 20. sync_log — NIGHTLY SYNC AUDIT TRAIL
-- ============================================================================
-- System/ops table — no FK to business entities.
-- Tracks each sync run: source, row counts, errors, duration.
-- Used for debugging sync failures and monitoring data freshness.

CREATE TABLE sync_log (
  id                      BIGSERIAL PRIMARY KEY,
  sync_source             TEXT NOT NULL,              -- jobber | airtable | fillout | samsara | gps_enrichment
  started_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at             TIMESTAMPTZ,
  rows_inserted           INTEGER DEFAULT 0,
  rows_updated            INTEGER DEFAULT 0,
  rows_errored            INTEGER DEFAULT 0,
  error_details           JSONB,
  duration_seconds        NUMERIC(8,2),
  status                  TEXT DEFAULT 'running'      -- running | completed | failed
);

CREATE INDEX idx_synclog_source ON sync_log(sync_source);
CREATE INDEX idx_synclog_started ON sync_log(started_at DESC);
CREATE INDEX idx_synclog_status ON sync_log(status);

COMMENT ON TABLE sync_log IS 'Sync run audit log. Tracks each nightly sync: source, row counts, errors, duration. No FK to business tables — system/ops table.';


-- ============================================================================
-- AUTO-UPDATE TRIGGERS (updated_at)
-- ============================================================================
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOR tbl IN
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      AND table_name NOT IN ('visit_assignments', 'manifest_visits')  -- junction tables, no updated_at
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%I_updated_at ON %I;
       CREATE TRIGGER trg_%I_updated_at
         BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at();',
      tbl, tbl, tbl, tbl
    );
  END LOOP;
END $$;


-- ============================================================================
-- VIEWS (5) — Ops team daily queries
-- ============================================================================

-- Flat client+service view for Diego/Aaron daily lookups
CREATE OR REPLACE VIEW client_services_flat AS
SELECT
  c.id, c.name, c.client_code, c.address_line1, c.city, c.zone, c.gt_size_gallons, c.status,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.frequency_days END) AS gt_frequency_days,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.price_per_visit END) AS gt_price_per_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.last_visit END) AS gt_last_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.next_visit END) AS gt_next_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.status END) AS gt_status,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.frequency_days END) AS cl_frequency_days,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.price_per_visit END) AS cl_price_per_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.last_visit END) AS cl_last_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.next_visit END) AS cl_next_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.status END) AS cl_status,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.frequency_days END) AS wd_frequency_days,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.price_per_visit END) AS wd_price_per_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.last_visit END) AS wd_last_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.next_visit END) AS wd_next_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.status END) AS wd_status
FROM clients c
LEFT JOIN service_configs s ON s.client_id = c.id
GROUP BY c.id;

-- Overdue/due-soon scheduling view — most operationally critical
CREATE OR REPLACE VIEW clients_due_service AS
SELECT
  c.id, c.name, c.client_code, c.address_line1, c.city, c.zone,
  s.service_type,
  s.last_visit,
  s.next_visit,
  s.frequency_days,
  (s.next_visit - CURRENT_DATE) AS days_until_due,
  CASE
    WHEN s.next_visit < CURRENT_DATE THEN 'OVERDUE'
    WHEN s.next_visit <= CURRENT_DATE + 14 THEN 'DUE_SOON'
    ELSE 'OK'
  END AS due_status
FROM clients c
JOIN service_configs s ON s.client_id = c.id
WHERE c.status = 'ACTIVE'
  AND s.status IS DISTINCT FROM 'Paused'
  AND s.next_visit IS NOT NULL
ORDER BY s.next_visit ASC;

-- Last 30 days of completed visits with client context
CREATE OR REPLACE VIEW visits_recent AS
SELECT
  v.id, v.visit_date, v.service_type,
  c.name AS client_name, c.address_line1, c.zone,
  v.visit_status, v.gps_confirmed,
  v.actual_arrival_at, v.actual_departure_at,
  v.truck, v.completed_by
FROM visits v
JOIN clients c ON c.id = v.client_id
WHERE v.visit_date >= CURRENT_DATE - 30
ORDER BY v.visit_date DESC;

-- DERM manifest detail with client info and visit count
CREATE OR REPLACE VIEW manifest_detail AS
SELECT
  m.id, m.white_manifest_num, m.service_date,
  c.name AS client_name, c.address_line1,
  m.service_address, m.service_county,
  m.sent_to_client, m.sent_to_city,
  COUNT(mv.visit_id) AS visit_count
FROM derm_manifests m
JOIN clients c ON c.id = m.client_id
LEFT JOIN manifest_visits mv ON mv.manifest_id = m.id
GROUP BY m.id, m.white_manifest_num, m.service_date,
         c.name, c.address_line1, m.service_address,
         m.service_county, m.sent_to_client, m.sent_to_city
ORDER BY m.service_date DESC;

-- Daily driver inspection compliance (handles overnight shifts)
CREATE OR REPLACE VIEW driver_inspection_status AS
SELECT
  e.id, e.full_name,
  MAX(CASE WHEN i.inspection_type = 'PRE' AND i.shift_date = CURRENT_DATE THEN i.submitted_at END) AS pre_submitted_at,
  MAX(CASE WHEN i.inspection_type = 'POST' THEN i.submitted_at END) AS post_submitted_at,
  COUNT(CASE WHEN i.shift_date = CURRENT_DATE THEN 1 END) AS inspections_today,
  BOOL_OR(CASE WHEN i.has_issue = true THEN true END) AS has_open_issue
FROM employees e
LEFT JOIN inspections i
  ON i.employee_id = e.id
  AND (
    i.shift_date = CURRENT_DATE
    OR (
      i.shift_date = CURRENT_DATE - 1
      AND i.inspection_type = 'POST'
      AND i.submitted_at >= CURRENT_DATE::timestamptz
    )
  )
WHERE e.status = 'ACTIVE'
GROUP BY e.id, e.full_name;


-- ============================================================================
-- RELATIONSHIP MAP
-- ============================================================================
--
-- clients (PK)
--   |-- properties (client_id FK)
--   |-- service_configs (client_id FK)        [3NF: per service type]
--   |-- jobs (client_id FK)
--   |     |-- visits (job_id FK)
--   |     |     |-- visit_assignments (visit_id FK) ---> employees
--   |     |     |-- manifest_visits (visit_id FK) ---> derm_manifests
--   |     |     |-- invoices (via visits.invoice_id FK)
--   |     |-- invoices (job_id FK)
--   |     |-- line_items (job_id FK)
--   |     |-- quotes (via jobs.quote_id FK)   [quote → job conversion]
--   |-- visits (client_id FK)                 [also links to jobs, vehicles, invoices]
--   |-- quotes (client_id FK)
--   |     |-- line_items (quote_id FK)
--   |     |-- jobs (quote_id FK)              [quote conversion tracking]
--   |-- invoices (client_id FK)
--   |-- derm_manifests (client_id FK)
--   |-- routes (client_id FK)
--   |-- receivables (client_id FK)
--   |-- source_map (client_id FK)
--   |-- leads (converted_client_id FK)   [reverse: lead -> client on conversion]
--
-- vehicles (PK)
--   |-- visits (vehicle_id FK)
--   |-- inspections (vehicle_id FK)
--   |-- expenses (vehicle_id FK)
--
-- employees (PK)
--   |-- visit_assignments (employee_id FK)
--   |-- inspections (employee_id FK)
--   |-- expenses (employee_id FK)
--
-- No orphan tables. Every table has at least one FK relationship.
--
-- ============================================================================
-- ROW LEVEL SECURITY — Lock down all public tables
-- ============================================================================
-- Strategy: ENABLE + FORCE RLS on every table. No policies created.
-- Effect: Only service_role can read/write (bypasses RLS by Supabase design).
--         The anon key returns empty for all queries via PostgREST.
-- Why: No frontend / authenticated users in this project. Sync scripts only.
--      If a frontend is added later, add granular policies per role at that time.
-- ============================================================================

DO $$
DECLARE tbl TEXT;
BEGIN
  FOR tbl IN
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', tbl);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY;', tbl);
  END LOOP;
END $$;


-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
