-- ============================================================================
-- 2026-10-18_0320 HR App: who may do what, and editing an employee record
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "the page where we can see each client data and that we can edit ... remember that it
--   also needs to be reflected on other apps when we change stuff". Plan:
--   docs/superpowers/specs/2026-10-18-hr-app-record-pay-bonus-history-design.md (sections 4.1, 4.2, 4.6).
-- WHAT IT DOES
--   1. hr.fn_require_level / hr.fn_caller_level: the caller is the ONE active employee whose email is the
--      JWT email (auth.jwt(), plural claims). Zero or two matches = nobody (fails closed).
--   2. hr.update_employee(p_id, p_patch): the only app write path to public.employees. Admin and office.
--      Fields: full_name, status, shift, email, phone, hire_date. Not here: role (vocabulary undecided),
--      access_level (Privileges, phase 3), color_hex (rule 4b palette, a reviewed migration), notes
--      (readable by every staff account through client.employees).
--      Rights rules (the review of 2026-10-18 found the takeover path): nobody changes their OWN email or
--      status; only an admin changes the email or status of an office or admin person; one active admin
--      must remain; a person becomes Active only with a Jobber link (Fred's standing rule, 2026-08-18).
--      Plain sentences for every refusal, the technical part in DETAIL blocker=<code>.
--   3. Unique indexes on lower(btrim(email)) and lower(btrim(full_name)): 0 duplicates today (measured).
--      They back the RPC's plain refusals for SQL edits and for webhook-samsara's fill-blank too.
--   4. audit.log_change: hr.unclogme.app, the project id 816f8580 and the default host
--      blank-canvas-creator-8666 map to app_source 'hr-app' (spliced from the live body, md5 pinned).
--   hr.fn_employee_impact(p_id): what a move to Inactive does NOT do (sign-in, Jobber, page approver) and
--   what stays assigned. Returned by update_employee and shown before saving.
-- NOT DONE HERE: an HR edit never writes to Jobber (our names are display names; Jobber's userEdit can only
--   set the name and would turn full Jobber names into first names).
-- RULE 8: no new table. public.employees is already audited (audit_employees).
-- GRANTS: every hr function is revoked from PUBLIC/anon/authenticated (new functions are EXECUTE-able by
--   PUBLIC by default, and hr is in PostgREST db_schema); authenticated + service_role get only
--   hr.update_employee.
-- ROLLBACK: 2026-10-18_rollback_hr_gate_and_employee_edit.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'd2e48e25e2d29dd0453e6d0e78f7acf6' THEN
    RAISE EXCEPTION 'audit.log_change changed since this migration was built: rebuild it';
  END IF;
END $g$;

-- 1. Uniqueness that the gate depends on
CREATE UNIQUE INDEX employees_email_lower_uniq ON public.employees (lower(btrim(email)))
  WHERE email IS NOT NULL AND btrim(email) <> '';
CREATE UNIQUE INDEX employees_full_name_ci_uniq ON public.employees (lower(btrim(full_name)));

-- 2. The gate
CREATE FUNCTION hr.fn_caller_level() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  select case when count(*) = 1 then min(e.access_level) end
    from public.employees e
   where e.status = 'ACTIVE'
     and auth.uid() is not null
     and lower(btrim(e.email)) = lower(btrim(nullif(auth.jwt()->>'email', '')))
$f$;

CREATE FUNCTION hr.fn_require_level(p_levels text[])
RETURNS TABLE(employee_id bigint, access_level text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_n int; v_id bigint; v_level text;
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr';
  end if;
  select count(*), min(e.id), min(e.access_level) into v_n, v_id, v_level
    from public.employees e where e.status = 'ACTIVE' and lower(btrim(e.email)) = v_email;
  if v_n <> 1 then
    raise exception 'Your sign-in is not linked to one active person in the HR App, so it cannot let you do this.'
      using errcode = '42501', detail = 'blocker=no_employee_row matches=' || v_n;
  end if;
  if v_level is null or not (v_level = any (p_levels)) then
    raise exception '%', case when p_levels = array['admin'] then 'Only an admin can do this.'
                              else 'Only admin and office staff can do this.' end
      using errcode = '42501', detail = 'blocker=level level=' || coalesce(v_level, 'none');
  end if;
  return query select v_id, v_level;
end $f$;

-- 3. The row as the HR App reads it (no role, no notes: the app does not read them)
CREATE FUNCTION hr.fn_employee_json(e public.employees) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = '' AS $f$
  select jsonb_build_object('id', e.id, 'full_name', e.full_name, 'status', e.status, 'shift', e.shift,
    'email', e.email, 'phone', e.phone, 'hire_date', e.hire_date, 'access_level', e.access_level,
    'color_hex', e.color_hex, 'updated_at', e.updated_at)
$f$;

-- 4. What a move to Inactive leaves in place (computed, never fixed text)
CREATE FUNCTION hr.fn_employee_impact(p_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  with e as (select * from public.employees where id = p_id),
       today as (select (now() at time zone 'America/New_York')::date as d),
       acct as (select u.id from auth.users u, e
                 where e.email is not null and lower(btrim(u.email)) = lower(btrim(e.email)) limit 1)
  select jsonb_build_object(
    'upcoming_visits', (select count(distinct v.id) from public.visit_team vt
                          join public.visits v on v.id = vt.visit_id, today
                         where vt.employee_id = p_id and v.deleted_at is null
                           and v.visit_status = 'scheduled' and v.visit_date >= today.d),
    'open_tasks', (select count(distinct t.id) from ops.calendar_task_assignees a
                     join ops.calendar_tasks t on t.id = a.task_id, today
                    where a.employee_id = p_id and not coalesce(t.is_complete, false) and t.task_date >= today.d),
    'has_sign_in', exists (select 1 from acct),
    'is_page_approver', exists (select 1 from acct where acct.id = any (coalesce(public.fn_page_approver_ids(), '{}'))),
    'has_jobber_link', exists (select 1 from public.entity_source_links l
                                where l.entity_type = 'employee' and l.source_system = 'jobber' and l.entity_id = p_id),
    'has_samsara_link', exists (select 1 from public.entity_source_links l
                                 where l.entity_type = 'employee' and l.source_system = 'samsara' and l.entity_id = p_id))
$f$;

-- 5. The write path
CREATE FUNCTION hr.update_employee(p_id bigint, p_patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_caller bigint; v_level text;
  v_row public.employees; v_new public.employees;
  v_bad text[]; v_changed text[] := '{}'; v_txt text; v_other text; v_date date;
  v_today date := (now() at time zone 'America/New_York')::date;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;

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
    if v_row.access_level in ('admin', 'office') and v_level <> 'admin' then
      raise exception 'Only an admin can change the email or status of someone who uses the office apps.'
        using errcode = '42501', detail = 'blocker=rights_row';
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
end $f$;

-- 6. Attribution: hr.unclogme.app -> hr-app (spliced from the live body)
CREATE OR REPLACE FUNCTION audit.log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pk_cols          TEXT[];
  v_pk               JSONB;
  v_old_clean        JSONB;
  v_new_clean        JSONB;
  v_redact           TEXT[];
  v_col              TEXT;
  v_headers          JSONB;
  v_origin           TEXT;
  v_referer          TEXT;
  v_method           TEXT;
  v_path             TEXT;
  v_x_app_source     TEXT;
  v_app_source       TEXT;
  v_request_context  JSONB;
BEGIN
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT pg_catalog.array_agg(a.attname::TEXT)
    INTO v_pk_cols
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = TG_RELID AND i.indisprimary;

  IF v_pk_cols IS NULL THEN
    v_pk := '{}'::jsonb;
  ELSE
    SELECT pg_catalog.jsonb_object_agg(col, pg_catalog.to_jsonb(COALESCE(NEW, OLD))->col)
      INTO v_pk
      FROM pg_catalog.unnest(v_pk_cols) AS col;
  END IF;

  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  SELECT pg_catalog.array_agg(column_name)
    INTO v_redact
    FROM audit.redacted_columns
   WHERE table_name = TG_TABLE_NAME;
  IF v_redact IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_redact LOOP
      v_old_clean := v_old_clean - v_col;
      v_new_clean := v_new_clean - v_col;
    END LOOP;
  END IF;

  BEGIN
    v_headers := NULLIF(pg_catalog.current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := NULL;
  END;

  v_origin       := COALESCE(v_headers->>'origin', '');
  v_referer      := COALESCE(v_headers->>'referer', '');
  v_method       := NULLIF(pg_catalog.current_setting('request.method', true), '');
  v_path         := NULLIF(pg_catalog.current_setting('request.path', true), '');
  v_x_app_source := NULLIF(v_headers->>'x-app-source', '');

  v_app_source := COALESCE(
    v_x_app_source,
    CASE
      WHEN v_origin = '' THEN 'sql'
      WHEN v_origin LIKE '%derm.unclogme.app%'    THEN 'derm-tracker'
      WHEN v_origin LIKE '%fp.unclogme.app%'      THEN 'field-portal'
      -- Review Builder (Yannick, 2026-08-04). NEW APP on reviews.unclogme.app. Listed FIRST so that a
      -- future loosening of the review.* pattern below cannot swallow it. Verified today that
      -- 'https://reviews.unclogme.app' LIKE '%review.unclogme.app%' is FALSE, so the two do not collide
      -- as written, but the ordering makes that independent of the pattern staying exactly as it is.
      WHEN v_origin LIKE '%reviews.unclogme.app%' THEN 'review-builder'
      -- Admin Review is moving OFF review.unclogme.app because it reads almost identically to the new
      -- app's domain. Both candidate replacements are pinned NOW, before DNS changes, so the cutover
      -- cannot reproduce the 2026-07-03..07-29 failure where 232 rows landed as
      -- other:review.unclogme.app and a usage check reported the app dead while it was writing daily.
      -- All three Admin Review hosts stay mapped: whichever is chosen, and the old one for rollback.
      WHEN v_origin LIKE '%admin.unclogme.app%'   THEN 'admin-review'
      WHEN v_origin LIKE '%audit.unclogme.app%'   THEN 'admin-review'
      WHEN v_origin LIKE '%grease-buddy-dash%'    THEN 'admin-review'
      WHEN v_origin LIKE '%review.unclogme.app%'  THEN 'admin-review'
      WHEN v_origin LIKE '%studio.unclogme.app%'  THEN 'derm-stamp-studio'
      -- stamp.unclogme.app: the Studio's CURRENT custom domain (studio.* redirects here as of
      -- 2026-07-30). Both patterns are kept: the old one still matches 71 historical rows, and a
      -- redirect can be undone. Attribution was surviving ONLY on the per-client X-App-Source
      -- header, which is the Admin Review failure shape (232 rows lost to other:review.unclogme.app).
      WHEN v_origin LIKE '%stamp.unclogme.app%'   THEN 'derm-stamp-studio'
      WHEN v_origin LIKE '%dump.unclogme.app%'    THEN 'dump-schedule'
      WHEN v_origin LIKE '%clients.unclogme.app%' THEN 'client-app'
      WHEN v_origin LIKE '%calendar.unclogme.app%' THEN 'visit-calendar'
      WHEN v_origin LIKE '%6533c3ee%'             THEN 'visit-calendar'
      -- Apps Hub (2026-08-18). The staff launcher at hub.unclogme.app. Pinned BEFORE the DNS change,
      -- which is the rule this file exists to enforce: Admin Review moved host without a CASE arm and
      -- 232 rows landed as other:review.unclogme.app over 26 days while a usage check called it dead.
      -- ⚠ The hub writes NOTHING today (no tables, no RPCs; its only backend contact is Supabase Auth),
      -- so this arm is expected to match ZERO rows on day one. That is not a reason to omit it: the
      -- moment the hub gains any write (a pinned-apps preference, a last-opened marker) attribution
      -- would degrade silently, and the retrofit is the 26-day incident above.
      -- The project-id arm mirrors the %6533c3ee% precedent below so the Lovable preview is labelled
      -- apps-hub rather than being swallowed by the %lovable.app% catch-all.
      WHEN v_origin LIKE '%hub.unclogme.app%'     THEN 'apps-hub'
      WHEN v_origin LIKE '%6ce459ba%'             THEN 'apps-hub'
      -- Picture Planner (2026-09-24). Staff page builder plus, later, the public intake form, moving to
      -- planner.unclogme.app. Pinned BEFORE the DNS change (plan B.3, Building Apps/docs/
      -- 2026-09-23_intake-forms-viewer-plan.md): Admin Review moved host without an arm and 232 rows
      -- landed as other:review.unclogme.app over 26 days. It writes nothing today, so these arms match
      -- zero rows on day one; that is not a reason to omit them. The published Lovable host and the
      -- project id keep its previews out of the %lovable.app% catch-all, as %6533c3ee% does.
      WHEN v_origin LIKE '%planner.unclogme.app%' THEN 'picture-planner'
      WHEN v_origin LIKE '%unclogme-pics-organizer%' THEN 'picture-planner'
      WHEN v_origin LIKE '%d9464151%'             THEN 'picture-planner'
      -- HR App (2026-10-18): hr.unclogme.app, its Lovable project id and its default host, pinned before its
      -- first write (until now the app wrote nothing). Above the %lovable.app% catch-all.
      WHEN v_origin LIKE '%hr.unclogme.app%'      THEN 'hr-app'
      WHEN v_origin LIKE '%816f8580%'             THEN 'hr-app'
      WHEN v_origin LIKE '%blank-canvas-creator-8666%' THEN 'hr-app'
      WHEN v_origin LIKE '%lovable.app%'          THEN 'lovable-preview'
      ELSE 'other:' || COALESCE(pg_catalog.substring(v_origin, 'https?://([^/]+)'), v_origin)
    END
  );

  v_request_context := pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'origin',          NULLIF(v_origin, ''),
      'referer',         NULLIF(v_referer, ''),
      'method',          v_method,
      'path',            v_path,
      'app_source_hint', v_x_app_source,
      'actor_name',      pg_catalog.left(NULLIF(v_headers->>'x-actor-name', ''), 120),
      'change_reason',   pg_catalog.left(NULLIF(v_headers->>'x-change-reason', ''), 500)
    )
  );

  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row,
    changed_by, db_role, jwt_claims,
    app_source, request_context, txid
  ) VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_pk,
    TG_OP,
    v_old_clean,
    v_new_clean,
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    CURRENT_USER::text,
    NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    v_app_source,
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END,
    pg_catalog.txid_current()
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$;

-- 7. Grants
REVOKE ALL ON FUNCTION hr.fn_caller_level() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_require_level(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_employee_json(public.employees) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_employee_impact(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.update_employee(bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.update_employee(bigint, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION hr.update_employee(bigint, jsonb) IS
  'HR App: the only app write path to public.employees (full_name, status, shift, email, phone, hire_date). '
  'Admin and office; own email/status refused; office cannot change email/status of office/admin rows. '
  'Never writes to Jobber. Spec docs/superpowers/specs/2026-10-18-hr-app-record-pay-bonus-history-design.md';

-- VERIFY
DO $v$
DECLARE v_body text := pg_get_functiondef('audit.log_change()'::regprocedure); v_bad text;
BEGIN
  IF (length(v_body) - length(replace(v_body, '''%hr.unclogme.app%''', ''))) / length('''%hr.unclogme.app%''') <> 1 THEN
    RAISE EXCEPTION 'VERIFY: hr.unclogme.app arm missing or duplicated in audit.log_change';
  END IF;
  IF position('''%hr.unclogme.app%''' in v_body) > position('''%lovable.app%''' in v_body) THEN
    RAISE EXCEPTION 'VERIFY: the hr arm sits below the lovable.app catch-all';
  END IF;
  -- every hr function: anon never; authenticated only on the allowlist
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'hr'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
             <> (p.proname IN ('update_employee')));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr EXECUTE grants wrong on: %', v_bad; END IF;
  IF NOT has_function_privilege('authenticated', 'hr.update_employee(bigint,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: positive control failed (authenticated cannot run update_employee)';
  END IF;
  IF (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'employees'
       AND indexname IN ('employees_email_lower_uniq', 'employees_full_name_ci_uniq')) <> 2 THEN
    RAISE EXCEPTION 'VERIFY: unique indexes missing';
  END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
COMMIT;
