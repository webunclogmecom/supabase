-- Probes for hr.get_bonus_amounts (2026-10-18_1410) and the retired hr.set_company_bonus (2026-10-19_1200). Ends by RAISE-ing its results, so
-- nothing it does is ever committed. Run with scripts/checks/hr_app/run.js.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; v jsonb; v_det text; v_state text;
  em_admin text;
  c_admin text; c_nobody text; c_outside text;
  v_next date := (now() at time zone 'America/New_York')::date + 7;
BEGIN
  SELECT email INTO em_admin FROM public.employees WHERE id = 2;
  c_admin := json_build_object('sub','00000000-0000-0000-0000-000000000002','email',em_admin,'role','authenticated')::text;
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

  -- 4 since 2026-10-19_1200 a company amount cannot be set at all, even by an admin: bonuses are per person
  BEGIN
    PERFORM set_config('request.jwt.claims', c_admin, true);
    PERFORM set_config('role', 'authenticated', true);
    v := hr.set_company_bonus('per_visit_bonus', 12, v_next, 'probe');
    PERFORM set_config('role', 'none', true);
    r := r || jsonb_build_object('t','4 company amount retired','ok', false);
  EXCEPTION WHEN others THEN
    PERFORM set_config('role', 'none', true);
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','4 company amount retired','ok', v_det LIKE 'blocker=company_bonus_retired%');
  END;

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
