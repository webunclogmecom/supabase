-- ============================================================================
-- 2026-09-28_1816_site_file_wording.sql (applied 2026-09-28_1817 ET)
-- 2026-09-28 · "Driver page" becomes "Site file" in the database's sentences (wording only)
-- ============================================================================
-- Fred, 2026-09-28: "at the drivers page, which i don't like that name, because is not only a drivers page, is also
--   for the client to see, that page is just like a 'file' where we display the data we have gathered from the client".
--   His pick: the name "Site file" (button "View site file", header "UnclogMe · Site file").
-- Plan: the 2026-09-28 site file plan in Building Apps/Picture Planner/docs/specs/ (its inventory walked the live
-- bundle, every pg_proc body, the edge fn driver-page, the Client App and the collector form).
--
-- Six sentences in three functions, all read by STAFF only (the Page Builder), copied whole from the live bodies with
-- only these strings changed:
--   client.get_property_activity (the body 2026-09-28_1015 left, md5 6ce868ead6b96ad58e7a9f363a0bfb24):
--     'Version N of the driver page submitted for approval'  -> 'Version N of the site file submitted for approval'
--     'Version N of the driver page approved'                -> 'Version N of the site file approved'
--     'Driver link created'                                  -> 'Site file link created'
--     'Driver link replaced'                                 -> 'Site file link replaced'
--   client.rotate_driver_link (the Get a new link refusal):
--     'This page has no driver link yet. ...'                -> 'This page has no site file link yet. ...'
--   public.fn_page_blocker (get_page_builder's banner and link card, page_builder_list, the submit and approve refusals;
--   fn_driver_page only tests it for NULL, so the public page never shows it):
--     'This client is inactive, so a driver link would not open.' -> '... so the site file link would not open.'
--
-- Kept on purpose (internal names, no screen shows them): the route /driver, the edge fn driver-page, fn_driver_page,
-- rotate_driver_link, the JSON key driver_link_blocker, the event kinds driver_link_created / driver_link_replaced, the
-- DETAIL codes (blocker=no_link, blocker=link_would_not_open). The edge fn driver-page needs NO change: its replies
-- ("This link is not valid.", "Could not open this page, please try again.", 405/413/400) never name the page.
-- A comment in client.accept_intake_answers says "a driver page": comments are not shown; that function is untouched.
--
-- Rule 8 (audit): no table, no write. Grants and attributes unchanged (CREATE OR REPLACE keeps them; asserted below).
-- ATOMIC: no COMMIT; the VERIFY's one call that could write (rotate) runs in a sentinel sub-block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> '6ce868ead6b96ad58e7a9f363a0bfb24'
     or md5(pg_get_functiondef('client.rotate_driver_link(bigint)'::regprocedure)) <> '20938dd3c56f5762d7b6fdf78105f39f'
     or md5(pg_get_functiondef('public.fn_page_blocker(bigint)'::regprocedure)) <> 'af5015a0d9bdba215c7862584327ea55' then
    raise exception 'PIN: a function this migration copies changed since it was written';
  end if;
  -- Each old sentence lives in exactly one body (so nothing else quotes or compares it), and fn_page_blocker has
  -- exactly its five known callers. Positive control: the sweep finds the three bodies it is about to change.
  if (select count(*) from pg_proc where prosrc like '%of the driver page submitted for approval%') <> 1
     or (select count(*) from pg_proc where prosrc like '%of the driver page approved%') <> 1
     or (select count(*) from pg_proc where prosrc like '%''Driver link created''%') <> 1
     or (select count(*) from pg_proc where prosrc like '%''Driver link replaced''%') <> 1
     or (select count(*) from pg_proc where prosrc like '%no driver link yet%') <> 1
     or (select count(*) from pg_proc where prosrc like '%so a driver link would not open%') <> 1
     or (select string_agg(n.nspname || '.' || p.proname, ',' order by n.nspname || '.' || p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where p.prosrc like '%fn_page_blocker%')
        <> 'client.approve_property_page,client.get_page_builder,client.page_builder_list,client.submit_property_page,public.fn_driver_page' then
    raise exception 'PIN: another function quotes one of the sentences, or fn_page_blocker has a new caller';
  end if;
  if exists (select 1 from pg_proc where prosrc ilike any (array['%site file link%', '%of the site file%'])) then
    raise exception 'PIN: a "site file" sentence already exists';
  end if;
end $pin$;

-- The before picture, for the VERIFY: the three definitions, their grants and attributes, and 1164's history as Fred.
create temp table _sf_before on commit drop as
select p.oid::regprocedure::text as fn, pg_get_functiondef(p.oid) as def, coalesce(p.proacl::text, 'NULL') as acl,
       p.prosecdef, p.provolatile, p.proconfig, p.proowner::regrole::text as owner, p.prolang, null::jsonb as act1164
  from pg_proc p
 where p.oid in ('client.get_property_activity(bigint)'::regprocedure, 'client.rotate_driver_link(bigint)'::regprocedure,
                 'public.fn_page_blocker(bigint)'::regprocedure);
do $snap$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  set local role authenticated;
  v := client.get_property_activity(1164);
  reset role;
  update _sf_before set act1164 = v where fn = 'client.get_property_activity(bigint)';
end $snap$;

-- 1. The history's sentences (the 2026-09-28_1015 body, four strings changed).
CREATE OR REPLACE FUNCTION client.get_property_activity(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_property_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_property_activity';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_property_activity';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', ev.at, 'kind', ev.kind, 'who', ev.who, 'intake_id', ev.intake_id, 'version', ev.version,
             'text', ev.what || coalesce(' by ' || ev.who, '')
                     -- a developer approval of one's own version says so (2026-09-27)
                     || case when ev.kind = 'page_approved' and exists (
                               select 1 from public.property_pages x
                                where x.property_id = p_property_id and x.version = ev.version
                                  and x.approved_by = x.submitted_by)
                             then ', who also made it (developer approval)' else '' end
                     -- what an accept changed comes after the name (2026-09-28)
                     || coalesce(ev.tail, ''))
           order by ev.at desc, ev.ord desc, ev.sub)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who,
               null::text as tail, null::bigint as sub
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email), null, null
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), ''), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.submitted_at is not null
        union all
        select i.cancelled_at, 4, 'form_cancelled', i.id, null,
               'Site survey form #' || i.id || ' cancelled',
               public.fn_page_staff_name((
                 select l.jwt_claims ->> 'email' from audit.logs l
                  where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                    and l.table_schema = 'public' and l.operation = 'UPDATE'
                    and l.old_row ->> 'cancelled_at' is null and l.new_row ->> 'cancelled_at' is not null
                  order by l.changed_at desc limit 1)), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the site file submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the site file approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Site file link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by)), null, null
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Site file link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email'), null, null
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
        union all
        -- An approver saved a form answer to the property record (Picture Planner, 2026-09-28). One row per field;
        -- the rows of one save share accepted_at, so the ledger id keeps them in the order they were saved.
        -- The lock box code is shown: staff already see it on the property card.
        select a.accepted_at, 9, 'intake_accepted', a.intake_id, null,
               'Accepted from Site survey form #' || a.intake_id,
               public.fn_page_staff_name(a.actor),
               ': ' || case a.question_key
                         when 'access_entry.lock_box_code'   then 'Lock box code'
                         when 'access_hours.schedule'        then 'When we can come'
                         when 'grease_trap.capacity_gallons' then 'Grease trap gallons'
                         when 'grease_trap.manhole_count'    then 'Manholes'
                         when 'grease_trap.sample_ports'     then 'Sample ports'
                         else a.question_key end
                    || case when a.question_key = 'access_hours.schedule' then ' replaced'
                            else ' ' || coalesce(a.old_value #>> '{}', 'Not on file') || ' → '
                                     || coalesce(a.new_value #>> '{}', 'Not on file') end,
               a.id
          from public.property_intake_accepts a
         where a.property_id = p_property_id
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$
;

-- 2. Get a new link's refusal (the live body, one string changed).
CREATE OR REPLACE FUNCTION client.rotate_driver_link(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_new   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.rotate_driver_link';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.rotate_driver_link';
  end if;
  update public.property_page_links
     set public_id = public.gen_short_id(22), rotated_at = now(), rotated_by = v_uid
   where property_id = p_property_id
  returning public_id into v_new;
  if v_new is null then
    raise exception 'This page has no site file link yet. It gets one when it is first submitted.' using errcode = 'P0002',
      detail = 'blocker=no_link in client.rotate_driver_link';
  end if;
  return jsonb_build_object('ok', true, 'public_id', v_new);
end $function$
;

-- 3. The page blocker (the live body, one string changed).
CREATE OR REPLACE FUNCTION public.fn_page_blocker(p_property_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when p.id is null or p.deleted_at is not null then 'This property is not active any more.'
    when coalesce(p.is_billing, false) then 'This is a billing address, not a place we service.'
    when c.status = 'INACTIVE' then 'This client is inactive, so the site file link would not open.'
    else null end
    from (select 1) one
    left join public.properties p on p.id = p_property_id
    left join public.clients c on c.id = p.client_id
$function$
;

-- VERIFY.
do $verify$
declare
  v_old      _sf_before;
  v_act      jsonb;
  v_back     jsonb;
  v_pb       jsonb;
  v_inactive bigint := (select p.id from public.properties p join public.clients c on c.id = p.client_id
                         where c.status = 'INACTIVE' and p.deleted_at is null and not coalesce(p.is_billing, false)
                         order by p.id limit 1);
  v_nolink   bigint := (select p.id from public.properties p
                         where not exists (select 1 from public.property_page_links k where k.property_id = p.id)
                         order by p.id limit 1);
  v_links0   text   := (select md5(string_agg(to_jsonb(k)::text, ',' order by k.property_id)) from public.property_page_links k);
  v_state text; v_detail text; v_msg text;
begin
  -- V1. Only the strings changed: each new definition is the old one with exactly these replacements, and the grants,
  -- owner, language, security and volatility are the same as before (and as measured on 2026-09-28).
  for v_old in select * from _sf_before loop
    if pg_get_functiondef(v_old.fn::regprocedure) is distinct from
         replace(replace(replace(replace(replace(replace(v_old.def,
           ' of the driver page submitted for approval''', ' of the site file submitted for approval'''),
           ' of the driver page approved''', ' of the site file approved'''),
           '''Driver link created''', '''Site file link created'''),
           '''Driver link replaced''', '''Site file link replaced'''),
           'This page has no driver link yet.', 'This page has no site file link yet.'),
           'so a driver link would not open.', 'so the site file link would not open.')
       or pg_get_functiondef(v_old.fn::regprocedure) = v_old.def then
      raise exception 'VERIFY 1a: % is not its old body with only the sentences changed', v_old.fn;
    end if;
    if (select coalesce(p.proacl::text, 'NULL') <> v_old.acl or p.prosecdef <> v_old.prosecdef or p.provolatile <> v_old.provolatile
               or p.proconfig is distinct from v_old.proconfig or p.proowner::regrole::text <> v_old.owner or p.prolang <> v_old.prolang
          from pg_proc p where p.oid = v_old.fn::regprocedure) then
      raise exception 'VERIFY 1b: % lost a grant or an attribute', v_old.fn;
    end if;
  end loop;
  if (select count(*) from _sf_before) <> 3
     or (select string_agg(acl, ' ' order by fn) from _sf_before)
        <> '{postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 1c: the grants are not the ones measured on 2026-09-28';
  end if;

  -- V2. No body says "driver page" or "Driver link" in a sentence any more; each new sentence is in exactly one body.
  if exists (select 1 from pg_proc where prosrc like any (array['%of the driver page submitted%', '%of the driver page approved%',
               '%''Driver link created''%', '%''Driver link replaced''%', '%no driver link yet%', '%so a driver link would not open%']))
     or (select count(*) from pg_proc where prosrc like '%of the site file submitted for approval%') <> 1
     or (select count(*) from pg_proc where prosrc like '%of the site file approved%') <> 1
     or (select count(*) from pg_proc where prosrc like '%''Site file link created''%') <> 1
     or (select count(*) from pg_proc where prosrc like '%''Site file link replaced''%') <> 1
     or (select count(*) from pg_proc where prosrc like '%no site file link yet%') <> 1
     or (select count(*) from pg_proc where prosrc like '%so the site file link would not open%') <> 1 then
    raise exception 'VERIFY 2: an old sentence survived, or a new one is missing';
  end if;

  -- V3. 1164's history, read as Fred: the old wording is gone, the new one reads on every version and link row, and
  -- nothing else moved (the reply with the four new strings mapped back equals the reply from before).
  perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_act := client.get_property_activity(1164);
  v_pb  := client.get_page_builder(v_inactive);
  reset role;
  if exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'text' ~* 'driver[[:space:]]+(page|link)') then
    raise exception 'VERIFY 3a: 1164''s history still says driver page or driver link';
  end if;
  -- positive control: 1164 has submitted, approved, created and replaced rows (3, 3, 1, 1 on 2026-09-28)
  if (select count(*) from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_submitted') < 1
     or (select count(*) from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_approved') < 1
     or (select count(*) from jsonb_array_elements(v_act) e where e ->> 'kind' = 'driver_link_created') < 1
     or (select count(*) from jsonb_array_elements(v_act) e where e ->> 'kind' = 'driver_link_replaced') < 1
     or exists (select 1 from jsonb_array_elements(v_act) e
                 where (e ->> 'kind' = 'page_submitted' and e ->> 'text' not like 'Version ' || (e ->> 'version') || ' of the site file submitted for approval%')
                    or (e ->> 'kind' = 'page_approved' and e ->> 'text' not like 'Version ' || (e ->> 'version') || ' of the site file approved%')
                    or (e ->> 'kind' = 'driver_link_created' and e ->> 'text' not like 'Site file link created%')
                    or (e ->> 'kind' = 'driver_link_replaced' and e ->> 'text' not like 'Site file link replaced%')) then
    raise exception 'VERIFY 3b: 1164''s history does not read the site file sentences on every version and link row';
  end if;
  v_back := replace(replace(replace(replace(v_act::text,
              ' of the site file submitted for approval', ' of the driver page submitted for approval'),
              ' of the site file approved', ' of the driver page approved'),
              '"Site file link created', '"Driver link created'),
              '"Site file link replaced', '"Driver link replaced')::jsonb;
  if v_back is distinct from (select act1164 from _sf_before where fn = 'client.get_property_activity(bigint)') then
    raise exception 'VERIFY 3c: 1164''s history changed beyond the four sentences';
  end if;

  -- V4. The page blocker: an inactive client's property reads the new sentence, through get_page_builder too; an
  -- active property still reads NULL and a missing one the unchanged first sentence.
  if v_inactive is null
     or public.fn_page_blocker(v_inactive) is distinct from 'This client is inactive, so the site file link would not open.'
     or v_pb::text not like '%This client is inactive, so the site file link would not open.%'
     or v_pb::text like '%driver link would not open%'
     or public.fn_page_blocker(1164) is not null
     or public.fn_page_blocker(-1) is distinct from 'This property is not active any more.' then
    raise exception 'VERIFY 4: the blocker reads %', public.fn_page_blocker(v_inactive);
  end if;

  -- V5. Get a new link on a property with no link: the new sentence, the same code and DETAIL. Inside a sentinel block,
  -- so even a property that gained a link meanwhile is rolled back.
  begin
    set local role authenticated;
    begin
      perform client.rotate_driver_link(v_nolink);
      raise exception 'VERIFY 5: rotate on a property with no link went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
      if v_state <> 'P0002' or v_detail is distinct from 'blocker=no_link in client.rotate_driver_link'
         or v_msg is distinct from 'This page has no site file link yet. It gets one when it is first submitted.' then
        raise exception 'VERIFY 5: gave % / % / %', v_state, v_detail, v_msg;
      end if;
    end;
    reset role;
    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  reset role;
  if (select md5(string_agg(to_jsonb(k)::text, ',' order by k.property_id)) from public.property_page_links k) is distinct from v_links0 then
    raise exception 'VERIFY 6: a driver link changed';
  end if;
  raise notice 'VERIFY: six sentences say site file, nothing else in the three bodies changed, grants kept, 1164 reads the new history';
end $verify$;

drop table _sf_before;

notify pgrst, 'reload schema';
