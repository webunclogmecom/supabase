-- =====================================================================
-- TARGET: SANDBOX ubtlwpcyntelgbykdatn ONLY  —  *** NOT a Prod migration ***
-- Already applied 2026-06-05 via the Supabase Management API.
-- =====================================================================
-- Purpose: bring the Sandbox canonical schema back to Prod parity so the
-- data-only `sandbox_refresh.sh` (TRUNCATE + reload) succeeds. The refresh
-- executes NO DDL, so Prod canonical schema changes must be propagated by hand.
--
-- Root cause of the ~1-day refresh outage: the new table `client_groups`
-- (clients.group_id FK) plus 5 other dimension tables the canonical set FKs
-- into were never in CANONICAL_TABLES (fixed in sandbox_refresh.sh, commit
-- b6179fe), AND the Sandbox schema had drifted from Prod:
--   * tables missing entirely: client_locations, service_line_items
--   * columns missing: disposal_facilities.county, gdos.client_location_id
--   * stale CHECK: visits_source_chk lacked 'visit-calendar'
--   * zones.id was a plain bigint (Prod = GENERATED ALWAYS AS IDENTITY) -> the
--     dump's setval('zones_id_seq') had no sequence to target
-- Canonical-only — does NOT touch any of Yannick's Sandbox tables/columns.
-- =====================================================================

-- 1. Missing tables ---------------------------------------------------
CREATE TABLE IF NOT EXISTS public.service_line_items (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  code text NOT NULL, title text NOT NULL,
  requires_derm boolean NOT NULL DEFAULT false,
  reason text, service_kind text, location_target text, method text, service_type text,
  schedulable boolean NOT NULL DEFAULT true, active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT service_line_items_pkey PRIMARY KEY (id),
  CONSTRAINT service_line_items_code_key UNIQUE (code)
);

CREATE TABLE IF NOT EXISTS public.client_locations (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  client_id bigint NOT NULL, name text NOT NULL, property_id bigint,
  status text NOT NULL DEFAULT 'active'::text,
  contact_name text, contact_phone text, contact_email text, notes text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT client_locations_pkey PRIMARY KEY (id),
  CONSTRAINT client_locations_status_check CHECK ((status = ANY (ARRAY['active'::text, 'closed'::text]))),
  CONSTRAINT client_locations_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE,
  CONSTRAINT client_locations_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_client_locations_client_id ON public.client_locations USING btree (client_id);
CREATE INDEX IF NOT EXISTS idx_client_locations_property_id ON public.client_locations USING btree (property_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_client_locations_client_name ON public.client_locations USING btree (client_id, name);

-- 2. Missing columns + FKs --------------------------------------------
ALTER TABLE public.disposal_facilities ADD COLUMN IF NOT EXISTS county text;
ALTER TABLE public.gdos ADD COLUMN IF NOT EXISTS client_location_id bigint;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='gdos_client_location_id_fkey') THEN
    ALTER TABLE public.gdos ADD CONSTRAINT gdos_client_location_id_fkey
      FOREIGN KEY (client_location_id) REFERENCES public.client_locations(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='visits_service_line_item_id_fkey') THEN
    ALTER TABLE public.visits ADD CONSTRAINT visits_service_line_item_id_fkey
      FOREIGN KEY (service_line_item_id) REFERENCES public.service_line_items(id) NOT VALID;
  END IF;
END $$;

-- 3. Stale / missing CHECK constraints --------------------------------
ALTER TABLE public.visits DROP CONSTRAINT IF EXISTS visits_source_chk;
ALTER TABLE public.visits ADD CONSTRAINT visits_source_chk
  CHECK ((source = ANY (ARRAY['jobber'::text,'supabase_cron'::text,'airtable'::text,'manual'::text,'odoo'::text,'visit-calendar'::text])));
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='clients_client_class_check') THEN
    ALTER TABLE public.clients ADD CONSTRAINT clients_client_class_check
      CHECK (((client_class IS NULL) OR (client_class = ANY (ARRAY['commercial'::text,'residential'::text])))) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='disposal_facilities_county_check') THEN
    ALTER TABLE public.disposal_facilities ADD CONSTRAINT disposal_facilities_county_check
      CHECK (((county IS NULL) OR (county = ANY (ARRAY['Miami-Dade'::text,'Broward'::text])))) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='zones_color_hex_check') THEN
    ALTER TABLE public.zones ADD CONSTRAINT zones_color_hex_check CHECK ((color_hex ~ '^#[0-9A-Fa-f]{6}$'::text)) NOT VALID;
  END IF;
END $$;

-- 4. zones.id identity (so the dump's setval('zones_id_seq') has a target) ---
ALTER TABLE public.zones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY;
