-- Probe for the hr-bonus-health check (2026-10-18_1626). Plants one bad bonus row (no approval, decided by
-- the earner, filled by the sweep) with the guard triggers off, runs the check, and RAISEs the results, so
-- nothing is ever committed. Run with scripts/checks/hr_app/run.js probe_health.sql.
DO $p$
DECLARE r jsonb := '[]'; v_vis bigint; v_emp bigint; v_email text; n int; ks text[];
BEGIN
  n := public.log_hr_bonus_health();
  r := r || jsonb_build_object('t','1 the $0 forms-issue shift never becomes an item','ok',
        not exists (select 1 from ops.v_health_items where check_name = 'hr-bonus-health' and item->>'issue' = 'shift_forms_issue'));
  select v.id, vt.employee_id, lower(btrim(e.email)) into v_vis, v_emp, v_email
    from public.visits v join public.visit_team vt on vt.visit_id = v.id join public.employees e on e.id = vt.employee_id
   where v.visit_status = 'completed' and v.deleted_at is null and e.email is not null
     and not exists (select 1 from public.visit_reviews vr where vr.visit_id = v.id and vr.bonus_status = 'approved')
   order by v.id desc limit 1;
  set local session_replication_role = replica;
  insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, rule, decided_by_email, decided_at, filled_by)
  values ('visit_bonus', v_emp, v_vis, (select visit_date from public.visits where id = v_vis), 10, 'approved', v_email, now(), 'sweep');
  set local session_replication_role = origin;
  n := public.log_hr_bonus_health();
  select array_agg(item->>'issue') into ks from ops.v_health_items where check_name = 'hr-bonus-health';
  r := r || jsonb_build_object('t','2 a planted bad row gives 4 items in the health email','ok',
        ks @> array['grant_not_expected','decider_is_earner','decider_unknown','trigger_missed']
        and (select status from ops.v_health_status where check_name = 'hr-bonus-health') = 'attention', 'issues', ks);
  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
