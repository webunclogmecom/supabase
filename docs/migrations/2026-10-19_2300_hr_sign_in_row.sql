-- 2026-10-19_2300_hr_sign_in_row
-- Fred, 2026-10-19: "we should be able to manage things like the username and password on the user view too ... where
-- is the detail section". Then "go ahead with all recommended" (the email is the username; a reset email, nobody types or
-- sees a password; office sees the row without the buttons; the email of a person with a sign-in is locked; turning a
-- sign-in off and on: "go"). Plan: Building Apps/HR App/docs/specs/2026-10-19-access-privileges-plan.md, Part 2.
--   1. hr.sign_in_changes: the record of every sign-in action, refusals included (rule 8: opted OUT, it is the record).
--   2. hr.get_employee_record: `sign_in` (state none / unconfirmed / active / turned_off / several, method google /
--      password / both, last sign-in date, who turned it off), viewer.can_manage_sign_in (admins, not their own), and
--      Activity lines for sign-in changes (admins).
--   3. hr.request_sign_in_action (admins, called AS THE CALLER by the edge function hr-sign-in) and
--      hr.finish_sign_in_action (server key only): never their own sign-in, never an admin's turn-off, no reset on a
--      Google-only or turned-off sign-in, one reset per person per 15 minutes.
--   4. A turned-off sign-in counts as no sign-in for the access check and for the last-admin count.
--   5. hr.update_employee: the email of a person with a sign-in is locked, and no email may be set to one that signs in.
-- Bodies copied from the live definitions (md5 guarded). Rollback: 2026-10-19_rollback_hr_sign_in_row.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'dca1f1b0b9c77ab6c03da9af377affbe' OR md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) <> '5843e24514a27ed9e8999392fef23af1' OR md5(pg_get_functiondef('hr.fn_access_caller()'::regprocedure)) <> 'da23c03d1df2e4101406d83895cdaf81' OR md5(pg_get_functiondef('hr.fn_active_admins(bigint)'::regprocedure)) <> '5c1c4e6dbf5fa09c28d2faf4339560ef' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;
-- ===== 1. The record of sign-in changes (who, for whom, what, when, the result). Never a password, a link or a token.
CREATE TABLE hr.sign_in_changes (
  id                    bigserial PRIMARY KEY,
  employee_id           bigint NOT NULL REFERENCES public.employees(id),
  auth_user_id          uuid,
  action                text NOT NULL CHECK (action IN ('reset_email', 'turn_off', 'turn_on')),
  status                text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'refused', 'failed')),
  reason                text,
  requested_by_email    text,
  requested_by_employee bigint,
  created_at            timestamptz NOT NULL DEFAULT now(),
  finished_at           timestamptz
);
COMMENT ON TABLE hr.sign_in_changes IS 'Every sign-in action an admin asks for in the HR App (reset email, turn off, turn on), refusals included, with its result. Written only by hr.request_sign_in_action / hr.finish_sign_in_action. Rule 8: opted OUT of audit.logs because this table IS the record (insert, then one status update). 2026-10-19_2300.';
CREATE INDEX sign_in_changes_employee_idx ON hr.sign_in_changes (employee_id, created_at DESC);
REVOKE ALL ON hr.sign_in_changes FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE hr.sign_in_changes_id_seq FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. How a person signs in, for the Details card (admin and office see it; nobody sees a secret)
CREATE FUNCTION hr.fn_sign_in_summary(p_employee_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  with e as (select x.email from public.employees x where x.id = p_employee_id),
  u as (select su.id, su.email_confirmed_at, su.last_sign_in_at, su.banned_until,
               coalesce(nullif(su.encrypted_password, ''), null) is not null as has_password,
               exists (select 1 from auth.identities i where i.user_id = su.id and i.provider = 'google') as has_google
          from auth.users su, e
         where nullif(btrim(e.email), '') is not null and lower(btrim(su.email)) = lower(btrim(e.email))),
  last_off as (select c.requested_by_email, c.finished_at from hr.sign_in_changes c
                where c.employee_id = p_employee_id and c.action = 'turn_off' and c.status = 'done' order by c.id desc limit 1)
  select case
    when (select count(*) from u) = 0 then jsonb_build_object('state', 'none')
    when (select count(*) from u) > 1 then jsonb_build_object('state', 'several')
    else (select jsonb_build_object(
            'state', case when u.email_confirmed_at is null then 'unconfirmed'
                          when u.banned_until is not null and u.banned_until > now() then 'turned_off'
                          else 'active' end,
            'method', case when u.has_google and u.has_password then 'both' when u.has_google then 'google' else 'password' end,
            'last_sign_in_on', (u.last_sign_in_at at time zone 'America/New_York')::date,
            'turned_off_by', case when u.banned_until > now() then hr.fn_person_label((select l.requested_by_email from last_off l)) end,
            'turned_off_on', case when u.banned_until > now() then ((select l.finished_at from last_off l) at time zone 'America/New_York')::date end)
          from u)
  end
$function$;

-- ===== 3. Ask for a sign-in action (the edge function hr-sign-in calls this AS THE CALLER, then does the sign-in
-- change with the server key, then calls hr.finish_sign_in_action). Admins only, never their own sign-in, never an
-- admin's turn-off. A refusal after the admin check is recorded and answered as { ok: false, message }.
CREATE FUNCTION hr.request_sign_in_action(p_employee_id bigint, p_action text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
declare
  v_caller bigint; v_e public.employees; v_n int; v_uid uuid; v_pw boolean; v_banned boolean; v_first text;
  v_msg text; v_id bigint; v_by text;
begin
  perform pg_advisory_xact_lock(hashtext('hr.access'));
  v_caller := hr.fn_require_access_admin();
  if p_action not in ('reset_email', 'turn_off', 'turn_on') then
    raise exception 'Unknown sign-in action.' using errcode = '22023', detail = 'blocker=action_value';
  end if;
  select * into v_e from public.employees where id = p_employee_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  v_first := split_part(btrim(v_e.full_name), ' ', 1);
  select u.email into v_by from auth.users u where u.id = auth.uid();
  select count(*), min(u.id::text)::uuid,
         bool_or(nullif(u.encrypted_password, '') is not null),
         bool_or(u.banned_until is not null and u.banned_until > now())
    into v_n, v_uid, v_pw, v_banned
    from auth.users u
   where u.email_confirmed_at is not null and nullif(btrim(v_e.email), '') is not null
     and lower(btrim(u.email)) = lower(btrim(v_e.email));

  v_msg := case
    when v_n = 0 then v_first || ' has no sign-in.'
    when v_n > 1 then v_first || '''s email matches more than one sign-in. Ask Fred to sort it out.'
    when v_uid = auth.uid() or v_e.id = v_caller then 'You cannot change your own sign-in here.'
    when p_action = 'reset_email' and v_e.status <> 'ACTIVE' then v_first || ' is inactive.'
    when p_action = 'reset_email' and v_banned then v_first || '''s sign-in is turned off. Turn it back on first.'
    when p_action = 'reset_email' and not v_pw then v_first || ' signs in with Google, so there is no password to reset.'
    when p_action = 'reset_email' and exists (select 1 from hr.sign_in_changes c where c.employee_id = v_e.id and c.action = 'reset_email'
                                                and c.status in ('pending', 'done') and c.created_at > now() - interval '15 minutes')
      then 'A reset email was sent to ' || v_first || ' less than 15 minutes ago. Try again later.'
    when p_action = 'turn_off' and v_e.access_level = 'admin' and v_e.status = 'ACTIVE' then 'An admin''s sign-in cannot be turned off. Change the group first.'
    when p_action = 'turn_off' and v_banned then v_first || '''s sign-in is already turned off.'
    when p_action = 'turn_on' and not v_banned then v_first || '''s sign-in is already on.'
  end;

  if v_msg is not null then
    insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
    values (v_e.id, case when v_n = 1 then v_uid end, p_action, 'refused', v_msg, v_by, v_caller, now());
    return jsonb_build_object('ok', false, 'message', v_msg);
  end if;

  insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, requested_by_email, requested_by_employee)
  values (v_e.id, v_uid, p_action, 'pending', v_by, v_caller) returning id into v_id;
  return jsonb_build_object('ok', true, 'log_id', v_id, 'auth_user_id', v_uid, 'email', lower(btrim(v_e.email)),
                            'name', v_e.full_name, 'first_name', v_first, 'action', p_action);
end $function$;

-- ===== 4. Record the result (the server key only, from the edge function). Returns who to tell.
CREATE FUNCTION hr.finish_sign_in_action(p_log_id bigint, p_ok boolean, p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
declare v_c hr.sign_in_changes;
begin
  update hr.sign_in_changes c set status = case when p_ok then 'done' else 'failed' end,
         reason = left(nullif(btrim(p_reason), ''), 300), finished_at = now()
   where c.id = p_log_id and c.status = 'pending'
  returning * into v_c;
  if not found then
    raise exception 'That sign-in request is not waiting.' using errcode = '22023', detail = 'blocker=not_pending log_id=' || p_log_id;
  end if;
  return jsonb_build_object(
    'person', (select jsonb_build_object('name', e.full_name, 'email', lower(btrim(e.email))) from public.employees e where e.id = v_c.employee_id),
    'by', hr.fn_person_label(v_c.requested_by_email),
    'other_admins', (select coalesce(jsonb_agg(lower(btrim(e.email)) order by e.id), '[]'::jsonb) from public.employees e
                      where e.access_level = 'admin' and e.status = 'ACTIVE' and e.id <> v_c.requested_by_employee
                        and nullif(btrim(e.email), '') is not null));
end $function$;

REVOKE ALL ON FUNCTION hr.fn_sign_in_summary(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.request_sign_in_action(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.request_sign_in_action(bigint, text) TO authenticated;
REVOKE ALL ON FUNCTION hr.finish_sign_in_action(bigint, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.finish_sign_in_action(bigint, boolean, text) TO service_role;

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
  -- 2026-10-19_2230 (review): the access lock first, then the caller check, then the row lock, in every writer
  if p_patch ? 'email' or p_patch ? 'status' then perform pg_advisory_xact_lock(hashtext('hr.access')); end if;
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
    if v_row.access_level = 'admin' and v_row.status = 'ACTIVE' and hr.fn_active_admins(p_id) < 1 then
      raise exception 'There must always be one active admin who can sign in. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=last_admin';
    end if;
  end if;
  -- 2026-10-19_2300 (Fred, default 20): the email of a person with a sign-in is their username; changing it is a separate
  -- task, and no email may be set to one that already signs in (access follows the email).
  if 'email' = any (v_changed) then
    if hr.fn_has_sign_in(v_row.email) then
      raise exception 'This email is also %''s sign-in. Changing it is a separate task. Nothing was saved.', split_part(btrim(v_row.full_name), ' ', 1)
        using errcode = '22023', detail = 'blocker=email_is_sign_in';
    end if;
    if v_new.email is not null and exists (select 1 from auth.users u where lower(btrim(u.email)) = lower(btrim(v_new.email))) then
      raise exception 'That email already belongs to a sign-in. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_sign_in_taken';
    end if;
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

CREATE OR REPLACE FUNCTION hr.fn_access_caller()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when count(*) = 1 then min(e.id) end
    from auth.users u
    join public.employees e on e.status = 'ACTIVE' and lower(btrim(e.email)) = lower(btrim(u.email))
   where u.id = auth.uid() and u.email_confirmed_at is not null
     and (u.banned_until is null or u.banned_until <= now())   -- 2026-10-19_2300: a turned-off sign-in is no sign-in
$function$;

CREATE OR REPLACE FUNCTION hr.fn_active_admins(p_except bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select count(*)::int from public.employees e
   where e.access_level = 'admin' and e.status = 'ACTIVE' and e.id is distinct from p_except
     and (select count(*) from auth.users u where u.email_confirmed_at is not null and lower(btrim(u.email)) = lower(btrim(e.email))
            and (u.banned_until is null or u.banned_until <= now())) = 1   -- 2026-10-19_2300: not turned off
$function$;

DO $verify$
DECLARE
  c_fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  j jsonb; r jsonb; v_ok boolean; v_det text;
BEGIN
  -- 1. how people sign in (measured 2026-10-19: Fred and Serena Google + password, Aaron and Yannick Google, Michael none)
  IF hr.fn_sign_in_summary(2)->>'method' <> 'both' OR hr.fn_sign_in_summary(42)->>'method' <> 'both'
     OR hr.fn_sign_in_summary(26)->>'method' <> 'google' OR hr.fn_sign_in_summary(40)->>'state' <> 'none'
     OR hr.fn_sign_in_summary(26)->>'state' <> 'active' THEN
    RAISE EXCEPTION 'VERIFY 1: sign-in summaries: % % % %', hr.fn_sign_in_summary(2), hr.fn_sign_in_summary(26), hr.fn_sign_in_summary(40), hr.fn_sign_in_summary(42);
  END IF;

  -- 2. the record carries the row and the right; office sees the row, not the right
  PERFORM set_config('request.jwt.claims', c_fred, true);
  j := hr.get_employee_record(42);
  IF j->'sign_in'->>'method' <> 'both' OR NOT (j->'viewer'->>'can_manage_sign_in')::boolean THEN RAISE EXCEPTION 'VERIFY 2a: admin view'; END IF;
  j := hr.get_employee_record(2);
  IF (j->'viewer'->>'can_manage_sign_in')::boolean THEN RAISE EXCEPTION 'VERIFY 2b: own page offers sign-in actions'; END IF;
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  j := hr.get_employee_record(42);
  IF j->'sign_in'->>'method' <> 'both' OR (j->'viewer'->>'can_manage_sign_in')::boolean THEN RAISE EXCEPTION 'VERIFY 2c: office view'; END IF;

  -- 3. requests: office refused; refusals recorded and answered in words; a valid request is pending (all undone)
  BEGIN PERFORM hr.request_sign_in_action(42, 'reset_email'); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3a: office asked for a reset'; END IF;
  PERFORM set_config('request.jwt.claims', c_fred, true);
  v_ok := false;
  BEGIN
    r := hr.request_sign_in_action(26, 'reset_email');   -- Aaron is Google only
    v_ok := NOT (r->>'ok')::boolean AND r->>'message' LIKE '%signs in with Google%';
    r := hr.request_sign_in_action(40, 'reset_email');   -- Michael has no sign-in
    v_ok := v_ok AND NOT (r->>'ok')::boolean AND r->>'message' = 'Michael has no sign-in.';
    r := hr.request_sign_in_action(2, 'reset_email');    -- own
    v_ok := v_ok AND NOT (r->>'ok')::boolean AND r->>'message' = 'You cannot change your own sign-in here.';
    r := hr.request_sign_in_action(27, 'turn_off');      -- an admin
    v_ok := v_ok AND NOT (r->>'ok')::boolean AND r->>'message' LIKE 'An admin''s sign-in cannot be turned off%';
    r := hr.request_sign_in_action(26, 'turn_on');       -- not off
    v_ok := v_ok AND NOT (r->>'ok')::boolean;
    v_ok := v_ok AND (SELECT count(*) FROM hr.sign_in_changes WHERE status = 'refused') = 5;
    r := hr.request_sign_in_action(42, 'reset_email');   -- Serena: valid
    v_ok := v_ok AND (r->>'ok')::boolean AND r->>'email' = 'serena@unclogme.com' AND (r->>'log_id') IS NOT NULL;
    r := hr.request_sign_in_action(42, 'reset_email');   -- again: the 15-minute rule
    v_ok := v_ok AND NOT (r->>'ok')::boolean AND r->>'message' LIKE 'A reset email was sent to Serena less than 15 minutes ago%';
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR (SELECT count(*) FROM hr.sign_in_changes) <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: the request rules, or not undone'; END IF;

  -- 4. finish: server key only; a done change shows in Activity; a turned-off sign-in is no sign-in for the access check
  IF has_function_privilege('authenticated', 'hr.finish_sign_in_action(bigint,boolean,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'hr.finish_sign_in_action(bigint,boolean,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.request_sign_in_action(bigint,text)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'hr.sign_in_changes', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4a: a grant is wrong';
  END IF;
  v_ok := false;
  BEGIN
    r := hr.request_sign_in_action(26, 'turn_off');
    r := hr.finish_sign_in_action((r->>'log_id')::bigint, true, NULL);
    v_ok := r->'person'->>'email' = 'aaron@unclogme.com' AND r->'other_admins' ? 'yannick@ayache.com';
    UPDATE auth.users SET banned_until = now() + interval '100 years' WHERE id = '77d4c343-1e21-44eb-98ce-c221028d028a';
    j := hr.get_employee_record(26);
    v_ok := v_ok AND j->'sign_in'->>'state' = 'turned_off' AND j->'sign_in'->>'turned_off_by' IS NOT NULL
            AND EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'SIGN_IN');
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    v_ok := v_ok AND hr.fn_app_level('hr') = 'none';
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR (SELECT banned_until FROM auth.users WHERE id = '77d4c343-1e21-44eb-98ce-c221028d028a') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4b: finish, Activity or the turned-off rule failed, or not undone';
  END IF;

  -- 5. email rules
  PERFORM set_config('request.jwt.claims', c_fred, true);
  BEGIN PERFORM hr.update_employee(42, '{"email":"serena.new@unclogme.com"}'); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=email_is_sign_in'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 5a: a sign-in email was changed (%)', v_det; END IF;
  BEGIN PERFORM hr.update_employee(1, '{"email":"unclogme@unclogme.com"}'); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=email_sign_in_taken'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 5b: Grecia got a sign-in''s email (%)', v_det; END IF;
  v_ok := false;
  BEGIN
    j := hr.update_employee(1, '{"email":"grecia.probe@example.com"}');   -- a normal email for someone with no sign-in still works
    v_ok := j->'employee'->>'email' = 'grecia.probe@example.com';
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 5c: a plain email change was refused'; END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY 2300 passed';
END $verify$;

COMMIT;
