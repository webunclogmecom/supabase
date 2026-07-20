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
--  * 2026-07-09 — PHASE 2 (Stamp Studio) DEPLOYED + PROVEN LIVE: trigger added to
--    `derm.address_row_map` (topic inval:address_row_map; anon inval:% policy
--    already covers it). DERM Stamp Studio wired + live-verified (backend write to
--    address_row_map AND derm_manifests each auto-refetch its v_stamp_sheets query;
--    idle = no refetch). DERM Tracker (07-09) + Stamp Studio (07-09) both on realtime.
--  * 2026-07-20 — PHASE 0 + 1a COMPLETE: the `visits` + `clients` triggers are
--    DEPLOYED (all 5 zzz_broadcast_inval triggers now live, all STATEMENT-level,
--    all enabled) and the Visit Calendar app is WIRED + PUBLISHED + LIVE-VERIFIED.
--    Backend proof: an ANON supabase-js subscriber (no auth user) SUBSCRIBED to
--    both inval:visits and inval:clients and received {table,op,at} from 0-row
--    (WHERE false) writes; row counts identical before/after (visits 2148,
--    clients 433) => zero data residue; payload carried no business columns.
--    App proof (calendar.unclogme.app, tab HIDDEN + unfocused throughout, so no
--    focus-refetch could contribute): 3 external 0-row writes to public.visits
--    produced exactly 3 refetch batches at +630ms / +518ms / +1023ms — the 400ms
--    debounce plus network. A 41s IDLE window produced ZERO fetches, proving the
--    app does not poll and every refetch is signal-driven. All REST calls hit
--    wbasvhvvismukaqdnouk (no Lovable Cloud repoint — parent CLAUDE.md rule #12).
--    NOTE worth keeping: an earlier 32s "idle" control saw 2 refetch batches. That
--    was NOT polling — it was real production writers (Jobber polls, pg_cron, the
--    other session) touching visits/clients. That is precisely the staleness class
--    this tier exists to fix, and it is now visibly working.
--  * 2026-07-20 (later) — ROOT-CAUSE FIX: the RLS policy was widened from
--    `to anon` to `to anon, authenticated`. DERM Tracker and Stamp Studio had
--    been receiving NOTHING since they were wired on 2026-07-09, because both
--    apps use real Supabase Auth sign-in (4 users in auth.users, 0 anonymous)
--    and an authenticated JWT did not match a policy scoped to `anon`.
--    Proof, with NO app code change whatsoever — only this policy edit:
--      - DERM Tracker: a 0-row write to derm_manifests now triggers all 5 of its
--        queries to refetch (visits, manifest_visits, manifests, manifest_health,
--        derm_manifests) with the tab HIDDEN; a 39s idle control produced ZERO
--        requests, so the refetch is signal-driven and not a poll.
--      - Stamp Studio self-reports in its console:
--        "[realtimeInvalidation] inval:derm_manifests → SUBSCRIBED" and
--        "inval:address_row_map → SUBSCRIBED" (it logs the error branch on
--        failure, which is what it had been doing).
--    The Visit Calendar was unaffected throughout: its Supabase client holds no
--    auth session, so it matched `anon` and worked from the start.
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

-- 3) The RLS policy — lets clients RECEIVE on inval:* private channels ONLY
--    (spike-proven: policy-only is sufficient; no table GRANT needed.)
--
-- ⚠ MUST cover BOTH `anon` AND `authenticated` (fixed 2026-07-20 — see below).
-- The original version granted `to anon` only. That silently broke every app
-- whose users actually SIGN IN: once a Supabase Auth session exists the client
-- sends an `authenticated` JWT, the policy no longer matches, the private
-- channel subscribe is DENIED, and the app receives nothing. It fails silently —
-- the code is correct, the trigger fires, the DB broadcasts, and the UI just
-- quietly stays stale. DERM Tracker and Stamp Studio ran this way from
-- 2026-07-09 to 2026-07-20 while both were documented as "live-verified".
--
-- Why it was missed: every verification used a raw anon-key subscriber (a Node
-- script or an unauthenticated tab), which matches `to anon` and passes. The
-- Visit Calendar also passed because its Supabase client carries no auth
-- session. **Verify realtime with a client in the SAME auth state as the real
-- app, not with the anon key.**
drop policy if exists app_inval_read on realtime.messages;
create policy app_inval_read
  on realtime.messages
  for select
  to anon, authenticated
  using (topic like 'inval:%');

-- 4) Phase 2 (Stamp Studio) — DEPLOYED 2026-07-09. Stamp Studio subscribes to
--    inval:address_row_map (+ inval:derm_manifests).
drop trigger if exists zzz_broadcast_inval on derm.address_row_map;
create trigger zzz_broadcast_inval
  after insert or update or delete on derm.address_row_map
  for each statement execute function public.tg_broadcast_inval();

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
