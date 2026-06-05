-- Migration: municipality_regulators + derm_email_sends.recipient_type (Send DERM to City)
-- Date:   2026-06-05
-- Author: Claude, directed by Fred (DERM Tracker — "Send DERM to City")
-- Design: Building Apps/DERM Tracker/docs/send-derm-to-city-design.md
--
-- AUDIT (rule 8): public.municipality_regulators -> OPT-IN. Human-editable (ops
--   maintains the regulator emails) + DERM-compliance (the .gov submission targets);
--   rule 8 hard rule requires audit for compliance data.
-- 3NF: emails/status/notes/county/state depend ONLY on the municipality (the natural
--   key, UNIQUE). county/state are mild reference denormalization (city->county/state
--   functional dep) on a small lookup table — acceptable per ADR 004 + the design.
-- derm_email_sends.recipient_type: derm_email_sends is already audited (opt-in); a
--   column add is auto-captured. Existing rows default to 'client'.
--
-- RLS/grants: the base table holds the actual .gov addresses, so it stays LOCKED from
--   anon/authenticated (same posture as derm_email_sends). The Edge Function reads it
--   via service_role; the derm.* views (postgres-owned, definer) expose only booleans
--   + the municipality label — never the address.

SET search_path TO public;

-- 1. municipality_regulators ------------------------------------------------
CREATE TABLE IF NOT EXISTS public.municipality_regulators (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  municipality text NOT NULL UNIQUE,
  state        text NOT NULL DEFAULT 'FL',
  county       text,
  emails       text[] NOT NULL,
  status       text NOT NULL DEFAULT 'ACTIVE',
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.municipality_regulators IS
  'One row per municipality with a FOG/grease manifest-submission program; holds the regulator email(s). Matched to a manifest via the served location''s property.city. Recipient source for the "Send DERM to City" send.';

DROP TRIGGER IF EXISTS trg_municipality_regulators_updated_at ON public.municipality_regulators;
CREATE TRIGGER trg_municipality_regulators_updated_at BEFORE UPDATE ON public.municipality_regulators
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS audit_municipality_regulators ON public.municipality_regulators;
CREATE TRIGGER audit_municipality_regulators AFTER INSERT OR UPDATE OR DELETE ON public.municipality_regulators
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Lock the base table (holds .gov addresses); service_role reads, views expose labels only
ALTER TABLE public.municipality_regulators ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.municipality_regulators FROM anon, authenticated;
GRANT SELECT ON public.municipality_regulators TO service_role;

-- Idempotent seed (DO NOTHING preserves any later ops edits to the emails)
INSERT INTO public.municipality_regulators (municipality, state, county, emails) VALUES
  ('Surfside',         'FL', 'Dade',    ARRAY['csantos-alborna@townofsurfsidefl.gov','aeugent@townofsurfsidefl.gov']),
  ('Hallandale Beach', 'FL', 'Broward', ARRAY['jbrown@hallandalebeachfl.gov','JTuszynski@hallandalebeachfl.gov'])
ON CONFLICT (municipality) DO NOTHING;

-- 2. derm_email_sends.recipient_type ---------------------------------------
ALTER TABLE public.derm_email_sends
  ADD COLUMN IF NOT EXISTS recipient_type text NOT NULL DEFAULT 'client'
    CHECK (recipient_type IN ('client','city'));

NOTIFY pgrst, 'reload schema';
