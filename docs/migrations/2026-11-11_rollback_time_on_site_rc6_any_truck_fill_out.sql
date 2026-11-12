-- ============================================================================
-- 2026-11-11_rollback_time_on_site_rc6_any_truck_fill_out   Undoes 2026-11-11_2350
-- ============================================================================
-- Puts the any-truck fill back: the third statement of pg_cron job 26 and the line in
-- public.fn_request_time_on_site_reminder(). Takes effect at the next 02:20 ET run / 11 AM post.
-- Refuses unless both are exactly what 2026-11-11_2350 wrote (md5 2be5493e... and f7bb9ad7...).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $rc6_back$
DECLARE
  c_fn      constant regprocedure := 'public.fn_request_time_on_site_reminder()'::regprocedure;
  c_from    constant text := E'    -- 2026-11-11 RC6 (Trello vpF5PLQj): the any-truck fill is out; the 02:50 nightly asks which truck went\n';
  c_to      constant text := E'    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today, true);\n';
  c_cmd_old constant text := 'select public.fn_fill_time_on_site_from_stops(true); select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true)';
  v_old text; v_acl_before text; v_acl_after text;
BEGIN
  v_old := pg_get_functiondef(c_fn);
  IF md5(v_old) <> '2be5493ef69a057b0e3c047c85cd88d8' THEN
    RAISE EXCEPTION 'RC6 rollback: the wrapper is not the one RC6 wrote (md5 %)', md5(v_old);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobid = 26 AND md5(command) = 'f7bb9ad7e5be19613da578071ced19f8') THEN
    RAISE EXCEPTION 'RC6 rollback: cron 26 is not the command RC6 wrote';
  END IF;
  SELECT proacl::text INTO v_acl_before FROM pg_proc WHERE oid = c_fn;
  EXECUTE replace(v_old, c_from, c_to);
  PERFORM cron.alter_job(26, command => c_cmd_old);
  IF md5(pg_get_functiondef(c_fn)) <> '3a26981f6aeac06d460c2cab3ad59456' THEN
    RAISE EXCEPTION 'RC6 rollback: the restored wrapper is not the pre-RC6 one (md5 %)', md5(pg_get_functiondef(c_fn));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobid = 26 AND md5(command) = 'c9a5863e351a828e3197880d6f64244e'
                 AND schedule = '20 7 * * *' AND active) THEN
    RAISE EXCEPTION 'RC6 rollback: cron 26 is not the pre-RC6 command';
  END IF;
  SELECT proacl::text INTO v_acl_after FROM pg_proc WHERE oid = c_fn;
  IF v_acl_after IS DISTINCT FROM v_acl_before THEN RAISE EXCEPTION 'RC6 rollback: grants moved'; END IF;
END $rc6_back$;
COMMIT;
