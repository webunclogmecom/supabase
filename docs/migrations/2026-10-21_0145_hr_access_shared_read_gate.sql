-- 2026-10-21_0145 ET · Access phase 6 (part 1): the shared lists close to anyone with no access anywhere
--
-- Fred, 2026-10-21: "go with the next phase" (plan Building Apps/HR App/docs/specs/2026-10-19-access-privileges-plan.md,
-- section 5 "Last phase": shared lists readable only by people with View in at least one app; a sign-in with no
-- access anywhere must read and change nothing).
--
-- WHY A PRE-REQUEST GATE AND NOT THE PLAN'S PER-TABLE POLICIES (measured before writing this):
--   authenticated can SELECT 65 tables AND 149 views in client / ops / derm / customer / public. The views are
--   postgres-owned without security_invoker, so they BYPASS RLS: narrowing the USING(true) policies on employees,
--   clients, properties, visits would have left nearly every list open. One PostgREST pre-request function covers
--   every table, view and RPC an app reads through the API, in one place.
--
-- WHAT IT DOES:
--   public.fn_request_gate() runs before every PostgREST request (pgrst.db_pre_request on the authenticator role).
--   - anon and service_role: passes (the Field Portal and DUMP are anon; edge functions with the server key do
--     their own checks).
--   - authenticated: passes while hr.fn_any_app_open() is true, else refuses 42501
--     "You do not have access to any UnclogMe app. Ask Fred or Yannick to change it." (DETAIL blocker=no_access app=any).
--   - /rpc/get_my_access always passes, so an app can still show its "You do not have access" card.
--   hr.fn_any_app_open(): true when the caller is service_role / has no claims, OR any top-level app is not 'on'
--   (an unchecked app does not refuse anyone, the same rule as hr.fn_app_open), OR the caller has View or Edit in at
--   least one top-level app that is 'on'.
--   => TODAY (HR on, six apps in watch) NOBODY IS REFUSED. The gate engages by itself the moment the last app switches
--      on (planned about 2026-10-28). That is deliberate: reads cannot be watched (a read-only request cannot log), so
--      the rehearsal below is the evidence, plus the rehearsal header.
--   Rehearsal header: a request carrying `x-access-rehearsal: all-on` is judged as if every app were on. It can only
--   make the gate STRICTER, never looser, so it is safe to leave in. Every response carries `x-access-gate: pass`
--   (proof the hook runs).
--
-- NOT COVERED (stated so nobody assumes otherwise): Storage objects (bucket policies, auth.uid() not null), Realtime
-- (the apps use broadcast invalidations only, no rows), edge functions that read with the server key on a user's behalf
-- (each checks hr.check_app_action already). pg_graphql is not installed.
--
-- KILL SWITCH (one statement, no deploy):
--   alter role authenticator reset pgrst.db_pre_request; notify pgrst, 'reload config';
-- Rollback file: 2026-10-21_rollback_hr_access_shared_read_gate.sql

BEGIN;

create or replace function hr.fn_any_app_open(p_all_on boolean default false)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
-- 2026-10-21_0145: true when the caller may read the shared lists (View in at least one checked app).
declare v_claims text := nullif(current_setting('request.jwt.claims', true), ''); v_emp bigint;
begin
  if v_claims is null or (v_claims::jsonb)->>'role' = 'service_role' then return true; end if;
  if not p_all_on and exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on') then
    return true;
  end if;
  v_emp := hr.fn_access_caller();
  if v_emp is null then return false; end if;
  return exists (select 1 from hr.fn_effective_access(v_emp) f
                  where f.parent is null and (p_all_on or f.mode = 'on') and f.level in ('view', 'edit'));
end $function$;

revoke all on function hr.fn_any_app_open(boolean) from public, anon;
grant execute on function hr.fn_any_app_open(boolean) to authenticated, service_role;

create or replace function public.fn_request_gate()
 returns void
 language plpgsql
 stable security invoker
 set search_path to ''
as $function$
-- 2026-10-21_0145: PostgREST pre-request gate (pgrst.db_pre_request). Access phase 6.
-- SECURITY INVOKER on purpose: current_user must be the request role (anon / authenticated / service_role);
-- inside a SECURITY DEFINER body current_user is the owner and the gate would pass everyone (caught by VERIFY).
declare v_path text; v_all_on boolean;
begin
  perform set_config('response.headers', '[{"x-access-gate": "pass"}]', true);
  if current_user is distinct from 'authenticated' then return; end if;
  v_path := coalesce(current_setting('request.path', true), '');
  if v_path in ('/rpc/get_my_access') then return; end if;
  v_all_on := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal', '') = 'all-on';
  if hr.fn_any_app_open(v_all_on) then return; end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$;

revoke all on function public.fn_request_gate() from public;
grant execute on function public.fn_request_gate() to anon, authenticated, service_role;

-- VERIFY (rolled back by the runner when rehearsing; on apply these must pass before commit)
do $verify$
declare
  r record; v_res text; v_fail text := '';
  -- name, auth uid, path, all_on, expected ('pass'|'refuse')
  cases text[][] := array[
    ['fred',       '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', '/clients',           'false', 'pass'],
    ['jon.v',      '8bdb9ba7-e917-466d-bdb1-c525dbf90194', '/clients',           'false', 'pass'],
    ['test.agent', '46ff7904-faef-45c2-8aa2-a5a185c042ec', '/clients',           'false', 'pass'],
    ['fred',       '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', '/clients',           'true',  'pass'],
    ['yannick',    '71e294b9-9898-4c21-a48d-d970e32d829c', '/clients',           'true',  'pass'],
    ['aaron',      '77d4c343-1e21-44eb-98ce-c221028d028a', '/clients',           'true',  'pass'],
    ['serena',     '5c5df96c-1924-410a-a996-e3e58c44e3c2', '/clients',           'true',  'pass'],
    ['diego',      'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8', '/clients',           'true',  'pass'],
    ['jon.v',      '8bdb9ba7-e917-466d-bdb1-c525dbf90194', '/clients',           'true',  'refuse'],
    ['unclogme@',  'ebd7aebe-d77d-4e18-a33d-00e1dc55be9f', '/v_calendar_visit',  'true',  'refuse'],
    ['test.agent', '46ff7904-faef-45c2-8aa2-a5a185c042ec', '/rpc/get_record_history', 'true', 'refuse'],
    ['jon.v',      '8bdb9ba7-e917-466d-bdb1-c525dbf90194', '/rpc/get_my_access', 'true',  'pass']
  ];
  i int;
begin
  for i in 1 .. array_length(cases, 1) loop
    perform set_config('request.jwt.claims', json_build_object('sub', cases[i][2], 'role', 'authenticated')::text, true);
    perform set_config('request.path', cases[i][3], true);
    perform set_config('request.headers', case when cases[i][4] = 'true' then '{"x-access-rehearsal":"all-on"}' else '{}' end, true);
    perform set_config('role', 'authenticated', true);
    begin
      perform public.fn_request_gate();
      v_res := 'pass';
    exception when insufficient_privilege then v_res := 'refuse';
    end;
    perform set_config('role', 'postgres', true);
    if v_res <> cases[i][5] then
      v_fail := v_fail || format(' [%s %s all_on=%s expected %s got %s]', cases[i][1], cases[i][3], cases[i][4], cases[i][5], v_res);
    end if;
  end loop;
  -- anon passes even all-on
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
  perform public.fn_request_gate();
  perform set_config('role', 'postgres', true);
  if v_fail <> '' then raise exception 'VERIFY failed:%', v_fail; end if;
  raise notice 'VERIFY ok: 12 cases + anon';
end $verify$;

COMMIT;

-- Enabled separately, after the commit (a role setting is not transactional with the function):
--   alter role authenticator set pgrst.db_pre_request to 'public.fn_request_gate';
--   notify pgrst, 'reload config';
