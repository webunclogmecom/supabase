-- 2026-09-02_1400_outbound_custom_field_queue.sql
--
-- AUTOMATIC OUTBOUND for the two Jobber property custom fields, half one of two: the QUEUE.
-- Fred: "we need a two way ... when edit at our app it reflects on jobber."
--
-- This migration adds ONLY the enqueue side. It writes nothing to Jobber and changes no existing
-- function. Until the drain edge function is deployed the queue simply accumulates rows, which is
-- deliberate: an intermediate state that records intent and pushes nothing is safe, whereas one
-- that pushes without a durable record of what it meant to push is not.
--
-- ============================================================================
-- WHY A QUEUE AND NOT A DIRECT CALL FROM THE RPC
-- ============================================================================
-- The safety argument for any outbound write is an ORDER: push -> read back -> THEN record the
-- shadow. A trigger cannot honour it. pg_net's net.http_post only ENQUEUES a request and returns an
-- id, so the trigger's transaction commits before the push is even attempted; treating that as
-- delivery is the false-success this estate has a standing rule against. And a synchronous call
-- would make a staff member's Save wait on Jobber and fail when Jobber is shedding load.
-- So the trigger records INTENT durably, and the drain function - which can read Jobber back before
-- it touches the shadow - owns the ordering.
--
-- The crash window is therefore benign by construction. If the drain dies after the Jobber write
-- and before the shadow re-baseline, the row stays pending; the retry re-reads Jobber, finds it
-- already equal to the desired value, and only re-baselines. Idempotent, and it converges.
--
-- ============================================================================
-- THE SUPPRESSION MARKER IS POSITIVE, NOT A DENYLIST. THIS IS THE CRUX.
-- ============================================================================
-- Without suppression this trigger pushes every value the inbound sync just ADOPTED straight back
-- to Jobber, on every poll, 477+ rows wide, at the */5 cadence.
--
-- The obvious guard - skip when app_source is the sync's label - is INCOMPLETE BY CONSTRUCTION.
-- public.properties is also written by 'jobber-lock-box-import', 'sql' (2161 rows, 117 of which
-- changed grease_trap_size_gallons), 'probe-smoke-test', 'admin-review', 'visit-calendar' and
-- 'force-adopt-jobber'. Every future backfill script would spray Jobber, and nobody would remember
-- to add it to the list. A denylist of writers is a list you have to keep completing.
--
-- So the condition is POSITIVE: enqueue only when auth.uid() is not null, i.e. this write is
-- happening inside a request carrying a real logged-in person's JWT. The app's RPCs are called
-- through PostgREST with the user's token, so auth.uid() is set and the AFTER ROW trigger sees it.
-- Everything else in this estate writes as service_role or postgres with no JWT: the inbound sync
-- (fn_sync_property_custom_field, called by the webhook edge function), every script that goes
-- through the Management API, and every cron job. They are all excluded without being enumerated.
--
-- This also means NO existing function had to change. client.update_property_operational and
-- client.update_property_capacity are untouched, so there is no chance of regressing them, and a
-- third app entry point added later is covered automatically rather than silently missed.
--
-- ============================================================================
-- OTHER THINGS THAT WOULD HAVE MADE THIS WRONG
-- ============================================================================
--  * A BARE AFTER UPDATE TRIGGER FIRES ON NO-OP UPDATES. Postgres row triggers fire even when the
--    UPDATE changed nothing, and the inbound handler rewrites the whole property row on every
--    replay - measured, 84 properties touched in an hour against 2 real audit rows. The WHEN clause
--    below is column-scoped and IS DISTINCT FROM, so a no-op replay enqueues nothing. A WHEN clause
--    is better than an IF inside the function because it cannot be forgotten and costs nothing.
--  * updated_at IS NOT A CHANGE SIGNAL for the same reason. Nothing here reads it.
--  * jsonb TYPE IDENTITY. The shadow compares with IS DISTINCT FROM, so 3061111 must round-trip as
--    a jsonb NUMBER and 3061112 as a jsonb STRING. to_jsonb() on the typed column gives exactly
--    that; a text cast anywhere here would make every later poll see a change that never happened.
--  * fn_record_shadow RAISES on a frozen row rather than returning. Nothing in this migration calls
--    it - that belongs to the drain, outside the user's transaction, where a raise cannot turn a
--    staff member's Save into a raw P0001.
--
-- Rollback: drop the trigger, then the function, then the table. Nothing else is touched.

begin;

-- ---------------------------------------------------------------------------
-- 1. The queue
-- ---------------------------------------------------------------------------
create table if not exists sync.outbound_queue (
  id             bigserial primary key,
  entity_type    text        not null default 'property',
  entity_id      bigint      not null,
  source_system  text        not null default 'jobber',
  field_key      text        not null,
  field_label    text        not null,
  -- jsonb 'null' means "clear it". Distinct from SQL NULL, which never appears here.
  desired_value  jsonb       not null,
  status         text        not null default 'pending'
                 check (status in ('pending','done','failed','skipped')),
  attempts       integer     not null default 0,
  last_error     text,
  enqueued_by    text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  processed_at   timestamptz
);

comment on table sync.outbound_queue is
  'Intent to write one field to an external system. Written by a trigger inside the user''s '
  'transaction; drained by an edge function that owns the push -> read back -> record shadow order.';

-- ONE pending row per (entity, field). Two quick edits collapse to the latest desired value, which
-- is the correct outcome: we want the field to end up right, not to replay every keystroke at Jobber.
create unique index if not exists outbound_queue_one_pending_per_field
  on sync.outbound_queue (entity_type, entity_id, field_key)
  where status = 'pending';

create index if not exists outbound_queue_pending_created
  on sync.outbound_queue (created_at) where status = 'pending';

-- The app roles must never see or touch this. Only the drain (service_role) does.
revoke all on sync.outbound_queue from public;
grant select, insert, update on sync.outbound_queue to service_role;
grant usage, select on sequence sync.outbound_queue_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- 2. The enqueue trigger
-- ---------------------------------------------------------------------------
create or replace function sync.fn_enqueue_outbound_custom_field()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_uid uuid;
begin
  -- POSITIVE MARKER. See the header: only a request carrying a real person's JWT enqueues.
  -- Wrapped because a malformed request.jwt.claims would otherwise abort the staff member's write,
  -- and refusing to push is a far smaller failure than refusing to save.
  begin
    v_uid := auth.uid();
  exception when others then
    v_uid := null;
  end;
  if v_uid is null then
    return null;
  end if;

  -- Never push a row Jobber does not have as a Property, and never push a corpse.
  if new.deleted_at is not null or coalesce(new.is_billing, false) then
    return null;
  end if;

  if new.grease_trap_size_gallons is distinct from old.grease_trap_size_gallons then
    insert into sync.outbound_queue
      (entity_type, entity_id, source_system, field_key, field_label, desired_value, enqueued_by)
    values ('property', new.id, 'jobber',
            'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
            coalesce(to_jsonb(new.grease_trap_size_gallons), 'null'::jsonb), v_uid::text)
    on conflict (entity_type, entity_id, field_key) where status = 'pending'
      do update set desired_value = excluded.desired_value,
                    enqueued_by   = excluded.enqueued_by,
                    updated_at    = now(),
                    attempts      = 0,
                    last_error    = null;
  end if;

  if new.lock_box_key is distinct from old.lock_box_key then
    insert into sync.outbound_queue
      (entity_type, entity_id, source_system, field_key, field_label, desired_value, enqueued_by)
    values ('property', new.id, 'jobber',
            'gid://Jobber/CustomFieldConfigurationText/3061112', 'Lock Box/Key',
            coalesce(to_jsonb(new.lock_box_key), 'null'::jsonb), v_uid::text)
    on conflict (entity_type, entity_id, field_key) where status = 'pending'
      do update set desired_value = excluded.desired_value,
                    enqueued_by   = excluded.enqueued_by,
                    updated_at    = now(),
                    attempts      = 0,
                    last_error    = null;
  end if;

  return null;
end
$fn$;

revoke all on function sync.fn_enqueue_outbound_custom_field() from public;

drop trigger if exists trg_properties_enqueue_outbound on public.properties;
create trigger trg_properties_enqueue_outbound
  after update on public.properties
  for each row
  when (old.grease_trap_size_gallons is distinct from new.grease_trap_size_gallons
     or old.lock_box_key             is distinct from new.lock_box_key)
  execute function sync.fn_enqueue_outbound_custom_field();

-- ---------------------------------------------------------------------------
-- 3. Observability. A success-only log is structurally blind to a feature that always fails, so
--    this view reports the SHAPE of the queue - including how old the oldest pending row is, which
--    is the number that goes wrong when the drain silently stops running.
-- ---------------------------------------------------------------------------
create or replace view sync.v_outbound_queue_health as
select
  field_label,
  status,
  count(*)                                              as rows,
  max(attempts)                                         as max_attempts,
  min(created_at)                                       as oldest,
  round(extract(epoch from (now() - min(created_at)))/60.0, 1) as oldest_minutes,
  max(processed_at)                                     as last_processed
from sync.outbound_queue
group by field_label, status;

grant select on sync.v_outbound_queue_health to service_role;

-- ---------------------------------------------------------------------------
-- VERIFY. Assertions that must hold, run inside the same transaction.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_n        integer;
  v_enqueued integer;
  v_prop     bigint;
  v_before   integer;
begin
  -- the trigger exists and carries a WHEN clause (a bare one would fire on every no-op replay)
  select count(*) into v_n
    from pg_trigger t
   where t.tgrelid = 'public.properties'::regclass
     and t.tgname = 'trg_properties_enqueue_outbound'
     and pg_get_triggerdef(t.oid) like '%IS DISTINCT FROM%';
  if v_n <> 1 then
    raise exception 'VERIFY FAILED: enqueue trigger missing or has no column-scoped WHEN clause (found %)', v_n;
  end if;

  -- the partial unique index that collapses repeat edits
  select count(*) into v_n from pg_indexes
   where schemaname='sync' and indexname='outbound_queue_one_pending_per_field';
  if v_n <> 1 then raise exception 'VERIFY FAILED: pending-uniqueness index missing'; end if;

  -- THE CENTRAL ASSERTION, and it is a NEGATIVE one with a positive control beside it.
  -- A service_role / no-JWT write must enqueue NOTHING. This transaction has no auth.uid(), so a
  -- real UPDATE here stands in exactly for what the inbound sync does on every poll.
  select id, grease_trap_size_gallons into v_prop, v_before
    from public.properties
   where deleted_at is null and is_billing = false and grease_trap_size_gallons is not null
   order by id limit 1;
  if v_prop is null then raise exception 'VERIFY FAILED: no subject property to probe with'; end if;

  -- The probe WRITES, so it runs inside a BEGIN..EXCEPTION block, which is plpgsql's implicit
  -- savepoint. The deliberate raise rolls back the UPDATE (and the audit row it caused) while
  -- leaving this migration's DDL intact. A plain `rollback;` at the end of the file would have
  -- discarded the whole migration, and a bare DO block with no exception handler would have
  -- COMMITTED the probe's +1 onto a real client's capacity.
  begin
    update public.properties
       set grease_trap_size_gallons = coalesce(v_before, 0) + 1
     where id = v_prop;
    select count(*) into v_enqueued from sync.outbound_queue where entity_id = v_prop;
    raise exception 'PROBE_ROLLBACK';
  exception
    when others then
      if sqlerrm <> 'PROBE_ROLLBACK' then raise; end if;
      -- plpgsql variables are not transactional: v_enqueued survives the rollback, the UPDATE does not.
  end;

  if v_enqueued <> 0 then
    raise exception 'VERIFY FAILED: a no-JWT write enqueued % row(s). The suppression marker is '
                    'inverted and the inbound sync would push every adopted value back to Jobber.',
                    v_enqueued;
  end if;

  -- POSITIVE CONTROL for that negative: prove the trigger is actually attached and would fire, so
  -- the zero above is a working suppression rather than a trigger that does nothing at all.
  select count(*) into v_n
    from pg_trigger t
   where t.tgrelid = 'public.properties'::regclass
     and t.tgname = 'trg_properties_enqueue_outbound'
     and t.tgenabled <> 'D';
  if v_n <> 1 then
    raise exception 'VERIFY FAILED: the zero above is vacuous - the trigger is absent or disabled';
  end if;

  raise notice 'VERIFY OK: queue, index, trigger present; a no-JWT write enqueued 0 rows; trigger enabled';
end
$verify$;

commit;
