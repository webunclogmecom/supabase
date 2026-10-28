-- 2026-10-28_1804_rls_on_every_app_table.sql
--
-- Trello FFSF71BI: "Fix Supabase critical security alert: RLS disabled on public tables".
-- Supabase's weekly advisor emailed web@unclogme.com on 2026-10-20 and 2026-10-27 (lint
-- rls_disabled_in_public, "Table publicly accessible"). Spec:
-- docs/specs/2026-10-28-rls-on-every-app-table.md
--
-- Fred, 2026-10-28, on how to stop the next new table landing with RLS off:
-- "Turn it on automatically" (picked over a daily alert and over relying on Supabase's email).
--
-- WHAT IT DOES
--   1. ENABLE ROW LEVEL SECURITY on all 49 tables in public / derm / ops / client / customer / hr
--      that have it off: the 17 the advisor flags (authenticated holds SELECT on them) and 32 that
--      grant anon / authenticated nothing (closed only by grants until now). Not FORCE: the owner
--      keeps bypassing, as on every other table.
--   2. One policy, derm.page_slots_staff_read: DERM Stamp Studio reads derm.page_slots directly
--      (.from('page_slots').select('slot_index,y0_pct,y1_pct'), live bundle, and in
--      pg_stat_statements as authenticated). Same shape as derm.generated_visit_sheets_staff_read.
--      The per-app access gate (public.fn_request_gate) still runs before it.
--   3. Event trigger rls_auto_enable: any table created in those six schemas comes out with RLS on.
--      A table an app must read directly then needs a policy in the same migration.
--
-- WHY NOTHING ELSE MOVES (measured 2026-10-28 before writing this)
--   - Every view over the 17 is owner-rights (no security_invoker) and owned by postgres, which
--     has BYPASSRLS. Every function that names them is SECURITY DEFINER owned by postgres, except
--     the trigger derm.trg_generated_sheet_complete, which fires only on derm.address_row_map
--     writes; authenticated holds SELECT only there, so it always runs as postgres or service_role.
--   - Edge functions, the pdf-service and the GDO bot use the service_role key (BYPASSRLS).
--   - Every role that reads tables without BYPASSRLS (authenticator, yannick_readonly) holds no
--     grant on any of the 49, or cannot log in. db_backup_reader, supabase_read_only_user and
--     supabase_etl_admin all have BYPASSRLS.
--   - Stamp Studio's live update on address_row_map is a PRIVATE BROADCAST channel
--     (public.tg_broadcast_inval, SECURITY DEFINER), authorised by realtime.messages, not table RLS.
--   - Live app bundles swept (calendar, derm, fp, hub, clients, dump, admin, reviews, hr, stamp,
--     planner): only Stamp Studio names any of the 17, and only page_slots as a table read.
--   - The other 16 flagged tables keep their unused authenticated SELECT grant; with RLS on and no
--     policy it returns 0 rows.
--
-- RULE 8 (audit): no new business table, no audit trigger added or removed.
-- Grants: none changed. public.rls_auto_enable() is revoked from PUBLIC, anon, authenticated by
-- name (Supabase default privileges grant EXECUTE on every new public function) and asserted.
-- lock_timeout 3s: ENABLE ROW LEVEL SECURITY takes ACCESS EXCLUSIVE on each table; the backup
-- dump (HH:17 UTC, even hours) holds ACCESS SHARE on every table, so retry if it times out.
-- The VERIFY inside is catalogue reads and single-row probes only, to keep app reads unblocked.
--
-- Rollback: docs/migrations/2026-10-28_rollback_rls_on_every_app_table.sql

begin;
set local lock_timeout = '3s';

-- PART 0. GUARD: the state this was written against.
do $guard$
declare
  v_n int;
  v_list text;
begin
  select count(*), string_agg(n.nspname || '.' || c.relname, ', ' order by 1)
    into v_n, v_list
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'derm', 'ops', 'client', 'customer', 'hr')
     and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if v_n <> 49 then
    raise exception 'GUARD: expected 49 RLS-off tables in the six app schemas, found %: %', v_n, v_list;
  end if;
  if exists (select 1 from pg_policy where polrelid = 'derm.page_slots'::regclass) then
    raise exception 'GUARD: derm.page_slots already has a policy';
  end if;
  if exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable')
     or to_regprocedure('public.rls_auto_enable()') is not null then
    raise exception 'GUARD: rls_auto_enable already exists';
  end if;
end
$guard$;

-- PART 1. RLS on. The 17 the advisor flags:
alter table derm.address_row_map enable row level security;
alter table derm.address_sheet_manifests enable row level security;
alter table derm.address_sheet_scan_reads enable row level security;
alter table derm.address_sheets enable row level security;
alter table derm.band_review enable row level security;
alter table derm.client_aliases enable row level security;
alter table derm.manifest_document_detachments enable row level security;
alter table derm.page_row_rules enable row level security;
alter table derm.page_rule_scans enable row level security;
alter table derm.page_slots enable row level security;
alter table derm.sheet_number_ocr_attempts enable row level security;
alter table derm.stamp_sheet_status enable row level security;
alter table ops.client_call_policy enable row level security;
alter table ops.pgss_snapshot_20260903_medium enable row level security;
alter table public.derm_required_backfill_snapshot_2026_06_24 enable row level security;
alter table public.dump_sites enable row level security;
alter table public.review_scope_inclusions enable row level security;
-- ... and the 32 closed only by grants:
alter table derm.address_sheet_clients enable row level security;
alter table derm.address_sheet_row_reads enable row level security;
alter table derm.generated_measure_attempts enable row level security;
alter table derm.page_reference_attempts enable row level security;
alter table derm.row_ocr_attempts enable row level security;
alter table hr.access_apps enable row level security;
alter table hr.access_group_defaults enable row level security;
alter table hr.access_overrides enable row level security;
alter table hr.access_refusals enable row level security;
alter table hr.jobber_user_ignores enable row level security;
alter table hr.jobber_users enable row level security;
alter table hr.shift_bonus_overrides enable row level security;
alter table hr.sign_in_changes enable row level security;
alter table hr.visit_bonus_overrides enable row level security;
alter table ops.dispatch_routing_usage enable row level security;
alter table ops.marker_jobber_claims enable row level security;
alter table ops.marker_push_retries enable row level security;
alter table ops.plan_fill_request enable row level security;
alter table ops.plan_fill_run enable row level security;
alter table ops.plan_routing_usage enable row level security;
alter table ops.route_leg_cache enable row level security;
alter table ops.route_leg_fail enable row level security;
alter table ops.start_heal_attempts enable row level security;
alter table ops.start_heal_kick enable row level security;
alter table ops.start_recheck_queue enable row level security;
alter table public.app_config enable row level security;
alter table public.client_status_changes enable row level security;
alter table public.derm_portal_requeue enable row level security;
alter table public.health_alert_state enable row level security;
alter table public.intake_task_closures enable row level security;
alter table public.job_frequency_changes enable row level security;
alter table public.non_customer_clients enable row level security;

-- PART 2. The one direct app read: Stamp Studio's printed rows.
create policy page_slots_staff_read on derm.page_slots
  as permissive for select to authenticated using (true);

-- PART 3. Every new table in an app schema comes out with RLS on.
create function public.rls_auto_enable()
returns event_trigger
language plpgsql
set search_path = pg_catalog
as $fn$
declare
  cmd record;
begin
  for cmd in
    select object_identity
      from pg_event_trigger_ddl_commands()
     where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
       and object_type in ('table', 'partitioned table')
       and schema_name in ('public', 'derm', 'ops', 'client', 'customer', 'hr')
       and not in_extension
  loop
    execute format('alter table %s enable row level security', cmd.object_identity);
  end loop;
end
$fn$;

comment on function public.rls_auto_enable() is
  'Event trigger rls_auto_enable: turns RLS on for every table created in public, derm, ops, client, customer, hr (Trello FFSF71BI, Fred 2026-10-28: "Turn it on automatically"). A table an app reads directly needs a policy in the same migration. Keep the schema list equal to the PostgREST exposed schemas we own.';

revoke all on function public.rls_auto_enable() from public, anon, authenticated;

create event trigger rls_auto_enable on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.rls_auto_enable();

-- PART 4. VERIFY (catalogue reads and single-row probes only).
do $verify$
declare
  v_n int;
  v_list text;
begin
  -- V1 no table left with RLS off in the six schemas
  select count(*), string_agg(n.nspname || '.' || c.relname, ', ')
    into v_n, v_list
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'derm', 'ops', 'client', 'customer', 'hr')
     and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if v_n <> 0 then raise exception 'V1: % tables still RLS off: %', v_n, v_list; end if;

  -- V2 the policy is exactly SELECT, permissive, authenticated, USING (true)
  if not exists (
    select 1 from pg_policy p
     where p.polrelid = 'derm.page_slots'::regclass and p.polname = 'page_slots_staff_read'
       and p.polcmd = 'r' and p.polpermissive
       and p.polroles = array['authenticated'::regrole::oid]
       and pg_get_expr(p.polqual, p.polrelid) = 'true'
  ) then raise exception 'V2: page_slots_staff_read is not the intended policy'; end if;

  -- V3 the event trigger is enabled and the function is closed to app roles
  if not exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable' and evtenabled = 'O') then
    raise exception 'V3: event trigger rls_auto_enable missing or disabled';
  end if;
  if has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE') then
    raise exception 'V3: rls_auto_enable is executable by anon or authenticated';
  end if;
end
$verify$;

-- V4 the trigger works: CREATE TABLE and CREATE TABLE AS in app schemas come out RLS on,
--    a table in a schema outside the list (raw) and a temp table do not (controls).
create table public.zz_rls_auto_enable_selftest (id int);
create table derm.zz_rls_auto_enable_selftest_as as select 1 as x;
create table raw.zz_rls_auto_enable_selftest_control (id int);
create temp table zz_rls_auto_enable_selftest_temp (id int);
do $v4$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.zz_rls_auto_enable_selftest'::regclass) then
    raise exception 'V4: CREATE TABLE in public did not get RLS';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'derm.zz_rls_auto_enable_selftest_as'::regclass) then
    raise exception 'V4: CREATE TABLE AS in derm did not get RLS';
  end if;
  if (select relrowsecurity from pg_class where oid = 'raw.zz_rls_auto_enable_selftest_control'::regclass) then
    raise exception 'V4 control: a table in raw got RLS, the schema filter is not working';
  end if;
  if (select relrowsecurity from pg_class where oid = 'pg_temp.zz_rls_auto_enable_selftest_temp'::regclass) then
    raise exception 'V4 control: a temp table got RLS';
  end if;
end
$v4$;
drop table public.zz_rls_auto_enable_selftest;
drop table derm.zz_rls_auto_enable_selftest_as;
drop table raw.zz_rls_auto_enable_selftest_control;
drop table zz_rls_auto_enable_selftest_temp;

-- V5 as a signed-in user: Stamp Studio's read still returns rows, an unpolicied table returns
--    none, and an owner-rights view over it still returns rows.
set local role authenticated;
do $v5$
begin
  if not exists (select 1 from derm.page_slots) then raise exception 'V5: authenticated reads no derm.page_slots rows'; end if;
  if exists (select 1 from derm.address_row_map) then raise exception 'V5: authenticated still reads derm.address_row_map directly'; end if;
  if not exists (select 1 from derm.v_stamp_rows) then raise exception 'V5: derm.v_stamp_rows went empty for authenticated'; end if;
  if not exists (select 1 from public.visits_with_review) then raise exception 'V5: public.visits_with_review went empty for authenticated'; end if;
end
$v5$;
reset role;

commit;
