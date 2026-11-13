-- Standing check of derm.manifest_row_states() (the Ops Portal Manifests rows; migration 2026-11-13_0148_derm_manifest_row_states.sql).
-- Run as owner (the Management API), as ONE request. It reads only, and RAISES unless:
--   anon and PUBLIC cannot execute it, authenticated and service_role can; it is SECURITY DEFINER, STABLE, with an
--   empty search_path; a signed-in person with no DERM Tracker access gets the usual refusal; a signed-in admin gets
--   one entry per row of the list, with every live manifest row in exactly one entry; "needs" follows the states;
--   every sheet of derm.v_stamp_sheets is opened by a row with the same state and counts; no "@" is returned.
-- It can fail once for a reason in the data: a sheet stamped between its two reads. Run it again before believing it.
-- Its controls (the same block must FAIL on a copy granted to anon, with the gate removed, with a row left out)
-- were run on 2026-11-13: 6 of 6 failed as they must.

do $verify$
declare
  v_sig constant text := 'derm.manifest_row_states()';
  v_uid uuid; v_email text; v_lvl text; v_res jsonb; v_keys bigint; v_want bigint; v_bad bigint; v_msg text; v_state text;
  r record;
begin
  if has_function_privilege('anon', v_sig, 'execute') then raise exception 'verify_fail: anon can execute'; end if;
  if has_function_privilege('public', v_sig, 'execute') then raise exception 'verify_fail: PUBLIC can execute'; end if;
  if exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
              where p.oid = v_sig::regprocedure and a.grantee = 0) then raise exception 'verify_fail: PUBLIC holds a grant'; end if;
  if not has_function_privilege('authenticated', v_sig, 'execute') then raise exception 'verify_fail: authenticated cannot execute'; end if;
  if not has_function_privilege('service_role', v_sig, 'execute') then raise exception 'verify_fail: service_role cannot execute'; end if;
  if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'verify_fail: not SECURITY DEFINER, STABLE, with an empty search_path';
  end if;

  -- A signed-in person with no DERM Tracker access: refused with the access sentence, before any data is read.
  for r in
    select u.id, u.email
      from public.employees e
      join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
     where e.status = 'ACTIVE' and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until <= now())
     order by (e.access_level = 'field') desc, e.id
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    v_lvl := hr.fn_app_level('derm_tracker');
    if v_lvl = 'none' then v_uid := r.id; v_email := r.email; exit; end if;
  end loop;
  if v_uid is null then raise exception 'verify_fail: no signed-in person without DERM Tracker access to test the refusal with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_res := derm.manifest_row_states();
    v_state := 'no error';
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if v_state is distinct from '42501' or v_msg not like 'You do not have access to do this in DERM Tracker.%' then
    raise exception 'verify_fail: a person without DERM Tracker access was not refused the usual way (% %)', v_state, v_msg;
  end if;

  -- A signed-in admin: one entry per row of today's list, in the list's own keys.
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
  reset role;
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_keys from jsonb_object_keys(v_res);
  with live as (
    select dm.id,
           case when coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') = '' then 'No number'
                when coalesce(dm.yellow_ticket_number, '') <> '' then 'Broward #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number)
                else 'Miami-Dade #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number) end as key
      from public.derm_manifests dm where dm.deleted_at is null
  ), got as (
    select e.key, (i.value)::bigint as id
      from jsonb_each(v_res) e cross join lateral jsonb_array_elements_text(e.value -> 'manifest_ids') i(value)
  )
  select (select count(distinct l.key) from live l),
         (select count(*) from live l full join got g on g.id = l.id and g.key = l.key where l.id is null or g.id is null)
    into v_want, v_bad;
  if v_keys = 0 or v_keys is distinct from v_want then raise exception 'verify_fail: % entries for % rows of the list', v_keys, v_want; end if;
  if v_bad <> 0 then raise exception 'verify_fail: % manifest rows are not in exactly the entry of their list row', v_bad; end if;

  -- Every entry has its four places, and "needs" follows them.
  select count(*) into v_bad from jsonb_each(v_res) e
   where not (e.value ? 'papers' and e.value ? 'stamps' and e.value ? 'city' and e.value ? 'needs' and e.value ? 'worst' and e.value ? 'sheets')
      or (e.value ->> 'needs')::boolean is distinct from
         (coalesce(e.value #>> '{papers,s}', '') in ('warn', 'bad') or coalesce(e.value #>> '{stamps,s}', '') in ('warn', 'bad')
          or coalesce(e.value #>> '{copies,s}', '') in ('warn', 'bad') or coalesce(e.value #>> '{city,s}', '') in ('warn', 'bad')
          or coalesce(e.value #>> '{visit,s}', '') in ('warn', 'bad'));
  if v_bad <> 0 then raise exception 'verify_fail: % entries are incomplete or their "needs" does not follow their states', v_bad; end if;

  -- The sheets: every sheet of the Stamp list is opened by a row, and its state, counts and folder are the list's own.
  with fn as (
    select distinct s ->> 'number' as wm, s ->> 'folder' as folder, s ->> 'state' as state,
           (s ->> 'placed')::bigint as placed, (s ->> 'total')::bigint as total
      from jsonb_each(v_res) e cross join lateral jsonb_array_elements(e.value -> 'sheets') s
  ), vw as (
    select v.white_manifest_number as wm, v.dump_folder as folder,
           case when v.skipped then 'skipped' when v.completed then 'completed' when v.placed_rows > 0 then 'in_progress' else 'not_started' end as state,
           v.placed_rows as placed, v.total_rows as total
      from derm.v_stamp_sheets v
  )
  select count(*) into v_bad from fn full join vw using (wm, folder, state, placed, total) where fn.wm is null or vw.wm is null;
  if v_bad <> 0 then raise exception 'verify_fail: % sheets differ between the function and derm.v_stamp_sheets', v_bad; end if;

  if v_res::text like '%@%' then raise exception 'verify_fail: the result holds an @, so maybe an email address'; end if;

  raise notice 'verify ok: % entries, % that need someone', v_keys,
    (select count(*) from jsonb_each(v_res) e where (e.value ->> 'needs')::boolean);
end $verify$;
