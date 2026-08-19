-- POST-FIX PROBE. Rolled back. Four assertions, both directions.
DO $probe$
DECLARE v_change int; v_photo bigint; v_visit bigint;
        forged bool; forged_other_role bool; visit_ok bool; svc_ok bool; dangling bool;
BEGIN
  SELECT id INTO v_change FROM public.job_frequency_changes ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_photo  FROM public.photos ORDER BY id DESC LIMIT 1;
  SELECT v.id INTO v_visit FROM public.visits v WHERE v.deleted_at IS NULL ORDER BY v.id DESC LIMIT 1;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

  -- 1. THE FIX: a browser must NOT be able to assert approval proof
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role, caption)
    VALUES (v_photo, 'job_frequency_change', v_change, 'approval_proof', 'forged');
    forged := true;
  EXCEPTION WHEN others THEN forged := false; END;

  -- 2. and not by dodging the role either
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
    VALUES (v_photo, 'job_frequency_change', v_change, 'other');
    forged_other_role := true;
  EXCEPTION WHEN others THEN forged_other_role := false; END;

  -- 3. POSITIVE CONTROL: Admin Review's visit insert must STILL work
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
    VALUES (v_photo, 'visit', v_visit, 'other');
    visit_ok := true;
  EXCEPTION WHEN others THEN visit_ok := false; END;

  RESET ROLE;

  -- 4. POSITIVE CONTROL: the edge function (service_role) must STILL be able to file proof
  SET LOCAL ROLE service_role;
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role, caption)
    VALUES (v_photo, 'job_frequency_change', v_change, 'approval_proof', 'edge fn');
    svc_ok := true;
  EXCEPTION WHEN others THEN svc_ok := false; END;

  -- 5. the extended trigger must reject a nonexistent job_frequency_change target
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
    VALUES (v_photo, 'job_frequency_change', 2147483000, 'approval_proof');
    dangling := true;
  EXCEPTION WHEN others THEN dangling := false; END;
  RESET ROLE;

  RAISE NOTICE '1 browser forges approval_proof : %  (want FALSE)', forged;
  RAISE NOTICE '2 browser forges other role     : %  (want FALSE)', forged_other_role;
  RAISE NOTICE '3 CONTROL admin-review visit    : %  (want TRUE)',  visit_ok;
  RAISE NOTICE '4 CONTROL service_role proof    : %  (want TRUE)',  svc_ok;
  RAISE NOTICE '5 dangling jfc target rejected  : %  (want FALSE)', dangling;

  IF forged            THEN RAISE EXCEPTION 'FAIL: browser can still forge approval_proof'; END IF;
  IF forged_other_role THEN RAISE EXCEPTION 'FAIL: browser can still create job_frequency_change links'; END IF;
  IF NOT visit_ok      THEN RAISE EXCEPTION 'FAIL: BROKE ADMIN REVIEW - authenticated can no longer insert a visit link'; END IF;
  IF NOT svc_ok        THEN RAISE EXCEPTION 'FAIL: BROKE THE EDGE FUNCTION - service_role can no longer file proof'; END IF;
  IF dangling          THEN RAISE EXCEPTION 'FAIL: a link to a nonexistent job_frequency_change was accepted'; END IF;

  RAISE EXCEPTION 'ALL FIVE PASSED - rolling back, nothing kept';
END $probe$;
