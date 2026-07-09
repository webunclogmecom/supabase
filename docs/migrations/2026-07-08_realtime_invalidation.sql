-- ============================================================================
-- 2026-07-08_realtime_invalidation.sql
-- Realtime "invalidation signal" tier — leak-free live updates for the apps.
-- ============================================================================
-- WHY: focus/reconnect refetch is already ON in 5/6 apps (audit 2026-07-08), but
-- it only fires on a tab *focus transition*. It does NOTHING while a tab stays
-- focused and a cron / other writer mutates the data underneath it — the exact
-- class behind Yannick's 2026-07-07 stale "Missing Docs" (~84% of derm_manifests
-- writes are non-app). This is the ONLY mechanism that refreshes an already-
-- focused tab: DB write -> broadcast an id-less signal -> app invalidateQueries.
--
-- DESIGN (proven by the anon-channel spike 2026-07-08, plan-notes doc):
--  * Payload is LEAK-FREE: {table, op, at} only — NO row data. (We deliberately
--    use realtime.send() with a hand-built payload, NOT realtime.broadcast_changes,
--    which would embed the full NEW/OLD records and leak them to any subscriber.)
--  * STATEMENT-LEVEL AFTER triggers: one signal per statement, so a 400-row bulk
--    backfill emits 1 message, not 400 (the #1 amplification hazard). Apps ALSO
--    debounce (~400ms) — belt and suspenders.
--  * Private channels, topic "inval:<table>", gated by ONE anon RLS policy on
--    realtime.messages (topic LIKE 'inval:%'). NO auth users / login needed — the
--    anon key is already a valid role=anon JWT (spike Test C).
--  * The trigger fn SWALLOWS ALL EXCEPTIONS — a Realtime hiccup can NEVER abort a
--    business write. This is load-bearing on visits/clients (the hottest tables).
--
-- AUDIT (ADR 010): OPT-OUT. This trigger writes NO business data (it only emits a
-- transient broadcast into realtime.messages). Nothing to audit. The tables it is
-- attached to keep their existing audit triggers unchanged.
--
-- REVERSIBLE: see the teardown block at the bottom (commented).
-- IDEMPOTENT: re-runnable.
--
-- DEPLOYMENT STATUS:
--  * 2026-07-08 — DERM SUBSET DEPLOYED + PROVEN LIVE on Prod: the function, the
--    anon RLS policy, and the triggers on `derm_manifests` + `manifest_visits`
--    ONLY. End-to-end proof: an anon WS subscriber (no auth users) on
--    inval:derm_manifests + inval:manifest_visits received `{table,op,at}` from
--    real 0-row test writes (WHERE false → 0 rows touched, 0 audit rows, zero
--    data residue verified). Note: the delivered payload also carries a random
--    UUID `id` — that is the realtime.messages ENVELOPE id (the tables' own ids
--    are bigint / composite), NOT business data → still leak-free.
--  * PENDING (coordinate w/ Supabase 2): the `visits` + `clients` triggers below
--    (the hot shared tables). Run those two CREATE TRIGGER statements when ready.
-- ============================================================================

-- 1) The broadcast function ---------------------------------------------------
create or replace function public.tg_broadcast_inval()
  returns trigger
  language plpgsql
  security definer          -- always runs with owner rights, regardless of writer role
  set search_path = public, realtime
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object(
        'table', tg_table_name,
        'op',    tg_op,
        'at',    extract(epoch from clock_timestamp())
      ),
      'inval',                         -- event
      'inval:' || tg_table_name,       -- topic (matches the app channel name)
      true                             -- private channel
    );
  exception when others then
    -- A broadcast failure must NEVER break the actual data write.
    null;
  end;
  return null;  -- AFTER STATEMENT trigger
end;
$$;

comment on function public.tg_broadcast_inval() is
  'Statement-level AFTER trigger: emits a leak-free {table,op,at} realtime broadcast on inval:<table> so apps can invalidateQueries. Swallows all errors. See docs/migrations/2026-07-08_realtime_invalidation.sql';

-- 2) Attach to the core invalidation set -------------------------------------
--    (visits + clients + derm_manifests + manifest_visits — NOTE 5 core set)
--    Statement-level so bulk writes coalesce to a single signal.
drop trigger if exists zzz_broadcast_inval on public.visits;
create trigger zzz_broadcast_inval
  after insert or update or delete on public.visits
  for each statement execute function public.tg_broadcast_inval();

drop trigger if exists zzz_broadcast_inval on public.clients;
create trigger zzz_broadcast_inval
  after insert or update or delete on public.clients
  for each statement execute function public.tg_broadcast_inval();

drop trigger if exists zzz_broadcast_inval on public.derm_manifests;
create trigger zzz_broadcast_inval
  after insert or update or delete on public.derm_manifests
  for each statement execute function public.tg_broadcast_inval();

drop trigger if exists zzz_broadcast_inval on public.manifest_visits;
create trigger zzz_broadcast_inval
  after insert or update or delete on public.manifest_visits
  for each statement execute function public.tg_broadcast_inval();

-- 3) The one anon RLS policy — lets anon RECEIVE on inval:* private channels ONLY
--    (spike-proven: policy-only is sufficient; no table GRANT needed.)
drop policy if exists app_inval_read on realtime.messages;
create policy app_inval_read
  on realtime.messages
  for select
  to anon
  using (topic like 'inval:%');

-- 4) Phase 2 (Stamp Studio) — attach when Stamp Studio subscribes. Uncomment:
-- drop trigger if exists zzz_broadcast_inval on derm.address_row_map;
-- create trigger zzz_broadcast_inval
--   after insert or update or delete on derm.address_row_map
--   for each statement execute function public.tg_broadcast_inval();

-- ============================================================================
-- TEARDOWN (reversal) — run to fully remove:
-- drop policy if exists app_inval_read on realtime.messages;
-- drop trigger if exists zzz_broadcast_inval on public.visits;
-- drop trigger if exists zzz_broadcast_inval on public.clients;
-- drop trigger if exists zzz_broadcast_inval on public.derm_manifests;
-- drop trigger if exists zzz_broadcast_inval on public.manifest_visits;
-- -- drop trigger if exists zzz_broadcast_inval on derm.address_row_map;
-- drop function if exists public.tg_broadcast_inval();
-- ============================================================================
