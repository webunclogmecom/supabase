-- 2026-10-20_0100 · HR App: a person's photo, and "Signed in on" with sign out (Security tab)
--
-- Fred, 2026-10-20: "put like an avatar image ... where we can edit or remove it, it's for the user image. You can put
-- for now the images of slack of each person"; "the next tab will be Security where we have the Sign-in,
-- authentication, change password, reset password, etc." He approved the Security tab as drawn (mockup
-- https://claude.ai/artifact/1vaubTk7z7UXiYnu9o9Eoy) without the two-step code, and the rights recommended there.
--
-- 1. public.employees.photo_path: the photo's path in the new PRIVATE bucket employee-photos ("<employee id>/<file>").
--    Audited already (audit_employees, full row). Readable wherever employees is readable today (authenticated r).
--    hr.fn_employee_json returns it, so hr.get_employee_record carries it.
-- 2. Who may set or remove a photo: Edit in the HR App, or the person on their own page (hr.fn_can_set_photo).
--    Upload: the browser uploads to employee-photos/<id>/<file> (INSERT policy checks the same rule); then
--    hr.set_employee_photo(id, path) records it (the object must exist and be an image). Remove = path NULL.
--    Objects are never updated or deleted by the app (no UPDATE/DELETE policy): a replaced photo stays as a file.
--    ponytail: old files are kept; add a cleanup if the bucket ever matters for size.
-- 3. hr.get_sign_in_devices(id) / hr.sign_out_devices(id): the person themselves, or an admin. Reads/deletes
--    auth.sessions of that person's ONE confirmed sign-in (same match as hr.request_sign_in_action). Only live
--    sessions are listed (inside Auth's 168 h inactivity and 720 h time box). Signing out deletes the sessions, which
--    ends their refresh tokens; an access token already issued stays valid until it expires (at most 1 hour).
--    On your own page your current session is kept. Recorded in hr.sign_in_changes as action 'sign_out' (new value),
--    shown in the record's Activity as "Signed out on N devices" (admins see sign-in Activity, as before).
-- Rule 8: no new table. hr.sign_in_changes stays opted out (it is the record). Every new function is revoked from
-- PUBLIC and anon by name and granted to authenticated + service_role only.
-- Rollback: 2026-10-20_rollback_hr_photo_and_sign_in_devices.sql.

BEGIN;

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'c8c086678b2f3fa2ae4f0189ffc8b4b1' THEN
    RAISE EXCEPTION 'hr.get_employee_record changed since this migration was built';
  END IF;
  IF md5(pg_get_functiondef('hr.fn_employee_json(public.employees)'::regprocedure)) <> '2770c415fa7a2e01e3a68121d4ee25d4' THEN
    RAISE EXCEPTION 'hr.fn_employee_json changed since this migration was built';
  END IF;
END $guard$;

-- 1. the column ------------------------------------------------------------------------------------------------
ALTER TABLE public.employees ADD COLUMN photo_path text
  CONSTRAINT employees_photo_path_chk CHECK (photo_path IS NULL OR photo_path ~ '^[0-9]+/[A-Za-z0-9._-]+$');
COMMENT ON COLUMN public.employees.photo_path IS
  'The person''s photo: a path in the private storage bucket employee-photos ("<id>/<file>"). Written only by hr.set_employee_photo. NULL = initial on the person colour.';

CREATE OR REPLACE FUNCTION hr.fn_employee_json(e employees)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', e.id, 'full_name', e.full_name, 'status', e.status, 'shift', e.shift,
    'email', e.email, 'phone', e.phone, 'hire_date', e.hire_date, 'access_level', e.access_level,
    'color_hex', e.color_hex, 'payroll_week_start_day', e.payroll_week_start_day, 'updated_at', e.updated_at,
    'photo_path', e.photo_path)
$function$;

-- 2. the bucket and its rules ----------------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('employee-photos', 'employee-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp']);

CREATE FUNCTION hr.fn_can_set_photo(p_employee_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller bigint := hr.fn_access_caller();
begin
  if v_caller is null or p_employee_id is null then return false; end if;
  if not exists (select 1 from public.employees e where e.id = p_employee_id) then return false; end if;
  return v_caller = p_employee_id or hr.fn_access_rank(hr.fn_app_level('hr')) >= 2;
end $function$;

CREATE FUNCTION hr.fn_can_set_photo_path(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_name is null or p_name !~ '^[0-9]{1,12}/[A-Za-z0-9._-]+$' then return false; end if;
  return hr.fn_can_set_photo(split_part(p_name, '/', 1)::bigint);
end $function$;

CREATE POLICY employee_photos_staff_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'employee-photos');
CREATE POLICY employee_photos_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'employee-photos' AND hr.fn_can_set_photo_path(name));

CREATE FUNCTION hr.set_employee_photo(p_employee_id bigint, p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_first text;
begin
  select split_part(btrim(e.full_name), ' ', 1) into v_first from public.employees e where e.id = p_employee_id;
  if v_first is null then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  if not hr.fn_can_set_photo(p_employee_id) then
    raise exception 'You cannot change %''s photo. Ask an admin.', v_first using errcode = '42501', detail = 'blocker=photo_rights';
  end if;
  if p_path is not null then
    if p_path !~ ('^' || p_employee_id || '/[A-Za-z0-9._-]+$') then
      raise exception 'That photo belongs to someone else. Upload it again.' using errcode = '22023', detail = 'blocker=photo_path';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'employee-photos' and o.name = p_path
                     and coalesce(o.metadata->>'mimetype', '') like 'image/%') then
      raise exception 'The photo did not finish uploading. Try again.' using errcode = '22023', detail = 'blocker=photo_missing';
    end if;
  end if;
  update public.employees set photo_path = p_path where id = p_employee_id;
  return jsonb_build_object('ok', true, 'photo_path', p_path);
end $function$;

-- 3. signed-in devices -----------------------------------------------------------------------------------------
ALTER TABLE hr.sign_in_changes DROP CONSTRAINT IF EXISTS sign_in_changes_action_check;
ALTER TABLE hr.sign_in_changes ADD CONSTRAINT sign_in_changes_action_check
  CHECK (action = ANY (ARRAY['reset_email','turn_off','turn_on','sign_out']));

-- the person whose devices these are: the caller themselves, or an admin; returns the one confirmed sign-in
CREATE FUNCTION hr.fn_devices_target(p_employee_id bigint, OUT o_self boolean, OUT o_uid uuid, OUT o_caller bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_email text; v_n int;
begin
  o_caller := hr.fn_access_caller();
  if o_caller is null then
    raise exception 'Your sign-in is not linked to one active person in the HR App, so it cannot let you do this.'
      using errcode = '42501', detail = 'blocker=no_employee_row in hr devices';
  end if;
  o_self := (o_caller = p_employee_id);
  if not o_self then perform hr.fn_require_access_admin(); end if;
  select e.email into v_email from public.employees e where e.id = p_employee_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  select count(*), min(u.id::text)::uuid into v_n, o_uid
    from auth.users u
   where u.email_confirmed_at is not null and nullif(btrim(v_email), '') is not null
     and lower(btrim(u.email)) = lower(btrim(v_email));
  if v_n <> 1 then o_uid := null; end if;
end $function$;

CREATE FUNCTION hr.get_sign_in_devices(p_employee_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t record; v_cur text;
begin
  select * into t from hr.fn_devices_target(p_employee_id);
  v_cur := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  return jsonb_build_object('is_self', t.o_self, 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'user_agent', s.user_agent, 'signed_in_at', s.created_at,
             'last_active_at', coalesce(s.refreshed_at, s.updated_at, s.created_at),
             'current', t.o_self and s.id::text = v_cur)
           order by coalesce(s.refreshed_at, s.updated_at, s.created_at) desc)
      from auth.sessions s
     where s.user_id = t.o_uid
       and (s.not_after is null or s.not_after > now())
       and coalesce(s.refreshed_at, s.updated_at, s.created_at) > now() - interval '168 hours'
       and s.created_at > now() - interval '720 hours'), '[]'::jsonb));
end $function$;

CREATE FUNCTION hr.sign_out_devices(p_employee_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t record; v_cur text; v_n int; v_by text; v_first text; v_msg text;
begin
  select * into t from hr.fn_devices_target(p_employee_id);
  select split_part(btrim(e.full_name), ' ', 1) into v_first from public.employees e where e.id = p_employee_id;
  if t.o_uid is null then
    return jsonb_build_object('ok', false, 'message', v_first || ' has no sign-in.');
  end if;
  v_cur := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  delete from auth.sessions s
   where s.user_id = t.o_uid and not (t.o_self and s.id::text is not distinct from v_cur);
  get diagnostics v_n = row_count;
  v_msg := case when v_n = 0 then 'No other devices were signed in.'
                when v_n = 1 then 'Signed out on 1 device.'
                else 'Signed out on ' || v_n || ' devices.' end;
  if v_n > 0 then
    select u.email into v_by from auth.users u where u.id = auth.uid();
    insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
    values (p_employee_id, t.o_uid, 'sign_out', 'done', case when v_n = 1 then '1 device' else v_n || ' devices' end, v_by, t.o_caller, now());
  end if;
  return jsonb_build_object('ok', true, 'signed_out', v_n, 'message', v_msg);
end $function$;

REVOKE ALL ON FUNCTION hr.fn_can_set_photo(bigint), hr.fn_can_set_photo_path(text), hr.set_employee_photo(bigint, text),
  hr.fn_devices_target(bigint), hr.get_sign_in_devices(bigint), hr.sign_out_devices(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.fn_can_set_photo(bigint), hr.fn_can_set_photo_path(text), hr.set_employee_photo(bigint, text),
  hr.get_sign_in_devices(bigint), hr.sign_out_devices(bigint) TO authenticated, service_role;
REVOKE ALL ON FUNCTION hr.fn_devices_target(bigint) FROM authenticated;

-- the record's Activity names the new action
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

-- VERIFY ---------------------------------------------------------------------------------------------------------
DO $verify$
DECLARE r jsonb; n int; fred uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'; aaron uuid := '77d4c343-1e21-44eb-98ce-c221028d028a';
  serena uuid := '5c5df96c-1924-410a-a996-e3e58c44e3c2'; ok boolean;
BEGIN
  -- the record carries photo_path
  PERFORM set_config('request.jwt.claims', json_build_object('sub', fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  r := hr.get_employee_record(26);
  IF NOT (r->'employee' ? 'photo_path') THEN RAISE EXCEPTION 'V1 record has no photo_path'; END IF;
  -- rights: Fred (admin, edit) may set Aaron's photo; Aaron (office: HR edit by default) may set his own and others';
  IF NOT hr.fn_can_set_photo(26) THEN RAISE EXCEPTION 'V2 admin cannot set a photo'; END IF;
  IF hr.fn_can_set_photo_path('26/../x.jpg') OR hr.fn_can_set_photo_path('abc/x.jpg') OR hr.fn_can_set_photo_path(NULL) THEN
    RAISE EXCEPTION 'V3 bad paths accepted'; END IF;
  IF NOT hr.fn_can_set_photo_path('26/a.jpg') THEN RAISE EXCEPTION 'V3b good path refused'; END IF;
  -- set: a missing object is refused, a wrong folder is refused, NULL clears
  BEGIN PERFORM hr.set_employee_photo(26, '26/missing.jpg'); RAISE EXCEPTION 'V4 missing object accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
  BEGIN PERFORM hr.set_employee_photo(26, '27/x.jpg'); RAISE EXCEPTION 'V5 wrong folder accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
  r := hr.set_employee_photo(26, NULL);
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'V6 clear failed'; END IF;
  -- a person with no employee link (no claims sub match) cannot: anon-like caller
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  IF hr.fn_can_set_photo(26) THEN RAISE EXCEPTION 'V7 unknown caller may set a photo'; END IF;
  -- devices: Fred reads Serena's (admin), Aaron (office) may not read Serena's, Aaron reads his own
  PERFORM set_config('request.jwt.claims', json_build_object('sub', fred, 'email', 'fred@ayache.com', 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);
  r := hr.get_sign_in_devices(42);
  IF jsonb_typeof(r->'devices') <> 'array' OR (r->>'is_self')::boolean THEN RAISE EXCEPTION 'V8 admin devices read'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', aaron, 'email', 'aaron@unclogme.com', 'role', 'authenticated')::text, true);
  BEGIN PERFORM hr.get_sign_in_devices(42); RAISE EXCEPTION 'V9 office read someone else''s devices';
  EXCEPTION WHEN sqlstate '42501' THEN NULL; END;
  r := hr.get_sign_in_devices(26);
  IF (r->>'is_self')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'V10 own devices'; END IF;
  -- sign out: Fred signs Serena out; the count matches her live sessions and a log row is written
  PERFORM set_config('request.jwt.claims', json_build_object('sub', fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SELECT count(*) INTO n FROM auth.sessions WHERE user_id = serena;
  BEGIN  -- probe only: always rolled back, so applying this migration never signs Serena out
  r := hr.sign_out_devices(42);
  IF (r->>'signed_out')::int <> n THEN RAISE EXCEPTION 'V11 signed out % of % sessions', r->>'signed_out', n; END IF;
  IF (SELECT count(*) FROM auth.sessions WHERE user_id = serena) <> 0 THEN RAISE EXCEPTION 'V12 sessions left'; END IF;
  IF n > 0 AND NOT EXISTS (SELECT 1 FROM hr.sign_in_changes WHERE employee_id = 42 AND action = 'sign_out') THEN
    RAISE EXCEPTION 'V13 no log row'; END IF;
  RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM auth.sessions WHERE user_id = serena) <> n THEN RAISE EXCEPTION 'V13b probe was not rolled back'; END IF;
  -- grants
  IF has_function_privilege('anon', 'hr.set_employee_photo(bigint,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_devices_target(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.sign_out_devices(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V14 grants'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY ok (Serena had % sessions)', n;
END $verify$;

COMMIT;
