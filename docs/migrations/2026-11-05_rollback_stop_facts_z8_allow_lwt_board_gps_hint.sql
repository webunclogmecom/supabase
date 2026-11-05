-- ============================================================================
-- 2026-11-05_rollback_stop_facts_z8_allow_lwt_board_gps_hint  Undoes 2026-11-05_1120
-- ============================================================================
-- Z8 counts derm.lwt_board again, so every hourly stop_facts_integrity run reads 'error' until that read is gone.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $rb$
DECLARE v text := pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure);
  a text := $a$where n.nspname in ('derm','customer','client') and (case when n.nspname = 'derm' and p.proname = 'lwt_board' then replace(p.prosrc, 'public.v_vehicle_dumps', '') else p.prosrc end) ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))   -- Fred, 2026-11-05: derm.lwt_board may read public.v_vehicle_dumps (the on-screen GPS hint); any other read still counts$a$;
  b text := $b$where n.nspname in ('derm','customer','client') and p.prosrc ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))$b$;
BEGIN
  IF md5(v) <> 'ef54fb8a632a44d7db96fb826b421be6' THEN RAISE EXCEPTION 'rollback: fn_stop_facts_checks is not the body 2026-11-05_1120 left'; END IF;
  EXECUTE replace(v, a, b);
  IF md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) <> '2d8720d7875029f3fc64a890ddda0b9e' THEN RAISE EXCEPTION 'rollback: the old md5 did not come back'; END IF;
END $rb$;
COMMIT;
