-- Probes for hr.get_bonus_amounts / hr.set_company_bonus (2026-10-18_1410). Ends by RAISE-ing its results, so
-- nothing it does is ever committed. Run with scripts/checks/hr_app/run.js.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; v jsonb; v_det text; v_state text;
  em_admin text; em_office text;
  c_admin text; c_office text; c_nobody text; c_outside text;
  v_next date := (now() at time zone 'America/New_York')::date + 7;
BEGIN
  SELECT email INTO em_admin FROM public.employees WHERE id = 2;
  SELECT email INTO em_office FROM public.employees WHERE id = 42;
  c_admin := json_build_object('sub','00000000-0000-0000-0000-000000000002','email',em_admin,'role','authenticated')::text;
  c_office := json_build_object('sub','00000000-0000-0000-0000-000000000042','email',em_office,'role','authenticated')::text;
  c_nobody := '{"sub":"00000000-0000-0000-0000-000000000009","email":"nobody-hr-probe@unclogme.com","role":"authenticated"}';
  c_outside := '{"sub":"00000000-0000-0000-0000-000000000008","email":"someone@gmail.com","role":"authenticated"}';

  -- 1 a staff sign-in with no employee row can read the amounts (Admin Review must keep working for it)
  PERFORM set_config('request.jwt.claims', c_nobody, true);
  PERFORM set_config('role', 'authenticated', true);
  v := hr.get_bonus_amounts();
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','1 staff reads amounts','ok', (v->'per_visit_bonus'->>'today') IS NOT NULL AND (v->'per_shift_bonus'->>'today') IS NOT NULL, 'v', v);

  -- 2 a non-staff email is refused
  BEGIN
    PERFORM set_config('request.jwt.claims', c_outside, true);
    PERFORM set_config('role', 'authenticated', true);
    v := hr.get_bonus_amounts();
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','2 non-staff refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','2 non-staff refused','ok', v_det LIKE 'blocker=not_staff%');
  END;

  -- 3 anon refused
  BEGIN
    PERFORM set_config('role', 'anon', true);
    v := hr.get_bonus_amounts();
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','3 anon refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    r := r || jsonb_build_object('t','3 anon refused','ok', v_state = '42501');
  END;

  -- 4 office cannot change a company bonus
  BEGIN
    PERFORM set_config('request.jwt.claims', c_office, true);
    PERFORM set_config('role', 'authenticated', true);
    v := hr.set_company_bonus('per_visit_bonus', 12, v_next, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','4 office refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','4 office refused','ok', v_det LIKE 'blocker=level%');
  END;

  -- 5 admin cannot backdate
  BEGIN
    PERFORM set_config('request.jwt.claims', c_admin, true);
    PERFORM set_config('role', 'authenticated', true);
    v := hr.set_company_bonus('per_visit_bonus', 12, v_next - 30, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','5 backdated refused','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','5 backdated refused','ok', v_det = 'blocker=effective_from');
  END;

  -- 6 admin sets $12 from next week: today unchanged, schedule shows it, fn_rate_on agrees on both days
  PERFORM set_config('request.jwt.claims', c_admin, true);
  PERFORM set_config('role', 'authenticated', true);
  v := hr.set_company_bonus('per_visit_bonus', 12, v_next, 'probe raise');
  v := hr.get_bonus_amounts();
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','6 future amount scheduled','ok',
        (v->'per_visit_bonus'->>'today')::numeric = (SELECT amount FROM hr.fn_rate_on(NULL, 'per_visit_bonus', v_next - 7))
        AND (v->'per_visit_bonus'->'schedule'->0->>'amount')::numeric = 12
        AND (v->'per_visit_bonus'->'schedule'->0->>'effective_from')::date = v_next
        AND (SELECT amount FROM hr.fn_rate_on(NULL, 'per_visit_bonus', v_next)) = 12, 'v', v->'per_visit_bonus');

  -- 7 the same amount again is a no-op
  PERFORM set_config('role', 'authenticated', true);
  v := hr.set_company_bonus('per_visit_bonus', 12, v_next, 'probe again');
  PERFORM set_config('role', 'none', true);
  r := r || jsonb_build_object('t','7 same amount is a no-op','ok', (v->>'noop') = 'true');

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
