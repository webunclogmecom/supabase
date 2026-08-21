-- ============================================================================
-- The permit-choice rules on fn_record_manual_gdo_report.  Everything rolls back.
--   node scripts/q.js scripts/probes/manual_gdo_permit_choice.sql <out.json>
--
-- ⚠ SIGNATURE: p_confirmation was REMOVED 2026-08-20. Calls here are
--   (visit_id, attempted_at, run_id, screenshot_path, filed_by_email, gdo_id).
-- 44% of eligible visits carry 2-3 GDO permits, so "which permit was this filed under" is a real
-- question and the answer must never be guessed. Each case below is paired with the outcome that
-- proves the rule discriminates rather than just refusing everything.
-- ============================================================================
DO $permit$
DECLARE
  v_multi bigint; v_single bigint; v_none bigint; v_bucket text;
  a_gdo bigint; b_gdo bigint; other_gdo bigint; got_gdo bigint;
  r_noarg bool; r_valid bool; r_foreign bool; r_single bool; r_none bool;
  e1 text; e2 text; e3 text;

  FUNCTION_UNUSED text := '';
BEGIN
  SELECT id INTO v_bucket FROM storage.buckets WHERE name = 'rpa-evidence';

  SELECT r.visit_id INTO v_multi FROM derm.visit_gdo_our_record r
    JOIN derm.visit_gdo_manual_eligibility e ON e.visit_id = r.visit_id AND e.can_record_manual
   GROUP BY r.visit_id HAVING count(DISTINCT r.gdo_id) > 1 LIMIT 1;
  SELECT r.visit_id INTO v_single FROM derm.visit_gdo_our_record r
    JOIN derm.visit_gdo_manual_eligibility e ON e.visit_id = r.visit_id AND e.can_record_manual
   GROUP BY r.visit_id HAVING count(DISTINCT r.gdo_id) = 1 LIMIT 1;
  SELECT e.visit_id INTO v_none FROM derm.visit_gdo_manual_eligibility e
   WHERE e.can_record_manual
     AND NOT EXISTS (SELECT 1 FROM derm.visit_gdo_our_record r WHERE r.visit_id = e.visit_id) LIMIT 1;

  IF v_multi IS NULL OR v_single IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: need both a multi-permit and a single-permit eligible visit';
  END IF;

  SELECT min(gdo_id), max(gdo_id) INTO a_gdo, b_gdo FROM derm.visit_gdo_our_record WHERE visit_id = v_multi;
  SELECT gdo_id INTO other_gdo FROM derm.visit_gdo_our_record
   WHERE visit_id <> v_multi AND gdo_id NOT IN (a_gdo, b_gdo) LIMIT 1;

  -- stage evidence for every path we are about to exercise
  INSERT INTO storage.objects (bucket_id, name, metadata) VALUES
    (v_bucket, v_multi::text ||'/manual-permitprobe.jpg', '{"size":1}'::jsonb),
    (v_bucket, v_single::text||'/manual-permitprobe.jpg', '{"size":1}'::jsonb)
  ON CONFLICT DO NOTHING;
  IF v_none IS NOT NULL THEN
    INSERT INTO storage.objects (bucket_id, name, metadata)
    VALUES (v_bucket, v_none::text||'/manual-permitprobe.jpg', '{"size":1}'::jsonb) ON CONFLICT DO NOTHING;
  END IF;

  -- 1. multi-permit, no permit given -> REFUSED
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_multi,now()-interval '1 h','manual-permitprobe',
              v_multi::text||'/manual-permitprobe.jpg','fred@ayache.com', NULL);
    r_noarg := true;
  EXCEPTION WHEN others THEN r_noarg := false; e1 := SQLERRM; END;

  -- 2. multi-permit, a permit belonging to a DIFFERENT visit -> REFUSED
  IF other_gdo IS NOT NULL THEN
    BEGIN
      PERFORM public.fn_record_manual_gdo_report(v_multi,now()-interval '1 h','manual-permitprobe',
                v_multi::text||'/manual-permitprobe.jpg','fred@ayache.com', other_gdo);
      r_foreign := true;
    EXCEPTION WHEN others THEN r_foreign := false; e2 := SQLERRM; END;
  ELSE r_foreign := false; e2 := '(no foreign permit available to test with)';
  END IF;

  -- 3. multi-permit, one of ITS OWN permits -> ACCEPTED, and stored as the one chosen
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_multi,now()-interval '1 h','manual-permitprobe',
              v_multi::text||'/manual-permitprobe.jpg','fred@ayache.com', b_gdo);
    r_valid := true;
  EXCEPTION WHEN others THEN r_valid := false; e3 := SQLERRM; END;
  SELECT gdo_id INTO got_gdo FROM public.derm_portal_submissions
   WHERE visit_id = v_multi AND run_id = 'manual-permitprobe';
  DELETE FROM public.derm_portal_submissions WHERE visit_id = v_multi AND run_id='manual-permitprobe';

  -- 4. single-permit, no permit given -> ACCEPTED (callers should not have to care)
  BEGIN
    PERFORM public.fn_record_manual_gdo_report(v_single,now()-interval '1 h','manual-permitprobe',
              v_single::text||'/manual-permitprobe.jpg','fred@ayache.com', NULL);
    r_single := true;
  EXCEPTION WHEN others THEN r_single := false; END;

  -- 5. no-permit visit, no permit given -> ACCEPTED with a NULL permit
  IF v_none IS NOT NULL THEN
    BEGIN
      PERFORM public.fn_record_manual_gdo_report(v_none,now()-interval '1 h','manual-permitprobe',
                v_none::text||'/manual-permitprobe.jpg','fred@ayache.com', NULL);
      r_none := true;
    EXCEPTION WHEN others THEN r_none := false; END;
  ELSE r_none := true;
  END IF;

  RAISE NOTICE 'multi-permit visit % (permits % and %), single-permit visit %, no-permit visit %',
    v_multi, a_gdo, b_gdo, v_single, coalesce(v_none::text,'(none exist)');
  RAISE NOTICE '1 multi, no permit given   -> accepted %  (want f)  [%]', r_noarg, coalesce(e1,'-');
  RAISE NOTICE '2 multi, ANOTHER visit''s   -> accepted %  (want f)  [%]', r_foreign, coalesce(e2,'-');
  RAISE NOTICE '3 multi, its own permit    -> accepted %  (want t)  [%]', r_valid, coalesce(e3,'-');
  RAISE NOTICE '  ... and stored gdo_id    -> %  (want %)', got_gdo, b_gdo;
  RAISE NOTICE '4 single, no permit given  -> accepted %  (want t)', r_single;
  RAISE NOTICE '5 no permits at all        -> accepted %  (want t)', r_none;

  IF r_noarg   THEN RAISE EXCEPTION 'FAIL 1: a multi-permit visit was filed without saying which permit'; END IF;
  IF r_foreign THEN RAISE EXCEPTION 'FAIL 2: a permit from another visit was accepted'; END IF;
  IF NOT r_valid THEN RAISE EXCEPTION 'FAIL 3: a valid permit was refused: %', e3; END IF;
  IF got_gdo IS DISTINCT FROM b_gdo THEN
    RAISE EXCEPTION 'FAIL 3b: stored permit % is not the one chosen (%) - the guess is still happening', got_gdo, b_gdo;
  END IF;
  IF NOT r_single THEN RAISE EXCEPTION 'FAIL 4: a single-permit visit now needs an explicit permit'; END IF;
  IF NOT r_none   THEN RAISE EXCEPTION 'FAIL 5: a visit with no permit can no longer be recorded'; END IF;

  RAISE EXCEPTION 'ALL FIVE PASSED - the permit is chosen, never guessed - rolling back';
END $permit$;
