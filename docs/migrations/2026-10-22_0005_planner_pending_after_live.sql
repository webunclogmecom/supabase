-- 2026-10-22_0005_planner_pending_after_live
-- Trello 1Mej1zDX, Fred on the Activity mockup (2026-10-21): *"all that are pending can be waiting for approval, but only
-- the ones that were submitted after an approved version"*. Until now only the NEWEST unapproved version waited (approve and
-- reject refused any other, blocker=not_newest); an older one read "Not approved". Now:
--   - every version that is not approved, not rejected and newer than the live version is WAITING, and can be approved or
--     rejected (approve_property_page and reject_property_page refuse only a version BELOW the live one, blocker=superseded);
--   - a version below the live one was passed over: status superseded, "replaced by" the next APPROVED version;
--   - get_page_builder and page_builder_list: the version the builder edits (pending) is the newest WAITING one;
--   - get_page_versions gives, per version, can_approve, approve_blocker (why this caller cannot approve a waiting version)
--     and can_reject (an approver, own version included: a withdraw), for the Activity buttons.
-- Approving an older waiting version makes it live and copies its map, exactly as before; newer waiting versions keep
-- waiting. Approvals still always move the live version UP (a version below the live one is refused), so the live version
-- stays the highest approved one (fn_driver_page, restore and the statuses rely on that).
-- NOT CHANGED: the append-only trigger, submit (its version_clash check counts every version), fn_driver_page, restore,
-- grants. Rule 8: functions only, no table change.
-- Rollback: 2026-10-22_rollback_planner_pending_after_live.sql (rehearsed).

begin;
set local lock_timeout = '3s';
do $g$ begin
  if md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> '553544cf1ee558689b8ae81bbbc51ece'
     or md5(pg_get_functiondef('client.reject_property_page(bigint,text)'::regprocedure)) <> 'e224c9b9096b2276846481f359ee2cc1'
     or md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> 'f89f1cf2c63cb10fd50051c29747944f'
     or md5(pg_get_functiondef('client.page_builder_list()'::regprocedure)) <> 'd54e282d6657cb9a512eab526566ccab'
     or md5(pg_get_functiondef('client.get_page_versions(bigint)'::regprocedure)) <> '998966c3ee362dfb04cab3daca945bcd' then
    raise exception 'a page function changed since this migration was written, re-read it';
  end if;
end $g$;
-- the readers' answers BEFORE, for VERIFY 8
do $c$
declare v_fred uuid := (select id from auth.users where lower(email) = 'fred@ayache.com');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform set_config('pa.list0', (select ',' || string_agg(property_id || ':' || coalesce(live_version::text, '-') || '/' || coalesce(pending_version::text, '-'), ',' order by property_id) || ','
                                    from client.page_builder_list()), true);
  perform set_config('pa.v162', client.get_page_versions(162)::text, true);
  perform set_config('pa.v1164', client.get_page_versions(1164)::text, true);
  perform set_config('pa.v1208', client.get_page_versions(1208)::text, true);
  perform set_config('pa.pb0', jsonb_build_array(client.get_page_builder(162), client.get_page_builder(1164), client.get_page_builder(1208))::text, true);
  reset role;
end $c$;

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
  v_live  int;
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
  perform hr.fn_check_app('picture_planner', 'edit', 'approve a site file');   -- 2026-10-20_1600 access phase 3
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
  if v_page.rejected_at is not null then
    raise exception 'This version was rejected, so it cannot be approved. Submit a new version.' using errcode = '22023',
      detail = 'blocker=rejected in client.approve_property_page';
  end if;
  -- Any version submitted after the live one is waiting and can be decided, not only the newest (Fred, 2026-10-21: "all
  -- that are pending can be waiting for approval, but only the ones that were submitted after an approved version").
  -- One below the live version was passed over and cannot.
  select max(version) into v_live from public.property_pages where property_id = v_page.property_id and approved_at is not null;
  if v_page.version < coalesce(v_live, 0) then
    raise exception 'A later version of this page is already live, so this one can no longer be approved.' using errcode = '22023',
      detail = 'blocker=superseded in client.approve_property_page';
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
end $function$
;

CREATE OR REPLACE FUNCTION client.reject_property_page(p_page_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21 (Trello 1Mej1zDX, Fred: "Reason required"): the people who can approve a site file can reject its
-- waiting version instead, with a reason. The version stays (append-only) and reads Rejected in Activity; the site
-- file and the property are unchanged; the next draft starts from the live version (or the property record).
-- One's own version may be rejected (a withdraw), so there is no own-version rule here.
declare
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_page   public.property_pages;
  v_live   int;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.reject_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.reject_property_page';
  end if;
  perform hr.fn_check_app('picture_planner', 'edit', 'reject a site file');
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can reject a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.reject_property_page';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'Write why this version is rejected (3 to 500 characters).' using errcode = '22023',
      detail = 'blocker=reason in client.reject_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.reject_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);   -- the same lock as submit and approve
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved, so it cannot be rejected.' using errcode = '22023',
      detail = 'blocker=already_approved in client.reject_property_page';
  end if;
  if v_page.rejected_at is not null then
    raise exception 'This version is already rejected.' using errcode = '22023',
      detail = 'blocker=already_rejected in client.reject_property_page';
  end if;
  -- Any version submitted after the live one is waiting and can be decided, not only the newest (Fred, 2026-10-21: "all
  -- that are pending can be waiting for approval, but only the ones that were submitted after an approved version").
  -- One below the live version was passed over and cannot.
  select max(version) into v_live from public.property_pages where property_id = v_page.property_id and approved_at is not null;
  if v_page.version < coalesce(v_live, 0) then
    raise exception 'A later version of this page is already live, so this one can no longer be rejected.' using errcode = '22023',
      detail = 'blocker=superseded in client.reject_property_page';
  end if;

  update public.property_pages
     set rejected_at = now(), rejected_by = v_uid, rejected_by_email = v_email, reject_reason = v_reason
   where id = p_page_id;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$
;

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
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
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
  -- The builder edits the newest version still waiting: not approved, not rejected, submitted after the live one. Older
  -- waiting versions are decided from Activity (2026-10-21).
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and rejected_at is null and version > coalesce(v_live.version, 0)
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
  -- Every version's photos, not only the live and waiting ones (2026-09-29, Restore): a restored version can hold a
  -- photo that is in neither of them nor in the pool's 12 newest visits, and the builder needs its bucket and path to
  -- show it, or owned=false to leave it out (the validator would refuse it: blocker=content).
  refd as (
    select distinct (ph ->> 'photo_id')::bigint as photo_id
      from public.property_pages pg,
           jsonb_array_elements(case when jsonb_typeof(pg.content -> 'photos') = 'array' then pg.content -> 'photos' else '[]'::jsonb end) ph
     where pg.property_id = p_property_id)
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
end $function$
;

CREATE OR REPLACE FUNCTION client.page_builder_list()
 RETURNS TABLE(property_id bigint, client_id bigint, client_code text, client_name text, property_name text, address text, city text, intake_status text, intake_id bigint, live_version integer, live_approved_at timestamp with time zone, live_approved_by_name text, pending_version integer, pending_submitted_at timestamp with time zone, pending_submitted_by_name text, property_changed_since_live boolean, photos_no_longer_available integer, has_link boolean, link_blocker text, last_opened_at timestamp with time zone, last_open_was_staff boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.page_builder_list';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.page_builder_list';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
  return query
  select pi.property_id,
         pi.client_id,
         c.client_code::text,
         c.name::text,
         nullif(btrim(p.name), '')::text,
         p.address::text,
         p.city::text,
         pi.intake_status::text,
         pi.intake_id,
         lv.version,
         lv.approved_at,
         case when lv.id is null then null else public.fn_page_staff_name(lv.approved_by_email) end,
         pv.version,
         pv.submitted_at,
         case when pv.id is null then null else public.fn_page_staff_name(pv.submitted_by_email) end,
         (lv.id is not null and (lv.source - 'site_map') is distinct from public.fn_page_source(p.id)),
         case when lv.id is null then 0 else (
           select count(*)::int from jsonb_array_elements(lv.content -> 'photos') ph
            where not exists (select 1 from public.fn_page_photo_ids(p.id) o
                               where o.photo_id = (ph ->> 'photo_id')::bigint)) end,
         (l.property_id is not null),
         public.fn_page_blocker(p.id),
         lo.opened_at,
         lo.staff
    from client.v_property_intake pi
    join public.properties p on p.id = pi.property_id
    join public.clients c    on c.id = pi.client_id
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is not null
                        order by x.version desc limit 1) lv on true
    -- the newest version still waiting: not approved, not rejected, submitted after the live one (2026-10-21)
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is null and x.rejected_at is null
                          and x.version > coalesce(lv.version, 0)
                        order by x.version desc limit 1) pv on true
    left join lateral (select o.opened_at, o.staff from public.property_page_opens o
                        where o.property_id = p.id order by o.opened_at desc limit 1) lo on true
    left join public.property_page_links l on l.property_id = p.id
   where nullif(btrim(c.client_code), '') is not null
   order by c.client_code, p.id;
end $function$
;

CREATE OR REPLACE FUNCTION client.get_page_versions(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_appr  boolean;
  v_self  boolean;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_versions';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_versions';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_versions';
  end if;

  -- Who may decide a waiting version (2026-10-21): the same rules as approve_property_page and get_page_builder.
  v_appr := coalesce(v_uid = any (public.fn_page_approver_ids()), false);
  v_self := coalesce(v_uid = any (public.fn_page_self_approver_ids()), false);
  v_block := public.fn_page_blocker(p_property_id);

  -- ponytail: every version's whole content in one reply (about 2 KB each today); page it if a property ever keeps hundreds.
  return coalesce((
    with v as (
      select pg.*,
             max(pg.version) over () as newest,
             max(pg.version) filter (where pg.approved_at is not null) over () as live_version
        from public.property_pages pg
       where pg.property_id = p_property_id)
    select jsonb_agg(jsonb_build_object(
             'page_id', v.id, 'version', v.version, 'status', s.status, 'content', v.content,
             'submitted_at', v.submitted_at, 'submitted_by_name', public.fn_page_staff_name(v.submitted_by_email),
             'approved_at', v.approved_at, 'approved_by_name', public.fn_page_staff_name(v.approved_by_email),
             'self_approved', coalesce(v.approved_by = v.submitted_by, false),
             'rejected_at', v.rejected_at, 'reject_reason', v.reject_reason,
             'rejected_by_name', case when v.rejected_at is not null then public.fn_page_staff_name(v.rejected_by_email) end,
             'replaced_by_version', r.version, 'replaced_at', r.at,
             'can_approve', s.status = 'waiting' and ab.b is null,
             'approve_blocker', case when s.status = 'waiting' then ab.b end,
             'can_reject', s.status = 'waiting' and v_appr,
             'restored_from_version', v.restored_from_version, 'source', v.source)
           order by v.version desc)
      from v
      cross join lateral (select case
               when v.approved_at is not null and v.version = v.live_version then 'live'
               when v.approved_at is not null then 'replaced'
               when v.rejected_at is not null then 'rejected'
               when v.version > coalesce(v.live_version, 0) then 'waiting'   -- every version after the live one (2026-10-21)
               else 'superseded' end as status) s
      -- why this caller cannot approve a waiting version (null: they can); own versions may still be rejected
      cross join lateral (select case
               when not v_appr then 'Only ' || public.fn_page_approver_names() || ' can approve a page.'
               when v.submitted_by = v_uid and not v_self then 'You submitted this version, so another person has to approve it.'
               else v_block end as b) ab
      -- replaced and superseded: the next APPROVED version and when it was approved (a superseded version was passed over
      -- when a later one went live, 2026-10-21)
      left join lateral (
        select n.version, n.approved_at as at
          from public.property_pages n
         where s.status in ('replaced', 'superseded')
           and n.property_id = v.property_id and n.version > v.version
           and n.approved_at is not null
         order by n.version
         limit 1) r on true), '[]'::jsonb);
end $function$
;

-- VERIFY, in the same transaction. Test versions on the [TEST] property 1164 (client 112-YA) inside a block that always
-- ends with a sentinel error, so they roll back. Fred (a developer approver) and one other approver read and decide.
do $v$
declare
  v_fred  uuid := (select id from auth.users where lower(email) = 'fred@ayache.com');
  v_x     uuid;  v_xmail text;
  v_top   public.property_pages;
  v_ids   bigint[] := '{}';  v_id bigint;
  v_r     jsonb;  v_vs jsonb;
  v_state text;  v_detail text;
  v_n0    bigint := (select count(*) from public.property_pages);
  v_list1 text;
  fred_claims text;  x_claims text;
begin
  select u.id, lower(u.email) into v_x, v_xmail from auth.users u
   where u.id = any (public.fn_page_approver_ids()) and u.id <> v_fred and not (u.id = any (public.fn_page_self_approver_ids()))
   order by u.email limit 1;
  if v_x is null then raise exception 'VERIFY 0: no second approver to test with'; end if;
  fred_claims := json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  x_claims := json_build_object('sub', v_x, 'email', v_xmail, 'role', 'authenticated')::text;
  -- V1. Control on the capture (OLD functions): 1208 has two unapproved versions and no live one, its v1 read superseded.
  if current_setting('pa.list0') not like '%,1208:-/2,%' or current_setting('pa.list0') not like '%,1164:5/-,%'
     or current_setting('pa.v1208')::jsonb -> 1 ->> 'status' is distinct from 'superseded' then
    raise exception 'VERIFY 1: the capture reads wrong: %', current_setting('pa.list0');
  end if;

  begin   -- sentinel block
    select * into v_top from public.property_pages where property_id = 1164 order by version desc limit 1;
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 1, v_top.content, v_top.source, v_fred, 'fred@ayache.com'),
             (1164, v_top.version + 2, v_top.content, v_top.source, v_x, v_xmail);
    select array_agg(id order by version) into v_ids from public.property_pages where property_id = 1164 and version > v_top.version;

    -- V2. Both new versions wait; Fred may approve both (developer approval for his own), X only Fred's, both may reject.
    perform set_config('request.jwt.claims', fred_claims, true); set local role authenticated;
    v_vs := client.get_page_versions(1164);
    if v_vs -> 0 ->> 'status' is distinct from 'waiting' or v_vs -> 1 ->> 'status' is distinct from 'waiting' then raise exception 'VERIFY 2a: statuses % %', v_vs -> 0 ->> 'status', v_vs -> 1 ->> 'status'; end if;
    if not ((v_vs -> 0 ->> 'can_approve')::boolean and (v_vs -> 1 ->> 'can_approve')::boolean and (v_vs -> 0 ->> 'can_reject')::boolean) then
      raise exception 'VERIFY 2b: Fred cannot act: %', v_vs -> 0 - 'content' - 'source';
    end if;
    if (v_vs -> 2 ->> 'can_approve')::boolean or (v_vs -> 2 ->> 'can_reject')::boolean or v_vs -> 2 ->> 'approve_blocker' is not null then
      raise exception 'VERIFY 2c: the live version offers a decision';
    end if;
    if (client.get_page_builder(1164) -> 'pending' ->> 'version')::int is distinct from v_top.version + 2
       or (select pending_version from client.page_builder_list() where property_id = 1164) is distinct from v_top.version + 2 then
      raise exception 'VERIFY 2d: the builder or the list does not edit the newest waiting version';
    end if;
    reset role;
    perform set_config('request.jwt.claims', x_claims, true); set local role authenticated;
    v_vs := client.get_page_versions(1164);
    if (v_vs -> 0 ->> 'can_approve')::boolean or v_vs -> 0 ->> 'approve_blocker' <> 'You submitted this version, so another person has to approve it.'
       or not (v_vs -> 0 ->> 'can_reject')::boolean or not (v_vs -> 1 ->> 'can_approve')::boolean then
      raise exception 'VERIFY 2e: the other approver reads %', jsonb_build_object('a0', v_vs -> 0 -> 'can_approve', 'b0', v_vs -> 0 -> 'approve_blocker', 'r0', v_vs -> 0 -> 'can_reject', 'a1', v_vs -> 1 -> 'can_approve');
    end if;
    reset role;

    -- V3. The OLDER waiting version can be approved; the newer keeps waiting.
    perform set_config('request.jwt.claims', fred_claims, true); set local role authenticated;
    v_r := client.approve_property_page(v_ids[1]);
    v_vs := client.get_page_versions(1164);
    if v_vs -> 0 ->> 'status' is distinct from 'waiting' or v_vs -> 1 ->> 'status' is distinct from 'live' or v_vs -> 2 ->> 'status' is distinct from 'replaced' or (v_vs -> 2 ->> 'replaced_by_version')::int is distinct from v_top.version + 1 then
      raise exception 'VERIFY 3a: after approving the older one: % % %', v_vs -> 0 ->> 'status', v_vs -> 1 ->> 'status', v_vs -> 2 ->> 'status';
    end if;
    if (client.get_page_builder(1164) -> 'live' ->> 'version')::int is distinct from v_top.version + 1 or (client.get_page_builder(1164) -> 'pending' ->> 'version')::int is distinct from v_top.version + 2 then
      raise exception 'VERIFY 3b: builder live/pending wrong';
    end if;
    -- V4. Reject the remaining waiting one: nothing waits.
    perform client.reject_property_page(v_ids[2], 'Verify: not needed');
    if client.get_page_builder(1164) -> 'pending' <> 'null'::jsonb or (select pending_version from client.page_builder_list() where property_id = 1164) is not null then
      raise exception 'VERIFY 4: something still waits after the reject';
    end if;
    reset role;

    -- V5. Two more; approving the NEWER passes the older over: superseded, replaced by the approved one, refused both ways.
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 3, v_top.content, v_top.source, v_fred, 'fred@ayache.com'),
             (1164, v_top.version + 4, v_top.content, v_top.source, v_fred, 'fred@ayache.com');
    select array_agg(id order by version) into v_ids from public.property_pages where property_id = 1164 and version > v_top.version;
    perform set_config('request.jwt.claims', fred_claims, true); set local role authenticated;
    v_r := client.approve_property_page(v_ids[4]);
    v_vs := client.get_page_versions(1164);
    if v_vs -> 1 ->> 'status' is distinct from 'superseded' or (v_vs -> 1 ->> 'replaced_by_version')::int is distinct from v_top.version + 4 or (v_vs -> 1 ->> 'can_approve')::boolean or (v_vs -> 1 ->> 'can_reject')::boolean then
      raise exception 'VERIFY 5a: the passed-over version reads %', v_vs -> 1 - 'content' - 'source';
    end if;
    begin
      perform client.approve_property_page(v_ids[3]);
      raise exception 'VERIFY 5b: a passed-over version was approved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=superseded in client.approve_property_page' then raise exception 'VERIFY 5b: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.reject_property_page(v_ids[3], 'Too late');
      raise exception 'VERIFY 5c: a passed-over version was rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=superseded in client.reject_property_page' then raise exception 'VERIFY 5c: gave % / %', v_state, v_detail; end if;
    end;
    -- the rejected version keeps reading rejected after a later approval
    if v_vs -> 2 ->> 'status' is distinct from 'rejected' then raise exception 'VERIFY 5d: the rejected version reads %', v_vs -> 2 ->> 'status'; end if;
    reset role;

    -- V6. With an older version waiting, rejecting the newest leaves the older one as the builder's waiting version.
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 5, v_top.content, v_top.source, v_fred, 'fred@ayache.com'),
             (1164, v_top.version + 6, v_top.content, v_top.source, v_fred, 'fred@ayache.com');
    select id into v_id from public.property_pages where property_id = 1164 and version = v_top.version + 6;
    perform set_config('request.jwt.claims', fred_claims, true); set local role authenticated;
    perform client.reject_property_page(v_id, 'Verify: older one waits');
    if (client.get_page_builder(1164) -> 'pending' ->> 'version')::int is distinct from v_top.version + 5
       or (select pending_version from client.page_builder_list() where property_id = 1164) is distinct from v_top.version + 5 then
      raise exception 'VERIFY 6: the older waiting version is not the one waiting';
    end if;
    reset role;
    raise exception 'sentinel' using errcode = 'P0004';
  exception when sqlstate 'P0004' then
    null;
  end;

  reset role;
  if (select count(*) from public.property_pages) <> v_n0 or exists (select 1 from public.property_pages where rejected_at is not null) then
    raise exception 'VERIFY 7: a test version survived';
  end if;
  -- V8. Everything else reads as before: the list and the builder byte for byte; the versions too once the three new keys
  -- are left out, except 1208's version 1, which now waits (that is the change).
  perform set_config('request.jwt.claims', fred_claims, true); set local role authenticated;
  select ',' || string_agg(property_id || ':' || coalesce(live_version::text, '-') || '/' || coalesce(pending_version::text, '-'), ',' order by property_id) || ','
    into v_list1 from client.page_builder_list();
  if v_list1 <> current_setting('pa.list0') then reset role; raise exception 'VERIFY 8a: page_builder_list changed'; end if;
  if jsonb_build_array(client.get_page_builder(162), client.get_page_builder(1164), client.get_page_builder(1208))::text <> current_setting('pa.pb0') then
    reset role; raise exception 'VERIFY 8b: get_page_builder changed';
  end if;
  if (select jsonb_agg(e - 'can_approve' - 'approve_blocker' - 'can_reject' order by o) from jsonb_array_elements(client.get_page_versions(162)) with ordinality t(e, o)) <> current_setting('pa.v162')::jsonb
     or (select jsonb_agg(e - 'can_approve' - 'approve_blocker' - 'can_reject' order by o) from jsonb_array_elements(client.get_page_versions(1164)) with ordinality t(e, o)) <> current_setting('pa.v1164')::jsonb then
    reset role; raise exception 'VERIFY 8c: get_page_versions changed for 162 or 1164';
  end if;
  v_vs := (select jsonb_agg(e - 'can_approve' - 'approve_blocker' - 'can_reject' order by o) from jsonb_array_elements(client.get_page_versions(1208)) with ordinality t(e, o));
  reset role;
  if v_vs -> 0 <> current_setting('pa.v1208')::jsonb -> 0
     or v_vs -> 1 <> jsonb_set(jsonb_set(jsonb_set(current_setting('pa.v1208')::jsonb -> 1, '{status}', '"waiting"'), '{replaced_by_version}', 'null'), '{replaced_at}', 'null') then
    raise exception 'VERIFY 8d: 1208 reads % / %', v_vs -> 1 ->> 'status', v_vs -> 1 ->> 'replaced_by_version';
  end if;
  raise notice 'VERIFY ok';
end $v$;
commit;
