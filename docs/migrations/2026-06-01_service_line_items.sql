-- ============================================================================
-- 2026-06-01_service_line_items.sql
-- Canonical reference table for the 27 standardized service line items (the
-- "Service list Unclogme" sheet). Backs the Calendar app's service dropdown and
-- the Jobber write-back: the chosen item's `title` becomes the Jobber visit title
-- (col B), `requires_derm` drives visits.derm_required + the DERM app, and the
-- decomposition (reason/service_kind/location_target/method) is kept for reporting.
--
-- Audit (Rule 8 / ADR 010): OPT-IN — human-curated reference data (like
--   disposal_facilities). audit trigger added below.
-- 3NF (Rule 2): PK id (surrogate); `code` is the natural key (UNIQUE). Every other
--   column describes the line item identified by code — depends on the whole key.
--   `service_type` is a stored business mapping (NOT a clean function of service_kind),
--   so it is a canonical attribute, not a transitive dep.
-- RLS: anon/authenticated read (non-PII reference; the Calendar Lovable app reads it).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.service_line_items (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code            TEXT NOT NULL UNIQUE,                 -- '01'..'27'
  title           TEXT NOT NULL,                        -- col B = the Jobber visit title
  requires_derm   BOOLEAN NOT NULL DEFAULT false,       -- col A (Y/N)
  reason          TEXT,                                 -- col D: Service Agreement | Service Call | fee | other
  service_kind    TEXT,                                 -- col E: Pumping | Cleaning | Unclogging | ...
  location_target TEXT,                                 -- col F: Grease Trap & Tank Cleaning | Grey Water | ...
  method          TEXT,                                 -- col G: Manual | Hydrojet
  service_type    TEXT,                                 -- GT/CL/WD where determinable, else NULL (VERIFY w/ Fred)
  schedulable     BOOLEAN NOT NULL DEFAULT true,        -- false for fees (25,26) + GDO reporting (27)
  active          BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.service_line_items (code, title, requires_derm, reason, service_kind, location_target, method, service_type, schedulable) VALUES
('01','01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning',                      true,  'Service Agreement','Pumping','Grease Trap & Tank Cleaning',NULL,'GT', true),
('02','02 - Service Agreement - Pumping - Grease Trap, Tank Cleaning & Warranty of Drainnage',true, 'Service Agreement','Pumping','Grease Trap, Tank Cleaning & Warranty of Drainnage',NULL,'GT', true),
('03','03 - Service Agreement - Pumping - Grey Water',                                       true,  'Service Agreement','Pumping','Grey Water',NULL,NULL, true),
('04','04 - Service Agreement - Pumping - Lift Station & Tank Cleaning',                     true,  'Service Agreement','Pumping','Lift Station & Tank Cleaning',NULL,NULL, true),
('05','05 - Service Agreement - Cleaning - Main Line Cleaning',                              false, 'Service Agreement','Cleaning','Main Line Cleaning',NULL,'CL', true),
('06','06 - Service Agreement - Cleaning - Aux Cleaning',                                    false, 'Service Agreement','Cleaning','Aux Cleaning',NULL,'CL', true),
('07','07 - Service Agreement - Cleaning - Tank Cleaning',                                   false, 'Service Agreement','Cleaning','Tank Cleaning',NULL,'CL', true),
('08','08 - Service Agreement - Warranty of Drainage',                                       false, 'Service Agreement','Warranty of Drainage',NULL,NULL,'WD', true),
('09','09 - Service Call - Pumping - Grease Trap & Tank Cleaning',                           true,  'Service Call','Pumping','Grease Trap & Tank Cleaning',NULL,'GT', true),
('10','10 - Service Call - Pumping - Grey Water',                                            true,  'Service Call','Pumping','Grey Water',NULL,NULL, true),
('11','11 - Service Call - Pumping - Lift Station & Tank Cleaning',                          true,  'Service Call','Pumping','Lift Station & Tank Cleaning',NULL,NULL, true),
('12','12 - Service Call - Cleaning - Main Line Cleaning',                                   false, 'Service Call','Cleaning','Main Line Cleaning',NULL,'CL', true),
('13','13 - Service Call - Cleaning - Auxiliary Line Cleaning',                              false, 'Service Call','Cleaning','Auxiliary Line Cleaning',NULL,'CL', true),
('14','14 - Service Call - Cleaning - Tank Cleaning',                                        false, 'Service Call','Cleaning','Tank Cleaning',NULL,'CL', true),
('15','15 - Service Call - Unclogging - Residential - Manual',                               false, 'Service Call','Unclogging','Residential','Manual',NULL, true),
('16','16 - Service Call - Unclogging - Residential - Hydrojet',                             false, 'Service Call','Unclogging','Residential','Hydrojet',NULL, true),
('17','17 - Service Call - Unclogging - Commercial - Manual',                                false, 'Service Call','Unclogging','Commercial','Manual',NULL, true),
('18','18 - Service Call - Unclogging - Commercial - Hydrojet',                              false, 'Service Call','Unclogging','Commercial','Hydrojet',NULL, true),
('19','19 - Service Call - Camera Inspection',                                               false, 'Service Call','Camera Inspection',NULL,NULL,NULL, true),
('20','20 - Service Call - Dye Test',                                                        false, 'Service Call','Dye Test',NULL,NULL,NULL, true),
('21','21 - Service Call - Assessment',                                                      false, 'Service Call','Assessment',NULL,NULL,NULL, true),
('22','22 - Service Call - Labor',                                                           false, 'Service Call','Labor',NULL,NULL,NULL, true),
('23','23 - Service Call - Parts',                                                           false, 'Service Call','Parts',NULL,NULL,NULL, true),
('24','24 - Service Call - Labor BUS',                                                       false, 'Service Call','Labor BUS',NULL,NULL,NULL, true),
('25','25 - Credit card fee (3.53%)',                                                        false, 'fee',NULL,NULL,NULL,NULL, false),
('26','26 - ACH Fee (1%)',                                                                   false, 'fee',NULL,NULL,NULL,NULL, false),
('27','27 - GDO Online Reporting',                                                           false, 'other',NULL,NULL,NULL,NULL, false)
ON CONFLICT (code) DO NOTHING;

-- updated_at trigger-managed (Rule 7)
DROP TRIGGER IF EXISTS trg_service_line_items_updated_at ON public.service_line_items;
CREATE TRIGGER trg_service_line_items_updated_at BEFORE UPDATE ON public.service_line_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- audit opt-in (Rule 8)
DROP TRIGGER IF EXISTS audit_service_line_items ON public.service_line_items;
CREATE TRIGGER audit_service_line_items AFTER INSERT OR UPDATE OR DELETE ON public.service_line_items
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- RLS: read-only reference data for the Calendar app (anon/authenticated)
ALTER TABLE public.service_line_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_line_items_read ON public.service_line_items;
CREATE POLICY service_line_items_read ON public.service_line_items FOR SELECT TO anon, authenticated USING (true);
GRANT SELECT ON public.service_line_items TO anon, authenticated;
