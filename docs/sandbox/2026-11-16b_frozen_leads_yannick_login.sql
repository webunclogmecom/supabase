-- =====================================================================================================================
-- HR SANDBOX (klgtrdwrasrlxbmfyvdh) ONLY. NEVER RUN ON PROD. The guard refuses a database that has schema `derm`.
-- 2026-11-16, Trello #211 (nG6FjqsT): Yannick gets his OWN database login that can read, write and change the structure
-- of `frozen_leads` (his Miami-Dade prospecting data), and nothing else. Replaces the read-only key of
-- 2026-11-16_leads_api_read_only.sql, which was built and tested the same afternoon and never handed over.
--
-- Fred: "can we make the API so he can read/write ? he will make a lot changes to the DB", then, asked what kind of
-- changes: "Tables too, on the HR Sandbox" (a database login that can change only the frozen_leads schema).
--
-- WHAT THIS DOES
--   1. Removes the read-only key: role leads_reader and schema leads_api. Its views would block his column changes
--      ("other objects depend on it") and he would not own them. The PostgREST db_schema change is NOT SQL: the runner
--      sets it back to "public,graphql_public" BEFORE this file runs.
--   2. Creates login role yannick_leads (5 connections at most, 60 s statement timeout, search_path frozen_leads first).
--      The password arrives ONLY as a SCRAM-SHA-256 verifier (app.yl_verifier, set by the runner): this project logs
--      every DDL request in full (log_statement = ddl), so a plain password would be written to the server log. The
--      verifier may be logged; that is the form Postgres stores anyway, and it cannot be used to log in.
--   3. Hands him every object in frozen_leads (13 tables and their sequences and indexes, 6 views, 16 functions,
--      7 enum types) EXCEPT view v_active_clients, which reads OUR client list (public.clients, public.properties); he
--      gets SELECT on it. He gets USAGE and CREATE on the schema, not the schema itself.
--   4. postgres becomes a member of yannick_leads (INHERIT, SET), so our admin login keeps full rights on his objects
--      (the Management API, the dashboard, backups) and his SECURITY DEFINER functions keep working.
--   5. Takes CREATE on schema public away from PUBLIC (it was `=UC/postgres`, the pre-PG15 default), so a login
--      that holds no grant of its own cannot create objects in public. Measured first: anon, authenticated and
--      service_role held CREATE there only through PUBLIC; the API cannot run DDL for them and no function does;
--      postgres (owner) and supabase_admin keep it.
--
-- BACKUP BEFORE: workspace backups/2026-11-16_hr_sandbox_frozen_leads_before_yannick_login.json (every row of the 13
-- tables, columns, constraints, indexes, triggers, 42 policies, views, functions, enums, owners, grants, sequences).
--
-- KNOWN AND ACCEPTED
--   * A table owner's triggers run with the rights of whoever writes the row. So no session writes to frozen_leads as
--     postgres from now on (nothing does today: the HR refresh script never touches it, and it is not exposed to the
--     API). Read freely.
--   * He can grant his own tables to anon/authenticated, but frozen_leads is not exposed to the API, so nothing reaches
--     them that way.
--   * Three of his tables keep their audit triggers (contacts, gdo_universe, hours_of_operation -> audit.log_change,
--     SECURITY DEFINER), so their row changes stay recoverable from audit.logs. He may drop them; it is his data.
--
-- RUN: one string through the Management API (implicit transaction; any RAISE undoes it all), with the runner's
-- `select set_config('app.yl_verifier', '<SCRAM verifier>', true);` in front. No BEGIN / COMMIT on purpose.
--
-- UNDO (does not restore data: for that, the backup above):
--   1. THE KILL SWITCH IS BOTH LINES. Rehearsed 2026-11-16: NOLOGIN alone did NOT cut him off, because the pooler
--      (Supavisor, session mode) handed back a connection it already held; a login is checked only when a new
--      connection is made. With the second line a new connection is refused (XX000), and LOGIN lets it back in.
--      alter role yannick_leads nologin;
--      select pg_terminate_backend(pid) from pg_stat_activity where usename = 'yannick_leads';
--   2. To give the objects back: for each object in frozen_leads, alter ... owner to postgres; then
--      revoke yannick_leads from postgres; drop owned by yannick_leads; drop role yannick_leads;
--   3. grant create on schema public to public;    -- only if something turns out to have needed it
-- =====================================================================================================================

do $guard$
begin
  if exists (select 1 from pg_namespace where nspname = 'derm') then
    raise exception 'refusing: schema derm exists, this looks like Prod';
  end if;
  if not exists (select 1 from pg_namespace where nspname = 'frozen_leads') then
    raise exception 'refusing: schema frozen_leads is missing, wrong project?';
  end if;
  if exists (select 1 from pg_roles where rolname = 'yannick_leads') then
    raise exception 'refusing: role yannick_leads already exists';
  end if;
  if coalesce(current_setting('app.yl_verifier', true), '') !~ '^SCRAM-SHA-256\$4096:' then
    raise exception 'refusing: app.yl_verifier is not a SCRAM-SHA-256 verifier (never send a plain password here)';
  end if;
end
$guard$;

-- Who may create in public BEFORE, kept for the comparison in VERIFY.
create temp table _public_create_before on commit drop as
  select r.rolname, has_schema_privilege(r.oid, 'public', 'CREATE') can_create from pg_roles r;

-- 1. The read-only key goes.
do $drop_reader$
begin
  if exists (select 1 from pg_roles where rolname = 'leads_reader') then
    execute 'revoke leads_reader from authenticator';
  end if;
end
$drop_reader$;
drop schema if exists leads_api cascade;
drop role if exists leads_reader;

-- 2. His login. The verifier is read inside the block, so the logged statement never carries it.
do $create_login$
begin
  execute format('create role yannick_leads login nosuperuser nocreatedb nocreaterole noreplication nobypassrls '
                 'connection limit 5 password %L', current_setting('app.yl_verifier'));
end
$create_login$;
comment on role yannick_leads is
  'Yannick''s own login: reads, writes and changes the structure of frozen_leads only (Trello #211, 2026-11-16). '
  'Kill switch: alter role yannick_leads nologin.';
alter role yannick_leads set statement_timeout = '60s';
alter role yannick_leads set search_path = frozen_leads, public, extensions;
grant yannick_leads to postgres with inherit true, set true;
grant usage, create on schema frozen_leads to yannick_leads;

-- 3. Hand over every object in frozen_leads except v_active_clients.
do $hand_over$
declare
  r record;
begin
  for r in select c.oid, c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'frozen_leads' and c.relkind in ('r', 'p', 'v', 'm', 'f') and c.relname <> 'v_active_clients'
            order by c.relkind, c.relname loop
    execute format('alter %s frozen_leads.%I owner to yannick_leads',
                   case r.relkind when 'v' then 'view' when 'm' then 'materialized view' when 'f' then 'foreign table' else 'table' end,
                   r.relname);
  end loop;
  -- Sequences not tied to a column (tied ones moved with their table).
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'frozen_leads' and c.relkind = 'S' and pg_get_userbyid(c.relowner) <> 'yannick_leads' loop
    execute format('alter sequence frozen_leads.%I owner to yannick_leads', r.relname);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'frozen_leads' loop
    execute format('alter routine %s owner to yannick_leads', r.sig);
  end loop;
  for r in select t.typname from pg_type t join pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'frozen_leads' and t.typtype in ('e', 'c', 'd')
              and not exists (select 1 from pg_class c where c.reltype = t.oid) loop
    execute format('alter type frozen_leads.%I owner to yannick_leads', r.typname);
  end loop;
end
$hand_over$;
grant select on frozen_leads.v_active_clients to yannick_leads;

-- 5. No creating in public through PUBLIC.
revoke create on schema public from public;

do $verify$
declare
  n int;
  l text;
begin
  -- The login: can log in, holds no special power, belongs to no role.
  if not exists (select 1 from pg_roles where rolname = 'yannick_leads' and rolcanlogin and not rolsuper and not rolcreaterole
                  and not rolcreatedb and not rolreplication and not rolbypassrls and rolconnlimit = 5) then
    raise exception 'VERIFY: yannick_leads attributes are wrong';
  end if;
  if exists (select 1 from pg_auth_members m join pg_roles r on r.oid = m.member where r.rolname = 'yannick_leads') then
    raise exception 'VERIFY: yannick_leads is a member of another role';
  end if;

  -- Ownership: everything in frozen_leads is his, except v_active_clients.
  select string_agg(x, ', ') into l from (
    select c.relname x from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'frozen_leads' and c.relkind in ('r','p','v','m','f','S','i') and c.relname <> 'v_active_clients'
       and pg_get_userbyid(c.relowner) <> 'yannick_leads'
    union all select p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'frozen_leads' and pg_get_userbyid(p.proowner) <> 'yannick_leads'
    union all select t.typname from pg_type t join pg_namespace s on s.oid = t.typnamespace
     where s.nspname = 'frozen_leads' and t.typtype in ('e','c','d') and not exists (select 1 from pg_class c where c.reltype = t.oid)
       and pg_get_userbyid(t.typowner) <> 'yannick_leads') q;
  if l is not null then raise exception 'VERIFY: not handed over: %', l; end if;
  if (select pg_get_userbyid(c.relowner) from pg_class c join pg_namespace s on s.oid = c.relnamespace
       where s.nspname = 'frozen_leads' and c.relname = 'v_active_clients') <> 'postgres' then
    raise exception 'VERIFY: v_active_clients must stay ours';
  end if;

  -- Reach: outside frozen_leads he reaches no table or view, and he can create only in frozen_leads.
  select string_agg(s.nspname || '.' || c.relname, ', ') into l from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname not in ('frozen_leads', 'pg_catalog', 'information_schema')
     and has_schema_privilege('yannick_leads', s.oid, 'USAGE') and c.relkind in ('r','v','m','p','f')
     and (has_table_privilege('yannick_leads', c.oid, 'SELECT') or has_table_privilege('yannick_leads', c.oid, 'INSERT')
       or has_table_privilege('yannick_leads', c.oid, 'UPDATE') or has_table_privilege('yannick_leads', c.oid, 'DELETE'));
  if l is not null then raise exception 'VERIFY: yannick_leads reaches outside frozen_leads: %', l; end if;
  select string_agg(nspname, ', ') into l from pg_namespace
   where has_schema_privilege('yannick_leads', oid, 'CREATE') and nspname <> 'frozen_leads'
     and nspname !~ '^pg_(toast_)?temp_';   -- a session's own temp area (TEMP is a database default; gone at disconnect)
  if l is not null then raise exception 'VERIFY: yannick_leads may create in: %', l; end if;
  -- Control: the same reach test finds something for a role that has it (anon reads public tables here).
  if not exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                  where s.nspname = 'public' and has_schema_privilege('anon', s.oid, 'USAGE')
                    and has_table_privilege('anon', c.oid, 'SELECT')) then
    raise exception 'VERIFY control: anon reaches nothing in public, so the reach test above proves nothing';
  end if;

  -- He can write and change his tables (privilege view; the live login test does it for real).
  if not (has_table_privilege('yannick_leads', 'frozen_leads.gdo_universe', 'SELECT,INSERT,UPDATE,DELETE')
          and has_schema_privilege('yannick_leads', 'frozen_leads', 'CREATE')
          and has_table_privilege('yannick_leads', 'frozen_leads.v_active_clients', 'SELECT')) then
    raise exception 'VERIFY: yannick_leads lacks rights on frozen_leads';
  end if;

  -- Our admin login still reads and owns through membership.
  if not pg_has_role('postgres', 'yannick_leads', 'USAGE') then raise exception 'VERIFY: postgres does not inherit yannick_leads'; end if;
  select count(*) into n from frozen_leads.gdo_universe;
  if n <> 9890 then raise exception 'VERIFY: postgres reads % rows of gdo_universe, expected 9890', n; end if;

  -- The read-only key is gone.
  if exists (select 1 from pg_namespace where nspname = 'leads_api') or exists (select 1 from pg_roles where rolname = 'leads_reader') then
    raise exception 'VERIFY: leads_api or leads_reader still exists';
  end if;

  -- public: nobody gained CREATE; PUBLIC lost it; postgres kept it. List who lost it, for the record.
  if has_schema_privilege('public', 'public', 'CREATE') then raise exception 'VERIFY: PUBLIC still creates in public'; end if;
  if not has_schema_privilege('postgres', 'public', 'CREATE') then raise exception 'VERIFY: postgres lost CREATE on public'; end if;
  if exists (select 1 from _public_create_before b join pg_roles r on r.rolname = b.rolname
              where not b.can_create and has_schema_privilege(r.oid, 'public', 'CREATE')) then
    raise exception 'VERIFY: a role gained CREATE on public';
  end if;
end
$verify$;
