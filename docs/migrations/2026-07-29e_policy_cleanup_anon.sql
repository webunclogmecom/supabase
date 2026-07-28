-- ============================================================================
-- 2026-07-29e — policy cleanup: disarm the anon RLS policies left behind by the
--               2026-07-28 grant revokes
-- ============================================================================
-- ── WHY THIS EXISTS ────────────────────────────────────────────────────────
-- 28r/28s/28u/28w/28y revoked anon SELECT across derm, ops, customer and public.
-- They deliberately did NOT touch policies, because narrowing a policy is a
-- REPLACE and not a DROP (see the `{public}` trap below) and that deserved its
-- own gated migration. This is that migration.
--
-- Today anon holds ZERO grants in public/ops/customer/derm, so every anon policy
-- is INERT: Postgres checks the GRANT first and never consults RLS, so a policy
-- naming anon changes nothing. The problem is that they stay PRIMED — the moment
-- anyone re-grants (deliberately, or via a stray ALTER DEFAULT PRIVILEGES, which
-- is exactly how ops and public got wide open in the first place), 22 blanket
-- `USING (true)` policies silently re-open the whole exposure with no second
-- decision point. This migration removes the ammunition, not just the trigger.
--
-- Defence in depth, explicitly: the grant is the lock, the policy is the second
-- lock. After 28y the grant does all the work; after this, both do.
--
-- ── WHAT IS IN SCOPE ───────────────────────────────────────────────────────
-- `public` and `ops` ONLY. Deliberately NOT touched:
--   • storage.objects  — its 3 anon policies are LIVE, not inert (storage checks
--     RLS on its own table and anon reaches it through the storage API, not
--     through table grants). "Public can read manifests" and "Public can read
--     gdo permits" (2026-07-29a) are load-bearing for the Field Portal RIGHT NOW.
--     Touching them belongs to the storage-privacy leg.
--   • realtime.messages `app_inval_read` {anon,authenticated} — this IS the
--     anon-can-subscribe finding from the 28y audit, but DERM Tracker opens those
--     channels on mount OUTSIDE its auth gate, so narrowing it to authenticated
--     may break invalidation for the pre-auth window. Needs an app-side check
--     first. Left alone on purpose; do not read its survival as an oversight.
--   • cron.job / cron.job_run_details — Supabase-managed, `username = CURRENT_USER`,
--     not ours.
--
-- ── ⚠ THE `{public}` TRAP, AND WHY THIS IS NOT A BULK DROP ─────────────────
-- The PUBLIC pseudo-role INCLUDES `authenticated` (and every other role). Two
-- policies name it:
--     public.clients      "Allow public read access on clients"      SELECT true
--     public.inspections  "Allow public read access on inspections"  SELECT true
-- Dropping them blindly takes `authenticated` to ZERO ROWS, not just anon.
-- They are handled differently and for measured reasons:
--   • clients      — DROPPED. `admin_review_anon_read_clients` (narrowed below to
--                    authenticated, SELECT, USING true) provides identical
--                    coverage, so the drop is redundant-removal, not a loss.
--   • inspections  — NARROWED, NOT DROPPED. It is the ONLY non-service_role
--                    policy on the table; measured, `authenticated` has no other
--                    named policy there. Dropping it would silently take Admin
--                    Review's 319 inspections to 0 rows with no error anywhere.
-- This asymmetry is the entire reason this migration was not folded into 28y.
--
-- ── ⚠ WHY FIELD PORTAL CANNOT BE AFFECTED (verified, not assumed) ──────────
-- FP reads through postgres-owned SECURITY DEFINER RPCs and owner-rights views.
-- `postgres` has rolbypassrls = true, so RLS is bypassed entirely — even on the
-- 19 public tables that have FORCE ROW LEVEL SECURITY (where the owner would
-- normally NOT be exempt). Proven empirically rather than reasoned: with BOTH
-- non-service_role SELECT policies dropped from public.clients inside a
-- rolled-back transaction, `customer.get_client_portal('168-ava')` called as anon
-- still returned a populated client object.
--
-- ── METHOD ─────────────────────────────────────────────────────────────────
-- Role narrowing uses ALTER POLICY ... TO authenticated rather than DROP+CREATE,
-- so the USING/WITH CHECK expressions are preserved byte-for-byte and cannot be
-- mistranscribed. Every statement below was GENERATED from the live pg_policies
-- output, not typed from a doc.
--
-- Renames: 8 surviving policies had names that would actively lie after
-- narrowing (`..._anon_read...`, "Allow public read access..."). Misleading
-- security docs caused real damage this week — a table headed "Current Prod anon
-- policies the app depends on" nearly got anon INSERT/UPDATE restored verbatim.
-- A policy named `admin_review_anon_read_clients` that is authenticated-only is
-- the same hazard in the database itself. Names are also corrected away from
-- `admin_review_*`, since Calendar and DERM Tracker rely on several of them too.
--
-- ── ⚠ WHY THE 22 DROPS COST authenticated NOTHING: THE `_authn` TWINS ──────
-- Discovered while executing this, and worth knowing before reading pg_policies
-- on this database: the 2026-07-12 anon-surface harden did NOT narrow the anon
-- policies, it DUPLICATED them — each `anon_read_x` got an `anon_read_x_authn`
-- twin `TO authenticated`. So every table here already had authenticated
-- coverage from its twin, and dropping the anon half is a pure no-op for
-- authenticated. That is why the snapshot below is identical rather than merely
-- close.
-- ⚠ CONSEQUENCE FOR ANYONE AUDITING LATER: 34 policies in public/ops still have
-- "anon" in their NAME while being `{authenticated}`-only. ALL 34 end in
-- `_authn`. **Read the `roles` column, never the policy name.** They were left
-- renamed-alone deliberately: 34 more renames is typo surface for zero security
-- gain, and the `_authn` suffix is a consistent, greppable marker. The 8 renames
-- in section 4 were done only because those names had NO such marker and would
-- have read as live anon grants.
--
-- ── TEST GATE (must hold, or this does not ship) ───────────────────────────
-- The full `authenticated` row-count snapshot across all 51 RLS-enabled public
-- tables must be IDENTICAL before and after. Anything that moves means a policy
-- was load-bearing for authenticated and the change is wrong.
--
-- RESULT — dry run inside a rolled-back transaction: IDENTICAL across 51 tables.
-- ⚠ AND THE DETECTOR WAS PROVEN TO WORK IN BOTH DIRECTIONS, because a gate that
-- can only pass is not a gate. Negative control: doing the WRONG thing on
-- inspections (dropping the `{public}` policy instead of narrowing it) inside
-- the same harness produced `inspections before=319 after=0` and failed loudly.
--
-- Post-apply, live: authenticated snapshot matched the pre-migration baseline on
-- 50 of 51 tables; the one mover was `vehicle_telemetry_readings`
-- 1,215,656 -> 1,215,668, which is Samsara ingesting 12 rows during the window,
-- not a policy effect. inspections=319, clients=439, visits=2278, photos=10599
-- all held. anon still 401/42501 on public/customer/ops. All three Field Portal
-- RPCs still 200. Final state: ZERO anon-roled policies in public/ops.
--
-- ROLLBACK: restore from the pre-change policy inventory captured in
-- scripts/probes/ (or re-create from this file's inverse: re-add the dropped
-- anon policies as SELECT ... TO anon USING (true), and ALTER the narrowed ones
-- back TO anon, authenticated). Note the dropped ones are INERT while anon holds
-- no grants, so a rollback is only meaningful alongside a grant rollback.
--
-- AUDIT (ADR 010): policy-only change. No business data touched, no table shape
-- changed, no grant changed.
-- ============================================================================

begin;

-- ── 1. DROP the 22 inert anon-only policies in `public` ─────────────────────
-- anon holds no grant on any of these, so each is unreachable today. Removing
-- them means a future re-grant does not silently re-open blanket read access.
drop policy if exists "anon_read_client_contacts" on public.client_contacts;
drop policy if exists "client_locations_anon_read" on public.client_locations;
drop policy if exists "anon_read_dmnp" on public.derm_manifest_number_proposals;
drop policy if exists "Allow anon read on derm_manifests" on public.derm_manifests;
drop policy if exists "anon_read_disposal_facilities" on public.disposal_facilities;
drop policy if exists "admin_review_anon_read_employees" on public.employees;
drop policy if exists "anon_read_entity_source_links" on public.entity_source_links;
drop policy if exists "admin_review_anon_read_jobs" on public.jobs;
drop policy if exists "Allow anon read on line_items" on public.line_items;
drop policy if exists "Allow anon read on manifest_visits" on public.manifest_visits;
drop policy if exists "photo_classifications_anon_select" on public.photo_classifications;
drop policy if exists "Anon read photos" on public.photos;
drop policy if exists "anon_read_properties" on public.properties;
drop policy if exists "properties_anon_update_manhole" on public.properties;
drop policy if exists "shift_reviews_anon_select" on public.shift_reviews;
drop policy if exists "vehicle_decals_anon_read" on public.vehicle_decals;
drop policy if exists "admin_review_anon_read_vehicles" on public.vehicles;
drop policy if exists "Allow anon read on visit_assignments" on public.visit_assignments;
drop policy if exists "visit_assignments_anon_select" on public.visit_assignments;
drop policy if exists "visit_locations_anon_read" on public.visit_locations;
drop policy if exists "visit_reviews_anon_select" on public.visit_reviews;
drop policy if exists "visits_app_update_anon" on public.visits;

-- ── 2. NARROW the 10 {anon,authenticated} policies to authenticated ─────────
-- ALTER, not DROP+CREATE: the USING / WITH CHECK expressions are preserved
-- exactly. Several of these carry real predicates (not just `true`) — e.g.
-- visits_calendar_update's `source = 'visit-calendar'` — which is precisely what
-- must not be retyped by hand.
alter policy "calendar_day_markers_rw" on ops.calendar_day_markers to authenticated;
alter policy "admin_review_anon_read_clients" on public.clients to authenticated;
alter policy "anon_read_gdos" on public.gdos to authenticated;
alter policy "admin_review_anon_read_photo_links" on public.photo_links to authenticated;
alter policy "admin_review_anon_read_photos" on public.photos to authenticated;
alter policy "service_line_items_read" on public.service_line_items to authenticated;
alter policy "admin_review_anon_read_visits" on public.visits to authenticated;
alter policy "anon_update_visit_derm_required" on public.visits to authenticated;
alter policy "visits_calendar_update" on public.visits to authenticated;
alter policy "zones_anon_select_all" on public.zones to authenticated;

-- ── 3. the two {public} policies — asymmetric on purpose ────────────────────
-- clients: redundant once admin_review_anon_read_clients is authenticated-only.
drop policy if exists "Allow public read access on clients" on public.clients;
-- inspections: the ONLY non-service_role policy on the table. Narrow, never drop.
alter policy "Allow public read access on inspections" on public.inspections to authenticated;

-- ── 4. rename the survivors whose names would now lie ───────────────────────
alter policy "admin_review_anon_read_clients"     on public.clients     rename to clients_authenticated_read;
alter policy "anon_read_gdos"                     on public.gdos        rename to gdos_authenticated_read;
alter policy "admin_review_anon_read_photo_links" on public.photo_links rename to photo_links_authenticated_read;
alter policy "admin_review_anon_read_photos"      on public.photos      rename to photos_authenticated_read;
alter policy "admin_review_anon_read_visits"      on public.visits      rename to visits_authenticated_read;
alter policy "anon_update_visit_derm_required"    on public.visits      rename to visits_authenticated_update_derm_required;
alter policy "zones_anon_select_all"              on public.zones       rename to zones_authenticated_read;
alter policy "Allow public read access on inspections" on public.inspections rename to inspections_authenticated_read;

commit;
