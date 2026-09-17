-- ============================================================================
-- 2026-09-17_1725 : customer.get_client_portal + customer.get_client_by_code
--                   resolve a duplicated slug DETERMINISTICALLY
-- ============================================================================
-- Fred, 2026-09-17, after the Field Portal could not open 239-COM: "Delete the
-- inactive 050-PV too, then fix the resolvers."
--
-- WHAT WAS WRONG
-- public.clients.client_code is NOT unique. clients_active_client_code_uniq
-- (2026-07-01c) is a PARTIAL unique index, WHERE status <> 'INACTIVE', so the
-- table can hold one non-INACTIVE row per code plus any number of INACTIVE ones.
-- Two such pairs existed today (239-COM ids 247/493, 050-PV ids 469/41; the
-- INACTIVE shells were deleted today, backups in the root backups/ folder).
-- customer.clients derives slug = lower(client_code), so both rows of a pair
-- share a slug, and the two resolvers over that view reacted differently:
--   customer.get_client_portal(p_slug)   scalar SQL function, WHERE only, no
--                                         ORDER BY: returns whichever row the
--                                         planner yields first. Measured: the
--                                         empty INACTIVE 493 for '239-com', so
--                                         /239-com rendered ACCOUNT INACTIVE
--                                         with 0 visits while 247 had 5.
--   the Field Portal /login server fn     .single() on the view: throws on 2
--                                         rows, rendered as the generic
--                                         "Something went wrong" (not "Invalid
--                                         code").
--   customer.get_client_by_code(p_code)  same shape as get_client_portal, same
--                                         first-row behaviour. It was built for
--                                         the login (2026-07-29b) and was never
--                                         wired; it is being wired now.
--
-- THE RULE (both functions, identical)
--   ORDER BY (c.status <> 'INACTIVE') DESC, c.created_at DESC, c.id DESC
--   LIMIT 1
-- Because of the partial unique index there is AT MOST ONE non-INACTIVE row per
-- code, so the first key alone is decisive whenever a live client exists; the
-- newest-first tiebreak only matters between INACTIVE shells, where the newer
-- one is the re-created record (the 050-PV shape: the April import row was the
-- stale one, the June re-creation the live one). c.id is the uuid derived from
-- the bigint id, used only as a total-order tiebreak so two rows created in the
-- same transaction still resolve the same way every time.
-- ⚠ Do NOT "simplify" to ORDER BY is_active: PAUSED is neither active nor
-- INACTIVE and must still beat an INACTIVE shell (a paused client logs in and
-- sees the amber banner; that is the contract, docs/06 auth flow step 6).
--
-- WHY NOT A UNIQUE INDEX ON THE WHOLE CODE INSTEAD
-- Jobber creates our rows (fn_jobber_resolve_client) and Yan can type the same
-- NNN-XX into two Jobber clients; a full unique index would make the webhook
-- and the poll FAIL on that day instead of landing an INACTIVE duplicate we can
-- see and clean. The partial index plus a deterministic reader is the safer
-- pair. The duplicate census stays a maintenance check:
--   select slug, count(*) from customer.clients where slug is not null
--   group by 1 having count(*) > 1;
--
-- GRANTS
-- get_client_portal: unchanged (anon + authenticated EXECUTE; the browser calls
-- it as anon). get_client_by_code: anon + authenticated as before, PLUS
-- service_role, because the /login server function runs as service_role
-- (Field Portal docs/09-known-issues.md 0b) and until now could not execute it
-- (has_function_privilege('service_role', ...) was false, measured today).
-- Supabase default privileges would hand EXECUTE to PUBLIC on CREATE OR REPLACE;
-- the revoke below restates the intended set explicitly, as 2026-07-29b did.
--
-- VERIFY (inside the transaction, rolled back fixture): a fake INACTIVE
-- duplicate of a live client must lose to the live row in BOTH functions; two
-- INACTIVE-only rows must resolve to the newer one; a miss must still return
-- NULL; '%' must still return NULL from get_client_by_code.
--
-- ROLLBACK: re-run 2026-07-29b for get_client_by_code and the previous
-- get_client_portal body (docs/migrations, 2026-08-02 series) without the
-- ORDER BY; nothing else changes.
--
-- AUDIT (ADR 010): read-only functions; no business table touched. The fixture
-- rows below are created and rolled back inside this transaction; the audit
-- trigger rows they produce roll back with them.
-- ============================================================================

begin;

create or replace function customer.get_client_portal(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'client', to_jsonb(c),
    'permits', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb)
        from customer.permits p where p.client_id = c.id),
    'work_orders', (
      select coalesce(jsonb_agg(to_jsonb(w) order by w.visit_date desc), '[]'::jsonb)
        from customer.work_orders w where w.client_id = c.id),
    'scheduled_visits', (
      select coalesce(jsonb_agg(to_jsonb(s) order by s.scheduled_date asc), '[]'::jsonb)
        from customer.scheduled_visits s where s.client_id = c.id),
    'access_photos', (
      select coalesce(jsonb_agg(to_jsonb(a) order by a.position), '[]'::jsonb)
        from customer.client_access_photos a where a.client_id = c.id)
  )
  from customer.clients c
  where lower(c.slug) = lower(p_slug)
  -- deterministic on a duplicated slug: the one live row first (partial unique
  -- index guarantees at most one), then the newest re-creation
  order by (c.status <> 'INACTIVE') desc, c.created_at desc, c.id desc
  limit 1;
$$;

create or replace function customer.get_client_by_code(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'id',          c.id,
           'slug',        c.slug,
           'client_code', c.client_code)
    from customer.clients c
   where p_code is not null
     and length(btrim(p_code)) > 0
     -- EXACT case-insensitive match on purpose: `%` / `_` must NOT be wildcards
     and lower(c.client_code) = lower(btrim(p_code))
   -- same deterministic pick as get_client_portal, so login and portal agree
   order by (c.status <> 'INACTIVE') desc, c.created_at desc, c.id desc
   limit 1;
$$;

revoke all on function customer.get_client_portal(text)  from public;
revoke all on function customer.get_client_by_code(text) from public;
grant execute on function customer.get_client_portal(text)  to anon, authenticated;
grant execute on function customer.get_client_by_code(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY with a rolled-back fixture. The savepoint is rolled back whether the
-- block passes or not: on a pass the fixture rows AND their audit rows vanish
-- and only the function changes above commit; on a failure the raise aborts
-- the whole transaction and nothing commits.
-- ---------------------------------------------------------------------------
savepoint verify_fixture;
do $$
declare
  v_live_id   bigint;
  v_live_code text;
  v_fake_id   bigint;
  v_old_id    bigint;
  v_new_id    bigint;
  v_portal    jsonb;
  v_bycode    jsonb;
begin
  -- pick a live client that has no duplicate today
  select c.id, c.client_code into v_live_id, v_live_code
    from public.clients c
   where c.status in ('ACTIVE','RECURRING') and c.client_code is not null
     and not exists (select 1 from public.clients d where d.client_code = c.client_code and d.id <> c.id)
   order by c.id limit 1;
  if v_live_id is null then raise exception 'VERIFY: no live client without duplicate found'; end if;

  -- (1) a NEWER INACTIVE duplicate must lose to the live row in both functions
  insert into public.clients (client_code, name, status, client_class, status_source, client_class_source)
  values (v_live_code, '[TEST] duplicate shell', 'INACTIVE', 'commercial', 'manual', 'manual')
  returning id into v_fake_id;

  v_portal := customer.get_client_portal(lower(v_live_code));
  if (v_portal->'client'->>'id') <> customer.uuid_from_bigint(v_live_id)::text
     or (v_portal->'client'->>'is_active') <> 'true' then
    raise exception 'VERIFY 1a failed: get_client_portal picked % (expected live id %)', v_portal->'client'->>'name', v_live_id;
  end if;
  v_bycode := customer.get_client_by_code(v_live_code);
  if (v_bycode->>'id') <> customer.uuid_from_bigint(v_live_id)::text then
    raise exception 'VERIFY 1b failed: get_client_by_code picked % (expected live id %)', v_bycode->>'id', v_live_id;
  end if;

  -- (2) two INACTIVE-only rows: the newer one wins
  insert into public.clients (client_code, name, status, client_class, status_source, client_class_source)
  values ('ZZZ-TST', '[TEST] older shell', 'INACTIVE', 'commercial', 'manual', 'manual')
  returning id into v_old_id;
  insert into public.clients (client_code, name, status, client_class, status_source, client_class_source)
  values ('ZZZ-TST', '[TEST] newer shell', 'INACTIVE', 'commercial', 'manual', 'manual')
  returning id into v_new_id;
  -- created_at is set by default now() and is identical inside one transaction,
  -- so push the older one back explicitly to exercise the created_at key
  update public.clients set created_at = created_at - interval '1 day' where id = v_old_id;

  v_portal := customer.get_client_portal('zzz-tst');
  if (v_portal->'client'->>'id') <> customer.uuid_from_bigint(v_new_id)::text then
    raise exception 'VERIFY 2a failed: get_client_portal picked % (expected newer id %)', v_portal->'client'->>'name', v_new_id;
  end if;
  v_bycode := customer.get_client_by_code('zzz-tst');
  if (v_bycode->>'id') <> customer.uuid_from_bigint(v_new_id)::text then
    raise exception 'VERIFY 2b failed: get_client_by_code picked % (expected newer id %)', v_bycode->>'id', v_new_id;
  end if;

  -- (3) misses and wildcards still return NULL
  if customer.get_client_portal('zzz-nope') is not null then raise exception 'VERIFY 3a failed: portal miss not null'; end if;
  if customer.get_client_by_code('zzz-nope') is not null then raise exception 'VERIFY 3b failed: by_code miss not null'; end if;
  if customer.get_client_by_code('%') is not null then raise exception 'VERIFY 3c failed: wildcard matched'; end if;
  if customer.get_client_by_code('ZZZ-T_T') is not null then raise exception 'VERIFY 3d failed: underscore wildcard matched'; end if;

  -- (4) grants
  if not has_function_privilege('service_role', 'customer.get_client_by_code(text)', 'execute') then raise exception 'VERIFY 4a failed: service_role cannot execute get_client_by_code'; end if;
  if not has_function_privilege('anon', 'customer.get_client_by_code(text)', 'execute') then raise exception 'VERIFY 4b failed: anon lost get_client_by_code'; end if;
  if not has_function_privilege('anon', 'customer.get_client_portal(text)', 'execute') then raise exception 'VERIFY 4c failed: anon lost get_client_portal'; end if;
  if has_function_privilege('service_role', 'customer.get_client_portal(text)', 'execute') then raise exception 'VERIFY 4d failed: get_client_portal grant set changed'; end if;

  -- fixture teardown (belt and braces; the rows are [TEST] tagged and would
  -- also vanish on a rollback of this transaction)
  delete from derm.client_aliases where client_id in (v_fake_id, v_old_id, v_new_id);
  delete from public.client_locations where client_id in (v_fake_id, v_old_id, v_new_id);
  delete from public.clients where id in (v_fake_id, v_old_id, v_new_id);
  if exists (select 1 from public.clients where name like '[TEST]%') then raise exception 'VERIFY teardown failed'; end if;
  raise notice 'VERIFY ok: live=% fake=% old=% new=%', v_live_id, v_fake_id, v_old_id, v_new_id;
end $$;
rollback to savepoint verify_fixture;

commit;
