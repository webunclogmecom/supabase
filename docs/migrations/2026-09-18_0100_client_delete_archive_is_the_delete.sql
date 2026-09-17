-- ============================================================================
-- 2026-09-18_0100 : "archive is the delete" for the Clients App, DB half
-- ============================================================================
-- Fred, 2026-09-17: "we need to be able to delete clients on the Clients App, do a full audit on
-- how is the best way to do it, knowing it needs to be reflected on Jobber, do we need a soft-delete
-- or hard-delete, also how it can be reflected on jobber." Then, on the audit: "go ahead with all
-- the recommended."
--
-- The audit is Building Apps/Client App/docs/2026-09-18_client-delete-audit.md. Its answer: soft,
-- and it already exists. Jobber has no clientDelete in any API version it accepts (introspected
-- live across 2026-04-16, 04-22, 05-12, 07-27, 09-09), a Jobber UI deletion is permanent and
-- cascades to jobs, quotes, requests and invoices, and 23 foreign keys point at public.clients
-- (18 NO ACTION, 1 RESTRICT), so the "delete" is the shipped archive-client saga (Jobber archive,
-- verified, then INACTIVE with a reason) plus hiding INACTIVE rows in the Clients list. Nothing here
-- adds a deleted_at column, a DELETED status or a hard delete. This migration ships the DB half of
-- the mandatory grafts:
--
--   1. public.client_status_changes.event ('status_change' | 'archived' | 'archived_here_only' |
--      'deleted_in_jobber'), so the ledger can say WHY a client became INACTIVE. 'deleted_in_jobber'
--      is written by webhook-jobber's handleClientDestroy (a CLIENT_DESTROY webhook: the client was
--      deleted in the Jobber UI) and by archive-client when Jobber affirmatively has no such client
--      any more; 'archived' is stamped by archive-client on the row the 3-arg
--      client.update_client_status just wrote after a VERIFIED Jobber archive;
--      'archived_here_only' when there was no Jobber record to archive; everything else keeps the
--      default. A partial unique index allows ONE deleted_in_jobber row per client, so two
--      concurrent deliveries of the same CLIENT_DESTROY converge instead of doubling the history.
--      client.update_client_status refuses to move a deleted_in_jobber client anywhere but
--      INACTIVE: the Jobber record is gone, so "reactivating" would promise a client that cannot be
--      served (create the client again instead; a new Jobber GID mints a new row).
--      Backfilled for the two CLIENT_DESTROY deliveries on record: client 564 (event 317778,
--      2026-08-23) and client 505 (event 384683, 2026-09-16), both ACTIVE -> INACTIVE per audit.logs
--      133370 and 200278.
--   2. client.status_changes (what the Status history panel reads) exposes `event`.
--   3. A weekly READ-ONLY sweep, edge function sync-jobber-client-state-sweep, asks Jobber
--      `client(id){ id isArchived }` for every linked client and logs two divergence shapes into
--      sync_log as 'jobber-client-state-sweep': our INACTIVE but live in Jobber (Jobber auto-
--      unarchives a client when new work is created there while our manual pin keeps the row
--      INACTIVE and hidden), and our non-INACTIVE but gone in Jobber (a lost CLIENT_DESTROY: that
--      webhook is ack-first and never retried). It never writes clients. This file registers the
--      source in ops.v_health_items and ops.v_health_status (the rule: a check absent from either
--      CASE contributes zero items and can never escalate), adds it to the health function's
--      watched-surface list with an 8-day staleness window, whitelists it in
--      public.fn_request_jobber_sync, and schedules it (Sunday 07:15 UTC). Two more splices in
--      the health function: the sync_stuck arm exempts this source (one weekly 'attention' run is
--      not a streak), and the jobber_link_orphan detector's visits arm skips completed and skipped
--      visits, because webhook-jobber now UNLINKS a completed visit that Jobber destroyed (keeping
--      it completed) and the detector would otherwise call that visit "invisible debris, remove it".
--
-- WHAT THIS MIGRATION DOES NOT DO, ON PURPOSE
--   - No column on public.clients. INACTIVE already carries every property a deleted marker would
--     need: both partial unique indexes key on it, the 6 worklist views filter on it, the Field
--     Portal shows its banner on it, and it is what a Jobber archive and a Jobber deletion already
--     produce on our side.
--   - No write from the sweep. A null read is an ABSENCE and this estate has soft-deleted 756 live
--     visits from an absence before (2026-08-14). The sweep reports; a person decides in the app.
--   - The completed-visit guard in webhook-jobber's softStatusFlip ships in the edge function, not
--     here (it needs no DB object).
--
-- SPLICES: log_jobber_sync_health, fn_request_jobber_sync and client.update_client_status are
-- edited by string replacement on their LIVE bodies inside this transaction, each pinned to an md5
-- read on 2026-09-18 and each anchor asserted to match exactly once, so nothing is retyped (the
-- 2026-08-06 lesson). The two ops views are re-created the same way from pg_get_viewdef. If any md5
-- or anchor count differs the migration raises and nothing commits.
--
-- REVIEWED before apply (2026-09-18, five lenses plus a refuter per finding, read-only). What that
-- changed here: the archived_here_only value, the one-deletion index, the update_client_status
-- guard, the two extra health splices, VERIFY 4c scoped to its fixture, VERIFY 6 asserting the
-- watched tuple rather than a comment, and the deploy order below.
--
-- DEPLOY ORDER (a window in the wrong order is a false alarm or a false success):
--   1. deploy sync-jobber-client-state-sweep and invoke it ONCE over HTTPS with the service bearer
--      so a sync_log row exists BEFORE this migration registers the source in the health function's
--      stall watch (otherwise the 13:13 UTC health run mails "has not run since never").
--   2. apply this migration.
--   3. deploy webhook-jobber (writes the event column this migration adds).
--   4. publish the Client App (its toast must read the new reply fields, or a no_link / not_found
--      archive reads as "Archived in Jobber" on the old bundle).
--   5. deploy archive-client.
--
-- GRANTS: CREATE OR REPLACE keeps the views' ACLs; the ALTER TABLE adds a column to an audited
-- table (audit_client_status_changes captures full rows, so the new column is captured with no
-- action). fn_request_jobber_sync stays cron-only (no anon/authenticated/service_role EXECUTE,
-- measured before and asserted after).
--
-- ROLLBACK, in execution order: (1) redeploy the previous webhook-jobber and archive-client
-- (the commits before this work; they must stop writing `event` before the column goes);
-- (2) select cron.unschedule('jobber-client-state-sweep'); (3) replay the CREATE OR REPLACE
-- FUNCTION statements for public.log_jobber_sync_health from 2026-09-16_2350, for
-- public.fn_request_jobber_sync from the 2026-09-09 invoice-drift migration, and for
-- client.update_client_status from 2026-09-16_2030 (statements only, not the whole files);
-- (4) CREATE OR REPLACE the two ops views from their pre-2026-09-18 definitions (same columns, so
-- grants survive; if you DROP instead, re-grant SELECT to authenticated, service_role and
-- yannick_readonly); (5) CREATE OR REPLACE client.status_changes without `event`;
-- (6) delete the two backfilled ledger rows (event = 'deleted_in_jobber', clients 505 and 564);
-- (7) drop index client_status_changes_one_deletion_per_client; (8) ALTER TABLE
-- public.client_status_changes DROP COLUMN event.
--
-- AUDIT (ADR 010): client_status_changes is already audited; the two backfilled rows land in
-- audit.logs as INSERTs (app_source 'sql'). sync_log is a journal and is not audited.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the ledger event
-- ---------------------------------------------------------------------------
alter table public.client_status_changes
  add column event text not null default 'status_change';

alter table public.client_status_changes
  add constraint client_status_changes_event_chk
  check (event in ('status_change', 'archived', 'archived_here_only', 'deleted_in_jobber'));

-- One recorded Jobber deletion per client: two deliveries of the same CLIENT_DESTROY can both pass
-- webhook-jobber's prior-row read (three PostgREST transactions); the second insert then raises
-- 23505, which the handler treats as convergence.
create unique index client_status_changes_one_deletion_per_client
  on public.client_status_changes (client_id) where event = 'deleted_in_jobber';

comment on column public.client_status_changes.event is
  'Why the status moved. status_change: a person changed it in the Client App (the default). '
  'archived: archive-client archived the client in Jobber first (verified), then wrote this row. '
  'archived_here_only: archive-client found no Jobber link, so only our side was archived. '
  'deleted_in_jobber: the client was deleted in the Jobber UI (a CLIENT_DESTROY webhook, or '
  'archive-client finding Jobber has no such client). Permanent there; the row here stays as '
  'history. client.update_client_status refuses to move such a client anywhere but INACTIVE and '
  'the Clients App hides Reactivate for it; the weekly sweep reports the pair either way.';

-- Backfill the two Jobber-UI deletions on record. changed_by is NULL (no human on our side),
-- changed_at is the webhook delivery instant, old/new from the matching audit rows.
insert into public.client_status_changes
  (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed, changed_at, event)
select v.client_id, 'ACTIVE', 'INACTIVE',
       'Deleted in the Jobber UI (CLIENT_DESTROY webhook ' || v.event_id || ', backfilled 2026-09-18)',
       null, null, 0, v.at, 'deleted_in_jobber'
  from (values (564, 317778, timestamptz '2026-08-23 23:47:26.895821+00'),
               (505, 384683, timestamptz '2026-09-16 20:03:43.082332+00')) as v(client_id, event_id, at)
 where exists (select 1 from public.clients c where c.id = v.client_id and c.status = 'INACTIVE')
   and exists (select 1 from public.webhook_events_log w where w.id = v.event_id and w.event_type = 'CLIENT_DESTROY' and w.entity_id = v.client_id)
   and not exists (select 1 from public.client_status_changes s where s.client_id = v.client_id and s.event = 'deleted_in_jobber');

-- ---------------------------------------------------------------------------
-- 2. the view the Status history panel reads: same leading columns, `event` appended
-- ---------------------------------------------------------------------------
create or replace view client.status_changes as
 select id,
    client_id,
    old_status,
    new_status,
    reason,
    changed_by_email,
    visits_removed,
    changed_at,
    ( select count(*)::integer as count
        from public.photo_links pl
       where pl.entity_type = 'client_status_change'::text and pl.entity_id = s.id and pl.role = 'reason_photo'::text and pl.deleted_at is null) as photo_count,
    event
   from public.client_status_changes s;

-- ---------------------------------------------------------------------------
-- 3. health views: register 'jobber-client-state-sweep' (items live in details->'items')
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_n   int;
begin
  -- ops.v_health_items
  v_def := pg_get_viewdef('ops.v_health_items'::regclass, true);
  v_n := (length(v_def) - length(replace(v_def, '''note-photo-sync-health''::text]', ''))) / length('''note-photo-sync-health''::text]');
  if v_n <> 1 then raise exception 'v_health_items: expected 1 array anchor, found %', v_n; end if;
  v_def := replace(v_def, '''note-photo-sync-health''::text]', '''note-photo-sync-health''::text, ''jobber-client-state-sweep''::text]');
  v_n := (length(v_def) - length(replace(v_def, 'WHEN ''note-photo-sync-health''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)', ''))) / length('WHEN ''note-photo-sync-health''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)');
  if v_n <> 1 then raise exception 'v_health_items: expected 1 CASE anchor, found %', v_n; end if;
  v_def := replace(v_def,
    'WHEN ''note-photo-sync-health''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)',
    'WHEN ''note-photo-sync-health''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb) WHEN ''jobber-client-state-sweep''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_items as ' || v_def;

  -- ops.v_health_status (the source list appears twice: the runs CTE and the streak subquery; the CASE once)
  v_def := pg_get_viewdef('ops.v_health_status'::regclass, true);
  v_n := (length(v_def) - length(replace(v_def, '''jobber-sync-health''::text]', ''))) / length('''jobber-sync-health''::text]');
  if v_n <> 2 then raise exception 'v_health_status: expected 2 array anchors, found %', v_n; end if;
  v_def := replace(v_def, '''jobber-sync-health''::text]', '''jobber-sync-health''::text, ''jobber-client-state-sweep''::text]');
  v_n := (length(v_def) - length(replace(v_def, 'WHEN ''jobber-sync-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)', ''))) / length('WHEN ''jobber-sync-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)');
  if v_n <> 1 then raise exception 'v_health_status: expected 1 CASE anchor, found %', v_n; end if;
  v_def := replace(v_def,
    'WHEN ''jobber-sync-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)',
    'WHEN ''jobber-sync-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb) WHEN ''jobber-client-state-sweep''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_status as ' || v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 4. the cron wrapper learns the new target (spliced from the live body, md5 pinned)
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text := pg_get_functiondef('public.fn_request_jobber_sync(text)'::regprocedure);
  v_anchor text := 'WHEN ''invoice-drift'' THEN ''https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-invoice-drift''';
  v_n int;
begin
  if md5(v_def) <> '22e4b7c0a94bd3ab3b1104599de193aa' then
    raise exception 'fn_request_jobber_sync changed since 2026-09-18 (md5 %); re-read it before splicing', md5(v_def);
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'fn_request_jobber_sync: anchor found % times', v_n; end if;
  v_def := replace(v_def, v_anchor,
    v_anchor || E'\n    WHEN ''client-state-sweep'' THEN ''https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-client-state-sweep''');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 5. the health function watches the sweep for staleness (weekly: 8 days), spliced, md5 pinned
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  v_anchor text := '      (''calendar-task-poll'',            interval ''25 minutes''),';
  v_n int;
begin
  if md5(v_def) <> '24a79f66df05535fb37f586ec0e0ce7c' then
    raise exception 'log_jobber_sync_health changed since 2026-09-18 (md5 %); re-read it before splicing', md5(v_def);
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'log_jobber_sync_health: anchor found % times', v_n; end if;
  v_def := replace(v_def, v_anchor,
    v_anchor || E'\n      -- weekly (Sunday 07:15 UTC), read-only; 8 days allows one missed run before it reads stale.\n      (''jobber-client-state-sweep'',     interval ''8 days''),');

  -- the sync_stuck arm: a weekly source's single 'attention' run is not a streak, and its items are
  -- already deduplicated through ops.v_health_items
  v_anchor := $a$       and now() - c.since >= interval '72 hours'$a$;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'log_jobber_sync_health: stuck anchor found % times', v_n; end if;
  v_def := replace(v_def, v_anchor,
    v_anchor || E'\n       -- a weekly source reports through its own items; one ''attention'' run is not a streak (2026-09-18)\n       and c.sync_source <> ''jobber-client-state-sweep''');

  -- the orphan detector's visits arm: a completed or skipped visit is UNLINKED on purpose when
  -- Jobber destroys it after the fact (webhook-jobber softStatusFlip, 2026-09-18 and 2026-08-xx),
  -- so it is history without a Jobber object, not race debris
  v_anchor := $a$('visit','public.visits',true,'and t.source = ''jobber''')$a$;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'log_jobber_sync_health: orphan visits anchor found % times', v_n; end if;
  v_def := replace(v_def, v_anchor,
    $a$('visit','public.visits',true,'and t.source = ''jobber'' and t.visit_status not in (''completed'',''skipped'')')$a$);

  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 5b. client.update_client_status: a client deleted in Jobber only ever moves to INACTIVE
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text := pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure);
  v_anchor text := $a$  select c.status into v_old from public.clients c where c.id = p_client_id;$a$;
  v_n int;
begin
  if md5(v_def) <> '89995b7fd5d88004126847449a6a32f7' then
    raise exception 'client.update_client_status changed since 2026-09-18 (md5 %); re-read it before splicing', md5(v_def);
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'update_client_status: anchor found % times', v_n; end if;
  v_def := replace(v_def, v_anchor,
    $a$  -- 2026-09-18: a client deleted in the Jobber UI has no Jobber record to serve it; it stays as
  -- history and only ever moves to INACTIVE. Create the client again instead (a new GID, a new row).
  if p_status <> 'INACTIVE' and exists (
       select 1 from public.client_status_changes s
        where s.client_id = p_client_id and s.event = 'deleted_in_jobber') then
    raise exception 'This client was deleted in Jobber, so it cannot be reactivated here. Create the client again instead; this record stays as history.'
      using errcode = '22023', detail = 'blocker=deleted_in_jobber client_id=' || p_client_id;
  end if;

$a$ || v_anchor);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 6. schedule (Sunday 07:15 UTC = 03:15 EDT / 02:15 EST)
-- ---------------------------------------------------------------------------
select cron.schedule('jobber-client-state-sweep', '15 7 * * 0',
                     $cron$select public.fn_request_jobber_sync('client-state-sweep')$cron$);

-- ---------------------------------------------------------------------------
-- VERIFY (raises = nothing commits)
-- ---------------------------------------------------------------------------
do $$
declare
  n int; t text; v_items jsonb;
begin
  -- 1. the CHECK bites and the default holds
  begin
    insert into public.client_status_changes (client_id, old_status, new_status, reason, event)
    values ((select id from public.clients order by id limit 1), 'ACTIVE', 'ACTIVE', '[TEST] junk event', 'junk');
    raise exception 'VERIFY 1 failed: junk event accepted';
  exception when check_violation then null;
  end;
  select count(*) into n from public.client_status_changes where event = 'status_change';
  if n < 28 then raise exception 'VERIFY 1b failed: existing rows did not take the default (%)', n; end if;
  -- 1c. the one-deletion index bites: a second deleted_in_jobber row for 505 is refused
  begin
    insert into public.client_status_changes (client_id, old_status, new_status, reason, event)
    values (505, 'INACTIVE', 'INACTIVE', '[TEST] second deletion row', 'deleted_in_jobber');
    raise exception 'VERIFY 1c failed: second deleted_in_jobber row accepted';
  exception when unique_violation then null;
  end;
  -- 1d. the update_client_status guard: moving 505 to ACTIVE is refused with the plain sentence,
  --     INACTIVE is not refused by that guard (it is a no-op there). The function checks auth first,
  --     so the probe runs with a staff JWT claim set locally and rolls the whole thing back.
  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","email":"probe@ayache.com","role":"authenticated"}', true);
    begin
      perform client.update_client_status(505, 'ACTIVE', '[TEST] must be refused');
      raise exception 'VERIFY 1d failed: a deleted_in_jobber client was reactivated';
    exception when invalid_parameter_value then
      if sqlerrm !~ 'deleted in Jobber' then raise exception 'VERIFY 1d failed: wrong refusal %', sqlerrm; end if;
    end;
    raise exception '__rollback_fixture__';
  exception when others then
    if sqlerrm <> '__rollback_fixture__' then raise; end if;
  end;
  if exists (select 1 from public.clients where id = 505 and status <> 'INACTIVE') then raise exception 'VERIFY 1d failed: 505 moved'; end if;

  -- 2. exactly two backfilled rows, on the right clients
  select count(*) into n from public.client_status_changes where event = 'deleted_in_jobber';
  if n <> 2 then raise exception 'VERIFY 2 failed: % deleted_in_jobber rows, expected 2', n; end if;
  if not exists (select 1 from public.client_status_changes where event = 'deleted_in_jobber' and client_id = 505 and changed_at = timestamptz '2026-09-16 20:03:43.082332+00')
     or not exists (select 1 from public.client_status_changes where event = 'deleted_in_jobber' and client_id = 564 and changed_at = timestamptz '2026-08-23 23:47:26.895821+00') then
    raise exception 'VERIFY 2b failed: backfilled rows do not match the webhook instants';
  end if;

  -- 3. the view exposes event, same ACL as before
  if not exists (select 1 from information_schema.columns where table_schema = 'client' and table_name = 'status_changes' and column_name = 'event') then
    raise exception 'VERIFY 3 failed: client.status_changes has no event column';
  end if;
  select relacl::text into t from pg_class where oid = 'client.status_changes'::regclass;
  if t <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres}' then raise exception 'VERIFY 3b failed: client.status_changes ACL changed to %', t; end if;
  if has_table_privilege('anon', 'client.status_changes', 'select') then raise exception 'VERIFY 3c failed: anon can read client.status_changes'; end if;

  -- 4. health views: a synthetic sweep row must surface as an item in BOTH. PL/pgSQL has no
  --    SAVEPOINT statement; the sub-block below is the savepoint, and the deliberate raise at its
  --    end rolls the fixture back whether the asserts pass or not.
  begin
    insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
    values ('jobber-client-state-sweep', clock_timestamp(), clock_timestamp(), 1, 'attention',
            jsonb_build_object('items', jsonb_build_array(jsonb_build_object(
              'kind', 'inactive_client_live_in_jobber:999999', 'issue', 'inactive_client_live_in_jobber',
              'client_id', 999999, 'client_code', '[TEST]', 'reason', 'verify fixture'))));
    select count(*) into n from ops.v_health_items where check_name = 'jobber-client-state-sweep' and item_key = 'inactive_client_live_in_jobber:999999';
    if n <> 1 then raise exception 'VERIFY 4 failed: v_health_items shows % items for the sweep, expected 1', n; end if;
    select count(*) into n from ops.v_health_status where check_name = 'jobber-client-state-sweep' and item_count = 1;
    if n <> 1 then raise exception 'VERIFY 4b failed: v_health_status does not show the sweep with 1 item'; end if;
    raise exception '__rollback_fixture__';
  exception when others then
    if sqlerrm <> '__rollback_fixture__' then raise; end if;
  end;
  select count(*) into n from public.sync_log where sync_source = 'jobber-client-state-sweep' and details -> 'items' @> '[{"client_id": 999999}]'::jsonb;
  if n <> 0 then raise exception 'VERIFY 4c failed: fixture sync_log row survived the rollback'; end if;
  -- positive control: the existing source still renders through the same path
  select count(*) into n from ops.v_health_status where check_name = 'jobber-sync-health';
  if n <> 1 then raise exception 'VERIFY 4d failed: jobber-sync-health disappeared from v_health_status'; end if;
  -- ACLs unchanged
  select relacl::text into t from pg_class where oid = 'ops.v_health_items'::regclass;
  if t <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' then raise exception 'VERIFY 4e failed: v_health_items ACL is %', t; end if;
  select relacl::text into t from pg_class where oid = 'ops.v_health_status'::regclass;
  if t <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' then raise exception 'VERIFY 4f failed: v_health_status ACL is %', t; end if;

  -- 5. wrapper whitelists the new target and stays cron-only
  if pg_get_functiondef('public.fn_request_jobber_sync(text)'::regprocedure) !~ 'client-state-sweep' then raise exception 'VERIFY 5 failed: wrapper does not know client-state-sweep'; end if;
  if has_function_privilege('anon', 'public.fn_request_jobber_sync(text)', 'execute')
     or has_function_privilege('authenticated', 'public.fn_request_jobber_sync(text)', 'execute')
     or has_function_privilege('service_role', 'public.fn_request_jobber_sync(text)', 'execute') then
    raise exception 'VERIFY 5b failed: fn_request_jobber_sync gained an EXECUTE grant';
  end if;

  -- 6. health function watches the sweep; the body still parses and runs (it writes one verdict row,
  --    which is what the cron does daily; rolled back with the savepoint)
  t := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  if position($a$('jobber-client-state-sweep',     interval '8 days'),$a$ in t) = 0 then raise exception 'VERIFY 6 failed: the watched VALUES tuple is missing'; end if;
  if position($a$and c.sync_source <> 'jobber-client-state-sweep'$a$ in t) = 0 then raise exception 'VERIFY 6b failed: the stuck-arm exemption is missing'; end if;
  if position($a$and t.visit_status not in (''completed'',''skipped'')$a$ in t) = 0 then raise exception 'VERIFY 6c failed: the orphan visits predicate is missing'; end if;
  -- the body still runs, and its verdict row does not report the sweep as stalled (a sync_log row
  -- for the sweep must exist before this migration: deploy order step 1)
  begin
    perform public.log_jobber_sync_health();
    select details -> 'items' into v_items from public.sync_log where sync_source = 'jobber-sync-health' order by started_at desc limit 1;
    if v_items @> '[{"kind": "sync_stalled:jobber-client-state-sweep"}]'::jsonb then
      raise exception 'VERIFY 6d failed: the health run reports the sweep as stalled; run the sweep once before applying (deploy order step 1)';
    end if;
    raise exception '__rollback_fixture__';
  exception when others then
    if sqlerrm <> '__rollback_fixture__' then raise; end if;
  end;
  if pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure) !~ 'deleted_in_jobber' then raise exception 'VERIFY 6e failed: update_client_status guard missing'; end if;

  -- 7. cron row
  select count(*) into n from cron.job where jobname = 'jobber-client-state-sweep' and schedule = '15 7 * * 0' and active;
  if n <> 1 then raise exception 'VERIFY 7 failed: cron row missing'; end if;

  raise notice 'VERIFY ok';
end $$;

commit;
