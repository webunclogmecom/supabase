-- ============================================================================
-- 2026-11-05_1120_stop_facts_z8_allow_lwt_board_gps_hint  Z8 allows one read: the Monthly Report page's GPS hint
-- ============================================================================
-- THE ASK
--   Fred, 2026-11-05 (AskUserQuestion, Trello vpF5PLQj morning check): "Allow this one function".
-- WHY
--   Z8 is the boundary check from the tank sensors plan (N1, V43): no derm, customer or client object may read the new
--   stop and tank objects. 2026-11-05_0245 (Monthly Report, Trello #173) made derm.lwt_board read public.v_vehicle_dumps
--   for one line on the staff page ("GPS saw <truck> at <site> on <day> at <time>"). The value is never saved or printed:
--   the page's code uses it only in that line. So every hourly stop_facts_integrity run since 02:35 ET read 'error',
--   which also fails the duration re-check's morning check.
-- WHAT CHANGES
--   public.fn_stop_facts_checks, one anchored edit of the live body, md5 2d8720d7875029f3fc64a890ddda0b9e -> ef54fb8a632a44d7db96fb826b421be6.
--   Z8's function sweep ignores the text 'public.v_vehicle_dumps' in derm.lwt_board and nowhere else. It is the read that
--   is allowed, not the function: a second stop or tank read in lwt_board still counts, and so does that same view read
--   from any other function.
-- WHAT DOES NOT CHANGE
--   No data. derm.lwt_board and the page are untouched. Z8's view half and its positive control are unchanged.
-- VERIFY: before the edit Z8 is 1 (the alarm this answers); after it Z8 is 0 with its control found; three probe functions
--   created and dropped inside this transaction each make Z8 fire: a derm function naming public.vehicle_stops, an
--   overload of lwt_board naming the allowed view AND public.vehicle_stops, and a derm function naming only the allowed
--   view. The ACL and the SECURITY DEFINER flag are unchanged.
-- ROLLBACK: docs/migrations/2026-11-05_rollback_stop_facts_z8_allow_lwt_board_gps_hint.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) <> '2d8720d7875029f3fc64a890ddda0b9e' THEN
    RAISE EXCEPTION 'Z8: fn_stop_facts_checks is not the body this edit was written against'; END IF;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 1 THEN RAISE EXCEPTION 'Z8: expected Z8 = 1 before the edit, the alarm this answers'; END IF;
END $pin$;
CREATE TEMP TABLE _z8_ctx ON COMMIT DROP AS
  SELECT proacl::text AS acl0, prosecdef AS def0 FROM pg_proc WHERE oid = 'public.fn_stop_facts_checks()'::regprocedure;

DO $edit$
DECLARE v text := pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure);
  a text := $a$where n.nspname in ('derm','customer','client') and p.prosrc ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))$a$;
  b text := $b$where n.nspname in ('derm','customer','client') and (case when n.nspname = 'derm' and p.proname = 'lwt_board' then replace(p.prosrc, 'public.v_vehicle_dumps', '') else p.prosrc end) ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))   -- Fred, 2026-11-05: derm.lwt_board may read public.v_vehicle_dumps (the on-screen GPS hint); any other read still counts$b$;
BEGIN
  IF array_length(string_to_array(v, a), 1) <> 2 THEN RAISE EXCEPTION 'Z8: the anchor must occur exactly once'; END IF;
  EXECUTE replace(v, a, b);
END $edit$;

DO $verify$ BEGIN
  IF md5(pg_get_functiondef('public.fn_stop_facts_checks()'::regprocedure)) <> 'ef54fb8a632a44d7db96fb826b421be6' THEN RAISE EXCEPTION 'VERIFY: the new md5 is not the expected one'; END IF;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: Z8 is not 0 after the edit'; END IF;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8_control_found')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'VERIFY: the Z8 control was not found'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_stop_facts_checks()'::regprocedure) IS DISTINCT FROM (SELECT acl0 FROM _z8_ctx) THEN RAISE EXCEPTION 'VERIFY: the ACL moved'; END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.fn_stop_facts_checks()'::regprocedure) IS DISTINCT FROM (SELECT def0 FROM _z8_ctx) THEN RAISE EXCEPTION 'VERIFY: SECURITY DEFINER moved'; END IF;

  CREATE FUNCTION derm.z8_probe_a() RETURNS bigint LANGUAGE sql AS $p$ SELECT count(*) FROM public.vehicle_stops $p$;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 1 THEN RAISE EXCEPTION 'VERIFY: a derm function naming public.vehicle_stops did not fire Z8'; END IF;
  DROP FUNCTION derm.z8_probe_a();

  CREATE FUNCTION derm.lwt_board(p_z8_probe boolean) RETURNS bigint LANGUAGE sql AS $p$ SELECT count(*) FROM public.v_vehicle_dumps d, public.vehicle_stops s $p$;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 1 THEN RAISE EXCEPTION 'VERIFY: a second read inside lwt_board did not fire Z8'; END IF;
  DROP FUNCTION derm.lwt_board(boolean);

  CREATE FUNCTION derm.z8_probe_c() RETURNS bigint LANGUAGE sql AS $p$ SELECT count(*) FROM public.v_vehicle_dumps $p$;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 1 THEN RAISE EXCEPTION 'VERIFY: the allowed view read from another function did not fire Z8'; END IF;
  DROP FUNCTION derm.z8_probe_c();

  IF (public.fn_stop_facts_checks()->'integrity'->>'Z8')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: Z8 is not 0 after the probes'; END IF;
END $verify$;

COMMIT;
