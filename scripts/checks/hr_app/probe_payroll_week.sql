-- Probes for each person's payroll week (2026-10-19_2130). Nothing is committed: the block ends by RAISE-ing its results.
-- Run with scripts/checks/hr_app/run.js probe_payroll_week.sql.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; x jsonb; v_msg text; v_det text; v_before numeric; v_after numeric; v_n int;
  c_admin text; c_office text;
BEGIN
  c_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)),'role','authenticated')::text;

  -- 1. every start day gives a 7-day week that starts on that day and holds the date
  SELECT count(*) INTO v_n FROM generate_series(0, 6) s, generate_series(date '2026-01-01', date '2026-01-31', interval '1 day') g(d)
   WHERE NOT (g.d::date - hr.fn_payroll_week_start(g.d::date, s::smallint) BETWEEN 0 AND 6
              AND extract(dow FROM hr.fn_payroll_week_start(g.d::date, s::smallint)) = s);
  r := r || jsonb_build_object('t','1 a week starts on its day and holds the date','ok', v_n = 0, 'bad', v_n);

  -- 2. office cannot change a week; a bad day is refused
  PERFORM set_config('request.jwt.claims', c_office, true);
  BEGIN
    PERFORM hr.set_payroll_week(35, 3);
    r := r || jsonb_build_object('t','2 office cannot change a payroll week','ok', false);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','2 office cannot change a payroll week','ok', v_det LIKE 'blocker=level%' OR v_det LIKE 'blocker=no_access app=hr_pay%', 'msg', v_msg);
  END;
  PERFORM set_config('request.jwt.claims', c_admin, true);
  BEGIN
    PERFORM hr.set_payroll_week(35, 7);
    r := r || jsonb_build_object('t','3 day 7 is refused','ok', false);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
    r := r || jsonb_build_object('t','3 day 7 is refused','ok', v_det LIKE 'blocker=week_day_value%');
  END;

  -- 4. an admin moves Mark to Wednesday weeks: his rows regroup, his total does not move, Activity says so
  j := hr.get_employee_record(35);
  SELECT coalesce(sum((h->>'amount')::numeric), 0) INTO v_before FROM jsonb_array_elements(j->'history') h WHERE (h->>'counts_in_total')::boolean;
  x := hr.set_payroll_week(35, 3);
  j := hr.get_employee_record(35);
  SELECT coalesce(sum((h->>'amount')::numeric), 0) INTO v_after FROM jsonb_array_elements(j->'history') h WHERE (h->>'counts_in_total')::boolean;
  r := r || jsonb_build_object('t','4 the setter answers with the new week','ok', x->>'label' = 'Wed to Tue' AND NOT (x->>'noop')::boolean, 'x', x);
  r := r || jsonb_build_object('t','5 every row moves to a Wednesday week','ok',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE extract(dow FROM (h->>'week_start')::date) <> 3)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'bonus_weeks') w WHERE extract(dow FROM (w->>'week_start')::date) <> 3));
  r := r || jsonb_build_object('t','6 no amount moves','ok', v_before = v_after, 'before', v_before, 'after', v_after);
  r := r || jsonb_build_object('t','7 Activity shows the change','ok', EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a, jsonb_array_elements(a->'changes') c
        WHERE c->>'field' = 'Payroll week' AND c->>'old' = 'Fri to Thu' AND c->>'new' = 'Wed to Tue'));
  x := hr.set_payroll_week(35, 3);
  r := r || jsonb_build_object('t','8 the same day again is a no-op','ok', (x->>'noop')::boolean);
  r := r || jsonb_build_object('t','9 admin sees the right, office does not','ok',
        (j->'viewer'->>'can_set_payroll_week')::boolean
        AND (SELECT NOT (hr_o->'viewer'->>'can_set_payroll_week')::boolean FROM (SELECT set_config('request.jwt.claims', c_office, true)) s,
             LATERAL (SELECT hr.get_employee_record(35) AS hr_o) q));

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
