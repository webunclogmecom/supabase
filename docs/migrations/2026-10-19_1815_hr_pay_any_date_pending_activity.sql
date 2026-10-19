-- 2026-10-19_1815_hr_pay_any_date_pending_activity
-- Fred, 2026-10-19 (ET): "if we change the payrate in HR app then that needs to be reflected on the apps, like Admin Review
-- App ... we should be able to change it from any date, but it should affect only the ones that have bonus pending.
-- Also we should show the bonuses pending in the HR App table. also the change of the bonuses rates are not being shown in
-- the activity history but in the table as a row, i don't want that, only shown in the activity history."
-- His picks: pending shown as an amount only; the hourly rate follows the same rules; the visit bonus crew is the
-- Calendar crew (public.visit_team) only.
--
-- Measured first: an approved bonus is written once into hr.bonus_events with its amount (hr.fn_sync_visit_bonus /
-- fn_sync_shift_bonus) and nothing recalculates it (hr.v_bonus_drift checks that a grant exists, never its amount). So a
-- rate row dated in the past changes only bonuses still pending. hr.set_pay_rates already accepts dates from 2020.
--
--   1. hr.set_person_bonus: any start date from 2020-01-01 to a year ahead (was today or later).
--   2. hr.get_employee_record: rate changes leave `history` and join `activity` (operation 'RATE', negative id, one
--      change line "Visit bonus: $10.00 -> $15.00 from Nov 2, 2026" plus a "Reason" line). Bonus kinds for admin and
--      office, hourly / salary for admin only. Activity is now ordered by time.
--   3. NEW hr.fn_pending_bonus(employee, today): what the person would earn on bonuses still pending in Admin Review:
--      visits in the review queue (completed, in_review_scope, dated today or earlier, not a non-customer, bonus not
--      decided) where they are on the Calendar crew, at their rate on the visit date; plus shifts of the last 28 days
--      (Admin Review's shift list) with both forms and no issue, bonus not decided, at their shift rate on that date.
--   4. hr.get_pay_summary rows gain `pending_bonus` (admin and office).
--   5. NEW hr.get_review_bonuses(visit_ids, shifts) for Admin Review (any staff sign-in, like get_person_bonus_amounts):
--      per visit the Calendar crew and the RECORDED amounts when the bonus is approved; per shift the recorded amount.
--      Admin Review shows recorded amounts for approved bonuses and today's rates only for pending ones.
-- Bodies 1, 2 and 4 are the live definitions edited in place (md5 guarded), never retyped.
-- Rule 8: no table touched. Rollback: 2026-10-19_rollback_hr_pay_any_date_pending_activity.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.set_person_bonus(bigint,text,numeric,date,text)'::regprocedure)) <> '275e333b19751fe84bb4a746ecce3f76'
     OR md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> '587c4a76a78c3a349815f6c6bfca3167'
     OR md5(pg_get_functiondef('hr.get_pay_summary()'::regprocedure)) <> 'b9d82fac3ff6b80aa3bc15efcdb51330' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;

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
  perform 1 from hr.fn_require_level(array['admin']);
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

CREATE OR REPLACE FUNCTION hr.fn_pending_bonus(p_employee_id bigint, p_today date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select sum(coalesce(r.amount, 0))
      from public.visits_with_review v
      join public.visit_team vt on vt.visit_id = v.id and vt.employee_id = p_employee_id
      cross join lateral hr.fn_rate_on(p_employee_id, 'per_visit_bonus', v.visit_date) r
     where v.visit_status = 'completed' and v.in_review_scope
       and v.visit_date <= p_today and coalesce(v.bonus_status, 'pending') = 'pending'
       and not public.fn_is_non_customer(v.client_id)), 0)
  + coalesce((
    select sum(coalesce(r.amount, 0))
      from (select i.shift_date
              from public.inspections i
             where i.employee_id = p_employee_id and i.shift_date >= p_today - 28 and i.shift_date <= p_today
             group by i.shift_date
            having bool_or(i.inspection_type = 'PRE') and bool_or(i.inspection_type = 'POST')
               and not bool_or(coalesce(i.has_issue, false))) s
      cross join lateral hr.fn_rate_on(p_employee_id, 'per_shift_bonus', s.shift_date) r
     where not exists (select 1 from public.shift_reviews sr
                        where sr.employee_id = p_employee_id and sr.shift_date = s.shift_date
                          and coalesce(sr.bonus_status, 'pending') <> 'pending')), 0)
$function$;

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
      'admin_review_url', hr.fn_admin_review_url(g.kind, g.visit_id, g.employee_id, g.work_date)) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
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

CREATE OR REPLACE FUNCTION hr.get_review_bonuses(p_visit_ids bigint[], p_shifts jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1815: what Admin Review needs to show a bonus the way HR pays it. Per visit: the Calendar crew (who is paid)
-- and, once the bonus is approved, the amounts HR recorded. Per shift ("<employee_id>|<YYYY-MM-DD>"): the recorded amount.
-- Same gate as hr.get_person_bonus_amounts (any staff sign-in).
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_review_bonuses';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_review_bonuses';
  end if;
  if p_visit_ids is null or cardinality(p_visit_ids) > 2000
     or p_shifts is null or jsonb_typeof(p_shifts) <> 'array' or jsonb_array_length(p_shifts) > 500 then
    raise exception 'Ask for up to 2,000 visits and 500 shifts at a time.' using errcode = '22023', detail = 'blocker=size in hr.get_review_bonuses';
  end if;
  return jsonb_build_object(
    'visits', coalesce((
      select jsonb_object_agg(v.id::text, jsonb_build_object(
               'crew', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) order by e.full_name)
                                   from public.visit_team vt join public.employees e on e.id = vt.employee_id
                                  where vt.visit_id = v.id), '[]'::jsonb),
               'recorded', (select jsonb_agg(jsonb_build_object('employee_id', g.employee_id, 'amount', g.amount) order by g.employee_id)
                              from hr.bonus_events g
                             where g.kind = 'visit_bonus' and g.visit_id = v.id and g.reverses_id is null
                               and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id))))
        from (select distinct unnest(p_visit_ids) as id) v), '{}'::jsonb),
    'shifts', coalesce((
      select jsonb_object_agg((x->>'employee_id') || '|' || (x->>'shift_date'), g.amount)
        from jsonb_array_elements(p_shifts) x
        join hr.bonus_events g on g.kind = 'shift_bonus' and g.employee_id = (x->>'employee_id')::bigint
                              and g.work_date = (x->>'shift_date')::date and g.reverses_id is null
                              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)), '{}'::jsonb));
end $function$;

REVOKE ALL ON FUNCTION hr.fn_pending_bonus(bigint, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.get_review_bonuses(bigint[], jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.get_review_bonuses(bigint[], jsonb) TO authenticated, service_role;

-- VERIFY
DO $verify$
DECLARE j jsonb; n int; c_admin text; c_office text; v_p numeric;
BEGIN
  IF has_function_privilege('anon', 'hr.get_review_bonuses(bigint[], jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_pending_bonus(bigint, date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.get_review_bonuses(bigint[], jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: grants';
  END IF;
  c_admin := json_build_object('sub','00000000-0000-0000-0000-000000000002','email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub','00000000-0000-0000-0000-000000000042','email',(select email from public.employees where id = 42),'role','authenticated')::text;
  PERFORM set_config('request.jwt.claims', c_admin, true);
  j := hr.get_employee_record(40);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'rate_change') THEN
    RAISE EXCEPTION 'VERIFY: a rate row is still in the history';
  END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'RATE';
  IF n <> (SELECT count(*) FROM hr.pay_rates WHERE employee_id = 40) THEN
    RAISE EXCEPTION 'VERIFY: admin activity has % rate entries, pay_rates has %', n, (SELECT count(*) FROM hr.pay_rates WHERE employee_id = 40);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'visit_bonus') THEN
    RAISE EXCEPTION 'VERIFY: control failed, Michael has no visit bonus rows left';
  END IF;
  j := hr.get_pay_summary();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'rows') x WHERE x ? 'pending_bonus') THEN
    RAISE EXCEPTION 'VERIFY: pending_bonus missing (admin)';
  END IF;
  PERFORM set_config('request.jwt.claims', c_office, true);
  j := hr.get_employee_record(40);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a, jsonb_array_elements(a->'changes') c
              WHERE a->>'operation' = 'RATE' AND c->>'field' IN ('Hourly rate', 'Weekly salary', 'Yearly salary')) THEN
    RAISE EXCEPTION 'VERIFY: office sees an hourly or salary change';
  END IF;
  j := hr.get_pay_summary();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'rows') x WHERE x ? 'pending_bonus') OR (j->>'can_see_pay')::boolean THEN
    RAISE EXCEPTION 'VERIFY: office summary';
  END IF;
  j := hr.get_review_bonuses(array[5680]::bigint[], '[]'::jsonb);
  IF jsonb_typeof(j->'visits'->'5680'->'crew') <> 'array' THEN RAISE EXCEPTION 'VERIFY: review bonuses shape'; END IF;
  -- a past start date is accepted now (written inside a sub-transaction that is then undone)
  PERFORM set_config('request.jwt.claims', c_admin, true);
  BEGIN
    j := hr.set_person_bonus(40, 'per_visit_bonus', 11, (now() at time zone 'America/New_York')::date - 30, 'verify');
    IF (j->>'noop')::boolean THEN RAISE EXCEPTION 'VERIFY: backdated amount not written' USING errcode = '22000'; END IF;
    RAISE EXCEPTION 'undo_verify_row';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'undo_verify_row' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY ok';
END $verify$;
COMMIT;
