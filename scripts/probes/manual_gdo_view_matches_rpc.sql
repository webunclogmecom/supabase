-- ============================================================================
-- Does derm.visit_gdo_manual_eligibility.can_record_manual agree with what
-- fn_record_manual_gdo_report ACTUALLY does?  Everything rolls back.
--   node scripts/q.js scripts/probes/manual_gdo_view_matches_rpc.sql <out.json>
--
-- The view exists so the app does not re-derive the rules. That is only worth anything if the two
-- never disagree, so this calls the real function on EVERY completed code-27 visit and compares.
-- A disagreement in either direction is a bug:
--   view says yes / RPC refuses  -> the app offers a form that always fails
--   view says no  / RPC accepts  -> the app hides the feature on a visit that needed it
--
-- Evidence is staged per visit because the RPC requires the storage object to exist; that check is
-- deliberately NOT modelled in the view (the upload happens at submit time, not at render time),
-- so staging it is what isolates the RULES from the ordering.
-- ============================================================================
DO $agree$
DECLARE
  r record; v_run text; v_path text; v_bucket text; v_pick bigint;
  predicted bool; actual bool; err text;
  n int := 0; mismatches int := 0; yes_ok int := 0; no_ok int := 0; multi int := 0;
BEGIN
  SELECT id INTO v_bucket FROM storage.buckets WHERE name = 'rpa-evidence';

  FOR r IN
    SELECT e.visit_id, e.can_record_manual, e.blocked_reason, e.permit_count
      FROM derm.visit_gdo_manual_eligibility e
      JOIN public.visits v ON v.id = e.visit_id
     WHERE v.visit_status = 'completed'   -- has_code27 no longer gates anything (2026-08-19_1915)
     ORDER BY e.visit_id
  LOOP
    n := n + 1;
    predicted := r.can_record_manual;
    IF r.permit_count > 1 THEN multi := multi + 1; END IF;

    v_run  := 'manual-agree' || r.visit_id::text;
    v_path := r.visit_id::text || '/' || v_run || '.jpg';
    INSERT INTO storage.objects (bucket_id, name, metadata)
    VALUES (v_bucket, v_path, '{"mimetype":"image/jpeg","size":1}'::jsonb)
    ON CONFLICT DO NOTHING;

    -- Mirror the UI: when the visit has more than one permit the person is REQUIRED to choose one,
    -- so the probe chooses one too. Passing NULL here would measure the missing-argument error and
    -- report it as an eligibility disagreement, which is the instrument being wrong, not the code.
    v_pick := NULL;
    IF r.permit_count > 1 THEN
      SELECT gdo_id INTO v_pick FROM derm.visit_gdo_our_record
       WHERE visit_id = r.visit_id AND gdo_id IS NOT NULL ORDER BY gdo_id LIMIT 1;
    END IF;

    BEGIN
      PERFORM public.fn_record_manual_gdo_report(
        r.visit_id, now() - interval '1 hour', v_run, v_path, 'fred@ayache.com', v_pick);
      actual := true;
    EXCEPTION WHEN others THEN actual := false; err := SQLERRM; END;

    -- undo the row so the next visit is judged on its own merits
    DELETE FROM public.derm_portal_submissions WHERE visit_id = r.visit_id AND run_id = v_run;

    IF predicted IS DISTINCT FROM actual THEN
      mismatches := mismatches + 1;
      RAISE NOTICE 'MISMATCH visit % | view=% rpc=% | view said: % | rpc said: %',
        r.visit_id, predicted, actual, coalesce(r.blocked_reason,'(eligible)'), coalesce(err,'(accepted)');
    ELSIF predicted THEN yes_ok := yes_ok + 1;
    ELSE no_ok := no_ok + 1;
    END IF;
  END LOOP;

  RAISE NOTICE '---';
  RAISE NOTICE 'code-27 completed visits checked : %', n;
  RAISE NOTICE '  agreed, both YES               : %', yes_ok;
  RAISE NOTICE '  agreed, both NO                : %', no_ok;
  RAISE NOTICE '  of which multi-permit          : %', multi;
  RAISE NOTICE '  MISMATCHES                     : %', mismatches;

  -- Both controls must be non-zero, or the comparison never exercised one of the branches and a
  -- zero-mismatch result would be an untested instrument rather than an all-clear.
  IF n = 0        THEN RAISE EXCEPTION 'CONTROL FAILED: no visits examined at all'; END IF;
  IF yes_ok = 0   THEN RAISE EXCEPTION 'CONTROL FAILED: not one visit was accepted, so agreement on YES is unproven'; END IF;
  IF no_ok = 0    THEN RAISE EXCEPTION 'CONTROL FAILED: not one visit was refused, so agreement on NO is unproven'; END IF;
  IF multi = 0    THEN RAISE EXCEPTION 'CONTROL FAILED: no multi-permit visit was exercised, so the permit branch is unproven'; END IF;
  IF mismatches>0 THEN RAISE EXCEPTION 'FAIL: % visit(s) where the view and the function disagree', mismatches; END IF;

  RAISE EXCEPTION 'PASSED: view and function agree on all % visits (% yes, % no) - rolling back', n, yes_ok, no_ok;
END $agree$;
