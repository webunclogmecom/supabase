-- Probes for per-person bonus amounts (2026-10-19_1200). Everything is undone: the block ends by RAISE-ing its results.
-- Run with scripts/checks/hr_app/run.js probe_person_bonus.sql.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; c_admin text; c_office text; v_tomorrow date := (now() at time zone 'America/New_York')::date + 1;
  v_msg text; v_ok boolean;
BEGIN
  c_admin := json_build_object('sub','00000000-0000-0000-0000-000000000002','email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub','00000000-0000-0000-0000-000000000042','email',(select email from public.employees where id = 42),'role','authenticated')::text;

  PERFORM set_config('request.jwt.claims', c_admin, true);
  -- 1. an admin schedules Grecia's own amount: today stays $10, the next change reads $15
  PERFORM hr.set_person_bonus(1, 'per_visit_bonus', 15, v_tomorrow, 'probe');
  j := hr.get_employee_record(1)->'bonus_amounts'->'per_visit_bonus';
  r := r || jsonb_build_object('t','1 a scheduled per-person amount','ok', (j->>'amount')::numeric = 10 AND (j->'next'->>'amount')::numeric = 15, 'v', j);
  -- 2. it is Grecia's only: Michael keeps $10 tomorrow
  r := r || jsonb_build_object('t','2 another person is untouched','ok',
        (select r2.amount from hr.fn_rate_on(40, 'per_visit_bonus', v_tomorrow) r2) = 10 AND (select r2.amount from hr.fn_rate_on(1, 'per_visit_bonus', v_tomorrow) r2) = 15);
  -- 3. the Admin Review reader returns both dated rows for Grecia
  j := hr.get_person_bonus_amounts(array[1, 40]::bigint[]);
  r := r || jsonb_build_object('t','3 Admin Review reader lists the dated rows','ok', jsonb_array_length(j->'1'->'per_visit_bonus') = 2 AND (j->'1'->'per_visit_bonus'->0->>'amount')::numeric = 15);
  -- 4. never backdated
  v_ok := false; BEGIN PERFORM hr.set_person_bonus(1, 'per_shift_bonus', 30, v_tomorrow - 2, 'probe'); EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'The new amount can start today or later%'; END;
  r := r || jsonb_build_object('t','4 a past start date is refused','ok', v_ok);
  -- 5. the company amount functions are gone (2026-10-19_1240)
  r := r || jsonb_build_object('t','5 company amount functions removed','ok',
        to_regprocedure('hr.get_bonus_amounts()') IS NULL AND to_regprocedure('hr.set_company_bonus(text,numeric,date,text)') IS NULL);

  PERFORM set_config('request.jwt.claims', c_office, true);
  -- 6. office cannot change an amount
  v_ok := false; BEGIN PERFORM hr.set_person_bonus(1, 'per_visit_bonus', 20, v_tomorrow, 'probe'); EXCEPTION WHEN others THEN v_ok := true; END;
  r := r || jsonb_build_object('t','6 office cannot set an amount','ok', v_ok);
  -- 7. office sees the amounts, never pay rates
  j := hr.get_pay_summary();
  r := r || jsonb_build_object('t','7 office list has bonus amounts and no pay','ok',
        NOT (j->>'can_see_pay')::boolean AND EXISTS (select 1 from jsonb_array_elements(j->'rows') x where (x->>'employee_id')::bigint = 40 and (x->>'per_visit_bonus')::numeric = 10)
        AND NOT EXISTS (select 1 from jsonb_array_elements(j->'rows') x where x ? 'hourly'));
  j := hr.get_employee_record(40);
  r := r || jsonb_build_object('t','8 office reads the person''s amounts','ok', (j->'bonus_amounts'->'per_shift_bonus'->>'amount')::numeric = 25 AND j->'rates' = 'null'::jsonb);
  PERFORM set_config('request.jwt.claims', '', true);

  -- 9. an active person with no amount earns $0 and reaches the health email
  SET LOCAL session_replication_role = replica;
  UPDATE public.employees SET status = 'ACTIVE' WHERE id = 33;
  SET LOCAL session_replication_role = origin;
  r := r || jsonb_build_object('t','9 no amount of their own reads $0','ok', (select r2.amount from hr.fn_rate_on(33, 'per_visit_bonus', current_date) r2) IS NULL);
  PERFORM public.log_hr_bonus_health();
  r := r || jsonb_build_object('t','10 the health email names them','ok', EXISTS (SELECT 1 FROM ops.v_health_items
           WHERE check_name = 'hr-bonus-health' AND item->>'kind' = 'hr_bonus:no_amount:e33:per_visit_bonus'));

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
