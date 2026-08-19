-- Mutation test for fn_record_manual_gdo_report. Everything rolled back.
DO $probe$
DECLARE
  v_ok bigint; v_bad_noc27 bigint; v_dup bigint;
  ok_happy bool; ok_noc27 bool; ok_dup bool; ok_runid bool; ok_path bool;
  ok_noconf bool; ok_future bool; ok_notcompleted bool;
  v_row public.derm_portal_submissions; v_run text; v_path text;
  v_queue_before int; v_suppressed bool; v_err text;
BEGIN
  -- a real code-27 completed visit with NO filing yet
  SELECT v.id INTO v_ok
    FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status='completed'
     AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id=v.id
                   AND (li.name='27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%'))
     AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                       WHERE s.visit_id=v.id AND s.dry_run IS NOT TRUE)
   ORDER BY v.visit_date DESC LIMIT 1;
  -- a completed visit with NO code-27 line item
  SELECT v.id INTO v_bad_noc27
    FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status='completed'
     AND NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id=v.id
                       AND (li.name='27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%'))
   ORDER BY v.id DESC LIMIT 1;
  -- a visit that ALREADY has a live filing
  SELECT s.visit_id INTO v_dup FROM public.derm_portal_submissions s
   WHERE s.dry_run IS NOT TRUE LIMIT 1;

  IF v_ok IS NULL OR v_bad_noc27 IS NULL OR v_dup IS NULL THEN
    RAISE EXCEPTION 'PROBE SETUP FAILED: ok=% noc27=% dup=% - cannot test', v_ok, v_bad_noc27, v_dup;
  END IF;

  v_run  := 'manual-20260819-probe';
  v_path := v_ok::text || '/' || v_run || '.jpg';

  -- 1 HAPPY PATH
  BEGIN
    v_row := public.fn_record_manual_gdo_report(v_ok,'CONF-12345', now() - interval '2 days', v_run, v_path, 'fred@ayache.com');
    ok_happy := true;
  EXCEPTION WHEN others THEN ok_happy := false; v_err := SQLERRM;
  END;

  -- 9 does the row satisfy the queue's already-reported test? (i.e. it suppresses the bot)
  v_suppressed := ok_happy AND v_row.dry_run IS NOT TRUE
                  AND (v_row.status='SUCCESS' OR v_row.portal_confirmation IS NOT NULL);

  -- 2 a visit with no code-27 line item
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_bad_noc27,'C', now(), 'manual-x', v_bad_noc27::text||'/manual-x.jpg','a@b.com');
    ok_noc27 := true; EXCEPTION WHEN others THEN ok_noc27 := false; END;

  -- 3 a visit that already has a filing
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_dup,'C', now(), 'manual-y', v_dup::text||'/manual-y.jpg','a@b.com');
    ok_dup := true; EXCEPTION WHEN others THEN ok_dup := false; END;

  -- 4 run_id without the manual- prefix
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_ok,'C', now(), 'botrun-123', v_ok::text||'/botrun-123.jpg','a@b.com');
    ok_runid := true; EXCEPTION WHEN others THEN ok_runid := false; END;

  -- 5 screenshot path pointing at a DIFFERENT visit
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_ok,'C', now(), 'manual-z', '999999/manual-z.jpg','a@b.com');
    ok_path := true; EXCEPTION WHEN others THEN ok_path := false; END;

  -- 6 no confirmation number
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_ok,'   ', now(), 'manual-w', v_ok::text||'/manual-w.jpg','a@b.com');
    ok_noconf := true; EXCEPTION WHEN others THEN ok_noconf := false; END;

  -- 7 a filing date in the future
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_ok,'C', now() + interval '30 days', 'manual-v', v_ok::text||'/manual-v.jpg','a@b.com');
    ok_future := true; EXCEPTION WHEN others THEN ok_future := false; END;

  RAISE NOTICE '1 happy path accepted        : %  (want TRUE)  visit %', ok_happy, v_ok;
  RAISE NOTICE '9 row suppresses the bot     : %  (want TRUE)', v_suppressed;
  RAISE NOTICE '2 no code-27 line item       : %  (want FALSE)', ok_noc27;
  RAISE NOTICE '3 already filed              : %  (want FALSE)', ok_dup;
  RAISE NOTICE '4 run_id without manual-     : %  (want FALSE)', ok_runid;
  RAISE NOTICE '5 path for a different visit : %  (want FALSE)', ok_path;
  RAISE NOTICE '6 blank confirmation         : %  (want FALSE)', ok_noconf;
  RAISE NOTICE '7 future filing date         : %  (want FALSE)', ok_future;

  IF NOT ok_happy    THEN RAISE EXCEPTION 'FAIL: happy path -> %', v_err; END IF;
  IF NOT v_suppressed THEN RAISE EXCEPTION 'FAIL: the row would NOT suppress the bot'; END IF;
  IF ok_noc27        THEN RAISE EXCEPTION 'FAIL: accepted a visit with no code-27 line item'; END IF;
  IF ok_dup          THEN RAISE EXCEPTION 'FAIL: accepted a second filing for the same visit'; END IF;
  IF ok_runid        THEN RAISE EXCEPTION 'FAIL: accepted a non-manual run_id'; END IF;
  IF ok_path         THEN RAISE EXCEPTION 'FAIL: accepted a screenshot path for another visit'; END IF;
  IF ok_noconf       THEN RAISE EXCEPTION 'FAIL: accepted a blank confirmation'; END IF;
  IF ok_future       THEN RAISE EXCEPTION 'FAIL: accepted a future filing date'; END IF;

  RAISE EXCEPTION 'ALL EIGHT PASSED - rolling back, nothing kept';
END $probe$;

-- ---------------------------------------------------------------------------
-- CONTROL: the guard must STILL reject a BOT-shaped live row on a pre-cutoff visit.
-- Without this, "manual rows now work" and "the guard is disabled" look identical.
DO $control$
DECLARE v_pre bigint; bot_allowed bool;
BEGIN
  SELECT v.id INTO v_pre FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_date < public.rpa_launch_cutoff() LIMIT 1;
  BEGIN
    INSERT INTO public.derm_portal_submissions
      (visit_id, run_id, status, dry_run, portal_confirmation, attempted_at, screenshot_path)
    VALUES (v_pre, 'rpa-run-control', 'SUCCESS', false, 'C', now(), v_pre::text||'/rpa-run-control.jpg');
    bot_allowed := true;
  EXCEPTION WHEN others THEN bot_allowed := false; END;
  IF bot_allowed THEN
    RAISE EXCEPTION 'FAIL: the guard now lets a BOT row through on a pre-cutoff visit - it has been disabled, not narrowed';
  END IF;
  RAISE EXCEPTION 'CONTROL PASSED: bot rows still blocked pre-cutoff - rolling back';
END $control$;
