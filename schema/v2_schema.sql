-- ============================================================================
-- UNCLOGME — SCHEMA V2 (Clean Foundation)
-- ============================================================================
-- Principles:
--   1. Source-agnostic: ZERO service-prefixed columns on business tables
--   2. 3NF: No transitive dependencies, no repeating groups
--   3. No dead columns: Every column must serve a purpose
--   4. Samsara is the only permanent external system (IDs in entity_source_links)
--   5. Calculated fields belong in views, not tables
--   6. All source FKs live in entity_source_links (the plumbing layer)
-- ============================================================================

-- ============================================================================
-- PLUMBING LAYER (sync infrastructure)
-- ============================================================================

CREATE TABLE entity_source_links (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_type     text    NOT NULL,  -- 'client','employee','vehicle','visit','invoice','job','quote','property','inspection','expense','derm_manifest','line_item','lead','route','receivable'
  entity_id       bigint  NOT NULL,
  source_system   text    NOT NULL,  -- 'jobber','airtable','samsara','fillout','ramp'
  source_id       text    NOT NULL,  -- the external system's ID
  source_name     text,              -- human-readable label from source (for debugging)
  match_method    text,              -- 'exact','fuzzy','manual','id'
  match_confidence numeric,
  synced_at       timestamptz DEFAULT now(),
  created_at      timestamptz DEFAULT now(),

  UNIQUE (entity_type, entity_id, source_system),
  UNIQUE (entity_type, source_system, source_id)
);

CREATE INDEX idx_esl_entity   ON entity_source_links (entity_type, entity_id);
CREATE INDEX idx_esl_source   ON entity_source_links (source_system, source_id);

-- Sync infrastructure (unchanged)
CREATE TABLE sync_cursors (
  entity          text PRIMARY KEY,
  last_synced_at  timestamptz,
  last_run_started  timestamptz,
  last_run_finished timestamptz,
  last_run_status   text,
  last_error        text,
  rows_pulled       integer DEFAULT 0,
  rows_populated    integer DEFAULT 0,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE TABLE sync_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sync_source     text    NOT NULL,
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  rows_inserted   integer DEFAULT 0,
  rows_updated    integer DEFAULT 0,
  rows_errored    integer DEFAULT 0,
  error_details   jsonb,
  duration_seconds numeric,
  status          text DEFAULT 'running'
);

-- ============================================================================
-- CORE ENTITIES
-- ============================================================================

-- CLIENTS — identity only. Address, contacts, GPS all normalized out.
CREATE TABLE clients (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text    NOT NULL,
  client_code     text,              -- operational code (e.g., "051-PV")
  status          text    DEFAULT 'Active',
  balance         numeric DEFAULT 0,
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_clients_name   ON clients (name);
CREATE INDEX idx_clients_code   ON clients (client_code);
CREATE INDEX idx_clients_status ON clients (status);

-- CLIENT CONTACTS — one row per contact role per client
CREATE TABLE client_contacts (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  contact_role    text    NOT NULL,  -- 'primary','accounting','operations','city_compliance'
  name            text,
  email           text,
  phone           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),

  UNIQUE (client_id, contact_role)
);

CREATE INDEX idx_contacts_client ON client_contacts (client_id);

-- PROPERTIES — physical locations with GPS + access schedule
CREATE TABLE properties (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  address         text,              -- street address (was "address_line1")
  city            text,
  state           text    DEFAULT 'FL',
  zip             text,
  county          text,
  country         text    DEFAULT 'US',
  zone            text,              -- operational zone (BEACH, PALM, etc.)
  latitude        numeric,
  longitude       numeric,
  geofence_radius_meters numeric,
  geofence_type   text,              -- 'circle','polygon'
  access_hours_start text,           -- e.g., "21:00" (was hours_in)
  access_hours_end   text,           -- e.g., "06:00" (was hours_out)
  access_days     text[],            -- e.g., {"mon","tue","wed"} (was days_of_week)
  location_photo_url text,           -- photo of the GT/service location (was photo_location_gt)
  is_primary      boolean DEFAULT true,
  is_billing      boolean DEFAULT false,
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_properties_client ON properties (client_id);
CREATE INDEX idx_properties_zone   ON properties (zone);

-- SERVICE CONFIGS — one row per service type per client (3NF)
CREATE TABLE service_configs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  service_type    text    NOT NULL,  -- 'GT','CL','WD'
  frequency_days  integer,
  price_per_visit numeric,
  equipment_size_gallons numeric,    -- GT trap size, CL pipe size, etc. (was gt_size_gallons)
  first_visit_date date,
  last_visit      date,
  next_visit      date,
  stop_date       date,
  status          text,              -- 'Active','Paused','Stopped'
  permit_number   text,              -- GDO number (was gdo_number)
  permit_expiration date,            -- GDO expiration (was gdo_expiration_date)
  schedule_notes  text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),

  UNIQUE (client_id, service_type)
);

CREATE INDEX idx_svcconfig_client ON service_configs (client_id);
CREATE INDEX idx_svcconfig_type   ON service_configs (service_type);
CREATE INDEX idx_svcconfig_next   ON service_configs (next_visit);
CREATE INDEX idx_svcconfig_status ON service_configs (status);

-- EMPLOYEES — identity + role only
CREATE TABLE employees (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name       text    NOT NULL UNIQUE,
  role            text,              -- 'Field Technician','Admin','Driver','Owner'
  status          text    DEFAULT 'Active',
  shift           text,              -- 'Day','Night'
  email           text,
  phone           text,
  hire_date       date,
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_employees_status ON employees (status);
CREATE INDEX idx_employees_role   ON employees (role);

-- VEHICLES — fleet specs only
CREATE TABLE vehicles (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text    NOT NULL UNIQUE,
  make            text,
  model           text,
  year            integer,
  vin             text    UNIQUE,
  license_plate   text,
  tank_capacity_gallons numeric NOT NULL,
  status          text    DEFAULT 'Active',
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

-- ============================================================================
-- OPERATIONAL ENTITIES
-- ============================================================================

-- QUOTES
CREATE TABLE quotes (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  property_id     bigint  REFERENCES properties(id),
  quote_number    text,
  title           text,
  subtotal        numeric,
  tax_amount      numeric,
  total           numeric,
  deposit_amount  numeric,
  quote_status    text,
  sent_at         timestamptz,
  approved_at     timestamptz,
  converted_to_job_at timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_quotes_client ON quotes (client_id);
CREATE INDEX idx_quotes_status ON quotes (quote_status);

-- JOBS
CREATE TABLE jobs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  property_id     bigint  REFERENCES properties(id),
  quote_id        bigint  REFERENCES quotes(id),
  job_number      text,
  title           text,
  job_status      text,
  start_at        timestamptz,
  end_at          timestamptz,
  total           numeric,
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_jobs_client ON jobs (client_id);
CREATE INDEX idx_jobs_status ON jobs (job_status);
CREATE INDEX idx_jobs_start  ON jobs (start_at);

-- INVOICES
CREATE TABLE invoices (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  job_id          bigint  REFERENCES jobs(id),
  invoice_number  text,
  subject         text,
  subtotal        numeric,
  tax_amount      numeric,
  total           numeric,
  outstanding     numeric,
  deposit_amount  numeric,
  invoice_status  text,
  due_date        date,
  sent_at         timestamptz,
  paid_at         timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_invoices_client      ON invoices (client_id);
CREATE INDEX idx_invoices_job         ON invoices (job_id);
CREATE INDEX idx_invoices_status      ON invoices (invoice_status);
CREATE INDEX idx_invoices_due         ON invoices (due_date);
CREATE INDEX idx_invoices_outstanding ON invoices (outstanding) WHERE outstanding > 0;

-- LINE ITEMS
CREATE TABLE line_items (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id          bigint  REFERENCES jobs(id),
  quote_id        bigint  REFERENCES quotes(id),
  name            text,
  description     text,
  quantity        numeric,
  unit_price      numeric,
  total_price     numeric,
  taxable         boolean DEFAULT false,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_lineitems_job   ON line_items (job_id);
CREATE INDEX idx_lineitems_quote ON line_items (quote_id);

-- VISITS — the core operational event
CREATE TABLE visits (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  property_id     bigint  REFERENCES properties(id),
  job_id          bigint  REFERENCES jobs(id),
  vehicle_id      bigint  REFERENCES vehicles(id),
  invoice_id      bigint  REFERENCES invoices(id),
  visit_date      date    NOT NULL,
  start_at        timestamptz,
  end_at          timestamptz,
  completed_at    timestamptz,
  duration_minutes integer,
  service_type    text,              -- 'GT','CL','WD'
  visit_status    text,              -- 'Completed','Upcoming','Late','Skipped'
  is_complete     boolean DEFAULT false,
  gps_confirmed   boolean DEFAULT false,
  actual_arrival_at   timestamptz,
  actual_departure_at timestamptz,
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_visits_client  ON visits (client_id);
CREATE INDEX idx_visits_job     ON visits (job_id);
CREATE INDEX idx_visits_date    ON visits (visit_date);
CREATE INDEX idx_visits_status  ON visits (visit_status);
CREATE INDEX idx_visits_vehicle ON visits (vehicle_id);
CREATE INDEX idx_visits_invoice ON visits (invoice_id);
CREATE INDEX idx_visits_type    ON visits (service_type);
CREATE INDEX idx_visits_incomplete ON visits (is_complete) WHERE is_complete = false;

-- VISIT ASSIGNMENTS — junction table
CREATE TABLE visit_assignments (
  visit_id        bigint  NOT NULL REFERENCES visits(id) ON DELETE CASCADE,
  employee_id     bigint  NOT NULL REFERENCES employees(id),
  PRIMARY KEY (visit_id, employee_id)
);

CREATE INDEX idx_va_employee ON visit_assignments (employee_id);

-- ============================================================================
-- INSPECTION & FLEET
-- ============================================================================

-- INSPECTIONS — truck condition per shift (data only, photos separate)
CREATE TABLE inspections (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id      bigint  REFERENCES vehicles(id),
  employee_id     bigint  REFERENCES employees(id),
  shift_date      date    NOT NULL,
  inspection_type text    NOT NULL,  -- 'PRE','POST'
  submitted_at    timestamptz,
  sludge_gallons  integer,
  water_gallons   integer,
  gas_level       text,              -- 'Full','3/4','1/2','1/4','Empty'
  valve_is_closed boolean,
  has_issue       boolean DEFAULT false,
  issue_note      text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_inspections_date     ON inspections (shift_date);
CREATE INDEX idx_inspections_vehicle  ON inspections (vehicle_id);
CREATE INDEX idx_inspections_employee ON inspections (employee_id);
CREATE INDEX idx_inspections_type     ON inspections (inspection_type);
CREATE INDEX idx_inspections_issues   ON inspections (has_issue) WHERE has_issue = true;

-- INSPECTION PHOTOS — one row per photo (replaces 17 inline columns)
CREATE TABLE inspection_photos (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inspection_id   bigint  NOT NULL REFERENCES inspections(id) ON DELETE CASCADE,
  photo_type      text    NOT NULL,  -- 'dashboard','cabin','front','back','left_side','right_side',
                                     -- 'boots','remote','closed_valve','sludge_level','water_level',
                                     -- 'derm_manifest','derm_address','issue','expense_receipt',
                                     -- 'cabin_side_left','cabin_side_right'
  url             text    NOT NULL,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_inspection_photos_insp ON inspection_photos (inspection_id);

-- VISIT PHOTOS — before/after service photos (from Jobber notes, future: direct upload)
CREATE TABLE visit_photos (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  visit_id        bigint  REFERENCES visits(id) ON DELETE CASCADE,
  client_id       bigint  REFERENCES clients(id),  -- for photos linked to client but not a specific visit
  photo_type      text,              -- 'before','after','location','other'
  url             text    NOT NULL,
  thumbnail_url   text,
  file_name       text,
  content_type    text,              -- 'image/jpeg','image/png','video/mp4','application/pdf'
  caption         text,              -- note text associated with the photo
  taken_at        timestamptz,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_visit_photos_visit  ON visit_photos (visit_id);
CREATE INDEX idx_visit_photos_client ON visit_photos (client_id);

-- EXPENSES
CREATE TABLE expenses (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  expense_date    date    NOT NULL,
  amount          numeric,
  description     text,
  category        text,              -- 'fuel','repair','supplies','dump_fee','other'
  vendor_name     text,
  vehicle_id      bigint  REFERENCES vehicles(id),
  employee_id     bigint  REFERENCES employees(id),
  receipt_url     text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_expenses_date     ON expenses (expense_date);
CREATE INDEX idx_expenses_vehicle  ON expenses (vehicle_id);
CREATE INDEX idx_expenses_employee ON expenses (employee_id);
CREATE INDEX idx_expenses_category ON expenses (category);

-- ============================================================================
-- DERM / COMPLIANCE
-- ============================================================================

-- DERM MANIFESTS — regulatory disposal records
CREATE TABLE derm_manifests (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  service_date    date,
  dump_ticket_date date,
  white_manifest_num text,
  yellow_ticket_num  text,
  manifest_images jsonb,             -- [{url, thumbnail_url, filename}]
  address_images  jsonb,             -- [{url, thumbnail_url, filename}]
  sent_to_client  boolean DEFAULT false,
  sent_to_city    boolean DEFAULT false,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_derm_client       ON derm_manifests (client_id);
CREATE INDEX idx_derm_date         ON derm_manifests (service_date);
CREATE INDEX idx_derm_unsent_client ON derm_manifests (sent_to_client) WHERE sent_to_client = false;
CREATE INDEX idx_derm_unsent_city   ON derm_manifests (sent_to_city) WHERE sent_to_city = false;

-- MANIFEST-VISIT JUNCTION
CREATE TABLE manifest_visits (
  manifest_id     bigint  NOT NULL REFERENCES derm_manifests(id) ON DELETE CASCADE,
  visit_id        bigint  NOT NULL REFERENCES visits(id),
  PRIMARY KEY (manifest_id, visit_id)
);

CREATE INDEX idx_mv_visit ON manifest_visits (visit_id);

-- ============================================================================
-- CRM / PIPELINE
-- ============================================================================

-- RECEIVABLES — accounts receivable tracking
CREATE TABLE receivables (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id       bigint  REFERENCES clients(id),
  amount_due      numeric,
  status          text,
  assignee        text,
  note            text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_receivables_client ON receivables (client_id);
CREATE INDEX idx_receivables_status ON receivables (status);

-- LEADS
CREATE TABLE leads (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  converted_client_id bigint REFERENCES clients(id),
  contact_name    text    NOT NULL,
  company_name    text,
  phone           text,
  email           text,
  address         text,
  city            text,
  state           text    DEFAULT 'FL',
  zip             text,
  lead_source     text,
  lead_status     text    DEFAULT 'new',
  notes           text,
  first_contact_at timestamptz,
  converted_at    timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_leads_status ON leads (lead_status);

-- ROUTES — scheduling/dispatching
CREATE TABLE routes (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  route_date      date,
  vehicle_id      bigint  REFERENCES vehicles(id),
  employee_id     bigint  REFERENCES employees(id),
  zone            text,
  status          text,              -- 'Planned','In Progress','Completed'
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_routes_date ON routes (route_date);
CREATE INDEX idx_routes_zone ON routes (zone);

-- ROUTE STOPS — individual client stops on a route
CREATE TABLE route_stops (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  route_id        bigint  NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
  client_id       bigint  REFERENCES clients(id),
  property_id     bigint  REFERENCES properties(id),
  service_type    text,
  stop_order      integer,
  wanted_date     date,
  status          text,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX idx_route_stops_route ON route_stops (route_id);

-- ============================================================================
-- UPDATED_AT TRIGGER
-- ============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'updated_at'
    AND table_name NOT IN ('sync_log','entity_source_links')
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
      t
    );
  END LOOP;
END;
$$;

-- ============================================================================
-- VIEWS (computed data, never stored)
-- ============================================================================

-- Client services flat — pivot of service_configs for dashboard
CREATE VIEW client_services_flat
WITH (security_invoker = true)
AS
SELECT
  c.id, c.name, c.client_code,
  p.address, p.city, p.zone,
  c.status,
  -- GT
  MAX(CASE WHEN s.service_type = 'GT' THEN s.equipment_size_gallons END) AS gt_size_gallons,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.frequency_days END) AS gt_frequency_days,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.price_per_visit END) AS gt_price_per_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.last_visit END) AS gt_last_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.next_visit END) AS gt_next_visit,
  MAX(CASE WHEN s.service_type = 'GT' THEN s.status END) AS gt_status,
  -- CL
  MAX(CASE WHEN s.service_type = 'CL' THEN s.frequency_days END) AS cl_frequency_days,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.price_per_visit END) AS cl_price_per_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.last_visit END) AS cl_last_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.next_visit END) AS cl_next_visit,
  MAX(CASE WHEN s.service_type = 'CL' THEN s.status END) AS cl_status,
  -- WD
  MAX(CASE WHEN s.service_type = 'WD' THEN s.frequency_days END) AS wd_frequency_days,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.price_per_visit END) AS wd_price_per_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.last_visit END) AS wd_last_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.next_visit END) AS wd_next_visit,
  MAX(CASE WHEN s.service_type = 'WD' THEN s.status END) AS wd_status
FROM clients c
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN service_configs s ON s.client_id = c.id
GROUP BY c.id, p.address, p.city, p.zone;

-- Clients due for service
CREATE VIEW clients_due_service
WITH (security_invoker = true)
AS
SELECT
  c.id, c.name, c.client_code,
  p.address, p.city, p.zone,
  s.service_type, s.last_visit, s.next_visit, s.frequency_days,
  s.next_visit - CURRENT_DATE AS days_until_due,
  CASE
    WHEN s.next_visit < CURRENT_DATE THEN 'OVERDUE'
    WHEN s.next_visit <= CURRENT_DATE + 14 THEN 'DUE_SOON'
    ELSE 'OK'
  END AS due_status
FROM clients c
JOIN service_configs s ON s.client_id = c.id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
WHERE c.status = 'Active'
  AND s.status IS DISTINCT FROM 'Paused'
  AND s.next_visit IS NOT NULL
ORDER BY s.next_visit;

-- Recent visits with computed fields
CREATE VIEW visits_recent
WITH (security_invoker = true)
AS
SELECT
  v.id, v.visit_date, v.service_type,
  c.name AS client_name,
  p.address, p.zone,
  v.visit_status, v.gps_confirmed,
  v.actual_arrival_at, v.actual_departure_at,
  veh.name AS vehicle_name,
  string_agg(e.full_name, ', ') AS assigned_to
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN properties p ON p.id = v.property_id
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN visit_assignments va ON va.visit_id = v.id
LEFT JOIN employees e ON e.id = va.employee_id
WHERE v.visit_date >= CURRENT_DATE - 30
GROUP BY v.id, v.visit_date, v.service_type, c.name, p.address, p.zone,
         v.visit_status, v.gps_confirmed, v.actual_arrival_at, v.actual_departure_at, veh.name
ORDER BY v.visit_date DESC;

-- Manifest detail
CREATE VIEW manifest_detail
WITH (security_invoker = true)
AS
SELECT
  m.id, m.white_manifest_num, m.service_date,
  c.name AS client_name,
  p.address,
  p.county AS service_county,
  m.sent_to_client, m.sent_to_city,
  COUNT(mv.visit_id) AS visit_count
FROM derm_manifests m
JOIN clients c ON c.id = m.client_id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN manifest_visits mv ON mv.manifest_id = m.id
GROUP BY m.id, m.white_manifest_num, m.service_date,
         c.name, p.address, p.county, m.sent_to_client, m.sent_to_city
ORDER BY m.service_date DESC;

-- Driver inspection status
CREATE VIEW driver_inspection_status
WITH (security_invoker = true)
AS
SELECT
  e.id, e.full_name,
  MAX(CASE WHEN i.inspection_type = 'PRE' AND i.shift_date = CURRENT_DATE THEN i.submitted_at END) AS pre_submitted_at,
  MAX(CASE WHEN i.inspection_type = 'POST' THEN i.submitted_at END) AS post_submitted_at,
  COUNT(CASE WHEN i.shift_date = CURRENT_DATE THEN 1 END) AS inspections_today,
  BOOL_OR(CASE WHEN i.has_issue THEN true END) AS has_open_issue
FROM employees e
LEFT JOIN inspections i ON i.employee_id = e.id
  AND (i.shift_date = CURRENT_DATE
       OR (i.shift_date = CURRENT_DATE - 1 AND i.inspection_type = 'POST'
           AND i.submitted_at >= CURRENT_DATE::timestamptz))
WHERE e.status = 'Active'
GROUP BY e.id, e.full_name;

-- Late status computed view (replaces stored late_status columns)
CREATE VIEW visits_with_status
WITH (security_invoker = true)
AS
SELECT
  v.*,
  c.name AS client_name,
  p.zone,
  veh.name AS vehicle_name,
  sc.frequency_days,
  CASE
    WHEN v.visit_status = 'Completed' THEN 'OK'
    WHEN v.visit_date < CURRENT_DATE AND NOT v.is_complete THEN 'LATE'
    ELSE 'ON_TIME'
  END AS computed_late_status
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type;

-- ============================================================================
-- COLUMN COUNT COMPARISON
-- ============================================================================
-- Table            V1 Columns   V2 Columns   Removed
-- clients          40+          7            33+ (moved to contacts/properties/service_configs)
-- employees        25           10           15
-- vehicles         19           11           8
-- visits           24           20           4 (removed redundant, kept clean FKs)
-- jobs             20           12           8
-- invoices         17           15           2
-- inspections      30           13           17 (photos → inspection_photos)
-- expenses         16           10           6
-- derm_manifests   13           10           3
-- routes           10           8            2 (redesigned with route_stops)
-- leads            21           16           5
--
-- NEW TABLES: entity_source_links, client_contacts, inspection_photos,
--             visit_photos, route_stops
-- REMOVED: source_map (replaced by entity_source_links)
