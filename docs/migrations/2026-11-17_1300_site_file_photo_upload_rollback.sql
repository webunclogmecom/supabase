-- =============================================================================
-- 2026-11-17_1300_site_file_photo_upload_rollback
-- Undoes 2026-11-17_1300_site_file_photo_upload.sql: the three old bodies verbatim (md5-checked after), the old CHECK, and drops the new storage rule,
-- client.add_site_photo and client.fn_site_photo_path_ok. 🛑 Refuses while any photo is linked to a location
-- (entity_type 'property'): those photos and any version holding them would be orphaned. Decide them first.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $refuse$
BEGIN
  IF EXISTS (SELECT 1 FROM public.photo_links WHERE entity_type = 'property') THEN
    RAISE EXCEPTION 'rollback refused: photos are linked to a location (entity_type property); decide them first';
  END IF;
END $refuse$;

DROP POLICY site_photos_staff_insert ON storage.objects;
DROP FUNCTION client.add_site_photo(bigint, text, integer, integer);
DROP FUNCTION client.fn_site_photo_path_ok(text);

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
  if not public.fn_is_staff_email(v_email) then
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_page_photo_ids(p_property_id bigint)
 RETURNS TABLE(photo_id bigint, kind text, bucket text, path text, entity_id bigint, visit_date date, question_key text, caption text, rotation_deg smallint, content_type text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select distinct on (x.photo_id) x.*
    from (
      select p.id, 'visit'::text, 'GT - Visits Images'::text, p.storage_path, v.id, v.visit_date,
             null::text, pl.caption, p.rotation_deg, p.content_type
        from public.photo_links pl
        join public.photos p on p.id = pl.photo_id
        join public.visits v on v.id = pl.entity_id
       where pl.entity_type = 'visit' and pl.deleted_at is null
         and v.deleted_at is null and v.property_id = p_property_id
         and p.content_type like 'image/%'
      union all
      select p.id, 'intake'::text, 'intake-photos'::text, substr(p.storage_path, 15), i.id, null::date,
             pl.role, nullif(btrim(pl.caption), ''), p.rotation_deg, p.content_type
        from public.photo_links pl
        join public.photos p on p.id = pl.photo_id
        join public.property_intakes i on i.id = pl.entity_id
       where pl.entity_type = 'property_intake' and pl.deleted_at is null
         and i.property_id = p_property_id
         and i.submitted_at is not null and i.cancelled_at is null
         and p.storage_path ~ ('^intake-photos/' || i.id::text || '/[0-9a-f-]{36}[.][a-z0-9]{2,5}$')
         and p.content_type like 'image/%'
    ) x (photo_id, kind, bucket, path, entity_id, visit_date, question_key, caption, rotation_deg, content_type)
   where exists (select 1 from storage.objects so where so.bucket_id = x.bucket and so.name = x.path)
   order by x.photo_id, x.visit_date desc nulls last, x.kind desc, x.entity_id desc
$function$;

CREATE OR REPLACE FUNCTION public.fn_photo_link_target_exists()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.entity_type = 'visit' then
    if not exists (select 1 from public.visits v
                    where v.id = new.entity_id and v.deleted_at is null) then
      raise exception 'photo_links: visit % does not exist or is soft-deleted', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'job_frequency_change' then
    -- added 2026-08-19. Same class the visit branch closes: a link must not point at a
    -- record that does not exist. Three job_frequency_changes rows have already been deleted.
    if not exists (select 1 from public.job_frequency_changes f
                    where f.id = new.entity_id) then
      raise exception 'photo_links: job_frequency_change % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'client_status_change' then
    -- added 2026-09-16, same class.
    if not exists (select 1 from public.client_status_changes s
                    where s.id = new.entity_id) then
      raise exception 'photo_links: client_status_change % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'property_intake' then
    -- added 2026-09-22, same class. The intake row is the target; the property is
    -- reached through it, which is why there is no 'property' branch here either.
    if not exists (select 1 from public.property_intakes i
                    where i.id = new.entity_id) then
      raise exception 'photo_links: property_intake % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  end if;
  return new;
end
$function$;

ALTER TABLE public.photo_links DROP CONSTRAINT photo_links_entity_type_chk;
ALTER TABLE public.photo_links ADD CONSTRAINT photo_links_entity_type_chk CHECK ((entity_type = ANY (ARRAY['client_status_change'::text, 'derm_manifest'::text, 'inspection'::text, 'job_frequency_change'::text, 'note'::text, 'property_intake'::text, 'visit'::text])));

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.fn_photo_link_target_exists()'::regprocedure)) IS DISTINCT FROM 'b5eea86c45919cec9a0c2364ed24313e' THEN
    RAISE EXCEPTION 'public.fn_photo_link_target_exists() changed since this file was written: splice again';
  END IF;
  IF md5(pg_get_functiondef('public.fn_page_photo_ids(bigint)'::regprocedure)) IS DISTINCT FROM '309e0612230e7ba98075f7a4bbe93231' THEN
    RAISE EXCEPTION 'public.fn_page_photo_ids(bigint) changed since this file was written: splice again';
  END IF;
  IF md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) IS DISTINCT FROM '886c391e5e710a5a2d4ae2cd26881f0a' THEN
    RAISE EXCEPTION 'client.get_page_builder(bigint) changed since this file was written: splice again';
  END IF;
END $verify$;

COMMIT;
