-- ============================================================================
-- 2026-11-09_1200_time_on_site_s5_switch_on   Trello vpF5PLQj, step S5
-- ============================================================================
-- Fred, 2026-11-09: "switch it on". The switch was planned for Wed 11-11; he moved it up after three passing
-- daily shadows (11-05, 11-06, 11-09; samsara-checks/duration_recheck_run_2026-10-28/shadow/).
--
-- WHAT: one line in public.fn_request_time_on_site_samsara_recheck (cron 151, 02:50 ET): the request body goes
-- from '{}' (rules 1, the old v14 rule) to '{"rules":2}' (the new nightly rule in edge fn
-- time-on-site-samsara-recheck v15, deployed switched off on 2026-11-05, spec
-- docs/specs/2026-11-02-time-on-site-nightly-rule.md). Nothing else in the function moves: the new body must equal
-- the old one with that single anchor replaced, byte for byte, and the grants must be identical.
--
-- From tonight (02:50 ET 11-10) the nightly writes Samsara stays by the new rule, holds doubtful visits for a person,
-- and writes close-out rows (stage 'nightly') to public.visit_time_on_site_corrections.
--
-- Audit (rule 8): no table changes. Function only.
-- Rollback: 2026-11-09_rollback_time_on_site_s5_switch_on.sql (the same line back; guarded by the new md5).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $s5$
DECLARE
  c_fn   constant regprocedure := 'public.fn_request_time_on_site_samsara_recheck()'::regprocedure;
  c_from constant text := 'body := ''{}''::jsonb, timeout_milliseconds := 120000';
  c_to   constant text := 'body := ''{"rules":2}''::jsonb, timeout_milliseconds := 120000';
  v_old text; v_new text; v_acl_before text; v_acl_after text; v_hits int;
BEGIN
  -- PIN: the body read on 2026-11-09 11:57 ET
  v_old := pg_get_functiondef(c_fn);
  IF md5(v_old) <> '10797df588684d193d674f9f227edc5d' THEN
    RAISE EXCEPTION 'S5: the live body is not the one read on 11-09 (md5 %). Re-read it before switching.', md5(v_old);
  END IF;
  v_hits := (length(v_old) - length(replace(v_old, c_from, ''))) / length(c_from);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'S5: the anchor occurs % times, expected 1', v_hits; END IF;
  SELECT proacl::text INTO v_acl_before FROM pg_proc WHERE oid = c_fn;

  EXECUTE replace(v_old, c_from, c_to);

  -- VERIFY
  v_new := pg_get_functiondef(c_fn);
  IF v_new IS DISTINCT FROM replace(v_old, c_from, c_to) THEN
    RAISE EXCEPTION 'S5: the new body differs from the old one beyond the one line';
  END IF;
  IF md5(v_new) <> 'b36e494ec7dc8be801ef47cf32966bc7' THEN
    RAISE EXCEPTION 'S5: new body md5 % is not the rehearsed one', md5(v_new);
  END IF;
  IF position('''{}''::jsonb' in v_new) > 0 THEN RAISE EXCEPTION 'S5: the old body is still present'; END IF;
  SELECT proacl::text INTO v_acl_after FROM pg_proc WHERE oid = c_fn;
  IF v_acl_after IS DISTINCT FROM v_acl_before THEN
    RAISE EXCEPTION 'S5: grants moved (% -> %)', v_acl_before, v_acl_after;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobid = 151 AND active AND schedule = '50 7 * * *'
                 AND command = 'select public.fn_request_time_on_site_samsara_recheck()') THEN
    RAISE EXCEPTION 'S5: cron 151 is not the expected 02:50 ET job calling the request function';
  END IF;
END $s5$;
COMMIT;
