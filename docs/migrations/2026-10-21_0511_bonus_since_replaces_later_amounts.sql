-- 2026-10-21_0511_bonus_since_replaces_later_amounts.sql
--
-- Fred, 2026-10-21: "make "since" replace later amounts too". Until now a bonus amount set from a date ran only until the
-- person's next dated amount (Michael: $15 from Oct 1 stopped at his $13 from Oct 19). From now on a bonus amount set in
-- the HR App replaces every later dated amount of the same kind, for pending and (with the box) approved bonuses alike.
--
-- hr.pay_rates is append-only, so nothing is deleted: NEW column replaces_later (true on every row hr.set_person_bonus
-- writes from now on) and NEW hr.fn_rate_superseded(id, person, kind, from), the ONE rule: an older row stops counting once
-- a newer replaces_later row of the same person and kind starts on or before its date. It is applied by hr.fn_rate_on (all
-- pricing: sync, pending, health, record), hr.get_person_bonus_amounts (Admin Review prices pending visits from those
-- rows), the record's "next change", hr.set_person_bonus (a change whenever a later amount differs) and
-- hr.preview_person_bonus (new `replaces`: the later amounts it would replace). hr.fn_bonus_reprice_rows: the window is
-- every date from the start date on. Activity adds "Replaces later amounts: $13.00 from Oct 19, 2026".
-- Rows written before this migration are false, so no amount in force moves today (VERIFY 2 checks it). Hourly pay
-- (hr.set_pay_rates) is unchanged.
--
-- Rule 8: hr.pay_rates gains one NOT NULL DEFAULT false column (no row rewritten, append-only guard not fired) and an index.
-- Rehearsed with scripts/checks/hr_app/probe_bonus_reprice.sql (updated) and the rollback after the forward.
-- Rollback: 2026-10-21_rollback_bonus_since_replaces_later_amounts.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_rate_on(bigint,text,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'cd0ca6015d529b676d55a7026a52ba09' THEN RAISE EXCEPTION 'guard: hr.fn_rate_on(bigint,text,date) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_person_bonus_amounts(bigint[])'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '1d807f058120403a29f9498d7b1467d5' THEN RAISE EXCEPTION 'guard: hr.get_person_bonus_amounts(bigint[]) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '8ae4c8911ea1941593dfa2bcb92f9848' THEN RAISE EXCEPTION 'guard: hr.get_employee_record(bigint) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_person_bonus(bigint,text,numeric,date,text,boolean)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '3ac46e223471fa81cfa513e9c10a2510' THEN RAISE EXCEPTION 'guard: hr.set_person_bonus(bigint,text,numeric,date,text,boolean) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_bonus_reprice_rows(bigint,text,numeric,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'c4e4e6809e84018c236281230ac7a6f3' THEN RAISE EXCEPTION 'guard: hr.fn_bonus_reprice_rows(bigint,text,numeric,date) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.preview_person_bonus(bigint,text,numeric,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '045f0d7f1d703a8c5257ffa3288cac8b' THEN RAISE EXCEPTION 'guard: hr.preview_person_bonus(bigint,text,numeric,date) changed'; END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
 WHERE p.oid IN ('hr.fn_rate_on(bigint,text,date)'::regprocedure, 'hr.get_person_bonus_amounts(bigint[])'::regprocedure, 'hr.get_employee_record(bigint)'::regprocedure, 'hr.set_person_bonus(bigint,text,numeric,date,text,boolean)'::regprocedure, 'hr.fn_bonus_reprice_rows(bigint,text,numeric,date)'::regprocedure, 'hr.preview_person_bonus(bigint,text,numeric,date)'::regprocedure);
CREATE TEMP TABLE rate_before ON COMMIT DROP AS
  SELECT e.id, k.kind, d.d, (SELECT x.amount FROM hr.fn_rate_on(e.id, k.kind, d.d) x) amt
    FROM public.employees e CROSS JOIN (VALUES ('per_visit_bonus'), ('per_shift_bonus'), ('hourly')) k(kind)
    CROSS JOIN (VALUES (date '2026-01-15'), (date '2026-10-01'), (date '2026-10-21'), (date '2026-12-31')) d(d);

ALTER TABLE hr.pay_rates ADD COLUMN replaces_later boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN hr.pay_rates.replaces_later IS
  'true on a bonus amount set by hr.set_person_bonus since 2026-10-21 (Fred: "make since replace later amounts too"): it '
  'replaces every OLDER row of the same person and kind that starts on or after its own date (hr.fn_rate_superseded). '
  'Rows before that day are false and keep the old meaning (in force until the next dated row).';

CREATE FUNCTION hr.fn_rate_superseded(p_id bigint, p_employee_id bigint, p_kind text, p_from date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 2026-10-21: a pay_rates row no longer counts once a NEWER row of the same person and kind with replaces_later starts on
  -- or before its date. The ONE rule: hr.fn_rate_on, hr.get_person_bonus_amounts (Admin Review prices from those rows),
  -- the record's next change, the preview and the setter all call it.
  select exists (select 1 from hr.pay_rates y
                  where y.employee_id = p_employee_id and y.kind = p_kind and y.replaces_later
                    and y.id > p_id and y.effective_from <= p_from)
$function$;
REVOKE ALL ON FUNCTION hr.fn_rate_superseded(bigint, bigint, text, date) FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX IF NOT EXISTS pay_rates_person_kind ON hr.pay_rates (employee_id, kind, effective_from);

CREATE OR REPLACE FUNCTION hr.fn_rate_on(p_employee_id bigint, p_kind text, p_day date)
 RETURNS TABLE(rate_id bigint, amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with personal as (
    select r.id, r.amount from hr.pay_rates r
     where r.employee_id = p_employee_id and r.kind = p_kind and r.effective_from <= p_day
       and not hr.fn_rate_superseded(r.id, r.employee_id, r.kind, r.effective_from)   -- 2026-10-21: a later "since" amount replaces it
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

CREATE OR REPLACE FUNCTION hr.get_person_bonus_amounts(p_employee_ids bigint[])
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
  -- 2026-10-20_1400 (phase 2): amounts follow the HR "See bonus amounts" setting
  if hr.fn_access_rank(hr.fn_app_level('hr_bonus')) < 1 then
    raise exception 'You cannot see bonus amounts. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=hr_bonus in hr.get_person_bonus_amounts';
  end if;
  if p_employee_ids is null or cardinality(p_employee_ids) > 200 then
    raise exception 'Ask for up to 200 people at a time.' using errcode = '22023', detail = 'blocker=ids in hr.get_person_bonus_amounts';
  end if;
  return coalesce((
    select jsonb_object_agg(e.id::text, jsonb_build_object(
             'per_visit_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_visit_bonus' and not hr.fn_rate_superseded(p2.id, p2.employee_id, p2.kind, p2.effective_from)
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb),
             'per_shift_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_shift_bonus' and not hr.fn_rate_superseded(p2.id, p2.employee_id, p2.kind, p2.effective_from)
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb)))
      from public.employees e where e.id = any(p_employee_ids)), '{}'::jsonb);
end $function$;

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
                       and not hr.fn_rate_superseded(n.id, n.employee_id, n.kind, n.effective_from)
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
      'note', case when v.bonus_status = 'denied' then vr.bonus_denial_note else r.custom_note end,
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
      left join lateral hr.fn_visit_rate_on(p_id, v.id, v.visit_date) r on true
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
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))
      -- 2026-10-21 (Fred): an amount change that also moved approved bonuses says how many
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Approved bonuses updated', 'old', null,
                     'new', count(*) || case when p.kind = 'per_shift_bonus' then ' shift' else ' visit' end
                            || case when count(*) = 1 then '' else 's' end || ' changed to the new amount'))
                     from hr.bonus_events b where b.reprice_rate_id = p.id and b.reverses_id is null having count(*) > 0),
                  '[]'::jsonb)
      -- 2026-10-21 (Fred: "make since replace later amounts too"): the later dated amounts this change replaced
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Replaces later amounts', 'old', null,
                     'new', string_agg(to_char(o.amount, 'FM$999,999,990.00') || ' from ' || to_char(o.effective_from, 'Mon FMDD, YYYY'), ', '
                                       order by o.effective_from)))
                     from (select distinct on (o0.effective_from) o0.* from hr.pay_rates o0
                            where p.replaces_later and o0.employee_id = p.employee_id and o0.kind = p.kind
                              and o0.effective_from > p.effective_from and o0.id < p.id
                              and not exists (select 1 from hr.pay_rates y where y.employee_id = o0.employee_id and y.kind = o0.kind
                                                and y.replaces_later and y.id > o0.id and y.id < p.id and y.effective_from <= o0.effective_from)
                            order by o0.effective_from, o0.id desc) o
                   having count(*) > 0), '[]'::jsonb)) a
    from (select p0.*, lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount
            from hr.pay_rates p0 where p0.employee_id = p_id) p
   where (p.kind in ('per_visit_bonus', 'per_shift_bonus') and v_seebonus) or v_pay
  -- 2026-10-20 (Trello bZvoo91Z, Fred: "that should be saved who change that number btw in the history activity"): a
  -- custom visit bonus amount set or removed in Admin Review for this person on one visit.
  union all
  select jsonb_build_object(
      'id', -(2000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Visit bonus, ' || concat_ws(' ', c.client_code, to_char(v.visit_date, 'Mon FMDD, YYYY')),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.visit_id order by o0.id) as prev_amount
            from hr.visit_bonus_overrides o0 where o0.employee_id = p_id) o
    join public.visits v on v.id = o.visit_id
    left join public.clients c on c.id = v.client_id
   where v_seebonus
     and not public.fn_is_non_customer(v.client_id)   -- 2026-10-20 (Fred): a smoke test on the test client never reaches HR
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
   where l.table_schema = 'hr' and l.table_name = 'access_overrides' and v_level = 'admin'   -- 2026-10-19_2230: admins only
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  -- 2026-10-19_2300: sign-in changes made from the HR App ("Password reset email sent")
  union all
  select jsonb_build_object(
      'id', -(1000000000 + c.id), 'at', coalesce(c.finished_at, c.created_at), 'operation', 'SIGN_IN',
      'by', coalesce(hr.fn_person_label(c.requested_by_email), 'HR App'), 'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object('field', 'Sign-in', 'old', null,
        'new', case c.action when 'reset_email' then 'Password reset email sent' when 'turn_off' then 'Sign-in turned off'
                             when 'sign_out' then 'Signed out on ' || coalesce(c.reason, 'every device')
                             else 'Sign-in turned back on' end
               || case when c.status = 'failed' then ' (failed: ' || coalesce(c.reason, 'no reason') || ')' else '' end))) a
    from hr.sign_in_changes c
   where c.employee_id = p_id and c.status in ('done', 'failed') and v_level = 'admin'
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
                                 'can_set_payroll_week', v_pay,
                                 -- 2026-10-19_2300: send a reset email, turn a sign-in off or on (admins, never their own)
                                 'can_manage_sign_in', v_level = 'admin' and v_e.id <> v_caller),
    'sign_in', hr.fn_sign_in_summary(p_id),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_person_bonus(p_employee_id bigint, p_kind text, p_amount numeric, p_effective_from date, p_reason text, p_update_approved boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: one person's visit or shift bonus. Admins only.
-- 2026-10-19_1815 (Fred): any start date from 2020 on. A past date changes every bonus still pending.
-- 2026-10-21 (Fred): "add a checkbox ... Update approved bonuses since [date] ... by default unchecked". With
-- p_update_approved, every approved bonus from p_effective_from (hr.fn_bonus_reprice_rows: until the next later amount,
-- custom visit amounts and $0 forms-issue shifts left out) is taken back and recorded again at the new amount, both rows
-- carrying reprice_rate_id. Without it an approved bonus keeps its recorded amount. The same amount and date again with
-- the option still applies it (the amount was changed before, the approved bonuses were not).
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  v_current numeric; v_later boolean; v_rows int := 0; v_rate bigint; v_n int := 0; v_g record; v_note text;
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
  perform pg_advisory_xact_lock(hashtextextended('hr.rates:' || p_employee_id || ':' || p_kind, 0));
  select r.amount into v_current from hr.fn_rate_on(p_employee_id, p_kind, p_effective_from) r;
  if coalesce(p_update_approved, false) then
    select count(*) into v_rows from hr.fn_bonus_reprice_rows(p_employee_id, p_kind, p_amount, p_effective_from);
  end if;
  -- 2026-10-21 (Fred: "make since replace later amounts too"): the new row replaces every later dated amount of this kind
  -- (replaces_later; hr.fn_rate_superseded), so it is a change whenever such a later amount differs.
  v_later := exists (select 1 from hr.pay_rates l where l.employee_id = p_employee_id and l.kind = p_kind
                       and l.effective_from > p_effective_from and l.amount is distinct from p_amount
                       and not hr.fn_rate_superseded(l.id, l.employee_id, l.kind, l.effective_from));
  if v_current is not distinct from p_amount and v_rows = 0 and not v_later then
    return jsonb_build_object('noop', true, 'updated_approved', 0);
  end if;
  insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email, replaces_later)
  values (p_employee_id, p_kind, p_amount, p_effective_from, btrim(p_reason), v_email, true)
  returning id into v_rate;
  if v_rows > 0 then
    v_note := 'Amount changed to ' || to_char(p_amount, 'FM$999,990.00') || ' from ' || to_char(p_effective_from, 'Mon FMDD, YYYY')
              || ' by ' || coalesce(hr.fn_person_label(v_email), 'someone') || ': ' || btrim(p_reason);
    for v_g in select g.* from hr.fn_bonus_reprice_rows(p_employee_id, p_kind, p_amount, p_effective_from) x
                 join hr.bonus_events g on g.id = x.grant_id order by g.id loop
      perform pg_advisory_xact_lock(hashtextextended(case when v_g.kind = 'visit_bonus' then 'hr.bonus.visit:' || v_g.visit_id
                                                          else 'hr.bonus.shift:' || v_g.employee_id || ':' || v_g.work_date end, 0));
      continue when exists (select 1 from hr.bonus_events r where r.reverses_id = v_g.id);
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   pre_present, post_present, forms_issue, decided_by_email, decided_at, reverses_id,
                                   filled_by, reprice_rate_id)
      values (v_g.kind, v_g.employee_id, v_g.visit_id, v_g.work_date, -v_g.amount, v_g.pay_rate_id, 'reversal', v_note,
              v_g.crew_size, v_g.pre_present, v_g.post_present, v_g.forms_issue, v_email, now(), v_g.id, 'rate_change', v_rate);
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   pre_present, post_present, forms_issue, decided_by_email, decided_at, filled_by,
                                   override_id, reprice_rate_id)
      values (v_g.kind, v_g.employee_id, v_g.visit_id, v_g.work_date, p_amount, v_rate, 'approved', v_note,
              v_g.crew_size, v_g.pre_present, v_g.post_present, v_g.forms_issue, v_email, now(), 'rate_change',
              v_g.override_id, v_rate);
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('noop', false, 'updated_approved', v_n);
end $function$;

CREATE OR REPLACE FUNCTION hr.fn_bonus_reprice_rows(p_employee_id bigint, p_kind text, p_amount numeric, p_from date)
 RETURNS TABLE(grant_id bigint, work_date date, old_amount numeric, new_amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 2026-10-21 (Fred): the approved bonuses that a new amount "since <date>" changes. The new amount runs from p_from until
  -- the person's next later amount of the same kind. Left out: a visit with its own custom amount for this person (it
  -- keeps the custom amount), a $0 shift with a forms issue (rule forms_issue), and a bonus already at the new amount.
  -- Used by hr.preview_person_bonus (the count the HR App shows) and hr.set_person_bonus (what it changes): keep ONE rule.
  -- 2026-10-21 (Fred: "make since replace later amounts too"): the window is every date from p_from on.
  select g.id, g.work_date, g.amount, p_amount
    from hr.bonus_events g
   where g.employee_id = p_employee_id
     and g.kind = case p_kind when 'per_visit_bonus' then 'visit_bonus' when 'per_shift_bonus' then 'shift_bonus' end
     and g.reverses_id is null and g.rule = 'approved'
     and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)
     and g.work_date >= p_from
     and g.amount <> p_amount
     and not (g.kind = 'visit_bonus' and coalesce((select o.amount is not null from hr.visit_bonus_overrides o
                                                    where o.visit_id = g.visit_id and o.employee_id = g.employee_id
                                                    order by o.id desc limit 1), false))
$function$;

CREATE OR REPLACE FUNCTION hr.preview_person_bonus(p_employee_id bigint, p_kind text, p_amount numeric, p_effective_from date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21 (Fred): "Update approved bonuses since <date>" / "<N> visits will be updated". Read only. Same people as
-- hr.set_person_bonus. An incomplete form (no amount or date yet) answers 0 instead of an error.
declare v jsonb;
begin
  perform 1 from hr.fn_require_level(array['admin', 'office']);
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);
  if p_kind not in ('per_visit_bonus', 'per_shift_bonus') or p_amount is null or p_amount < 0 or p_amount > 1000
     or p_effective_from is null then
    return jsonb_build_object('approved_count', 0, 'net_change', 0, 'unit', case p_kind when 'per_shift_bonus' then 'shift' else 'visit' end);
  end if;
  select jsonb_build_object('approved_count', count(*), 'net_change', coalesce(sum(x.new_amount - x.old_amount), 0),
                            'first_date', min(x.work_date), 'last_date', max(x.work_date),
                            'unit', case p_kind when 'per_visit_bonus' then 'visit' else 'shift' end,
                            -- 2026-10-21: the later dated amounts this change would replace (newest per date)
                            'replaces', coalesce((select jsonb_agg(jsonb_build_object('effective_from', l.effective_from, 'amount', l.amount)
                                                                    order by l.effective_from)
                                                    from (select distinct on (l0.effective_from) l0.* from hr.pay_rates l0
                                                           where l0.employee_id = p_employee_id and l0.kind = p_kind
                                                             and l0.effective_from > p_effective_from and not hr.fn_rate_superseded(l0.id, l0.employee_id, l0.kind, l0.effective_from)
                                                           order by l0.effective_from, l0.id desc) l), '[]'::jsonb))
    into v from hr.fn_bonus_reprice_rows(p_employee_id, p_kind, p_amount, p_effective_from) x;
  return v;
end $function$;

DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY 1: privileges of a replaced function moved'; END IF;
  IF EXISTS (SELECT 1 FROM rate_before b WHERE b.amt IS DISTINCT FROM (SELECT x.amount FROM hr.fn_rate_on(b.id, b.kind, b.d) x)) THEN
    RAISE EXCEPTION 'VERIFY 2: an amount in force moved (no row replaces anything yet)'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
