-- Probe for 2026-10-26_1030_access_no_access_signins_stay_closed (Send invite phase 1): a sign-in with no access anywhere stays shut whatever the app modes,
-- D17 refuses View/Edit for a Field person, and the three access-health lines fire on their controls.
-- Makes its own temporary Field person and sign-ins inside the transaction (run.js always rolls back), reports PROBE_RESULT.
-- Before 2026-10-26_1030 the "watch", "off", D17, view_derm_doc and new health line cases FAIL; that is the old-body control.
DO $p1$
DECLARE
  c_fred  text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  c_diego text := json_build_object('sub', 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8', 'email', 'contact@unclogme.com', 'role', 'authenticated')::text;
  v_tag text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  v_emp bigint := 990001;   -- explicit id (OVERRIDING SYSTEM VALUE) so the probe takes no value from the employees sequence
  v_uid uuid := gen_random_uuid(); v_stranger uuid := gen_random_uuid(); v_gmail uuid := gen_random_uuid();
  c_tmp text; c_str text;
  r jsonb := '[]'; v_state text; v_msg text; v_det text; v_note text; v_b boolean; v_j jsonb; v_ver text; v_n bigint; v_items jsonb;
BEGIN
  c_tmp := json_build_object('sub', v_uid, 'email', 'p1-probe-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  c_str := json_build_object('sub', v_stranger, 'email', 'p1-stranger-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  BEGIN   -- every write in this block (the temporary people included) is undone by the raise at its end

  -- case 1: health today: none of the three new lines
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health today: none of the three new lines', 'expect', '0 lines', 'ok', coalesce(v_state is null and (SELECT count(*) FROM jsonb_array_elements(v_items) x WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view')) = 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- the temporary people (undone at the end of the outer block)
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@unclogme.com', '',
          now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false),
         ('00000000-0000-0000-0000-000000000000', v_stranger, 'authenticated', 'authenticated', 'p1-stranger-' || v_tag || '@unclogme.com', '',
          now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
  INSERT INTO public.employees (id, full_name, status, email, access_level, notes) OVERRIDING SYSTEM VALUE
  VALUES (v_emp, 'ZZ P1 Probe ' || v_tag, 'ACTIVE', 'p1-probe-' || v_tag || '@unclogme.com', 'field', 'Temporary row of a rolled-back probe');

  -- case 2: instrument: the temp sign-in is the temp Field person, with no View/Edit anywhere
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      v_note := 'caller ' || coalesce(hr.fn_access_caller()::text, 'null') || ', apps with view/edit '
                || (SELECT count(*) FROM hr.fn_effective_access(v_emp) f WHERE f.parent IS NULL AND f.level IN ('view', 'edit'));
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'instrument: the temp sign-in is the temp Field person, with no View/Edit anywhere', 'expect', 'caller = temp employee, 0 apps', 'ok', coalesce(v_state is null and v_note = 'caller ' || v_emp || ', apps with view/edit 0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 3: gate: temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: temp Field person, every app on', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 4: gate: Fred, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Fred, every app on', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 5: gate: temp Field person, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: temp Field person, stamp_studio in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 6: gate: a confirmed sign-in with no employee row, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_str, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: a confirmed sign-in with no employee row, stamp_studio in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 7: gate: Fred, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Fred, stamp_studio in watch', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 8: gate: Diego, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Diego, stamp_studio in watch', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 9: storage: temp Field person, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: temp Field person, stamp_studio in watch', 'expect', 'fn_storage_open() = false', 'ok', coalesce(v_state is null and v_b = false, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 10: storage: temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: temp Field person, every app on', 'expect', 'fn_storage_open() = false', 'ok', coalesce(v_state is null and v_b = false, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 11: storage: Fred, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: Fred, stamp_studio in watch', 'expect', 'fn_storage_open() = true', 'ok', coalesce(v_state is null and v_b = true, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 12: storage: Diego, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: Diego, stamp_studio in watch', 'expect', 'fn_storage_open() = true', 'ok', coalesce(v_state is null and v_b = true, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 13: check_app_action(preview_derm_email): temp Field person, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, derm_tracker in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 14: check_app_action(preview_derm_email): temp Field person, derm_tracker off
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'off' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, derm_tracker off', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 15: check_app_action(preview_derm_email): temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, every app on', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 16: check_app_action(preview_derm_email): Fred, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Fred, derm_tracker in watch', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 17: check_app_action(preview_derm_email): Diego, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Diego, derm_tracker in watch', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 18: check_app_action(preview_derm_email): Fred, derm_tracker off
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'off' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Fred, derm_tracker off', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 19: check_app_action(view_derm_doc): Fred, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): Fred, every app on (new action)', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 20: check_app_action(view_derm_doc): Diego, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): Diego, every app on (new action)', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 21: check_app_action(view_derm_doc): temp Field person, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): temp Field person, every app on (new action)', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 22: set_access: Fred gives the temp Field person View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"client_app":"view"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives the temp Field person View in client_app', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 23: set_access: Fred gives the temp Field person Edit in admin_review
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"admin_review":"edit"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives the temp Field person Edit in admin_review', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 24: set_access: Fred sets the temp Field person to None in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"client_app":"none"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred sets the temp Field person to None in client_app', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 25: set_access: Fred sets a Yes/No sub-setting for the temp Field person
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"hr_bonus":"yes"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred sets a Yes/No sub-setting for the temp Field person', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 26: set_group_access: Field group default View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_defaults_version();
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_group_access('[{"group":"field","app":"client_app","level":"view"}]'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_group_access: Field group default View in client_app', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 27: set_group_access: Office group default View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_defaults_version();
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_group_access('[{"group":"office","app":"client_app","level":"view"}]'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_group_access: Office group default View in client_app', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 28: set_access: Fred gives Aaron (office) View in client_app, then takes it back
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(26);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(26, null, '{"client_app":"view"}'::jsonb, v_ver);
      RESET ROLE;
      v_ver := hr.fn_access_version(26);
      v_n := (SELECT count(*) FROM hr.access_overrides o WHERE o.employee_id = 26 AND o.app = 'client_app' AND o.level = 'view');
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(26, null, '{"client_app":null}'::jsonb, v_ver);
      RESET ROLE;
      v_note := 'override after save ' || v_n || ', after undo ' || (SELECT count(*) FROM hr.access_overrides o WHERE o.employee_id = 26);
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives Aaron (office) View in client_app, then takes it back', 'expect', 'saved twice, 0 own settings left', 'ok', coalesce(v_state is null and v_note = 'override after save 1, after undo 0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 29: health: an unbanned sign-in at a gmail address is listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
    VALUES ('00000000-0000-0000-0000-000000000000', v_gmail, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@gmail.com', '',
            now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: an unbanned sign-in at a gmail address is listed', 'expect', 'line outside_domain_sign_in for it', 'ok', coalesce(v_state is null and EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x WHERE x->>'issue' = 'outside_domain_sign_in' AND x->>'user_id' = v_gmail::text), false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 30: health: the same gmail sign-in turned off is not listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous, banned_until)
    VALUES ('00000000-0000-0000-0000-000000000000', v_gmail, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@gmail.com', '',
            now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false, now() + interval '100 years');
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: the same gmail sign-in turned off is not listed', 'expect', 'no line', 'ok', coalesce(v_state is null and (SELECT count(*) FROM jsonb_array_elements(v_items) x WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view')) = 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 31: health: a Field person with a sign-in and View in an app is listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO hr.access_overrides (employee_id, app, level, set_by_email) VALUES (v_emp, 'client_app', 'view', 'p1-probe');
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: a Field person with a sign-in and View in an app is listed', 'expect', 'line field_with_view for the temp person', 'ok', coalesce(v_state is null and EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x WHERE x->>'issue' = 'field_with_view' AND (x->>'employee_id')::bigint = v_emp), false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case 32: health: a changed sign-up rule is listed (changed body rolled back at once)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    EXECUTE 'CREATE OR REPLACE FUNCTION public.fn_restrict_signup_domains(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''''
AS $function$
DECLARE
  v_email  text := lower(coalesce(event->''user''->>''email'', ''''));
  v_domain text := substring(v_email from ''@([^@]+)$'');
BEGIN
  -- p1 probe control: a changed body, rolled back at once
  IF v_domain IS NULL OR v_domain NOT IN (''ayache.com'', ''unclogme.com'') THEN
    RETURN jsonb_build_object(
      ''error'', jsonb_build_object(
        ''message'', ''Sign-up is restricted to ayache.com and unclogme.com accounts.'',
        ''http_code'', 403
      )
    );
  END IF;
  RETURN ''{}''::jsonb;  -- allow
END;
$function$
';
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: a changed sign-up rule is listed (changed body rolled back at once)', 'expect', 'line signup_rule_changed', 'ok', coalesce(v_state is null and EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x WHERE x->>'issue' = 'signup_rule_changed'), false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  r := r || jsonb_build_object('t', 'health: the sign-up rule is back to its reviewed fingerprint after the control', 'expect', 'ad0b912c75d4e8f6a5d7ce7c493da6e6',
             'ok', md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)) = 'ad0b912c75d4e8f6a5d7ce7c493da6e6',
             'got', md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)));
    RAISE EXCEPTION 'p1_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_undo' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('p1.results', r::text, true);
END $p1$;
DO $r$ BEGIN RAISE EXCEPTION 'PROBE_RESULT %', current_setting('p1.results'); END $r$;
