-- ============================================================================
-- fix_security_definer_views.sql — flip 7 views from SECURITY DEFINER to INVOKER
-- ============================================================================
-- Triggered by Supabase ERROR lint security_definer_view (2026-04-19 alert).
--
-- A view created with SECURITY DEFINER runs with the *view creator's* permissions
-- (usually the supabase service role / postgres superuser), bypassing RLS on the
-- underlying tables. With security_invoker=true, the view runs as the querying
-- role — RLS on underlying tables is respected.
--
-- Reference: https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view
--
-- This is idempotent: setting the option to its current value is a no-op.
-- ============================================================================

ALTER VIEW public.driver_inspection_status     SET (security_invoker = true);
ALTER VIEW public.clients_due_service          SET (security_invoker = true);
ALTER VIEW public.client_services_flat         SET (security_invoker = true);
ALTER VIEW public.manifest_detail              SET (security_invoker = true);
ALTER VIEW public.visits_with_status           SET (security_invoker = true);
ALTER VIEW public.v_vehicle_telemetry_latest   SET (security_invoker = true);
ALTER VIEW public.visits_recent                SET (security_invoker = true);

-- Verification: list any remaining views in public.* still on definer mode.
DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'v'
    AND COALESCE((
      SELECT option_value
      FROM pg_options_to_table(c.reloptions)
      WHERE option_name = 'security_invoker'
    ), 'false') = 'false';

  IF bad IS NOT NULL THEN
    RAISE WARNING 'public views still on SECURITY DEFINER: %', bad;
  ELSE
    RAISE NOTICE 'All targeted views now use security_invoker.';
  END IF;
END $$;
