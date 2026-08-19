-- ============================================================================
-- Manual GDO filing - full guard suite.  Everything rolls back; nothing is kept.
--   node scripts/q.js scripts/probes/manual_gdo_filing_guards.sql <out.json>
-- A PASS is reported by RAISE EXCEPTION at the end, which is also what rolls the work back.
--
-- Every negative case is paired with the positive control that must still succeed, because a
-- refusal on its own proves nothing - the call could be dying on a different guard entirely.
-- ============================================================================
DO $suite$
DECLARE
  v_visit bigint; v_pre bigint; v_manifest bigint; v_bucket text;
  v_run text := 'manual-suiteprobe';
  v_path text;
  ok bool; err text; n int := 0;

  PROCEDURE_NOTE text := '';

  -- helper results
  r_happy bool; r_nopath bool; r_badrun bool; r_noconf bool; r_future bool;
  r_wrongvisit bool; r_dupe bool; r_failedok bool; r_nolink bool;
  q_before bool; q_after bool; q_permanent bool;
BEGIN
  -- A post-cutoff, manifest-linked, code-27 visit we can safely reshape inside this transaction.
  SELECT s.visit_id INTO v_visit
    FROM public.derm_portal_submissions s
    JOIN public.visits v ON v.id = s.visit_id
   WHERE s.dry_run IS NOT TRUE
     AND v.visit_date >= public.rpa_launch_cutoff()
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)
   LIMIT 1;
  IF v_visit IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: no post-cutoff linked visit to test with'; END IF;

  SELECT mv.manifest_id INTO v_manifest FROM public.manifest_visits mv WHERE mv.visit_id = v_visit LIMIT 1;
  SELECT id INTO v_bucket FROM storage.buckets WHERE name = 'rpa-evidence';
  v_path := v_visit::text || '/' || v_run || '.jpg';

  DELETE FROM public.derm_portal_submissions WHERE visit_id = v_visit;
  DELETE FROM public.derm_portal_leases l
   WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  WHERE mv.visit_id = l.visit_id AND mv.manifest_id = v_manifest);

  -- ---- 1. evidence must exist BEFORE the row (the upload-first ordering, enforced) -------------
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF',now()-interval '1 hour',v_run,v_path,'fred@ayache.com');
    r_nopath := true;
  EXCEPTION WHEN others THEN r_nopath := false; END;

  INSERT INTO storage.objects (bucket_id, name, metadata)
  VALUES (v_bucket, v_path, '{"mimetype":"image/jpeg","size":123}'::jsonb);

  -- ---- 2. the queue control: it must be IN the queue before we file --------------------------
  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.manifest_id = v_manifest) INTO q_before;

  -- ---- 3. rejected inputs, each with the object now present so only the named rule can fire ---
  BEGIN PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF',now()-interval '1 hour','rpa-notmanual',v_path,'fred@ayache.com');
    r_badrun := true; EXCEPTION WHEN others THEN r_badrun := false; END;
  BEGIN PERFORM public.fn_record_manual_gdo_report(v_visit,'   ',now()-interval '1 hour',v_run,v_path,'fred@ayache.com');
    r_noconf := true; EXCEPTION WHEN others THEN r_noconf := false; END;
  BEGIN PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF',now()+interval '30 days',v_run,v_path,'fred@ayache.com');
    r_future := true; EXCEPTION WHEN others THEN r_future := false; END;
  BEGIN PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF',now()-interval '1 hour',v_run,'999999/'||v_run||'.jpg','fred@ayache.com');
    r_wrongvisit := true; EXCEPTION WHEN others THEN r_wrongvisit := false; END;

  -- ---- 4. the happy path ----------------------------------------------------------------------
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF-OK',now()-interval '1 hour',v_run,v_path,'fred@ayache.com');
    r_happy := true;
  EXCEPTION WHEN others THEN r_happy := false; err := SQLERRM; END;

  -- ---- 5. it must now be OUT of the queue, permanently ----------------------------------------
  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.manifest_id = v_manifest) INTO q_after;
  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest AND NOT s.dry_run
       AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
  ) INTO q_permanent;

  -- ---- 6. a second filing on the same visit must be refused ------------------------------------
  BEGIN PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF2',now()-interval '1 hour',v_run||'b',v_path,'fred@ayache.com');
    r_dupe := true; EXCEPTION WHEN others THEN r_dupe := false; END;

  -- ---- 7. a FAILED bot attempt must NOT block a manual filing ----------------------------------
  DELETE FROM public.derm_portal_submissions WHERE visit_id = v_visit;
  INSERT INTO public.derm_portal_submissions
    (visit_id, run_id, status, dry_run, portal_confirmation, attempted_at, failure_reason, screenshot_missing_reason)
  VALUES (v_visit,'rpa-failed','ERROR_LOGIN_FAILED',false,NULL,now(),'bad permit','NO_SCREENSHOT');
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF-AFTER-FAIL',now()-interval '1 hour',v_run,v_path,'fred@ayache.com');
    r_failedok := true;
  EXCEPTION WHEN others THEN r_failedok := false; err := SQLERRM; END;

  -- ---- 8. a post-cutoff visit with NO manifest link must be refused -----------------------------
  DELETE FROM public.derm_portal_submissions WHERE visit_id = v_visit;
  DELETE FROM public.manifest_visits WHERE visit_id = v_visit;
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_visit,'CONF',now()-interval '1 hour',v_run,v_path,'fred@ayache.com');
    r_nolink := true;
  EXCEPTION WHEN others THEN r_nolink := false; END;

  RAISE NOTICE 'visit % / manifest %', v_visit, v_manifest;
  RAISE NOTICE ' 1 no stored evidence          -> accepted %  (want f)', r_nopath;
  RAISE NOTICE ' 2 in queue BEFORE filing      -> %           (want t, the control)', q_before;
  RAISE NOTICE ' 3 run_id without manual-      -> accepted %  (want f)', r_badrun;
  RAISE NOTICE ' 4 blank confirmation          -> accepted %  (want f)', r_noconf;
  RAISE NOTICE ' 5 future filing date          -> accepted %  (want f)', r_future;
  RAISE NOTICE ' 6 path for another visit      -> accepted %  (want f)', r_wrongvisit;
  RAISE NOTICE ' 7 HAPPY PATH                  -> accepted %  (want t)  [%]', r_happy, coalesce(err,'-');
  RAISE NOTICE ' 8 in queue AFTER filing       -> %           (want f)', q_after;
  RAISE NOTICE ' 9 excluded PERMANENTLY        -> %           (want t)', q_permanent;
  RAISE NOTICE '10 second filing same visit    -> accepted %  (want f)', r_dupe;
  RAISE NOTICE '11 after a FAILED bot attempt  -> accepted %  (want t)', r_failedok;
  RAISE NOTICE '12 post-cutoff, no manifest    -> accepted %  (want f)', r_nolink;

  IF r_nopath     THEN RAISE EXCEPTION 'FAIL 1: a filing with no stored evidence was accepted'; END IF;
  IF NOT q_before THEN RAISE EXCEPTION 'FAIL 2: control - the visit never entered the queue, so leaving it proves nothing'; END IF;
  IF r_badrun     THEN RAISE EXCEPTION 'FAIL 3: a non-manual run_id was accepted'; END IF;
  IF r_noconf     THEN RAISE EXCEPTION 'FAIL 4: a blank confirmation was accepted'; END IF;
  IF r_future     THEN RAISE EXCEPTION 'FAIL 5: a future filing date was accepted'; END IF;
  IF r_wrongvisit THEN RAISE EXCEPTION 'FAIL 6: a screenshot path for another visit was accepted'; END IF;
  IF NOT r_happy  THEN RAISE EXCEPTION 'FAIL 7: the happy path was refused: %', err; END IF;
  IF q_after      THEN RAISE EXCEPTION 'FAIL 8: the bot would still pick this visit up'; END IF;
  IF NOT q_permanent THEN RAISE EXCEPTION 'FAIL 9: suppressed only by the cooldown, which expires'; END IF;
  IF r_dupe       THEN RAISE EXCEPTION 'FAIL 10: a duplicate filing was accepted'; END IF;
  IF NOT r_failedok THEN RAISE EXCEPTION 'FAIL 11: a failed bot attempt still blocks the manual path: %', err; END IF;
  IF r_nolink     THEN RAISE EXCEPTION 'FAIL 12: an unlinked post-cutoff filing was accepted'; END IF;

  RAISE EXCEPTION 'ALL TWELVE PASSED - rolling back, nothing kept';
END $suite$;
