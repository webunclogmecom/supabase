-- 2026-10-21_2030_planner_reject_version
-- Trello 1Mej1zDX "Picture Planner: intake map tweaks, reject button, version history fixes, counts bar polish".
-- Serena and Aaron (#new-app-issues): a waiting version could only be approved, never sent back. Fred, 2026-10-21:
-- Reject = "Reason required (Recommended)": the same people who can approve; a reason is required; the version shows
-- "Rejected" with the reason and who, in Activity; the site file is unchanged; the next draft starts from the last
-- approved version (or the property record). Plan: Building Apps/Picture Planner/docs/specs/2026-10-21-cards-130-131-plan.md.
--
-- WHAT:
--   public.property_pages gains rejected_at, rejected_by, rejected_by_email, reject_reason, with three CHECKs
--     (who and when together; never approved AND rejected; a reason of 3 to 500 characters exactly when rejected).
--   public.fn_property_pages_append_only allows ONE more UPDATE: recording a rejection once, on a version that is
--     neither approved nor rejected, nothing else changing. An INSERT may not arrive rejected; a rejected version
--     can never be approved. Delete and every other change stay refused.
--   NEW client.reject_property_page(p_page_id, p_reason): staff sign-in, Picture Planner Edit, a page approver
--     (fn_page_approver_ids, the HR App's "Approve site files"), the newest version only, not approved, not already
--     rejected, reason trimmed 3 to 500 characters; the same advisory lock as submit and approve. Own version allowed.
--   client.approve_property_page refuses a rejected version (blocker=rejected).
--   client.get_page_builder: the waiting version is the NEWEST one when neither approved nor rejected (was the newest
--     unapproved one above the live one: the same rows today, but after a rejection it would have offered an older
--     superseded version that approve refuses).
--   client.page_builder_list: the same rule for pending_version.
--   client.get_page_versions: status 'rejected' (before 'waiting' / 'superseded'), plus rejected_at,
--     rejected_by_name, reject_reason on every version (null when not rejected).
--   client.get_property_activity: one event per rejection, kind page_rejected, "Version N of the site file rejected
--     by <name>: <reason>" (the Client App's Activity reads it too).
-- NOT CHANGED: submit_property_page (its version_clash check counts a rejected version, so the next submit is N+1),
--   fn_driver_page (approved versions only), restore (approved versions only), every grant except the new function's.
-- Rule 8: property_pages is audited (audit_property_pages), so each rejection leaves an audit row.
-- Lock: ALTER TABLE on a 10-row table; lock_timeout 3s.
-- Rollback: 2026-10-21_rollback_planner_reject_version.sql (rehearsed; refuses if any version was rejected).

begin;
set local lock_timeout = '3s';
do $g$ begin
  if md5(pg_get_functiondef('public.fn_property_pages_append_only()'::regprocedure)) <> '668fb9e3ef3fa8857d102946251833e7'
     or md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> '5bdde4d4082cab515c8cef8ab106ed40'
     or md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '3cce03663dbfa855cd65709503a1d889'
     or md5(pg_get_functiondef('client.page_builder_list()'::regprocedure)) <> '43ad8f76f132d5771d6c3a4648124198'
     or md5(pg_get_functiondef('client.get_page_versions(bigint)'::regprocedure)) <> '3c704ef2109198b5711d2e71f4ddbd83'
     or md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> '04ba9cc37223152f8861e0b39b0e556e' then
    raise exception 'a page function changed since this migration was written, re-read it';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'client' and p.proname = 'reject_property_page') then
    raise exception 'client.reject_property_page already exists';
  end if;
end $g$;
select set_config('rej.rows', (select md5(string_agg(to_jsonb(pg)::text, '|' order by pg.id)) from public.property_pages pg), true);
select set_config('rej.others', (select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p
  where p.oid in ('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure, 'public.fn_driver_page(text,boolean,text)'::regprocedure,
                  'public.fn_property_pages_no_truncate()'::regprocedure)), true);
-- What the readers answer BEFORE (old functions, as Fred), compared in VERIFY 8.
do $c$
declare v_fred uuid := (select id from auth.users where lower(email) = 'fred@ayache.com');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform set_config('rej.list0', (select ',' || string_agg(property_id || ':' || coalesce(live_version::text, '-') || '/' || coalesce(pending_version::text, '-'), ',' order by property_id) || ','
                                     from client.page_builder_list()), true);
  perform set_config('rej.vers0', client.get_page_versions(162)::text || '|' || client.get_page_versions(1164)::text || '|' || client.get_page_versions(1208)::text, true);
  perform set_config('rej.pb0', jsonb_build_array(client.get_page_builder(162), client.get_page_builder(1164), client.get_page_builder(1208))::text, true);
  reset role;
end $c$;

alter table public.property_pages
  add column rejected_at timestamptz,
  add column rejected_by uuid,
  add column rejected_by_email text,
  add column reject_reason text,
  add constraint property_pages_rejected_who_check
    check ((rejected_at is null) = (rejected_by is null) and (rejected_at is null) = (rejected_by_email is null)),
  add constraint property_pages_not_approved_and_rejected check (approved_at is null or rejected_at is null),
  add constraint property_pages_reject_reason_check
    check (case when rejected_at is null then reject_reason is null
                else coalesce(char_length(reject_reason) between 3 and 500, false) end);
comment on column public.property_pages.rejected_at is 'When a page approver rejected this waiting version (client.reject_property_page, 2026-10-21). Set once; a rejected version is never approved.';
comment on column public.property_pages.reject_reason is 'Why it was rejected, as the approver wrote it (trimmed, 3 to 500 characters). Shown in the Picture Planner Activity.';

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
    if new.approved_at is not null or new.approved_by is not null or new.approved_by_email is not null
       or new.rejected_at is not null or new.rejected_by is not null or new.rejected_by_email is not null
       or new.reject_reason is not null then
      raise exception 'A page version is approved or rejected after it is submitted, never while it is written.'
        using errcode = '55000', detail = 'blocker=append_only in public.property_pages';
    end if;
    return new;
  end if;
  -- A rejection (2026-10-21, Trello 1Mej1zDX; Fred: "Reason required"): recorded once, on a version that is neither
  -- approved nor rejected, and nothing else changes. One's own version may be rejected (a withdraw), so the
  -- own-version rule below is for approvals only.
  if old.approved_at is null and old.rejected_at is null
     and new.approved_at is null and new.rejected_at is not null
     and (pg_catalog.to_jsonb(new) - 'rejected_at' - 'rejected_by' - 'rejected_by_email' - 'reject_reason')
         is not distinct from
         (pg_catalog.to_jsonb(old) - 'rejected_at' - 'rejected_by' - 'rejected_by_email' - 'reject_reason') then
    return new;
  end if;
  if old.approved_at is not null
     or old.rejected_at is not null
     or new.approved_at is null
     or (pg_catalog.to_jsonb(new) - 'approved_at' - 'approved_by' - 'approved_by_email')
        is distinct from
        (pg_catalog.to_jsonb(old) - 'approved_at' - 'approved_by' - 'approved_by_email') then
    raise exception 'A page version cannot be changed after it is submitted; only its approval or its rejection can be recorded, once.'
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
end $function$
;

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
  -- Only the NEWEST version can wait (approve takes the newest only), and a rejected one waits for nothing (2026-10-21).
  select * into v_pend from public.property_pages
   where property_id = p_property_id and version = v_newest and approved_at is null and rejected_at is null;

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
    -- the newest version, while it is neither approved nor rejected (2026-10-21)
    left join lateral (select x.* from (select y.* from public.property_pages y
                                         where y.property_id = p.id order by y.version desc limit 1) x
                        where x.approved_at is null and x.rejected_at is null) pv on true
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
             'restored_from_version', v.restored_from_version, 'source', v.source)
           order by v.version desc)
      from v
      cross join lateral (select case
               when v.approved_at is not null and v.version = v.live_version then 'live'
               when v.approved_at is not null then 'replaced'
               when v.rejected_at is not null then 'rejected'
               when v.version = v.newest then 'waiting'
               else 'superseded' end as status) s
      -- replaced: the next APPROVED version and when it was approved; superseded: the next version and when it was submitted
      left join lateral (
        select n.version, case when v.approved_at is not null then n.approved_at else n.submitted_at end as at
          from public.property_pages n
         where s.status in ('replaced', 'superseded')
           and n.property_id = v.property_id and n.version > v.version
           and (v.approved_at is null or n.approved_at is not null)
         order by n.version
         limit 1) r on true), '[]'::jsonb);
end $function$
;

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
  perform hr.fn_require_any_app(array['picture_planner', 'client_app'], 'view');   -- 2026-10-21_0930 (D6): the Client App Activity reads it too
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
               public.fn_page_staff_name(pg.submitted_by_email),
               -- a restore names its origin after the name (2026-09-29); null otherwise
               ' (restored from version ' || pg.restored_from_version || ')', null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the site file approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        -- A rejection names its reason after the name (2026-10-21, Trello 1Mej1zDX).
        select pg.rejected_at, 6, 'page_rejected', null, pg.version,
               'Version ' || pg.version || ' of the site file rejected',
               public.fn_page_staff_name(pg.rejected_by_email), ': ' || pg.reject_reason, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.rejected_at is not null
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
  v_newest int;
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
  select max(version) into v_newest from public.property_pages where property_id = v_page.property_id;
  if v_page.version <> v_newest then
    raise exception 'A newer version of this page was submitted. Reload the Page Builder.' using errcode = '22023',
      detail = 'blocker=not_newest in client.reject_property_page';
  end if;

  update public.property_pages
     set rejected_at = now(), rejected_by = v_uid, rejected_by_email = v_email, reject_reason = v_reason
   where id = p_page_id;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$;

revoke all on function client.reject_property_page(bigint, text) from public, anon, authenticated, service_role;
grant execute on function client.reject_property_page(bigint, text) to authenticated;

-- VERIFY, in the same transaction. The test versions are written on the [TEST] property 1164 (client 112-YA) inside
-- a block that always ends with a sentinel error, so they roll back. Fred's login plays the approver.
do $v$
declare
  v_fred   uuid := (select id from auth.users where lower(email) = 'fred@ayache.com');
  v_top    public.property_pages;
  v_id1    bigint; v_id2 bigint; v_id3 bigint;
  v_r      jsonb;
  v_state  text; v_detail text;
  v_list0  text; v_list1 text; v_vers0 text; v_vers1 text;
  v_n0     bigint := (select count(*) from public.property_pages);
begin
  -- V0. Grants: the new function is for signed-in staff only, like approve.
  if (select proacl::text from pg_proc where oid = 'client.reject_property_page(bigint,text)'::regprocedure)
     is distinct from (select proacl::text from pg_proc where oid = 'client.approve_property_page(bigint)'::regprocedure) then
    raise exception 'VERIFY 0: reject grants differ from approve''s';
  end if;
  if has_function_privilege('anon', 'client.reject_property_page(bigint,text)', 'execute') then
    raise exception 'VERIFY 0b: anon can reject';
  end if;
  if current_setting('rej.rows') <> (select md5(string_agg((to_jsonb(pg) - 'rejected_at' - 'rejected_by' - 'rejected_by_email' - 'reject_reason')::text, '|' order by pg.id)) from public.property_pages pg) then
    raise exception 'VERIFY 0c: a page version row changed';
  end if;

  begin   -- sentinel block: everything inside rolls back
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    -- V1. Control on the capture: 162 and 1208 have a version waiting, 1164 none (read with the OLD functions).
    v_list0 := current_setting('rej.list0');
    if v_list0 not like '%,162:2/3,%' or v_list0 not like '%,1208:-/2,%' or v_list0 not like '%,1164:5/-,%' then
      raise exception 'VERIFY 1: waiting versions read wrong before the migration: %', v_list0;
    end if;

    select * into v_top from public.property_pages where property_id = 1164 order by version desc limit 1;
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 1, v_top.content, v_top.source, v_fred, 'fred@ayache.com') returning id into v_id1;

    set local role authenticated;
    -- V2. Control: the new version waits.
    v_r := client.get_page_builder(1164);
    if (v_r -> 'pending' ->> 'page_id')::bigint is distinct from v_id1 then raise exception 'VERIFY 2a: pending is %', v_r -> 'pending' ->> 'page_id'; end if;
    if (select pending_version from client.page_builder_list() where property_id = 1164) is distinct from v_top.version + 1 then
      raise exception 'VERIFY 2b: the list does not show the version waiting';
    end if;
    if client.get_page_versions(1164) -> 0 ->> 'status' <> 'waiting' then raise exception 'VERIFY 2c: status is not waiting'; end if;

    -- V3. Refusals before any write.
    begin
      perform client.reject_property_page(v_id1, '  a ');
      raise exception 'VERIFY 3a: a 1-character reason was taken' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=reason in client.reject_property_page' then raise exception 'VERIFY 3a: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.reject_property_page(v_id1, repeat('x', 501));
      raise exception 'VERIFY 3b: a 501-character reason was taken' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=reason in client.reject_property_page' then raise exception 'VERIFY 3b: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.reject_property_page(v_top.id, 'Photos are blurry');
      raise exception 'VERIFY 3c: an approved version was rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=already_approved in client.reject_property_page' then raise exception 'VERIFY 3c: gave % / %', v_state, v_detail; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'verify.someone@unclogme.com', 'role', 'authenticated')::text, true);
    begin
      perform client.reject_property_page(v_id1, 'Photos are blurry');
      raise exception 'VERIFY 3d: a login with no access rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' then raise exception 'VERIFY 3d: gave % / %', v_state, v_detail; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'verify.outsider@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.reject_property_page(v_id1, 'Photos are blurry');
      raise exception 'VERIFY 3e: a non-staff login rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=not_staff in client.reject_property_page' then raise exception 'VERIFY 3e: gave % / %', v_state, v_detail; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    reset role;
    if exists (select 1 from public.property_pages where rejected_at is not null) then raise exception 'VERIFY 3f: a refusal wrote a rejection'; end if;

    -- V4. Fred rejects his own waiting version (a withdraw is allowed).
    set local role authenticated;
    v_r := client.reject_property_page(v_id1, '  Photos are blurry  ');
    if (v_r ->> 'version')::int <> v_top.version + 1 then raise exception 'VERIFY 4a: reply %', v_r; end if;
    reset role;
    if (select row(rejected_by, rejected_by_email, reject_reason, approved_at is null)::text from public.property_pages where id = v_id1)
       is distinct from row(v_fred, 'fred@ayache.com', 'Photos are blurry', true)::text then
      raise exception 'VERIFY 4b: the row reads wrong';
    end if;
    if (select count(*) from audit.logs where table_name = 'property_pages' and record_pk ->> 'id' = v_id1::text and operation = 'UPDATE') < 1 then
      raise exception 'VERIFY 4c: no audit row for the rejection';
    end if;

    -- V5. Nothing waits any more; the version reads Rejected with who and why; Activity names it.
    set local role authenticated;
    v_r := client.get_page_builder(1164);
    if v_r -> 'pending' <> 'null'::jsonb then raise exception 'VERIFY 5a: still pending: %', v_r -> 'pending' ->> 'version'; end if;
    if (v_r ->> 'newest_version')::int <> v_top.version + 1 or (v_r -> 'live' ->> 'version')::int <> v_top.version
       or (v_r ->> 'can_approve')::boolean then
      raise exception 'VERIFY 5b: newest %, live %, can_approve %', v_r ->> 'newest_version', v_r -> 'live' ->> 'version', v_r ->> 'can_approve';
    end if;
    if (select pending_version from client.page_builder_list() where property_id = 1164) is not null then
      raise exception 'VERIFY 5c: the list still shows a version waiting';
    end if;
    v_r := client.get_page_versions(1164) -> 0;
    if v_r ->> 'status' <> 'rejected' or v_r ->> 'reject_reason' <> 'Photos are blurry' or v_r ->> 'rejected_by_name' is null
       or v_r ->> 'rejected_at' is null then
      raise exception 'VERIFY 5d: version reads status % reason %', v_r ->> 'status', v_r ->> 'reject_reason';
    end if;
    if (client.get_page_versions(1164) -> 1 ->> 'status') <> 'live' or (client.get_page_versions(1164) -> 1 ->> 'rejected_by_name') is not null then
      raise exception 'VERIFY 5e: the live version reads wrong';
    end if;
    if not exists (select 1 from jsonb_array_elements(client.get_property_activity(1164)) e
                    where e ->> 'kind' = 'page_rejected' and (e ->> 'version')::int = v_top.version + 1
                      and e ->> 'text' like 'Version % of the site file rejected by %: Photos are blurry') then
      raise exception 'VERIFY 5f: Activity has no rejection';
    end if;

    -- V6. A rejected version can never be approved, nor rejected again.
    begin
      perform client.approve_property_page(v_id1);
      raise exception 'VERIFY 6a: a rejected version was approved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=rejected in client.approve_property_page' then raise exception 'VERIFY 6a: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.reject_property_page(v_id1, 'Again');
      raise exception 'VERIFY 6b: rejected twice' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=already_rejected in client.reject_property_page' then raise exception 'VERIFY 6b: gave % / %', v_state, v_detail; end if;
    end;
    reset role;
    -- the table itself refuses it too (a raw write cannot skip the function)
    begin
      update public.property_pages set approved_at = now(), approved_by = v_fred, approved_by_email = 'fred@ayache.com' where id = v_id1;
      raise exception 'VERIFY 6c: a raw approval of a rejected version went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state not in ('55000', '23514') then raise exception 'VERIFY 6c: gave %', v_state; end if;
    end;
    begin
      update public.property_pages set reject_reason = 'Changed my mind' where id = v_id1;
      raise exception 'VERIFY 6d: a reason was changed' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '55000' then raise exception 'VERIFY 6d: gave %', v_state; end if;
    end;
    begin
      update public.property_pages set rejected_at = now(), rejected_by = v_fred, rejected_by_email = 'x', reject_reason = 'Too late', content = '{"photos":[]}' where id = v_top.id;
      raise exception 'VERIFY 6e: an approved version was changed' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state not in ('55000', '23514') then raise exception 'VERIFY 6e: gave %', v_state; end if;
    end;
    begin
      insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, rejected_at, rejected_by, rejected_by_email, reject_reason)
        values (1164, v_top.version + 9, v_top.content, v_top.source, v_fred, 'fred@ayache.com', now(), v_fred, 'fred@ayache.com', 'Born rejected');
      raise exception 'VERIFY 6f: a version arrived rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '55000' then raise exception 'VERIFY 6f: gave %', v_state; end if;
    end;

    -- V7. The next version waits again; an older one cannot be rejected; approve still works.
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 2, v_top.content, v_top.source, v_fred, 'fred@ayache.com') returning id into v_id2;
    insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, v_top.version + 3, v_top.content, v_top.source, v_fred, 'fred@ayache.com') returning id into v_id3;
    set local role authenticated;
    if (client.get_page_builder(1164) -> 'pending' ->> 'page_id')::bigint is distinct from v_id3 then raise exception 'VERIFY 7a: the newest does not wait'; end if;
    if client.get_page_versions(1164) -> 1 ->> 'status' <> 'superseded' or client.get_page_versions(1164) -> 2 ->> 'status' <> 'rejected' then
      raise exception 'VERIFY 7b: statuses read %, %', client.get_page_versions(1164) -> 1 ->> 'status', client.get_page_versions(1164) -> 2 ->> 'status';
    end if;
    begin
      perform client.reject_property_page(v_id2, 'Old one');
      raise exception 'VERIFY 7c: an older version was rejected' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=not_newest in client.reject_property_page' then raise exception 'VERIFY 7c: gave % / %', v_state, v_detail; end if;
    end;
    v_r := client.approve_property_page(v_id3);
    if (v_r ->> 'version')::int <> v_top.version + 3 then raise exception 'VERIFY 7d: approve replied %', v_r; end if;
    if client.get_page_versions(1164) -> 0 ->> 'status' <> 'live' or client.get_page_versions(1164) -> 2 ->> 'status' <> 'rejected' then
      raise exception 'VERIFY 7e: after approval the statuses read wrong';
    end if;
    reset role;
    raise exception 'sentinel' using errcode = 'P0004';
  exception when sqlstate 'P0004' then
    null;   -- the test versions are gone
  end;

  reset role;
  if (select count(*) from public.property_pages) <> v_n0 or exists (select 1 from public.property_pages where rejected_at is not null) then
    raise exception 'VERIFY 9: a test version survived';
  end if;
  -- V8. With no rejection anywhere, every reader answers exactly as the old functions did (3 new null keys aside).
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  set local role authenticated;
  select ',' || string_agg(property_id || ':' || coalesce(live_version::text, '-') || '/' || coalesce(pending_version::text, '-'), ',' order by property_id) || ','
    into v_list1 from client.page_builder_list();
  v_vers1 := client.get_page_versions(162)::text || '|' || client.get_page_versions(1164)::text || '|' || client.get_page_versions(1208)::text;
  v_r := jsonb_build_array(client.get_page_builder(162), client.get_page_builder(1164), client.get_page_builder(1208));
  reset role;
  if v_list1 <> current_setting('rej.list0') then raise exception 'VERIFY 8a: page_builder_list changed'; end if;
  if regexp_replace(v_vers1, ', "reject_reason": null|, "rejected_at": null|, "rejected_by_name": null', '', 'g') <> current_setting('rej.vers0') then
    raise exception 'VERIFY 8b: get_page_versions reads differently beyond the three new null keys';
  end if;
  if v_r::text <> current_setting('rej.pb0') then raise exception 'VERIFY 8c: get_page_builder reads differently'; end if;
  if current_setting('rej.others') <> (select string_agg(md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p
       where p.oid in ('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure, 'public.fn_driver_page(text,boolean,text)'::regprocedure,
                       'public.fn_property_pages_no_truncate()'::regprocedure)) then
    raise exception 'VERIFY 10: submit, fn_driver_page or no_truncate changed';
  end if;
  raise notice 'VERIFY ok';
end $v$;
commit;
