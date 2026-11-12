-- ============================================================================
-- 2026-11-11_2350_time_on_site_rc6_any_truck_fill_out   Trello vpF5PLQj, step RC6
-- ============================================================================
-- Fred, 2026-11-11: "go ahead with today's three". Plan: samsara-checks/recheck_plan_2026-10-27/PLAN.md 5.6 (RC6),
-- spec docs/specs/2026-11-02-time-on-site-nightly-rule.md.
--
-- WHY: public.fn_fill_blank_time_on_site writes a blank visit's time on site from ANY truck's GPS within 150 m of the
-- property when the job was marked complete (source gps_150m_any_truck). Since S5 (2026-11-09) the 02:50 ET nightly
-- (edge fn time-on-site-samsara-recheck, rules 2) measures blanks from Samsara's own stays and, when another truck
-- than the visit's was there, holds the visit and asks a person which truck went (the 11 AM post's "Which truck
-- went?" block, S8). A fill from another truck's GPS answers that question by guessing, and since it writes once, the
-- guess stays. Viktor's truck-set path lost the same call in S3b (2026-11-03_1500).
--
-- WHAT, two edits and nothing else:
--   1. pg_cron job 26 `time-on-site-nightly` (02:20 ET): its third statement, the any-truck fill, is removed. The stop
--      fill and the 150 m compute stay (the compute is removed at S10 if the nightly replaced every value it wrote).
--   2. public.fn_request_time_on_site_reminder() (the 11 AM post's wrapper): its line calling the any-truck fill is
--      replaced by a comment. The new body must equal the old one with that one line replaced, byte for byte, and the
--      grants must be identical.
-- public.fn_fill_blank_time_on_site itself stays until S10 (cleanup); after this nothing calls it (checked below).
--
-- Measured before: 0 rows labelled time-on-site-any-truck in audit.logs in the 14 days to 2026-11-11, so "no any-truck
-- write tomorrow morning" cannot fail on its own. The positive control (rehearsal, rolled back): a 112-YA fixture with
-- no truck, placed where a real truck was parked when it was marked complete, with 112-YA counted as a customer for
-- that transaction only, is filled gps_150m_any_truck by the OLD cron command and left blank by the NEW one.
-- (The plan's fixture as written could not work: the fill skips test clients through public.fn_is_non_customer.)
--
-- Audit (rule 8): no table changes. A cron command and one function body.
-- Rollback: 2026-11-11_rollback_time_on_site_rc6_any_truck_fill_out.sql (both back; guarded by the new md5s).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $rc6$
DECLARE
  c_fn      constant regprocedure := 'public.fn_request_time_on_site_reminder()'::regprocedure;
  c_from    constant text := E'    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today, true);\n';
  c_to      constant text := E'    -- 2026-11-11 RC6 (Trello vpF5PLQj): the any-truck fill is out; the 02:50 nightly asks which truck went\n';
  c_cmd_old constant text := 'select public.fn_fill_time_on_site_from_stops(true); select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true)';
  c_cmd_new constant text := 'select public.fn_fill_time_on_site_from_stops(true); select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true)';
  v_old text; v_new text; v_acl_before text; v_acl_after text; v_hits int; v_job record;
BEGIN
  -- PIN: the body and the command read on 2026-11-11 23:31 ET
  v_old := pg_get_functiondef(c_fn);
  IF md5(v_old) <> '3a26981f6aeac06d460c2cab3ad59456' THEN
    RAISE EXCEPTION 'RC6: the reminder wrapper is not the one read on 11-11 (md5 %). Re-read it first.', md5(v_old);
  END IF;
  v_hits := (length(v_old) - length(replace(v_old, c_from, ''))) / length(c_from);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'RC6: the anchor occurs % times, expected 1', v_hits; END IF;
  SELECT jobid, jobname, schedule, active, command INTO v_job FROM cron.job WHERE jobid = 26;
  IF v_job.command IS DISTINCT FROM c_cmd_old OR md5(v_job.command) <> 'c9a5863e351a828e3197880d6f64244e'
     OR v_job.jobname <> 'time-on-site-nightly' OR v_job.schedule <> '20 7 * * *' OR NOT v_job.active THEN
    RAISE EXCEPTION 'RC6: cron 26 is not the job read on 11-11 (% / % / % / md5 %)', v_job.jobname, v_job.schedule, v_job.active, md5(v_job.command);
  END IF;
  SELECT proacl::text INTO v_acl_before FROM pg_proc WHERE oid = c_fn;

  EXECUTE replace(v_old, c_from, c_to);
  PERFORM cron.alter_job(26, command => c_cmd_new);

  -- VERIFY
  v_new := pg_get_functiondef(c_fn);
  IF v_new IS DISTINCT FROM replace(v_old, c_from, c_to) THEN
    RAISE EXCEPTION 'RC6: the new wrapper body differs from the old one beyond the one line';
  END IF;
  IF position('fn_fill_blank_time_on_site' in v_new) > 0 THEN RAISE EXCEPTION 'RC6: the wrapper still names the any-truck fill'; END IF;
  IF position('perform public.fn_fill_time_on_site_from_stops(true);' in v_new) = 0
     OR position('perform public.fn_compute_time_on_site(v_today - 3, v_today, true);' in v_new) = 0 THEN
    RAISE EXCEPTION 'RC6: the stop fill and the 150 m compute must stay in the wrapper';
  END IF;
  IF md5(v_new) <> '2be5493ef69a057b0e3c047c85cd88d8' THEN
    RAISE EXCEPTION 'RC6: new wrapper md5 % is not the rehearsed one', md5(v_new);
  END IF;
  SELECT proacl::text INTO v_acl_after FROM pg_proc WHERE oid = c_fn;
  IF v_acl_after IS DISTINCT FROM v_acl_before THEN RAISE EXCEPTION 'RC6: grants moved (% -> %)', v_acl_before, v_acl_after; END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobid = 26 AND jobname = 'time-on-site-nightly' AND schedule = '20 7 * * *'
                 AND active AND command = c_cmd_new AND md5(command) = 'f7bb9ad7e5be19613da578071ced19f8') THEN
    RAISE EXCEPTION 'RC6: cron 26 is not the expected job after the change (md5 %)', (SELECT md5(command) FROM cron.job WHERE jobid = 26);
  END IF;
  -- nothing calls the fill any more; the function itself stays until S10
  IF EXISTS (SELECT 1 FROM cron.job WHERE command ILIKE '%fn_fill_blank_time_on_site%') THEN
    RAISE EXCEPTION 'RC6: a cron job still calls the any-truck fill';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prokind = 'f'
                AND p.proname <> 'fn_fill_blank_time_on_site'
                AND pg_get_functiondef(p.oid) ILIKE '%fn_fill_blank_time_on_site%') THEN
    RAISE EXCEPTION 'RC6: a function still calls the any-truck fill';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_fill_blank_time_on_site') THEN
    RAISE EXCEPTION 'RC6: the fill function itself must stay until S10';
  END IF;
END $rc6$;
COMMIT;
