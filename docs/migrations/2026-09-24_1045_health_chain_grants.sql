-- =====================================================================================================
-- 2026-09-24_1045_health_chain_grants.sql
-- The health-alert chain is callable only by what runs it (pg_cron as postgres, health-escalate as
-- service_role), and note-photo-sync-health is registered in ops.v_health_status too.
-- =====================================================================================================
--
-- WHY. Found in passing by the adversarial review of 2026-09-24_0845_start_freshness_phase2 (not fixed
-- there, out of scope). The escalation chain (docs: CLAUDE.md, "THE HEALTH WATCHDOG") is what emails
-- Fred; a signed-in staff user could silence it or trigger it.
--
-- MEASURED BEFORE THIS FILE (2026-09-24, read-only, and a rolled-back role probe):
--   function                                   secdef  ACL                                         reachable?
--   fn_health_ack(text,text,int,text,text)     yes     postgres, authenticated, service_role       YES: as authenticated the BODY RAN
--                                                                                                  (p_days 0 raised its own 22023)
--   fn_health_alert_mark_sent(jsonb)           yes     postgres, authenticated, service_role       same grant, same path (not called: writes)
--   fn_health_alert_scan(int,int)              yes     postgres, authenticated, service_role       same (not called: writes health_alert_state)
--   fn_request_health_escalation()             yes     postgres, authenticated, service_role       same (not called: posts to health-escalate,
--                                                                                                  which SENDS THE EMAIL)
--   log_rpa_derm_health()                      no      PUBLIC, anon, authenticated, service_role   no: fails on v_rpa_derm_health (42501)
--   log_jobber_note_photo_health()             no      PUBLIC, authenticated, service_role         no: fails on sync_log (42501)
--   log_calendar_push_health()                 no      authenticated, service_role                 no: fails on sync_log (42501)
--   log_sa_schedule_gaps()                     no      PUBLIC, anon, authenticated, service_role   no: fails on v_sa_schedule_gaps (42501)
--                                                                                                  (writer of the watched source
--                                                                                                  'sa-schedule-gap-check'; added after review)
--   fn_request_auth_recovery_watch()           yes     postgres, authenticated, service_role       same grant as fn_request_health_escalation:
--                                                                                                  reads the vault service key and posts to the
--                                                                                                  edge fn auth-recovery-watch on demand. Its cron
--                                                                                                  no longer exists (last run 2026-09-01 13:17 UTC;
--                                                                                                  public.auth_recovery_state stuck at 'down' since),
--                                                                                                  so NOTHING calls it; added after review. After
--                                                                                                  this file no fn_request_* poster (16) is open to
--                                                                                                  anon or authenticated.
--   view public.v_jobber_note_photo_health     -       authenticated = arwdDxtm                    SELECT yes (owner-rights: sync_log aggregates
--                                                                                                  that authenticated cannot read directly);
--                                                                                                  writes no (an aggregate view, not updatable)
--   PostgREST exposes: public, graphql_public, customer, derm, ops, client, hr. So each function above is at
--   /rest/v1/rpc/<name> for any staff JWT. Consequences of the four SECURITY DEFINER ones: mute any alert
--   for up to 365 days (fn_health_ack); mark alerts as sent so they are never emailed
--   (fn_health_alert_mark_sent); record items as seen out of cycle (fn_health_alert_scan); trigger the
--   escalation email on demand (fn_request_health_escalation).
--   The grants were never intended: 2026-08-24_1820 granted service_role only, and Supabase's default
--   privileges grant EXECUTE on new public functions to anon, authenticated and service_role BY NAME before
--   any GRANT runs, so REVOKE ... FROM PUBLIC does not remove them (scripts/probes/calendar_task_poll.mjs
--   records the same finding for fn_request_health_escalation).
--
-- WHO CALLS THEM (so nothing that works stops working):
--   * pg_cron as postgres: every log_*_health() and fn_request_health_escalation() (cron.job, username postgres).
--   * edge fn health-escalate with its SUPABASE_SERVICE_ROLE_KEY: fn_health_alert_scan, fn_health_alert_mark_sent
--     (pg_stat_statements since 2026-09-03: 21 and 17 calls, all as service_role).
--   * fn_health_ack: a person, from SQL (postgres). No caller on record.
--   * NO APP: all ten live bundles (calendar, clients, derm, admin, fp, stamp, dump, hub, hr, planner) walked to
--     closure (absolute AND relative chunks; byte counts match scripts/checks/app-rpc-contract.js), with a
--     per-app positive control: 0 occurrences of any function above, of v_jobber_note_photo_health, of
--     health_alert_state, v_health_items or v_health_status. No edge function other than health-escalate
--     names them; no script calls them.
--
-- WHAT THIS DOES
--   1. REVOKE ALL ... FROM public, anon, authenticated on the nine functions. postgres and service_role keep
--      EXECUTE (service_role is what health-escalate is; postgres is what cron is).
--   2. REVOKE ALL on public.v_jobber_note_photo_health FROM public, anon, authenticated, matching its siblings
--      public.v_rpa_derm_health and public.v_inbound_file_queue_health (postgres, service_role, yannick_readonly).
--      Its only reader is log_jobber_note_photo_health, run by cron as postgres.
--   3. ops.v_health_status learns 'note-photo-sync-health' (both source lists + one CASE arm, details->'items'),
--      which 2026-09-08_0230's header claimed and never did (it redefined v_health_items only). Anchor splice
--      of the live definition; the column list does not change, so the ACL survives (asserted).
--   NOT CHANGED: ops.v_health_items / ops.v_health_status stay readable by authenticated (reading the health
--   state was not the finding); public.log_blackout_health, log_jobber_sync_health, log_start_flags_health
--   (already postgres + service_role, or postgres only); health_alert_state (no API grants).
--
-- RULE 8 (audit): no table changes. Grants and a view definition only.
--
-- REVIEWED before apply: 3 adversarial lenses (completeness, breakage, soundness) + a skeptic per lens; 8 findings
--   confirmed, none must-fix. Folded in: log_sa_schedule_gaps and fn_request_auth_recovery_watch (above), V3b (the
--   view's whole ACL must equal its sibling's), this rollback note. Nothing that runs the chain loses access
--   (every health cron runs as postgres; health-escalate calls /rest/v1/rpc with the service key; no function
--   body reads ops.v_health_status, and fn_health_alert_scan reads ops.v_health_items only).
--
-- ROLLBACK: re-grant what was there (it is recorded above), e.g.
--   grant execute on function public.fn_health_ack(text,text,integer,text,text) to authenticated;
--   PART 3 is display-only (nothing escalates from ops.v_health_status). To undo it, reverse the splice on
--   pg_get_viewdef('ops.v_health_status'::regclass, true): replace
--   'start-flags-health'::text, 'note-photo-sync-health'::text]  with  'start-flags-health'::text]  (2 occurrences)
--   and remove " WHEN 'note-photo-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)" (1),
--   then create or replace the view. (2026-09-24_0845 PART 10 cannot be re-run: its anchor is gone.)
-- =====================================================================================================

begin;
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------
-- PART 1. Functions: only postgres (cron) and service_role (health-escalate)
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.fn_health_ack(text, text, integer, text, text) from public, anon, authenticated;
revoke all on function public.fn_health_alert_mark_sent(jsonb)               from public, anon, authenticated;
revoke all on function public.fn_health_alert_scan(integer, integer)         from public, anon, authenticated;
revoke all on function public.fn_request_health_escalation()                 from public, anon, authenticated;
revoke all on function public.log_rpa_derm_health()                          from public, anon, authenticated;
revoke all on function public.log_jobber_note_photo_health()                 from public, anon, authenticated;
revoke all on function public.log_calendar_push_health()                     from public, anon, authenticated;
revoke all on function public.log_sa_schedule_gaps()                         from public, anon, authenticated;
revoke all on function public.fn_request_auth_recovery_watch()               from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- PART 2. The note-photo health view: like its siblings, no API role but service_role
-- ---------------------------------------------------------------------------------------------------
revoke all on public.v_jobber_note_photo_health from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- PART 3. ops.v_health_status learns note-photo-sync-health (anchor splice of the live definition)
-- ---------------------------------------------------------------------------------------------------
create temp table zz_acl_before on commit drop as
select c.oid::regclass::text as rel, c.relacl::text as acl
  from pg_class c where c.oid in ('ops.v_health_status'::regclass, 'ops.v_health_items'::regclass);

do $$
declare
  v_def text := pg_get_viewdef('ops.v_health_status'::regclass, true);
  v_n   int;
  v_arr text := '''start-flags-health''::text]';
  v_new text := '''start-flags-health''::text, ''note-photo-sync-health''::text]';
  v_case text := 'WHEN ''start-flags-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)';
begin
  if v_def ~ 'note-photo-sync-health' then raise exception 'v_health_status already names note-photo-sync-health'; end if;
  v_n := (length(v_def) - length(replace(v_def, v_arr, ''))) / length(v_arr);
  if v_n <> 2 then raise exception 'v_health_status: expected 2 array anchors, found %', v_n; end if;
  v_def := replace(v_def, v_arr, v_new);
  v_n := (length(v_def) - length(replace(v_def, v_case, ''))) / length(v_case);
  if v_n <> 1 then raise exception 'v_health_status: expected 1 CASE anchor, found %', v_n; end if;
  v_def := replace(v_def, v_case,
    v_case || ' WHEN ''note-photo-sync-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_status as ' || v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- VERIFY (inside the transaction: any failure rolls the whole migration back)
-- ---------------------------------------------------------------------------------------------------
do $verify$
declare
  f text;
  fns text[] := array[
    'public.fn_health_ack(text, text, integer, text, text)',
    'public.fn_health_alert_mark_sent(jsonb)',
    'public.fn_health_alert_scan(integer, integer)',
    'public.fn_request_health_escalation()',
    'public.log_rpa_derm_health()',
    'public.log_jobber_note_photo_health()',
    'public.log_calendar_push_health()',
    'public.log_sa_schedule_gaps()',
    'public.fn_request_auth_recovery_watch()'];
  v_state text; v_msg text; v_ctl_state text;
  v_items int; v_status int; v_np_items int; v_np_status int;
begin
  -- V1. Privilege, per role, per function. The service_role / postgres TRUEs are the instrument's control:
  --     has_function_privilege can see a grant that exists.
  foreach f in array fns loop
    if has_function_privilege('anon', f, 'EXECUTE') then raise exception 'V1 anon can still execute %', f; end if;
    if has_function_privilege('authenticated', f, 'EXECUTE') then raise exception 'V1 authenticated can still execute %', f; end if;
    if not has_function_privilege('service_role', f, 'EXECUTE') then raise exception 'V1 service_role lost %', f; end if;
    if not has_function_privilege('postgres', f, 'EXECUTE') then raise exception 'V1 postgres lost %', f; end if;
    if (select proacl::text from pg_proc where oid = f::regprocedure) ~ '(^\{|,)=X/' then
      raise exception 'V1 PUBLIC still holds EXECUTE on %', f; end if;
  end loop;

  -- V2. The same call, as each role, in a rolled-back block. authenticated must now be refused BEFORE the
  --     body (42501 on the function); service_role must still reach the body (its own 22023 on p_days 0).
  --     Before this migration authenticated also got 22023 (measured), so this pair is the control.
  begin
    set local role authenticated;
    perform public.fn_health_ack('probe', 'probe', 0, 'probe');
    v_state := 'ran';
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  begin
    set local role service_role;
    perform public.fn_health_ack('probe', 'probe', 0, 'probe');
    v_ctl_state := 'ran';
  exception when others then v_ctl_state := sqlstate;
  end;
  reset role;
  if v_state is distinct from '42501' or v_msg !~ 'function fn_health_ack' then
    raise exception 'V2 authenticated was not refused at the function: % %', v_state, v_msg; end if;
  if v_ctl_state is distinct from '22023' then
    raise exception 'V2 service_role no longer reaches fn_health_ack''s body (got %)', v_ctl_state; end if;

  -- V3. The view: no API role but service_role; service_role and yannick_readonly keep SELECT.
  if has_table_privilege('authenticated', 'public.v_jobber_note_photo_health', 'SELECT')
     or has_table_privilege('authenticated', 'public.v_jobber_note_photo_health', 'INSERT')
     or has_table_privilege('anon', 'public.v_jobber_note_photo_health', 'SELECT') then
    raise exception 'V3 v_jobber_note_photo_health is still open to an app role'; end if;
  if not has_table_privilege('service_role', 'public.v_jobber_note_photo_health', 'SELECT')
     or not has_table_privilege('yannick_readonly', 'public.v_jobber_note_photo_health', 'SELECT') then
    raise exception 'V3 v_jobber_note_photo_health lost a reader it should keep'; end if;
  -- V3b. The whole ACL, not two privileges: it must equal its sibling's byte for byte (a partial revoke that
  --      left authenticated=wdDxtm passed V3 in review).
  if (select relacl::text from pg_class where oid = 'public.v_jobber_note_photo_health'::regclass)
     is distinct from (select relacl::text from pg_class where oid = 'public.v_rpa_derm_health'::regclass) then
    raise exception 'V3b v_jobber_note_photo_health ACL differs from its sibling v_rpa_derm_health'; end if;

  -- V4. The registration: v_health_status now carries every source v_health_items carries, and for
  --     note-photo-sync-health the two views agree on the item count.
  select count(distinct check_name) into v_status from ops.v_health_status;
  select array_length(regexp_split_to_array(
           substring(pg_get_viewdef('ops.v_health_items'::regclass, true) from 'ANY \(ARRAY\[([^\]]+)\]'), ','), 1)
    into v_items;
  if not exists (select 1 from ops.v_health_status where check_name = 'note-photo-sync-health') then
    raise exception 'V4 note-photo-sync-health is not in ops.v_health_status'; end if;
  if v_status <> v_items then
    raise exception 'V4 v_health_status has % checks, v_health_items lists % sources', v_status, v_items; end if;
  select count(*) into v_np_items from ops.v_health_items where check_name = 'note-photo-sync-health';
  select item_count into v_np_status from ops.v_health_status where check_name = 'note-photo-sync-health';
  if v_np_items is distinct from v_np_status then
    raise exception 'V4 note-photo-sync-health: % items in v_health_items, % in v_health_status', v_np_items, v_np_status; end if;

  -- V4b. Today the check has 0 items, and a missing CASE arm would ALSO read 0 (ELSE '[]'), so V4 alone
  --      cannot fail on it. A rolled-back fixture run with one item must reach v_health_status as 1.
  begin
    insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
    values ('note-photo-sync-health', clock_timestamp(), clock_timestamp(), 1, 'warning',
            jsonb_build_object('items', jsonb_build_array(jsonb_build_object('kind', 'probe_item_zz'))));
    select item_count into v_np_status from ops.v_health_status where check_name = 'note-photo-sync-health';
    select count(*) into v_np_items from ops.v_health_items
     where check_name = 'note-photo-sync-health' and item_key = 'probe_item_zz';
    raise exception 'ROLLBACK_PROBE';
  exception when raise_exception then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;
  if v_np_status is distinct from 1 or v_np_items is distinct from 1 then
    raise exception 'V4b the fixture item reached v_health_status as % and v_health_items as %', v_np_status, v_np_items; end if;
  if exists (select 1 from public.sync_log where sync_source = 'note-photo-sync-health' and details::text ~ 'probe_item_zz') then
    raise exception 'V4b the fixture row survived'; end if;

  -- V5. Both health views kept their ACLs byte for byte, and v_health_status its columns.
  if exists (select 1 from zz_acl_before b join pg_class c on c.oid = b.rel::regclass
              where c.relacl::text is distinct from b.acl) then
    raise exception 'V5 a health view''s ACL changed'; end if;
  if (select count(*) from information_schema.columns where table_schema = 'ops' and table_name = 'v_health_status') <> 12 then
    raise exception 'V5 v_health_status column list changed'; end if;
end
$verify$;

commit;
