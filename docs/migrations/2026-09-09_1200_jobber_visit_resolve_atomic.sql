-- ============================================================================
-- 2026-09-09_1200_jobber_visit_resolve_atomic.sql
--
-- Fred: "Then do an audit to the visits, jobs and properties race too."
--
-- Closes the create race in webhook-jobber's handleVisit, the same way
-- 2026-09-08_1100 (client) and 2026-09-08_1300 (invoice/quote) closed theirs.
-- This migration is the VISIT half. Job and property ship alongside it as _1230 and _1300.
--
-- ============================================================================
-- WHAT ACTUALLY HAPPENED, MEASURED. 🛑 READ THIS BEFORE THE 8049/8050 STORY ANYWHERE ELSE.
--
-- Two visits exist for one Jobber visit:
--   8049  created 2026-09-09 00:15:46.700163Z  LINKED    (esl 181700, .732421Z, method 'webhook')
--   8050  created 2026-09-09 00:15:46.774661Z  NO LINK   <- the phantom, removed by _1330
--
-- 🛑 MY FIRST READING OF THIS WAS WRONG AND IS RECORDED HERE SO NOBODY REPEATS IT.
-- visits.source on row 8049 reads 'visit-calendar' TODAY, and I concluded from that column alone
-- that the Calendar created 8049 and that Jobber's echo raced `jobber-push-visit`'s link write.
-- That story is FALSE. audit.logs holds the INSERTs themselves:
--   8049 INSERT .700163Z  app_source='jobber'  new_row.source='jobber'  txid 3211488
--   8050 INSERT .774661Z  app_source='jobber'  new_row.source='jobber'  txid 3211493
--   8049 UPDATE 01:04:05.360113Z  source 'jobber' -> 'visit-calendar'  origin calendar.unclogme.app
-- The column changed 48 MINUTES LATER from an office edit. And the decisive mechanism:
--   trg_push_visit_insert WHEN ((new.source = ANY (ARRAY['visit-calendar','supabase_cron'])))
-- 8049 was inserted as source='jobber', so the trigger never fired and `jobber-push-visit` was
-- never involved at all. The 32ms is webhook-jobber's OWN gap between its INSERT (.700163) and
-- its OWN upsertEntityLink (.732421).
--
-- ⇒ **This is handleVisit racing ITSELF on a double-delivered VISIT_CREATE**, which is exactly the
--   invoice shape. A gid-keyed lock inside handleVisit alone DOES close it.
-- ⇒ The general lesson, and it is the reusable one: **a mutable column read TODAY is not evidence
--   of its value at INSERT.** `visits.source` is rewritten at runtime (22 jobber -> visit-calendar
--   flips in 90 days). The audit trail was the only instrument that could answer the question, and
--   I built a design argument for several minutes before consulting it.
--
-- The driver: Jobber DOUBLE-DELIVERS. 160 VISIT_CREATE event_ids delivered 2+ times, and
-- **155 of them land UNDER ONE SECOND apart (minimum 0.000s)** against a handler that runs
-- 500-900ms. The two deliveries overlap essentially always. Both confirmed incidents are this
-- shape: 7883/7884 (2026-08-31 14:26:01, 13ms apart) and 8049/8050 (74ms apart).
--
-- ============================================================================
-- WHY THIS IS NOT A COPY OF THE INVOICE FUNCTION
--
-- 1. 🛑 `INSERT ... DEFAULT VALUES` IS IMPOSSIBLE HERE. public.visits is NOT NULL on `visit_date`
--    with NO DEFAULT, so the invoice template's shell insert raises 23502. The function therefore
--    takes a real payload. The invoice migration's own header says "do NOT improve these by
--    passing the payload in"; that instruction is correct FOR INVOICES and wrong for visits, and
--    the difference is a table constraint, not a preference.
--
-- 2. 🛑 THE CREATE PATH IS create-OR-PROMOTE, AND A GID-ONLY SHELL WOULD SILENTLY DEFEAT IT.
--    handleVisit may claim an existing supabase_cron placeholder instead of inserting. If the
--    resolve function did not know about promotion it would insert a fresh row every time and
--    leave the placeholder orphaned -- manufacturing a duplicate for every recurring visit, which
--    is worse than the bug being fixed. So client_id / service_type / visit_date are arguments.
--
-- 3. 🛑 NO CONSTRAINT TRIGGER. Invoices got `trg_zz_invoice_requires_jobber_link` because an
--    invoice can only originate in Jobber. **A visit cannot have that guard**: 520 alive visits
--    legitimately carry no link because the Calendar and the SA generator create them here and
--    push them later. Copying that trigger would refuse the Calendar. Do not add it.
--
-- ============================================================================
-- TWO LATENT BUGS IN THE PROMOTION PREDICATE, FIXED HERE
--
-- The TypeScript candidate query filtered client_id + service_type + visit_status='scheduled' +
-- source='supabase_cron' + visit_date +/- 7 days. It did NOT filter on:
--
-- (a) **deleted_at.** It could promote a SOFT-DELETED placeholder, resurrecting a visit somebody
--     removed. 336 soft-deleted supabase_cron rows exist to be resurrected.
--
-- (b) **an existing link.** 753 rows are promotion candidates today and **238 of them already
--     hold a jobber link.** Promoting one of those re-links it, and because upsertEntityLink names
--     ON CONFLICT (entity_type, entity_id, source_system), the write does NOT raise -- it UPDATEs
--     `source_id` in place, **silently repointing a live Jobber visit's link to a different Jobber
--     visit.** entity_source_links carries ZERO triggers, so there is no audit row either. That is
--     strictly worse than the 8050 bug, which at least announced itself with a 23505.
--
-- Both are closed below. The candidate SELECT also takes FOR UPDATE SKIP LOCKED, because the
-- per-gid advisory lock does NOT serialise two DIFFERENT gids competing for the SAME placeholder
-- (different lock keys). Skipping is the correct loss behaviour: the loser inserts its own row
-- rather than stealing one.
--
-- ============================================================================
-- WHAT IS DELIBERATELY *NOT* IN SCOPE, AND WHY
--
-- `jobber-push-visit`'s visitCreate + linkVisit is NOT moved into this lock.
--   - Zero measured instances. Both real incidents are handleVisit against itself.
--   - The lock CANNOT be held across its outbound HTTP call to Jobber anyway, so joining it would
--     buy a much larger change and still not close the window.
--   - Its own pre/post-create re-checks (jobber-push-visit/index.ts:620-643) already compensate.
--   Its mirror-image ON CONFLICT (entity_type, source_system, source_id) CAN silently steal a link
--   when it matches. That is real, unmeasured, and recorded in the reference doc as open. It is a
--   separate change and is not smuggled in here on the strength of a story that turned out false.
--
-- ⚠ lock_timeout is 8s (from the `authenticator` role; service_role inherits it). The locked
--   section below is two statements with NO outbound HTTP and is held for microseconds. A lock
--   wait that reached 8s would abort with 55P03 under an HTTP 200 that webhook-jobber has already
--   sent, and nothing re-processes webhook_events_log -- i.e. a timeout is PERMANENT event loss.
--   That is why nothing slow may ever be added inside the lock.
--
-- Audit: this migration creates one function. It modifies no business rows.
-- ============================================================================

begin;

create or replace function public.fn_jobber_resolve_visit(
  p_gid          text,
  p_visit_date   date,
  p_client_id    bigint default null,
  p_service_type text   default null
)
returns table (entity_id bigint, was_created boolean, was_promoted boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id bigint;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_visit: p_gid is required';
  end if;
  if p_visit_date is null then
    -- handleVisit already returns early when it cannot derive an operating date, so reaching here
    -- with NULL means the caller changed and the NOT NULL would fail one statement later with a
    -- far less useful message.
    raise exception 'fn_jobber_resolve_visit: p_visit_date is required (visits.visit_date is NOT NULL)';
  end if;

  -- ---- FAST PATH: already linked. No lock. -------------------------------------------------
  -- 75,319 VISIT_UPDATEs against 316 creates. Locking the update path would serialise the whole
  -- poll for nothing. Only the create path pays.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'visit' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false, false;
    return;
  end if;

  -- ---- SLOW PATH: serialise every creator of THIS gid ---------------------------------------
  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:visit:' || p_gid, 0));

  -- 🛑 THIS RE-READ IS THE FIX. The first read happened BEFORE the lock, so it saw the world as it
  -- was before the winner committed. This one happens after, and it is the only reason the loser
  -- stops instead of inserting a duplicate.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'visit' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false, false;
    return;
  end if;

  -- ---- PROMOTE an SA placeholder, if one genuinely matches ----------------------------------
  -- Keeps the cron's planned schedule and Jobber's actual execution as ONE row. Same predicate
  -- the TypeScript used (client + service_type + scheduled + supabase_cron + date within 7 days,
  -- closest date wins), PLUS the two filters it was missing.
  if p_client_id is not null and p_service_type is not null then
    select v.id into v_id
      from public.visits v
     where v.client_id     = p_client_id
       and v.service_type  = p_service_type
       and v.visit_status  = 'scheduled'
       and v.source        = 'supabase_cron'
       and v.deleted_at is null                                   -- (a) never resurrect a delete
       and v.visit_date between p_visit_date - 7 and p_visit_date + 7
       and not exists (select 1                                    -- (b) never steal a linked row
                         from public.entity_source_links l2
                        where l2.entity_type = 'visit'
                          and l2.entity_id   = v.id
                          and l2.source_system = 'jobber')
     order by pg_catalog.abs(v.visit_date - p_visit_date), v.id
     limit 1
       for update skip locked;   -- two DIFFERENT gids hash to different advisory keys and would
                                 -- otherwise both claim this same row. The loser skips and
                                 -- inserts its own below, which is the safe direction.

    if v_id is not null then
      -- source becomes 'jobber': this row IS the Jobber visit now. Pre-existing behaviour,
      -- deliberately unchanged. ⚠ It detaches the row from trg_push_visit_insert,
      -- trg_push_visit_update's schedule disjunct, fn_mark_visit_sync_pending,
      -- adopt_visit_schedule_from_jobber and trg_zz_freeze_line_items_on_complete, all of which
      -- gate on source IN ('visit-calendar','supabase_cron'). That is correct for a promotion and
      -- would be a serious bug if the predicate were ever widened to accept 'visit-calendar'.
      update public.visits set source = 'jobber' where id = v_id;

      insert into public.entity_source_links
             (entity_type, entity_id, source_system, source_id,
              match_method, match_confidence, synced_at)
           values ('visit', v_id, 'jobber', p_gid,
                   'webhook_promoted_from_cron', 1.0, pg_catalog.now());

      return query select v_id, false, true;
      return;
    end if;
  end if;

  -- ---- CREATE ------------------------------------------------------------------------------
  -- 🛑 client_id IS LOAD-BEARING IN THIS INSERT AND MUST NOT BE MOVED TO THE CALLER'S UPDATE.
  --    `trg_visit_default_locations` is **AFTER INSERT ONLY**, and public.seed_visit_locations()
  --    opens with `IF NEW.client_id IS NULL THEN RETURN NEW; END IF;`. A bare shell insert
  --    therefore seeds NOTHING, and because an AFTER INSERT trigger never fires again, the later
  --    payload UPDATE cannot recover it. Nothing backfills visit_locations (its only other writers
  --    are set_visit_manholes and create_calendar_visit, both human paths; no cron touches it).
  --
  --    Measured, rolled back, with a positive control:
  --      payload in the INSERT (old shape)  -> 1 visit_locations row
  --      bare shell + payload UPDATE        -> 0 visit_locations rows
  --    That is 100% of new webhook visits losing their locations, silently and permanently.
  --
  --    What it would have broken: `public.fn_resolve_gdo_id`'s arm 1 reads visit_locations and is
  --    "the only non-arbitrary answer" per its own comment; with no rows it falls through to the
  --    client/property-wide guess, which on a multi-tenant building is the exact mis-attribution
  --    CLAUDE.md forbids ("ATTRIBUTE A PERMIT BY THE TENANT, NEVER BY THE ADDRESS"). It also
  --    silently blanks `public.visit_manhole_options.is_assigned` and drops the visit from
  --    `ops.invoice_locations`.
  --
  --    🛑 THE GENERAL RULE, because it invalidates the invoice/quote template for any table with
  --    AFTER INSERT triggers: A SHELL INSERT IS ONLY SAFE ON A TABLE WHOSE TRIGGERS DO NOT READ
  --    THE COLUMNS THE SHELL OMITS. public.invoices has no such trigger; public.visits has two.
  --    Enumerate pg_trigger before copying this pattern anywhere else.
  --
  -- service_type carries the caller's `serviceTypeConcrete ?? 'Pumping'` default, because the
  -- standard UPDATE path deliberately DROPS service_type when the derive is non-concrete, so on a
  -- fresh row that column would otherwise stay NULL for ever. It also lets trg_gdo_compliance_check
  -- evaluate correctly at insert.
  --
  -- `source` deliberately takes its column DEFAULT of 'jobber', which is what keeps
  -- trg_push_visit_insert from firing and booking a second visit in Jobber -- its WHEN clause is
  -- `new.source = ANY (ARRAY['visit-calendar','supabase_cron'])`.
  insert into public.visits (visit_date, client_id, service_type)
       values (p_visit_date, p_client_id, p_service_type)
    returning id into v_id;

  -- Same transaction as the row above: if this fails the visit goes with it and the caller gets an
  -- error instead of a phantom. That is the entire point.
  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id,
          match_method, match_confidence, synced_at)
       values ('visit', v_id, 'jobber', p_gid, 'webhook', 1.0, pg_catalog.now());

  return query select v_id, true, false;
end
$fn$;

-- SECURITY DEFINER + a default EXECUTE to PUBLIC would hand the anon role a visit factory.
revoke all on function public.fn_jobber_resolve_visit(text, date, bigint, text) from public;
revoke all on function public.fn_jobber_resolve_visit(text, date, bigint, text) from anon;
revoke all on function public.fn_jobber_resolve_visit(text, date, bigint, text) from authenticated;
grant execute on function public.fn_jobber_resolve_visit(text, date, bigint, text) to service_role;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY  (static assertions only; the functional/concurrency test is
--          scripts/probes/visit_resolve_probe.js, which runs in a rolled-back transaction)
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_body text;
  v_n    bigint;
begin
  -- 1. it exists with the intended signature
  if pg_catalog.to_regprocedure('public.fn_jobber_resolve_visit(text, date, bigint, text)') is null then
    raise exception 'VERIFY 1 FAILED: fn_jobber_resolve_visit(text,date,bigint,text) does not exist';
  end if;

  v_body := pg_catalog.pg_get_functiondef(
              pg_catalog.to_regprocedure('public.fn_jobber_resolve_visit(text, date, bigint, text)')::oid);
  -- CRLF-proof. The counting assertion below matches a bare LF, and that newline is load-bearing
  -- (it is what excludes the `l2` alias in the promotion subquery). A checkout that stored CR in
  -- prosrc would make the count return 0 and fail this migration for a reason that is not real.
  v_body := pg_catalog.replace(v_body, pg_catalog.chr(13), '');

  -- 2. the lock, the re-read, and BOTH new promotion filters are present.
  --    POSIX classes, never backslash escapes (CLAUDE.md regex rule).
  if v_body !~ 'pg_advisory_xact_lock' then
    raise exception 'VERIFY 2a FAILED: no advisory lock in the body';
  end if;
  if v_body !~ 'jobber:visit:' then
    raise exception 'VERIFY 2b FAILED: the lock key prefix is wrong';
  end if;
  -- the entity_source_links read must appear TWICE: once before the lock, once after.
  select (pg_catalog.length(v_body)
          - pg_catalog.length(pg_catalog.replace(v_body, 'from public.entity_source_links l' || E'\n', '')))
         / pg_catalog.length('from public.entity_source_links l' || E'\n')
    into v_n;
  if v_n < 2 then
    raise exception 'VERIFY 2c FAILED: the link is read % time(s); the re-read after the lock is missing', v_n;
  end if;
  -- 🛑 THE COUNT ALONE IS NOT THE PROPERTY. Two reads BOTH sitting above the lock satisfy it while
  --    the race is completely un-fixed. Assert POSITION: at least one read must follow the lock.
  if pg_catalog.strpos(
       pg_catalog.substr(v_body, pg_catalog.strpos(v_body, 'pg_advisory_xact_lock')),
       'from public.entity_source_links l' || E'\n') = 0 then
    raise exception 'VERIFY 2c-bis FAILED: no link read appears AFTER the advisory lock; the re-read was moved above it and the fix is inert';
  end if;
  if v_body !~ 'deleted_at is null' then
    raise exception 'VERIFY 2d FAILED: promotion can still resurrect a soft-deleted placeholder';
  end if;
  if v_body !~ 'for update skip locked' then
    raise exception 'VERIFY 2e FAILED: the placeholder claim is not row-locked';
  end if;
  if v_body !~ 'not exists' then
    raise exception 'VERIFY 2f FAILED: promotion can still steal an already-linked row';
  end if;

  -- 3. NEGATIVE CONTROL. Without this, every assertion above passes just as well against a
  --    function that accepts anything. A required argument must actually be required.
  begin
    perform * from public.fn_jobber_resolve_visit(null, '2026-01-01'::date);
    raise exception 'VERIFY 3 FAILED: a NULL gid was accepted';
  exception when others then
    if sqlerrm like '%VERIFY 3 FAILED%' then raise; end if;
    if sqlerrm not like '%p_gid is required%' then
      raise exception 'VERIFY 3b FAILED: wrong error for a NULL gid: %', sqlerrm;
    end if;
  end;
  begin
    perform * from public.fn_jobber_resolve_visit('gid://test/nonexistent', null);
    raise exception 'VERIFY 3c FAILED: a NULL visit_date was accepted';
  exception when others then
    if sqlerrm like '%VERIFY 3c FAILED%' then raise; end if;
    if sqlerrm not like '%p_visit_date is required%' then
      raise exception 'VERIFY 3d FAILED: wrong error for a NULL visit_date: %', sqlerrm;
    end if;
  end;

  -- 4. the grant is narrow
  if pg_catalog.has_function_privilege('anon',
       'public.fn_jobber_resolve_visit(text, date, bigint, text)', 'EXECUTE') then
    raise exception 'VERIFY 4 FAILED: anon can execute the visit factory';
  end if;
  if pg_catalog.has_function_privilege('authenticated',
       'public.fn_jobber_resolve_visit(text, date, bigint, text)', 'EXECUTE') then
    raise exception 'VERIFY 4b FAILED: authenticated can execute the visit factory';
  end if;
  if not pg_catalog.has_function_privilege('service_role',
       'public.fn_jobber_resolve_visit(text, date, bigint, text)', 'EXECUTE') then
    raise exception 'VERIFY 4c FAILED: service_role CANNOT execute it; the webhook would break';
  end if;

  -- 5. the guard that must NOT have been copied from the invoice work.
  --    A constraint trigger requiring a link would refuse the Calendar's 520 alive unlinked rows.
  select pg_catalog.count(*) into v_n
    from pg_catalog.pg_trigger t
   where t.tgrelid = 'public.visits'::pg_catalog.regclass
     and not t.tgisinternal
     and t.tgname like '%requires_jobber_link%';
  if v_n > 0 then
    raise exception 'VERIFY 5 FAILED: a requires-jobber-link trigger exists on public.visits; it would refuse the Calendar';
  end if;

  -- 6. 🛑 THE CREATE PATH IS EXERCISED, NOT JUST READ. PL/pgSQL is not parsed at CREATE time, so
  --    every assertion above passes against a body that raises on its first real call. This also
  --    asserts the defect that nearly shipped: that a created visit SEEDS visit_locations.
  --    It runs inside a savepoint and is rolled back; a bare DO block would COMMIT.
  declare
    v_client bigint;
    v_id     bigint;
    v_id2    bigint;
    v_made   boolean;
    v_seeded bigint;
    v_ctrl   bigint;
    v_gid    text := 'VERIFY_2026-09-09_1200_probe_gid';
  begin
    select cl.client_id into v_client
      from public.client_locations cl
     group by cl.client_id having pg_catalog.count(*) >= 1
     order by cl.client_id limit 1;
    if v_client is null then
      raise exception 'VERIFY 6 FAILED: no client has client_locations, so the seeding assertion is an untested instrument';
    end if;

    begin
      -- create
      select r.entity_id, r.was_created into v_id, v_made
        from public.fn_jobber_resolve_visit(v_gid, date '2026-01-02', v_client, 'Pumping') r;
      if not v_made then raise exception 'VERIFY 6a FAILED: a brand-new gid did not report was_created'; end if;

      select pg_catalog.count(*) into v_seeded from public.visit_locations where visit_id = v_id;

      -- MUTATION CONTROL: the shell insert this migration replaced. It MUST seed nothing, or the
      -- assertion above proves nothing about the fix.
      insert into public.visits (visit_date) values (date '2026-01-02') returning id into v_id2;
      select pg_catalog.count(*) into v_ctrl from public.visit_locations where visit_id = v_id2;

      if v_ctrl <> 0 then
        raise exception 'VERIFY 6b FAILED: the bare-shell control seeded % location(s); this instrument cannot detect the defect', v_ctrl;
      end if;
      if v_seeded = 0 then
        raise exception 'VERIFY 6c FAILED: a visit created by fn_jobber_resolve_visit seeded 0 visit_locations. client_id is missing from the INSERT and trg_visit_default_locations is AFTER INSERT ONLY.';
      end if;

      -- idempotence: a second call on the same gid must find, not create
      select r.entity_id, r.was_created into v_id2, v_made
        from public.fn_jobber_resolve_visit(v_gid, date '2026-01-02', v_client, 'Pumping') r;
      if v_id2 is distinct from v_id or v_made then
        raise exception 'VERIFY 6d FAILED: the second call returned % (was_created=%), expected % / false', v_id2, v_made, v_id;
      end if;

      raise exception 'VERIFY_6_ROLLBACK';
    exception when others then
      if sqlerrm <> 'VERIFY_6_ROLLBACK' then raise; end if;
    end;
    raise notice 'VERIFY 6 ok: create seeds % visit_locations (bare-shell control seeds 0), and the call is idempotent', v_seeded;
  end;

  raise notice 'VERIFY ok: fn_jobber_resolve_visit present, locked, re-reads AFTER the lock, promotion filters soft-deletes and already-linked rows, create path exercised and seeds visit_locations, grants narrow, no link-required trigger on visits';
end
$verify$;
