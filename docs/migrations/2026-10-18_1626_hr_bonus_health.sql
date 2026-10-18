-- ============================================================================
-- 2026-10-18_1626 The HR bonus check joins the daily health email (hr-bonus-health)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "add the bonus check to the daily health email". Planned in
--   docs/superpowers/specs/2026-10-18-hr-app-record-pay-bonus-history-design.md (section 4.4) and deferred
--   while another session held ops.v_health_items / ops.v_health_status (released 03:30 ET the same day).
-- WHAT IT DOES
--   public.log_hr_bonus_health() writes one sync_log row ('hr-bonus-health', ok | attention) whose items are:
--     1. every row of hr.v_bonus_drift EXCEPT 'shift_forms_issue' (an approved shift paid $0 because a form
--        reported an issue: that is the rule Admin Review shows, and Fred confirmed the Oct 5 case on
--        2026-10-18, so it is not a fault and would only mail him about a decision he already made);
--     2. bonus rows the HOURLY REPAIR had to add in the last 26 hours (filled_by = 'sweep'): the triggers on
--        visit_reviews / shift_reviews catch their own errors so an Admin Review save is never blocked, so
--        this is the only trace that they are failing;
--     3. the hourly repair (cron hr-bonus-sweep) has not succeeded in 3 hours.
--   Each item carries a plain 'reason' and 'what_to_do' (rendered by health-escalate) and a unique 'kind',
--   which is the item key. No 'visit_id' field on purpose: v_health_items keys on visit_id first, and two
--   problems on one visit (two crew members) would then collapse into one item.
--   Cron 'hr-bonus-health' 13:27 UTC, before health-escalation at 13:30 (it reads only the latest run).
--   ops.v_health_items and ops.v_health_status get one source entry + one CASE arm each, spliced from the
--   live text with md5 pins (CREATE OR REPLACE keeps their grants).
-- RULE 8: no new table. GRANTS: the function is postgres only (revoked by name from PUBLIC, anon,
--   authenticated, service_role), like log_start_flags_health.
-- ROLLBACK: 2026-10-18_rollback_hr_bonus_health.sql.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION public.log_hr_bonus_health() RETURNS integer
LANGUAGE plpgsql SET search_path = '' AS $f$
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
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('hr-bonus-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $f$;

REVOKE ALL ON FUNCTION public.log_hr_bonus_health() FROM PUBLIC, anon, authenticated, service_role;

-- The two health views: splice from the live text, pinned.
DO $s$
DECLARE v text; c int;
BEGIN
  v := pg_get_viewdef('ops.v_health_items'::regclass);
  IF md5(v) <> '99f968b35d1fc00c65dee00f2c78c292' THEN RAISE EXCEPTION 'v_health_items changed since it was read'; END IF;
  c := (length(v) - length(replace(v, '''samsara-feed-health''::text]))', ''))) / length('''samsara-feed-health''::text]))');
  IF c <> 1 THEN RAISE EXCEPTION 'items list anchor found % times', c; END IF;
  v := replace(v, '''samsara-feed-health''::text]))', '''samsara-feed-health''::text, ''hr-bonus-health''::text]))');
  c := (length(v) - length(replace(v, 'WHEN ''samsara-feed-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)', '')))
       / length('WHEN ''samsara-feed-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)');
  IF c <> 1 THEN RAISE EXCEPTION 'items CASE anchor found % times', c; END IF;
  v := replace(v, 'WHEN ''samsara-feed-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)',
               'WHEN ''samsara-feed-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)'
               || ' WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)');
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_items AS ' || v;

  v := pg_get_viewdef('ops.v_health_status'::regclass);
  IF md5(v) <> 'ccc042496d4f354acafdf6e32cfa5b3f' THEN RAISE EXCEPTION 'v_health_status changed since it was read'; END IF;
  c := (length(v) - length(replace(v, '''samsara-feed-health''::text]))', ''))) / length('''samsara-feed-health''::text]))');
  IF c <> 2 THEN RAISE EXCEPTION 'status list anchor found % times', c; END IF;
  v := replace(v, '''samsara-feed-health''::text]))', '''samsara-feed-health''::text, ''hr-bonus-health''::text]))');
  c := (length(v) - length(replace(v, 'WHEN ''samsara-feed-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)', '')))
       / length('WHEN ''samsara-feed-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)');
  IF c <> 1 THEN RAISE EXCEPTION 'status CASE anchor found % times', c; END IF;
  v := replace(v, 'WHEN ''samsara-feed-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)',
               'WHEN ''samsara-feed-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)'
               || ' WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)');
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_status AS ' || v;
END $s$;

SELECT cron.schedule('hr-bonus-health', '27 13 * * *', 'select public.log_hr_bonus_health()');

-- VERIFY
DO $v$
DECLARE n int; v_status text;
BEGIN
  IF has_function_privilege('anon', 'public.log_hr_bonus_health()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.log_hr_bonus_health()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.log_hr_bonus_health()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: log_hr_bonus_health is executable by an API role';
  END IF;
  IF (SELECT string_agg(relname || ' ' || array_to_string(relacl, ','), ' | ' ORDER BY relname) FROM pg_class
       WHERE oid IN ('ops.v_health_items'::regclass, 'ops.v_health_status'::regclass))
     <> 'v_health_items postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres | v_health_status postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres' THEN
    RAISE EXCEPTION 'VERIFY: health view grants changed';
  END IF;
  n := public.log_hr_bonus_health();
  SELECT status INTO v_status FROM ops.v_health_status WHERE check_name = 'hr-bonus-health';
  IF v_status IS NULL THEN RAISE EXCEPTION 'VERIFY: hr-bonus-health missing from v_health_status'; END IF;
  IF (SELECT count(*) FROM ops.v_health_items WHERE check_name = 'hr-bonus-health') <> n THEN
    RAISE EXCEPTION 'VERIFY: v_health_items does not carry the % item(s)', n;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.v_health_items WHERE check_name = 'hr-bonus-health' AND item->>'issue' = 'shift_forms_issue') THEN
    RAISE EXCEPTION 'VERIFY: the $0 forms-issue shift reached the health items';
  END IF;
  -- the other checks are untouched
  IF (SELECT count(DISTINCT check_name) FROM ops.v_health_status) < 12 THEN RAISE EXCEPTION 'VERIFY: a check vanished from v_health_status'; END IF;
  RAISE NOTICE 'VERIFY passed: % item(s), status %', n, v_status;
END $v$;
COMMIT;
