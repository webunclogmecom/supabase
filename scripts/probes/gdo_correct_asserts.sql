-- Assertions appended to the migration INSIDE the same transaction, then rolled back.
-- Every one RAISEs on failure. Uses visit 6617 (043-MIL Mila), which has TWO permits:
--   GDO-14117 -> SUCCESS,            run 5c8e6957-06cb-4932-ba79-757c31785734, 08-07 11:52
--   GDO-11024 -> ERROR_LOGIN_FAILED, run e5b43501-1e88-4b9b-a82e-e9f54b910e8e, 08-19 12:15 (NEWEST)
-- The newest row belongs to the OTHER permit, which is exactly what made the old function wrong.

DO $assert$
DECLARE
  V_VISIT   CONSTANT bigint := 6617;
  RUN_OK    CONSTANT text   := '5c8e6957-06cb-4932-ba79-757c31785734';  -- GDO-14117, SUCCESS
  RUN_FAIL  CONSTANT text   := 'e5b43501-1e88-4b9b-a82e-e9f54b910e8e';  -- GDO-11024, newest
  v_before_other text;
  v_after_other  text;
  v_after_target text;
  v_newest_run   text;
  v_cnt          int;
  v_raised       boolean;
BEGIN
  -- (A) CONTROL: the newest live row for this visit must belong to the OTHER permit, or this whole
  --     test proves nothing - it is the recency collision that the migration exists to remove.
  SELECT s.run_id INTO v_newest_run
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = V_VISIT AND s.dry_run IS NOT TRUE
   ORDER BY s.attempted_at DESC NULLS LAST, s.id DESC LIMIT 1;
  IF v_newest_run IS NOT DISTINCT FROM RUN_OK THEN
    RAISE EXCEPTION 'A FAILED (control): the newest row IS the target row, so this fixture cannot detect the bug';
  END IF;
  RAISE NOTICE 'A ok: newest run is % (the OTHER permit), target is %', v_newest_run, RUN_OK;

  -- (B) the 4-arg form corrects the ROW WE NAMED, and leaves the other permit alone
  SELECT s.failure_reason INTO v_before_other
    FROM public.derm_portal_submissions s WHERE s.visit_id=V_VISIT AND s.run_id=RUN_FAIL;

  PERFORM public.fn_correct_gdo_report(V_VISIT, RUN_OK,
            'Submitted - corrected by assertion', NULL);

  SELECT s.portal_confirmation INTO v_after_target
    FROM public.derm_portal_submissions s WHERE s.visit_id=V_VISIT AND s.run_id=RUN_OK;
  SELECT s.failure_reason INTO v_after_other
    FROM public.derm_portal_submissions s WHERE s.visit_id=V_VISIT AND s.run_id=RUN_FAIL;

  IF v_after_target IS DISTINCT FROM 'Submitted - corrected by assertion' THEN
    RAISE EXCEPTION 'B FAILED: the named row was not corrected (got %)', v_after_target;
  END IF;
  IF v_after_other IS DISTINCT FROM v_before_other THEN
    RAISE EXCEPTION 'B FAILED: the OTHER permit changed, % -> %', v_before_other, v_after_other;
  END IF;
  RAISE NOTICE 'B ok: GDO-14117 corrected, GDO-11024 untouched';

  -- (C) MUTATION TEST of assertion B. Reproduce the OLD recency pick and prove B would catch it:
  --     writing "most recent for the visit" must move the OTHER permit's row.
  UPDATE public.derm_portal_submissions s
     SET failure_reason = 'mutation-probe'
   WHERE s.id = (SELECT s2.id FROM public.derm_portal_submissions s2
                  WHERE s2.visit_id=V_VISIT AND s2.dry_run IS NOT TRUE
                  ORDER BY s2.attempted_at DESC NULLS LAST, s2.id DESC LIMIT 1);
  SELECT s.failure_reason INTO v_after_other
    FROM public.derm_portal_submissions s WHERE s.visit_id=V_VISIT AND s.run_id=RUN_FAIL;
  IF v_after_other IS DISTINCT FROM 'mutation-probe' THEN
    RAISE EXCEPTION 'C FAILED: the old recency pick did NOT hit the other permit, so B is not a real test';
  END IF;
  RAISE NOTICE 'C ok: the old recency pick lands on GDO-11024 - B genuinely detects it';

  -- (D) the superseded 3-arg form refuses LOUDLY rather than writing something plausible
  v_raised := false;
  BEGIN
    PERFORM public.fn_correct_gdo_report(V_VISIT, 'should not be stored', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
    IF SQLERRM NOT LIKE '%run id is now required%' THEN
      RAISE EXCEPTION 'D FAILED: 3-arg raised the wrong error: %', SQLERRM;
    END IF;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'D FAILED: the 3-arg overload did NOT raise - it is still writable';
  END IF;
  RAISE NOTICE 'D ok: the 3-arg form is a hard refusal naming its replacement';

  -- (E) a wrong run id is refused, not silently applied to something else
  v_raised := false;
  BEGIN
    PERFORM public.fn_correct_gdo_report(V_VISIT, 'not-a-real-run-id', 'x', NULL);
  EXCEPTION WHEN OTHERS THEN v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'E FAILED: an unknown run id was accepted';
  END IF;
  RAISE NOTICE 'E ok: an unknown run id is refused';

  -- (F) both arities are still callable by `authenticated`
  SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='fn_correct_gdo_report'
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION 'F FAILED: expected 2 executable overloads, found %', v_cnt;
  END IF;
  RAISE NOTICE 'F ok: both arities present and executable by authenticated';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END
$assert$;

SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname='fn_correct_gdo_report')::int AS overloads,
       (SELECT count(*) FROM public.derm_portal_submissions WHERE dry_run IS NOT TRUE)::int AS live_rows;

ROLLBACK;
