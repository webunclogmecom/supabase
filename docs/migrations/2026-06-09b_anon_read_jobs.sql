-- ============================================================================
-- Admin Review app — grant anon SELECT on jobs (RLS policy)
-- ----------------------------------------------------------------------------
-- Companion to 2026-06-09_anon_read_employees_vehicles.sql. While auditing the
-- Admin Review app's full anon-read contract on Prod, `public.jobs` turned out to
-- be the SAME class of gap: RLS enabled, anon SELECT *grant* present, but NO anon
-- (or public) SELECT *policy* — so the anon app reads it 200-but-EMPTY. The app
-- reads jobs (useVisitDetail -> job_number, title) for the /review/:id detail, so
-- that job metadata was silently missing. The Prod-move anon-read pass had added
-- policies for visits/visit_assignments/clients/etc. but missed jobs (as it missed
-- employees + vehicles). Fix: add an anon SELECT policy (USING true), matching the
-- ship-first anon-permissive pattern. No frontend change / republish needed.
-- Audit (ADR 010): RLS policy only, no data mutation — no audit trigger needed.
-- Idempotent.
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='jobs'
      AND policyname='admin_review_anon_read_jobs'
  ) THEN
    CREATE POLICY "admin_review_anon_read_jobs"
      ON public.jobs FOR SELECT TO anon USING (true);
  END IF;
END $$;
