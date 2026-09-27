-- ============================================================================
-- 2026-09-27_1155_page_developer_approval.sql (applied 2026-09-27_1155 ET)
-- 2026-09-27 · Driver pages: Fred approves too, and only Fred may approve his own version
-- ============================================================================
-- Fred, 2026-09-27, answering "a real approval: Serena, Yannick or Diego should approve one test version":
--   "Good, also I can also approve it. And only me can double approve it, meaning that i can bypass that
--    approval step because i'm dev side, and for testing and other purposes i can't be waiting on other people."
--
-- 1. Fred's login (auth user 5ca25eb1-...) joins app_config.page_approvers (Diego, Serena, Yannick, Fred), so he
--    can approve anyone's version, and fn_page_approver_names now reads "Diego, Fred, Serena or Yannick".
-- 2. NEW app_config.page_self_approvers = Fred's login ONLY, read by NEW public.fn_page_self_approver_ids()
--    (the same reader as fn_page_approver_ids, its own key). A login on that list may approve a version it
--    submitted itself: a "developer approval". Everyone else still needs a second person. Adding someone to it
--    is one config write and is Fred's decision alone.
-- 3. The table rule moves: CHECK property_pages_check1 (approved_by IS DISTINCT FROM submitted_by) is dropped and
--    the same rule, with that one exception, is enforced in public.fn_property_pages_append_only (the append-only
--    trigger), so a raw write cannot skip it either (23514, blocker=own_version in public.property_pages).
-- 4. client.approve_property_page lets a self-approver through its own_version refusal; client.get_page_builder
--    does not show them the "another person has to approve it" blocker, and returns can_self_approve (true only
--    for a login on BOTH lists). The builder's Submit confirm reads it in a Picture Planner change shipped in the
--    same cycle (until then its confirm still says "(not you) approves it"; the Approve button itself already
--    works, it follows can_approve).
-- 5. client.get_property_activity: an approval of one's own version reads "... approved by Fred, who also made it
--    (developer approval)", so the history never hides that nobody else checked it.
--    The public driver page is unchanged ("Checked by Fred").
--
-- ⚠ The cost, stated so it is a decision and not an accident: while this list holds a login, that login alone can
-- publish a driver page (lock box and gate codes included) with nobody else looking. Keep it to Fred's login.
--
-- Rule 8 (audit): no new table; app_config is audited (audit_app_config), property_pages is audited. Grants: the new
-- helper is revoked by name and gets the same proacl as fn_page_approver_ids ({postgres, service_role});
-- replaced functions keep theirs (asserted). ATOMIC: no COMMIT; the VERIFY's writes run in a sentinel sub-block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> '4ef5caf021fafa37f87760f17cde40f0'
     or md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '609b863b44869aeb38bfd328fa4ca58b'
     or md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> 'c05573ac5e843b7c2a349da55380a35d'
     or md5(pg_get_functiondef('public.fn_property_pages_append_only()'::regprocedure)) <> '96f7a72acc9d404ad1fab03960063b13'
     or md5(pg_get_functiondef('public.fn_page_approver_ids()'::regprocedure)) <> '1ce2b08a1c30397886e576fdc6871dae' then
    raise exception 'PIN: a page function changed since this migration was written';
  end if;
  if not exists (select 1 from auth.users where id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' and lower(email) = 'fred@ayache.com') then
    raise exception 'PIN: Fred''s login id is not what this migration expects';
  end if;
  if exists (select 1 from public.app_config where key = 'page_self_approvers') then
    raise exception 'PIN: app_config.page_self_approvers already exists';
  end if;
end $pin$;

-- ----------------------------------------------------------------- 1. config: Fred approves; only Fred self-approves
update public.app_config
   set value = value || ',5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'
 where key = 'page_approvers'
   and not ('5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid = any (public.fn_page_approver_ids()));
insert into public.app_config (key, value) values ('page_self_approvers', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b');

-- ----------------------------------------------------------------- 2. the self-approver reader
CREATE FUNCTION public.fn_page_self_approver_ids()
 RETURNS uuid[]
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(array_agg(btrim(x)::uuid), '{}')
    from pg_catalog.regexp_split_to_table(
           coalesce((select value from public.app_config where key = 'page_self_approvers'), ''), ',') x
   where btrim(x) <> ''
$function$;
revoke all on function public.fn_page_self_approver_ids() from public, anon, authenticated, service_role;
grant execute on function public.fn_page_self_approver_ids() to service_role;

-- ----------------------------------------------------------------- 3. the table rule, with its one exception
CREATE OR REPLACE FUNCTION public.fn_property_pages_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'Page versions are never deleted.' using errcode = '55000',
      detail = 'blocker=append_only in public.property_pages';
  end if;
  if tg_op = 'INSERT' then
    if new.approved_at is not null or new.approved_by is not null or new.approved_by_email is not null then
      raise exception 'A page version is approved after it is submitted, never while it is written.'
        using errcode = '55000', detail = 'blocker=append_only in public.property_pages';
    end if;
    return new;
  end if;
  if old.approved_at is not null
     or new.approved_at is null
     or (pg_catalog.to_jsonb(new) - 'approved_at' - 'approved_by' - 'approved_by_email')
        is distinct from
        (pg_catalog.to_jsonb(old) - 'approved_at' - 'approved_by' - 'approved_by_email') then
    raise exception 'A page version cannot be changed after it is submitted; only its approval can be recorded, once.'
      using errcode = '55000', detail = 'blocker=append_only in public.property_pages';
  end if;
  -- Nobody approves their own version (it was the CHECK property_pages_check1 until 2026-09-27). The one
  -- exception is app_config.page_self_approvers, today Fred's login only (Fred, 2026-09-27: "only me can
  -- double approve it ... because i'm dev side, and for testing and other purposes i can't be waiting on other
  -- people"). Checked here so a raw write cannot skip it either.
  if new.approved_by = old.submitted_by
     and not coalesce(new.approved_by = any (public.fn_page_self_approver_ids()), false) then
    raise exception 'Nobody approves their own version of a page.'
      using errcode = '23514', detail = 'blocker=own_version in public.property_pages';
  end if;
  return new;
end $function$;
alter table public.property_pages drop constraint property_pages_check1;

-- ----------------------------------------------------------------- 4. approve, the builder read, the history
CREATE OR REPLACE FUNCTION client.approve_property_page(p_page_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_page  public.property_pages;
  v_newest int;
  v_block text;
  v_map   jsonb;
  v_cur   jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.approve_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.approve_property_page';
  end if;
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can approve a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.approve_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.approve_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved.' using errcode = '22023',
      detail = 'blocker=already_approved in client.approve_property_page';
  end if;
  select max(version) into v_newest from public.property_pages where property_id = v_page.property_id;
  if v_page.version <> v_newest then
    raise exception 'A newer version of this page was submitted. Approve that one instead.' using errcode = '22023',
      detail = 'blocker=not_newest in client.approve_property_page';
  end if;
  -- A developer approval (app_config.page_self_approvers, Fred only) may approve their own version.
  if v_page.submitted_by = v_uid and not (v_uid = any (public.fn_page_self_approver_ids())) then
    raise exception 'You submitted this version, so another person has to approve it.' using errcode = '42501',
      detail = 'blocker=own_version in client.approve_property_page';
  end if;
  v_block := public.fn_page_blocker(v_page.property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.approve_property_page';
  end if;

  update public.property_pages
     set approved_at = now(), approved_by = v_uid, approved_by_email = v_email
   where id = p_page_id;

  -- Since 2026-09-27 the map is drawn in the draft and reaches the property only here, when the version is
  -- approved (Fred: "Make it draft-only"), by a second person or by a developer approval (page_self_approvers). Only a version whose map came from the draft is
  -- copied: submit stores that map as an object WITHOUT rev. A version from an older builder froze the
  -- property's own map (NULL or an object WITH rev) while that builder may still be drawing on the
  -- property, so it is left alone. The revision always moves and the column is never set to NULL (a
  -- NULL restarts the revision at 0, and a stale save at that number would be accepted). The row is
  -- locked only when there is something to write.
  v_map := v_page.content -> 'site_map';
  if jsonb_typeof(v_map) = 'object' and not (v_map ? 'rev') then
    select p.site_map into v_cur from public.properties p where p.id = v_page.property_id;
    if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
      select p.site_map into v_cur from public.properties p where p.id = v_page.property_id for update;
      if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
        update public.properties
           set site_map = v_map || jsonb_build_object('rev', coalesce((v_cur ->> 'rev')::int, 0) + 1)
         where id = v_page.property_id;
      end if;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$;

CREATE OR REPLACE FUNCTION client.get_page_builder(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p     record;
  v_live  public.property_pages;
  v_pend  public.property_pages;
  v_newest int;
  v_out   jsonb;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_builder';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_builder';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_builder';
  end if;

  select p.id, p.client_id, p.name, p.address, p.city, p.latitude, p.longitude, p.site_map,
         p.is_billing, p.deleted_at, c.client_code, c.name as client_name
    into v_p
    from public.properties p join public.clients c on c.id = p.client_id
   where p.id = p_property_id;
  if not found or v_p.deleted_at is not null then
    raise exception 'This property is not active any more.' using errcode = 'P0002',
      detail = 'blocker=property_retired in client.get_page_builder';
  end if;
  if coalesce(v_p.is_billing, false) then
    raise exception 'This is a billing address, not a place we service.' using errcode = '22023',
      detail = 'blocker=billing_property in client.get_page_builder';
  end if;

  select max(version) into v_newest from public.property_pages where property_id = p_property_id;
  select * into v_live from public.property_pages
   where property_id = p_property_id and approved_at is not null order by version desc limit 1;
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and version > coalesce(v_live.version, 0)
   order by version desc limit 1;

  v_block := case
    when v_pend.id is null then 'There is nothing waiting for approval.'
    when not (v_uid = any (public.fn_page_approver_ids())) then
      'Only ' || public.fn_page_approver_names() || ' can approve a page.'
    when v_pend.submitted_by = v_uid and not (v_uid = any (public.fn_page_self_approver_ids()))
      then 'You submitted this version, so another person has to approve it.'
    else public.fn_page_blocker(p_property_id) end;

  with owned as (
    select o.*, q.label from public.fn_page_photo_ids(p_property_id) o
      left join client.v_intake_questions q on q.question_key = o.question_key),
  item as (
    select o.photo_id, jsonb_build_object(
             'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
             'visit_id', case when o.kind = 'visit' then o.entity_id end,
             'intake_id', case when o.kind = 'intake' then o.entity_id end,
             'visit_date', o.visit_date, 'question_key', o.question_key,
             'label', coalesce(o.label, o.question_key), 'caption', o.caption,
             'rotation_deg', o.rotation_deg, 'content_type', o.content_type) as j,
           o.kind, o.entity_id, o.visit_date
      from owned o),
  recent_visits as (
    select entity_id from owned where kind = 'visit'
     group by entity_id order by max(visit_date) desc, entity_id desc limit 12),
  refd as (
    select distinct (ph ->> 'photo_id')::bigint as photo_id
      from (select v_live.content as c union all select v_pend.content) s,
           jsonb_array_elements(s.c -> 'photos') ph
     where s.c is not null)
  select jsonb_build_object(
    'property', jsonb_build_object(
        'id', v_p.id, 'client_id', v_p.client_id, 'client_code', v_p.client_code,
        'client_name', v_p.client_name, 'name', nullif(btrim(v_p.name), ''),
        'address', v_p.address, 'city', v_p.city, 'lat', v_p.latitude, 'lng', v_p.longitude,
        'site_map', v_p.site_map, 'site_map_rev', coalesce((v_p.site_map ->> 'rev')::int, 0),
        -- The map is no longer a page source (fn_page_source), but the builder from before 2026-09-27
        -- compares it in its "Nothing changed" check and sends it back as its baseline; submit strips it.
        'source', public.fn_page_source(p_property_id) || jsonb_build_object('site_map', v_p.site_map - 'rev'),
        'driver_link_blocker', public.fn_page_blocker(p_property_id)),
    'intake', (select jsonb_build_object('intake_id', i.id, 'submitted_at', i.submitted_at, 'collector', i.collector)
                 from public.property_intakes i
                where i.property_id = p_property_id and i.submitted_at is not null and i.cancelled_at is null
                order by i.submitted_at desc limit 1),
    'pool', coalesce((select jsonb_agg(it.j order by it.kind, it.visit_date desc nulls last, it.photo_id)
                        from item it
                       where it.kind = 'intake' or it.entity_id in (select entity_id from recent_visits)), '[]'::jsonb),
    'referenced', coalesce((select jsonb_agg(case when it.photo_id is null
                    then jsonb_build_object('photo_id', r.photo_id, 'owned', false)
                    else it.j || jsonb_build_object('owned', true) end)
                  from refd r left join item it on it.photo_id = r.photo_id), '[]'::jsonb),
    -- People only (a name or a role), per D7 "unknown stays unknown"; the client-record label
    -- ("Business - 123-AB") is offered separately as the main line, never as a person.
    'contacts', coalesce((select jsonb_agg(jsonb_build_object(
                  'name', nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), ''),
                  'phone', nullif(btrim(cc.phone), ''),
                  'role', coalesce(nullif(btrim(cc.person_role_other), ''), nullif(btrim(cc.person_role), '')))
                  order by cc.property_id nulls last, cc.id)
                from public.client_contacts cc
               where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                 and (cc.property_id is null or cc.property_id = p_property_id)
                 and (nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), '') is not null
                      or nullif(btrim(cc.person_role), '') is not null
                      or nullif(btrim(cc.person_role_other), '') is not null)), '[]'::jsonb),
    'main_line', (select jsonb_build_object(
                    'name', regexp_replace(v_p.client_name, '\s*-\s*' || coalesce(v_p.client_code, '') || '\s*$', ''),
                    'phone', nullif(btrim(cc.phone), ''), 'role', 'Main line')
                    from public.client_contacts cc
                   where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                     and nullif(btrim(cc.phone), '') is not null
                   order by cc.property_id = p_property_id desc nulls last, cc.id limit 1),
    'newest_version', coalesce(v_newest, 0),
    'live', case when v_live.id is null then null else jsonb_build_object(
              'page_id', v_live.id, 'version', v_live.version, 'content', v_live.content,
              'source', v_live.source, 'submitted_at', v_live.submitted_at,
              'submitted_by_name', public.fn_page_staff_name(v_live.submitted_by_email),
              'approved_at', v_live.approved_at,
              'approved_by_name', public.fn_page_staff_name(v_live.approved_by_email)) end,
    'pending', case when v_pend.id is null then null else jsonb_build_object(
              'page_id', v_pend.id, 'version', v_pend.version, 'content', v_pend.content,
              'source', v_pend.source, 'submitted_at', v_pend.submitted_at,
              'submitted_by_name', public.fn_page_staff_name(v_pend.submitted_by_email),
              'mine', v_pend.submitted_by = v_uid) end,
    'link', (select jsonb_build_object('public_id', l.public_id, 'created_at', l.created_at, 'rotated_at', l.rotated_at)
               from public.property_page_links l where l.property_id = p_property_id),
    'can_approve', v_block is null,
    'approve_blocker', v_block,
    'approvers', public.fn_page_approver_names(),
    -- true only for a developer approval login (Fred): the builder's Submit confirm then says they can approve it.
    'can_self_approve', v_uid = any (public.fn_page_self_approver_ids()) and v_uid = any (public.fn_page_approver_ids()))
  into v_out;
  return v_out;
end $function$;

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
                             then ', who also made it (developer approval)' else '' end)
           order by ev.at desc, ev.ord desc)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email)
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), '')
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
                  order by l.changed_at desc limit 1))
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the driver page submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email)
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the driver page approved',
               public.fn_page_staff_name(pg.approved_by_email)
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Driver link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by))
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Driver link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email')
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$;

-- ----------------------------------------------------------------- 5. VERIFY
do $verify$
declare
  v_fred   uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_other  uuid := gen_random_uuid();
  v_pb     jsonb;
  v_base   jsonb;
  v_r      jsonb;
  v_act    jsonb;
  v_dp     jsonb;
  v_pid    bigint;
  v_state  text; v_detail text;
  v_ver0   int   := (select coalesce(max(version), 0) from public.property_pages where property_id = 1164);
  v_map0   jsonb := (select site_map from public.properties where id = 1164);
  v_appr0  text  := (select value from public.app_config where key = 'page_approvers');
  v_link   text  := (select public_id from public.property_page_links where property_id = 1164);
  v_opens0 int   := (select count(*) from public.property_page_opens where property_id = 1164);
begin
  -- V1. Config, constraint, grants.
  if public.fn_page_self_approver_ids() is distinct from array[v_fred]
     or not (v_fred = any (public.fn_page_approver_ids()))
     or cardinality(public.fn_page_approver_ids()) <> 4 then
    raise exception 'VERIFY 1a: approvers % / self-approvers %', public.fn_page_approver_ids(), public.fn_page_self_approver_ids();
  end if;
  if public.fn_page_approver_names() is distinct from 'Diego, Fred, Serena or Yannick' then
    raise exception 'VERIFY 1b: approver names read %', public.fn_page_approver_names();
  end if;
  if exists (select 1 from pg_constraint where conrelid = 'public.property_pages'::regclass and conname = 'property_pages_check1') then
    raise exception 'VERIFY 1c: the old CHECK is still there';
  end if;
  if (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'public.fn_page_self_approver_ids()'::regprocedure)
     <> '{postgres=X/postgres,service_role=X/postgres}'
     or (select string_agg(coalesce(proacl::text, 'NULL'), ' ') from pg_proc where oid in (
           'client.approve_property_page(bigint)'::regprocedure, 'client.get_page_builder(bigint)'::regprocedure,
           'client.get_property_activity(bigint)'::regprocedure))
        <> '{postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres}'
     or (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'public.fn_property_pages_append_only()'::regprocedure)
        <> '{postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 1d: a grant is wrong';
  end if;

  begin
    -- V2. Fred submits and approves his own version: the developer approval.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    if not coalesce((v_pb ->> 'can_self_approve')::boolean, false) then
      raise exception 'VERIFY 2a: can_self_approve is not true for Fred';
    end if;
    v_base := coalesce(v_pb -> 'pending' -> 'content', v_pb -> 'live' -> 'content');
    v_r := client.submit_property_page(1164, v_base || jsonb_build_object('site_map', jsonb_build_object('pins',
             jsonb_build_object('truck', jsonb_build_object('lat', round((v_pb -> 'property' ->> 'lat')::numeric + 0.0002, 6),
                                                            'lng', round((v_pb -> 'property' ->> 'lng')::numeric, 6))))),
             (v_pb ->> 'newest_version')::int, 0, v_pb -> 'property' -> 'source');
    v_pb := client.get_page_builder(1164);
    if not (v_pb ->> 'can_approve')::boolean or v_pb ->> 'approve_blocker' is not null then
      raise exception 'VERIFY 2b: Fred cannot approve his own version (%)', v_pb ->> 'approve_blocker';
    end if;
    v_r := client.approve_property_page((v_pb -> 'pending' ->> 'page_id')::bigint);
    v_act := client.get_property_activity(1164);
    reset role;
    if (select approved_by from public.property_pages where property_id = 1164 and version = v_ver0 + 1) is distinct from v_fred
       or (select submitted_by from public.property_pages where property_id = 1164 and version = v_ver0 + 1) is distinct from v_fred then
      raise exception 'VERIFY 2c: the developer approval was not recorded';
    end if;
    if v_act -> 0 ->> 'text' is distinct from 'Version ' || (v_ver0 + 1) || ' of the driver page approved by Fred, who also made it (developer approval)' then
      raise exception 'VERIFY 2d: the history reads %', v_act -> 0 ->> 'text';
    end if;
    if exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_approved'
                  and (e ->> 'version')::int = 1 and e ->> 'text' ~ 'developer approval') then
      raise exception 'VERIFY 2e: an approval by someone else is labelled a developer approval';
    end if;
    if (select site_map ->> 'rev' from public.properties where id = 1164) is null then
      raise exception 'VERIFY 2f: the approved map did not reach the property';
    end if;
    v_dp := public.fn_driver_page(v_link, true, 'verify 2026-09-27 self approval');
    if v_dp ->> 'approved_by' is distinct from 'Fred' or (v_dp ->> 'version')::int <> v_ver0 + 1 then
      raise exception 'VERIFY 2g: the driver page shows v% checked by %', v_dp ->> 'version', v_dp ->> 'approved_by';
    end if;

    -- V3. Any other approver still cannot approve their own version: the RPC, the builder read and a raw write.
    update public.app_config set value = value || ',' || v_other::text where key = 'page_approvers';
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_other, 'email', 'verify.approver@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    if coalesce((v_pb ->> 'can_self_approve')::boolean, true) then
      raise exception 'VERIFY 3a: can_self_approve is not false for another approver';
    end if;
    perform client.submit_property_page(1164, v_base || jsonb_build_object('site_map', null), (v_pb ->> 'newest_version')::int, 0,
              v_pb -> 'property' -> 'source');
    v_pb := client.get_page_builder(1164);
    if (v_pb ->> 'can_approve')::boolean
       or v_pb ->> 'approve_blocker' is distinct from 'You submitted this version, so another person has to approve it.' then
      raise exception 'VERIFY 3b: another approver sees can_approve % / %', v_pb ->> 'can_approve', v_pb ->> 'approve_blocker';
    end if;
    begin
      perform client.approve_property_page((v_pb -> 'pending' ->> 'page_id')::bigint);
      raise exception 'VERIFY 3c: another approver approved their own version' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=own_version in client.approve_property_page' then
        raise exception 'VERIFY 3c: gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    v_pid := (select id from public.property_pages where property_id = 1164 and version = v_ver0 + 2);
    begin
      update public.property_pages set approved_at = now(), approved_by = v_other, approved_by_email = 'verify.approver@ayache.com'
       where id = v_pid;
      raise exception 'VERIFY 3d: a raw self-approval went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '23514' or v_detail is distinct from 'blocker=own_version in public.property_pages' then
        raise exception 'VERIFY 3d: gave % / %', v_state, v_detail;
      end if;
    end;

    -- V4. Fred approves someone else's version (a normal approval, no developer label).
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_r := client.approve_property_page(v_pid);
    v_act := client.get_property_activity(1164);
    reset role;
    -- (both test approvals share one transaction timestamp, so the row is picked by version, not position)
    if (select e ->> 'text' from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_approved' and (e ->> 'version')::int = v_ver0 + 2)
       is distinct from 'Version ' || (v_ver0 + 2) || ' of the driver page approved by Fred' then
      raise exception 'VERIFY 4: Fred approving another person''s version reads %',
        (select e ->> 'text' from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_approved' and (e ->> 'version')::int = v_ver0 + 2);
    end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V5. Nothing from the test survived.
  if (select coalesce(max(version), 0) from public.property_pages where property_id = 1164) <> v_ver0
     or (select site_map from public.properties where id = 1164) is distinct from v_map0
     or (select value from public.app_config where key = 'page_approvers') is distinct from v_appr0
     or (select count(*) from public.property_page_opens where property_id = 1164) <> v_opens0 then
    raise exception 'VERIFY 5: test rows survived the rollback';
  end if;
  raise notice 'VERIFY: Fred approves; only Fred self-approves; everyone else still needs a second person';
end $verify$;

notify pgrst, 'reload schema';
