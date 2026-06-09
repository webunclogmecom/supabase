-- ============================================================================
-- Admin Review app — grant anon SELECT on employees + vehicles (RLS policy)
-- ----------------------------------------------------------------------------
-- The Admin Review app (grease-buddy-dash, ANON role on Prod) resolves driver
-- names (employees.full_name) and truck names (vehicles.name) via anon REST reads
-- (employees?select=id,full_name&id=in.(...) ; vehicles?select=id,name&id=in.(...)).
-- Both tables have RLS ENABLED with ONLY an "authenticated" SELECT policy plus the
-- anon SELECT *grant* — so anon got 200-but-EMPTY, and every driver rendered
-- "Unknown"/"Unassigned" and every truck "Not recorded", regardless of the frontend
-- approach (PostgREST embed OR the separate IN-query Lovable later switched to).
--
-- This was a BACKEND RLS gap, NOT a frontend bug. The Admin-Review Prod-move
-- anon-read pass (admin_review_anon_read_visits, visit_assignments_anon_select,
-- the {public} read on inspections, etc.) simply missed employees + vehicles.
-- Fix: add anon SELECT policies (USING true), matching that ship-first
-- anon-permissive pattern. No frontend change / republish needed — the app's
-- existing (already-published) queries start returning rows immediately.
--
-- Audit (ADR 010): RLS policy only, no data mutation — no audit trigger needed.
-- Idempotent.
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='employees'
      AND policyname='admin_review_anon_read_employees'
  ) THEN
    CREATE POLICY "admin_review_anon_read_employees"
      ON public.employees FOR SELECT TO anon USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='vehicles'
      AND policyname='admin_review_anon_read_vehicles'
  ) THEN
    CREATE POLICY "admin_review_anon_read_vehicles"
      ON public.vehicles FOR SELECT TO anon USING (true);
  END IF;
END $$;
