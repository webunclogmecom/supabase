-- ============================================================================
-- 2026-10-19_0215 HR pay and bonus history: separate fields for the redesigned table and the Excel export
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-19 (HR App redesign, release 1): the history "grows infinitely", must become a filtered table of
--   20 per page with an Excel export, a better "Open in Admin Review" button, and better formatting of lines like
--   "010-CS Chima Steakhouse · by Serena Natali in Admin Review · approved Oct 12". Then: "go with the real data, and
--   go as recommended". Plan: Building Apps/HR App/docs/specs/2026-10-19-hr-app-redesign-plan.md, step 2.
-- WHY IN THE DATABASE
--   hr.get_employee_record sent each line's client, crew note and ledger note as ONE joined `detail` string, which
--   the app cannot split (33 client names carry the legal company in brackets). Dates must also come out in ET from
--   here: the browser on Fred's machine runs Paris time and would move an evening approval to the next day.
-- WHAT IT DOES (additive: every existing key keeps its exact value; the VERIFY proves it for every employee)
--   1. hr.get_employee_record (copied from the live body, md5 bd8197e5..., anchored edits only):
--      bonus rows gain bonus_kind, rule, visit_id, client_code, client_name, crew_size, shared_with (the other people
--      paid for the same visit, from the ledger), note, decided_on / decided_time (ET), recorded_on (ET),
--      week_start / week_end, reverses_id, reversed_on, after_week_ended, counts_in_total (true), admin_review_url;
--      rate rows gain rate_kind, previous_amount, first_rate, rate_stopped, note, decided_on / decided_time,
--      recorded_on, counts_in_total (false), admin_review_url (null).
--      `link` (relative) and `detail` stay byte-identical: the live app builds "https://admin.unclogme.app" + link,
--      so changing `link` would break every live button until the new table ships. Both go in a later cleanup.
--      Change log: the source label is plain words ("Changed outside the apps", the app's name, "Another app",
--      "Not recorded"), never a raw key; field labels Start date, Access, Color.
--   2. NEW hr.fn_admin_review_url(kind, visit_id, employee_id, date): the one place the Admin Review address lives;
--      NULL for a deleted visit or a shift with no review (the app then shows no button). Owner only.
--   3. public.log_hr_bonus_health (copied from the live body, md5 ba9a0555...): two more items, a person past 800
--      history entries (the trigger to build server paging, hr.get_pay_history) and a bonus taken back after its
--      payroll week ended (Fred: keep it in the week of the work, but say so).
-- RULE 8: no new table or column. GRANTS: hr.fn_admin_review_url revoked from PUBLIC, anon, authenticated,
--   service_role; the hr EXECUTE allowlist is re-asserted (still exactly six functions for authenticated).
-- ROLLBACK: 2026-10-19_rollback_hr_history_fields.sql (the captured live bodies, then DROP of the helper).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

-- Capture today's output for every employee, as an admin and as an office viewer, to prove nothing existing moves.
CREATE TEMP TABLE _ger_old (viewer text, p_id bigint, out jsonb) ON COMMIT DROP;
DO $c$
DECLARE v record; e record;
BEGIN
  FOR v IN SELECT 'admin' AS viewer, id, email FROM public.employees WHERE id = 2
           UNION ALL SELECT 'office', id, email FROM public.employees WHERE id = 42 LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000' || lpad(v.id::text, 2, '0'),
                                                               'email', v.email, 'role', 'authenticated')::text, true);
    FOR e IN SELECT id FROM public.employees ORDER BY id LOOP
      INSERT INTO _ger_old VALUES (v.viewer, e.id, hr.get_employee_record(e.id));
    END LOOP;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
END $c$;


CREATE FUNCTION hr.fn_admin_review_url(p_kind text, p_visit_id bigint, p_employee_id bigint, p_date date) RETURNS text
LANGUAGE sql STABLE SET search_path = '' AS $f$
  -- The one place the Admin Review address lives for the HR App. NULL (no button) when the decision cannot be opened:
  -- a deleted or missing visit, or a shift with no review row.
  with base(u) as (select 'https://admin.unclogme.app')
  select case
    when p_kind = 'visit_bonus' then
      (select b.u || '/review/' || v.id from public.visits v, base b where v.id = p_visit_id and v.deleted_at is null)
    when p_kind = 'shift_bonus' then
      (select b.u || '/review-shift/shift-' || s.employee_id || '-' || to_char(s.shift_date, 'YYYY-MM-DD')
         from public.shift_reviews s, base b where s.employee_id = p_employee_id and s.shift_date = p_date)
  end
$f$;

REVOKE ALL ON FUNCTION hr.fn_admin_review_url(text, bigint, bigint, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb;
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
                            when 'salary_yearly' then 'Yearly salary' end,
      'amount', p.amount, 'unit', case p.kind when 'hourly' then 'hour' when 'salary_weekly' then 'week' else 'year' end,
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
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
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

-- VERIFY
DO $v$
DECLARE r record; v_new jsonb; v_bad text; i int; it jsonb; n_rows int := 0; n_bonus int := 0; v_em text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'hr'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
             <> (p.proname IN ('update_employee', 'get_employee_record', 'get_pay_summary', 'set_pay_rates',
                               'get_bonus_amounts', 'set_company_bonus')));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr EXECUTE grants wrong on: %', v_bad; END IF;

  FOR r IN SELECT * FROM _ger_old ORDER BY viewer, p_id LOOP
    SELECT email INTO v_em FROM public.employees WHERE id = CASE r.viewer WHEN 'admin' THEN 2 ELSE 42 END;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000' ||
              CASE r.viewer WHEN 'admin' THEN '02' ELSE '42' END, 'email', v_em, 'role', 'authenticated')::text, true);
    v_new := hr.get_employee_record(r.p_id);
    n_rows := n_rows + 1;
    IF (r.out - 'activity' - 'history') IS DISTINCT FROM (v_new - 'activity' - 'history') THEN
      RAISE EXCEPTION 'VERIFY: employee % (%): a top-level key changed', r.p_id, r.viewer;
    END IF;
    IF jsonb_array_length(r.out->'history') <> jsonb_array_length(v_new->'history')
       OR jsonb_array_length(r.out->'activity') <> jsonb_array_length(v_new->'activity') THEN
      RAISE EXCEPTION 'VERIFY: employee % (%): history or activity length changed', r.p_id, r.viewer;
    END IF;
    FOR i IN 0 .. jsonb_array_length(v_new->'history') - 1 LOOP
      it := v_new->'history'->i;
      IF NOT (it @> (r.out->'history'->i)) THEN
        RAISE EXCEPTION 'VERIFY: employee % (%): history item % lost or changed an existing key', r.p_id, r.viewer, i;
      END IF;
      IF NOT (it ? 'decided_on' AND it ? 'counts_in_total' AND it ? 'admin_review_url' AND it ? 'note') THEN
        RAISE EXCEPTION 'VERIFY: employee % (%): history item % is missing a new key', r.p_id, r.viewer, i;
      END IF;
      IF it->>'type' <> 'rate_change' THEN
        n_bonus := n_bonus + 1;
        IF NOT (it ? 'client_code' AND it ? 'week_start' AND it ? 'bonus_kind') THEN
          RAISE EXCEPTION 'VERIFY: employee % (%): bonus item % is missing a new key', r.p_id, r.viewer, i;
        END IF;
        IF it->>'admin_review_url' IS NOT NULL AND it->>'admin_review_url' NOT LIKE 'https://admin.unclogme.app/review%' THEN
          RAISE EXCEPTION 'VERIFY: employee %: admin_review_url not absolute: %', r.p_id, it->>'admin_review_url';
        END IF;
      ELSIF r.viewer = 'office' THEN
        RAISE EXCEPTION 'VERIFY: office received a pay rate row for employee %', r.p_id;
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_new->'activity') a
                WHERE a->>'by' IN ('sql', 'Database (by hand)') OR a->>'by' LIKE 'other:%') THEN
      RAISE EXCEPTION 'VERIFY: employee %: the change log still shows a raw source', r.p_id;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  IF n_bonus = 0 THEN RAISE EXCEPTION 'VERIFY: no bonus rows were compared (positive control)'; END IF;
  PERFORM public.log_hr_bonus_health();
  RAISE NOTICE 'VERIFY passed: % record reads compared, % bonus items checked', n_rows, n_bonus;
END $v$;

COMMIT;
