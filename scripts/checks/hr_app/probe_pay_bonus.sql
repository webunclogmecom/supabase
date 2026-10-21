DO $p$
DECLARE
  r jsonb := '[]'::jsonb;
  v_res jsonb; v_msg text; v_det text; v_state text; n int; m int; v_num numeric;
  em_admin text; em_office text;
  v_visit bigint; v_crew bigint; v_other bigint; v_semp bigint; v_sdate date; v_iemp bigint; v_idate date;
  v_claims_office text; v_claims_admin text;
BEGIN
  SELECT email INTO em_admin FROM public.employees WHERE id = 2;
  -- office: an active office person on the group defaults (no access settings of their own), picked live
  SELECT email INTO em_office FROM public.employees WHERE id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1);
  v_claims_office := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower(em_office)), '00000000-0000-0000-0000-000000000001'),'email',em_office,'role','authenticated')::text;
  v_claims_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower(em_admin)), '00000000-0000-0000-0000-000000000001'),'email',em_admin,'role','authenticated')::text;

  -- a completed, unreviewed, real-client visit with a one-person crew
  SELECT v.id, min(vt.employee_id) INTO v_visit, v_crew FROM public.visits v
    JOIN public.visit_team vt ON vt.visit_id = v.id
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND NOT public.fn_is_non_customer(v.client_id)
     AND v.visit_date >= current_date - 30
     AND NOT EXISTS (SELECT 1 FROM public.visit_reviews vr WHERE vr.visit_id = v.id AND vr.bonus_status <> 'pending')
   GROUP BY v.id HAVING count(*) = 1 ORDER BY v.id DESC LIMIT 1;
  SELECT id INTO v_other FROM public.employees WHERE status = 'ACTIVE' AND id <> v_crew AND id IN (1, 35, 40) LIMIT 1;

  -- 1 office approves in Admin Review (direct upsert, as the app does) -> one grant, by the trigger, decider = office
  PERFORM set_config('request.jwt.claims', v_claims_office, true);
  PERFORM set_config('request.headers', '{"origin":"https://admin.unclogme.app"}', true);
  PERFORM set_config('role', 'authenticated', true);
  INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, bonus_decided_at)
  VALUES (v_visit, 'approved', 'approved', now())
  ON CONFLICT (visit_id) DO UPDATE SET review_status = excluded.review_status, bonus_status = excluded.bonus_status, bonus_decided_at = excluded.bonus_decided_at;
  PERFORM set_config('role', 'none', true);
  SELECT count(*), max(amount) INTO n, v_num FROM hr.bonus_events WHERE visit_id = v_visit AND rule = 'approved' AND filled_by = 'trigger' AND decided_by_email = em_office AND employee_id = v_crew;
  r := r || jsonb_build_object('t','1 approval grants once via trigger','ok', n = 1 AND v_num = coalesce((SELECT x.amount FROM hr.fn_rate_on(v_crew, 'per_visit_bonus', (SELECT visit_date FROM public.visits WHERE id = v_visit)) x), 0), 'n', n, 'amount', v_num, 'visit', v_visit);

  -- 2 same save again -> nothing new
  PERFORM set_config('role', 'authenticated', true);
  INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, bonus_decided_at)
  VALUES (v_visit, 'approved', 'approved', now())
  ON CONFLICT (visit_id) DO UPDATE SET review_status = excluded.review_status, bonus_status = excluded.bonus_status, bonus_decided_at = excluded.bonus_decided_at;
  PERFORM set_config('role', 'none', true);
  SELECT count(*) INTO n FROM hr.bonus_events WHERE visit_id = v_visit;
  r := r || jsonb_build_object('t','2 re-save adds nothing','ok', n = 1, 'n', n);

  -- 3 a second person added to the crew after approval, then re-save -> still one grant
  INSERT INTO public.visit_team (visit_id, employee_id) VALUES (v_visit, v_other) ON CONFLICT DO NOTHING;
  PERFORM set_config('role', 'authenticated', true);
  UPDATE public.visit_reviews SET quality_flag_note = 'probe' WHERE visit_id = v_visit;
  PERFORM set_config('role', 'none', true);
  SELECT count(*) INTO n FROM hr.bonus_events WHERE visit_id = v_visit;
  r := r || jsonb_build_object('t','3 crew change after approval adds no one','ok', n = 1, 'n', n);

  -- 4 back to pending -> one reversal, net 0
  PERFORM set_config('role', 'authenticated', true);
  UPDATE public.visit_reviews SET bonus_status = 'pending', bonus_decided_at = null WHERE visit_id = v_visit;
  PERFORM set_config('role', 'none', true);
  SELECT count(*), sum(amount) INTO n, v_num FROM hr.bonus_events WHERE visit_id = v_visit;
  r := r || jsonb_build_object('t','4 back to pending reverses','ok', n = 2 AND v_num = 0, 'n', n, 'net', v_num);

  -- 5 approve again -> new grant to the crew now (2 people), net = each person's own amount (per person since 2026-10-19_1200)
  PERFORM set_config('role', 'authenticated', true);
  UPDATE public.visit_reviews SET bonus_status = 'approved', bonus_decided_at = now() WHERE visit_id = v_visit;
  PERFORM set_config('role', 'none', true);
  SELECT count(*), sum(amount) INTO n, v_num FROM hr.bonus_events WHERE visit_id = v_visit;
  r := r || jsonb_build_object('t','5 approve again grants the crew now','ok', n = 4 AND v_num = coalesce((SELECT x.amount FROM hr.fn_rate_on(v_crew, 'per_visit_bonus', (SELECT visit_date FROM public.visits WHERE id = v_visit)) x), 0) + coalesce((SELECT x.amount FROM hr.fn_rate_on(v_other, 'per_visit_bonus', (SELECT visit_date FROM public.visits WHERE id = v_visit)) x), 0), 'n', n, 'net', v_num);

  -- 6 the visit is soft-deleted -> the sweep reverses both
  PERFORM set_config('app.suppress_jobber_push', 'on', true);
  UPDATE public.visits SET deleted_at = now() WHERE id = v_visit;
  v_res := hr.fn_sync_all_bonuses();
  SELECT sum(amount), count(*) FILTER (WHERE filled_by = 'sweep') INTO v_num, n FROM hr.bonus_events WHERE visit_id = v_visit;
  r := r || jsonb_build_object('t','6 sweep reverses a deleted visit','ok', v_num = 0 AND n = 2, 'net', v_num, 'sweep_rows', n);

  -- 7 append-only
  BEGIN
    UPDATE hr.bonus_events SET amount = 99 WHERE visit_id = v_visit;
    r := r || jsonb_build_object('t','7 ledger refuses UPDATE','ok', false);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    r := r || jsonb_build_object('t','7 ledger refuses UPDATE','ok', v_state = '55000');
  END;

  -- 8 a shift with both forms and no issue -> $25; with an issue -> $0 forms_issue
  SELECT i.employee_id, i.shift_date INTO v_semp, v_sdate FROM public.inspections i
   WHERE i.employee_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews s WHERE s.employee_id = i.employee_id AND s.shift_date = i.shift_date)
   GROUP BY i.employee_id, i.shift_date
  HAVING bool_or(i.inspection_type = 'PRE') AND bool_or(i.inspection_type = 'POST') AND NOT bool_or(coalesce(i.has_issue, false))
   ORDER BY i.shift_date DESC LIMIT 1;
  SELECT i.employee_id, i.shift_date INTO v_iemp, v_idate FROM public.inspections i
   WHERE i.employee_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews s WHERE s.employee_id = i.employee_id AND s.shift_date = i.shift_date)
   GROUP BY i.employee_id, i.shift_date
  HAVING bool_or(i.inspection_type = 'PRE') AND bool_or(i.inspection_type = 'POST') AND bool_or(coalesce(i.has_issue, false))
   ORDER BY i.shift_date DESC LIMIT 1;
  PERFORM set_config('role', 'authenticated', true);
  INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at)
  VALUES (v_semp, v_sdate, 'approved', 'approved', now()) ON CONFLICT (employee_id, shift_date) DO UPDATE SET bonus_status = excluded.bonus_status;
  IF v_iemp IS NOT NULL THEN
    INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at)
    VALUES (v_iemp, v_idate, 'approved', 'approved', now()) ON CONFLICT (employee_id, shift_date) DO UPDATE SET bonus_status = excluded.bonus_status;
  END IF;
  PERFORM set_config('role', 'none', true);
  SELECT amount INTO v_num FROM hr.bonus_events WHERE kind = 'shift_bonus' AND employee_id = v_semp AND work_date = v_sdate;
  r := r || jsonb_build_object('t','8a clean shift pays the person''s shift amount','ok', v_num = coalesce((SELECT x.amount FROM hr.fn_rate_on(v_semp, 'per_shift_bonus', v_sdate) x), 0), 'amount', v_num, 'emp', v_semp, 'date', v_sdate);
  IF v_iemp IS NOT NULL THEN
    SELECT amount INTO v_num FROM hr.bonus_events WHERE kind = 'shift_bonus' AND employee_id = v_iemp AND work_date = v_idate AND rule = 'forms_issue';
    r := r || jsonb_build_object('t','8b shift with an issue pays 0','ok', v_num = 0, 'amount', v_num);
  ELSE
    r := r || jsonb_build_object('t','8b shift with an issue pays 0','ok', true, 'note', 'no unreviewed issue shift to test');
  END IF;

  -- 9 authenticated cannot read the ledger or the rates directly
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM count(*) FROM hr.bonus_events;
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','9 no direct read','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    r := r || jsonb_build_object('t','9 no direct read','ok', v_state = '42501');
  END;

  -- 10 record reader: office sees bonuses but no rates; admin sees rates
  PERFORM set_config('request.jwt.claims', v_claims_office, true);
  PERFORM set_config('role', 'authenticated', true);
  v_res := hr.get_employee_record(40);
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','10a office record: bonuses, no rates','ok',
        (v_res->'viewer'->>'can_see_pay') = 'false' AND jsonb_typeof(v_res->'rates') = 'null'
        AND jsonb_array_length(v_res->'history') > 0
        AND NOT exists (SELECT 1 FROM jsonb_array_elements(v_res->'history') h WHERE h->>'type' = 'rate_change'),
        'history_n', jsonb_array_length(v_res->'history'), 'weeks', v_res->'bonus_weeks'->0, 'first', v_res->'history'->0);

  -- 11 rates: office refused, admin sets hourly, bonus kind refused
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.set_pay_rates(40, '{"hourly": 20}', (now() AT TIME ZONE 'America/New_York')::date, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','11a office cannot set pay','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL, v_msg = MESSAGE_TEXT;
    r := r || jsonb_build_object('t','11a office cannot set pay','ok', v_det LIKE 'blocker=level%' OR v_det LIKE 'blocker=no_access app=hr_pay%', 'msg', v_msg);
  END;
  PERFORM set_config('request.jwt.claims', v_claims_admin, true);
  PERFORM set_config('role', 'authenticated', true);
  v_res := hr.set_pay_rates(40, '{"hourly": "21.50", "salary_weekly": null}', (now() AT TIME ZONE 'America/New_York')::date, 'probe raise');
  v_res := hr.get_employee_record(40);
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','11b admin sets hourly and sees it','ok',
        (v_res->'viewer'->>'can_see_pay') = 'true' AND (v_res->'rates'->0->>'amount')::numeric = 21.50
        AND exists (SELECT 1 FROM jsonb_array_elements(v_res->'activity') a WHERE a->>'operation' = 'RATE' AND a->'changes'->0->>'field' = 'Hourly rate'),
        'rates', v_res->'rates');
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.set_pay_rates(40, '{"per_visit_bonus": 12}', (now() AT TIME ZONE 'America/New_York')::date, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','11c bonus amount per person refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','11c bonus amount per person refused','ok', v_det = 'blocker=bonus_rate_company');
  END;
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    v_res := hr.set_pay_rates(40, '{"hourly": "abc"}', (now() AT TIME ZONE 'America/New_York')::date, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','11d bad amount refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','11d bad amount refused','ok', v_det = 'blocker=amount_format');
  END;

  -- 12 pay summary: office gets can_see_pay false, admin gets rows
  PERFORM set_config('role', 'authenticated', true);
  v_res := hr.get_pay_summary();
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','12a admin pay summary','ok', (v_res->>'can_see_pay') = 'true' AND jsonb_array_length(v_res->'rows') = (SELECT count(*) FROM public.employees));
  PERFORM set_config('request.jwt.claims', v_claims_office, true);
  PERFORM set_config('role', 'authenticated', true);
  v_res := hr.get_pay_summary();
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','12b office sees bonus amounts, never pay','ok', (v_res->>'can_see_pay') = 'false' AND jsonb_array_length(v_res->'rows') > 0
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'rows') x WHERE x ? 'hourly' OR x ? 'salary_weekly' OR x ? 'salary_yearly'));

  -- 13 drift after all this (the soft-deleted visit is handled; the test shift rows are granted)
  SELECT count(*) INTO n FROM hr.v_bonus_drift WHERE problem IN ('missing_grant', 'grant_not_expected');
  r := r || jsonb_build_object('t','13 no drift','ok', n = 0, 'n', n);
  SELECT count(*) INTO n FROM hr.v_bonus_drift WHERE problem = 'shift_forms_issue';
  r := r || jsonb_build_object('t','13b forms issue listed','ok', n >= 1, 'n', n);

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
