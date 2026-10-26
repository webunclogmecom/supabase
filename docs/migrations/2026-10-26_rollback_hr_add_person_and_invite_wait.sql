-- 2026-10-26_rollback_hr_add_person_and_invite_wait.sql
--
-- Puts hr.fn_invite_refusal, hr.update_employee and hr.get_employee_record back to their bodies from before
-- 2026-10-26_1730 (copied from the live catalog by pg_get_functiondef before the change; md5 89cbaa3c / 14ab32dd /
-- c1d2992c), and drops hr.create_employee and hr.fn_invite_timing. People already added through Add person stay (soft
-- delete only: set them Inactive). Run the HR App's previous build first if it calls hr.create_employee.

BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION hr.fn_invite_refusal(p_employee_id bigint, p_caller bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-26 (Send invite, Trello HhuFXLlt): NULL when an invite may go to this person, otherwise the one sentence the
-- admin sees, checked in the plan's order. It looks at EVERY sign-in at the address, confirmed or not.
declare
  v_e public.employees; v_first text; v_email text;
  v_n int; v_conf boolean; v_self boolean; v_banned boolean; v_mine boolean;
begin
  select * into v_e from public.employees where id = p_employee_id;
  if not found then return 'That person was not found. Reload the page.'; end if;
  v_first := split_part(btrim(v_e.full_name), ' ', 1);
  v_email := lower(nullif(btrim(v_e.email), ''));
  select count(*),
         bool_or(u.email_confirmed_at is not null),
         -- never confirmed and not our own pending invite: it has a password (a self sign-up, whatever invited_at says;
         -- Supabase keeps that password at the click) or it was never invited
         bool_or(u.email_confirmed_at is null and (nullif(u.encrypted_password, '') is not null or u.invited_at is null)),
         bool_or(u.banned_until is not null and u.banned_until > now()),
         bool_or(u.id = auth.uid())
    into v_n, v_conf, v_self, v_banned, v_mine
    from auth.users u
   where v_email is not null and lower(btrim(u.email)) = v_email;

  -- 1. the switch: exactly 'true' is on, anything else (missing included) is off
  if coalesce((select c.value from public.app_config c where c.key = 'hr_invites_on'), '') <> 'true' then
    return 'Invites are not switched on.';
  end if;
  -- 2. own row
  if p_employee_id = p_caller or v_mine then return 'You cannot change your own sign-in here.'; end if;
  -- 3. D7: every app checks access
  if exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on') then
    return 'Invites are off until every app checks access.';
  end if;
  -- 4. active
  if v_e.status is distinct from 'ACTIVE' then
    return v_first || ' is not active. Only an active person can get a sign-in.';
  end if;
  -- 5. an email
  if v_email is null then return v_first || ' has no email in the HR App. Add their company email first.'; end if;
  -- 6. a company address: the sign-up rule itself decides (Supabase runs it when the invite creates the user), never a copy
  if public.fn_restrict_signup_domains(jsonb_build_object('user', jsonb_build_object('email', v_email))) ? 'error' then
    return 'Invites go to company addresses only (@unclogme.com or @ayache.com). ' || v_first || '''s email is a personal address.';
  end if;
  -- 7. several sign-ins at the address
  if v_n > 1 then return v_first || '''s email matches more than one sign-in. Ask Fred to sort it out.'; end if;
  -- 8. confirmed
  if v_conf then return v_first || ' already has a sign-in. If they never chose a password, use Send password reset.'; end if;
  -- 9. never confirmed and not our pending invite (Supabase would resend to it and keep its password)
  if v_self then return 'This address has a sign-in that was never confirmed. Ask Fred or Yannick to clear it first.'; end if;
  -- 10. our invite, turned off (Turn off, or the person set Inactive)
  if v_banned then return v_first || '''s invite was withdrawn. Turn the sign-in back on first.'; end if;
  -- 11. one invite per 15 minutes per person (Supabase has no per-person limit, only 30 emails an hour for everyone)
  if exists (select 1 from hr.sign_in_changes c where c.employee_id = p_employee_id and c.action = 'invite'
                and c.status in ('pending', 'done') and c.created_at > now() - interval '15 minutes') then
    return 'An invite went to ' || v_first || ' less than 15 minutes ago. Try again later.';
  end if;
  return null;
end $function$
;

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
   where k not in ('full_name', 'status', 'shift', 'email', 'phone', 'hire_date', 'color_hex');
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

  -- 2026-10-20_0200 (Fred): the person's colour, the one every app shows (Calendar chips, DUMP, the HR avatar)
  if p_patch ? 'color_hex' then
    v_txt := upper(btrim(coalesce(p_patch->>'color_hex', '')));
    if v_txt !~ '^#[0-9A-F]{6}$' then
      raise exception 'Pick a colour from the list. Nothing was saved.' using errcode = '22023', detail = 'blocker=color_format';
    end if;
    if v_txt in ('#F59E0B', '#22D3EE', '#16A34A', '#F14714') then
      raise exception 'That colour already means something in the apps (a dump site, GO or the UnclogMe orange). Pick another. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=color_reserved';
    end if;
    select e.full_name into v_other from public.employees e
     where upper(e.color_hex) = v_txt and e.id <> p_id and e.status = 'ACTIVE' limit 1;
    if v_other is not null then
      raise exception '% already has this colour. Pick another. Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=color_taken';
    end if;
    v_new.color_hex := v_txt;
  end if;

  if v_new.full_name is distinct from v_row.full_name then v_changed := array_append(v_changed, 'full_name'); end if;
  if v_new.status    is distinct from v_row.status    then v_changed := array_append(v_changed, 'status'); end if;
  if v_new.shift     is distinct from v_row.shift     then v_changed := array_append(v_changed, 'shift'); end if;
  if v_new.email     is distinct from v_row.email     then v_changed := array_append(v_changed, 'email'); end if;
  if v_new.phone     is distinct from v_row.phone     then v_changed := array_append(v_changed, 'phone'); end if;
  if v_new.hire_date is distinct from v_row.hire_date then v_changed := array_append(v_changed, 'hire_date'); end if;
  if v_new.color_hex is distinct from v_row.color_hex then v_changed := array_append(v_changed, 'color_hex'); end if;

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
    -- 2026-10-26 (Send invite): any sign-in at the address (an invite not clicked yet included), or an invite asked for in
    -- the last 15 minutes that Supabase may still be creating, locks the email too. hr.fn_has_sign_in stays confirmed-only
    -- (hr.get_access and hr.get_access_overview read it).
    if exists (select 1 from auth.users u where nullif(btrim(v_row.email), '') is not null and lower(btrim(u.email)) = lower(btrim(v_row.email)))
       or exists (select 1 from hr.sign_in_changes c where c.employee_id = p_id and c.action = 'invite' and c.status = 'pending'
                     and c.created_at > now() - interval '15 minutes') then
      raise exception 'An invite was sent to this email. Changing it is a separate task. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=email_has_invite';
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
         email = v_new.email, phone = v_new.phone, hire_date = v_new.hire_date, color_hex = v_new.color_hex
   where id = p_id
  returning * into v_new;

  return jsonb_build_object('noop', false, 'employee', hr.fn_employee_json(v_new),
    'changed', to_jsonb(v_changed), 'impact', hr.fn_employee_impact(p_id));
end $function$
;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean; v_seebonus boolean; v_can_edit boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb; v_hours jsonb;
  v_invite text;   -- 2026-10-26 (Send invite)
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
      'note', coalesce(x.note, case when x.status = 'pending' then r.custom_note end),
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
          from (select v.shift_date from public.v_inspection_shifts v   -- 2026-10-21 ZEYkT63t: paired shifts
                 where v.employee_id = p_id and v.shift_date >= v_today - 28 and v.shift_date <= v_today and v.kind = 'pair'
                 group by v.shift_date) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_shift_rate_on(p_id, x.shift_date) r on true
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
  -- 2026-10-21 (Fred): a custom SHIFT bonus amount set or removed in Admin Review for this person on one shift.
  union all
  select jsonb_build_object(
      'id', -(3000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Shift bonus, ' || to_char(o.shift_date, 'Mon FMDD, YYYY'),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.shift_date order by o0.id) as prev_amount
            from hr.shift_bonus_overrides o0 where o0.employee_id = p_id) o
   where v_seebonus
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
                             when 'invite' then 'Invite sent to ' || coalesce(lower(btrim(v_e.email)), 'their email')   -- 2026-10-26
                             else 'Sign-in turned back on' end
               || case when c.status = 'failed' then ' (failed: ' || coalesce(c.reason, 'no reason') || ')' else '' end))) a
    from hr.sign_in_changes c
   where c.employee_id = p_id and c.status in ('done', 'failed') and v_level = 'admin'
  ) s2;

  if not v_seebonus then
    v_history := '[]'::jsonb; v_weeks := '[]'::jsonb; v_bonus := null; v_company := null;
  end if;

  -- 2026-10-22 (Trello KqGyoiKQ): hours worked from the Jobber time sheet (hr.fn_hours_worked), the last 26 weeks, each day
  -- with its payroll week. 2026-10-22_2100 (Fred: "both"): hours show with "See bonus amounts" too; the hourly rate and
  -- pay only with "Pay rates and bonus settings".
  if v_pay or v_seebonus then
    select coalesce(jsonb_agg((to_jsonb(h) - case when v_pay then '{}'::text[] else array['hourly_rate', 'pay'] end) || jsonb_build_object(
             'week_start', hr.fn_payroll_week_start(h.work_day, v_e.payroll_week_start_day),
             'week_end', hr.fn_payroll_week_start(h.work_day, v_e.payroll_week_start_day) + 6) order by h.work_day desc), '[]'::jsonb)
      into v_hours from hr.fn_hours_worked(p_id, v_today - 182, v_today) h;
  end if;

  -- 2026-10-26 (Send invite, Trello HhuFXLlt): an admin sees whether an invite may go (hr.fn_invite_refusal). The reason is
  -- shown only to an admin, on someone else, who has no confirmed sign-in (decision 4); everyone else reads null.
  if v_level = 'admin' then v_invite := hr.fn_invite_refusal(p_id, v_caller); end if;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', v_can_edit, 'can_see_pay', v_pay, 'can_see_bonus', v_seebonus, 'is_self', v_e.id = v_caller,
                                 -- 2026-10-19_2145 (decision 10): access follows the email, so only an admin changes email or status
                                 'can_change_email_status', v_e.id <> v_caller and v_level = 'admin',
                                 -- 2026-10-19_2130: only an admin changes a person's payroll week (hr.set_payroll_week)
                                 'can_set_payroll_week', v_pay,
                                 -- 2026-10-19_2300: send a reset email, turn a sign-in off or on (admins, never their own)
                                 'can_manage_sign_in', v_level = 'admin' and v_e.id <> v_caller),
    'sign_in', jsonb_build_object('invited_on', null) || hr.fn_sign_in_summary(p_id)
               || jsonb_build_object('can_invite', v_level = 'admin' and v_invite is null,
                                     'invite_reason', case when v_level = 'admin' and v_e.id <> v_caller and not hr.fn_has_sign_in(v_e.email)
                                                           then v_invite end),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity,
    'hours', v_hours);
end $function$
;

DROP FUNCTION hr.create_employee(jsonb);
DROP FUNCTION hr.fn_invite_timing(bigint);

DO $v$ BEGIN
  IF left(md5(pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure)), 8) <> '89cbaa3c'
     OR left(md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)), 8) <> '14ab32dd'
     OR left(md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)), 8) <> 'c1d2992c' THEN
    RAISE EXCEPTION 'rollback: a body is not back to its pre-1730 fingerprint'; END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
