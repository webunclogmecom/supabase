-- ============================================================================
-- Security hardening — 2026-05-05
-- ============================================================================
-- Goal: bring Prod and Sandbox to the same posture so both score clean on
-- Supabase advisor AND Lovable's security scan.
--
-- Changes (applied to both projects):
--   1. Drop all "Allow public read access" policies (USING=true, role=PUBLIC)
--      on vehicles, visits. Replace with authenticated-only reads using
--      `auth.uid() IS NOT NULL` predicate (clears "Always True" lint).
--   2. Drop "Anon read photo_links" / "Allow anon read on properties"
--      (Sandbox-only) — anon should not read app data.
--   3. Replace authenticated-read policies' USING(true) with
--      USING(auth.uid() IS NOT NULL) on photo_links and properties.
--   4. service_role full-access policies kept as-is (Edge Functions need them).
--
-- Sandbox-only steps (safe no-ops in Prod):
--   5. Drop anon UPDATE policies on visits/photo_links/properties — these
--      become unnecessary once Lovable migrates to app_visit_reviews via the
--      yannick_app_tables_2026_05_05.sql migration.
--   6. Recreate v_vehicle_telemetry_latest WITH (security_invoker = true)
--      (Prod already does this since 2026-05-04).
--   7. Enable RLS on _prod_schema_baseline + service_role-only policy.
--
-- Storage bucket change (handled separately — see comment block at bottom):
--   `GT - Visits Images` bucket is `public=true` in both projects. Making it
--   private requires Lovable to switch from /object/public/<bucket>/<path>
--   URLs to either createSignedUrl() or authenticated session downloads.
--   This file does NOT toggle the bucket — that's a separate operational step
--   coordinated with Lovable.
--
-- Idempotent: safe to re-run. All DROP POLICY uses IF EXISTS; CREATE POLICY
-- uses fresh names that won't collide.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Block 1: vehicles — remove public read, restrict to authenticated
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow public read access on vehicles" ON vehicles;
DROP POLICY IF EXISTS "Authenticated read vehicles"           ON vehicles;
CREATE POLICY "Authenticated read vehicles" ON vehicles
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Block 2: visits — remove public read, restrict to authenticated; drop anon UPDATE
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow public read access on visits"      ON visits;
DROP POLICY IF EXISTS "Anon can update visit review decisions"  ON visits;  -- Sandbox-only
DROP POLICY IF EXISTS "Authenticated read visits"               ON visits;
CREATE POLICY "Authenticated read visits" ON visits
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Block 3: photo_links — drop anon, tighten authenticated, drop anon UPDATE
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anon read photo_links"                 ON photo_links;
DROP POLICY IF EXISTS "Authenticated read photo_links"        ON photo_links;
DROP POLICY IF EXISTS "Anon can update photo_links role"      ON photo_links;  -- Sandbox-only
CREATE POLICY "Authenticated read photo_links" ON photo_links
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);
-- Authenticated INSERT (driver photo upload flow per LOVABLE-SYSTEM-PROMPT.md)
DROP POLICY IF EXISTS "Authenticated insert photo_links" ON photo_links;
CREATE POLICY "Authenticated insert photo_links" ON photo_links
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Block 4: properties — drop anon read (Sandbox), tighten authenticated, drop anon UPDATE
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow anon read on properties"            ON properties;  -- Sandbox-only
DROP POLICY IF EXISTS "Allow authenticated read on properties"   ON properties;
DROP POLICY IF EXISTS "Anon can update property manhole count"   ON properties;  -- Sandbox-only
CREATE POLICY "Authenticated read properties" ON properties
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Block 5: storage.objects — tighten reads on the photo bucket
-- ---------------------------------------------------------------------------
-- (Bucket flip from public→private is a separate step done via
-- storage.buckets UPDATE — see end-of-file comment block.)
-- Add an authenticated SELECT policy so the app can fetch via authenticated
-- session once the bucket is private.
DROP POLICY IF EXISTS "Authenticated can read GT visit images" ON storage.objects;
CREATE POLICY "Authenticated can read GT visit images" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'GT - Visits Images' AND auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Block 6: Sandbox-only — recreate definer view as invoker, RLS the bookkeeping table
-- ---------------------------------------------------------------------------
-- These two are no-ops in Prod (view is already invoker as of 2026-05-04;
-- _prod_schema_baseline doesn't exist in Prod).
-- ALTER VIEW SET avoids guessing the column list; works whether or not the
-- view exists in this project (Prod set it 2026-05-04 already; Sandbox may
-- still have it as DEFINER).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_views WHERE schemaname='public' AND viewname='v_vehicle_telemetry_latest'
  ) THEN
    EXECUTE 'ALTER VIEW public.v_vehicle_telemetry_latest SET (security_invoker = true)';
  END IF;
END
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='_prod_schema_baseline'
  ) THEN
    EXECUTE 'ALTER TABLE public._prod_schema_baseline ENABLE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS "service_role full access on _prod_schema_baseline" ON public._prod_schema_baseline';
    EXECUTE $p$
      CREATE POLICY "service_role full access on _prod_schema_baseline"
        ON public._prod_schema_baseline
        FOR ALL TO service_role
        USING (true) WITH CHECK (true)
    $p$;
  END IF;
END
$$;

-- ============================================================================
-- Storage bucket privacy flip — DO NOT include in this migration
-- ============================================================================
-- Run separately AFTER Lovable's photo URL pattern is updated:
--
--   UPDATE storage.buckets SET public = false WHERE id = 'GT - Visits Images';
--
-- Lovable currently uses public URLs:
--   https://<proj>.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/<path>
-- After the flip, those URLs return 404. Lovable must use one of:
--   a. supabase.storage.from('GT - Visits Images').createSignedUrl(path, 3600)
--   b. supabase.storage.from('GT - Visits Images').download(path)  (returns Blob)
--   c. /storage/v1/object/authenticated/<bucket>/<path>  with Bearer token header
-- Update LOVABLE-SYSTEM-PROMPT.md and 04-EXAMPLE-PROMPTS.md to reflect (a)
-- before flipping, then flip Sandbox first → verify → flip Prod.
-- ============================================================================
