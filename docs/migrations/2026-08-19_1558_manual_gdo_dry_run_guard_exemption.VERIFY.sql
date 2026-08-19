-- CONTROL: the guard must STILL reject a BOT-shaped live row on a pre-cutoff visit.
-- Without this, "manual rows now work" and "the guard is disabled" look identical.
DO $control$
DECLARE v_pre bigint; bot_allowed bool; manual_allowed bool; v_err text;
BEGIN
  SELECT v.id INTO v_pre FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_date < public.rpa_launch_cutoff() LIMIT 1;
  IF v_pre IS NULL THEN RAISE EXCEPTION 'no pre-cutoff visit to test with'; END IF;

  -- A. a BOT-shaped live row on a pre-cutoff visit must STILL be rejected
  BEGIN
    INSERT INTO public.derm_portal_submissions
      (visit_id, run_id, status, dry_run, portal_confirmation, attempted_at, screenshot_path)
    VALUES (v_pre, 'rpa-run-control', 'SUCCESS', false, 'C', now(), v_pre::text||'/rpa-run-control.jpg');
    bot_allowed := true;
  EXCEPTION WHEN others THEN bot_allowed := false; v_err := SQLERRM; END;

  -- B. a MANUAL-shaped live row on the same visit must now be accepted
  BEGIN
    INSERT INTO public.derm_portal_submissions
      (visit_id, run_id, status, dry_run, portal_confirmation, attempted_at, screenshot_path)
    VALUES (v_pre, 'manual-control', 'SUCCESS', false, 'C', now(), v_pre::text||'/manual-control.jpg');
    manual_allowed := true;
  EXCEPTION WHEN others THEN manual_allowed := false; END;

  RAISE NOTICE 'A bot row pre-cutoff    : %  (want FALSE)  [%]', bot_allowed, coalesce(v_err,'');
  RAISE NOTICE 'B manual row pre-cutoff : %  (want TRUE)', manual_allowed;

  IF bot_allowed THEN
    RAISE EXCEPTION 'FAIL: the guard lets a BOT row through pre-cutoff - it was DISABLED, not narrowed';
  END IF;
  IF NOT manual_allowed THEN
    RAISE EXCEPTION 'FAIL: a manual row is still blocked pre-cutoff - the exemption does not work';
  END IF;

  RAISE EXCEPTION 'BOTH CONTROLS PASSED: guard narrowed, not disabled - rolling back';
END $control$;
