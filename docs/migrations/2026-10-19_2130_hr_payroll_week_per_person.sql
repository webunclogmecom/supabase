-- 2026-10-19_2130_hr_payroll_week_per_person
-- Fred, 2026-10-19 (ET): "the shift we can have something different, like payroll shift, where you there can select the
-- days of the week that person has a payroll, so then on the table below we can see the weeks starting from that ...
-- Grecia has a payroll starting Sunday, but Michael has a payroll starting Thursday". Then, choosing between three readings:
-- "A for all not just Michael" (a week that starts on one day and runs 7 days, for everyone) and "yes" (the whole history
-- regroups). Plan: Building Apps/HR App/docs/specs/2026-10-19-access-privileges-plan.md, Part 2 section 3.
--   1. public.employees.payroll_week_start_day smallint NOT NULL DEFAULT 5 (0 Sunday .. 6 Saturday; 5 = Friday to
--      Thursday, today's week for everyone). Grecia (1) is set to Sunday, Michael Escobar (40) to Thursday.
--   2. hr.fn_payroll_week_start(date, smallint) is the week of a person; the 1-argument form stays as the company
--      default (Friday) and its "as Admin Review's payroll week" note is corrected (Admin Review's filter is Friday noon
--      to the next Friday noon and lists both Fridays: a separate task, untouched here).
--   3. hr.get_employee_record, hr.get_pay_summary (bonus_this_week) and public.log_hr_bonus_health use each person's
--      week. The record carries employee.payroll_week_start_day, viewer.can_set_payroll_week, and Activity shows a change
--      as "Payroll week: Fri to Thu -> Thu to Wed".
--   4. hr.set_payroll_week(employee_id, start_day): admins only; no amount ever changes (a row's week comes from the
--      date of the work).
-- Bodies edited in place from the live definitions (md5 guarded). Rule 8: public.employees is audited
-- (audit_employees); the new column is captured with the row. New functions revoked by name from PUBLIC, anon.
-- Rollback: 2026-10-19_rollback_hr_payroll_week_per_person.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'cbb1cab5c163ae03dfc558d0d228e716' OR md5(pg_get_functiondef('hr.get_pay_summary()'::regprocedure)) <> 'e1880fd22f38de6c160029a46563b1be' OR md5(pg_get_functiondef('log_hr_bonus_health()'::regprocedure)) <> 'db50eb3a037748ac4b054027d4d0015d' OR md5(pg_get_functiondef('hr.fn_employee_json(employees)'::regprocedure)) <> '9979349f6311fe89c8f4e12e59a37db5' OR md5(pg_get_functiondef('hr.fn_payroll_week_start(date)'::regprocedure)) <> 'a8bb10f76c547a224d7abfeda10fd32b' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;

-- totals before, for the VERIFY (amounts must not move)
CREATE TEMP TABLE _before ON COMMIT DROP AS
  SELECT e.id, (SELECT coalesce(sum(b.amount), 0) FROM hr.bonus_events b WHERE b.employee_id = e.id) AS recorded
    FROM public.employees e;

ALTER TABLE public.employees ADD COLUMN payroll_week_start_day smallint NOT NULL DEFAULT 5
  CONSTRAINT employees_payroll_week_start_day_chk CHECK (payroll_week_start_day BETWEEN 0 AND 6);
COMMENT ON COLUMN public.employees.payroll_week_start_day IS
  'The day this person''s 7-day payroll week starts (0 Sunday .. 6 Saturday; default 5 = Friday to Thursday). Set by an admin in the HR App (hr.set_payroll_week). It decides how the HR history groups and totals weeks, never an amount. Fred, 2026-10-19.';

CREATE FUNCTION hr.fn_payroll_week_start(d date, p_start smallint)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- 2026-10-19_2130: the first day of the 7-day payroll week holding d, for a week starting on p_start (0 Sunday .. 6 Saturday)
  select d - ((extract(dow from d)::int - p_start + 7) % 7)
$function$;

CREATE FUNCTION hr.fn_week_label(p_start smallint)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- "Thu to Wed" for a week starting on Thursday (4). NULL for NULL.
  select (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[p_start + 1] || ' to ' || (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[((p_start + 6) % 7) + 1]
$function$;

CREATE OR REPLACE FUNCTION hr.fn_payroll_week_start(d date)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select hr.fn_payroll_week_start(d, 5::smallint)   -- the company default week, Friday to Thursday; a person's own week: the 2-argument form
$function$;

CREATE OR REPLACE FUNCTION hr.fn_employee_json(e employees)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', e.id, 'full_name', e.full_name, 'status', e.status, 'shift', e.shift,
    'email', e.email, 'phone', e.phone, 'hire_date', e.hire_date, 'access_level', e.access_level,
    'color_hex', e.color_hex, 'payroll_week_start_day', e.payroll_week_start_day, 'updated_at', e.updated_at)
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
   where p.kind in ('per_visit_bonus', 'per_shift_bonus') or v_pay
  ) s2;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', true, 'can_see_pay', v_pay, 'is_self', v_e.id = v_caller,
                                 'can_change_email_status', v_e.id <> v_caller and (v_level = 'admin' or coalesce(v_e.access_level, 'field') = 'field'),
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
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date, e.payroll_week_start_day) = hr.fn_payroll_week_start(v_today, e.payroll_week_start_day)),
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
             'reason', format('A %s of %s for %s (work date %s) was taken back on %s, after its payroll week (%s to %s) ended. If that week was already paid, take it off the next pay.',
                              case r.kind when 'visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              to_char(-r.amount, 'FM$999,990.00'), coalesce(e.full_name, 'someone'),
                              to_char(r.work_date, 'Mon FMDD'), to_char(r.created_at at time zone 'America/New_York', 'Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)), 'Dy Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)) + 6, 'Dy Mon FMDD')),
             'what_to_do', 'Check whether that week was already paid, and adjust the next payroll if it was.',
             'person', e.full_name)
      from hr.bonus_events r
      left join public.employees e on e.id = r.employee_id
     where r.rule = 'reversal' and r.amount < 0 and r.created_at > now() - interval '26 hours'
       and (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)) + 6
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('hr-bonus-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;


CREATE FUNCTION hr.set_payroll_week(p_employee_id bigint, p_start_day integer)
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
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin']) c;
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

REVOKE ALL ON FUNCTION hr.fn_payroll_week_start(date, smallint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_week_label(smallint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.set_payroll_week(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.set_payroll_week(bigint, integer) TO authenticated, service_role;

-- Fred's two people (the only ones not on Friday to Thursday)
UPDATE public.employees SET payroll_week_start_day = 0 WHERE id = 1 AND full_name = 'Grecia';
UPDATE public.employees SET payroll_week_start_day = 4 WHERE id = 40 AND full_name = 'Michael Escobar';

-- VERIFY (inside the transaction; any failure rolls the whole migration back)
DO $verify$
DECLARE
  c_admin text := json_build_object('sub','00000000-0000-0000-0000-000000000002','email',(SELECT email FROM public.employees WHERE id = 2),'role','authenticated')::text;
  c_office text := json_build_object('sub','00000000-0000-0000-0000-000000000028','email',(SELECT email FROM public.employees WHERE id = 28),'role','authenticated')::text;
  j jsonb; r jsonb; v_bad int; v_sum numeric; v_sum2 numeric; v_ok boolean;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  -- 1. the column and Fred's two people
  IF (SELECT count(*) FROM public.employees WHERE payroll_week_start_day <> 5) <> 2
     OR (SELECT payroll_week_start_day FROM public.employees WHERE id = 1) <> 0
     OR (SELECT payroll_week_start_day FROM public.employees WHERE id = 40) <> 4 THEN
    RAISE EXCEPTION 'VERIFY 1: the payroll week days are not as intended';
  END IF;

  -- 2. the person's week, for all 7 start days over 21 dates: starts on that day, holds the date, 7 days
  SELECT count(*) INTO v_bad
    FROM generate_series(0, 6) s, generate_series(date '2026-10-01', date '2026-10-21', interval '1 day') g(d)
   WHERE NOT (g.d::date - hr.fn_payroll_week_start(g.d::date, s::smallint) BETWEEN 0 AND 6
              AND extract(dow FROM hr.fn_payroll_week_start(g.d::date, s::smallint)) = s);
  IF v_bad > 0 THEN RAISE EXCEPTION 'VERIFY 2: % wrong week starts', v_bad; END IF;

  -- 3. the 1-argument form is still Friday to Thursday on every date of 2025 and 2026
  SELECT count(*) INTO v_bad FROM generate_series(date '2025-01-01', date '2026-12-31', interval '1 day') g(d)
   WHERE hr.fn_payroll_week_start(g.d::date) <> hr.fn_payroll_week_start(g.d::date, 5::smallint)
      OR extract(dow FROM hr.fn_payroll_week_start(g.d::date)) <> 5;
  IF v_bad > 0 THEN RAISE EXCEPTION 'VERIFY 3: the default week moved on % dates', v_bad; END IF;

  -- 4. Michael's record: every row in a Thursday week, the recorded total unchanged, the week and the right carried
  PERFORM set_config('request.jwt.claims', c_admin, true);
  j := hr.get_employee_record(40);
  SELECT count(*) INTO v_bad FROM jsonb_array_elements(j->'history') h
   WHERE extract(dow FROM (h->>'week_start')::date) <> 4
      OR (h->>'week_end')::date <> (h->>'week_start')::date + 6
      OR (h->>'date')::date NOT BETWEEN (h->>'week_start')::date AND (h->>'week_end')::date;
  IF v_bad > 0 OR jsonb_array_length(j->'history') = 0 THEN
    RAISE EXCEPTION 'VERIFY 4a: % of Michael''s rows are not in a Thursday week (rows: %)', v_bad, jsonb_array_length(j->'history');
  END IF;
  SELECT coalesce(sum((h->>'amount')::numeric), 0) INTO v_sum FROM jsonb_array_elements(j->'history') h WHERE (h->>'counts_in_total')::boolean;
  SELECT coalesce(sum((w->>'total')::numeric), 0) INTO v_sum2 FROM jsonb_array_elements(j->'bonus_weeks') w;
  IF v_sum <> (SELECT recorded FROM _before WHERE id = 40) OR v_sum2 <> v_sum THEN
    RAISE EXCEPTION 'VERIFY 4b: Michael''s totals moved (% / % vs %)', v_sum, v_sum2, (SELECT recorded FROM _before WHERE id = 40);
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(j->'bonus_weeks') w WHERE extract(dow FROM (w->>'week_start')::date) <> 4) > 0 THEN
    RAISE EXCEPTION 'VERIFY 4c: a payroll week of Michael''s does not start on Thursday';
  END IF;
  IF (j->'employee'->>'payroll_week_start_day')::int IS DISTINCT FROM 4 OR NOT coalesce((j->'viewer'->>'can_set_payroll_week')::boolean, false) THEN
    RAISE EXCEPTION 'VERIFY 4d: the record does not carry the week or the admin right';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a, jsonb_array_elements(a->'changes') c
                  WHERE c->>'field' = 'Payroll week' AND c->>'old' = 'Fri to Thu' AND c->>'new' = 'Thu to Wed') THEN
    RAISE EXCEPTION 'VERIFY 4e: Activity does not show "Payroll week: Fri to Thu -> Thu to Wed"';
  END IF;

  -- 5. Grecia's rows sit in Sunday weeks; Mark (35) stays Friday to Thursday
  j := hr.get_employee_record(1);
  IF (SELECT count(*) FROM jsonb_array_elements(j->'history') h WHERE extract(dow FROM (h->>'week_start')::date) <> 0) > 0 THEN
    RAISE EXCEPTION 'VERIFY 5a: a row of Grecia''s is not in a Sunday week';
  END IF;
  j := hr.get_employee_record(35);
  IF (SELECT count(*) FROM jsonb_array_elements(j->'history') h WHERE extract(dow FROM (h->>'week_start')::date) <> 5) > 0 THEN
    RAISE EXCEPTION 'VERIFY 5b: a row of Mark''s left the Friday week';
  END IF;

  -- 6. no recorded bonus changed for anyone
  SELECT count(*) INTO v_bad FROM _before b
   WHERE b.recorded <> (SELECT coalesce(sum(x.amount), 0) FROM hr.bonus_events x WHERE x.employee_id = b.id);
  IF v_bad > 0 THEN RAISE EXCEPTION 'VERIFY 6: % people''s recorded totals moved', v_bad; END IF;

  -- 7. the pay summary's "this week" is Michael's Thursday week
  j := hr.get_pay_summary();
  SELECT (x->>'bonus_this_week')::numeric INTO v_sum FROM jsonb_array_elements(j->'rows') x WHERE (x->>'employee_id')::bigint = 40;
  SELECT sum(b.amount) INTO v_sum2 FROM hr.bonus_events b
   WHERE b.employee_id = 40 AND hr.fn_payroll_week_start(b.work_date, 4::smallint) = hr.fn_payroll_week_start(v_today, 4::smallint);
  IF v_sum IS DISTINCT FROM v_sum2 THEN RAISE EXCEPTION 'VERIFY 7: bonus_this_week % vs %', v_sum, v_sum2; END IF;

  -- 8. the setter: office refused, a bad day refused, a same-day save is a no-op, a change works (then undone)
  PERFORM set_config('request.jwt.claims', c_office, true);
  BEGIN
    PERFORM hr.set_payroll_week(35, 3); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 8a: office could set a payroll week'; END IF;
  PERFORM set_config('request.jwt.claims', c_admin, true);
  BEGIN
    PERFORM hr.set_payroll_week(35, 9); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 8b: day 9 was accepted'; END IF;
  r := hr.set_payroll_week(40, 4);
  IF NOT (r->>'noop')::boolean THEN RAISE EXCEPTION 'VERIFY 8c: a same-day save was not a no-op'; END IF;
  v_ok := false;
  BEGIN
    r := hr.set_payroll_week(35, 3);
    v_ok := NOT (r->>'noop')::boolean AND r->>'label' = 'Wed to Tue' AND r->>'previous_label' = 'Fri to Thu'
            AND (SELECT payroll_week_start_day FROM public.employees WHERE id = 35) = 3;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR (SELECT payroll_week_start_day FROM public.employees WHERE id = 35) <> 5 THEN
    RAISE EXCEPTION 'VERIFY 8d: the admin change did not work, or was not undone';
  END IF;

  -- 9. who can call what
  IF has_function_privilege('anon', 'hr.set_payroll_week(bigint,integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.set_payroll_week(bigint,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_week_label(smallint)', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.fn_week_label(smallint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_payroll_week_start(date,smallint)', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.fn_payroll_week_start(date,smallint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 9: a function grant is wrong';
  END IF;

  -- 10. the health item reads the person's week; 11. the HR list can read the column, nobody can write it directly
  IF position('payroll_week_start_day' IN pg_get_functiondef('public.log_hr_bonus_health()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'VERIFY 10: log_hr_bonus_health still uses the company week';
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.employees', 'payroll_week_start_day', 'SELECT')
     OR has_column_privilege('anon', 'public.employees', 'payroll_week_start_day', 'SELECT')
     OR has_column_privilege('authenticated', 'public.employees', 'payroll_week_start_day', 'UPDATE') THEN
    RAISE EXCEPTION 'VERIFY 11: a column grant is wrong';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY 2130 passed';
END $verify$;

COMMIT;
