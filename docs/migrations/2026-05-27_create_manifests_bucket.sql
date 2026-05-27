-- 2026-05-27_create_manifests_bucket.sql
-- DERM Tracker /upload page calls `supabase.storage.from("manifests").upload(...)`
-- but the bucket didn't exist, so uploads returned "Bucket not found".
-- Create it mirroring the existing `GT - Visits Images` bucket: public read,
-- 50 MB limit, image/video/PDF mime types, anon-INSERT scoped to derm/* paths,
-- authenticated full CRUD.
-- Audit opt-out: storage.objects is high-volume and not human-edited at the
-- row level — opt-out per CLAUDE.md rule 8 (sync-only append-style table).

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'manifests',
  'manifests',
  true,
  52428800,
  ARRAY['image/*', 'video/*', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Anon can upload (write) to derm/* paths in this bucket. Mirrors the same
-- policy on `GT - Visits Images`.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Anon can upload to derm path in manifests'
  ) THEN
    CREATE POLICY "Anon can upload to derm path in manifests"
      ON storage.objects FOR INSERT TO anon
      WITH CHECK (
        bucket_id = 'manifests'
        AND (storage.foldername(name))[1] = 'derm'
      );
  END IF;
END $$;

-- Authenticated full CRUD on manifests bucket.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Authenticated can read manifests'
  ) THEN
    CREATE POLICY "Authenticated can read manifests"
      ON storage.objects FOR SELECT TO authenticated
      USING (bucket_id = 'manifests' AND auth.uid() IS NOT NULL);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Authenticated can upload manifests'
  ) THEN
    CREATE POLICY "Authenticated can upload manifests"
      ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'manifests');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Authenticated can update manifests'
  ) THEN
    CREATE POLICY "Authenticated can update manifests"
      ON storage.objects FOR UPDATE TO authenticated
      USING (bucket_id = 'manifests')
      WITH CHECK (bucket_id = 'manifests');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Authenticated can delete manifests'
  ) THEN
    CREATE POLICY "Authenticated can delete manifests"
      ON storage.objects FOR DELETE TO authenticated
      USING (bucket_id = 'manifests');
  END IF;
END $$;

-- Anon SELECT — public bucket, but explicit policy makes it discoverable.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='Public can read manifests'
  ) THEN
    CREATE POLICY "Public can read manifests"
      ON storage.objects FOR SELECT TO anon
      USING (bucket_id = 'manifests');
  END IF;
END $$;
