-- 2026-06-01_client_locations.sql
--
-- New canonical table public.client_locations + new column gdos.client_location_id.
-- Model: ONE client -> N named LOCATIONS, and each location has its own GDO
-- (Miami-Dade grease-control permit). Confirmed by Fred 2026-06-01 to be the
-- general pattern across the whole book of business (Casa Neos, Wynd 28, and
-- every other multi-facility client), not a one-off.
--
-- WHY
--   A "location" is a named service unit under a client: a restaurant tenant in a
--   food hall (Wynd 28 -> Pasta/Presidente/CU4/Nino Gordo/Pari Pari) OR a distinct
--   service area in one venue (Casa Neos -> Kitchens/Bars/Lounge). Each holds its
--   own DERM GDO permit and therefore its own DERM reporting line. Today we have no
--   place to store that identity: Casa Neos fakes it with gdos.location_label (free
--   text, 89% NULL across the table) and Wynd 28's tenants live ONLY in Airtable as
--   5 throwaway client records (216-220-WYN) that Diego created for DERM reporting.
--   Airtable sunsets this week, so that identity must become native + canonical.
--
-- WHAT THIS IS NOT
--   Visits, service frequency, price, billing and the physical trap stay shared on
--   their existing tables (visits / service_configs / properties) and are REFERENCED,
--   never copied per location. A shared-trap client (Wynd) still has ONE visit; a
--   multi-area client (Casa Neos) still has its per-area visit cadence. This table
--   only adds the missing IDENTITY layer + the location<-gdo link.
--
-- 3NF (ADR 005): every column depends on the whole key (id) and nothing else.
--   property_id is a *reference* (FK to the shared building), not a copy of any
--   property attribute. NO frequency / price / trap-size / visit columns (those live
--   on service_configs / visits at the client+property grain). gdos.client_location_id
--   is a FK reference, not a copy of any gdo attribute.
-- Source-agnostic (Rule 1 / ADR 002): zero airtable_*/jobber_* columns. Locations are
--   native canonical rows (like gdos, which carry no entity_source_links either).
-- Idempotent (Rule 5): IF NOT EXISTS; triggers DROP-then-CREATE; policies dropped first.
-- Audit (Rule 8 / ADR 010): OPT-IN (name/status/contact_*/notes are human-editable).
--   gdos already has the audit_gdos trigger, so the new column auto-audits.
-- RLS (ship-first, but READ-ONLY for anon): no app writes client_locations yet, so
--   anon gets SELECT only. anon INSERT/UPDATE + an audit_critical_poll ANON_ALLOWED
--   entry get added in the migration that wires the first writing app (DERM Tracker).

BEGIN;

-- 1. Table -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.client_locations (
  id             BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id      BIGINT       NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  name           TEXT         NOT NULL,
  property_id    BIGINT       REFERENCES public.properties(id) ON DELETE SET NULL,
  status         TEXT         NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'closed')),
  contact_name   TEXT,
  contact_phone  TEXT,
  contact_email  TEXT,
  notes          TEXT,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.client_locations IS
  'Named service locations within a single client (1 client -> N locations). A location is a tenant (food-hall restaurant, e.g. Wynd 28) OR a service area (e.g. Casa Neos Kitchens/Bars/Lounge); each has its own DERM GDO. Identity layer only: visits, frequency, price, billing, trap stay shared on their own tables and are referenced, NEVER duplicated here. Each location links to its permit via gdos.client_location_id. Created 2026-06-01, see migration 2026-06-01_client_locations.sql.';
COMMENT ON COLUMN public.client_locations.client_id IS
  'Owning client. FK -> clients(id) ON DELETE CASCADE.';
COMMENT ON COLUMN public.client_locations.name IS
  'Location display name (e.g. "Pasta", "Kitchens"). The per-location identity ops + DERM need.';
COMMENT ON COLUMN public.client_locations.property_id IS
  'Shared building/property this location occupies. FK -> properties(id) ON DELETE SET NULL. A reference for grouping, NOT a copy of any property attribute. Nullable: a location may be recorded before its property row exists.';
COMMENT ON COLUMN public.client_locations.status IS
  'active | closed. Per-location lifecycle, independent of the parent client.status.';
COMMENT ON COLUMN public.client_locations.updated_at IS
  'Auto-bumped to now() on UPDATE by set_updated_at_client_locations (Rule 7). Never set manually.';

-- 2. FK indexes (Postgres does NOT auto-index FK columns) ------------------
CREATE INDEX IF NOT EXISTS idx_client_locations_client_id
  ON public.client_locations (client_id);
CREATE INDEX IF NOT EXISTS idx_client_locations_property_id
  ON public.client_locations (property_id);

-- Prevent duplicate location names under one client; ON CONFLICT target for the seed.
CREATE UNIQUE INDEX IF NOT EXISTS uq_client_locations_client_name
  ON public.client_locations (client_id, name);

-- 3. updated_at trigger (Rule 7) — canonical public.set_updated_at() -------
DROP TRIGGER IF EXISTS set_updated_at_client_locations ON public.client_locations;
CREATE TRIGGER set_updated_at_client_locations
  BEFORE UPDATE ON public.client_locations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 4. Audit trigger (Rule 8 — opt-in) --------------------------------------
DROP TRIGGER IF EXISTS audit_client_locations ON public.client_locations;
CREATE TRIGGER audit_client_locations
  AFTER INSERT OR UPDATE OR DELETE ON public.client_locations
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 5. RLS — anon READ-ONLY (no app writes locations yet) -------------------
ALTER TABLE public.client_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS client_locations_anon_read ON public.client_locations;
CREATE POLICY client_locations_anon_read
  ON public.client_locations FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS client_locations_authenticated_all ON public.client_locations;
CREATE POLICY client_locations_authenticated_all
  ON public.client_locations FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- 6. Grants ----------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.client_locations TO authenticated, service_role;
GRANT SELECT                         ON public.client_locations TO anon;
-- ^ anon INSERT/UPDATE granted later, in the migration that wires the first
--   writing app (DERM Tracker), together with its audit_critical_poll allow-list entry.

-- 7. Location <- GDO link (CORE: each location has its own GDO) ------------
-- nullable: a location may exist before its permit is ingested (Wynd 28 has 0 GDOs
-- ingested today). ON DELETE SET NULL: deleting a location must not delete its permit.
ALTER TABLE public.gdos
  ADD COLUMN IF NOT EXISTS client_location_id BIGINT
  REFERENCES public.client_locations(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_gdos_client_location_id
  ON public.gdos (client_location_id);
COMMENT ON COLUMN public.gdos.client_location_id IS
  'The client_location (tenant / service area) this GDO permits. FK -> client_locations(id) ON DELETE SET NULL. NULL until the location is created/matched. Usually 1 GDO : 1 location; a location MAY have >1 GDO (multiple devices).';

COMMIT;

-- POST-MIGRATION VERIFICATION ---------------------------------------------
-- 1. Columns:   SELECT column_name,data_type,is_nullable FROM information_schema.columns
--               WHERE table_schema='public' AND table_name='client_locations' ORDER BY ordinal_position;
-- 2. gdos col:  SELECT column_name FROM information_schema.columns
--               WHERE table_schema='public' AND table_name='gdos' AND column_name='client_location_id';
-- 3. RLS on:    SELECT relrowsecurity FROM pg_class WHERE relname='client_locations';  -- expect true
