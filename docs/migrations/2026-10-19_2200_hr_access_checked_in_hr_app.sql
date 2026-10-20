-- 2026-10-19_2200_hr_access_checked_in_hr_app
-- Fred, 2026-10-19: "go ahead with all recommended" (plan: Building Apps/HR App/docs/specs/2026-10-19-access-privileges-
-- plan.md, phase 1d). The HR App, its two switches and "Approve site files" become CHECKED (hr.access_apps.mode = 'on'):
--   1. hr.get_employee_record / hr.get_pay_summary need View in the HR App; pay rates follow "Pay rates and bonus settings",
--      bonus amounts and the bonus history follow "See bonus amounts"; viewer.can_edit = Edit in the HR App (new
--      viewer.can_see_bonus). hr.update_employee needs Edit. hr.set_pay_rates, hr.set_person_bonus and hr.set_payroll_week
--      follow the Pay rates switch (admin while a row is not checked: hr.fn_require_app_or_level).
--   2. public.fn_page_approver_ids() reads the "Approve site files" setting (all 6 callers follow); app_config.page_approvers
--      is retired (the row is deleted; app_config is audited, so its value stays in audit.logs). page_self_approvers stays.
--   3. hr.get_access_overview's people carry `own` (app -> level) for the "affects N people" counts.
-- Starting values equal today, so nobody gains or loses anything at this release (VERIFY proves it for every person).
-- Bodies copied from the live definitions (md5 guarded). Rollback: 2026-10-19_rollback_hr_access_checked_in_hr_app.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> '0f9d4e1471834ce6ab2240e59f0c0598' OR md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) <> '01dbba83f86476e9d28b1a5a96ec6a82' OR md5(pg_get_functiondef('hr.set_pay_rates(bigint,jsonb,date,text)'::regprocedure)) <> 'c8ca8e043b4f5b9da95ef9440f290208' OR md5(pg_get_functiondef('hr.set_person_bonus(bigint,text,numeric,date,text)'::regprocedure)) <> 'f829e56cc012021671231d07fe740c64' OR md5(pg_get_functiondef('hr.get_pay_summary()'::regprocedure)) <> 'fa50b52be14d314142ef1b689fb08251' OR md5(pg_get_functiondef('hr.set_payroll_week(bigint,integer)'::regprocedure)) <> 'b49b0f29cb957ca7adab7d560dd6673f' OR md5(pg_get_functiondef('hr.get_access_overview()'::regprocedure)) <> '576dd8f906ad786ca9e6cf9a40fdb0df' OR md5(pg_get_functiondef('fn_page_approver_ids()'::regprocedure)) <> '1ce2b08a1c30397886e576fdc6871dae' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;
CREATE TEMP TABLE _appr_before ON COMMIT DROP AS SELECT unnest(public.fn_page_approver_ids()) AS id;
CREATE TEMP TABLE _cfg_before ON COMMIT DROP AS SELECT value FROM public.app_config WHERE key = 'page_approvers';

CREATE FUNCTION hr.fn_app_mode(p_app text) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  select a.mode from hr.access_apps a where a.app = p_app
$function$;

-- The access setting decides once its row is checked; until then, the old group rule.
CREATE FUNCTION hr.fn_require_app_or_level(p_app text, p_level text, p_levels text[]) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
begin
  if hr.fn_app_mode(p_app) = 'on' then perform hr.fn_require_app(p_app, p_level);
  else perform 1 from hr.fn_require_level(p_levels);
  end if;
end $function$;
REVOKE ALL ON FUNCTION hr.fn_app_mode(text), hr.fn_require_app_or_level(text, text, text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean; v_seebonus boolean; v_can_edit boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  -- 2026-10-19_2200: the HR App checks the person's access settings (hr.access_*); pay rates follow "Pay rates and bonus
  -- settings", bonuses "See bonus amounts", editing the HR App level. While a row is not checked, the old group rule stands.
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  v_can_edit := case when hr.fn_app_mode('hr') = 'on' then hr.fn_app_level('hr') = 'edit' else true end;

  v_company := jsonb_build_object(
    'per_visit_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_visit_bonus', v_today) r),
    'per_shift_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_shift_bonus', v_today) r));

  -- 2026-10-19_1200: this person's own bonus amounts (admin and office), with the next scheduled change
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'amount', r.amount,
           'since', p.effective_from,
           'next', (select jsonb_build_object('amount', n.amount, 'effective_from', n.effective_from)
                      from hr.pay_rates n where n.employee_id = p_id and n.kind = k.kind and n.effective_from > v_today
                     order by n.effective_from, n.id desc limit 1)))
    into v_bonus
    from unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
    cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
    left join hr.pay_rates p on p.id = r.rate_id;

  if v_pay then
    select coalesce(jsonb_agg(x order by x->>'kind'), '[]'::jsonb) into v_rates from (
      select jsonb_build_object('kind', k.kind, 'amount', r.amount, 'effective_from', p.effective_from,
                                'reason', p.reason, 'set_by', hr.fn_person_label(p.created_by_email)) x
        from unnest(array['hourly', 'salary_weekly', 'salary_yearly']) k(kind)
        cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
        left join hr.pay_rates p on p.id = r.rate_id
       where r.amount is not null) s;
  end if;

  -- One history list, newest first: rate changes (admin only) and bonuses (admin and office)
  select coalesce(jsonb_agg(h order by (h->>'date') desc, (h->>'sort_at') desc, (h->>'id')::bigint desc), '[]'::jsonb) into v_history from (
    -- 2026-10-19_1815 (Fred): pay rate changes are shown in Activity, never in this history table
    select jsonb_build_object(
      'id', g.id, 'type', case when g.rule = 'reversal' then 'reversal' else g.kind end,
      'date', g.work_date, 'sort_at', g.created_at,
      'title', case when g.rule = 'reversal' then 'Bonus taken back'
                    when g.kind = 'visit_bonus' then 'Visit bonus' else 'Shift bonus' end,
      'amount', g.amount, 'unit', null,
      'detail', concat_ws(' · ',
                  case when g.kind = 'visit_bonus' then concat_ws(' ', c.client_code, c.name) else 'Shift forms of ' || to_char(g.work_date, 'Mon FMDD') end,
                  case when g.crew_size > 1 then 'shared visit, ' || g.crew_size || ' on the crew' end,
                  g.note),
      'by', coalesce(hr.fn_person_label(g.decided_by_email), case when g.rule = 'reversal' then 'System' end),
      'decided_at', g.decided_at,
      'source', 'Admin Review',
      'link', case when g.kind = 'visit_bonus' then '/review/' || g.visit_id
                   else '/review-shift/shift-' || g.employee_id || '-' || to_char(g.work_date, 'YYYY-MM-DD') end,
      'reversed', exists (select 1 from hr.bonus_events r where r.reverses_id = g.id),
      -- 2026-10-19_0215: structured fields (additive; the keys above are unchanged)
      'bonus_kind', g.kind, 'rule', g.rule, 'visit_id', g.visit_id,
      'client_code', c.client_code, 'client_name', c.name,
      'crew_size', g.crew_size,
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name)
                        from hr.bonus_events b2 join public.employees e2 on e2.id = b2.employee_id
                       where g.visit_id is not null and b2.visit_id = g.visit_id and b2.employee_id <> g.employee_id
                         and b2.kind = 'visit_bonus' and b2.reverses_id is null
                         and not exists (select 1 from hr.bonus_events r2 where r2.reverses_id = b2.id)),
      'note', g.note,
      'decided_on', (g.decided_at at time zone 'America/New_York')::date, 'decided_time', to_char(g.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'recorded_on', (g.created_at at time zone 'America/New_York')::date,
      'week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
      'reverses_id', g.reverses_id,
      'reversed_on', (select (r.created_at at time zone 'America/New_York')::date from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1),
      'after_week_ended', case when g.rule = 'reversal'
                               then (g.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                               else (select (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                                       from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1) end,
      'counts_in_total', true,
      'admin_review_url', hr.fn_admin_review_url(g.kind, g.visit_id, g.employee_id, g.work_date),
      -- 2026-10-19_1900 (Fred): every row says its status
      'status', case when g.rule = 'reversal' then 'taken_back' else 'approved' end) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
    -- 2026-10-19_1900 (Fred): the bonuses not recorded in HR, so the table shows every bonus with its status.
    -- Pending: what Admin Review still has to decide (the same scope as hr.fn_pending_bonus), priced at the person's
    -- rate on the work date. Rejected: a decision of "not eligible", $0, with Admin Review's reason. Neither counts in
    -- a total. Ids are negative (visits: -visit_id; shifts: -(1000000 + days since 2020-01-01)) so a row key never
    -- equals a recorded bonus id.
    union all
    select jsonb_build_object(
      'id', -v.id, 'type', 'visit_bonus', 'date', v.visit_date, 'sort_at', v.completed_at,
      'title', 'Visit bonus', 'amount', case when coalesce(v.bonus_status, 'pending') = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', concat_ws(' ', c.client_code, c.name),
      'by', case when v.bonus_status = 'denied' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', case when v.bonus_status = 'denied' then vr.bonus_decided_at end,
      'link', '/review/' || v.id,
      'bonus_kind', 'visit_bonus', 'rule', case when v.bonus_status = 'denied' then 'denied' else 'pending' end,
      'visit_id', v.id, 'client_code', c.client_code, 'client_name', c.name,
      'crew_size', (select count(*) from public.visit_team t2 where t2.visit_id = v.id),
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name) from public.visit_team t2
                        join public.employees e2 on e2.id = t2.employee_id where t2.visit_id = v.id and t2.employee_id <> p_id),
      'note', case when v.bonus_status = 'denied' then vr.bonus_denial_note end,
      'decided_on', case when v.bonus_status = 'denied' then (vr.bonus_decided_at at time zone 'America/New_York')::date end,
      'decided_time', case when v.bonus_status = 'denied' then to_char(vr.bonus_decided_at at time zone 'America/New_York', 'HH24:MI') end,
      'week_start', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('visit_bonus', v.id, p_id, v.visit_date),
      'status', case when v.bonus_status = 'denied' then 'rejected' else 'pending' end)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from public.visits_with_review v
      join public.visit_team t on t.visit_id = v.id and t.employee_id = p_id
      left join public.visit_reviews vr on vr.visit_id = v.id
      left join public.clients c on c.id = v.client_id
      left join lateral hr.fn_rate_on(p_id, 'per_visit_bonus', v.visit_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'visit_reviews' and a.record_pk = jsonb_build_object('visit_id', v.id)
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on v.bonus_status = 'denied'
     where v.visit_status = 'completed' and not public.fn_is_non_customer(v.client_id)
       and ((coalesce(v.bonus_status, 'pending') = 'pending' and v.in_review_scope and v.visit_date <= v_today)
            or v.bonus_status = 'denied')
    union all
    select jsonb_build_object(
      'id', -(1000000 + (x.shift_date - date '2020-01-01')), 'type', 'shift_bonus', 'date', x.shift_date, 'sort_at', x.shift_date::timestamptz,
      'title', 'Shift bonus', 'amount', case when x.status = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', 'Shift forms of ' || to_char(x.shift_date, 'Mon FMDD'),
      'by', case when x.status = 'rejected' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', x.decided_at, 'link', '/review-shift/shift-' || p_id || '-' || to_char(x.shift_date, 'YYYY-MM-DD'),
      'bonus_kind', 'shift_bonus', 'rule', case when x.status = 'rejected' then 'denied' else 'pending' end,
      'visit_id', null, 'client_code', null, 'client_name', null, 'crew_size', null, 'shared_with', null,
      'note', x.note,
      'decided_on', (x.decided_at at time zone 'America/New_York')::date,
      'decided_time', to_char(x.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'week_start', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('shift_bonus', null, p_id, x.shift_date),
      'status', x.status)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from (
        -- pending: the shifts of the last 28 days with both forms and no issue, not decided (as hr.fn_pending_bonus)
        select s.shift_date, 'pending'::text as status, null::timestamptz as decided_at, null::text as note
          from (select i.shift_date from public.inspections i
                 where i.employee_id = p_id and i.shift_date >= v_today - 28 and i.shift_date <= v_today
                 group by i.shift_date
                having bool_or(i.inspection_type = 'PRE') and bool_or(i.inspection_type = 'POST')
                   and not bool_or(coalesce(i.has_issue, false))) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_rate_on(p_id, 'per_shift_bonus', x.shift_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'shift_reviews'
                            and a.record_pk = jsonb_build_object('employee_id', p_id, 'shift_date', to_char(x.shift_date, 'YYYY-MM-DD'))
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on x.status = 'rejected'
  ) s;

  select coalesce(jsonb_agg(w order by w->>'week_start' desc), '[]'::jsonb) into v_weeks from (
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day),
                              'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day)) s;

  select coalesce(jsonb_agg(a order by (a->>'at') desc, (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
    select a from (
    select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', l.operation,
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'),
                     case when l.app_source is null then 'Not recorded'
                          when l.app_source = 'sql' then 'Changed outside the apps'
                          when l.app_source = 'employee-dedup-merge' then 'Duplicate clean-up'
                          when l.app_source = 'hr-app' then 'HR App'
                          when l.app_source = 'admin-review' then 'Admin Review'
                          when l.app_source = 'visit-calendar' then 'Visit Calendar'
                          when l.app_source = 'client-app' then 'Client App'
                          when l.app_source = 'derm-tracker' then 'DERM Tracker'
                          when l.app_source = 'jobber' then 'Jobber sync'
                          else 'Another app' end),
      'app', case l.app_source when 'hr-app' then 'HR App' else null end,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label,
                      -- 2026-10-19_2130: the payroll week is stored as a day number; Activity shows "Thu to Wed"
                      'old', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.old_row->>f.col)::smallint) else l.old_row->>f.col end,
                      'new', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.new_row->>f.col)::smallint) else l.new_row->>f.col end)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Start date'), (7, 'access_level', 'Access'),
                                 (8, 'color_hex', 'Color'), (9, 'payroll_week_start_day', 'Payroll week')) f(ord, col, label)
                   where l.operation = 'INSERT' and l.new_row->>f.col is not null
                      or l.operation = 'UPDATE' and (l.old_row->>f.col) is distinct from (l.new_row->>f.col))) a
      from audit.logs l
     where l.table_name = 'employees' and l.record_pk->>'id' = p_id::text
     order by l.id desc limit 100) s
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE'
  -- 2026-10-19_1815 (Fred): pay rate changes are part of the person's Activity. Bonus amounts for admin and office,
  -- hourly and salary for admin only. The id is negative so it can never equal an audit row id.
  union all
  select jsonb_build_object(
      'id', -p.id, 'at', p.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(p.created_by_email), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(
        jsonb_build_object('field', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                                                when 'salary_yearly' then 'Yearly salary' when 'per_visit_bonus' then 'Visit bonus'
                                                else 'Shift bonus' end,
                           'old', case when p.prev_amount is null then null else to_char(p.prev_amount, 'FM$999,999,990.00') end,
                           'new', coalesce(to_char(p.amount, 'FM$999,999,990.00'), 'Stopped')
                                  || ' from ' || to_char(p.effective_from, 'Mon FMDD, YYYY')),
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))) a
    from (select p0.*, lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount
            from hr.pay_rates p0 where p0.employee_id = p_id) p
   where (p.kind in ('per_visit_bonus', 'per_shift_bonus') and v_seebonus) or v_pay
  -- 2026-10-19_2145: a change to this person's own access settings ("Visit Calendar: Group default -> View")
  union all
  select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', 'ACCESS',
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object(
        'field', coalesce(ap.name, coalesce(l.new_row, l.old_row)->>'app'),
        'old', case when l.operation = 'INSERT' then 'Group default' else hr.fn_access_label(l.old_row->>'level') end,
        'new', case when l.operation = 'DELETE' then 'Group default' else hr.fn_access_label(l.new_row->>'level') end))) a
    from audit.logs l
    left join hr.access_apps ap on ap.app = coalesce(l.new_row, l.old_row)->>'app'
   where l.table_schema = 'hr' and l.table_name = 'access_overrides'
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  ) s2;

  if not v_seebonus then
    v_history := '[]'::jsonb; v_weeks := '[]'::jsonb; v_bonus := null; v_company := null;
  end if;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', v_can_edit, 'can_see_pay', v_pay, 'can_see_bonus', v_seebonus, 'is_self', v_e.id = v_caller,
                                 -- 2026-10-19_2145 (decision 10): access follows the email, so only an admin changes email or status
                                 'can_change_email_status', v_e.id <> v_caller and v_level = 'admin',
                                 -- 2026-10-19_2130: only an admin changes a person's payroll week (hr.set_payroll_week)
                                 'can_set_payroll_week', v_pay),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $function$;

CREATE OR REPLACE FUNCTION hr.update_employee(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text;
  v_row public.employees; v_new public.employees;
  v_bad text[]; v_changed text[] := '{}'; v_txt text; v_other text; v_date date;
  v_today date := (now() at time zone 'America/New_York')::date;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  perform hr.fn_require_app('hr', 'edit');   -- 2026-10-19_2200

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=patch_shape in hr.update_employee';
  end if;
  select array_agg(k order by k) into v_bad from jsonb_object_keys(p_patch) k
   where k not in ('full_name', 'status', 'shift', 'email', 'phone', 'hire_date');
  if v_bad is not null then
    raise exception 'These fields cannot be changed here: %.', array_to_string(v_bad, ', ')
      using errcode = '22023', detail = 'blocker=field_not_editable in hr.update_employee';
  end if;

  select * into v_row from public.employees where id = p_id for update;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  v_new := v_row;

  if p_patch ? 'full_name' then
    v_txt := btrim(coalesce(p_patch->>'full_name', ''));
    if v_txt = '' then
      raise exception 'The name cannot be empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=name_empty';
    end if;
    if length(v_txt) > 80 then
      raise exception 'The name is too long (80 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=name_long';
    end if;
    select e.full_name into v_other from public.employees e
     where lower(btrim(e.full_name)) = lower(v_txt) and e.id <> p_id limit 1;
    if v_other is not null then
      raise exception 'Another person already has the name "%". Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=name_taken';
    end if;
    v_new.full_name := v_txt;
  end if;

  if p_patch ? 'status' then
    v_txt := upper(btrim(coalesce(p_patch->>'status', '')));
    if v_txt not in ('ACTIVE', 'INACTIVE') then
      raise exception 'Status must be Active or Inactive. Nothing was saved.' using errcode = '22023', detail = 'blocker=status_value';
    end if;
    v_new.status := v_txt;
  end if;

  if p_patch ? 'shift' then
    v_txt := lower(btrim(coalesce(p_patch->>'shift', '')));
    if v_txt = '' then v_new.shift := null;
    elsif v_txt in ('day', 'night') then v_new.shift := v_txt;
    else
      raise exception 'Shift must be Day, Night or empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=shift_value';
    end if;
  end if;

  if p_patch ? 'email' then
    v_txt := lower(btrim(coalesce(p_patch->>'email', '')));
    if v_txt = '' then v_new.email := null;
    else
      if v_txt !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
        raise exception 'That email does not look right. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_format';
      end if;
      select e.full_name into v_other from public.employees e
       where lower(btrim(e.email)) = v_txt and e.id <> p_id limit 1;
      if v_other is not null then
        raise exception 'That email already belongs to %. Nothing was saved.', btrim(v_other)
          using errcode = '23505', detail = 'blocker=email_taken';
      end if;
      v_new.email := v_txt;
    end if;
  end if;

  if p_patch ? 'phone' then
    v_txt := btrim(coalesce(p_patch->>'phone', ''));
    if v_txt = '' then v_new.phone := null;
    else
      if length(v_txt) > 40 then
        raise exception 'The phone number is too long. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_long';
      end if;
      if v_txt !~ '[0-9]' then
        raise exception 'The phone number has no digits. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_format';
      end if;
      v_new.phone := v_txt;
    end if;
  end if;

  if p_patch ? 'hire_date' then
    v_txt := btrim(coalesce(p_patch->>'hire_date', ''));
    if v_txt = '' then v_new.hire_date := null;
    else
      begin
        v_date := v_txt::date;
      exception when others then
        raise exception 'The hire date is not a date. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_format';
      end;
      if v_date < date '1990-01-01' or v_date > v_today + 366 then
        raise exception 'The hire date is out of range. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_range';
      end if;
      v_new.hire_date := v_date;
    end if;
  end if;

  if v_new.full_name is distinct from v_row.full_name then v_changed := array_append(v_changed, 'full_name'); end if;
  if v_new.status    is distinct from v_row.status    then v_changed := array_append(v_changed, 'status'); end if;
  if v_new.shift     is distinct from v_row.shift     then v_changed := array_append(v_changed, 'shift'); end if;
  if v_new.email     is distinct from v_row.email     then v_changed := array_append(v_changed, 'email'); end if;
  if v_new.phone     is distinct from v_row.phone     then v_changed := array_append(v_changed, 'phone'); end if;
  if v_new.hire_date is distinct from v_row.hire_date then v_changed := array_append(v_changed, 'hire_date'); end if;

  if cardinality(v_changed) = 0 then
    return jsonb_build_object('noop', true, 'employee', hr.fn_employee_json(v_row), 'changed', '[]'::jsonb);
  end if;

  -- Rights. Email and status decide who the HR App lets in, so they are guarded.
  if 'email' = any (v_changed) or 'status' = any (v_changed) then
    if p_id = v_caller then
      raise exception 'You cannot change your own email or status. Ask an admin to do it.'
        using errcode = '42501', detail = 'blocker=own_row';
    end if;
    -- 2026-10-19_2145 (Fred, decision 10): access follows the email, so only an admin changes anyone's email or status
    if v_level <> 'admin' then
      raise exception 'Only an admin can change a person''s email or status.'
        using errcode = '42501', detail = 'blocker=rights_row';
    end if;
    perform pg_advisory_xact_lock(hashtext('hr.access'));   -- the same lock as hr.set_access, before the admin count
  end if;
  if v_new.status = 'ACTIVE' and v_row.status is distinct from 'ACTIVE'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type = 'employee' and l.source_system = 'jobber' and l.entity_id = p_id) then
    raise exception 'This person is not linked to their Jobber user, so they cannot be made Active. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=no_jobber_link';
  end if;
  if v_row.access_level = 'admin' and v_row.status = 'ACTIVE' and v_new.status = 'INACTIVE'
     and not exists (select 1 from public.employees e where e.access_level = 'admin' and e.status = 'ACTIVE' and e.id <> p_id) then
    raise exception 'There must always be one active admin. Nothing was saved.' using errcode = '22023', detail = 'blocker=last_admin';
  end if;

  update public.employees
     set full_name = v_new.full_name, status = v_new.status, shift = v_new.shift,
         email = v_new.email, phone = v_new.phone, hire_date = v_new.hire_date
   where id = p_id
  returning * into v_new;

  return jsonb_build_object('noop', false, 'employee', hr.fn_employee_json(v_new),
    'changed', to_jsonb(v_changed), 'impact', hr.fn_employee_impact(p_id));
end $function$;

CREATE OR REPLACE FUNCTION hr.set_pay_rates(p_employee_id bigint, p_rates jsonb, p_effective_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  k text; v_val jsonb; v_amount numeric; v_current numeric; v_max numeric; v_n int := 0; v_bad text[];
begin
  select c.employee_id into v_caller from hr.fn_require_level(array['admin', 'office']) c;
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);   -- 2026-10-19_2200
  if not exists (select 1 from public.employees where id = p_employee_id) then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  if p_rates is null or jsonb_typeof(p_rates) <> 'object' or p_rates = '{}'::jsonb then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=rates_shape';
  end if;
  if p_rates ? 'per_visit_bonus' or p_rates ? 'per_shift_bonus' then
    raise exception 'The visit and shift bonuses are the same for everyone for now (the amounts Admin Review shows), so they cannot be changed per person. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=bonus_rate_company';
  end if;
  select array_agg(x order by x) into v_bad from jsonb_object_keys(p_rates) x where x not in ('hourly', 'salary_weekly', 'salary_yearly');
  if v_bad is not null then
    raise exception 'These pay kinds are not known: %. Nothing was saved.', array_to_string(v_bad, ', ') using errcode = '22023', detail = 'blocker=rate_kind';
  end if;
  if p_effective_from is null or p_effective_from < date '2020-01-01' or p_effective_from > v_today + 366 then
    raise exception 'Pick the date the new pay starts. Nothing was saved.' using errcode = '22023', detail = 'blocker=effective_from';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Write why the pay changes. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_missing';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;

  -- validate everything before writing anything
  for k, v_val in select * from jsonb_each(p_rates) loop
    if jsonb_typeof(v_val) not in ('number', 'null', 'string') then
      raise exception 'The % amount is not a number. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_format';
    end if;
    if jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') <> '' and btrim(v_val #>> '{}') !~ '^[0-9]+([.][0-9]{1,2})?$' then
      raise exception 'The % amount is not a number. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_format';
    end if;
    v_amount := nullif(btrim(v_val #>> '{}'), '')::numeric;
    v_max := case k when 'hourly' then 500 when 'salary_weekly' then 20000 else 1000000 end;
    if v_amount is not null and (v_amount < 0 or v_amount > v_max or v_amount <> round(v_amount, 2)) then
      raise exception 'The % amount is out of range. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_range';
    end if;
  end loop;

  for k, v_val in select * from jsonb_each(p_rates) loop
    v_amount := nullif(btrim(v_val #>> '{}'), '')::numeric;
    select r.amount into v_current from hr.fn_rate_on(p_employee_id, k, p_effective_from) r;
    if v_current is not distinct from v_amount then continue; end if;
    insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
    values (p_employee_id, k, v_amount, p_effective_from, btrim(p_reason), v_email);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('noop', v_n = 0, 'rows_added', v_n);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_person_bonus(p_employee_id bigint, p_kind text, p_amount numeric, p_effective_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: one person's visit or shift bonus. Admins only.
-- 2026-10-19_1815 (Fred): any start date from 2020 on. A past date changes only bonuses still pending: an approved
-- bonus is recorded once in hr.bonus_events with its amount and nothing recalculates it.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  v_current numeric;
begin
  perform 1 from hr.fn_require_level(array['admin', 'office']);
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);   -- 2026-10-19_2200
  if not exists (select 1 from public.employees where id = p_employee_id) then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || coalesce(p_employee_id::text, 'null');
  end if;
  if p_kind not in ('per_visit_bonus', 'per_shift_bonus') then
    raise exception 'Pick the visit bonus or the shift bonus. Nothing was saved.' using errcode = '22023', detail = 'blocker=bonus_kind';
  end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000 or p_amount <> round(p_amount, 2) then
    raise exception 'The amount must be between $0 and $1,000, in cents at most. Nothing was saved.' using errcode = '22023', detail = 'blocker=amount_range';
  end if;
  if p_effective_from is null or p_effective_from < date '2020-01-01' or p_effective_from > v_today + 366 then
    raise exception 'Pick the date the new amount starts (from 2020, and at most a year ahead). Nothing was saved.'
      using errcode = '22023', detail = 'blocker=effective_from';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Write why the bonus changes. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_missing';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;
  select r.amount into v_current from hr.fn_rate_on(p_employee_id, p_kind, p_effective_from) r;
  if v_current is not distinct from p_amount then
    return jsonb_build_object('noop', true);
  end if;
  insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
  values (p_employee_id, p_kind, p_amount, p_effective_from, btrim(p_reason), v_email);
  return jsonb_build_object('noop', false);
end $function$;

CREATE OR REPLACE FUNCTION hr.get_pay_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_level text; v_today date := (now() at time zone 'America/New_York')::date; v_rows jsonb; v_pay boolean; v_seebonus boolean;
begin
  select c.access_level into v_level from hr.fn_require_level(array['admin', 'office']) c;
  -- 2026-10-19_2200: the person's access settings decide
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  if not v_pay then
    -- 2026-10-19_1200: office sees bonus amounts (not pay rates)
    select coalesce(jsonb_agg(jsonb_build_object(
             'employee_id', e.id,
             'per_visit_bonus', case when v_seebonus then (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r) end,
             'per_shift_bonus', case when v_seebonus then (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r) end,
             'pending_bonus', case when v_seebonus then hr.fn_pending_bonus(e.id, v_today) end
           ) order by e.id), '[]'::jsonb) into v_rows
      from public.employees e;
    return jsonb_build_object('can_see_pay', false, 'can_see_bonus', v_seebonus, 'rows', v_rows);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', e.id,
           'hourly', (select r.amount from hr.fn_rate_on(e.id, 'hourly', v_today) r),
           'salary_weekly', (select r.amount from hr.fn_rate_on(e.id, 'salary_weekly', v_today) r),
           'salary_yearly', (select r.amount from hr.fn_rate_on(e.id, 'salary_yearly', v_today) r),
           'per_visit_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r),
           'per_shift_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r),
           'bonus_this_week', (select sum(g.amount) from hr.bonus_events g
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date, e.payroll_week_start_day) = hr.fn_payroll_week_start(v_today, e.payroll_week_start_day)),
           'pending_bonus', hr.fn_pending_bonus(e.id, v_today)
         ) order by e.id), '[]'::jsonb) into v_rows
    from public.employees e;
  return jsonb_build_object('can_see_pay', true, 'can_see_bonus', true, 'rows', v_rows);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_payroll_week(p_employee_id bigint, p_start_day integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_2130 (Fred: each person's payroll week starts on a day an admin picks and runs 7 days). Admins only.
-- It changes how the HR history groups and totals that person's weeks, never an amount.
declare
  v_caller bigint; v_level text; v_old smallint;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);   -- 2026-10-19_2200
  if p_start_day is null or p_start_day < 0 or p_start_day > 6 then
    raise exception 'Pick the day the payroll week starts. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=week_day_value in hr.set_payroll_week';
  end if;
  select e.payroll_week_start_day into v_old from public.employees e where e.id = p_employee_id for update;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  if v_old = p_start_day then
    return jsonb_build_object('employee_id', p_employee_id, 'payroll_week_start_day', p_start_day,
                              'label', hr.fn_week_label(p_start_day::smallint), 'noop', true);
  end if;
  update public.employees set payroll_week_start_day = p_start_day where id = p_employee_id;
  return jsonb_build_object('employee_id', p_employee_id, 'payroll_week_start_day', p_start_day,
                            'label', hr.fn_week_label(p_start_day::smallint), 'previous_label', hr.fn_week_label(v_old), 'noop', false);
end $function$;

CREATE OR REPLACE FUNCTION hr.get_access_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller bigint := hr.fn_require_access_admin();
begin
  return jsonb_build_object(
    'apps', (select jsonb_agg(jsonb_build_object('app', a.app, 'name', a.name, 'parent', a.parent, 'needs', a.needs, 'mode', a.mode, 'on_since', a.on_since) order by a.sort) from hr.access_apps a),
    'defaults', (select jsonb_agg(jsonb_build_object('group', d.grp, 'app', d.app, 'level', d.level) order by d.grp, a.sort)
                   from hr.access_group_defaults d join hr.access_apps a on a.app = d.app),
    'people', (select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name, 'group', coalesce(e.access_level, 'field'),
                       'has_sign_in', hr.fn_has_sign_in(e.email), 'is_self', e.id = v_caller,
                       'custom', (select count(*) from hr.access_overrides o where o.employee_id = e.id),
                       'own', (select coalesce(jsonb_object_agg(o.app, o.level), '{}'::jsonb) from hr.access_overrides o where o.employee_id = e.id)) order by e.full_name)
                 from public.employees e where e.status = 'ACTIVE'),
    'last_change', (select jsonb_build_object('at', l.changed_at, 'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
                            'group', l.new_row->>'grp', 'app', (select a.name from hr.access_apps a where a.app = l.new_row->>'app'),
                            'old', hr.fn_access_label(l.old_row->>'level'), 'new', hr.fn_access_label(l.new_row->>'level'))
                      from audit.logs l
                     where l.table_schema = 'hr' and l.table_name = 'access_group_defaults' and l.operation = 'UPDATE'
                       and (l.old_row->>'level') is distinct from (l.new_row->>'level')
                     order by l.id desc limit 1),
    'version', hr.fn_defaults_version());
end $function$;

CREATE OR REPLACE FUNCTION public.fn_page_approver_ids()
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-19_2200: the people whose "Approve site files" setting counts (HR App access: admins, plus anyone with their
  -- own Yes or an Office/Field default of Yes), by their confirmed sign-in. Replaces app_config.page_approvers.
  select coalesce(array_agg(u.id order by u.id), '{}')
    from public.employees e
    join auth.users u on u.email_confirmed_at is not null and lower(btrim(u.email)) = lower(btrim(e.email))
    cross join lateral hr.fn_effective_access(e.id) f
   where e.status = 'ACTIVE' and f.app = 'pp_approve' and f.level = 'yes'
$function$;

UPDATE hr.access_apps SET mode = 'on', on_since = now() WHERE app IN ('hr', 'hr_pay', 'hr_bonus', 'pp_approve');
DELETE FROM public.app_config WHERE key = 'page_approvers';

-- VERIFY (inside the transaction; any failure rolls the whole migration back)
DO $verify$
DECLARE
  c_fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  c_diego text := json_build_object('sub','cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8','email','contact@unclogme.com','role','authenticated')::text;
  j jsonb; v_ok boolean; v_det text; v_n int;
BEGIN
  -- 1. modes
  IF (SELECT string_agg(app, ',' ORDER BY app) FROM hr.access_apps WHERE mode = 'on') <> 'hr,hr_bonus,hr_pay,pp_approve' THEN
    RAISE EXCEPTION 'VERIFY 1: the checked rows are not the HR App, its two switches and Approve site files';
  END IF;
  -- 2. the approvers are exactly today's; the config row is gone (its value was today's list)
  IF (SELECT array_agg(id ORDER BY id) FROM _appr_before) IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(public.fn_page_approver_ids()) x)
     OR (SELECT count(*) FROM _appr_before) <> 4 OR EXISTS (SELECT 1 FROM public.app_config WHERE key = 'page_approvers') THEN
    RAISE EXCEPTION 'VERIFY 2: the approvers changed, or the old row is still there';
  END IF;
  IF public.fn_page_approver_names() IS NULL OR public.fn_page_approver_names() = 'the page approvers' THEN
    RAISE EXCEPTION 'VERIFY 2b: approver names: %', public.fn_page_approver_names();
  END IF;

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
  RAISE NOTICE 'VERIFY 2200 passed';
END $verify$;

COMMIT;
