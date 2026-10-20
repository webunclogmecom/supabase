-- Probes for migration A, run inside the rehearsal transaction (which is rolled back by the final RAISE).
DO $p$
DECLARE
  r jsonb := '[]'::jsonb;
  v_res jsonb; v_msg text; v_det text; v_state text;
  em_admin text; em_office text; em_admin2 text;
  id_admin bigint := 2; id_admin2 bigint := 27; id_office bigint := 42; id_field bigint := 37; id_retired bigint := 41;
  v_label text; v_who text;
BEGIN
  SELECT email INTO em_admin FROM public.employees WHERE id = id_admin;
  SELECT email INTO em_admin2 FROM public.employees WHERE id = id_admin2;
  SELECT email INTO em_office FROM public.employees WHERE id = id_office;

  -- helper pattern: set role + claims, call, catch, reset role
  -- 1 office edits a field person's hire date (allowed), from the HR origin
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower(em_office)), '00000000-0000-0000-0000-000000000001'),'email',em_office,'role','authenticated')::text, true);
    PERFORM set_config('request.headers', '{"origin":"https://hr.unclogme.app"}', true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.update_employee(id_field, '{"hire_date":"2026-07-04"}');
    PERFORM set_config('role', 'none', true);
    SELECT app_source, jwt_claims->>'email' INTO v_label, v_who FROM audit.logs
     WHERE table_name = 'employees' AND record_pk->>'id' = id_field::text ORDER BY id DESC LIMIT 1;
    r := r || jsonb_build_object('t','1 office edits field hire_date','ok', (v_res->>'noop') = 'false' AND v_label = 'hr-app' AND v_who = em_office, 'res', v_res->'changed', 'label', v_label);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','1 office edits field hire_date','ok', false, 'msg', v_msg, 'det', v_det);
  END;

  -- expected refusals: (name, claims email, target, patch, expected blocker)
  DECLARE
    c record;
  BEGIN
    FOR c IN SELECT * FROM (VALUES
      ('2 office changes an admin email', em_office, id_admin, '{"email":"x@unclogme.com"}'::jsonb, 'blocker=rights_row'),
      ('3 office changes own status', em_office, id_office, '{"status":"INACTIVE"}'::jsonb, 'blocker=own_row'),
      ('4 office gives field person the admin email', em_office, id_field, jsonb_build_object('email', upper(em_admin) || ' '), 'blocker=email_taken'),
      ('5 admin makes retired duplicate Active', em_admin, id_retired, '{"status":"ACTIVE"}'::jsonb, 'blocker=no_jobber_link'),
      ('6 rename to an existing name, other case', em_admin, id_field, '{"full_name":"grecia "}'::jsonb, 'blocker=name_taken'),
      ('7 unknown field', em_admin, id_field, '{"access_level":"admin"}'::jsonb, 'blocker=field_not_editable'),
      ('8 bad email', em_admin, id_field, '{"email":"not an email"}'::jsonb, 'blocker=email_format'),
      ('9 non-staff account', 'nobody-hr-probe@unclogme.com', id_field, '{"shift":"night"}'::jsonb, 'blocker=no_employee_row'),
      ('10 no sign-in', NULL, id_field, '{"shift":"night"}'::jsonb, 'blocker=not_signed_in'),
      ('11 admin changes own email', em_admin, id_admin, '{"email":"y@ayache.com"}'::jsonb, 'blocker=own_row'),
      ('12 bad hire date', em_admin, id_field, '{"hire_date":"soon"}'::jsonb, 'blocker=hire_date_format'),
      ('13 bad shift', em_admin, id_field, '{"shift":"evening"}'::jsonb, 'blocker=shift_value')
    ) AS t(name, em, target, patch, want) LOOP
      BEGIN
        IF c.em IS NULL THEN
          PERFORM set_config('request.jwt.claims', '', true);
        ELSE
          PERFORM set_config('request.jwt.claims', json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower(c.em)), '00000000-0000-0000-0000-000000000001'),'email',c.em,'role','authenticated')::text, true);
        END IF;
        PERFORM set_config('role', 'authenticated', true);
        v_res := hr.update_employee(c.target, c.patch);
        PERFORM set_config('role', 'none', true);
        r := r || jsonb_build_object('t', c.name, 'ok', false, 'msg', 'NOT REFUSED', 'res', v_res);
      EXCEPTION WHEN others THEN
        PERFORM set_config('role', 'none', true);
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
        r := r || jsonb_build_object('t', c.name, 'ok', v_det LIKE c.want || '%', 'msg', v_msg, 'det', v_det);
      END;
    END LOOP;
  END;

  -- 14 admin makes office person Inactive and back is refused at Active? (has jobber link -> allowed both ways)
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower(em_admin)), '00000000-0000-0000-0000-000000000001'),'email',em_admin,'role','authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.update_employee(id_field, '{"status":"INACTIVE"}');
    r := r || jsonb_build_object('t','14a admin sets field Inactive','ok', v_res->'impact' ? 'upcoming_visits', 'impact', v_res->'impact');
    v_res := hr.update_employee(id_field, '{"status":"active"}');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','14b admin sets field Active again','ok', v_res->'employee'->>'status' = 'ACTIVE');
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','14 admin inactive/active','ok', false, 'msg', v_msg, 'det', v_det);
  END;

  -- 15 noop
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.update_employee(id_field, jsonb_build_object('full_name', (SELECT full_name FROM public.employees WHERE id = id_field)));
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','15 same name is a no-op','ok', (v_res->>'noop') = 'true');
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    r := r || jsonb_build_object('t','15 noop','ok', false, 'msg', v_msg);
  END;

  -- 16 anon cannot call; 17 authenticated cannot call the gate helpers
  BEGIN
    PERFORM set_config('role', 'anon', true);
    v_res := hr.update_employee(id_field, '{"shift":"day"}');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','16 anon refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    r := r || jsonb_build_object('t','16 anon refused','ok', v_state = '42501', 'state', v_state);
  END;
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM hr.fn_employee_impact(id_field);
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','17 helper not callable','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    r := r || jsonb_build_object('t','17 helper not callable','ok', v_state = '42501', 'state', v_state);
  END;

  -- 18 SQL edit cannot create a duplicate email (index), control for the RPC refusal
  BEGIN
    UPDATE public.employees SET email = upper(em_admin2) WHERE id = id_field;
    r := r || jsonb_build_object('t','18 index blocks duplicate email','ok', false);
  EXCEPTION WHEN unique_violation THEN
    r := r || jsonb_build_object('t','18 index blocks duplicate email','ok', true);
  END;

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
