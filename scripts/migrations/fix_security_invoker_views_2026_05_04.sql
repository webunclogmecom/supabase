-- ============================================================================
-- Fix Supabase advisor CRITICAL warnings: 2026-05-04
-- Two views were SECURITY DEFINER (the default) which bypasses RLS for any
-- caller. Change to SECURITY INVOKER so the calling user's permissions
-- and RLS policies apply.
--
-- visits_with_status was just recreated 2026-05-04 (drop_dead_3nf_columns
-- migration) without the security_invoker flag — that migration's CREATE
-- VIEW is now also updated to set the flag, but this file fixes the
-- immediate state and addresses v_vehicle_telemetry_latest which was
-- DEFINER from the start.
-- ============================================================================

ALTER VIEW visits_with_status         SET (security_invoker = true);
ALTER VIEW v_vehicle_telemetry_latest SET (security_invoker = true);
