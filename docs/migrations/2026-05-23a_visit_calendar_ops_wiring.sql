-- 2026-05-23a_visit_calendar_ops_wiring.sql
--
-- Wires Visit Calendar Lovable app (project 6533c3ee-94f5-499c-96d1-c8847a729a8f)
-- to Prod canonical via the `ops` schema. Replaces the Lovable Cloud auto-
-- provisioned Supabase that the app currently reads from.
--
-- Per CLAUDE.md rule 3b (schema-per-app pattern) and the canonical doc
-- `apps/visit-calendar/docs/02-architecture.md` (proposed: `sched.*` or
-- `ops.*` — Fred 2026-05-22 decided on `ops`).
--
-- This migration:
--   1. Adds `property_id` BIGINT FK on `public.service_configs` per Fred's
--      2026-05-23 3NF decision: "1 Client can have multiple locations
--      (properties); each location can have its own GDO + its own service
--      schedule. Casa Neos = 1 Client with 3 Properties (Kitchen, Bar,
--      Lounge); each property has its own GDO + service_config." This
--      aligns service_configs with the existing `public.gdos.property_id`
--      pattern shipped 2026-05-20g.
--   2. Backfills `property_id` from `properties.is_primary = true` so
--      existing rows aren't orphaned.
--   3. Creates `ops.*` 1:1 views over `public.clients / properties /
--      service_configs / vehicles / visits`. These are the read surface
--      that Visit Calendar's TanStack Query will hit after the repoint.
--      `ops.v_service_due` already exists (2026-04-xx); kept as the
--      To-Be-Scheduled sidebar data source.
--   4. Grants anon SELECT on the `ops` schema (anon-permissive RLS by
--      design for prototype, per CLAUDE.md ship-first pattern).
--   5. Bumps anon `statement_timeout` from 3s → 15s per
--      `feedback_supabase_anon_timeout_3s.md` memory rule.
--
-- AFTER THIS MIGRATION: PostgREST config must be PATCHed to include `ops`
-- in `db_schema`. Done via Supabase Management API (not migration SQL).
--
-- 3NF check (Rule 2):
--   service_configs.property_id depends on the whole key (sc.id) — OK.
--   Per-row sc.property_id is independent of sc.client_id (Casa Neos has
--   3 service_configs each with a different property_id) — OK.
--
-- Audit (Rule 8):
--   service_configs is in the audited set (per CLAUDE.md 2026-05-17).
--   Column-add is auto-captured in full-row JSONB by audit_service_configs
--   trigger. No action needed.
--   ops.* are VIEWS — no audit applicable.
--
-- Source-of-truth (Rule 4):
--   ops.* views read canonical Jobber-sourced visits + clients. No new
--   source. No source-prefixed columns introduced.
--
-- Idempotent (Rule 5):
--   ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--   CREATE OR REPLACE VIEW. Re-runnable.

BEGIN;

-- ============================================================
-- 1. ADD property_id TO service_configs
-- ============================================================
ALTER TABLE public.service_configs
  ADD COLUMN IF NOT EXISTS property_id BIGINT REFERENCES public.properties(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_service_configs_property_id ON public.service_configs(property_id);

COMMENT ON COLUMN public.service_configs.property_id IS
  'FK to properties.id. Nullable: existing rows backfilled with the client''s primary property in this migration (2026-05-23a). For Casa Neos-style multi-property clients, each (client_id, property_id, service_type) combination is a distinct service_config row. ON DELETE RESTRICT to prevent orphaning service schedules.';

-- ============================================================
-- 2. BACKFILL property_id FROM PRIMARY PROPERTY
-- ============================================================
UPDATE public.service_configs sc
SET property_id = p.id
FROM public.properties p
WHERE p.client_id = sc.client_id
  AND p.is_primary = true
  AND sc.property_id IS NULL;

-- ============================================================
-- 3. ops.* VIEWS (1:1 read surface for Visit Calendar TanStack Query)
-- ============================================================
-- These views are intentionally `SELECT *` to keep Lovable's existing
-- column expectations working without code changes. Future refinement
-- can trim columns as Visit Calendar's needs stabilize.

CREATE OR REPLACE VIEW ops.clients AS
SELECT * FROM public.clients;

CREATE OR REPLACE VIEW ops.properties AS
SELECT * FROM public.properties;

CREATE OR REPLACE VIEW ops.service_configs AS
SELECT * FROM public.service_configs;

CREATE OR REPLACE VIEW ops.vehicles AS
SELECT * FROM public.vehicles;

CREATE OR REPLACE VIEW ops.visits AS
SELECT * FROM public.visits;

-- ============================================================
-- 4. GRANTS — anon SELECT on ops schema (prototype anon model)
-- ============================================================
GRANT USAGE ON SCHEMA ops TO anon, authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA ops TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT SELECT ON TABLES TO anon, authenticated;

-- ============================================================
-- 5. ANON STATEMENT_TIMEOUT (per memory rule, 3s → 15s)
-- ============================================================
ALTER ROLE anon SET statement_timeout = '15s';

COMMIT;

-- ============================================================
-- POST-MIGRATION (NOT in this transaction):
-- ============================================================
-- Apply via Supabase Management API:
--   PATCH /v1/projects/wbasvhvvismukaqdnouk/postgrest
--   body: { "db_schema": "public,graphql_public,customer,derm,ops" }
-- This makes the `ops` schema reachable through PostgREST's
-- `Accept-Profile: ops` header.
--
-- VERIFICATION:
--   1. SELECT COUNT(*) FROM service_configs WHERE property_id IS NOT NULL;
--      → should match the number of clients with is_primary properties
--   2. Hit Prod REST: GET /rest/v1/clients?select=id&limit=1
--      with Accept-Profile: ops header → should return data
--   3. Run smoke test on Visit Calendar app after Lovable repoint
