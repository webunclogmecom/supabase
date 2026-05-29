-- 2026-05-29_clients_class.sql
--
-- Add `client_class TEXT` to public.clients to persist Commercial vs
-- Residential classification canonically. Today we have no DB-side
-- signal for this; the only way to know is to round-trip to Jobber's
-- `Client.isCompany` field per client (slow, fragile).
--
-- Context: 2026-05-29 audit of 186 NULL-code Jobber-linked clients found
-- 112 commercial / 74 residential. Fred's ask: persist this so
-- list/filter queries don't need to call Jobber every time.
--
-- Decision (Fred, 2026-05-29 chat): supersedes the earlier
-- `project_residential_clients.md` rule that said "don't classify
-- residentials". The earlier concern was operational (don't filter ops
-- dashboards by class); storing the canonical fact is fine and
-- desirable. Memory note will be updated to reflect "store != act-on".
--
-- Source of truth: Jobber GraphQL `Client.isCompany: Boolean`
--   - isCompany = true  → 'commercial'
--   - isCompany = false → 'residential'
--   - other / NULL      → NULL until resolvable
--
-- Naming: `client_class` chosen per Rule 1 (source-agnostic). Not
-- `is_company` (Jobber-flavored), not `payment_terms` (Jobber UI
-- label). Generic name; survives Jobber sunset.
--
-- Audit (ADR 010): public.clients is opted-in to audit.log_change();
-- this column will be captured automatically (full-row JSONB) on
-- UPDATE. No trigger changes needed.
--
-- App impact: none today. Apps can start filtering on it once backfill
-- + webhook patch are deployed.
--
-- Idempotent.

BEGIN;

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS client_class TEXT;

-- CHECK constraint, idempotent via DO block (ALTER TABLE ADD CONSTRAINT
-- has no IF NOT EXISTS in PG)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clients_client_class_check'
  ) THEN
    ALTER TABLE public.clients
      ADD CONSTRAINT clients_client_class_check
      CHECK (client_class IS NULL OR client_class IN ('commercial','residential'));
  END IF;
END $$;

-- Partial index for the common filter path
CREATE INDEX IF NOT EXISTS clients_class_idx
  ON public.clients (client_class)
  WHERE client_class IS NOT NULL;

COMMENT ON COLUMN public.clients.client_class IS
  'Commercial vs Residential. Source of truth: Jobber Client.isCompany '
  '(true=commercial, false=residential). Maintained by webhook-jobber + '
  'scripts/sync/backfill_clients_class.js. Per project_residential_clients.md '
  'rule (2026-05-29 nuance): persist the fact, but ops dashboards default to '
  'all-clients views unless explicitly filtering.';

COMMIT;
