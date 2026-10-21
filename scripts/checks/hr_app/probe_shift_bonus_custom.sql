-- Probes for the custom SHIFT bonus (2026-10-21, Fred). Everything is undone: the block ends by RAISE-ing its results.
-- Run with scripts/checks/hr_app/run.js probe_shift_bonus_custom.sql. Fixtures are picked live: a shift in the last 28
-- days with both forms, no issue and no decision; a shift whose form reports an issue; a date with no forms.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; c_admin text; c_office text; v_today date := (now() at time zone 'America/New_York')::date;
  v_ok boolean; v_e bigint; v_d date; v_ie bigint; v_id date; v_normal numeric; v_p0 numeric; v_p1 numeric; v_n0 bigint;
  v_sum numeric; v_key text;
BEGIN
  c_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)),'role','authenticated')::text;

  SELECT i.employee_id, i.shift_date INTO v_e, v_d FROM public.inspections i
   WHERE i.shift_date >= v_today - 28 AND i.shift_date <= v_today AND i.employee_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews sr WHERE sr.employee_id = i.employee_id AND sr.shift_date = i.shift_date)
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = i.employee_id AND g.work_date = i.shift_date)
   GROUP BY 1, 2
  HAVING bool_or(i.inspection_type = 'PRE') AND bool_or(i.inspection_type = 'POST') AND NOT bool_or(coalesce(i.has_issue, false))
   ORDER BY 2 DESC LIMIT 1;
  SELECT i.employee_id, i.shift_date INTO v_ie, v_id FROM public.inspections i
   WHERE i.employee_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews sr WHERE sr.employee_id = i.employee_id AND sr.shift_date = i.shift_date)
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = i.employee_id AND g.work_date = i.shift_date)
   GROUP BY 1, 2
  HAVING bool_or(i.inspection_type = 'PRE') AND bool_or(i.inspection_type = 'POST') AND bool_or(coalesce(i.has_issue, false))
   ORDER BY 2 DESC LIMIT 1;
  v_normal := coalesce((SELECT x.amount FROM hr.fn_rate_on(v_e, 'per_shift_bonus', v_d) x), 0);
  v_key := v_e || '|' || to_char(v_d, 'YYYY-MM-DD');
  r := r || jsonb_build_object('t','0 fixtures found','ok', v_e IS NOT NULL AND v_ie IS NOT NULL AND c_office::jsonb->>'email' IS NOT NULL, 'shift', v_key, 'issue_shift', v_ie || '|' || v_id, 'normal', v_normal);

  -- 1. office without Pay rates and bonus settings cannot set it
  PERFORM set_config('request.jwt.claims', c_office, true);
  v_ok := false; BEGIN PERFORM hr.set_shift_bonus(v_e, v_d, 40, 'probe'); EXCEPTION WHEN others THEN v_ok := SQLSTATE = '42501'; END;
  r := r || jsonb_build_object('t','1 office cannot set a custom shift amount','ok', v_ok);

  PERFORM set_config('request.jwt.claims', c_admin, true);
  -- 2. a date with no forms, or a bad amount, is refused
  v_ok := false; BEGIN PERFORM hr.set_shift_bonus(v_e, date '2019-01-01', 40, 'probe'); EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'That shift has no forms%'; END;
  r := r || jsonb_build_object('t','2 a shift with no forms is refused','ok', v_ok);
  v_ok := false; BEGIN PERFORM hr.set_shift_bonus(v_e, v_d, 1000.01, null); EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'The amount must be%'; END;
  r := r || jsonb_build_object('t','2b out of range is refused','ok', v_ok);

  -- 3. custom amount on a pending shift: pending total, reader, HR history row, Activity
  v_p0 := hr.fn_pending_bonus(v_e, v_today);
  j := hr.set_shift_bonus(v_e, v_d, 40, '  probe: long night  ');
  v_p1 := hr.fn_pending_bonus(v_e, v_today);
  r := r || jsonb_build_object('t','3 the pending total moves by the difference','ok', NOT (j->>'noop')::boolean AND v_p1 - v_p0 = 40 - v_normal, 'p0', v_p0, 'p1', v_p1);
  j := hr.get_review_bonuses(array[]::bigint[], jsonb_build_array(jsonb_build_object('employee_id', v_e, 'shift_date', v_d)))->'shifts_custom'->v_key;
  r := r || jsonb_build_object('t','3b Admin Review reads the custom shift amount, who and why','ok',
        (j->>'amount')::numeric = 40 AND j->>'reason' = 'probe: long night' AND j->>'set_by' IS NOT NULL, 'v', j);
  j := hr.get_employee_record(v_e);
  r := r || jsonb_build_object('t','3c the HR history pending shift row is $40 with the note','ok',
        EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'shift_bonus' AND (h->>'date')::date = v_d
                  AND h->>'status' = 'pending' AND (h->>'amount')::numeric = 40 AND h->>'note' LIKE 'Custom amount for this shift, set by %: probe: long night'));
  r := r || jsonb_build_object('t','3d the person''s Activity says who changed it','ok',
        EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'RATE' AND a->>'app' = 'Admin Review'
                  AND a->'changes'->0->>'field' = 'Shift bonus, ' || to_char(v_d, 'Mon FMDD, YYYY')
                  AND a->'changes'->0->>'new' = '$40.00 for this shift' AND a->'changes'->1->>'new' = 'probe: long night'));
  -- 4. same amount again: no-op
  v_n0 := (SELECT count(*) FROM hr.shift_bonus_overrides);
  j := hr.set_shift_bonus(v_e, v_d, 40, 'again');
  r := r || jsonb_build_object('t','4 the same amount is a no-op','ok', (j->>'noop')::boolean AND (SELECT count(*) FROM hr.shift_bonus_overrides) = v_n0);

  -- 5. approving records $40
  INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at)
  VALUES (v_e, v_d, 'approved', 'approved', now());
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_e AND g.work_date = v_d;
  r := r || jsonb_build_object('t','5 the approved shift is recorded at the custom amount','ok', v_sum = 40
        AND EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_e AND g.work_date = v_d
                      AND g.reverses_id IS NULL AND g.shift_override_id IS NOT NULL AND g.note LIKE 'Custom amount for this shift%'), 'sum', v_sum);
  -- 6. change after recording: taken back and recorded again
  PERFORM hr.set_shift_bonus(v_e, v_d, 25, 'probe change');
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_e AND g.work_date = v_d;
  r := r || jsonb_build_object('t','6 a change after recording nets to the new amount','ok', v_sum = 25, 'sum', v_sum);
  -- 7. the HR checkbox leaves a custom shift alone
  j := hr.set_person_bonus(v_e, 'per_shift_bonus', v_normal + 7, v_d, 'probe hr', true);
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_e AND g.work_date = v_d;
  r := r || jsonb_build_object('t','7 the HR "update approved" box keeps the custom shift','ok', v_sum = 25, 'sum', v_sum, 'v', j);
  -- 8. back to the normal amount (now the HR amount just set)
  PERFORM hr.set_shift_bonus(v_e, v_d, null, null);
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_e AND g.work_date = v_d;
  r := r || jsonb_build_object('t','8 removing it records the normal amount','ok', v_sum = v_normal + 7
        AND NOT (hr.get_review_bonuses(array[]::bigint[], jsonb_build_array(jsonb_build_object('employee_id', v_e, 'shift_date', v_d)))->'shifts_custom' ? v_key), 'sum', v_sum);
  -- 9. the sweep moves nothing
  j := hr.fn_sync_all_bonuses('sweep');
  r := r || jsonb_build_object('t','9 the sweep writes nothing','ok', (j->>'visit_rows')::int = 0 AND (j->>'shift_rows')::int = 0, 'v', j);
  -- 10. a shift whose form reports an issue stays $0 even with a custom amount
  PERFORM hr.set_shift_bonus(v_ie, v_id, 50, 'probe issue');
  INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at)
  VALUES (v_ie, v_id, 'approved', 'approved', now());
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_ie AND g.work_date = v_id;
  r := r || jsonb_build_object('t','10 a forms-issue shift stays $0','ok', v_sum = 0
        AND EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_ie AND g.work_date = v_id AND g.rule = 'forms_issue'), 'sum', v_sum);
  -- 11. append-only and privileges
  v_ok := false; BEGIN UPDATE hr.shift_bonus_overrides SET amount = 1; EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'blocker=append_only%'; END;
  r := r || jsonb_build_object('t','11 custom shift amounts cannot be edited in place','ok', v_ok
        AND NOT has_table_privilege('authenticated', 'hr.shift_bonus_overrides', 'SELECT')
        AND NOT has_function_privilege('authenticated', 'hr.fn_shift_rate_on(bigint,date)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.set_shift_bonus(bigint,date,numeric,text)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'hr.set_shift_bonus(bigint,date,numeric,text)', 'EXECUTE'));
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'PROBE_RESULT %', r;
END $p$;
