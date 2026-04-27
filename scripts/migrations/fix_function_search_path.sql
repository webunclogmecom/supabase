-- ============================================================================
-- fix_function_search_path.sql — pin search_path on trg_set_updated_at
-- ============================================================================
-- Triggered by Supabase WARN lint function_search_path_mutable.
--
-- A function without an explicit search_path inherits the caller's search_path.
-- That's a hijack vector: a malicious schema in the caller's path could shadow
-- a function the body assumes is in pg_catalog (e.g. `now()`), letting an
-- attacker substitute their own implementation with a SECURITY DEFINER trigger.
--
-- Fix: pin to a known-safe search_path. We use `pg_catalog, public, pg_temp`
-- which is the default — the function body can keep its existing unqualified
-- references (`now()`) and resolution is now deterministic.
--
-- The other public function (set_updated_at) already has search_path pinned
-- (verified empty-string in audit), so we only target trg_set_updated_at here.
-- ============================================================================

ALTER FUNCTION public.trg_set_updated_at() SET search_path = pg_catalog, public, pg_temp;

-- Verification
DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
  INTO bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND p.proconfig IS NULL;

  IF bad IS NOT NULL THEN
    RAISE WARNING 'public functions still without pinned search_path: %', bad;
  ELSE
    RAISE NOTICE 'All public functions have pinned search_path.';
  END IF;
END $$;
