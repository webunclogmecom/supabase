-- ============================================================================
-- 2026-06-10 — Batch A: DB protocol hardening (from the 2026-06-10 full audit)
-- ============================================================================
-- Additive + behavior-neutral for the Lovable apps (anon policies untouched;
-- view output shapes unchanged). Five parts:
--   1. Missing FK indexes (gdos.property_id HIGH + 4 review-table employee FKs)
--   2. Wrap 8 RLS policies' bare auth.uid() in (select auth.uid()) — Supabase
--      perf rule: evaluates once per query (initPlan) instead of per row.
--      All 8 are authenticated-role policies; anon policies (qual=true) untouched.
--   3. visit_sync_flags: enable RLS + revoke anon/authenticated DML. It was the
--      ONLY RLS-off table in public, with anon holding full DML incl TRUNCATE.
--      No app/view reads it (verified); written by service_role (bypasses RLS).
--   4. Pin search_path on fn_check_gdo_on_visit — the one SECURITY DEFINER
--      function with a mutable search_path. Body uses unqualified public refs,
--      so pin to 'public' (matches the other 12 definer functions).
--   5. CHECK constraints on app/human-written STABLE enums only (live-data
--      vocabularies verified 2026-06-10). Jobber-synced statuses (jobs/invoices/
--      quotes/clients) + visits.visit_status are DEFERRED: pinning upstream-fed
--      enums can break webhook ingestion on a new upstream value, and the
--      Calendar app's visit_status vocabulary is unconfirmed.
-- 3NF note: no columns added; constraints + indexes + policy/function hygiene only.
-- ============================================================================

-- 1) Missing FK indexes ------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_gdos_property_id            ON public.gdos (property_id);
CREATE INDEX IF NOT EXISTS idx_shift_reviews_reviewed_by   ON public.shift_reviews (reviewed_by);
CREATE INDEX IF NOT EXISTS idx_shift_reviews_bonus_decided ON public.shift_reviews (bonus_decided_by);
CREATE INDEX IF NOT EXISTS idx_visit_reviews_reviewed_by   ON public.visit_reviews (reviewed_by);
CREATE INDEX IF NOT EXISTS idx_visit_reviews_bonus_decided ON public.visit_reviews (bonus_decided_by);

-- 2) Policy perf: wrap bare auth.uid() --------------------------------------
ALTER POLICY "Authenticated read photo_links"   ON public.photo_links USING ((select auth.uid()) IS NOT NULL);
ALTER POLICY "Authenticated insert photo_links" ON public.photo_links WITH CHECK ((select auth.uid()) IS NOT NULL);
ALTER POLICY "Authenticated read properties"    ON public.properties  USING ((select auth.uid()) IS NOT NULL);
ALTER POLICY "Authenticated read vehicles"      ON public.vehicles    USING ((select auth.uid()) IS NOT NULL);
ALTER POLICY "Authenticated read visits"        ON public.visits      USING ((select auth.uid()) IS NOT NULL);
ALTER POLICY app_visit_reviews_authenticated_all ON public.app_visit_reviews
  USING ((select auth.uid()) IS NOT NULL) WITH CHECK ((select auth.uid()) IS NOT NULL);
ALTER POLICY app_shift_reviews_authenticated_all ON public.app_shift_reviews
  USING ((select auth.uid()) IS NOT NULL) WITH CHECK ((select auth.uid()) IS NOT NULL);

-- 3) visit_sync_flags lockdown ------------------------------------------------
ALTER TABLE public.visit_sync_flags ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON public.visit_sync_flags FROM anon, authenticated;

-- 4) Pin SECURITY DEFINER search_path ----------------------------------------
ALTER FUNCTION public.fn_check_gdo_on_visit() SET search_path = public;

-- 5) CHECK constraints (stable, app/human-written enums; idempotent guards) ---
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicles_status_chk') THEN
    ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_status_chk
      CHECK (status = ANY (ARRAY['ACTIVE','INACTIVE']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'employees_status_chk') THEN
    ALTER TABLE public.employees ADD CONSTRAINT employees_status_chk
      CHECK (status = ANY (ARRAY['ACTIVE','INACTIVE']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'inspections_inspection_type_chk') THEN
    ALTER TABLE public.inspections ADD CONSTRAINT inspections_inspection_type_chk
      CHECK (inspection_type = ANY (ARRAY['PRE','POST']));
  END IF;
  -- entity_source_links.entity_type: vocabulary controlled by OUR code
  -- (upsertEntityLink) — 13 live values verified 2026-06-10. A new entity type
  -- means new code, which ships with a migration extending this list.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entity_source_links_entity_type_chk') THEN
    ALTER TABLE public.entity_source_links ADD CONSTRAINT entity_source_links_entity_type_chk
      CHECK (entity_type = ANY (ARRAY['client','derm_manifest','employee','inspection','invoice',
                                      'job','line_item','note','photo','property','quote','vehicle','visit']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'photo_links_entity_type_chk') THEN
    ALTER TABLE public.photo_links ADD CONSTRAINT photo_links_entity_type_chk
      CHECK (entity_type = ANY (ARRAY['derm_manifest','inspection','note','visit']));
  END IF;
END $$;
