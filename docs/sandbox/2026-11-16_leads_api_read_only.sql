-- =====================================================================================================================
-- 🛑 SUPERSEDED THE SAME DAY by 2026-11-16b_frozen_leads_yannick_login.sql: Fred wanted Yannick to write and change
-- tables too, so schema leads_api and role leads_reader were DROPPED there and the key below no longer works. Kept as
-- the record of what was built and tested (28 of 28) and never handed over. Do not re-run it on top of the login.
-- HR SANDBOX (klgtrdwrasrlxbmfyvdh) ONLY. NEVER RUN ON PROD. The guard below refuses a database that has schema `derm`.
-- 2026-11-16, Trello #211 (nG6FjqsT): a read-only API key for Yannick to the Miami-Dade frozen leads.
--
-- Yannick (DM with Fred): "Also I want to connect the Supabase of the dade frozen leads to my cloud. How do I do that?"
-- Fred: "For the frozen leads, it's not on the main DB but a separate one, so let me provide you with a API Key for it",
-- then to Claude: "let's give him the api key with a read only".
--
-- WHERE THE LEADS ARE: schema `frozen_leads` on this project ("UnclogMe prospecting database: GDO permits, enrichment,
-- route density scoring. Master = DERM (Miami-Dade DERM portal). Created 2026-05-25."). Loaded 2026-05-26, last
-- written 2026-07-20. 9,890 GDO permits (`gdo_universe`), 2,367 opening hours, 9 segments, 8 tags; contacts, tasks,
-- activities and stage history are empty. The paused project named "frozen leads" (oodjstkceacbmznccgia, created the
-- same day, idle since) is NOT used.
--
-- WHY A SEPARATE SCHEMA, NOT `frozen_leads` ITSELF:
--   * `frozen_leads` is Yannick's and marked never-touch (docs/hr-sandbox.md). This file adds NO grant, policy or row
--     there.
--   * Exposing `frozen_leads` to the API would also open it to the project's public key: anon holds SELECT on
--     `v_active_clients` (OUR client list, a view, so no RLS stops it) and on four lead tables, and that key ships in
--     Yannick's apps. The views below are readable by `leads_reader` and nobody else.
--
-- WHAT IS LEFT OUT ON PURPOSE: `enrichment_log` (raw Google requests; 3 of 2,546 carry key-like text),
-- `automation_outbox` and `automations` (machinery), `crm_users` (empty; would hold staff emails), `v_my_tasks` (per
-- signed-in user), `v_active_clients` (our clients, not leads). Add a view here if Yannick asks for one.
--
-- WHY THE KEY CANNOT WRITE (measured 2026-11-16 before building): `leads_reader` gets SELECT on these views and nothing
-- else. No table in public, graphql_public or frozen_leads grants anything to PUBLIC. The 8 functions PUBLIC may run in
-- the exposed schemas are 6 trigger functions (the API cannot call them), public.gen_short_id (returns random text,
-- writes nothing) and graphql_public.graphql (pg_graphql is not installed). No dblink / http / pg_net extension.
--
-- THE KEY: a JWT with `"role": "leads_reader"`, signed with the project's legacy HS256 secret (still a "previously
-- used" signing key, so PostgREST still accepts it), 1 year. It is NOT in this repo: it was written to the workspace's
-- git-ignored `.local-secrets/` for Fred to hand over.
-- Also needed (not SQL): PostgREST `db_schema` = "public,graphql_public,leads_api" (Management API, PATCH /postgrest).
--
-- RUN: as ONE string through the Management API (one implicit transaction: the VERIFY below raises to undo it all).
-- No BEGIN / COMMIT on purpose.
--
-- UNDO, in order:
--   1. revoke leads_reader from authenticator;   -- the key stops working at the next request (the kill switch)
--   2. drop schema leads_api cascade; drop role leads_reader;
--   3. PATCH /v1/projects/klgtrdwrasrlxbmfyvdh/postgrest {"db_schema": "public,graphql_public"}
--   Revoking the legacy HS256 signing key in the dashboard also kills the key (and any other token it signed).
-- =====================================================================================================================

do $guard$
begin
  if exists (select 1 from pg_namespace where nspname = 'derm') then
    raise exception 'refusing: schema derm exists, this looks like Prod';
  end if;
  if not exists (select 1 from pg_namespace where nspname = 'frozen_leads') then
    raise exception 'refusing: schema frozen_leads is missing, wrong project?';
  end if;
  if exists (select 1 from pg_namespace where nspname = 'leads_api') then
    raise exception 'refusing: schema leads_api already exists';
  end if;
  if exists (select 1 from pg_roles where rolname = 'leads_reader') then
    raise exception 'refusing: role leads_reader already exists';
  end if;
end
$guard$;

create schema leads_api;
comment on schema leads_api is
  'Read-only views of frozen_leads for one outside reader (Yannick, Trello #211, 2026-11-16). Only role leads_reader may '
  'read them. frozen_leads itself is untouched. Undo: Supabase docs/sandbox/2026-11-16_leads_api_read_only.sql.';
revoke all on schema leads_api from public;

-- Owner-rights views (owner postgres, which bypasses RLS), so the reader needs no grant on frozen_leads.
create view leads_api.gdo_universe        as select * from frozen_leads.gdo_universe;
create view leads_api.hours_of_operation  as select * from frozen_leads.hours_of_operation;
create view leads_api.contacts            as select * from frozen_leads.contacts;
create view leads_api.activities          as select * from frozen_leads.activities;
create view leads_api.tasks               as select * from frozen_leads.tasks;
create view leads_api.tags                as select * from frozen_leads.tags;
create view leads_api.lead_tags           as select * from frozen_leads.lead_tags;
create view leads_api.segments            as select * from frozen_leads.segments;
create view leads_api.stage_history       as select * from frozen_leads.stage_history;
create view leads_api.v_lead_full         as select * from frozen_leads.v_lead_full;
create view leads_api.v_lead_board        as select * from frozen_leads.v_lead_board;
create view leads_api.v_prospect_overview as select * from frozen_leads.v_prospect_overview;
create view leads_api.v_pipeline_stats    as select * from frozen_leads.v_pipeline_stats;
create view leads_api.v_segments_overview as select * from frozen_leads.v_segments_overview;

revoke all on all tables in schema leads_api from public, anon, authenticated, service_role;

create role leads_reader nologin;
comment on role leads_reader is 'Read-only API role for leads_api (Trello #211). Kill switch: revoke leads_reader from authenticator.';
grant usage on schema leads_api to leads_reader;
grant select on all tables in schema leads_api to leads_reader;
grant leads_reader to authenticator;
alter role leads_reader set statement_timeout = '15s';

do $verify$
declare
  n int;
begin
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'leads_api' and c.relkind = 'v';
  if n <> 14 then raise exception 'VERIFY: expected 14 views in leads_api, found %', n; end if;

  -- The reader reads every view and can change none of them; nobody else reads them.
  if exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
              where s.nspname = 'leads_api'
                and (not has_table_privilege('leads_reader', c.oid, 'SELECT')
                     or has_table_privilege('leads_reader', c.oid, 'INSERT')
                     or has_table_privilege('leads_reader', c.oid, 'UPDATE')
                     or has_table_privilege('leads_reader', c.oid, 'DELETE')
                     or has_table_privilege('leads_reader', c.oid, 'TRUNCATE')
                     or has_table_privilege('leads_reader', c.oid, 'MAINTAIN')
                     or has_table_privilege('anon', c.oid, 'SELECT')
                     or has_table_privilege('authenticated', c.oid, 'SELECT'))) then
    raise exception 'VERIFY: leads_api privileges are not reader-SELECT-only';
  end if;

  -- The reader reaches no table or view anywhere else. "Reaches" = a privilege on the relation AND USAGE on its schema:
  -- Postgres grants SELECT on extensions.pg_stat_statements(_info) to PUBLIC, but nobody holds USAGE on `extensions`,
  -- so they are unreachable (the first run of this file, without the USAGE test, refused on exactly those two).
  if exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
              where s.nspname not in ('leads_api', 'pg_catalog', 'information_schema')
                and has_schema_privilege('leads_reader', s.oid, 'USAGE')
                and c.relkind in ('r', 'v', 'm', 'p', 'f')
                and (has_table_privilege('leads_reader', c.oid, 'SELECT')
                     or has_table_privilege('leads_reader', c.oid, 'INSERT')
                     or has_table_privilege('leads_reader', c.oid, 'UPDATE')
                     or has_table_privilege('leads_reader', c.oid, 'DELETE'))) then
    raise exception 'VERIFY: leads_reader reaches a relation outside leads_api';
  end if;

  -- Control: the same test must find something for a role that has access (anon reads frozen_leads.gdo_universe).
  if not has_table_privilege('anon', 'frozen_leads.gdo_universe', 'SELECT') then
    raise exception 'VERIFY control: anon no longer reads frozen_leads.gdo_universe, so the checks above prove nothing';
  end if;

  if not pg_has_role('authenticator', 'leads_reader', 'MEMBER') then
    raise exception 'VERIFY: authenticator cannot switch to leads_reader';
  end if;

  select count(*) into n from leads_api.gdo_universe;
  if n <> 9890 then raise exception 'VERIFY: leads_api.gdo_universe has % rows, expected 9890', n; end if;
end
$verify$;
