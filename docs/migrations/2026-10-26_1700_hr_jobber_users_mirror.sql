-- ============================================================================
-- 2026-10-26_1700 · New hires part 2: Jobber's team list, kept in step with the HR App (read only on Jobber)
-- ============================================================================
-- Fred, 2026-10-26: "we need to be able to create new hires ... Keep in mind that also needs to be reflected in jobber,
-- same as when a staff member is inactive or active, their pay rate and any data that can be reflected in jobber."
-- Plan: Building Apps/HR App/docs/specs/2026-10-26-new-hires-plan.md (Trello zRTbWvXn).
--
-- Measured first: Jobber's API cannot create a user, change a user's status or set a pay rate (introspected at
-- 2026-04-16, 2026-09-09 and 2026-09-25: the only user write is userEdit(input: {name})). So this READS Jobber's team
-- every 15 minutes (edge fn sync-jobber-users, read token) and:
--   * hr.jobber_users: the mirror. Sync table, opted OUT of audit (rule 8: rewritten every 15 minutes). No grants.
--   * hr.jobber_user_ignores: a person's "not a staff member" mark on a Jobber user. Human-edited, so AUDITED.
--   * hr.sync_jobber_users(jsonb): the only writer of the mirror (service_role). Links an ACTIVE person with no Jobber link
--     to the ONE Jobber user with the same email (that user linked to nobody, that email on one person only).
--   * hr.fn_jobber_person(employee): the Jobber line on a person's page (state + the person's Jobber page).
--   * hr.get_jobber_people(): admins: Jobber users in no HR record (for Add), and every difference.
--   * hr.set_jobber_user_ignored(jobber_id, ignored, reason): admins.
--   * public.fn_request_jobber_sync('users') and cron sync-jobber-users (*/15).
--   * public.log_jobber_sync_health watches source jobber_users (45 minutes); public.log_access_health names differences
--     older than a day. Both are SPLICED from their live bodies (md5-guarded), never retyped.
-- Rule 1: links live in entity_source_links (match_method 'email' for the automatic link). Rule 6: nothing deleted;
-- a Jobber user Jobber no longer returns gets removed_at.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) <> 'f43f433306aa714e37e25d6b3483b360' THEN
    RAISE EXCEPTION 'guard: public.log_jobber_sync_health changed'; END IF;
  IF md5(pg_get_functiondef('public.log_access_health()'::regprocedure)) <> 'f653879c025a35324a75f577415e6d24' THEN
    RAISE EXCEPTION 'guard: public.log_access_health changed'; END IF;
  IF to_regclass('hr.jobber_users') IS NOT NULL THEN RAISE EXCEPTION 'guard: hr.jobber_users already exists'; END IF;
END $g$;

CREATE TEMP TABLE nh_acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('public.log_jobber_sync_health()'::regprocedure, 'public.log_access_health()'::regprocedure,
                   'public.fn_request_jobber_sync(text)'::regprocedure);

-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE hr.jobber_users (
  jobber_id          text PRIMARY KEY,                -- Jobber's encoded id (base64 gid://Jobber/User/<n>)
  full_name          text,
  email              text,
  phone              text,
  status             text NOT NULL,                   -- ACTIVATED, DEACTIVATED, NOT_INVITED, SEND_INVITE, RESEND_INVITE
  is_account_admin   boolean,
  is_account_owner   boolean,
  jobber_created_at  timestamptz,
  last_login_at      timestamptz,
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  seen_at            timestamptz NOT NULL DEFAULT now(),
  removed_at         timestamptz                      -- Jobber stopped returning it (never deleted here)
);
COMMENT ON TABLE hr.jobber_users IS
  'Jobber''s team list, read every 15 minutes by edge fn sync-jobber-users through hr.sync_jobber_users (2026-10-26_1700). '
  'Read only on Jobber. Opted out of audit (rewritten every run).';
REVOKE ALL ON hr.jobber_users FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE hr.jobber_user_ignores (
  jobber_id   text PRIMARY KEY,
  reason      text NOT NULL,
  set_by      text,
  set_at      timestamptz NOT NULL DEFAULT now(),
  cleared_at  timestamptz,
  cleared_by  text
);
COMMENT ON TABLE hr.jobber_user_ignores IS
  'An admin''s mark that a Jobber user is not a staff member (hr.set_jobber_user_ignored). Audited. 2026-10-26_1700.';
REVOKE ALL ON hr.jobber_user_ignores FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER audit_jobber_user_ignores AFTER INSERT OR UPDATE OR DELETE ON hr.jobber_user_ignores
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.fn_jobber_user_url(p_jobber_id text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
-- 2026-10-26_1700: the person's page in Jobber (manage_team/<base64 of the numeric id>, the address Serena shared for
-- Jerald), or the Manage Team page when the id cannot be read.
declare v_num text;
begin
  v_num := substring(convert_from(decode(p_jobber_id, 'base64'), 'UTF8') from '/([0-9]+)$');
  if v_num is null then return 'https://secure.getjobber.com/manage_team'; end if;
  return 'https://secure.getjobber.com/manage_team/' || encode(convert_to(v_num, 'UTF8'), 'base64');
exception when others then
  return 'https://secure.getjobber.com/manage_team';
end $function$;
REVOKE ALL ON FUNCTION hr.fn_jobber_user_url(text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.sync_jobber_users(p_users jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-26_1700: the only writer of hr.jobber_users. p_users = Jobber's users[] nodes as read (every page). An empty
-- list is refused (a failed read must never look like "everyone left"); removals are skipped when the list is under
-- half of the users we hold.
declare v_n int; v_known int; v_up int := 0; v_removed int := 0; v_linked jsonb := '[]'::jsonb; v_skip_removals boolean;
begin
  if p_users is null or jsonb_typeof(p_users) <> 'array' or jsonb_array_length(p_users) = 0 then
    raise exception 'Jobber returned no users; nothing changed.' using errcode = '22023', detail = 'blocker=empty_list in hr.sync_jobber_users';
  end if;
  v_n := jsonb_array_length(p_users);
  select count(*) into v_known from hr.jobber_users where removed_at is null;
  v_skip_removals := v_n < v_known / 2;

  with src as (
    select nullif(btrim(u->>'id'), '') id, nullif(btrim(u->'name'->>'full'), '') full_name,
           lower(nullif(btrim(u->'email'->>'raw'), '')) email, nullif(btrim(u->'phone'->>'raw'), '') phone,
           nullif(btrim(u->>'status'), '') status, (u->>'isAccountAdmin')::boolean adm, (u->>'isAccountOwner')::boolean own,
           (u->>'createdAt')::timestamptz created, (u->>'lastLoginAt')::timestamptz last_login
      from jsonb_array_elements(p_users) u),
  up as (
    insert into hr.jobber_users as j (jobber_id, full_name, email, phone, status, is_account_admin, is_account_owner,
                                      jobber_created_at, last_login_at, seen_at, removed_at)
    select id, full_name, email, phone, status, adm, own, created, last_login, now(), null from src where id is not null and status is not null
    on conflict (jobber_id) do update
      set full_name = excluded.full_name, email = excluded.email, phone = excluded.phone, status = excluded.status,
          is_account_admin = excluded.is_account_admin, is_account_owner = excluded.is_account_owner,
          jobber_created_at = excluded.jobber_created_at, last_login_at = excluded.last_login_at,
          seen_at = now(), removed_at = null
    returning 1)
  select count(*) into v_up from up;

  if not v_skip_removals then
    update hr.jobber_users j set removed_at = now()
     where j.removed_at is null
       and not exists (select 1 from jsonb_array_elements(p_users) u where btrim(u->>'id') = j.jobber_id);
    get diagnostics v_removed = row_count;
  end if;

  -- the automatic link: an ACTIVE person with no Jobber link, whose email is on exactly one live Jobber user that is
  -- linked to nobody, and on exactly one person
  with c as (
    select e.id employee_id, j.jobber_id, j.full_name
      from public.employees e
      join hr.jobber_users j on j.removed_at is null and j.email = lower(btrim(e.email))
     where e.status = 'ACTIVE' and nullif(btrim(e.email), '') is not null
       and not exists (select 1 from public.entity_source_links l
                        where l.entity_type = 'employee' and l.source_system = 'jobber' and l.entity_id = e.id)
       and not exists (select 1 from public.entity_source_links l
                        where l.entity_type = 'employee' and l.source_system = 'jobber' and l.source_id = j.jobber_id)
       and (select count(*) from hr.jobber_users j2 where j2.removed_at is null and j2.email = j.email) = 1
       and (select count(*) from public.employees e2 where lower(btrim(e2.email)) = lower(btrim(e.email))) = 1),
  ins as (
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
    select 'employee', c.employee_id, 'jobber', c.jobber_id, c.full_name, 'email', 1 from c
    returning entity_id, source_id)
  select coalesce(jsonb_agg(jsonb_build_object('employee_id', entity_id, 'jobber_id', source_id)), '[]'::jsonb) into v_linked from ins;

  return jsonb_build_object('read', v_n, 'upserted', v_up, 'removed', v_removed, 'removals_skipped', v_skip_removals,
                            'linked', v_linked);
end $function$;
REVOKE ALL ON FUNCTION hr.sync_jobber_users(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.sync_jobber_users(jsonb) TO service_role;

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.fn_jobber_person(p_employee_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-26_1700: the Jobber line on a person's page. state, in this order:
  --   not_in_jobber            active here, no Jobber link (add them in Jobber with the same email; they link by themselves)
  --   jobber_user_missing      linked, but Jobber no longer returns that user
  --   deactivated_in_jobber    active here, deactivated in Jobber
  --   active_in_jobber         inactive here, still active (or invited) in Jobber
  --   in_step                  everything agrees
  --   none                     inactive here and not in Jobber
  with e as (select x.id, x.status, lower(btrim(x.email)) email from public.employees x where x.id = p_employee_id),
  l as (select s.source_id from public.entity_source_links s
         where s.entity_type = 'employee' and s.source_system = 'jobber' and s.entity_id = p_employee_id limit 1),
  j as (select u.* from hr.jobber_users u join l on l.source_id = u.jobber_id where u.removed_at is null)
  select jsonb_build_object(
    'state', case
      when (select source_id from l) is null then case when (select status from e) = 'ACTIVE' then 'not_in_jobber' else 'none' end
      when not exists (select 1 from j) then 'jobber_user_missing'
      when (select status from e) = 'ACTIVE' and (select status from j) = 'DEACTIVATED' then 'deactivated_in_jobber'
      when (select status from e) is distinct from 'ACTIVE' and (select status from j) <> 'DEACTIVATED' then 'active_in_jobber'
      else 'in_step' end,
    'jobber_id', (select source_id from l),
    'jobber_name', (select full_name from j),
    'jobber_email', (select email from j),
    'jobber_status', (select status from j),
    'email_differs', coalesce((select email from j) is distinct from (select email from e), false) and exists (select 1 from j),
    'url', case when (select source_id from l) is not null then hr.fn_jobber_user_url((select source_id from l))
                else 'https://secure.getjobber.com/manage_team' end,
    'synced_at', (select max(seen_at) from hr.jobber_users))
$function$;
REVOKE ALL ON FUNCTION hr.fn_jobber_person(bigint) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.get_jobber_people()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-26_1700: admins. not_in_hr = live Jobber users that are not deactivated, linked to no person and not marked
-- "not a staff member" (Add person can prefill from them); differences = every person whose Jobber line is not in step.
declare v_caller bigint; v_level text;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin']) c;
  perform hr.fn_require_app('hr', 'view');
  return jsonb_build_object(
    'synced_at', (select max(seen_at) from hr.jobber_users),
    'not_in_hr', (select coalesce(jsonb_agg(jsonb_build_object('jobber_id', j.jobber_id, 'name', j.full_name, 'email', j.email,
                          'phone', j.phone, 'status', j.status, 'url', hr.fn_jobber_user_url(j.jobber_id)) order by j.full_name), '[]'::jsonb)
                    from hr.jobber_users j
                   where j.removed_at is null and j.status <> 'DEACTIVATED'
                     and not exists (select 1 from public.entity_source_links l
                                      where l.entity_type = 'employee' and l.source_system = 'jobber' and l.source_id = j.jobber_id)
                     and not exists (select 1 from hr.jobber_user_ignores i where i.jobber_id = j.jobber_id and i.cleared_at is null)),
    'differences', (select coalesce(jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) || p.v order by e.full_name), '[]'::jsonb)
                      from public.employees e
                     cross join lateral (select hr.fn_jobber_person(e.id) v) p
                     where p.v->>'state' in ('not_in_jobber', 'jobber_user_missing', 'deactivated_in_jobber', 'active_in_jobber')));
end $function$;
REVOKE ALL ON FUNCTION hr.get_jobber_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.get_jobber_people() TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.set_jobber_user_ignored(p_jobber_id text, p_ignored boolean, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-26_1700: admins mark a Jobber user as "not a staff member" (hidden from the Add list), or clear the mark.
declare v_caller bigint; v_level text; v_by text;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin']) c;
  perform hr.fn_require_app('hr', 'edit');
  select x.email into v_by from auth.users x where x.id = auth.uid();
  if not exists (select 1 from hr.jobber_users j where j.jobber_id = p_jobber_id) then
    raise exception 'That Jobber user was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=jobber_user_not_found';
  end if;
  if p_ignored then
    if nullif(btrim(coalesce(p_reason, '')), '') is null then
      raise exception 'Say why this is not a staff member. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_required';
    end if;
    insert into hr.jobber_user_ignores (jobber_id, reason, set_by) values (p_jobber_id, btrim(p_reason), v_by)
    on conflict (jobber_id) do update set reason = excluded.reason, set_by = excluded.set_by, set_at = now(),
                                          cleared_at = null, cleared_by = null;
  else
    update hr.jobber_user_ignores set cleared_at = now(), cleared_by = v_by where jobber_id = p_jobber_id and cleared_at is null;
  end if;
  return jsonb_build_object('ok', true, 'jobber_id', p_jobber_id, 'ignored', p_ignored);
end $function$;
REVOKE ALL ON FUNCTION hr.set_jobber_user_ignored(text, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.set_jobber_user_ignored(text, boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
-- Splices (live bodies, one anchor each, asserted once)
DO $s$
DECLARE d text; a text; n text;
BEGIN
  -- the request wrapper: one more allow-listed target
  d := pg_get_functiondef('public.fn_request_jobber_sync(text)'::regprocedure);
  a := E'    WHEN ''timesheets-window'' THEN ''https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-timesheets?mode=window&days=35''\n';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: fn_request_jobber_sync anchor'; END IF;
  n := a || E'    -- 2026-10-26_1700 (new hires): Jobber''s team list into hr.jobber_users\n'
         || E'    WHEN ''users''         THEN ''https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-users''\n';
  EXECUTE replace(d, a, n);

  -- the sync watchdog: one more source
  d := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  a := E'      (''jobber_timesheets_window'',      interval ''26 hours''),\n';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: log_jobber_sync_health anchor'; END IF;
  n := a || E'      -- 2026-10-26_1700 (new hires): Jobber''s team list, every 15 minutes\n'
         || E'      (''jobber_users'',                  interval ''45 minutes''),\n';
  EXECUTE replace(d, a, n);

  -- the access health: Jobber differences older than a day
  d := pg_get_functiondef('public.log_access_health()'::regprocedure);
  a := E'  n := jsonb_array_length(v_items);';   -- no line ending: this body was created with CRLF line endings
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: log_access_health anchor'; END IF;
  n := E'  -- 2026-10-26_1700 (new hires): the HR App and Jobber out of step for more than a day (Jobber cannot be written by\n'
    || E'  -- the API, so a person does it; the HR App shows the same line on the person''s page)\n'
    || E'  select v_items || coalesce(jsonb_agg(jsonb_build_object(''kind'', ''access:jobber_'' || (p.v->>''state'') || '':e'' || e.id,\n'
    || E'           ''issue'', ''jobber_'' || (p.v->>''state''), ''employee_id'', e.id,\n'
    || E'           ''reason'', case p.v->>''state''\n'
    || E'             when ''not_in_jobber'' then format(''%s is active in the HR App but not in Jobber.'', e.full_name)\n'
    || E'             when ''jobber_user_missing'' then format(''%s is linked to a Jobber user that Jobber no longer lists.'', e.full_name)\n'
    || E'             when ''deactivated_in_jobber'' then format(''%s is active in the HR App but deactivated in Jobber.'', e.full_name)\n'
    || E'             else format(''%s is inactive in the HR App but still active in Jobber.'', e.full_name) end,\n'
    || E'           ''what_to_do'', case p.v->>''state''\n'
    || E'             when ''not_in_jobber'' then ''Add them in Jobber (Manage Team) with the same email; they link by themselves within 15 minutes.''\n'
    || E'             when ''active_in_jobber'' then ''Deactivate them in Jobber (Manage Team), or set them back to Active in the HR App.''\n'
    || E'             else ''Open their page in the HR App and follow the Jobber line.'' end)\n'
    || E'           order by e.id), ''[]''::jsonb)\n'
    || E'    into v_items from public.employees e\n'
    || E'   cross join lateral (select hr.fn_jobber_person(e.id) v) p\n'
    || E'   where p.v->>''state'' in (''not_in_jobber'', ''jobber_user_missing'', ''deactivated_in_jobber'', ''active_in_jobber'')\n'
    || E'     and coalesce(e.updated_at, e.created_at) < now() - interval ''1 day''\n'
    || E'     and (select max(seen_at) from hr.jobber_users) > now() - interval ''2 hours'';\n'
    || E'  select v_items || coalesce(jsonb_agg(jsonb_build_object(''kind'', ''access:jobber_not_in_hr:'' || j.jobber_id,\n'
    || E'           ''issue'', ''jobber_not_in_hr'', ''jobber_id'', j.jobber_id,\n'
    || E'           ''reason'', format(''%s is in Jobber (%s) but not in the HR App.'', coalesce(j.full_name, ''A Jobber user''), lower(j.status)),\n'
    || E'           ''what_to_do'', ''In the HR App (Employees), add them, or mark them as not a staff member.'')\n'
    || E'           order by j.full_name), ''[]''::jsonb)\n'
    || E'    into v_items from hr.jobber_users j\n'
    || E'   where j.removed_at is null and j.status <> ''DEACTIVATED'' and j.first_seen_at < now() - interval ''1 day''\n'
    || E'     and not exists (select 1 from public.entity_source_links l\n'
    || E'                      where l.entity_type = ''employee'' and l.source_system = ''jobber'' and l.source_id = j.jobber_id)\n'
    || E'     and not exists (select 1 from hr.jobber_user_ignores i where i.jobber_id = j.jobber_id and i.cleared_at is null);\n'
    || a;
  EXECUTE replace(d, a, n);
END $s$;

SELECT cron.schedule('sync-jobber-users', '*/15 * * * *', $c$select public.fn_request_jobber_sync('users')$c$);

-- ---------------------------------------------------------------------------------------------------------------------
-- VERIFY
DO $v$
DECLARE r jsonb; n int; v jsonb; u text;
BEGIN
  IF EXISTS (SELECT 1 FROM nh_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: the privileges of a spliced function moved'; END IF;
  IF has_table_privilege('authenticated', 'hr.jobber_users', 'SELECT') OR has_table_privilege('anon', 'hr.jobber_users', 'SELECT')
     OR has_table_privilege('authenticated', 'hr.jobber_user_ignores', 'SELECT') THEN
    RAISE EXCEPTION 'verify: a mirror table is readable by an app role'; END IF;
  IF has_function_privilege('authenticated', 'hr.sync_jobber_users(jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.get_jobber_people()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_jobber_person(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify: a function is executable by the wrong role'; END IF;
  -- the url helper on Jerald's id (Serena's link was manage_team/NDQ0ODI3OA==)
  u := hr.fn_jobber_user_url('Z2lkOi8vSm9iYmVyL1VzZXIvNDQ0ODI3OA==');
  IF u <> 'https://secure.getjobber.com/manage_team/NDQ0ODI3OA==' THEN RAISE EXCEPTION 'verify: url %', u; END IF;
  IF hr.fn_jobber_user_url('garbage!') <> 'https://secure.getjobber.com/manage_team' THEN RAISE EXCEPTION 'verify: url fallback'; END IF;
  -- an empty list is refused
  BEGIN PERFORM hr.sync_jobber_users('[]'::jsonb); RAISE EXCEPTION 'verify: empty list accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  -- the linker, inside a block that is undone: a fake person with a fake Jobber user of the same email links; a second
  -- Jobber user with the same email stops it
  BEGIN
    INSERT INTO public.employees (id, full_name, email, status, access_level) OVERRIDING SYSTEM VALUE
      VALUES (990101, 'ZZ Linker Probe', 'zz.linker.probe@example.com', 'ACTIVE', 'field');
    r := hr.sync_jobber_users('[{"id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDE=","name":{"full":"ZZ Linker Probe"},"email":{"raw":"ZZ.Linker.Probe@example.com"},"status":"SEND_INVITE"}]'::jsonb);
    IF jsonb_array_length(r->'linked') <> 1 OR (r->'linked'->0->>'employee_id')::bigint <> 990101 THEN RAISE EXCEPTION 'verify: link %', r; END IF;
    v := hr.fn_jobber_person(990101);
    IF v->>'state' <> 'in_step' OR v->>'url' <> hr.fn_jobber_user_url('Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDE=') THEN RAISE EXCEPTION 'verify: person %', v; END IF;
    UPDATE public.employees SET status = 'INACTIVE' WHERE id = 990101;
    IF hr.fn_jobber_person(990101)->>'state' <> 'active_in_jobber' THEN RAISE EXCEPTION 'verify: inactive here, active there'; END IF;
    -- control: a second person whose email is on two Jobber users is not linked
    INSERT INTO public.employees (id, full_name, email, status, access_level) OVERRIDING SYSTEM VALUE
      VALUES (990102, 'ZZ Linker Probe 2', 'zz.linker.two@example.com', 'ACTIVE', 'field');
    r := hr.sync_jobber_users('[{"id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDI=","name":{"full":"A"},"email":{"raw":"zz.linker.two@example.com"},"status":"ACTIVATED"},
                               {"id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDM=","name":{"full":"B"},"email":{"raw":"zz.linker.two@example.com"},"status":"ACTIVATED"}]'::jsonb);
    IF jsonb_array_length(r->'linked') <> 0 THEN RAISE EXCEPTION 'verify: a shared email linked: %', r; END IF;
    IF hr.fn_jobber_person(990102)->>'state' <> 'not_in_jobber' THEN RAISE EXCEPTION 'verify: not_in_jobber'; END IF;
    -- a list under half of what we hold skips removals
    r := hr.sync_jobber_users('[{"id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDI=","name":{"full":"A"},"email":{"raw":"zz.linker.two@example.com"},"status":"ACTIVATED"}]'::jsonb);
    IF (r->>'removed')::int <> 1 OR (r->'removals_skipped')::boolean THEN RAISE EXCEPTION 'verify: removal %', r; END IF;
    INSERT INTO hr.jobber_users (jobber_id, status) SELECT 'probe' || g, 'ACTIVATED' FROM generate_series(1, 6) g;
    r := hr.sync_jobber_users('[{"id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MDI=","name":{"full":"A"},"email":{"raw":"zz.linker.two@example.com"},"status":"ACTIVATED"}]'::jsonb);
    IF NOT (r->'removals_skipped')::boolean OR (r->>'removed')::int <> 0 THEN RAISE EXCEPTION 'verify: a short list removed users %', r; END IF;
    -- the spliced bodies run (PL/pgSQL is parsed only when executed)
    PERFORM public.log_access_health();
    PERFORM public.log_jobber_sync_health();
    RAISE EXCEPTION 'nh_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'nh_undo' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.employees WHERE id IN (990101, 990102)) OR EXISTS (SELECT 1 FROM hr.jobber_users) THEN
    RAISE EXCEPTION 'verify: a probe row was left behind'; END IF;
  -- the spliced bodies carry their new lines and still run
  IF pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure) NOT LIKE '%(''jobber_users'',%' THEN RAISE EXCEPTION 'verify: watchdog'; END IF;
  IF pg_get_functiondef('public.log_access_health()'::regprocedure) NOT LIKE '%access:jobber_not_in_hr:%' THEN RAISE EXCEPTION 'verify: access health'; END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'sync-jobber-users' AND schedule = '*/15 * * * *') <> 1 THEN RAISE EXCEPTION 'verify: cron'; END IF;
  RAISE NOTICE 'hr.jobber_users mirror installed; linker, person line and health lines checked';
END $v$;

COMMIT;
