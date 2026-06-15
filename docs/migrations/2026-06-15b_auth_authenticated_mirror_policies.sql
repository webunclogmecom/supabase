-- ============================================================================
-- 2026-06-15 — A1: additive 'authenticated' mirror policies (auth gate Phase 1)
-- ============================================================================
-- Makes the 'authenticated' role a full peer of 'anon' for every anon-only policy
-- in public, so adding a Supabase Auth login to the apps does NOT change data access
-- (a logged-in user sees/writes exactly what anon did). ADDITIVE ONLY — the live anon
-- policies are untouched, so the currently-anon apps are unaffected (zero risk).
-- Generated from pg_policies; 35 mirror policies. Idempotent (skips existing _authn).
-- A2 (later, after each app's login is live) drops anon from the WRITE policies;
-- Phase 1.5 drops anon from the READ policies. Reversible: DROP the *_authn policies.
-- Audit (ADR 010): RLS policy change only; no business-table data touched.
-- ============================================================================

-- mirror of client_contacts.anon_read_client_contacts (SELECT)
CREATE POLICY "anon_read_client_contacts_authn" ON public."client_contacts" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of client_locations.client_locations_anon_read (SELECT)
CREATE POLICY "client_locations_anon_read_authn" ON public."client_locations" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of derm_manifest_number_proposals.anon_insert_dmnp (INSERT)
CREATE POLICY "anon_insert_dmnp_authn" ON public."derm_manifest_number_proposals" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of derm_manifest_number_proposals.anon_read_dmnp (SELECT)
CREATE POLICY "anon_read_dmnp_authn" ON public."derm_manifest_number_proposals" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of derm_manifest_number_proposals.anon_update_dmnp (UPDATE)
CREATE POLICY "anon_update_dmnp_authn" ON public."derm_manifest_number_proposals" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of derm_manifests.anon_insert_derm_manifests (INSERT)
CREATE POLICY "anon_insert_derm_manifests_authn" ON public."derm_manifests" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of derm_manifests.Allow anon read on derm_manifests (SELECT)
CREATE POLICY "Allow anon read on derm_manifests_authn" ON public."derm_manifests" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of derm_manifests.anon_update_derm_manifests (UPDATE)
CREATE POLICY "anon_update_derm_manifests_authn" ON public."derm_manifests" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of disposal_facilities.anon_read_disposal_facilities (SELECT)
CREATE POLICY "anon_read_disposal_facilities_authn" ON public."disposal_facilities" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of employees.admin_review_anon_read_employees (SELECT)
CREATE POLICY "admin_review_anon_read_employees_authn" ON public."employees" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of entity_source_links.anon_read_entity_source_links (SELECT)
CREATE POLICY "anon_read_entity_source_links_authn" ON public."entity_source_links" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of jobs.admin_review_anon_read_jobs (SELECT)
CREATE POLICY "admin_review_anon_read_jobs_authn" ON public."jobs" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of line_items.Allow anon read on line_items (SELECT)
CREATE POLICY "Allow anon read on line_items_authn" ON public."line_items" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of manifest_visits.anon_delete_manifest_visits (DELETE)
CREATE POLICY "anon_delete_manifest_visits_authn" ON public."manifest_visits" AS PERMISSIVE FOR DELETE TO authenticated USING (true);
-- mirror of manifest_visits.anon_insert_manifest_visits (INSERT)
CREATE POLICY "anon_insert_manifest_visits_authn" ON public."manifest_visits" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of manifest_visits.Allow anon read on manifest_visits (SELECT)
CREATE POLICY "Allow anon read on manifest_visits_authn" ON public."manifest_visits" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of photo_classifications.photo_classifications_anon_insert (INSERT)
CREATE POLICY "photo_classifications_anon_insert_authn" ON public."photo_classifications" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of photo_classifications.photo_classifications_anon_select (SELECT)
CREATE POLICY "photo_classifications_anon_select_authn" ON public."photo_classifications" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of photo_classifications.photo_classifications_anon_update (UPDATE)
CREATE POLICY "photo_classifications_anon_update_authn" ON public."photo_classifications" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of photos.Anon read photos (SELECT)
CREATE POLICY "Anon read photos_authn" ON public."photos" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of properties.anon_read_properties (SELECT)
CREATE POLICY "anon_read_properties_authn" ON public."properties" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of properties.properties_anon_update_manhole (UPDATE)
CREATE POLICY "properties_anon_update_manhole_authn" ON public."properties" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of shift_reviews.shift_reviews_anon_insert (INSERT)
CREATE POLICY "shift_reviews_anon_insert_authn" ON public."shift_reviews" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of shift_reviews.shift_reviews_anon_select (SELECT)
CREATE POLICY "shift_reviews_anon_select_authn" ON public."shift_reviews" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of shift_reviews.shift_reviews_anon_update (UPDATE)
CREATE POLICY "shift_reviews_anon_update_authn" ON public."shift_reviews" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of vehicles.admin_review_anon_read_vehicles (SELECT)
CREATE POLICY "admin_review_anon_read_vehicles_authn" ON public."vehicles" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of visit_assignments.visit_assignments_anon_delete (DELETE)
CREATE POLICY "visit_assignments_anon_delete_authn" ON public."visit_assignments" AS PERMISSIVE FOR DELETE TO authenticated USING (true);
-- mirror of visit_assignments.visit_assignments_anon_insert (INSERT)
CREATE POLICY "visit_assignments_anon_insert_authn" ON public."visit_assignments" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of visit_assignments.Allow anon read on visit_assignments (SELECT)
CREATE POLICY "Allow anon read on visit_assignments_authn" ON public."visit_assignments" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of visit_assignments.visit_assignments_anon_select (SELECT)
CREATE POLICY "visit_assignments_anon_select_authn" ON public."visit_assignments" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of visit_locations.visit_locations_anon_read (SELECT)
CREATE POLICY "visit_locations_anon_read_authn" ON public."visit_locations" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of visit_reviews.visit_reviews_anon_insert (INSERT)
CREATE POLICY "visit_reviews_anon_insert_authn" ON public."visit_reviews" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
-- mirror of visit_reviews.visit_reviews_anon_select (SELECT)
CREATE POLICY "visit_reviews_anon_select_authn" ON public."visit_reviews" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- mirror of visit_reviews.visit_reviews_anon_update (UPDATE)
CREATE POLICY "visit_reviews_anon_update_authn" ON public."visit_reviews" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
-- mirror of visits.visits_anon_update_manhole (UPDATE)
CREATE POLICY "visits_anon_update_manhole_authn" ON public."visits" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- Table write GRANTs authenticated lacked vs anon (RLS policies are inert without the grant).
-- SELECT grants are already at parity (verified 0 gaps). Idempotent.
GRANT INSERT, UPDATE ON public."derm_manifests" TO authenticated;
GRANT INSERT, DELETE ON public."manifest_visits" TO authenticated;
GRANT INSERT, DELETE ON public."visit_assignments" TO authenticated;
