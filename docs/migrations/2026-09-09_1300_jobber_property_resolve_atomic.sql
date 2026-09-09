-- ============================================================================
-- 2026-09-09_1300_jobber_property_resolve_atomic.sql
--
-- The PROPERTY half of the visit/job/property race audit. Ships with _1200 (visit), _1230 (job).
--
-- ============================================================================
-- 🛑 THE LOCK KEY IS THE **CLIENT**, NOT THE PROPERTY GID. THIS IS THE WHOLE DESIGN.
--
-- Every other resolve function in this family keys on the entity's own Jobber GID. Properties
-- cannot, for two independent reasons, and using the gid here would produce a fix that verifies
-- green and serialises nothing:
--
-- (1) THE CONTENDED RESOURCE IS NOT THE GID, IT IS THE CLIENT'S PRIMARY SLOT.
--     uq_properties_one_primary_per_client is UNIQUE (client_id) WHERE is_primary = true. Two
--     properties with two DIFFERENT gids, belonging to one client, contend for it. Different gids
--     hash to different advisory keys, so a gid lock lets them straight through.
--
-- (2) 🛑 THE BIGGEST PROPERTY CREATOR DOES NOT HAVE A PROPERTY GID AT ALL.
--     handleClient's billing-address branch (webhook-jobber/index.ts:626-687) links its row as
--     `<CLIENT_gid>_billing` -- a synthetic source_id built from the client. **452 of the property
--     links in production end in `_billing`**, so this is the dominant path, not an edge case. It
--     and handleProperty can never share a gid-derived key.
--
-- Keying on the client covers BOTH races at once, because a property belongs to exactly one client
-- and both contended resources -- the gid link and the primary slot -- live inside that client's
-- scope.
--
-- ============================================================================
-- THE TWO FAILURE MODES ARE OPPOSITE, AND ONLY ONE OF THEM IS LOUD
--
-- FIRST property for a client: both writers see no primary, both insert is_primary=true, the
--   second raises 23505 on uq_properties_one_primary_per_client. Because webhook-jobber ACKs
--   HTTP 200 before doing the work and nothing re-processes webhook_events_log, **Jobber never
--   retries and the event is LOST FOREVER.** This fired for real on 2026-09-02 21:07:32 and was
--   rescued only by an unrelated PROPERTY_UPDATE 14 seconds later.
--
-- SECOND-or-later property: both compute is_primary=false, the unique index does not apply, both
--   rows COMMIT, and the loser's link write hits idx_esl_source_id -- leaving an orphan property
--   with no announcement beyond one webhook_events_log row.
--
-- ⚠ The guard is far weaker than it looks. Of 468 clients, 465 already hold a primary, so the
--   loud-and-lossy first-property path is reachable for only 3 existing clients plus every newly
--   created one. **Everything else lands in the silent second path.** 481 properties sit in that
--   unguarded region.
--
-- ⚠ It has not produced a duplicate yet purely by TIMING: PROPERTY_CREATE is double-delivered 11
--   times and **0 of those pairs land under one second apart** (narrowest 1,777ms against handler
--   runs up to 1,967ms). Compare VISIT_CREATE, where 155 of 160 pairs are sub-second. Properties
--   are not protected; they are slow.
--
-- ============================================================================
-- THE is_primary DECISION MOVES INTO SQL BECAUSE BOTH TYPESCRIPT COPIES FAIL **OPEN**
--
-- handleProperty (:1452) leaves isPrimary undefined on a failed read, so the column DEFAULT of
-- true applies. handleClient (:660) computes `!(existingPrimary && existingPrimary.length > 0)`,
-- and on a failed read that is `!undefined` = true. **Both discard the error and both fail toward
-- CLAIMING the slot** -- the worst direction, because claiming is what collides. A lock alone
-- would fix the concurrency and leave the transport-failure path producing is_primary=true anyway.
-- Inside the function the read cannot half-fail: it either returns a row or it does not.
--
-- ============================================================================
-- ALSO FIXED HERE: uq_properties_one_primary_per_client IGNORED SOFT DELETES
--
-- The index had no `deleted_at IS NULL`, while its sibling properties_live_idx has one -- the two
-- disagreed about what a property is. handlePropertyDestroy sets deleted_at and never clears
-- is_primary, so a destroyed primary would hold the slot **permanently**: the default-true insert
-- raises 23505 forever, the guarded path forces is_primary=false forever, and client.properties
-- (which filters deleted_at IS NULL) shows the client as having no primary at all. A race turned
-- into a silent permanent dead end.
--
-- Latent today, which is why it is safe to fix now: 0 clients have >1 live primary and 0
-- soft-deleted properties are primary, so the rebuilt index selects exactly the same 465 rows.
--
-- ⚠ NOT changed: handlePropertyDestroy still does not demote. With the new predicate it no longer
--   needs to for correctness -- the slot is released on soft delete -- but the client is then left
--   with no primary until another property arrives. That is a data-quality question, not a race,
--   and it is listed as open rather than decided here.
--
-- ============================================================================
-- OUT OF SCOPE, WITH THE EVIDENCE FOR THE CALL
--
-- webhook-samsara/index.ts:160 is a THIRD writer of the primary slot and the worst-behaved of the
-- three: it inserts `is_primary: true` **hardcoded, with no check at all**. It is not joined to
-- this lock because the path is dormant -- 8 samsara webhook events in the entire log, the last on
-- 2026-08-31, and all 282 samsara property links were created 2026-05-12..2026-07-05 by the bulk
-- import, not by the webhook. Joining it means deploying a second, unrelated integration to fix a
-- path that has not created a property in three months. Recorded as open, not silently skipped.
--
-- Audit: creates one function, rebuilds one index. It modifies no business rows.
-- ============================================================================

begin;

-- ⚠ The index rebuild below takes ACCESS EXCLUSIVE on public.properties, a table 18 views and every
--   app read from. The applying session runs as `postgres`, whose lock_timeout is 0, so without
--   this it would queue behind any in-flight reader and block every property write that arrives
--   after it. 3s converts an unbounded queue into a clean 55P03 that rolls the whole transaction
--   back and is simply re-run. Precedent: 2026-07-30_1156_visit_requests_to_be_scheduled.sql.
set local lock_timeout = '3s';

-- ---------------------------------------------------------------------------
-- 1. the primary slot must ignore retired properties
-- ---------------------------------------------------------------------------
drop index if exists public.uq_properties_one_primary_per_client;
create unique index uq_properties_one_primary_per_client
    on public.properties (client_id)
 where is_primary = true and deleted_at is null;

-- ---------------------------------------------------------------------------
-- 2. the resolve function
-- ---------------------------------------------------------------------------
create or replace function public.fn_jobber_resolve_property(
  p_gid       text,
  p_client_id bigint
)
returns table (entity_id bigint, was_created boolean, assigned_primary boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id      bigint;
  v_primary boolean;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_property: p_gid is required';
  end if;

  -- ---- FAST PATH: already linked. No lock. -------------------------------------------------
  -- 7,845 PROPERTY_UPDATEs against 43 creates. Only the create path pays.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'property' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false, false;
    return;
  end if;

  -- 🛑 THE client_id CHECK SITS **AFTER** THE FAST PATH, AND THAT ORDER IS LOAD-BEARING.
  -- On the UPDATE path handleProperty legitimately holds a NULL clientId: its defer-if-orphan
  -- guard is `if (!existingId && !clientId)`, so a property we ALREADY hold is processed even when
  -- its Jobber client has not been resolved this pass. Raising before the fast path would turn
  -- every one of those into a failed PROPERTY_UPDATE. client_id is needed only to CREATE (the
  -- column is NOT NULL with no default) and to key the lock, so it is required only from here.
  if p_client_id is null then
    raise exception 'fn_jobber_resolve_property: p_client_id is required to create a property (properties.client_id is NOT NULL)';
  end if;

  -- ---- SLOW PATH: serialise every property creator for THIS CLIENT --------------------------
  -- 🛑 Keyed on the client, not the gid. See the header: the billing branch has no property gid,
  --    and the primary slot is a per-client resource. A gid key would serialise nothing.
  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:client-props:' || p_client_id::text, 0));

  -- 🛑 THIS RE-READ IS THE FIX. The first read happened BEFORE the lock and saw the world as it was
  -- before the winner committed.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'property' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false, false;
    return;
  end if;

  -- The primary decision, computed under the lock. Cannot fail open: this either finds a live
  -- primary or it does not, and there is no transport in between to swallow an error.
  select not exists (
           select 1 from public.properties p
            where p.client_id = p_client_id
              and p.is_primary
              and p.deleted_at is null)
    into v_primary;

  insert into public.properties (client_id, is_primary)
       values (p_client_id, v_primary)
    returning id into v_id;

  -- Same transaction as the row above: if this fails the property goes with it and the caller gets
  -- an error instead of an orphan.
  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id,
          match_method, match_confidence, synced_at)
       values ('property', v_id, 'jobber', p_gid, 'webhook', 1.0, pg_catalog.now());

  return query select v_id, true, v_primary;
end
$fn$;

revoke all on function public.fn_jobber_resolve_property(text, bigint) from public;
revoke all on function public.fn_jobber_resolve_property(text, bigint) from anon;
revoke all on function public.fn_jobber_resolve_property(text, bigint) from authenticated;
grant execute on function public.fn_jobber_resolve_property(text, bigint) to service_role;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_body text;
  v_def  text;
  v_n    bigint;
begin
  -- 1. the function exists, locks, and re-reads
  if pg_catalog.to_regprocedure('public.fn_jobber_resolve_property(text, bigint)') is null then
    raise exception 'VERIFY 1 FAILED: fn_jobber_resolve_property(text,bigint) does not exist';
  end if;
  v_body := pg_catalog.pg_get_functiondef(
              pg_catalog.to_regprocedure('public.fn_jobber_resolve_property(text, bigint)')::oid);
  v_body := pg_catalog.replace(v_body, pg_catalog.chr(13), '');   -- CRLF-proof, see _1200
  if v_body !~ 'pg_advisory_xact_lock' then
    raise exception 'VERIFY 1b FAILED: no advisory lock';
  end if;
  select (pg_catalog.length(v_body)
          - pg_catalog.length(pg_catalog.replace(v_body, 'from public.entity_source_links l' || E'\n', '')))
         / pg_catalog.length('from public.entity_source_links l' || E'\n')
    into v_n;
  if v_n < 2 then
    raise exception 'VERIFY 1c FAILED: the link is read % time(s); the re-read after the lock is missing', v_n;
  end if;
  -- The count alone passes against a body whose lock was moved BELOW both reads. Assert position.
  if pg_catalog.strpos(
       pg_catalog.substr(v_body, pg_catalog.strpos(v_body, 'pg_advisory_xact_lock')),
       'from public.entity_source_links l' || E'
') = 0 then
    raise exception 'VERIFY 1c-bis FAILED: no link read appears AFTER the advisory lock; the fix is inert';
  end if;

  -- 2. 🛑 THE KEY MUST BE THE CLIENT. If someone "tidies" this to the gid to match its three
  --    siblings, the billing branch stops serialising and the fix silently dies. Assert the
  --    client key is present AND that the gid key is NOT.
  if v_body !~ 'jobber:client-props:' then
    raise exception 'VERIFY 2a FAILED: the lock is not keyed on the client; the billing branch will not serialise';
  end if;
  if v_body ~ 'jobber:property:' then
    raise exception 'VERIFY 2b FAILED: the lock was changed to a per-gid key; read the header before doing that';
  end if;

  -- 3. the is_primary decision is INSIDE the function, not inherited from the column default
  if v_body !~ 'not exists' or v_body !~ 'is_primary' then
    raise exception 'VERIFY 3 FAILED: the is_primary decision is not computed in the function';
  end if;
  if v_body !~ 'deleted_at is null' then
    raise exception 'VERIFY 3b FAILED: the primary probe counts soft-deleted rows';
  end if;

  -- 4. the index gained the soft-delete predicate and still covers the same rows
  select pg_catalog.pg_get_indexdef(i.indexrelid) into v_def
    from pg_catalog.pg_index i
   where i.indexrelid = 'public.uq_properties_one_primary_per_client'::pg_catalog.regclass;
  if v_def is null then
    raise exception 'VERIFY 4 FAILED: uq_properties_one_primary_per_client is gone';
  end if;
  if v_def !~ 'deleted_at IS NULL' then
    raise exception 'VERIFY 4b FAILED: the index still ignores soft deletes: %', v_def;
  end if;
  if v_def !~ 'UNIQUE' then
    raise exception 'VERIFY 4c FAILED: the rebuilt index is not UNIQUE: %', v_def;
  end if;

  -- 5. 🛑 THIS ASSERTION WAS A TAUTOLOGY IN THE FIRST DRAFT AND ITS COMMENT CLAIMED THE OPPOSITE.
  --    It counted clients holding more than one LIVE primary and required 0 -- which the unique
  --    index created 30 lines above makes physically impossible. It could never fail, under a
  --    comment reading "a check shaped like the change can only confirm the change". Replaced with
  --    the one thing the NEW predicate genuinely stops enforcing: the rebuilt index permits a
  --    soft-deleted primary, where the old one did not. That is 0 today, which is exactly why the
  --    rebuild is a provable no-op, and it is a real number that can move.
  select pg_catalog.count(*) into v_n
    from public.properties p where p.is_primary and p.deleted_at is not null;
  if v_n <> 0 then
    raise exception 'VERIFY 5 FAILED: % soft-deleted primary propert(ies) exist, so the rebuilt index no longer constrains rows the old one did; the no-op claim in this header is false', v_n;
  end if;

  -- 5b. And the property the index DOES still enforce, asserted over the whole live population
  --     rather than over the rows this migration touched.
  select pg_catalog.count(*) into v_n
    from (select p.client_id from public.properties p
           where p.is_primary and p.deleted_at is null
           group by p.client_id having pg_catalog.count(*) > 1) z;
  if v_n <> 0 then
    raise exception 'VERIFY 5b FAILED: % client(s) hold more than one live primary property', v_n;
  end if;

  -- 6. NEGATIVE CONTROLS. Both arguments must genuinely be required.
  begin
    perform * from public.fn_jobber_resolve_property(null, 1::bigint);
    raise exception 'VERIFY 6 FAILED: a NULL gid was accepted';
  exception when others then
    if sqlerrm like '%VERIFY 6 FAILED%' then raise; end if;
    if sqlerrm not like '%p_gid is required%' then
      raise exception 'VERIFY 6b FAILED: wrong error for a NULL gid: %', sqlerrm;
    end if;
  end;
  begin
    perform * from public.fn_jobber_resolve_property('gid://test/nonexistent', null);
    raise exception 'VERIFY 6c FAILED: a NULL client_id was accepted';
  exception when others then
    if sqlerrm like '%VERIFY 6c FAILED%' then raise; end if;
    if sqlerrm not like '%p_client_id is required%' then
      raise exception 'VERIFY 6d FAILED: wrong error for a NULL client_id: %', sqlerrm;
    end if;
  end;

  -- 6e. 🛑 THE ORDERING TEST, AND IT IS THE MOST IMPORTANT ASSERTION IN THIS FILE.
  --     An ALREADY-LINKED property must resolve with a NULL p_client_id, because handleProperty
  --     legitimately passes one on the UPDATE path (its defer guard is `!existingId && !clientId`).
  --     I wrote the client_id check ABOVE the fast path first; that version would have failed every
  --     PROPERTY_UPDATE for a property whose client was not resolved in the same pass — 7,845
  --     PROPERTY_UPDATEs against 43 creates, so it would have broken the dominant path.
  --     This is read-only: the fast path takes no lock and writes nothing.
  declare
    v_gid    text;
    v_expect bigint;
    v_got    bigint;
    v_made   boolean;
  begin
    select l.source_id, l.entity_id into v_gid, v_expect
      from public.entity_source_links l
     where l.entity_type = 'property' and l.source_system = 'jobber'
     order by l.entity_id
     limit 1;
    if v_gid is null then
      raise exception 'VERIFY 6e FAILED: no linked property exists, so the ordering test is an untested instrument';
    end if;

    select r.entity_id, r.was_created into v_got, v_made
      from public.fn_jobber_resolve_property(v_gid, null) r;

    if v_got is distinct from v_expect then
      raise exception 'VERIFY 6e FAILED: the fast path returned % for gid %, expected %', v_got, v_gid, v_expect;
    end if;
    if v_made then
      raise exception 'VERIFY 6e FAILED: the fast path reported was_created on an existing property';
    end if;
    raise notice 'VERIFY 6e ok: an already-linked property resolves to % with a NULL client_id', v_got;
  end;

  -- 7. grants
  if pg_catalog.has_function_privilege('anon', 'public.fn_jobber_resolve_property(text, bigint)', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'public.fn_jobber_resolve_property(text, bigint)', 'EXECUTE') then
    raise exception 'VERIFY 7 FAILED: a non-service role can execute the property factory';
  end if;
  if not pg_catalog.has_function_privilege('service_role', 'public.fn_jobber_resolve_property(text, bigint)', 'EXECUTE') then
    raise exception 'VERIFY 7b FAILED: service_role CANNOT execute it; the webhook would break';
  end if;

  -- 8. 🛑 EXERCISE THE CREATE PATH. Every assertion above reads text, catalogue or existing rows;
  --    not one of them runs a single write statement in this function. PL/pgSQL is not parsed at
  --    CREATE time, so a wrong column name or a missed NOT NULL would ship green and fire on the
  --    first real PROPERTY_CREATE -- against a handler that has already ACKed HTTP 200, with no
  --    retry. Rolled back inside a savepoint; a bare DO block would COMMIT.
  declare
    v_c_with    bigint;
    v_c_without bigint;
    v_id        bigint;
    v_id2       bigint;
    v_made      boolean;
    v_prim      boolean;
    v_links     bigint;
  begin
    -- a client that already holds a live primary, and one that does not
    select p.client_id into v_c_with
      from public.properties p where p.is_primary and p.deleted_at is null
     order by p.client_id limit 1;
    select c.id into v_c_without
      from public.clients c
     where not exists (select 1 from public.properties p
                        where p.client_id = c.id and p.is_primary and p.deleted_at is null)
     order by c.id limit 1;
    if v_c_with is null then
      raise exception 'VERIFY 8 FAILED: no client holds a live primary, so the is_primary assertion is an untested instrument';
    end if;

    begin
      -- (a) a client that ALREADY has a primary must not get a second one
      select r.entity_id, r.was_created, r.assigned_primary into v_id, v_made, v_prim
        from public.fn_jobber_resolve_property('VERIFY_2026-09-09_1300_a', v_c_with) r;
      if not v_made then raise exception 'VERIFY 8a FAILED: a brand-new gid did not report was_created'; end if;
      if v_prim then
        raise exception 'VERIFY 8b FAILED: assigned_primary=true for client %, which already holds one', v_c_with;
      end if;

      -- exactly one link, and it points at the new row
      select pg_catalog.count(*) into v_links from public.entity_source_links l
       where l.entity_type = 'property' and l.source_system = 'jobber'
         and l.source_id = 'VERIFY_2026-09-09_1300_a' and l.entity_id = v_id;
      if v_links <> 1 then
        raise exception 'VERIFY 8c FAILED: the created property has % link(s), expected exactly 1', v_links;
      end if;

      -- (b) idempotence: the same gid must FIND, not create
      select r.entity_id, r.was_created into v_id2, v_made
        from public.fn_jobber_resolve_property('VERIFY_2026-09-09_1300_a', v_c_with) r;
      if v_id2 is distinct from v_id or v_made then
        raise exception 'VERIFY 8d FAILED: the second call returned % (was_created=%), expected % / false', v_id2, v_made, v_id;
      end if;

      -- (c) a client with NO live primary must be GIVEN one
      if v_c_without is not null then
        select r.assigned_primary into v_prim
          from public.fn_jobber_resolve_property('VERIFY_2026-09-09_1300_b', v_c_without) r;
        if not v_prim then
          raise exception 'VERIFY 8e FAILED: client % has no live primary but assigned_primary came back false', v_c_without;
        end if;
      end if;

      raise exception 'VERIFY_8_ROLLBACK';
    exception when others then
      if sqlerrm <> 'VERIFY_8_ROLLBACK' then raise; end if;
    end;
    raise notice 'VERIFY 8 ok: create path exercised, is_primary computed correctly in both directions, link written exactly once, idempotent on re-call';
  end;

  raise notice 'VERIFY ok: fn_jobber_resolve_property locked ON THE CLIENT, re-reads AFTER the lock, computes is_primary internally, create path exercised, index now ignores soft deletes, no client holds two live primaries';
end
$verify$;
