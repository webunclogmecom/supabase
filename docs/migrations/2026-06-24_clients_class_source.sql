-- ============================================================================
-- Migration: 2026-06-24_clients_class_source.sql
-- ADR: 010 (audit standing check), Rule 1 (source-agnostic), Rule 2 (3NF)
-- Purpose: Protect hand-set public.clients.client_class from the Jobber poll's
--          blind isCompany->client_class re-derivation (webhook-jobber.handleClient
--          + backfill_clients_class.js both clobber today). Adds a provenance
--          column + a BEFORE UPDATE guard, and pins the 3 known residentials
--          (119-ME / 121-FRO / 126-YM) that Jobber reports isCompany=true.
-- Audit: client_class_source added to already-audited public.clients -> auto-captured
--        by audit_clients (ADR 010, no trigger edit needed).
-- 3NF: client_class_source describes the PROVENANCE of client_class, depends only
--      on the PK, not derivable elsewhere. Rule 1: value 'jobber' names a system as
--      DATA (allowed); it is NOT a jobber_* column name.
-- Idempotent: ADD COLUMN IF NOT EXISTS; constraint via pg_constraint DO-block;
--             CREATE OR REPLACE FUNCTION; DROP/CREATE trigger; guarded pin UPDATE.
-- ============================================================================
BEGIN;

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS client_class_source TEXT NOT NULL DEFAULT 'jobber';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clients_client_class_source_check'
  ) THEN
    ALTER TABLE public.clients
      ADD CONSTRAINT clients_client_class_source_check
      CHECK (client_class_source IN ('jobber','manual'));
  END IF;
END $$;

COMMENT ON COLUMN public.clients.client_class_source IS
  'Provenance of client_class. jobber=auto-derived from Jobber Client.isCompany by webhook-jobber/backfill_clients_class.js; manual=hand-set ops override the poll must NOT clobber. Guarded by trg_clients_protect_manual_class. Source-agnostic per Rule 1 (value names a system as data).';

CREATE OR REPLACE FUNCTION public.fn_clients_protect_manual_class()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.client_class_source = 'manual'
     AND NEW.client_class_source = 'manual'
     AND NEW.client_class IS DISTINCT FROM OLD.client_class THEN
    NEW.client_class := OLD.client_class;  -- silently preserve; never RAISE so the */5 poll never fails
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clients_protect_manual_class ON public.clients;
CREATE TRIGGER trg_clients_protect_manual_class
  BEFORE UPDATE ON public.clients
  FOR EACH ROW EXECUTE FUNCTION public.fn_clients_protect_manual_class();

-- Pin the 3 known residentials. First manual-marking write passes the guard
-- because OLD.client_class_source='jobber' at fire time; re-asserts residential
-- even if a prior poll already flipped one to commercial.
UPDATE public.clients
   SET client_class = 'residential', client_class_source = 'manual'
 WHERE client_code IN ('119-ME','121-FRO','126-YM')
   AND (client_class IS DISTINCT FROM 'residential'
        OR client_class_source IS DISTINCT FROM 'manual');

COMMIT;
