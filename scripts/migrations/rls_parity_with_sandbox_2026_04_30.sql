-- =============================================================================
-- RLS parity with Sandbox — 2026-04-30
-- =============================================================================
-- Yannick's Lovable-driven security audit on Sandbox added baseline RLS
-- policies on 7 empty-RLS tables and tightened employees from public to
-- authenticated-only, plus added storage write policies on the bucket.
-- Production has the same gaps. This migration mirrors his fixes here.
--
-- All policies use DROP IF EXISTS + CREATE so the migration is idempotent.
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- public.notes — auth read + service_role full
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated read notes" ON public.notes;
CREATE POLICY "Authenticated read notes" ON public.notes
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role full access notes" ON public.notes;
CREATE POLICY "Service role full access notes" ON public.notes
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.photos — anon read + auth read + service_role full
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anon read photos" ON public.photos;
CREATE POLICY "Anon read photos" ON public.photos
  FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "Authenticated read photos" ON public.photos;
CREATE POLICY "Authenticated read photos" ON public.photos
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role full access photos" ON public.photos;
CREATE POLICY "Service role full access photos" ON public.photos
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.photo_links — anon read + auth read + service_role full
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anon read photo_links" ON public.photo_links;
CREATE POLICY "Anon read photo_links" ON public.photo_links
  FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "Authenticated read photo_links" ON public.photo_links;
CREATE POLICY "Authenticated read photo_links" ON public.photo_links
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role full access photo_links" ON public.photo_links;
CREATE POLICY "Service role full access photo_links" ON public.photo_links
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.vehicle_telemetry_readings — auth read + service_role full
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated read vehicle_telemetry_readings" ON public.vehicle_telemetry_readings;
CREATE POLICY "Authenticated read vehicle_telemetry_readings" ON public.vehicle_telemetry_readings
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role full access vehicle_telemetry_readings" ON public.vehicle_telemetry_readings;
CREATE POLICY "Service role full access vehicle_telemetry_readings" ON public.vehicle_telemetry_readings
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.jobber_oversized_attachments — auth read + service_role full
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated read jobber_oversized_attachments" ON public.jobber_oversized_attachments;
CREATE POLICY "Authenticated read jobber_oversized_attachments" ON public.jobber_oversized_attachments
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Service role full access jobber_oversized_attachments" ON public.jobber_oversized_attachments;
CREATE POLICY "Service role full access jobber_oversized_attachments" ON public.jobber_oversized_attachments
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.webhook_events_log — service_role only (raw webhook payloads)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Service role full access webhook_events_log" ON public.webhook_events_log;
CREATE POLICY "Service role full access webhook_events_log" ON public.webhook_events_log
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.webhook_tokens — service_role only (credentials)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Service role full access webhook_tokens" ON public.webhook_tokens;
CREATE POLICY "Service role full access webhook_tokens" ON public.webhook_tokens
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- public.employees — replace anon read with authenticated-only
-- (matching Yannick's choice to remove public read of staff roster)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow public read access on employees" ON public.employees;

DROP POLICY IF EXISTS "Authenticated users can read employees" ON public.employees;
CREATE POLICY "Authenticated users can read employees" ON public.employees
  FOR SELECT TO authenticated USING (true);
-- "Allow service_role full access on employees" already exists, leave it.

-- ----------------------------------------------------------------------------
-- storage.objects — write access on GT - Visits Images for authenticated only
-- (public reads via individual file URLs continue to work because the bucket
-- is marked public; we're only restricting WRITE).
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated can upload GT visit images" ON storage.objects;
CREATE POLICY "Authenticated can upload GT visit images" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'GT - Visits Images');

DROP POLICY IF EXISTS "Authenticated can update GT visit images" ON storage.objects;
CREATE POLICY "Authenticated can update GT visit images" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'GT - Visits Images')
  WITH CHECK (bucket_id = 'GT - Visits Images');

DROP POLICY IF EXISTS "Authenticated can delete GT visit images" ON storage.objects;
CREATE POLICY "Authenticated can delete GT visit images" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'GT - Visits Images');

COMMIT;
