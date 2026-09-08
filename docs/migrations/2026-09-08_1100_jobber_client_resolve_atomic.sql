-- ============================================================================
-- 2026-09-08_1100_jobber_client_resolve_atomic.sql
--
-- Make "find the client for this Jobber GID, or create it" ATOMIC, so two
-- concurrent handlers can no longer both decide the client is missing and both create it.
--
-- Fred, 2026-09-08: "there is a client called Bibi's Burger which we have it empty but in
-- jobber have data for it."
--
-- ============================================================================
-- WHAT WAS ACTUALLY WRONG. It is not one empty client, it is FOUR rows from one Jobber client.
--
--   Jobber client 151261972 ("Bibi's burgers") -> our clients 573, 574, 575, 576.
--   All four INSERTed 2026-09-01 20:56:47.949 .. 48.051 (about 100ms), app_source='jobber',
--   and FOUR DIFFERENT txids (2919390/2919391/2919397/2919404) = four concurrent transactions.
--   Only 573 got an entity_source_links row. 574/575/576 have NO link: 0 properties, 0 jobs,
--   0 visits, 0 contacts, client_code NULL. Invisible to every sync, forever.
--
-- The three losers are recorded verbatim in public.webhook_events_log:
--   "entity_source_links upsert failed: duplicate key value violates unique constraint
--    idx_esl_source_id"
--
-- THE MECHANISM, in webhook-jobber/index.ts handleClient:
--   L358  findEntityBySourceId('client','jobber',gid)   -- a plain SELECT
--   L540  supabaseJobber.from('clients').insert(...)    -- a SECOND HTTP request
--   L552  upsertEntityLink(...)                         -- a THIRD HTTP request
-- Three PostgREST calls means THREE transactions, so nothing spans them. N concurrent handlers
-- all read "not found", all INSERT, then race for the link.
--
-- 🛑 AND THE ON CONFLICT TARGET DOES NOT MATCH THE INDEX THAT ACTUALLY FIRES.
--    upsertEntityLink passes  onConflict: (entity_type, entity_id, source_system)
--    the index that raises is idx_esl_source_id (entity_type, source_system, source_id)
--    Different column sets, so ON CONFLICT cannot absorb it: it raises 23505. The winner keeps
--    the link; every loser's client row is ALREADY COMMITTED and is orphaned on the spot.
--    (This is the same lesson the Client App ledger already carries: an upsert is not a lock.)
--
-- 🛑 THE TRIGGER WAS TURNING REAL JOBBER WEBHOOKS ON, 2026-08-21.
--    Webhook-only topics (CLIENT_CREATE, JOB_CLOSED, QUOTE_SENT, VISIT_COMPLETE) appear in
--    webhook_events_log first on 2026-08-21 and in NONE of the 42,449 rows before it. From that
--    day the */5 poll replay and the live webhook both drive handleClient for the same client.
--    Measured: 84 clients created 2026-05-01 -> 2026-08-21 produced ZERO orphans; 8 orphans since.
--    The poll alone was safe (its replay loop is sequential). Two drivers are not.
--
-- ⚠ IT IS NOT CLIENTS-ONLY. Unlinked rows created since 2026-08-21: invoices 57, quotes 9,
--   clients 8. 76 idx_esl_source_id failures in all, the most recent on 2026-09-08. This
--   migration fixes the CLIENT path only, which is what was asked for. The same treatment is a
--   copy-paste for the others and is deliberately NOT bundled here: invoices are billing.
--
-- ============================================================================
-- THE FIX: one database call that holds a lock across the check and the insert.
--
-- fn_jobber_resolve_client() does find-or-create INSIDE ONE TRANSACTION, serialised per GID by
-- a transaction-scoped advisory lock. The loser of the lock re-reads AFTER the winner committed
-- and finds the row, so it never inserts. A duplicate becomes IMPOSSIBLE rather than detected.
--
-- ⚠ WHY AN ADVISORY LOCK AND NOT "JUST ADD ON CONFLICT". ON CONFLICT DO UPDATE never raises, so
--   it cannot tell a caller it lost -- it would happily give two callers two different client ids
--   and leave the second one orphaned exactly as today. The lock is what makes the second caller
--   WAIT and then agree. Prevention, not detection.
--
-- ⚠ THE LOCK IS pg_advisory_xact_lock, NOT the session form. PostgREST runs each request in its
--   own transaction, so the lock is released on commit and there is nothing to leak. Never swap
--   this for pg_advisory_lock: a connection-pooled session lock would outlive the request and
--   deadlock the pool.
--
-- ⚠ THE FAST PATH TAKES NO LOCK, on purpose. The overwhelming majority of calls are updates to a
--   client we already hold (3,344 CLIENT_UPDATEs in 30 days vs 30 creates). Locking those would
--   serialise the whole poll for no benefit. Only the create path pays.
--
-- ⚠ ATTRIBUTION IS PRESERVED. The caller invokes this through `supabaseJobber`, whose
--   `x-app-source: jobber` header PostgREST exposes to the audit trigger as request.headers, so
--   the shell INSERT still audits as app_source='jobber' and not 'sql'. Call it with any other
--   client and you silently lose that.
--
-- ⚠ THE SHELL IS A REAL ROW AND FIRES trg_client_default_location, exactly as the old INSERT did,
--   so the "Main" client_locations row still appears. Behaviour is unchanged; only atomicity is added.
--
-- Audit: N/A (one function + grants). No data is modified by this migration.
-- ============================================================================

begin;

create or replace function public.fn_jobber_resolve_client(
  p_gid     text,
  p_name    text,
  p_class   text    default null,
  p_balance numeric default null,
  p_status  text    default 'ACTIVE'
)
returns table (entity_id bigint, was_created boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id bigint;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_client: p_gid is required';
  end if;
  -- clients.name is NOT NULL, so a blank name would 23502 halfway through and leave the caller
  -- with no id. Refuse up front instead: handleClient already falls back through
  -- companyName -> firstName+lastName -> Jobber's denormalised `name` before calling us.
  if p_name is null or pg_catalog.btrim(p_name) = '' then
    raise exception 'fn_jobber_resolve_client: p_name is required (public.clients.name is NOT NULL)';
  end if;

  -- ---- FAST PATH: already linked. No lock. -------------------------------------------------
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'client'
     and l.source_system = 'jobber'
     and l.source_id = p_gid;

  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  -- ---- SLOW PATH: we may have to create it. Serialise every creator of THIS gid. -----------
  -- hashtextextended gives a stable bigint key per GID, so two handlers for DIFFERENT clients
  -- never block each other -- only the two that would have produced the duplicate.
  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:client:' || p_gid, 0));

  -- 🛑 THIS RE-READ IS THE FIX. Do not "optimise" it away as a repeat of the check above: the
  -- first read happened BEFORE the lock, so it saw the world before the winner committed. This
  -- one happens after, and it is the only reason the loser stops instead of inserting.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'client'
     and l.source_system = 'jobber'
     and l.source_id = p_gid;

  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  insert into public.clients (name, status, client_class, balance)
       values (pg_catalog.btrim(p_name), coalesce(p_status, 'ACTIVE'), p_class, p_balance)
    returning id into v_id;

  -- Same transaction as the client INSERT, so if this fails the client row goes with it and the
  -- caller gets an error instead of an orphan. That is the whole point.
  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id, source_name,
          match_method, match_confidence, synced_at)
       values ('client', v_id, 'jobber', p_gid, pg_catalog.btrim(p_name),
          'webhook', 1.0, pg_catalog.now());

  return query select v_id, true;
end
$fn$;

comment on function public.fn_jobber_resolve_client(text, text, text, numeric, text) is
  'Atomically resolve a Jobber client GID to our clients.id, creating a shell row + its '
  'entity_source_links row together if it is new. Returns (entity_id, was_created). '
  'Serialised per GID by a transaction-scoped advisory lock, which is what makes a duplicate '
  'IMPOSSIBLE rather than merely detected: before 2026-09-08 webhook-jobber did SELECT then '
  'INSERT then link as three separate PostgREST requests, and concurrent handlers produced '
  '8 orphan clients (Bibi''s burgers = 4 rows from 1 Jobber client). Call it through a client '
  'sending x-app-source: jobber so the audit row keeps its attribution.';

-- Default privileges on a new function are EXECUTE TO PUBLIC, and revoking FROM PUBLIC alone does
-- not remove a grant already held by a named role. Revoke by name, then grant only service_role.
revoke all on function public.fn_jobber_resolve_client(text, text, text, numeric, text) from public;
revoke all on function public.fn_jobber_resolve_client(text, text, text, numeric, text) from anon;
revoke all on function public.fn_jobber_resolve_client(text, text, text, numeric, text) from authenticated;
grant execute on function public.fn_jobber_resolve_client(text, text, text, numeric, text) to service_role;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_id1 bigint; v_id2 bigint; v_c1 boolean; v_c2 boolean;
  v_gid   text := 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNTEyNjE5NzI=';   -- Bibi's burgers, client 573
  v_fake  text := 'VERIFY_2026-09-08_1100_fake_gid_do_not_use';
  v_body  text;
  v_before bigint; v_after bigint;
begin
  -- 1. fast path resolves the REAL Bibi gid to the linked row, and reports it as pre-existing
  select r.entity_id, r.was_created into v_id1, v_c1
    from public.fn_jobber_resolve_client(v_gid, 'Bibi''s burgers') r;
  if v_id1 <> 573 then
    raise exception 'VERIFY 1 FAILED: Bibi gid resolved to %, expected 573', v_id1;
  end if;
  if v_c1 then
    raise exception 'VERIFY 1b FAILED: an EXISTING client was reported as was_created=true';
  end if;

  -- 2. create path: a fresh gid creates exactly ONE client, and the second call ADOPTS it.
  --    This is the idempotency the old code did not have.
  -- Count only the PROBE, never the whole table: the */5 poll can insert a real client
  -- mid-verify and a whole-table delta would fail for a reason that has nothing to do with us.
  select count(*) into v_before from public.clients where name = 'VERIFY probe client';

  select r.entity_id, r.was_created into v_id1, v_c1
    from public.fn_jobber_resolve_client(v_fake, 'VERIFY probe client') r;
  if not v_c1 then
    raise exception 'VERIFY 2 FAILED: a brand new gid did not report was_created=true';
  end if;

  select r.entity_id, r.was_created into v_id2, v_c2
    from public.fn_jobber_resolve_client(v_fake, 'VERIFY probe client') r;
  if v_id2 <> v_id1 then
    raise exception 'VERIFY 2b FAILED: second call returned % but first returned % -- NOT idempotent', v_id2, v_id1;
  end if;
  if v_c2 then
    raise exception 'VERIFY 2c FAILED: second call reported was_created=true; it would have duplicated';
  end if;

  select count(*) into v_after from public.clients where name = 'VERIFY probe client';
  if v_after <> v_before + 1 then
    raise exception 'VERIFY 2d FAILED: two calls created % clients, expected exactly 1', v_after - v_before;
  end if;

  -- 3. the link was written in the SAME transaction, so it must exist for the shell
  if not exists (select 1 from public.entity_source_links
                  where entity_type='client' and source_system='jobber'
                    and source_id=v_fake and entity_id=v_id1) then
    raise exception 'VERIFY 3 FAILED: client % created with NO link -- the orphan bug is still live', v_id1;
  end if;

  -- 4. CLEAN UP THE PROBE. A positive control on a write path COMMITS; leaving it behind would
  --    put a fake client in the Client App. client_locations cascades with the client.
  delete from public.entity_source_links
   where entity_type='client' and source_system='jobber' and source_id=v_fake;
  delete from public.clients where id = v_id1;
  if exists (select 1 from public.clients where id = v_id1) then
    raise exception 'VERIFY 4 FAILED: probe client % survived cleanup', v_id1;
  end if;

  -- 5. NEGATIVE CONTROL: a blank name must be refused, not inserted as ''
  begin
    perform * from public.fn_jobber_resolve_client(v_fake || '_blank', '   ');
    raise exception 'VERIFY 5 FAILED: a blank name was accepted';
  exception when others then
    if sqlerrm not like '%p_name is required%' then
      raise exception 'VERIFY 5b FAILED: blank name raised the wrong error: %', sqlerrm;
    end if;
  end;

  -- 6. THE LOCK IS ACTUALLY IN THE SHIPPED BODY. Comments are stripped first, because the
  --    comments above NAME the function and would satisfy this assertion on their own.
  select pg_get_functiondef('public.fn_jobber_resolve_client(text,text,text,numeric,text)'::regprocedure)
    into v_body;
  select string_agg(l, e'\n') into v_body
    from unnest(string_to_array(v_body, e'\n')) l
   where btrim(l) not like '--%';
  if v_body not like '%pg_advisory_xact_lock%' then
    raise exception 'VERIFY 6 FAILED: no advisory lock in the function body -- the race is NOT closed';
  end if;
  if v_body like '%pg_advisory_lock(%' then
    raise exception 'VERIFY 6b FAILED: a SESSION advisory lock is present; it would leak across the pooler';
  end if;

  -- 7. not reachable by the browser roles
  if has_function_privilege('anon',
       'public.fn_jobber_resolve_client(text,text,text,numeric,text)', 'EXECUTE') then
    raise exception 'VERIFY 7 FAILED: anon can execute it';
  end if;
  if has_function_privilege('authenticated',
       'public.fn_jobber_resolve_client(text,text,text,numeric,text)', 'EXECUTE') then
    raise exception 'VERIFY 7b FAILED: authenticated can execute it';
  end if;
  if not has_function_privilege('service_role',
       'public.fn_jobber_resolve_client(text,text,text,numeric,text)', 'EXECUTE') then
    raise exception 'VERIFY 7c FAILED: service_role CANNOT execute it -- the webhook would break';
  end if;

  raise notice 'VERIFY ok: fast path resolves 573 without creating; a fresh gid creates exactly one client+link and the second call adopts it; blank name refused; xact advisory lock present; anon/authenticated cannot execute';
end
$verify$;
