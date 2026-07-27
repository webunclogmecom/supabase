-- ============================================================================
-- 2026-07-28 — client.saved_views: per-user saved grid views for the Client App
-- ============================================================================
-- Fred scoped the Airtable-style grid (2026-07-27), v1 = SAVED VIEWS in a left
-- rail + COLUMN CONFIG (show/hide/reorder), on the CLIENTS list, persisted
-- PER-USER in the DB with the option to share. Explicitly OUT of v1: grouping
-- with collapsible headers, and inline cell editing.
--
-- ⚠ WHY INLINE EDITING BEING OUT MATTERS: it would have been a write on canonical
-- business data, which lands squarely on Client App phase 2 (the SECDEF write
-- RPCs + the client-side sync rig that does not exist yet). Leaving it out keeps
-- the whole grid off the phase-2 critical path — this migration touches NO
-- business data.
--
-- SCHEMA PLACEMENT: `client`, not `public`. This is Client-App UI state, not
-- canonical business data, so it belongs in the app's own schema per the
-- schema-per-app pattern (memory project_multi_app_schema_pattern). public stays
-- 3NF business-only.
--
-- ⚠ DELIBERATE, DOCUMENTED EXCEPTION to the "all Client App writes go through
-- SECDEF RPCs, nothing in `client` is ever writable" contract agreed with the BA
-- session: that rule exists because the client.* VIEWS are postgres-owned and
-- RLS-BYPASSING, so making one writable would be unrestricted write across all
-- 437 clients. Neither condition holds here — this is a NEW TABLE, it holds only
-- the user's own UI preferences, and it has RLS ENABLED **AND FORCED** with
-- owner-scoped policies. Direct RLS-protected access is the correct mechanism for
-- per-user preference data; the RPC contract continues to bind every business
-- write. (Flagged to BA rather than assumed.)
--
-- `config` is opaque JSONB on purpose — filters/sort/column order/visibility are
-- UI shape and belong to the frontend. Modelling them in SQL would force a
-- migration every time the grid gains a control.
--
-- AUDIT (ADR 010): OPT-OUT, documented. This is per-user UI preference data, not
-- business data, and touches no customer/billing/DERM surface. Audit triggers are
-- for human-editable BUSINESS fields; auditing view layouts would be noise.
-- ============================================================================

begin;

create table if not exists client.saved_views (
  id            bigint generated always as identity primary key,
  owner_user_id uuid        not null default auth.uid(),
  name          text        not null,
  entity        text        not null default 'clients',
  config        jsonb       not null default '{}'::jsonb,
  is_shared     boolean     not null default false,
  sort_order    int         not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint saved_views_name_not_blank check (btrim(name) <> ''),
  constraint saved_views_entity_allowed check (entity in ('clients','visits','invoices','jobs')),
  -- one view name per user per entity; a rename to an existing name fails loudly
  constraint saved_views_owner_entity_name_uniq unique (owner_user_id, entity, name)
);

create index if not exists saved_views_owner_entity_idx on client.saved_views (owner_user_id, entity, sort_order);
create index if not exists saved_views_shared_idx       on client.saved_views (entity) where is_shared;

-- updated_at (reuse the standard helper if present, else inline)
create or replace function client.tg_saved_views_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists saved_views_touch on client.saved_views;
create trigger saved_views_touch before update on client.saved_views
  for each row execute function client.tg_saved_views_touch();

-- RLS: owner-scoped. FORCED so even the table owner cannot bypass it.
alter table client.saved_views enable row level security;
alter table client.saved_views force row level security;

-- (select auth.uid()) is wrapped so it evaluates ONCE per query, not per row
-- (the standing Supabase RLS performance rule).
drop policy if exists saved_views_select on client.saved_views;
create policy saved_views_select on client.saved_views
  for select to authenticated
  using (owner_user_id = (select auth.uid()) or is_shared);

drop policy if exists saved_views_insert on client.saved_views;
create policy saved_views_insert on client.saved_views
  for insert to authenticated
  with check (owner_user_id = (select auth.uid()));

-- a user may only ever edit/delete their OWN view, and cannot reassign ownership
drop policy if exists saved_views_update on client.saved_views;
create policy saved_views_update on client.saved_views
  for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (owner_user_id = (select auth.uid()));

drop policy if exists saved_views_delete on client.saved_views;
create policy saved_views_delete on client.saved_views
  for delete to authenticated
  using (owner_user_id = (select auth.uid()));

grant select, insert, update, delete on client.saved_views to authenticated;
grant usage, select on all sequences in schema client to authenticated;
-- anon gets nothing (the Client App is authenticated-only).

commit;
