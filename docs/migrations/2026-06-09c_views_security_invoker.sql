-- ============================================================================
-- Fix RLS-bypass on two Admin Review views: set security_invoker = true
-- ----------------------------------------------------------------------------
-- public.visit_manhole_options (created 2026-06-08f) and public.visits_with_review
-- (re-pointed 2026-06-08g) were created via CREATE [OR REPLACE] VIEW WITHOUT
-- `WITH (security_invoker = true)`. In PG15+ a view defaults to SECURITY DEFINER
-- (owner-run), which BYPASSES the caller's RLS — full_session_audit.js flags both as
-- an RLS-bypass risk. Both are anon-readable (the Admin Review app reads them) and
-- read only non-sensitive joins. Every underlying table — visits, visit_reviews,
-- clients, client_locations, gdos — has an anon SELECT policy (verified 2026-06-09),
-- so flipping to security_invoker makes the views respect the CALLER's RLS WITHOUT
-- breaking the anon app. Matches the established pattern (the manifest_pickable_visits
-- migration warns that CREATE OR REPLACE resets this to owner-run).
-- Audit (ADR 010): no data mutation — no audit trigger needed. Idempotent.
-- ============================================================================

ALTER VIEW public.visit_manhole_options SET (security_invoker = true);
ALTER VIEW public.visits_with_review    SET (security_invoker = true);
