-- ============================================================================
-- 2026-11-03_1700_leads_schema_m1  Frozen leads, step M1: the private schema `leads` and its four tables
-- ============================================================================
-- THE ASK
--   Trello IWJkqTq1 (#166) and f3Q3Q55i (#165). Fred, 2026-11-03: "design the best plan, with the best practices ...
--   should we create a separate DB or add it to the current one, if so i want a generic leads one with 3NF as well, in
--   case we get like another source of leads too, so they merge, including a reference for their source obviously".
--   Then (AskUserQuestion): "Leads + routing now"; CCNs "Keep all, privately"; BSI contacts "Load them privately now".
--   Plan: docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md (section 8.1, stage S1).
-- WHAT
--   1. public.rls_auto_enable(): the schema list gains 'leads' (anchored edit of the live body, md5 pinned before and
--      after), so every table created in `leads` comes out with RLS on.
--   2. Schema `leads`: private (not in PostgREST's exposed list), no default grants for anon, authenticated or
--      service_role (measured: no default ACL applies to a new schema). db_backup_reader gets USAGE and SELECT (tables
--      and sequences, by default privileges) so the 2-hourly dump can read it (backup.sh is changed after this applies).
--   3. Four tables (3NF: each holds only what depends on its key):
--      leads.establishments   one restaurant; holds ONLY our decision: which of our properties it is (property_id),
--                             and its status. Nothing descriptive is copied here.
--      leads.source_records   one outside record (a BSI property now; a DERM permit or a web form later). Its id in
--                             that source lives in public.entity_source_links (entity_type 'source_record'), rule 1.
--      leads.source_versions  what the source said, append-only: a new row only when the content changed, otherwise
--                             only last_seen_at moves. Payloads are private (CCNs and BSI contacts kept here by
--                             Fred's choice, never in a view anyone can read).
--      leads.match_decisions  insert-only: who decided a record is or is not one of our properties, when, why, and
--                             on which version.
--   4. public.entity_source_links_entity_type_chk: the 17 live values plus 'source_record'.
-- WHY THE PROPERTY (not client_locations): the four Boca clients' "Main" client_locations have no property_id, while
--   every one of their visits carries one (measured 2026-11-03). The #169 bot joins visits -> property -> this link.
-- RULE 7 (widening a CHECK can wake a reader), measured 2026-11-03: function bodies and view definitions naming
--   'source_record' = 0 (re-run at apply; positive control 'time_entry' > 0).
-- RULE 8 (audit):
--   IN  leads.establishments  (the property link is a human decision)
--   IN  leads.source_records  (moving a record between establishments is a merge or a split)
--   OUT leads.source_versions (append-only machine landing; its only update is last_seen_at on every load; a purge
--                              ordered by counsel must not survive in audit.logs.old_row)
--   OUT leads.match_decisions (insert-only; who, when and why are columns on each row; precedent hr.bonus_events)
--   None touches customer.*, billing, DERM compliance or secrets. entity_source_links stays unaudited (unchanged).
-- GUARDS: no DELETE or TRUNCATE on the three landing tables (public.fn_append_only_guard, errcode 55000); UPDATE stays
--   allowed there (links, moves, last_seen_at, a purge). match_decisions refuses UPDATE, DELETE and TRUNCATE.
-- GRANTS: every table and sequence holds exactly {postgres, db_backup_reader=r}; anon, authenticated and service_role
--   hold nothing (read back with aclexplode below). The views for Viktor come in M2.
-- LOCKS: entity_source_links is on the webhook path; its ALTER sits last and lock_timeout is 3s (retry if it times
--   out). Applied clear of the backup dump (:17 on even UTC hours).
-- VERIFY (inside): md5 pins; a table made in `leads` comes out RLS-on while one in `raw` does not (control); the CHECK
--   is exactly 18 values ('bogus' fails 23514, a 'source_record' link inserts); exact grants; audit on exactly the
--   two tables; a DELETE on each guarded table fails 55000; an UPDATE of a decision fails 55000.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_leads_schema_m1.sql (valid before the first load).
-- ============================================================================
begin;
set local lock_timeout = '3s';

do $pre$
declare v_def text;
begin
  if md5((select prosrc from pg_proc where oid = 'public.rls_auto_enable()'::regprocedure)) <> '408c99c84a11a1e4acba0cc60c9bdace' then
    raise exception 'leads M1: public.rls_auto_enable() changed since this migration was written';
  end if;
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'public.entity_source_links'::regclass and conname = 'entity_source_links_entity_type_chk';
  if md5(v_def) <> '7f67c04c71e907fb4ed1ed7443c24dee' then
    raise exception 'leads M1: entity_source_links_entity_type_chk changed since this migration was written: %', v_def;
  end if;
  if exists (select 1 from pg_constraint where conrelid = 'public.entity_source_links'::regclass and contype = 'c'
              and conname <> 'entity_source_links_entity_type_chk') then
    raise exception 'leads M1: entity_source_links gained another CHECK; read it before widening';
  end if;
  if exists (select 1 from pg_namespace where nspname = 'leads') then
    raise exception 'leads M1: schema leads already exists';
  end if;
  if exists (select 1 from pg_proc where prosrc ilike '%source_record''%') then
    raise exception 'leads M1: a function already names ''source_record''; read it first (rule 7)';
  end if;
end $pre$;

-- 1. RLS on for every new table in `leads` (anchored edit of the live body)
do $rls$
declare d text; a text := $a$'customer', 'hr')$a$; b text := $b$'customer', 'hr', 'leads')$b$;
begin
  select pg_get_functiondef('public.rls_auto_enable()'::regprocedure) into d;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
    raise exception 'leads M1: the schema list anchor is not found exactly once in rls_auto_enable';
  end if;
  execute replace(d, a, b);
  if md5((select prosrc from pg_proc where oid = 'public.rls_auto_enable()'::regprocedure)) <> '89ec942fa505043d284b59455fa8e797' then
    raise exception 'leads M1: rls_auto_enable did not land as expected';
  end if;
end $rls$;

-- 2. The schema
create schema leads;
comment on schema leads is
  'Frozen leads (Trello #165/#166, 2026-11-03): outside records about restaurants we do not serve yet (BSI Online Boca '
  'Raton first), kept as received with their source and dates. Private: not exposed to the API; Viktor reads the '
  'public.v_frozen_leads / v_lead_interceptors / v_lead_review views. Plan docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md.';
revoke all on schema leads from public;
grant usage on schema leads to db_backup_reader;
alter default privileges for role postgres in schema leads grant select on tables to db_backup_reader;
alter default privileges for role postgres in schema leads grant select on sequences to db_backup_reader;

-- 3. Tables
create table leads.establishments (
  id          bigint generated always as identity primary key,
  property_id bigint references public.properties(id),
  status      text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index establishments_one_per_property on leads.establishments (property_id)
  where property_id is not null and status = 'ACTIVE';
comment on table leads.establishments is
  'One restaurant (food-service establishment). Holds only our decision: property_id = this restaurant IS that '
  'property of ours (set or cleared only by leads.decide_client), and status (INACTIVE = emptied by a merge). Every '
  'descriptive value is read from its source records, never copied here.';

create table leads.source_records (
  id               bigint generated always as identity primary key,
  establishment_id bigint not null references leads.establishments(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index source_records_establishment on leads.source_records (establishment_id);
comment on table leads.source_records is
  'One outside record about a restaurant (a BSI Online property now). Its id in that source lives only in '
  'public.entity_source_links (entity_type ''source_record'', source_system = the feed, source_id = its id there).';

create table leads.source_versions (
  source_record_id bigint not null references leads.source_records(id),
  fetched_at       timestamptz not null,
  last_seen_at     timestamptz not null,
  payload          jsonb not null,
  primary key (source_record_id, fetched_at),
  check (last_seen_at >= fetched_at),
  check (jsonb_typeof(payload) = 'object')
);
comment on table leads.source_versions is
  'What the source said: a new row only when the content changed; otherwise only last_seen_at moves. fetched_at = '
  'start of the first run that returned this content; last_seen_at = start of the latest run that returned it '
  'unchanged. Private: payloads hold CCNs and BSI contacts (Fred 2026-11-03: keep privately); no view anyone can read '
  'outputs them (scripts/checks/leads_integrity.sql).';

create table leads.match_decisions (
  id               bigint generated always as identity primary key,
  property_id      bigint not null references public.properties(id),
  source_record_id bigint references leads.source_records(id),
  absent_from      text,
  verdict          text not null check (verdict in ('same', 'different', 'absent')),
  seen_version_at  timestamptz,
  evidence         jsonb not null default '{}',
  reason           text not null check (btrim(reason) <> ''),
  decided_by       text not null,
  decided_at       timestamptz not null default now(),
  foreign key (source_record_id, seen_version_at) references leads.source_versions (source_record_id, fetched_at),
  check ((verdict = 'absent') = (absent_from is not null)),
  check ((source_record_id is null) = (verdict = 'absent')),
  check ((source_record_id is null) = (seen_version_at is null))
);
create index match_decisions_pair on leads.match_decisions (source_record_id, property_id, id desc);
comment on table leads.match_decisions is
  'Insert-only. Every same / different / absent decision a person makes about one of our properties: same = this '
  'outside record IS that property; different = it is not; absent = that property has no record in source '
  'absent_from. The newest decision on a pair wins. Written only by leads.decide_client.';

alter table leads.establishments   enable row level security;   -- also done by rls_auto_enable; explicit for certainty
alter table leads.source_records   enable row level security;
alter table leads.source_versions  enable row level security;
alter table leads.match_decisions  enable row level security;

-- 4. Triggers
create trigger establishments_updated_at before update on leads.establishments
  for each row execute function public.set_updated_at();
create trigger source_records_updated_at before update on leads.source_records
  for each row execute function public.set_updated_at();
create trigger audit_establishments after insert or update or delete on leads.establishments
  for each row execute function audit.log_change();
create trigger audit_source_records after insert or update or delete on leads.source_records
  for each row execute function audit.log_change();
create trigger establishments_no_delete before delete on leads.establishments
  for each row execute function public.fn_append_only_guard();
create trigger establishments_no_truncate before truncate on leads.establishments
  for each statement execute function public.fn_append_only_guard();
create trigger source_records_no_delete before delete on leads.source_records
  for each row execute function public.fn_append_only_guard();
create trigger source_records_no_truncate before truncate on leads.source_records
  for each statement execute function public.fn_append_only_guard();
create trigger source_versions_no_delete before delete on leads.source_versions
  for each row execute function public.fn_append_only_guard();
create trigger source_versions_no_truncate before truncate on leads.source_versions
  for each statement execute function public.fn_append_only_guard();
create trigger match_decisions_append_only before update or delete on leads.match_decisions
  for each row execute function public.fn_append_only_guard();
create trigger match_decisions_no_truncate before truncate on leads.match_decisions
  for each statement execute function public.fn_append_only_guard();

-- 5. Grants: nothing for the API roles (REVOKE ALL, never a list: PG17 adds MAINTAIN)
revoke all on all tables in schema leads from public, anon, authenticated, service_role;
revoke all on all sequences in schema leads from public, anon, authenticated, service_role;

-- 6. The new link type (last: this holds the webhook-path table's lock until commit)
alter table public.entity_source_links drop constraint entity_source_links_entity_type_chk;
alter table public.entity_source_links add constraint entity_source_links_entity_type_chk check (entity_type = any (array[
  'client','derm_manifest','employee','inspection','invoice','job','line_item','note','photo','property','quote',
  'vehicle','visit','calendar_day_marker','calendar_task','tank_sensor','time_entry',
  'source_record']));

-- VERIFY
do $verify$
declare
  v_err text; v_n int; v_bad text; v_est bigint; v_rec bigint;
begin
  -- the CHECK: exactly the 17 old values plus source_record
  if md5((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.entity_source_links'::regclass
            and conname = 'entity_source_links_entity_type_chk'))
     <> md5('CHECK ((entity_type = ANY (ARRAY[''client''::text, ''derm_manifest''::text, ''employee''::text, ''inspection''::text, ''invoice''::text, ''job''::text, ''line_item''::text, ''note''::text, ''photo''::text, ''property''::text, ''quote''::text, ''vehicle''::text, ''visit''::text, ''calendar_day_marker''::text, ''calendar_task''::text, ''tank_sensor''::text, ''time_entry''::text, ''source_record''::text])))') then
    raise exception 'leads M1 VERIFY: the entity_type CHECK is not the 18 expected values';
  end if;
  begin
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id) values ('bogus', 1, 'verify', 'x');
    raise exception 'leads M1 VERIFY: bogus entity_type accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, match_method)
    values ('source_record', -1, 'verify', 'verify-1', 'verify');
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise exception 'leads M1 VERIFY: a source_record link was refused: %', sqlerrm; end if;
  end;

  -- control: a table made in leads comes out RLS-on, one made in raw does not
  begin
    create table leads.verify_rls (x int);
    create table raw.verify_rls_control (x int);
    if not (select relrowsecurity from pg_class where oid = 'leads.verify_rls'::regclass) then
      raise exception 'leads M1 VERIFY: a new table in leads came out with RLS off';
    end if;
    if (select relrowsecurity from pg_class where oid = 'raw.verify_rls_control'::regclass) then
      raise exception 'leads M1 VERIFY: CONTROL FAILED, raw (not covered) came out RLS-on';
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;

  -- grants: tables and sequences exactly {postgres (owner), db_backup_reader SELECT}
  select string_agg(distinct c.relname || ':' || coalesce(pg_get_userbyid(a.grantee), 'PUBLIC') || ':' || a.privilege_type, ', ')
    into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(coalesce(c.relacl, acldefault((case when c.relkind = 'S' then 's' else 'r' end)::"char", c.relowner))) a
   where n.nspname = 'leads' and c.relkind in ('r', 'S')
     and not (pg_get_userbyid(a.grantee) = 'postgres'
              or (pg_get_userbyid(a.grantee) = 'db_backup_reader' and a.privilege_type = 'SELECT'));
  if v_bad is not null then raise exception 'leads M1 VERIFY: unexpected grants: %', v_bad; end if;
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   cross join lateral aclexplode(c.relacl) a
   where n.nspname = 'leads' and c.relkind = 'r' and pg_get_userbyid(a.grantee) = 'db_backup_reader' and a.privilege_type = 'SELECT';
  if v_n <> 4 then raise exception 'leads M1 VERIFY: db_backup_reader reads % of the 4 tables', v_n; end if;
  if has_table_privilege('service_role', 'leads.source_versions', 'SELECT')
     or has_table_privilege('authenticated', 'leads.source_versions', 'SELECT')
     or has_table_privilege('anon', 'leads.source_versions', 'SELECT') then
    raise exception 'leads M1 VERIFY: an API role can read leads.source_versions';
  end if;
  if not has_schema_privilege('db_backup_reader', 'leads', 'USAGE') then
    raise exception 'leads M1 VERIFY: db_backup_reader lacks USAGE on leads (the dump would fail)';
  end if;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'leads' and c.relkind = 'r' and not c.relrowsecurity) then
    raise exception 'leads M1 VERIFY: a leads table has RLS off';
  end if;

  -- audit on exactly the two tables (rule 8)
  select string_agg(c.relname, ',' order by c.relname) into v_bad
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'leads' and t.tgfoid = 'audit.log_change()'::regprocedure and not t.tgisinternal;
  if v_bad is distinct from 'establishments,source_records' then
    raise exception 'leads M1 VERIFY: audit triggers on % (expected establishments,source_records)', v_bad;
  end if;

  -- guards: a DELETE on each landing table fails 55000; an UPDATE of a decision fails 55000
  begin
    insert into leads.establishments default values returning id into v_est;
    insert into leads.source_records (establishment_id) values (v_est) returning id into v_rec;
    insert into leads.source_versions values (v_rec, now(), now(), '{"verify":true}');
    insert into leads.match_decisions (property_id, source_record_id, verdict, seen_version_at, reason, decided_by)
      select (select min(id) from public.properties), v_rec, 'different', (select fetched_at from leads.source_versions where source_record_id = v_rec), 'verify', 'system';
    begin delete from leads.source_versions where source_record_id = v_rec; raise exception 'leads M1 VERIFY: source_versions DELETE allowed';
    exception when sqlstate '55000' then null; end;
    begin delete from leads.source_records where id = v_rec; raise exception 'leads M1 VERIFY: source_records DELETE allowed';
    exception when sqlstate '55000' then null; end;
    begin delete from leads.establishments where id = v_est; raise exception 'leads M1 VERIFY: establishments DELETE allowed';
    exception when sqlstate '55000' then null; end;
    begin update leads.match_decisions set reason = 'changed' where source_record_id = v_rec; raise exception 'leads M1 VERIFY: decision UPDATE allowed';
    exception when sqlstate '55000' then null; end;
    update leads.source_versions set last_seen_at = last_seen_at + interval '1 minute' where source_record_id = v_rec;  -- allowed
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

commit;
