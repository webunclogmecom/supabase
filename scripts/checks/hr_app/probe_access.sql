-- Probe for the HR access rules (2026-10-19_2145 / _2200), the checks of the 2200 VERIFY minus its one-time data checks.
-- Each wrong rule RAISEs its own message (the runner then reports "did not report"); all right = one PASS line.
DO $verify$
DECLARE
  c_fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  c_diego text := json_build_object('sub','cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8','email','contact@unclogme.com','role','authenticated')::text;
  j jsonb; v_ok boolean; v_det text; v_n int;
BEGIN
  -- The office cases assume Office holds neither "Pay rates and bonus settings" nor "Approve site files". Fred set both
  -- Office defaults to yes on 2026-10-23 (HR App), so pin them back here; the run's ROLLBACK undoes it. Pinned on the
  -- GROUP, not on Aaron, because check 6b asserts Aaron holds no own setting.
  UPDATE hr.access_group_defaults SET level = 'no' WHERE grp = 'office' AND app IN ('hr_pay', 'pp_approve');
  -- 3. Fred (admin): everything as before
  PERFORM set_config('request.jwt.claims', c_fred, true);
  j := hr.get_employee_record(40);
  IF NOT (j->'viewer'->>'can_see_pay')::boolean OR NOT (j->'viewer'->>'can_see_bonus')::boolean OR NOT (j->'viewer'->>'can_edit')::boolean
     OR jsonb_array_length(j->'history') = 0 OR NOT (j->'viewer'->>'can_set_payroll_week')::boolean THEN
    RAISE EXCEPTION 'VERIFY 3a: Fred lost something on Michael''s record';
  END IF;
  IF NOT (hr.get_pay_summary()->>'can_see_pay')::boolean THEN RAISE EXCEPTION 'VERIFY 3b: Fred lost pay in the list'; END IF;

  -- 4. Aaron (office): as before
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  j := hr.get_employee_record(40);
  IF (j->'viewer'->>'can_see_pay')::boolean OR NOT (j->'viewer'->>'can_see_bonus')::boolean OR NOT (j->'viewer'->>'can_edit')::boolean
     OR jsonb_array_length(j->'history') = 0 OR j->'rates' IS NOT NULL AND jsonb_typeof(j->'rates') <> 'null' THEN
    RAISE EXCEPTION 'VERIFY 4a: Aaron''s view of Michael changed';
  END IF;
  j := hr.get_pay_summary();
  IF (j->>'can_see_pay')::boolean OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'rows') x WHERE x->>'per_visit_bonus' IS NOT NULL) THEN
    RAISE EXCEPTION 'VERIFY 4b: Aaron''s list changed';
  END IF;
  BEGIN PERFORM hr.set_pay_rates(40, '{"hourly": 20}', (now() AT TIME ZONE 'America/New_York')::date, 'verify'); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det LIKE 'blocker=no_access app=hr_pay%'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 4c: Aaron could set pay (or the refusal was not the switch: %)', v_det; END IF;
  BEGIN PERFORM hr.set_payroll_week(35, 4); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 4d: Aaron could change a payroll week'; END IF;

  -- 5. Fred gives Aaron "Pay rates and bonus settings": Aaron sees pay and can set a week (undone)
  v_ok := false;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    PERFORM hr.set_access(26, NULL, '{"hr_pay":"yes"}', hr.fn_access_version(26));
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    j := hr.get_employee_record(40);
    v_ok := (j->'viewer'->>'can_see_pay')::boolean AND (hr.get_pay_summary()->>'can_see_pay')::boolean
            AND (hr.set_payroll_week(35, 5)->>'noop')::boolean;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 5: the Pay rates switch did not give Aaron pay'; END IF;

  -- 6. Fred lowers Aaron to View and turns off See bonus amounts: no edit, no bonuses (undone)
  v_ok := false;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    PERFORM hr.set_access(26, NULL, '{"hr":"view","hr_bonus":"no"}', hr.fn_access_version(26));
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    j := hr.get_employee_record(40);
    v_ok := NOT (j->'viewer'->>'can_edit')::boolean AND NOT (j->'viewer'->>'can_see_bonus')::boolean
            AND jsonb_array_length(j->'history') = 0
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(hr.get_pay_summary()->'rows') x WHERE x->>'per_visit_bonus' IS NOT NULL);
    BEGIN
      PERFORM hr.update_employee(40, '{"phone":"305 555 0101"}');
      v_ok := false;
    EXCEPTION WHEN insufficient_privilege THEN
      GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_ok AND v_det LIKE 'blocker=no_access app=hr%';
    END;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6: View and See bonus amounts No did not take effect'; END IF;
  IF (SELECT count(*) FROM hr.access_overrides WHERE employee_id = 26) <> 0 THEN RAISE EXCEPTION 'VERIFY 6b: not undone'; END IF;

  -- 7. own settings in the overview
  PERFORM set_config('request.jwt.claims', c_fred, true);
  j := hr.get_access_overview();
  IF (SELECT x->'own'->>'pp_approve' FROM jsonb_array_elements(j->'people') x WHERE (x->>'id')::bigint = 28) IS DISTINCT FROM 'yes' THEN
    RAISE EXCEPTION 'VERIFY 7: the overview does not carry Diego''s own setting';
  END IF;

  -- 8. Diego still approves (his own setting), and the helpers are owner only
  IF NOT ('cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8'::uuid = ANY (public.fn_page_approver_ids())) OR '77d4c343-1e21-44eb-98ce-c221028d028a'::uuid = ANY (public.fn_page_approver_ids()) THEN
    RAISE EXCEPTION 'VERIFY 8a: approvers wrong';
  END IF;
  IF has_function_privilege('authenticated', 'hr.fn_app_mode(text)', 'EXECUTE') OR has_function_privilege('authenticated', 'hr.fn_require_app_or_level(text,text,text[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_page_approver_ids()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 8b: a helper grant is wrong';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'PROBE_RESULT %', '[{"t":"access rules: admin, office, Pay rates switch, View, See bonus amounts, overview, approvers (each a RAISE if wrong)","ok":true}]';
END $verify$;
