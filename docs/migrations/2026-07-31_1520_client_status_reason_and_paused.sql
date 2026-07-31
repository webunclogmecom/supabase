-- ============================================================================
-- 2026-07-31_1520 — Status-change PROOF (a required reason + an append-only
--                   history) and the PAUSED status
-- ============================================================================
-- ASK (Fred, 2026-07-31):
--   * "We need to create a 'proof' of change of status (active, recurrent,
--     inactive, paused), it means that when a client status is changed it shows
--     up a box where they can put the 'reason' of why the change."
--   * "We need to add the Paused status."
--
-- ---------------------------------------------------------------------------
-- WHY A TABLE AND NOT audit.logs
-- ---------------------------------------------------------------------------
-- audit.logs already records every clients UPDATE (old_row/new_row), so the
-- FACT of a status change is captured. What it cannot hold is the HUMAN REASON,
-- and Fred asked for proof-of-why. Options weighed:
--   (a) stuff the reason into audit.logs.request_context — invisible to anyone
--       reading the client, and awkward to query per client;
--   (b) a clients.status_reason column — keeps only the LATEST reason and is
--       overwritten by the next change, so it is not proof of anything;
--   (c) an append-only history table  <- chosen. One row per transition, never
--       updated, readable straight from the client page.
-- The table is the record; audit.logs remains the tamper-evidence around it.
--
-- Audit (ADR 010): OPT-IN. It holds a human-entered field on a
-- customer-affecting decision, so it takes audit.log_change() like every other
-- human-editable table. It is append-only by convention AND by grant: the app
-- role gets no UPDATE/DELETE (see grants at the bottom) — only the SECDEF RPC
-- inserts.
-- 3NF: client_id FK, statuses are the transition's own facts (not derivable
-- later — clients.status only holds the current value), reason + actor depend
-- on the transition alone. Nothing copied.
--
-- ROLLBACK:
--   drop function client.update_client_status(bigint, text, text);
--   drop table public.client_status_changes;
--   re-create client.update_client_status(bigint, text) from 2026-07-31_1430.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the proof table
-- ---------------------------------------------------------------------------
create table if not exists public.client_status_changes (
  id           bigint generated always as identity primary key,
  client_id    bigint not null references public.clients(id),
  old_status   text,
  new_status   text not null,
  reason       text not null,
  changed_by   uuid,                      -- auth.uid() of the staff user
  changed_by_email text,
  visits_removed integer not null default 0,
  changed_at   timestamptz not null default now(),
  constraint client_status_changes_reason_not_blank check (btrim(reason) <> '')
);

create index if not exists client_status_changes_client_idx
  on public.client_status_changes (client_id, changed_at desc);

comment on table public.client_status_changes is
  'Append-only PROOF of every client status change: what it was, what it became, WHY (required), who did it, and how many upcoming SA visits the change removed. Written only by client.update_client_status. Never updated or deleted (the app role holds no UPDATE/DELETE grant).';

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'audit_client_status_changes') then
    create trigger audit_client_status_changes
      after insert or update or delete on public.client_status_changes
      for each row execute function audit.log_change();
  end if;
end $$;

-- 🛑 REVOKE THE DEFAULT PRIVILEGES. Supabase's ALTER DEFAULT PRIVILEGES hands a
-- NEW table in the exposed `public` schema straight to anon/authenticated —
-- measured on this very table seconds after creation:
--     authenticated -> SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
-- For a table whose whole purpose is to be PROOF, an UPDATE/DELETE grant is the
-- defect: any staff session could rewrite or erase the reason after the fact.
-- Caught by an explicit append-only assertion in the test matrix, not by reading
-- the DDL (the DDL grants nothing — that is exactly why this is easy to miss).
-- The app reads the history through client.status_changes (SELECT only) and
-- writes it ONLY via the SECDEF RPC, which runs as the owner.
revoke all on public.client_status_changes from anon;
revoke all on public.client_status_changes from authenticated;

-- ---------------------------------------------------------------------------
-- 2. update_client_status — now REQUIRES a reason, and accepts PAUSED
-- ---------------------------------------------------------------------------
create or replace function client.update_client_status(
  p_client_id bigint,
  p_status    text,
  p_reason    text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old    text;
  v_row    public.clients;
  v_before int;
  v_after  int;
  v_removed int;
  v_email  text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- PAUSED added 2026-07-31 (Fred). All four states are now settable.
  if p_status is null or p_status not in ('ACTIVE','RECURRING','INACTIVE','PAUSED') then
    raise exception 'status must be ACTIVE, RECURRING, INACTIVE or PAUSED (got %)', p_status
      using errcode = '22023';
  end if;
  -- The proof is the point: no reason, no change.
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required when changing a client''s status'
      using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'reason is too long (500 characters max)' using errcode = '22023';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if v_old = p_status then
    select c.* into v_row from public.clients c where c.id = p_client_id;
    return jsonb_build_object('client', to_jsonb(v_row), 'visits_removed', 0, 'noop', true);
  end if;

  select count(*) into v_before
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  update public.clients c set status = p_status
   where c.id = p_client_id
  returning c.* into v_row;          -- AFTER trigger performs the SA cleanup

  select count(*) into v_after
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;
  v_removed := greatest(v_before - v_after, 0);

  insert into public.client_status_changes
    (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed)
  values (p_client_id, v_old, p_status, btrim(p_reason), auth.uid(), v_email, v_removed);

  return jsonb_build_object(
    'client', to_jsonb(v_row),
    'previous_status', v_old,
    'visits_removed', v_removed);
end;
$$;

revoke execute on function client.update_client_status(bigint, text, text) from public;
revoke execute on function client.update_client_status(bigint, text, text) from anon;
grant  execute on function client.update_client_status(bigint, text, text) to authenticated;

-- ⚠ The 2-argument version from 2026-07-31_1430 is REPLACED BY A REFUSAL rather
-- than dropped. Dropping it would let a stale client fall back to PostgREST's
-- "function not found" (a confusing 404); refusing gives the operator a readable
-- reason and, more importantly, guarantees there is no path that changes a
-- status WITHOUT recording why.
create or replace function client.update_client_status(
  p_client_id bigint,
  p_status    text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'a reason is now required: call update_client_status(client_id, status, reason)'
    using errcode = '22023';
end;
$$;

revoke execute on function client.update_client_status(bigint, text) from public;
revoke execute on function client.update_client_status(bigint, text) from anon;
grant  execute on function client.update_client_status(bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. read the proof back (newest first) for the client page
-- ---------------------------------------------------------------------------
create or replace view client.status_changes as
select s.id, s.client_id, s.old_status, s.new_status, s.reason,
       s.changed_by_email, s.visits_removed, s.changed_at
from public.client_status_changes s;

revoke all on client.status_changes from public;
revoke all on client.status_changes from anon;
grant select on client.status_changes to authenticated;   -- read-only: append-only table

commit;
