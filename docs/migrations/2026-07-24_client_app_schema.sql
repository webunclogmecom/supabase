-- ============================================================================
-- 2026-07-24 — `client` app-schema (Client App / Client View Pro, Prod reads)
-- ============================================================================
-- WHY: The Client App (Lovable dbf2133c-…, clients.unclogme.app) was built against
-- the Client App Mirror (project mjxjhwxktedrrnochwli), a flat public-schema hourly
-- snapshot of Prod's client domain. Fred 2026-07-24: migrate it onto Prod, READS FIRST
-- (writes — create client/code/job — are a separate, later phase). Per the schema-per-app
-- pattern (project_multi_app_schema_pattern; the customer/ops/derm precedent), an app never
-- reads public.* directly: it gets its own schema of owner-run read views over canonical
-- (security_invoker=false → they bypass canonical RLS), granted SELECT to the app role.
--
-- This creates the `client` schema as mirror-parity read views so the Lovable app can
-- repoint its single db.ts seam from the Mirror to Prod by only swapping URL/key +
-- `db.schema('client')`, with the same table names it already queries. It is NON-BREAKING
-- to the live app (the app keeps reading the Mirror until the frontend session repoints).
--
-- ACCESS: granted to `authenticated` ONLY (internal staff app, Supabase-Auth-gated like the
-- other 4 staff apps — NOT anon). So the app's frontend must add the login in the SAME publish
-- as the repoint (anon cannot read these views). Prod's existing auth gate (the
-- fn_restrict_signup_domains before-user-created hook + Google + shared account) covers it once
-- clients.unclogme.app is in the redirect allow-list (done via the Management API alongside this).
--
-- PII / SAFETY: `client.employees` excludes email + phone (matching the Mirror's strip). Visits
-- are served via public.v_visits_live (soft-delete filtered) so deleted rows never leak. A
-- `client.mirror_meta` compat stub returns now() so the app's freshness footer doesn't crash on
-- Prod (the frontend should replace the footer with a plain "live" indicator).
--
-- SUPERSET NOTE (ship-first, harden later): these views are SELECT * over the mirrored client
-- domain to guarantee no query breaks on repoint, i.e. they expose whatever the Mirror already
-- exposed to the app. entity_source_links (internal ID bridge) and full column sets are included
-- for parity; a follow-up pass can trim columns / drop entity_source_links to the minimal set the
-- app's pages actually query (enumerate from the app source before trimming).
--
-- AUDIT (ADR 010): opt-OUT — this migration creates only VIEWS in a new app schema (no base
-- table, no human-editable canonical write path). Writes into canonical come later via SECDEF
-- RPCs (phase 2), which will opt in + add app_source='client-app' to the audit CASE then.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS client;

-- ─── Read views (owner-run: bypass canonical RLS, the customer.* pattern) ────
CREATE OR REPLACE VIEW client.clients             AS SELECT * FROM public.clients;
CREATE OR REPLACE VIEW client.properties          AS SELECT * FROM public.properties;
CREATE OR REPLACE VIEW client.client_contacts     AS SELECT * FROM public.client_contacts;
CREATE OR REPLACE VIEW client.client_locations    AS SELECT * FROM public.client_locations;
CREATE OR REPLACE VIEW client.client_groups       AS SELECT * FROM public.client_groups;
CREATE OR REPLACE VIEW client.service_configs     AS SELECT * FROM public.service_configs;
CREATE OR REPLACE VIEW client.gdos                AS SELECT * FROM public.gdos;
CREATE OR REPLACE VIEW client.zones               AS SELECT * FROM public.zones;
CREATE OR REPLACE VIEW client.jobs                AS SELECT * FROM public.jobs;
CREATE OR REPLACE VIEW client.invoices            AS SELECT * FROM public.invoices;
CREATE OR REPLACE VIEW client.quotes              AS SELECT * FROM public.quotes;
CREATE OR REPLACE VIEW client.line_items          AS SELECT * FROM public.line_items;
CREATE OR REPLACE VIEW client.service_line_items  AS SELECT * FROM public.service_line_items;
CREATE OR REPLACE VIEW client.vehicles            AS SELECT * FROM public.vehicles;
CREATE OR REPLACE VIEW client.visit_team          AS SELECT * FROM public.visit_team;
CREATE OR REPLACE VIEW client.visit_assignments   AS SELECT * FROM public.visit_assignments;
CREATE OR REPLACE VIEW client.visit_locations     AS SELECT * FROM public.visit_locations;
CREATE OR REPLACE VIEW client.entity_source_links AS SELECT * FROM public.entity_source_links;

-- visits: always soft-delete-filtered (never expose deleted rows). The app reads v_visits_live.
CREATE OR REPLACE VIEW client.v_visits_live       AS SELECT * FROM public.v_visits_live;
CREATE OR REPLACE VIEW client.visits              AS SELECT * FROM public.v_visits_live;

-- employees: exclude PII (email, phone), matching the Mirror.
CREATE OR REPLACE VIEW client.employees AS
  SELECT id, full_name, role, status, shift, hire_date, notes,
         created_at, updated_at, access_level, color_hex
  FROM public.employees;

-- mirror_meta compat stub so the app's freshness footer does not crash on Prod (data is live).
CREATE OR REPLACE VIEW client.mirror_meta AS
  SELECT now()::timestamptz AS last_refresh_at;

COMMENT ON SCHEMA client IS
  'Client App (Client View Pro, clients.unclogme.app) per-app read schema — owner-run views over the canonical client domain, SELECT-only to authenticated. Added 2026-07-24 (reads-first migration off the Client App Mirror). Writes = later phase via SECDEF RPCs.';

-- ─── Grants: authenticated only (internal staff app; NOT anon) ───────────────
GRANT USAGE ON SCHEMA client TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA client TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA client GRANT SELECT ON TABLES TO authenticated;

-- service_role keeps full access (edge fns / scripts); anon gets nothing here.
GRANT USAGE ON SCHEMA client TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA client TO service_role;
