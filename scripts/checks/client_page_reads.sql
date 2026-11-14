-- Standing check of the reads behind the Ops Portal's Clients pages and the manifest dialog (the Client App move,
-- Trello #161 Stage E, pick BB). Run as owner (the Management API), as ONE request inside BEGIN ... ROLLBACK; it reads
-- only, and RAISES on the first failure. Each block is the VERIFY of its migration, without the parts that compare the
-- body before and after.
--   1. derm.fn_manifest_row_states_core(), derm.manifest_row_states(), derm.manifest_row_states_for_client(bigint)
--      (2026-11-14_0135_derm_manifest_row_states_per_client.sql)
-- Its controls (each block must FAIL on a copy granted to anon, with its gate removed, with rows left out) were run
-- in the rehearsals of each migration, 2026-11-14.

do $rowstates$
declare
  v_core constant text := 'derm.fn_manifest_row_states_core()';
  v_wrap constant text := 'derm.manifest_row_states()';
  v_pc constant text := 'derm.manifest_row_states_for_client(bigint)';
  v_role text; v_uid uuid; v_email text; v_after jsonb; v_res jsonb; v_state text; v_msg text; v_bad bigint; v_n bigint;
  v_client bigint;
  r record;
begin
  -- 1. Who may run what.
  foreach v_role in array array['public', 'anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(v_role, v_core, 'execute') then raise exception 'verify_fail: % can execute the core', v_role; end if;
  end loop;
  if exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
              where p.oid = v_core::regprocedure and a.grantee <> p.proowner) then raise exception 'verify_fail: the core holds a grant'; end if;
  if (select p.prosecdef or p.provolatile <> 's' or p.proconfig is distinct from array['search_path=""'] from pg_proc p where p.oid = v_core::regprocedure) then
    raise exception 'verify_fail: the core is not SECURITY INVOKER, STABLE, with an empty search_path';
  end if;
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_pc, 'execute') then raise exception 'verify_fail: % can execute the per-client read', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_pc, 'execute') then raise exception 'verify_fail: authenticated cannot execute the per-client read'; end if;
  foreach v_role in array array['public', 'anon'] loop
    if has_function_privilege(v_role, v_wrap, 'execute') then raise exception 'verify_fail: % can execute the wrapper', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_wrap, 'execute') or not has_function_privilege('service_role', v_wrap, 'execute') then
    raise exception 'verify_fail: the wrapper lost a grant';
  end if;
  if not (select bool_and(p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""']) from pg_proc p
           where p.oid in (v_wrap::regprocedure, v_pc::regprocedure)) then
    raise exception 'verify_fail: a reader is not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- 2. The wrapper answers what the core answers (the migration compared the old and the new body on every row).
  perform set_config('request.jwt.claims', '', true);
  v_after := derm.manifest_row_states();
  if (select count(*) from jsonb_object_keys(v_after)) = 0 then raise exception 'verify_fail: the answer is empty'; end if;
  if derm.fn_manifest_row_states_core() is distinct from v_after then raise exception 'verify_fail: the core differs from the wrapper'; end if;

  -- 3. The per-client read, for the test client 112-YA and the 8 clients with the most live manifest rows (the rehearsal
  --    runs every client): each entry it returns is the full answer's entry and holds one of the client's rows; each
  --    live row of the client is in exactly one entry.
  v_n := 0;
  for v_client in (select 381::bigint)
                  union
                  (select dm.client_id from public.derm_manifests dm where dm.deleted_at is null and dm.client_id is not null
                    group by 1 order by count(*) desc, 1 limit 8) loop
    v_res := derm.manifest_row_states_for_client(v_client);
    select count(*) into v_bad from jsonb_each(v_res) e
     where e.value is distinct from v_after -> e.key
        or not exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i
                         join public.derm_manifests dm on dm.id = i.value::bigint and dm.deleted_at is null
                        where dm.client_id = v_client);
    if v_bad <> 0 then raise exception 'verify_fail: client %: % entries are not the full answer''s or hold none of its rows', v_client, v_bad; end if;
    select count(*) into v_bad from public.derm_manifests dm
     where dm.client_id = v_client and dm.deleted_at is null
       and (select count(*) from jsonb_each(v_res) e
             where (e.value -> 'manifest_ids') @> to_jsonb(dm.id)) <> 1;
    if v_bad <> 0 then raise exception 'verify_fail: client %: % live rows are not in exactly one entry', v_client, v_bad; end if;
    v_n := v_n + 1;
  end loop;
  if v_n < 9 then raise exception 'verify_fail: only % clients checked', v_n; end if;
  if derm.manifest_row_states_for_client(-1) is distinct from '{}'::jsonb then raise exception 'verify_fail: a client with no row gets entries'; end if;

  -- 4. A signed-in person with neither the Client App nor the DERM Tracker is refused, with the access sentence; the
  --    wrapper still refuses a person without the DERM Tracker with its own sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none' then v_uid := r.id; v_email := r.email; exit; end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without both apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := derm.manifest_row_states_for_client(381);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: the per-client read did not refuse a person without both apps (% %)', v_state, v_msg;
  end if;
  set local role authenticated;
  begin
    v_res := derm.manifest_row_states();
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this in DERM Tracker.%' then
    raise exception 'verify_fail: the wrapper did not refuse the usual way (% %)', v_state, v_msg;
  end if;

  -- 5. A signed-in admin reads both.
  select u.id, u.email into v_uid, v_email
    from public.employees e
    join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
   where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null
     and (u.banned_until is null or u.banned_until <= now())
   order by e.id limit 1;
  if v_uid is null then raise exception 'verify_fail: no admin sign-in to test with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_res := derm.manifest_row_states();
  if v_res is distinct from v_after then raise exception 'verify_fail: an admin reads another answer'; end if;
  v_res := derm.manifest_row_states_for_client((select dm.client_id from public.derm_manifests dm where dm.deleted_at is null
                                                 group by 1 order by count(*) desc, 1 limit 1));
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if (select count(*) from jsonb_object_keys(v_res)) = 0 then raise exception 'verify_fail: an admin reads no entry for the busiest client'; end if;

  raise notice 'row states ok: % entries; % clients checked', (select count(*) from jsonb_object_keys(v_after)), v_n;
end $rowstates$;

