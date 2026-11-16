-- =====================================================================================================================
-- HR SANDBOX (klgtrdwrasrlxbmfyvdh) ONLY. NEVER RUN ON PROD. The guard refuses a database that has schema `derm`.
-- 2026-11-16 (evening), Trello #211: Yannick's Claude reaches his frozen_leads over HTTPS.
--
-- Why: his Claude (claude.ai) "only passes web traffic, and the Postgres connection was dropped on every route I tried"
-- (his screenshot, sent by Fred). The login of 2026-11-16b works from a computer, not from that chat. So one HTTPS call
-- now runs his SQL with EXACTLY his login's rights: read, write and change tables in frozen_leads, nothing else.
--
-- THE SHAPE, AND WHY EACH PART IS THERE
--   * leads_rpc.run(query text) -> jsonb. PostgREST: POST /rest/v1/rpc/run, header Content-Profile: leads_rpc.
--   * leads_caller (NOLOGIN): the role the HTTPS key carries. It may only USE schema leads_rpc and EXECUTE run().
--     Granted to authenticator so PostgREST can switch to it. It holds no table and creates nothing.
--   * leads_runner (NOLOGIN): OWNS run(), which is SECURITY DEFINER, so the SQL runs as leads_runner. It is a member
--     of yannick_leads (INHERIT, SET), so it has exactly his rights.
--   * 🛑 THE TRAP THIS CLOSES: inside a PostgREST request the SESSION user is `authenticator`, which may SET ROLE to
--     service_role. Arbitrary SQL run as the caller could therefore do `set role service_role` (or
--     `set_config('role', ...)`) and read or write everything. Postgres refuses SET ROLE, RESET ROLE and
--     set_config('role') inside a SECURITY DEFINER function, which is why run() is one.
--   * 🛑 AND THE SECOND TRAP: the owner of a function may ALTER it, e.g. back to SECURITY INVOKER, which reopens the
--     first trap. So nobody who can run SQL through it can NAME it: leads_runner, yannick_leads and leads_caller-in-SQL
--     hold no USAGE on schema leads_rpc except leads_caller, and leads_caller is not reachable from inside run()
--     (leads_runner is not a member of it, and SET ROLE is refused there). Without USAGE the name lookup fails.
--   * Anything a call creates is owned by leads_runner; run() hands it to yannick_leads before it returns, so his own
--     login can manage it too.
--   * No table is exposed to the API. The project's public key can reach nothing here.
--
-- run() RETURNS {"ok": true, "row_count": n, "rows": [...]} for a SELECT / WITH / VALUES / TABLE statement or anything
-- with RETURNING, and {"ok": true, "row_count": n} for everything else (INSERT, UPDATE, DELETE, CREATE, ALTER, DROP).
-- One statement per call for SELECT-like statements; an error comes back as an HTTP 4xx with Postgres's message, and
-- the whole call is undone.
--
-- UNDO, in order:
--   1. revoke leads_caller from authenticator;   -- the kill switch: the HTTPS key is refused at the next request
--   2. drop schema leads_rpc cascade; drop role leads_caller;
--      revoke yannick_leads from leads_runner; drop owned by leads_runner; drop role leads_runner;
--   3. PATCH /v1/projects/klgtrdwrasrlxbmfyvdh/postgrest {"db_schema": "public,graphql_public"}
-- RUN: one string through the Management API (implicit transaction; the VERIFY raises to undo it all).
-- =====================================================================================================================

do $guard$
begin
  if exists (select 1 from pg_namespace where nspname = 'derm') then
    raise exception 'refusing: schema derm exists, this looks like Prod';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'yannick_leads') then
    raise exception 'refusing: role yannick_leads is missing (run 2026-11-16b first)';
  end if;
  if exists (select 1 from pg_namespace where nspname = 'leads_rpc')
     or exists (select 1 from pg_roles where rolname in ('leads_runner', 'leads_caller')) then
    raise exception 'refusing: leads_rpc, leads_runner or leads_caller already exists';
  end if;
end
$guard$;

create role leads_runner nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
comment on role leads_runner is 'Owns leads_rpc.run (SECURITY DEFINER): runs Yannick''s SQL with exactly yannick_leads''s rights (Trello #211).';
grant yannick_leads to leads_runner with inherit true, set true;
grant leads_runner to postgres with inherit false, set true;   -- only so postgres may give it the function below

create role leads_caller nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
comment on role leads_caller is 'The role of Yannick''s HTTPS key: may only call leads_rpc.run (Trello #211). Kill switch: revoke leads_caller from authenticator.';
alter role leads_caller set statement_timeout = '60s';
grant leads_caller to authenticator with inherit false, set true;

create schema leads_rpc;
comment on schema leads_rpc is 'One function, run(query), for Yannick''s Claude over HTTPS (Trello #211). Only leads_caller may use it. Undo: Supabase docs/sandbox/2026-11-17_frozen_leads_https_run.sql.';
revoke all on schema leads_rpc from public;

create function leads_rpc.run(query text)
returns jsonb
language plpgsql
security definer
set search_path = frozen_leads, public, extensions
as $fn$
declare
  q   text := btrim(coalesce(query, ''), E' \t\r\n;');
  res jsonb;
  n   bigint;
  o   record;
begin
  if q = '' then
    raise exception 'empty query' using errcode = '22023';
  end if;

  if q ~* '^(select|with|values|table)([[:space:]]|[(])' or q ~* '[[:<:]]returning[[:>:]]' then
    execute format('with _q as (%s) select coalesce(jsonb_agg(to_jsonb(_q)), ''[]''::jsonb) from _q', q) into res;
    n := jsonb_array_length(res);
  else
    execute q;
    get diagnostics n = row_count;
  end if;

  -- Whatever this call created in frozen_leads belongs to Yannick's login, not to the runner.
  for o in
    select format('alter %s frozen_leads.%I owner to yannick_leads',
                  case c.relkind when 'v' then 'view' when 'm' then 'materialized view' when 'S' then 'sequence'
                                 when 'f' then 'foreign table' else 'table' end, c.relname) stmt
      from pg_catalog.pg_class c join pg_catalog.pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'frozen_leads' and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
       and c.relowner = 'leads_runner'::regrole
       and not (c.relkind = 'S' and exists (select 1 from pg_catalog.pg_depend d
                                             where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype in ('a', 'i')))
    union all
    select format('alter routine %s owner to yannick_leads', p.oid::regprocedure)
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'frozen_leads' and p.proowner = 'leads_runner'::regrole
    union all
    select format('alter type frozen_leads.%I owner to yannick_leads', t.typname)
      from pg_catalog.pg_type t join pg_catalog.pg_namespace s on s.oid = t.typnamespace
     where s.nspname = 'frozen_leads' and t.typowner = 'leads_runner'::regrole and t.typtype in ('e', 'c', 'd')
       and not exists (select 1 from pg_catalog.pg_class c where c.reltype = t.oid)
  loop
    execute o.stmt;
  end loop;

  return case when res is null then jsonb_build_object('ok', true, 'row_count', n)
              else jsonb_build_object('ok', true, 'row_count', n, 'rows', res) end;
end
$fn$;
-- Grants BEFORE the owner change: only the owner can revoke, so a revoke issued by postgres after the hand-over does
-- nothing (the second rehearsal caught exactly that).
revoke all on function leads_rpc.run(text) from public, anon, authenticated, service_role;
grant execute on function leads_rpc.run(text) to leads_caller;
grant usage on schema leads_rpc to leads_caller;
-- A new owner must hold CREATE on the function's schema at the moment of the change; taken back straight after
-- (the first rehearsal refused with 42501 without it).
grant create on schema leads_rpc to leads_runner;
alter function leads_rpc.run(text) owner to leads_runner;
revoke all on schema leads_rpc from leads_runner;

do $verify$
declare
  l text;
begin
  if exists (select 1 from pg_roles where rolname in ('leads_runner', 'leads_caller')
              and (rolcanlogin or rolsuper or rolcreaterole or rolcreatedb or rolreplication or rolbypassrls)) then
    raise exception 'VERIFY: leads_runner or leads_caller has a special attribute';
  end if;
  -- leads_caller belongs to no role; leads_runner belongs only to yannick_leads.
  if exists (select 1 from pg_auth_members m where m.member = 'leads_caller'::regrole) then
    raise exception 'VERIFY: leads_caller is a member of a role';
  end if;
  if (select array_agg(roleid::regrole::text) from pg_auth_members where member = 'leads_runner'::regrole) <> array['yannick_leads'] then
    raise exception 'VERIFY: leads_runner must be a member of yannick_leads only';
  end if;
  if not pg_has_role('authenticator', 'leads_caller', 'SET') then
    raise exception 'VERIFY: authenticator cannot switch to leads_caller';
  end if;

  -- Nobody who can run SQL through run() can name it: no USAGE on leads_rpc except leads_caller.
  select string_agg(r, ', ') into l from unnest(array['leads_runner', 'yannick_leads', 'anon', 'authenticated', 'service_role', 'public']) r
   where has_schema_privilege(r, 'leads_rpc', 'USAGE') or has_schema_privilege(r, 'leads_rpc', 'CREATE');
  if l is not null then raise exception 'VERIFY: may use schema leads_rpc: %', l; end if;
  if not has_schema_privilege('leads_caller', 'leads_rpc', 'USAGE') then raise exception 'VERIFY: leads_caller cannot use leads_rpc'; end if;
  if has_schema_privilege('leads_caller', 'leads_rpc', 'CREATE') then raise exception 'VERIFY: leads_caller may create in leads_rpc'; end if;

  -- run(): owned by leads_runner, SECURITY DEFINER, pinned search_path, callable by leads_caller only.
  if not exists (select 1 from pg_proc p where p.oid = 'leads_rpc.run(text)'::regprocedure
                  and p.proowner = 'leads_runner'::regrole and p.prosecdef
                  and p.proconfig @> array['search_path=frozen_leads, public, extensions']) then
    raise exception 'VERIFY: run() owner, security mode or search_path is wrong';
  end if;
  -- (leads_runner owns it, so it always may; nothing reaches leads_runner except run() itself.)
  select string_agg(r, ', ') into l from unnest(array['public', 'anon', 'authenticated', 'service_role', 'yannick_leads']) r
   where has_function_privilege(r, 'leads_rpc.run(text)', 'EXECUTE');
  if l is not null then raise exception 'VERIFY: may execute run(): %', l; end if;
  if not has_function_privilege('leads_caller', 'leads_rpc.run(text)', 'EXECUTE') then raise exception 'VERIFY: leads_caller cannot execute run()'; end if;

  -- leads_caller reaches no table or view anywhere, and creates nowhere (a session's own temp area aside).
  select string_agg(s.nspname || '.' || c.relname, ', ') into l from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname not in ('pg_catalog', 'information_schema') and has_schema_privilege('leads_caller', s.oid, 'USAGE')
     and c.relkind in ('r','v','m','p','f')
     and (has_table_privilege('leads_caller', c.oid, 'SELECT') or has_table_privilege('leads_caller', c.oid, 'INSERT')
       or has_table_privilege('leads_caller', c.oid, 'UPDATE') or has_table_privilege('leads_caller', c.oid, 'DELETE'));
  if l is not null then raise exception 'VERIFY: leads_caller reaches: %', l; end if;
  select string_agg(nspname, ', ') into l from pg_namespace
   where has_schema_privilege('leads_caller', oid, 'CREATE') and nspname !~ '^pg_(toast_)?temp_';
  if l is not null then raise exception 'VERIFY: leads_caller may create in: %', l; end if;
  -- Control: the same reach test finds something for a role that has it.
  if not exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                  where s.nspname = 'public' and has_schema_privilege('anon', s.oid, 'USAGE') and has_table_privilege('anon', c.oid, 'SELECT')) then
    raise exception 'VERIFY control: anon reaches nothing in public, so the reach test proves nothing';
  end if;

  -- leads_runner has his rights (inherited), so run() can do what his login does.
  if not (has_table_privilege('leads_runner', 'frozen_leads.gdo_universe', 'SELECT,INSERT,UPDATE,DELETE')
          and has_schema_privilege('leads_runner', 'frozen_leads', 'CREATE')) then
    raise exception 'VERIFY: leads_runner lacks yannick_leads''s rights';
  end if;
end
$verify$;
