-- Probe for 2026-10-27_2130_pp_forms_see_submitted (Trello AIwCYcmn): a Field person with "See submitted forms" reaches
-- exactly /rpc/get_intake and /rpc/list_intake_forms (schema header by method) and the intake photos get_intake shows;
-- every other path, function and bucket stays refused; watch does not widen it; No and mode off shut it; staff unchanged.
-- Makes its own temporary Field person and sign-in (rolled back; run.js always rolls back), reports PROBE_RESULT.
-- Control: with the gate's body before 2026-10-27_2130 the three "gate: ... pass" cases FAIL (they prove the probe reaches
-- the door); before the migration every Forms-only case fails.
DO $pf$
DECLARE
  c_fred  text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  c_diego text := json_build_object('sub', 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8', 'email', 'contact@unclogme.com', 'role', 'authenticated')::text;
  v_tag text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  v_emp bigint := 990002;   -- explicit id (OVERRIDING SYSTEM VALUE): the probe takes no value from the employees sequence
  v_uid uuid := gen_random_uuid();
  c_tmp text;
  v_sub bigint; v_wait bigint; v_cancel bigint; v_exp bigint; v_hidden text[]; v_hidden_n bigint;
  r jsonb := '[]'; v_state text; v_msg text; v_det text; v_note text; v_j jsonb; v_n bigint;
BEGIN
  c_tmp := json_build_object('sub', v_uid, 'email', 'pf-probe-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  -- 112-YA test forms (the sanctioned test client): one submitted, one waiting, one cancelled
  SELECT max(i.id) FILTER (WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL),
         max(i.id) FILTER (WHERE i.submitted_at IS NULL AND i.cancelled_at IS NULL AND i.expires_at > now()),
         max(i.id) FILTER (WHERE i.cancelled_at IS NOT NULL)
    INTO v_sub, v_wait, v_cancel
    FROM public.property_intakes i JOIN public.properties p ON p.id = i.property_id JOIN public.clients c ON c.id = p.client_id
   WHERE c.client_code = '112-YA';
  -- expected intake photos, counted another way: objects in a submitted, not cancelled intake's folder with a live link
  SELECT count(*) INTO v_exp FROM storage.objects o
   WHERE o.bucket_id = 'intake-photos'
     AND split_part(o.name, '/', 1) IN (SELECT i.id::text FROM public.property_intakes i WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL)
     AND EXISTS (SELECT 1 FROM public.photos ph JOIN public.photo_links pl ON pl.photo_id = ph.id
                  WHERE ph.storage_path = o.bucket_id || '/' || o.name AND pl.entity_type = 'property_intake'
                    AND pl.deleted_at IS NULL AND pl.role IS NOT NULL);
  -- folders of waiting or cancelled forms, and how many objects sit in them (the case below needs some to mean anything)
  SELECT array_agg(i.id::text) INTO v_hidden FROM public.property_intakes i WHERE i.submitted_at IS NULL OR i.cancelled_at IS NOT NULL;
  SELECT count(*) INTO v_hidden_n FROM storage.objects o WHERE o.bucket_id = 'intake-photos' AND split_part(o.name, '/', 1) = ANY (v_hidden);
  BEGIN   -- every write in this block (the temporary person included) is undone by the raise at its end
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', 'pf-probe-' || v_tag || '@unclogme.com', '',
          now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
  INSERT INTO public.employees (id, full_name, status, email, access_level, notes) OVERRIDING SYSTEM VALUE
  VALUES (v_emp, 'ZZ PF Probe ' || v_tag, 'ACTIVE', 'pf-probe-' || v_tag || '@unclogme.com', 'field', 'Temporary row of a rolled-back probe');

  -- case: premise: temp Field person has no top-level View, See submitted forms is on, Forms-only by level
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_note := hr.fn_any_app_open(false)::text || ',' || hr.fn_storage_open()::text || ',' || hr.fn_pp_forms_open()::text || ',' || hr.fn_pp_forms_only()::text;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'premise: temp Field person has no top-level View, See submitted forms is on, Forms-only by level', 'expect', 'false,false,true,true', 'ok', coalesce(v_note = 'false,false,true,true', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_intake, Content-Profile client
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_intake, Content-Profile client', 'expect', 'pass', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/list_intake_forms, Content-Profile client
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/list_intake_forms', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/list_intake_forms, Content-Profile client', 'expect', 'pass', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: GET /rpc/get_intake, Accept-Profile client
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"accept-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: GET /rpc/get_intake, Accept-Profile client', 'expect', 'pass', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: GET /v_intake_submissions (the view path stays shut: embedding)
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/v_intake_submissions', true);
      PERFORM set_config('request.headers', '{"accept-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: GET /v_intake_submissions (the view path stays shut: embedding)', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: GET /properties
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/properties', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: GET /properties', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_page_builder
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_page_builder', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_page_builder', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_intake_compare
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake_compare', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_intake_compare', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_intake_link
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake_link', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_intake_link', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_intake with Content-Profile public
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"public"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_intake with Content-Profile public', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: POST /rpc/get_intake with only Accept-Profile client (PostgREST would use public)
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"accept-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: POST /rpc/get_intake with only Accept-Profile client (PostgREST would use public)', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: GET /rpc/get_intake with Content-Profile client and Accept-Profile hr
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"client","accept-profile":"hr"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: GET /rpc/get_intake with Content-Profile client and Accept-Profile hr', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: gate: the refuse-me rehearsal header still refuses on the door path
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"client","x-access-rehearsal":"refuse-me"}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: the refuse-me rehearsal header still refuses on the door path', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: get_intake: a submitted 112-YA form, no accept history
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.get_intake(v_sub);
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'get_intake: a submitted 112-YA form, no accept history', 'expect', 'submitted, accepted [], forms_only', 'ok', coalesce(v_state is null and v_j->>'state' = 'submitted' and v_j->'accepted' = '[]'::jsonb and (v_j->>'forms_only')::boolean and jsonb_array_length(v_j->'sections') > 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: get_intake: a waiting 112-YA form, status and expiry only
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.get_intake(v_wait);
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'get_intake: a waiting 112-YA form, status and expiry only', 'expect', 'awaiting, no sections, no requester', 'ok', coalesce(v_state is null and v_j->>'state' = 'awaiting' and v_j->'sections' = '[]'::jsonb and v_j->'requested_by' = 'null'::jsonb and v_j->>'expires_at' is not null and v_j->'property' is not null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: get_intake: a cancelled 112-YA form is refused
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.get_intake(v_cancel);
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'get_intake: a cancelled 112-YA form is refused', 'expect', 'P0002 not_available', 'ok', coalesce(v_state = 'P0002' and v_det like 'blocker=not_available%', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: list_intake_forms: same rows as staff, waiting rows without requester, no accept counts
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.list_intake_forms();
      PERFORM set_config('request.jwt.claims', c_fred, true);
      v_note := jsonb_array_length(v_j) || '/' || jsonb_array_length(client.list_intake_forms()) || '/'
                || (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x->>'state' = 'awaiting' AND (x ? 'requested_by' OR x ? 'collector')) || '/'
                || (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x ? 'accepted_count') || '/'
                || (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x->>'state' = 'awaiting');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'list_intake_forms: same rows as staff, waiting rows without requester, no accept counts', 'expect', 'n = Fred, 0, 0, waiting > 0', 'ok', coalesce(v_state is null and split_part(v_note, '/', 1)::int > 0 and split_part(v_note, '/', 1) = split_part(v_note, '/', 2) and split_part(v_note, '/', 3) = '0' and split_part(v_note, '/', 4) = '0' and split_part(v_note, '/', 5)::int > 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: get_intake_compare (Property record) refused
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.get_intake_compare(v_sub);
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'get_intake_compare (Property record) refused', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: get_intake_link (collector link) refused
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_note := client.get_intake_link(v_wait)::text;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'get_intake_link (collector link) refused', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: page_builder_list refused
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := to_jsonb(client.page_builder_list());
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'page_builder_list refused', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: watch on Picture Planner does not widen Forms-only
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'picture_planner';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_j := client.list_intake_forms();
      v_note := (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x->>'state' = 'awaiting' AND x ? 'requested_by')::text;
      v_j := client.get_intake(v_cancel);
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'watch on Picture Planner does not widen Forms-only', 'expect', 'waiting rows still bare, cancelled still refused', 'ok', coalesce(v_state = 'P0002' and v_note = '0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: storage: only the photos get_intake shows; nothing in other private buckets or visit photos
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_note := (SELECT count(*) FROM storage.objects WHERE bucket_id = 'intake-photos')::text || ','
                || (SELECT count(*) FROM storage.objects WHERE bucket_id IN ('approval-proof', 'reason-photos', 'employee-photos', 'rpa-evidence'))::text || ','
                || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'GT - Visits Images')::text;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: only the photos get_intake shows; nothing in other private buckets or visit photos', 'expect', 'intake = expected, 0, 0', 'ok', coalesce(v_state is null and v_note = v_exp::text || ',0,0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: storage: no object of a waiting or cancelled form is visible (there are some)
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      v_note := (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = 'intake-photos'
                  AND split_part(o.name, '/', 1) = ANY (v_hidden))::text;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: no object of a waiting or cancelled form is visible (there are some)', 'expect', '0 visible, hidden objects > 0', 'ok', coalesce(v_state is null and v_note = '0' and v_hidden_n > 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: switch set to No for the person: door shut, no photo
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    INSERT INTO hr.access_overrides (employee_id, app, level) VALUES (v_emp, 'pp_forms', 'no');
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      v_note := (SELECT count(*) FROM storage.objects WHERE bucket_id = 'intake-photos')::text;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'switch set to No for the person: door shut, no photo', 'expect', '0 photos then refused', 'ok', coalesce(v_state = '42501' and v_note = '0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: switch row mode off: door shut, no photo (an off switch that gives access reads closed)
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'off' WHERE app = 'pp_forms';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      PERFORM set_config('request.method', 'POST', true);
      PERFORM set_config('request.path', '/rpc/get_intake', true);
      PERFORM set_config('request.headers', '{"content-profile":"client"}', true);
      SET LOCAL ROLE authenticated;
      v_note := (SELECT count(*) FROM storage.objects WHERE bucket_id = 'intake-photos')::text;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'switch row mode off: door shut, no photo (an off switch that gives access reads closed)', 'expect', '0 photos then refused', 'ok', coalesce(v_state = '42501' and v_note = '0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: staff (Fred): gate passes, list keeps the requester on waiting forms
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/properties', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      v_note := (SELECT count(*) FROM jsonb_array_elements(client.list_intake_forms()) x WHERE x->>'state' = 'awaiting' AND x ? 'requested_by')::text;
      v_j := client.get_intake(v_sub);
      IF v_j->'forms_only' <> 'false'::jsonb THEN RAISE EXCEPTION 'staff read as forms_only'; END IF;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'staff (Fred): gate passes, list keeps the requester on waiting forms', 'expect', 'pass, waiting with requester > 0', 'ok', coalesce(v_state is null and v_note::int > 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- case: office (Diego): gate passes and visit photos stay visible
  v_state := null; v_msg := null; v_det := null; v_j := null; v_note := null; v_n := null;
  BEGIN
    
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      PERFORM set_config('request.method', 'GET', true);
      PERFORM set_config('request.path', '/properties', true);
      PERFORM set_config('request.headers', '{}', true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      v_note := (SELECT count(*) FROM storage.objects WHERE bucket_id = 'GT - Visits Images')::text;
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'pf_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'office (Diego): gate passes and visit photos stay visible', 'expect', 'pass, GT photos > 0', 'ok', coalesce(v_state is null and v_note::int > 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
    RAISE EXCEPTION 'pf_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'pf_undo' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('pf.results', r::text, true);
END $pf$;
DO $r$ BEGIN RAISE EXCEPTION 'PROBE_RESULT %', current_setting('pf.results'); END $r$;
