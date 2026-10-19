-- ============================================================================
-- 2026-10-19_1200 HR: bonuses are per person
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-19: "The bonus are independent by the person, meaning Grecia can have a bonus of $15 and $30 on her
--   reviews, meanwhile Michael can have $10 and $20." Someone with no amount: "$0 until set". At go-live: "Everyone stays
--   $10 / $25". Edited on the person's page (no Bonus amounts page). Replaces the 2026-10-18 company-only rule.
-- WHAT IT DOES
--   1. hr.fn_rate_on: a person's bonus is their own row only; no row = NULL = $0 (the sync triggers already coalesce to 0).
--      A NULL person still reads the company row, which hr.get_bonus_amounts (today's Admin Review) asks for.
--   2. Seed: every ACTIVE person gets per_visit_bonus and per_shift_bonus rows from 2026-01-01 at the company amounts of
--      that day (9 people today), so no amount changes for anyone, past or present. The VERIFY proves it.
--   3. NEW hr.set_person_bonus (admins; today or later; same messages as set_company_bonus) and
--      hr.get_person_bonus_amounts (any staff sign-in, like get_bonus_amounts) for Admin Review.
--   4. hr.set_company_bonus now refuses in plain words (a company amount would change nobody's pay).
--   5. hr.get_employee_record gains `bonus_amounts` {kind: {amount, since, next}} for admin and office; bonus amount
--      changes show in the history as rate rows titled Visit bonus / Shift bonus (admins).
--   6. hr.get_pay_summary rows gain per_visit_bonus / per_shift_bonus; office now gets those two (never pay rates).
--   7. public.log_hr_bonus_health: an active person with no amount of their own (approvals would pay $0).
-- RULE 8: no new table or column (hr.pay_rates is insert-only and already opted out of audit; its rows are the history).
-- GRANTS: the two new functions revoked from PUBLIC, anon, service_role and granted to authenticated; the allowlist is
--   re-asserted at eight names.
-- ROLLBACK: 2026-10-19_rollback_hr_person_bonus.sql (live bodies; seeded rows stay, they are insert-only history and equal
--   to the company amounts, so they change nothing once the fallback is back).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TEMP TABLE _pb_before ON COMMIT DROP AS
SELECT e.id, k.kind, (select r.amount from hr.fn_rate_on(e.id, k.kind, d.day) r) amt, d.day
  FROM public.employees e CROSS JOIN unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
  CROSS JOIN (values (date '2026-01-01'), (date '2026-10-19'), ((now() at time zone 'America/New_York')::date)) d(day)
 WHERE e.status = 'ACTIVE';

CREATE OR REPLACE FUNCTION hr.fn_rate_on(p_employee_id bigint, p_kind text, p_day date)
 RETURNS TABLE(rate_id bigint, amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with personal as (
    select r.id, r.amount from hr.pay_rates r
     where r.employee_id = p_employee_id and r.kind = p_kind and r.effective_from <= p_day
     order by r.effective_from desc, r.id desc limit 1),
  company as (
    select r.id, r.amount from hr.pay_rates r
     where r.employee_id is null and r.kind = p_kind and r.effective_from <= p_day
     order by r.effective_from desc, r.id desc limit 1)
  -- 2026-10-19_1200 (Fred: bonuses are per person, $0 until set): a person's rate is their own row only. The company
  -- row answers only when no person is given (hr.get_bonus_amounts, which Admin Review reads until it moves to per person).
  select case when p_employee_id is null and p_kind in ('per_visit_bonus', 'per_shift_bonus') then c.id else p.id end,
         case when p_employee_id is null and p_kind in ('per_visit_bonus', 'per_shift_bonus') then c.amount else p.amount end
    from (select 1) one left join personal p on true left join company c on true
$function$;

-- every active person keeps today's company amounts, from Jan 1, 2026, so nothing changes on day one (Fred: "Everyone stays
-- $10 / $25"). Read from the company rows, never typed here.
INSERT INTO hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
SELECT e.id, k.kind, (select r.amount from hr.fn_rate_on(null, k.kind, date '2026-01-01') r), date '2026-01-01',
       'Carried over from the company amount when bonuses became per person (2026-10-19).', null
  FROM public.employees e CROSS JOIN unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
 WHERE e.status = 'ACTIVE'
   AND NOT EXISTS (SELECT 1 FROM hr.pay_rates p WHERE p.employee_id = e.id AND p.kind = k.kind);

CREATE FUNCTION hr.set_person_bonus(p_employee_id bigint, p_kind text, p_amount numeric, p_effective_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: one person's visit or shift bonus, from today or later (never backdated: bonuses already approved keep
-- the amount of their day). Admins only. Copied from hr.set_company_bonus with the person added.
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
  if p_effective_from is null or p_effective_from < v_today or p_effective_from > v_today + 366 then
    raise exception 'The new amount can start today or later (within a year), never in the past: bonuses already approved keep the amount of their day. Nothing was saved.'
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

CREATE FUNCTION hr.get_person_bonus_amounts(p_employee_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: each person's own bonus amounts, every dated row (newest first), so Admin Review can price a visit or
-- shift on its own date. Same gate as hr.get_bonus_amounts (any staff sign-in). A person with no row earns $0.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_person_bonus_amounts';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_person_bonus_amounts';
  end if;
  if p_employee_ids is null or cardinality(p_employee_ids) > 200 then
    raise exception 'Ask for up to 200 people at a time.' using errcode = '22023', detail = 'blocker=ids in hr.get_person_bonus_amounts';
  end if;
  return coalesce((
    select jsonb_object_agg(e.id::text, jsonb_build_object(
             'per_visit_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_visit_bonus'
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb),
             'per_shift_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_shift_bonus'
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb)))
      from public.employees e where e.id = any(p_employee_ids)), '{}'::jsonb);
end $function$;

REVOKE ALL ON FUNCTION hr.set_person_bonus(bigint, text, numeric, date, text) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION hr.get_person_bonus_amounts(bigint[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION hr.set_person_bonus(bigint, text, numeric, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION hr.get_person_bonus_amounts(bigint[]) TO authenticated;

CREATE OR REPLACE FUNCTION hr.set_company_bonus(p_kind text, p_amount numeric, p_effective_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  v_current numeric;
begin
  perform 1 from hr.fn_require_level(array['admin']);
  -- 2026-10-19_1200: bonuses are per person now; a company amount would change nobody's pay.
  raise exception 'Bonuses are set per person now. Open the person''s page and use Edit next to their visit or shift bonus. Nothing was saved.'
    using errcode = '22023', detail = 'blocker=company_bonus_retired in hr.set_company_bonus';
  if p_kind not in ('per_visit_bonus', 'per_shift_bonus') then
    raise exception 'Pick the visit bonus or the shift bonus. Nothing was saved.' using errcode = '22023', detail = 'blocker=bonus_kind';
  end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000 or p_amount <> round(p_amount, 2) then
    raise exception 'The amount must be between $0 and $1,000, in cents at most. Nothing was saved.' using errcode = '22023', detail = 'blocker=amount_range';
  end if;
  if p_effective_from is null or p_effective_from < v_today or p_effective_from > v_today + 366 then
    raise exception 'The new amount can start today or later (within a year), never in the past: bonuses already approved keep the amount of their day. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=effective_from';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Write why the bonus changes. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_missing';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;
  select r.amount into v_current from hr.fn_rate_on(null, p_kind, p_effective_from) r;
  if v_current is not distinct from p_amount then
    return jsonb_build_object('noop', true);
  end if;
  insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
  values (null, p_kind, p_amount, p_effective_from, btrim(p_reason), v_email);
  return jsonb_build_object('noop', false);
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
    select jsonb_build_object(
      'id', p.id, 'type', 'rate_change', 'date', p.effective_from, 'sort_at', p.created_at,
      'title', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                            when 'salary_yearly' then 'Yearly salary' when 'per_visit_bonus' then 'Visit bonus'
                            when 'per_shift_bonus' then 'Shift bonus' end,
      'amount', p.amount, 'unit', case p.kind when 'hourly' then 'hour' when 'salary_weekly' then 'week'
                                    when 'per_visit_bonus' then 'visit' when 'per_shift_bonus' then 'shift' else 'year' end,
      'detail', case when p.amount is null then 'Stopped from this date. ' else 'From this date. ' end || p.reason,
      'by', hr.fn_person_label(p.created_by_email), 'source', 'HR App', 'link', null,
      -- 2026-10-19_0215: structured fields (additive; the keys above are unchanged)
      'rate_kind', p.kind, 'previous_amount', p.prev_amount, 'first_rate', p.nth = 1, 'rate_stopped', p.amount is null,
      'note', p.reason,
      'decided_on', (p.created_at at time zone 'America/New_York')::date, 'decided_time', to_char(p.created_at at time zone 'America/New_York', 'HH24:MI'),
      'recorded_on', (p.created_at at time zone 'America/New_York')::date,
      'counts_in_total', false, 'admin_review_url', null) h
      from (select p0.*,
                   lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount,
                   row_number() over (partition by p0.kind order by p0.effective_from, p0.id) as nth
              from hr.pay_rates p0 where p0.employee_id = p_id) p
     where v_pay
    union all
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

  select coalesce(jsonb_agg(a order by (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
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
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE';

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
             'per_shift_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r)
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
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date) = hr.fn_payroll_week_start(v_today))
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

DO $v$
DECLARE v_bad text; n int;
BEGIN
  -- the allowlist: exactly eight hr functions callable by authenticated, none by anon
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'hr'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
             <> (p.proname IN ('update_employee', 'get_employee_record', 'get_pay_summary', 'set_pay_rates',
                               'get_bonus_amounts', 'set_company_bonus', 'set_person_bonus', 'get_person_bonus_amounts')));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr EXECUTE grants wrong on: %', v_bad; END IF;
  -- day one: every active person's amount on every checked day is what it was before (the company amount)
  SELECT count(*) INTO n FROM _pb_before b WHERE b.amt IS DISTINCT FROM (select r.amount from hr.fn_rate_on(b.id, b.kind, b.day) r);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % active person-day amounts changed', n; END IF;
  SELECT count(*) INTO n FROM _pb_before;
  IF n < 18 THEN RAISE EXCEPTION 'VERIFY: positive control, only % rows compared', n; END IF;
  -- no fallback: someone with no row of their own reads NULL ($0); the NULL person still reads the company row
  IF (select r.amount from hr.fn_rate_on(-1, 'per_visit_bonus', current_date) r) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: company fallback still on'; END IF;
  IF (select r.amount from hr.fn_rate_on(null, 'per_visit_bonus', current_date) r) IS NULL THEN RAISE EXCEPTION 'VERIFY: company read broken'; END IF;
  PERFORM public.log_hr_bonus_health();
  RAISE NOTICE 'VERIFY passed';
END $v$;

COMMIT;
