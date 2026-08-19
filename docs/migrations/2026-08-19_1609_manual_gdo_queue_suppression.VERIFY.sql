-- Does a MANUAL filing take the visit out of the bot's queue, permanently?
-- Everything rolled back. The positive control is the whole point: we must SEE the visit
-- enter the queue before we can claim our row removed it.
DO $q$
DECLARE
  v_visit bigint; v_manifest bigint; v_run text;
  in_queue_before bool; in_queue_after bool;
  reported_test_after bool; cooldown_only bool;
  v_nolink bigint; nolink_suppressed bool;
BEGIN
  -- a POST-cutoff code-27 visit that has a manifest link and an existing filing
  SELECT s.visit_id INTO v_visit
    FROM public.derm_portal_submissions s
    JOIN public.visits v ON v.id = s.visit_id
   WHERE s.dry_run IS NOT TRUE
     AND v.visit_date >= public.rpa_launch_cutoff()
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)
   LIMIT 1;
  IF v_visit IS NULL THEN RAISE EXCEPTION 'no suitable post-cutoff visit to test with'; END IF;

  SELECT mv.manifest_id INTO v_manifest FROM public.manifest_visits mv WHERE mv.visit_id = v_visit LIMIT 1;

  -- STEP 1: clear its filings so it becomes eligible again (rolled back)
  DELETE FROM public.derm_portal_submissions WHERE visit_id = v_visit;
  -- also clear any lease that would mask the result
  DELETE FROM public.derm_portal_leases l
   WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  WHERE mv.visit_id = l.visit_id AND mv.manifest_id = v_manifest);

  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.manifest_id = v_manifest)
    INTO in_queue_before;

  -- STEP 2: record a MANUAL filing through the real RPC
  v_run := 'manual-queueprobe';
  PERFORM public.fn_record_manual_gdo_report(
            v_visit, 'CONF-QUEUE-PROBE', now() - interval '1 hour',
            v_run, v_visit::text || '/' || v_run || '.jpg', 'fred@ayache.com');

  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.manifest_id = v_manifest)
    INTO in_queue_after;

  -- is it excluded by the PERMANENT already-reported test, or only by the 20h cooldown?
  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest AND NOT s.dry_run
       AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
  ) INTO reported_test_after;

  RAISE NOTICE 'visit % / manifest %', v_visit, v_manifest;
  RAISE NOTICE '1 in queue BEFORE manual filing : %  (want TRUE - the control)', in_queue_before;
  RAISE NOTICE '2 in queue AFTER  manual filing : %  (want FALSE)', in_queue_after;
  RAISE NOTICE '3 excluded by the PERMANENT already-reported test : %  (want TRUE)', reported_test_after;

  IF NOT in_queue_before THEN
    RAISE EXCEPTION 'CONTROL FAILED: the visit never entered the queue, so "it left" would prove nothing';
  END IF;
  IF in_queue_after THEN
    RAISE EXCEPTION 'FAIL: the bot would STILL pick this visit up after a manual filing';
  END IF;
  IF NOT reported_test_after THEN
    RAISE EXCEPTION 'FAIL: suppressed only by the 20h cooldown, which EXPIRES - not permanent';
  END IF;

  RAISE EXCEPTION 'PASSED: manual filing removes it from the queue permanently - rolling back';
END $q$;
