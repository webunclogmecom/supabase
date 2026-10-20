-- Rollback of 2026-10-19_2130_hr_payroll_week_per_person: the previous bodies (verbatim), the new functions and the column dropped.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $order$ BEGIN
  -- 2026-10-19_2230 (review): roll back in reverse order only
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'f1b101a4c85e3bd1a7300cbc3294a165' THEN
    RAISE EXCEPTION 'hr.get_employee_record is not the body this migration produced; run 2026-10-19_rollback_hr_access_settings.sql first';
  END IF;
END $order$;
CREATE OR REPLACE FUNCTION hr.fn_payroll_week_start(d date)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select d - ((extract(dow from d)::int - 5 + 7) % 7)   -- Friday to Thursday, as Admin Review's payroll week
$function$;

CREATE OR REPLACE FUNCTION hr.fn_employee_json(e employees)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', e.id, 'full_name', e.full_name, 'status', e.status, 'shift', e.shift,
    'email', e.email, 'phone', e.phone, 'hire_date', e.hire_date, 'access_level', e.access_level,
    'color_hex', e.color_hex, 'updated_at', e.updated_at)
$function$;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  v_pay := v_level = 'admin';

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
      'week_start', hr.fn_payroll_week_start(g.work_date), 'week_end', hr.fn_payroll_week_start(g.work_date) + 6,
      'reverses_id', g.reverses_id,
      'reversed_on', (select (r.created_at at time zone 'America/New_York')::date from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1),
      'after_week_ended', case when g.rule = 'reversal'
                               then (g.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date) + 6
                               else (select (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date) + 6
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
      'week_start', hr.fn_payroll_week_start(v.visit_date), 'week_end', hr.fn_payroll_week_start(v.visit_date) + 6,
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
      'week_start', hr.fn_payroll_week_start(x.shift_date), 'week_end', hr.fn_payroll_week_start(x.shift_date) + 6,
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
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date),
                              'week_end', hr.fn_payroll_week_start(g.work_date) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date)) s;

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
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label, 'old', l.old_row->>f.col, 'new', l.new_row->>f.col)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Start date'), (7, 'access_level', 'Access'),
                                 (8, 'color_hex', 'Color')) f(ord, col, label)
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
   where p.kind in ('per_visit_bonus', 'per_shift_bonus') or v_pay
  ) s2;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', true, 'can_see_pay', v_pay, 'is_self', v_e.id = v_caller,
                                 'can_change_email_status', v_e.id <> v_caller and (v_level = 'admin' or coalesce(v_e.access_level, 'field') = 'field')),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $function$;

CREATE OR REPLACE FUNCTION hr.get_pay_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_level text; v_today date := (now() at time zone 'America/New_York')::date; v_rows jsonb;
begin
  select c.access_level into v_level from hr.fn_require_level(array['admin', 'office']) c;
  if v_level <> 'admin' then
    -- 2026-10-19_1200: office sees bonus amounts (not pay rates)
    select coalesce(jsonb_agg(jsonb_build_object(
             'employee_id', e.id,
             'per_visit_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r),
             'per_shift_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r),
             'pending_bonus', hr.fn_pending_bonus(e.id, v_today)
           ) order by e.id), '[]'::jsonb) into v_rows
      from public.employees e;
    return jsonb_build_object('can_see_pay', false, 'rows', v_rows);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', e.id,
           'hourly', (select r.amount from hr.fn_rate_on(e.id, 'hourly', v_today) r),
           'salary_weekly', (select r.amount from hr.fn_rate_on(e.id, 'salary_weekly', v_today) r),
           'salary_yearly', (select r.amount from hr.fn_rate_on(e.id, 'salary_yearly', v_today) r),
           'per_visit_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r),
           'per_shift_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r),
           'bonus_this_week', (select sum(g.amount) from hr.bonus_events g
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date) = hr.fn_payroll_week_start(v_today)),
           'pending_bonus', hr.fn_pending_bonus(e.id, v_today)
         ) order by e.id), '[]'::jsonb) into v_rows
    from public.employees e;
  return jsonb_build_object('can_see_pay', true, 'rows', v_rows);
end $function$;

CREATE OR REPLACE FUNCTION public.log_hr_bonus_health()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  n integer;
  v_items jsonb;
begin
  with d as (
    select dr.problem, dr.kind, dr.visit_id, dr.employee_id, dr.work_date,
           e.full_name as person,
           c.client_code, v.visit_date,
           case dr.kind when 'visit_bonus' then 'visit bonus' else 'shift bonus' end as what,
           case when dr.visit_id is not null
                then format('visit V-%s (%s, %s)', dr.visit_id, coalesce(c.client_code, 'no client'), to_char(v.visit_date, 'Mon FMDD'))
                else format('the shift of %s', to_char(dr.work_date, 'Mon FMDD')) end as where_txt,
           g.decided_by_email
      from hr.v_bonus_drift dr
      left join public.employees e on e.id = dr.employee_id
      left join public.visits v on v.id = dr.visit_id
      left join public.clients c on c.id = v.client_id
      left join lateral (select b.decided_by_email from hr.bonus_events b
                          where b.kind = dr.kind and b.reverses_id is null
                            and b.employee_id is not distinct from dr.employee_id
                            and b.visit_id is not distinct from dr.visit_id
                            and b.work_date is not distinct from dr.work_date
                          order by b.id desc limit 1) g on true
     where dr.problem <> 'shift_forms_issue'
  ),
  f as (
    select jsonb_build_object(
             'kind', 'hr_bonus:' || d.problem || ':' || coalesce('v' || d.visit_id, '') || coalesce(':e' || d.employee_id, '')
                     || coalesce(':' || d.work_date, ''),
             'issue', d.problem,
             'reason', case d.problem
               when 'missing_grant' then format('The %s for %s was approved in Admin Review%s, but the HR pay history has no bonus for it.',
                                                d.what, d.where_txt, coalesce(' for ' || d.person, ''))
               when 'approved_no_crew' then format('The visit bonus for %s was approved in Admin Review, but the visit has no crew, so nobody was paid.', d.where_txt)
               when 'grant_not_expected' then format('%s still has a %s in the HR pay history for %s, but Admin Review does not show it as approved.',
                                                     coalesce(d.person, 'Someone'), d.what, d.where_txt)
               when 'decider_unknown' then format('%s''s %s for %s was approved by %s, who is not an active admin or office account.',
                                                  coalesce(d.person, 'Someone'), d.what, d.where_txt, coalesce(d.decided_by_email, 'an unknown account'))
               when 'decider_is_earner' then format('%s approved their own %s for %s.', coalesce(d.person, 'Someone'), d.what, d.where_txt)
               else format('Bonus problem "%s" on %s.', d.problem, d.where_txt) end,
             'what_to_do', case d.problem
               when 'approved_no_crew' then 'Add the crew to the visit in the Visit Calendar; the bonus is then added within the hour.'
               when 'decider_unknown' then 'Check the decision in Admin Review, and the person''s access level in the HR App.'
               when 'decider_is_earner' then 'Check the decision in Admin Review; someone else should approve it.'
               else 'The hourly repair should have fixed this. Run select hr.fn_sync_all_bonuses(); if it is still listed, the bonus rule is failing for this case.' end,
             'person', d.person, 'client_code', d.client_code) as item
      from d
    union all
    select jsonb_build_object(
             'kind', 'hr_bonus:repaired_by_sweep',
             'issue', 'trigger_missed',
             'reason', format('%s bonus row(s) were added by the hourly repair in the last 26 hours instead of at the moment of approval, so the Admin Review triggers are failing.', s.n),
             'what_to_do', 'Check the Postgres logs for warnings from hr.trg_visit_review_bonus / hr.trg_shift_review_bonus.',
             'count', s.n)
      from (select count(*) as n from hr.bonus_events b
             where b.filled_by = 'sweep' and b.created_at > now() - interval '26 hours') s
     where s.n > 0
    union all
    select jsonb_build_object(
             'kind', 'hr_bonus:sweep_not_running',
             'issue', 'sweep_not_running',
             'reason', 'The hourly bonus repair (cron hr-bonus-sweep) has not succeeded in the last 3 hours, so a bonus the triggers missed would stay missing.',
             'what_to_do', 'Check cron.job_run_details for hr-bonus-sweep.')
     where not exists (select 1 from cron.job_run_details r join cron.job j on j.jobid = r.jobid
                        where j.jobname = 'hr-bonus-sweep' and r.status = 'succeeded'
                          and r.end_time > now() - interval '3 hours')
    union all
    -- 2026-10-19_1200: an active person with no bonus amount of their own earns $0 (Fred: "$0 until set")
    select jsonb_build_object(
             'kind', 'hr_bonus:no_amount:e' || e.id || ':' || k.kind,
             'issue', 'no_amount',
             'reason', format('%s has no %s amount, so every %s Admin Review approves for them pays $0.',
                              e.full_name, case k.kind when 'per_visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              case k.kind when 'per_visit_bonus' then 'visit' else 'shift' end),
             'what_to_do', 'Open them in the HR App and set the amount with Edit on their Pay rates card.',
             'person', e.full_name)
      from public.employees e
      cross join unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
     where e.status = 'ACTIVE'
       and (select r.amount from hr.fn_rate_on(e.id, k.kind, (now() at time zone 'America/New_York')::date) r) is null
    union all
    -- 2026-10-19_0215: the history ceiling (server paging is planned past 800 entries)
    select jsonb_build_object(
             'kind', 'hr_bonus:history_large:e' || x.employee_id,
             'issue', 'history_large',
             'reason', format('%s has %s entries in the pay and bonus history. Past 800 the HR App should page the history in the database instead of the browser.',
                              coalesce(e.full_name, 'Someone'), x.n),
             'what_to_do', 'Build hr.get_pay_history (server paging), as planned in the HR App redesign plan of 2026-10-19.',
             'person', e.full_name, 'count', x.n)
      from (select b.employee_id, count(*) as n from hr.bonus_events b group by b.employee_id having count(*) > 800) x
      left join public.employees e on e.id = x.employee_id
    union all
    -- 2026-10-19_0215: a bonus taken back after its payroll week ended (Fred: keep it in the week of the work, but say so)
    select jsonb_build_object(
             'kind', 'hr_bonus:late_take_back:' || r.id,
             'issue', 'late_take_back',
             'reason', format('A %s of %s for %s (work date %s) was taken back on %s, after its payroll week (Fri %s to Thu %s) ended. If that week was already paid, take it off the next pay.',
                              case r.kind when 'visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              to_char(-r.amount, 'FM$999,990.00'), coalesce(e.full_name, 'someone'),
                              to_char(r.work_date, 'Mon FMDD'), to_char(r.created_at at time zone 'America/New_York', 'Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date), 'Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date) + 6, 'Mon FMDD')),
             'what_to_do', 'Check whether that week was already paid, and adjust the next payroll if it was.',
             'person', e.full_name)
      from hr.bonus_events r
      left join public.employees e on e.id = r.employee_id
     where r.rule = 'reversal' and r.amount < 0 and r.created_at > now() - interval '26 hours'
       and (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(r.work_date) + 6
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('hr-bonus-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;

DROP FUNCTION IF EXISTS hr.set_payroll_week(bigint, integer);
DROP FUNCTION IF EXISTS hr.fn_week_label(smallint);
DROP FUNCTION IF EXISTS hr.fn_payroll_week_start(date, smallint);
ALTER TABLE public.employees DROP COLUMN IF EXISTS payroll_week_start_day;
DO $v$ BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'cbb1cab5c163ae03dfc558d0d228e716' THEN RAISE EXCEPTION 'rollback did not restore get_employee_record'; END IF;
END $v$;
COMMIT;
