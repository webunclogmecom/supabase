-- 2026-10-20_1500 · Access phase 2: the daily health email lists the watch log
--
-- Plan Appendix A ("Daily health email: watch-log entries"). public.log_hr_bonus_health (already in ops.v_health_items
-- and ops.v_health_status as hr-bonus-health, so it reaches Fred's daily email) gains one item per app, person and
-- action logged in hr.access_refusals in the last 26 hours. Body spliced from the live definition (md5 pinned).
-- Rollback: re-run the previous body (md5 8e2b8a1d...) from git history of this file's predecessor.
BEGIN;
DO $g$ BEGIN IF md5(pg_get_functiondef('public.log_hr_bonus_health()'::regprocedure)) <> '8e2b8a1dfc3128657c9306dc95917bb9' THEN RAISE EXCEPTION 'log_hr_bonus_health changed'; END IF; END $g$;
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

    union all
    -- 2026-10-20_1500 (access phase 2): a change an app in watch mode let through but would refuse once it is checked
    select jsonb_build_object(
             'kind', 'hr_access:watch:' || w.app || ':' || coalesce(w.email, 'unknown') || ':' || w.what,
             'issue', 'access_watch',
             'reason', format('%s did "%s" in %s %s time(s) since yesterday. Their access (%s) would refuse it once %s is checked; it was let through because %s is in its watch week.',
                              coalesce(e.full_name, w.email, 'A sign-in with no person'), w.what, a.name, w.n,
                              hr.fn_access_label(w.has), a.name, a.name),
             'what_to_do', 'Give them the access they need on the HR App Access tab, or confirm they should be refused before the app is switched on.',
             'person', coalesce(e.full_name, w.email))
      from (select r.app, r.email, r.what, max(r.has) as has, max(r.employee_id) as employee_id, count(*) as n
              from hr.access_refusals r where r.at > now() - interval '26 hours'
             group by r.app, r.email, r.what) w
      join hr.access_apps a on a.app = w.app
      left join public.employees e on e.id = w.employee_id
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('hr-bonus-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;

DO $v$ DECLARE n int; it jsonb; BEGIN
  BEGIN
    INSERT INTO hr.access_refusals (app, needs, has, email, what) VALUES ('admin_review','edit','none','probe@unclogme.com','visit_reviews update');
    PERFORM public.log_hr_bonus_health();
    SELECT details INTO it FROM public.sync_log WHERE sync_source='hr-bonus-health' ORDER BY id DESC LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(it->'items') x WHERE x->>'issue' = 'access_watch') THEN RAISE EXCEPTION 'V1 no watch item %', it; END IF;
    RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
END $v$;
COMMIT;
