-- ============================================================================
-- 2026-11-09_rollback_time_on_site_s5_switch_on   Undoes 2026-11-09_1200 (the kill switch)
-- ============================================================================
-- Puts the request body back to '{}' (rules 1, the old v14 rule). Takes effect at the next 02:50 ET run; nothing
-- else needs undoing for it. Close-out rows already written (stage 'nightly') stay as the record of what ran.
-- Refuses unless the live body is exactly the one 2026-11-09_1200 wrote (md5 b36e494e...).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $s5_back$
DECLARE
  c_fn   constant regprocedure := 'public.fn_request_time_on_site_samsara_recheck()'::regprocedure;
  c_from constant text := 'body := ''{"rules":2}''::jsonb, timeout_milliseconds := 120000';
  c_to   constant text := 'body := ''{}''::jsonb, timeout_milliseconds := 120000';
  v_old text; v_new text; v_acl_before text; v_acl_after text;
BEGIN
  v_old := pg_get_functiondef(c_fn);
  IF md5(v_old) <> 'b36e494ec7dc8be801ef47cf32966bc7' THEN
    RAISE EXCEPTION 'S5 rollback: the live body is not the switched-on one (md5 %)', md5(v_old);
  END IF;
  SELECT proacl::text INTO v_acl_before FROM pg_proc WHERE oid = c_fn;
  EXECUTE replace(v_old, c_from, c_to);
  v_new := pg_get_functiondef(c_fn);
  IF md5(v_new) <> '10797df588684d193d674f9f227edc5d' THEN
    RAISE EXCEPTION 'S5 rollback: the restored body md5 % is not the pre-S5 one', md5(v_new);
  END IF;
  SELECT proacl::text INTO v_acl_after FROM pg_proc WHERE oid = c_fn;
  IF v_acl_after IS DISTINCT FROM v_acl_before THEN RAISE EXCEPTION 'S5 rollback: grants moved'; END IF;
END $s5_back$;
COMMIT;
