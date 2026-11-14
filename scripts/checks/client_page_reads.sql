-- Standing check of the reads behind the Ops Portal's Clients pages and the manifest dialog (the Client App move,
-- Trello #161 Stage E, pick BB). Run as owner (the Management API), as ONE request inside BEGIN ... ROLLBACK; it reads
-- only, and RAISES on the first failure. Each block is the VERIFY of its migration, without the parts that compare the
-- body before and after.
--   1. derm.fn_manifest_row_states_core(), derm.manifest_row_states(), derm.manifest_row_states_for_client(bigint)
--      (2026-11-14_0135_derm_manifest_row_states_per_client.sql)
--   2. B1, public.get_pumping_figures(bigint, bigint[]) (2026-11-14_0140_public_get_pumping_figures.sql); it also compares
--      the trust rule with ops.fn_client_sludge_averages() both ways
--   3. B3, client.get_client_emails(bigint, text) (2026-11-14_0148_client_get_client_emails.sql)
--   4. B2, derm.get_manifest_dialog(text) (2026-11-14_0155_derm_get_manifest_dialog.sql)
--   5. B4, ops.portal_search(text) (2026-11-14_0203_ops_portal_search_addresses_invoices_quotes.sql): the new groups only
--      with the Client App, their keys, and an address, an invoice number and a quote number found (the migration compared
--      the four old groups with the old body; this block cannot, the old body is gone)
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

do $pumping$
declare
  v_sig constant text := 'public.get_pumping_figures(bigint,bigint[])';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_all jsonb; v_state text; v_msg text; v_bad bigint; v_n bigint;
  r record;
begin
  -- 1. Who may run it.
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_sig, 'execute') then raise exception 'verify_fail: % can execute', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- 2. A signed-in person with none of the four apps is refused with the access sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none'
       and hr.fn_app_level('stamp_studio') = 'none' and hr.fn_app_level('admin_review') = 'none' then
      v_uid := r.id; v_email := r.email; exit;
    end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without the four apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := public.get_pumping_figures(381);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without the four apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. The test client 112-YA, and every visit the tank view measures: one entry per completed live visit, each with
  --    one of the four sources, gallons exactly when the source has them, the trap size only on a pumping, and
  --    "not a pumping" only on a visit whose work is known and is not one.
  v_res := public.get_pumping_figures(381);
  v_all := public.get_pumping_figures(null, (select array_agg(t.visit_id) from public.v_visit_tank_service t));
  select count(*) into v_bad
    from (select x, true as ya from jsonb_array_elements(v_res -> 'visits') x
          union all select x, false from jsonb_array_elements(v_all -> 'visits') x) y
    left join public.visits vv on vv.id = (y.x ->> 'visit_id')::bigint
   where (y.ya and (y.x ->> 'client_id')::bigint <> 381)
      or y.x ->> 'source' not in ('tank', 'trap_size', 'none', 'not_a_pumping')
      or ((y.x ->> 'gallons') is null) <> (y.x ->> 'source' in ('none', 'not_a_pumping'))
      or (y.x ->> 'source' = 'trap_size' and vv.service_type is distinct from 'Pumping')
      or (y.x ->> 'source' = 'not_a_pumping' and (vv.service_type is null or vv.service_type = 'Pumping'
                                                   and not exists (select 1 from public.v_visit_tank_service t where t.visit_id = vv.id and t.visit_kind = 'dump')));
  if v_bad <> 0 then raise exception 'verify_fail: % visits are malformed', v_bad; end if;
  if jsonb_array_length(v_res -> 'visits') <> (select count(*) from public.visits v where v.client_id = 381 and v.deleted_at is null and v.visit_status = 'completed') then
    raise exception 'verify_fail: 112-YA does not get one entry per completed visit';
  end if;
  if jsonb_array_length(v_all -> 'visits') <> (select count(*) from public.v_visit_tank_service) then
    raise exception 'verify_fail: the visits of the tank view do not each get one entry';
  end if;

  -- 4. Both ways against the averages (the other home of the trust rule), over every visit the tank view measures:
  --    a reading the averages use (any date) is "tank" here with the same whole gallons, and a "tank" reading of a
  --    visit with a site and a pump kind is one the averages use.
  with av as (
    select distinct (rr ->> 'visit_id')::bigint as visit_id, round((rr ->> 'gallons')::numeric)::int as g
      from ops.fn_client_sludge_averages((select array_agg(distinct t.visit_date + 1) from public.v_visit_tank_service t)) a
     cross join lateral jsonb_array_elements(a.readings) rr
  ), b1 as (
    select (x ->> 'visit_id')::bigint as visit_id, (x ->> 'gallons')::int as g, x ->> 'source' as source, (x ->> 'property_id')::bigint as pid
      from jsonb_array_elements(v_all -> 'visits') x
  )
  select (select count(*) from av left join b1 on b1.visit_id = av.visit_id where b1.source is distinct from 'tank' or b1.g is distinct from av.g)
       + (select count(*) from b1 join public.visits vv on vv.id = b1.visit_id
           where b1.source = 'tank' and b1.pid is not null and ops.fn_visit_pump_kind(vv.id, vv.job_id) is not null
             and not exists (select 1 from av where av.visit_id = b1.visit_id))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % readings differ between this read and the averages', v_bad; end if;
  if (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'tank') = 0 then
    raise exception 'verify_fail: no tank reading at all';
  end if;

  -- 5. The site figures are the averages' own, for a client that has some.
  select a.client_id into v_n from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
   order by a.readings_n desc, a.property_id limit 1;
  v_res := public.get_pumping_figures(v_n);
  select count(*) into v_bad
    from ops.fn_client_sludge_averages(array[(now() at time zone 'America/New_York')::date + 1]) a
    join public.properties p on p.id = a.property_id and p.client_id = v_n and p.deleted_at is null
   where not exists (select 1 from jsonb_array_elements(v_res -> 'sites') s
                      where (s ->> 'property_id')::bigint = a.property_id and s ->> 'pump_kind' = a.pump_kind
                        and (s ->> 'average_gallons')::int = round(a.avg_gallons)::int and (s ->> 'readings_in_average')::int = a.readings_n
                        and (s ->> 'last_date')::date = a.last_reading_date);
  if v_bad <> 0 or jsonb_array_length(v_res -> 'sites') = 0 then raise exception 'verify_fail: the site figures of client % are not the averages (% differ)', v_n, v_bad; end if;

  raise notice 'pumping figures ok: % visits measured by the tank, % with the trap size, across the tank era',
    (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'tank'),
    (select count(*) from jsonb_array_elements(v_all -> 'visits') x where x ->> 'source' = 'trap_size');
end $pumping$;

do $emails$
declare
  v_sig constant text := 'client.get_client_emails(bigint,text)';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_state text; v_msg text; v_bad bigint; v_client bigint; v_n bigint;
  v_addr text; v_want bigint;
  r record;
begin
  -- 1. Who may run it.
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_sig, 'execute') then raise exception 'verify_fail: % can execute', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- 2. A signed-in person with neither the Client App nor the DERM Tracker is refused with the access sentence.
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
    v_res := client.get_client_emails(381);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without both apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. Every client that has sent emails: one entry per sent record that is not a test, each with its delivery state
  --    exactly as public.v_email_delivery gives it; the client emails are exactly public.v_client_email_sends' rows.
  v_n := 0;
  for v_client in
    select d.client_id from public.derm_email_sends d where d.status = 'sent' and not coalesce(d.is_test, false) and d.client_id is not null
    union
    select v.client_id from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
     where s.status = 'sent' and not coalesce(s.is_test, false) and v.client_id is not null
  loop
    v_res := client.get_client_emails(v_client);
    select (select count(*) from public.derm_email_sends d where d.client_id = v_client and d.status = 'sent' and not coalesce(d.is_test, false))
         + (select count(*) from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
             where v.client_id = v_client and s.status = 'sent' and not coalesce(s.is_test, false))
      into v_want;
    if jsonb_array_length(v_res -> 'emails') <> v_want then
      raise exception 'verify_fail: client % gets % emails for % sent records', v_client, jsonb_array_length(v_res -> 'emails'), v_want;
    end if;
    select count(*) into v_bad from jsonb_array_elements(v_res -> 'emails') m
      left join public.v_email_delivery ed on ed.resend_email_id = m ->> 'resend_email_id'
     where m ->> 'kind' not in ('client', 'city')
        or (m ->> 'delivery_status') is distinct from ed.delivery_status
        or (m -> 'delivery_detail') is distinct from ed.delivery_detail
        or jsonb_array_length(m -> 'to') = 0
        or m ? 'text' or m ? 'body' or m ? 'html';
    if v_bad <> 0 then raise exception 'verify_fail: client %: % emails are malformed or their delivery is not the view''s', v_client, v_bad; end if;
    select count(*) into v_bad from (
      select (m ->> 'send_id')::bigint as send_id from jsonb_array_elements(v_res -> 'emails') m where m ->> 'kind' = 'client'
      except
      select s.send_id from public.v_client_email_sends s where s.client_id = v_client) q;
    if v_bad <> 0 or (select count(*) from jsonb_array_elements(v_res -> 'emails') m where m ->> 'kind' = 'client')
                      <> (select count(*) from public.v_client_email_sends s where s.client_id = v_client) then
      raise exception 'verify_fail: client %: the client emails are not the rows of public.v_client_email_sends', v_client;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n < 10 then raise exception 'verify_fail: only % clients with emails checked', v_n; end if;

  -- 4. One address: only the emails that carried it, each saying how; an address nobody got gets none. Two addresses:
  --    the most used To address of a client email, and the most used Bcc address (no email carries a Cc today).
  for v_addr, v_client in
    (select a.addr, a.client_id
       from (select lower(btrim(x)) as addr, d.client_id
               from public.derm_email_sends d cross join lateral unnest(string_to_array(d.recipient_email, ',')) x
              where d.status = 'sent' and not coalesce(d.is_test, false) and d.recipient_type = 'client') a
      group by 1, 2 order by count(*) desc, 1 limit 1)
    union all
    (select a.addr, a.client_id
       from (select lower(btrim(x)) as addr, d.client_id
               from public.derm_email_sends d cross join lateral unnest(d.bcc_emails) x
              where d.status = 'sent' and not coalesce(d.is_test, false)
             union all
             select lower(btrim(x)), v.client_id
               from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id cross join lateral unnest(s.bcc_emails) x
              where s.status = 'sent' and not coalesce(s.is_test, false)) a
      group by 1, 2 order by count(*) desc, 1 limit 1)
  loop
  v_res := client.get_client_emails(v_client, '  ' || upper(v_addr) || ' ');
  if jsonb_array_length(v_res -> 'emails') = 0
     or exists (select 1 from jsonb_array_elements(v_res -> 'emails') m
                 where m ->> 'matched_as' not in ('to', 'cc', 'bcc')
                    or not exists (select 1 from jsonb_array_elements_text(m -> (m ->> 'matched_as')) t where lower(btrim(t)) = v_addr))
     or jsonb_array_length(v_res -> 'emails') <> (
          select count(*) from public.derm_email_sends d
           where d.client_id = v_client and d.status = 'sent' and not coalesce(d.is_test, false)
             and (v_addr in (select lower(btrim(x)) from unnest(string_to_array(coalesce(d.recipient_email, ''), ',')) x)
                  or v_addr in (select lower(btrim(x)) from unnest(coalesce(d.cc_emails, '{}'::text[])) x)
                  or v_addr in (select lower(btrim(x)) from unnest(coalesce(d.bcc_emails, '{}'::text[])) x)))
        + (select count(*) from public.visit_photo_email_sends s join public.visits v on v.id = s.visit_id
            where v.client_id = v_client and s.status = 'sent' and not coalesce(s.is_test, false)
              and (v_addr in (select lower(btrim(x)) from unnest(string_to_array(coalesce(s.recipient_email, ''), ',')) x)
                   or v_addr in (select lower(btrim(x)) from unnest(coalesce(s.cc_emails, '{}'::text[])) x)
                   or v_addr in (select lower(btrim(x)) from unnest(coalesce(s.bcc_emails, '{}'::text[])) x))) then
    raise exception 'verify_fail: the emails to one address are wrong';
  end if;
  end loop;
  if jsonb_array_length((client.get_client_emails(v_client, 'nobody@example.invalid')) -> 'emails') <> 0 then
    raise exception 'verify_fail: an address nobody got gets emails';
  end if;

  raise notice 'emails ok: % clients with emails checked', v_n;
end $emails$;

do $dialog$
declare
  v_sig constant text := 'derm.get_manifest_dialog(text)';
  v_role text; v_uid uuid; v_email text; v_res jsonb; v_full jsonb; v_state text; v_msg text; v_bad bigint; v_n int := 0;
  v_num text;
  r record;
begin
  -- 1. Who may run it.
  foreach v_role in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(v_role, v_sig, 'execute') then raise exception 'verify_fail: % can execute', v_role; end if;
  end loop;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;
  -- Z8: nothing in derm may name a truck tank view.
  if (select p.prosrc ~* 'tank_|vehicle_stop|water_balance|water_ledger|vehicle_dumps' from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: the function names a truck tank object';
  end if;

  -- 2. A signed-in person with none of the three apps is refused with the access sentence.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    if hr.fn_app_level('client_app') = 'none' and hr.fn_app_level('derm_tracker') = 'none' and hr.fn_app_level('stamp_studio') = 'none' then
      v_uid := r.id; v_email := r.email; exit;
    end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without the three apps to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := derm.get_manifest_dialog('111111');
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this.%' then
    raise exception 'verify_fail: a person without the three apps was not refused (% %)', v_state, v_msg;
  end if;

  -- 3. The tickets of 112-YA, the 8 tickets with the most rows and the 4 newest Broward tickets (the rehearsal runs every
  --    ticket): one client entry per live row with its number, each with its visits, copies and emails exactly as their
  --    sources hold them, and the ticket's entries of the row states exactly the core's.
  v_full := derm.fn_manifest_row_states_core();
  for v_num in
    (select distinct coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and dm.client_id = 381 and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) is not null)
    union
    (select coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) is not null
      group by 1 order by count(*) desc, 1 limit 8)
    union
    (select coalesce(dm.white_manifest_number, dm.yellow_ticket_number) from public.derm_manifests dm
      where dm.deleted_at is null and coalesce(dm.yellow_ticket_number, '') <> ''
      group by 1 order by max(dm.dump_ticket_date) desc nulls last, 1 limit 4)
  loop
    v_res := derm.get_manifest_dialog(v_num);
    if v_res is null then raise exception 'verify_fail: ticket %: no answer', v_num; end if;
    select count(*) into v_bad from (
      select (c ->> 'manifest_id')::bigint as id from jsonb_array_elements(v_res -> 'clients') c
      except
      select dm.id from public.derm_manifests dm where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num) q;
    if v_bad <> 0 or jsonb_array_length(v_res -> 'clients') <> (select count(*) from public.derm_manifests dm
         where dm.deleted_at is null and coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num) then
      raise exception 'verify_fail: ticket %: the clients are not its live rows', v_num;
    end if;
    select count(*) into v_bad from jsonb_array_elements(v_res -> 'clients') c
     where jsonb_array_length(c -> 'visits') <> (select count(*) from public.manifest_visits mv join public.visits v on v.id = mv.visit_id and v.deleted_at is null
                                                  where mv.manifest_id = (c ->> 'manifest_id')::bigint)
        or jsonb_array_length(c -> 'copies') <> (select count(*) from derm.redacted_manifest_docs d
                                                  where d.manifest_id = (c ->> 'manifest_id')::bigint and d.client_id = (c ->> 'client_id')::bigint)
        or jsonb_array_length(c -> 'client_emails') <> (select count(*) from public.v_client_email_sends s
                                                         where s.manifest_id = (c ->> 'manifest_id')::bigint and s.client_id = (c ->> 'client_id')::bigint)
        or exists (select 1 from jsonb_array_elements(c -> 'visits') v
                    where (v -> 'city_email' ->> 'state') is distinct from (select s.state from public.v_visit_city_email_state s where s.visit_id = (v ->> 'visit_id')::bigint)
                       or jsonb_array_length(v -> 'city_email' -> 'sends') <> (select count(*) from public.v_visit_city_email_sends cs where cs.visit_id = (v ->> 'visit_id')::bigint)
                       or jsonb_array_length(v -> 'county_report' -> 'filed') <> (select count(*) from derm.visit_gdo_report g where g.visit_id = (v ->> 'visit_id')::bigint));
    if v_bad <> 0 then raise exception 'verify_fail: ticket %: % clients differ from their sources', v_num, v_bad; end if;
    select count(*) into v_bad from (
      select e.key, e.value from jsonb_each(v_full) e
       where exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i
                       join public.derm_manifests dm on dm.id = i.value::bigint
                      where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num and dm.deleted_at is null)
      except
      select e.key, e.value from jsonb_each(v_res -> 'row_states') e) q;
    if v_bad <> 0 or (select count(*) from jsonb_object_keys(v_res -> 'row_states')) = 0
       or (select count(*) from jsonb_object_keys(v_res -> 'row_states')) <> (
            select count(*) from jsonb_each(v_full) e
             where exists (select 1 from jsonb_array_elements_text(e.value -> 'manifest_ids') i
                             join public.derm_manifests dm on dm.id = i.value::bigint
                            where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_num and dm.deleted_at is null)) then
      raise exception 'verify_fail: ticket %: the row states are not the core''s', v_num;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n < 12 then raise exception 'verify_fail: only % tickets checked', v_n; end if;
  if derm.get_manifest_dialog('no such number') is not null or derm.get_manifest_dialog('') is not null or derm.get_manifest_dialog(null) is not null then
    raise exception 'verify_fail: a number with no row gets an answer';
  end if;

  raise notice 'manifest dialog ok: % tickets checked', v_n;
end $dialog$;

do $search$
declare
  v_sig constant text := 'ops.portal_search(text)';
  r record; v_res jsonb; v_bad bigint; v_n int := 0; v_clients boolean; v_seen_without boolean := false;
  v_addr text; v_pid bigint; v_inv text; v_quo text; v_term text;
begin
  if has_function_privilege('anon', v_sig, 'execute') or has_function_privilege('public', v_sig, 'execute') then
    raise exception 'verify_fail: anon or PUBLIC can execute';
  end if;
  if not has_function_privilege('authenticated', v_sig, 'execute') or not has_function_privilege('service_role', v_sig, 'execute') then
    raise exception 'verify_fail: a grant was lost';
  end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  select p.address, p.id into v_addr, v_pid from public.properties p
   where p.deleted_at is null and length(p.address) between 12 and 80
     and (select count(*) from public.properties p2 where p2.deleted_at is null and p2.address ilike '%' || p.address || '%') = 1
   order by p.id desc limit 1;
  select i.invoice_number into v_inv from public.invoices i where i.invoice_number ~ '^[0-9]+$'
   and (select count(*) from public.invoices i2 where i2.invoice_number = i.invoice_number) = 1 order by i.id desc limit 1;
  select q.quote_number into v_quo from public.quotes q where q.quote_number ~ '^[0-9]+$'
   and (select count(*) from public.quotes q2 where q2.quote_number = q.quote_number) = 1 order by q.id desc limit 1;

  -- Every active person with a working sign-in: the three groups only with the Client App, with the documented keys;
  -- with it, an address, an invoice number and a quote number each find their record.
  for r in
    select e.id as emp, u.id as uid, u.email from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.uid, 'email', r.email, 'role', 'authenticated')::text, true);
    v_clients := hr.fn_app_level('client_app') in ('view', 'edit');
    if not v_clients then v_seen_without := true; end if;
    foreach v_term in array array[v_addr, v_inv, v_quo, 'mi'] loop
      set local role authenticated;
      v_res := ops.portal_search(v_term);
      reset role;
      v_n := v_n + 1;
      if (v_res ? 'properties' and v_res ? 'invoices' and v_res ? 'quotes') is distinct from v_clients
         or (not v_clients and (v_res ? 'properties' or v_res ? 'invoices' or v_res ? 'quotes')) then
        raise exception 'verify_fail: the new groups show when they must not, or not when they must (person %)', r.emp;
      end if;
      if v_clients then
        select count(*) into v_bad from (
          select x from jsonb_array_elements(v_res -> 'properties') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['address', 'city', 'client_id', 'client_name', 'code', 'id', 'is_billing', 'name', 'rank', 'tab', 'zip'] or x ->> 'tab' <> 'sites'
          union all
          select x from jsonb_array_elements(v_res -> 'invoices') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['client_id', 'client_name', 'code', 'id', 'invoice_number', 'issued', 'rank', 'status', 'tab'] or x ->> 'tab' <> 'billing'
          union all
          select x from jsonb_array_elements(v_res -> 'quotes') x
           where (select array_agg(k order by k) from jsonb_object_keys(x) k)
                 <> array['archived', 'client_id', 'client_name', 'code', 'id', 'quote_number', 'rank', 'status', 'tab', 'title'] or x ->> 'tab' <> 'billing') q;
        if v_bad <> 0 then raise exception 'verify_fail: % new results do not have the documented keys (person %)', v_bad, r.emp; end if;
        if v_term = v_addr and not (v_res -> 'properties') @> jsonb_build_array(jsonb_build_object('id', v_pid, 'tab', 'sites')) then
          raise exception 'verify_fail: an address does not find its site (person %)', r.emp;
        end if;
        if v_term = v_inv and (v_res -> 'invoices' -> 0 ->> 'invoice_number') is distinct from v_inv then
          raise exception 'verify_fail: an invoice number does not find its invoice first (person %)', r.emp;
        end if;
        if v_term = v_quo and (v_res -> 'quotes' -> 0 ->> 'quote_number') is distinct from v_quo then
          raise exception 'verify_fail: a quote number does not find its quote first (person %)', r.emp;
        end if;
      end if;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  if not v_seen_without or v_n < 20 then raise exception 'verify_fail: no person without the Client App, or only % searches', v_n; end if;
  raise notice 'search ok: % searches', v_n;
end $search$;
