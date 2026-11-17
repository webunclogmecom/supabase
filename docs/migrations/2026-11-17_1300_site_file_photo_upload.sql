-- =============================================================================
-- 2026-11-17_1300_site_file_photo_upload
--
-- WHAT: a staff person can upload a photo into a location's Site file builder (Trello #219, VinArggt).
--   1. public.photo_links may link a photo straight to a location (entity_type 'property'); the target trigger checks the
--      location is live and serviced (BEFORE INSERT only, as before).
--   2. public.fn_page_photo_ids, the ONE rule for which photos belong to a location (client.get_page_builder, Submit's
--      check client.submit_property_page / fn_page_content_problem, page_builder_list and the driver page fn_driver_page
--      all read it), gains a third arm: kind 'upload', bucket intake-photos, path site/<property id>/<uuid>.jpg|png.
--   3. client.get_page_builder lists uploads in the pool (never cut to the 12 newest visits) with uploaded_at and
--      uploaded_by_name (the builder's orange "Uploaded by ..." line). Other photos' JSON is unchanged.
--   4. NEW client.fn_site_photo_path_ok (the storage rule) + policy site_photos_staff_insert on storage.objects: a staff
--      person with Picture Planner Edit may add a new object at site/<live serviced property id>/<uuid>.jpg|png in the
--      PRIVATE bucket intake-photos. No update or delete rule: Remove takes a photo off the draft, the file is kept.
--   5. NEW client.add_site_photo(property, path, width, height): records the uploaded object as public.photos (source
--      'site_file_upload', uploaded_by_employee_id from hr.fn_access_caller) + a photo_links row (role 'site_photo',
--      caption = the uploader's email, the author convention of client.attach_reason_photo). Idempotent per file.
--   Three anchored edits on md5-pinned live bodies; nothing else in them moved (proved in the rehearsal: for every
--   location with a Site file, the old and new bodies return the same, and the old bodies fail the upload cases).
--
-- WHY: huddle with Serena, 2026-11-17. Serena: "I can drag the picture here, but I cannot upload, right?" Fred: "So I need
--   to add a function to add pictures manually." Mockups mockups/2026-11-17-intake-photos.html (local); Fred's picks the same
--   day: "go with U3, yes to P2 and P3, all defaults". P2: an uploaded photo reaches drivers only with the next approved
--   version, which this keeps by construction (the driver page shows only an approved version's photos).
--   Defaults: stored privately like the form's photos (so the existing intake-photos signing in the builder, the portal's
--   builder and driver-page shows them with no change); turned upright in the browser before they are stored.
--
-- 🛑 Never widen site_photos_staff_insert to another folder, and never add an UPDATE or DELETE rule for site/: a version
--   that drivers see points at these files.
-- RULE 8, AUDIT: public.photo_links is audited (audit_photo_links), so every upload's link is in audit.logs.
--   public.photos is not audited (unchanged; its rows are written once).
-- ROLLBACK: 2026-11-17_1300_site_file_photo_upload_rollback.sql (refuses while any photo is linked to a location).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
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
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'photo_links_entity_type_chk') <> $c$CHECK ((entity_type = ANY (ARRAY['client_status_change'::text, 'derm_manifest'::text, 'inspection'::text, 'job_frequency_change'::text, 'note'::text, 'property_intake'::text, 'visit'::text])))$c$ THEN
    RAISE EXCEPTION 'photo_links_entity_type_chk changed since this file was written';
  END IF;
END $guard$;

-- 1. a photo may link straight to a location
ALTER TABLE public.photo_links DROP CONSTRAINT photo_links_entity_type_chk;
ALTER TABLE public.photo_links ADD CONSTRAINT photo_links_entity_type_chk CHECK ((entity_type = ANY (ARRAY['client_status_change'::text, 'derm_manifest'::text, 'inspection'::text, 'job_frequency_change'::text, 'note'::text, 'property'::text, 'property_intake'::text, 'visit'::text])));

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
    -- reached through it (a photo uploaded straight into a Site file has its own branch below).
    if not exists (select 1 from public.property_intakes i
                    where i.id = new.entity_id) then
      raise exception 'photo_links: property_intake % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'property' then
    -- added 2026-11-17 (Trello #219): a photo uploaded into a location's Site file. A live, serviced location only.
    if not exists (select 1 from public.properties p
                    where p.id = new.entity_id and p.deleted_at is null and not coalesce(p.is_billing, false)) then
      raise exception 'photo_links: property % does not exist, is removed or is a billing address', new.entity_id
        using errcode = '23503';
    end if;
  end if;
  return new;
end
$function$;

-- 2. the one rule for which photos belong to a location (the builder, Submit's check and the driver page all read it)
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
      union all
      -- 2026-11-17 (Trello #219): a photo a staff person uploaded into this location's Site file builder
      -- (client.add_site_photo), in the private bucket intake-photos under site/<property id>/.
      select p.id, 'upload'::text, 'intake-photos'::text, substr(p.storage_path, 15), pl.entity_id, null::date,
             null::text, null::text, p.rotation_deg, p.content_type
        from public.photo_links pl
        join public.photos p on p.id = pl.photo_id
       where pl.entity_type = 'property' and pl.deleted_at is null
         and pl.entity_id = p_property_id
         and p.storage_path ~ ('^intake-photos/site/' || p_property_id::text || '/[0-9a-f-]{36}[.](jpg|png)$')
         and p.content_type like 'image/%'
    ) x (photo_id, kind, bucket, path, entity_id, visit_date, question_key, caption, rotation_deg, content_type)
   where exists (select 1 from storage.objects so where so.bucket_id = x.bucket and so.name = x.path)
   order by x.photo_id, x.visit_date desc nulls last, x.kind desc, x.entity_id desc
$function$;

-- 3. the builder's read
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
    select o.*, q.label, up.uploaded_at, up.uploaded_by_name from public.fn_page_photo_ids(p_property_id) o
      left join client.v_intake_questions q on q.question_key = o.question_key
      -- 2026-11-17 (Trello #219): who uploaded a photo into the Site file, and when (the link's caption is their email).
      left join lateral (select ph.uploaded_at, public.fn_page_staff_name(pl.caption) as uploaded_by_name
                           from public.photo_links pl join public.photos ph on ph.id = pl.photo_id
                          where o.kind = 'upload' and pl.photo_id = o.photo_id and pl.entity_type = 'property'
                            and pl.entity_id = p_property_id and pl.deleted_at is null
                          order by pl.id limit 1) up on true),
  item as (
    select o.photo_id, jsonb_build_object(
             'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
             'visit_id', case when o.kind = 'visit' then o.entity_id end,
             'intake_id', case when o.kind = 'intake' then o.entity_id end,
             'visit_date', o.visit_date, 'question_key', o.question_key,
             'label', coalesce(o.label, o.question_key), 'caption', o.caption,
             'rotation_deg', o.rotation_deg, 'content_type', o.content_type)
           || case when o.kind = 'upload' then jsonb_build_object('uploaded_at', o.uploaded_at,
                'uploaded_by_name', o.uploaded_by_name) else '{}'::jsonb end as j,
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
                       where it.kind in ('intake', 'upload') or it.entity_id in (select entity_id from recent_visits)), '[]'::jsonb),
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

-- 4. the storage rule and the record
CREATE OR REPLACE FUNCTION client.fn_site_photo_path_ok(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-17 (Trello #219): the storage rule for a photo uploaded into a Site file. A signed-in staff person with Picture
-- Planner Edit may add ONE new object named site/<a live, serviced property id>/<uuid>.jpg (or .png) in the private bucket
-- intake-photos. Nothing else: no other folder, no overwrite (there is no UPDATE rule), no delete (Remove in the builder
-- takes a photo off the draft; the file is kept).
declare
  v_m text[];
begin
  if auth.uid() is null then return false; end if;
  if not coalesce(public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))), false) then return false; end if;
  v_m := regexp_match(coalesce(p_name, ''),
    '^site/([0-9]{1,18})/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png)$');
  if v_m is null then return false; end if;
  if not exists (select 1 from public.properties p
                  where p.id = v_m[1]::bigint and p.deleted_at is null and not coalesce(p.is_billing, false)) then
    return false;
  end if;
  return hr.fn_app_open('picture_planner', 'edit');
end
$function$;

CREATE POLICY site_photos_staff_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'intake-photos' AND client.fn_site_photo_path_ok(name));

CREATE OR REPLACE FUNCTION client.add_site_photo(p_property_id bigint, p_storage_path text, p_width_px integer DEFAULT NULL, p_height_px integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-17 (Trello #219; Fred: "go with U3, yes to P2 and P3, all defaults"): records a photo a staff person uploaded
-- into a location's Site file builder (Picture Planner; the Ops Portal's builder too), so the builder can put it in the
-- draft. The browser first stores the file at site/<property id>/<uuid>.jpg in the private bucket intake-photos (storage
-- rule client.fn_site_photo_path_ok), then calls this. From then on public.fn_page_photo_ids lists it for the location
-- (kind 'upload'), so Submit accepts it and the driver page shows it once a version holding it is approved (P2: never
-- before). Remove in the builder never deletes it. Returns the photo as client.get_page_builder's pool lists it; calling
-- this again for the same file returns the same photo.
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_m     text[];
  v_p     record;
  v_obj   record;
  v_mime  text;
  v_full  text;
  v_photo bigint;
  v_out   jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.add_site_photo';
  end if;
  if not coalesce(public.fn_is_staff_email(v_email), false) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.add_site_photo';
  end if;
  perform hr.fn_check_app('picture_planner', 'edit', 'upload a site file photo');

  select p.id, p.deleted_at, p.is_billing into v_p from public.properties p where p.id = p_property_id;
  if not found or v_p.deleted_at is not null then
    raise exception 'This property is not active any more.' using errcode = 'P0002',
      detail = 'blocker=property_retired in client.add_site_photo';
  end if;
  if coalesce(v_p.is_billing, false) then
    raise exception 'This is a billing address, not a place we service.' using errcode = '22023',
      detail = 'blocker=billing_property in client.add_site_photo';
  end if;

  -- the path must be THIS location's: no adding an object uploaded for another one
  v_m := regexp_match(coalesce(p_storage_path, ''),
    '^site/([0-9]{1,18})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[.](jpg|png)$');
  if v_m is null or v_m[1]::bigint <> p_property_id then
    raise exception 'This photo was uploaded for a different location and cannot be added here.' using errcode = '22023',
      detail = 'blocker=path_mismatch in client.add_site_photo';
  end if;
  v_full := 'intake-photos/' || p_storage_path;
  perform pg_advisory_xact_lock(hashtext('site_photo:' || v_full));

  select ph.id into v_photo from public.photos ph where ph.storage_path = v_full;
  if v_photo is null then
    -- the object: in THIS bucket, uploaded by THIS caller, a JPG or PNG; size and type from its own metadata
    select o.owner_id, o.metadata into v_obj
      from storage.objects o where o.bucket_id = 'intake-photos' and o.name = p_storage_path;
    if not found or v_obj.owner_id is null then
      raise exception 'The photo did not finish uploading. Try again.' using errcode = 'P0002',
        detail = 'blocker=object_missing in client.add_site_photo';
    end if;
    if v_obj.owner_id <> v_uid::text then
      raise exception 'This photo was uploaded by someone else.' using errcode = '42501',
        detail = 'blocker=object_owner in client.add_site_photo';
    end if;
    v_mime := v_obj.metadata ->> 'mimetype';
    if v_mime is null or v_mime not in ('image/jpeg', 'image/png') then
      raise exception 'Only JPG and PNG photos can be added.' using errcode = '22023',
        detail = 'blocker=not_image in client.add_site_photo';
    end if;
    insert into public.photos (storage_path, file_name, content_type, size_bytes, width_px, height_px,
                               uploaded_by_employee_id, uploaded_at, source)
    values (v_full, v_m[2] || '.' || v_m[3], v_mime, nullif(v_obj.metadata ->> 'size', '')::bigint,
            case when p_width_px between 1 and 20000 then p_width_px end,
            case when p_height_px between 1 and 20000 then p_height_px end,
            hr.fn_access_caller(), now(), 'site_file_upload')
    returning id into v_photo;
    -- caption = the uploader's sign-in email: the estate's author convention for a link (client.attach_reason_photo)
    insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
    values (v_photo, 'property', p_property_id, 'site_photo', v_email);
  end if;

  select jsonb_build_object(
           'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
           'visit_id', null, 'intake_id', null, 'visit_date', null, 'question_key', null, 'label', null, 'caption', null,
           'rotation_deg', o.rotation_deg, 'content_type', o.content_type,
           'uploaded_at', ph.uploaded_at,
           'uploaded_by_name', public.fn_page_staff_name((select pl.caption from public.photo_links pl
                                 where pl.photo_id = o.photo_id and pl.entity_type = 'property'
                                   and pl.entity_id = p_property_id and pl.deleted_at is null order by pl.id limit 1)),
           'owned', true)
    into v_out
    from public.fn_page_photo_ids(p_property_id) o join public.photos ph on ph.id = o.photo_id
   where o.photo_id = v_photo;
  if v_out is null then
    raise exception 'This photo belongs to another location.' using errcode = '22023',
      detail = 'blocker=not_this_location in client.add_site_photo';
  end if;
  return v_out;
end
$function$;

REVOKE ALL ON FUNCTION client.fn_site_photo_path_ok(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.fn_site_photo_path_ok(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION client.add_site_photo(bigint, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.add_site_photo(bigint, text, integer, integer) TO authenticated, service_role;

-- VERIFY (light: the heavy comparisons ran in the rolled-back rehearsal, rehearse219.sql in the session scratchpad)
DO $verify$
DECLARE
  v_fred text := '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","email":"fred@ayache.com","role":"authenticated"}';
  v_uuid text := 'site/1164/0e5c1d2a-1111-4222-8333-944455556666.jpg';
  v_ok boolean;
BEGIN
  -- grants
  IF has_function_privilege('anon', 'client.add_site_photo(bigint,text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'client.fn_site_photo_path_ok(text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'client.add_site_photo(bigint,text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'client.fn_site_photo_path_ok(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: grants';
  END IF;
  -- the storage rule, as no one: false
  IF client.fn_site_photo_path_ok(v_uuid) THEN RAISE EXCEPTION 'VERIFY: path ok with no sign-in'; END IF;
  -- as Fred: the right folder only
  PERFORM set_config('request.jwt.claims', v_fred, true);
  IF NOT client.fn_site_photo_path_ok(v_uuid) THEN RAISE EXCEPTION 'VERIFY: path refused for Fred'; END IF;
  IF client.fn_site_photo_path_ok('1164/0e5c1d2a-1111-4222-8333-944455556666.jpg')
     OR client.fn_site_photo_path_ok('site/1164/x.jpg')
     OR client.fn_site_photo_path_ok('site/1164/0e5c1d2a-1111-4222-8333-944455556666.gif')
     OR client.fn_site_photo_path_ok('site/1057/0e5c1d2a-1111-4222-8333-944455556666.jpg')   -- a removed location
     OR client.fn_site_photo_path_ok('site/493/0e5c1d2a-1111-4222-8333-944455556666.jpg') THEN -- a billing address
    RAISE EXCEPTION 'VERIFY: path accepted where it must not be';
  END IF;
  -- the record refuses another location's file and a file that is not there
  BEGIN
    PERFORM client.add_site_photo(1208, v_uuid);
    RAISE EXCEPTION 'VERIFY: add_site_photo took another location''s path';
  EXCEPTION WHEN sqlstate '22023' THEN NULL;
  END;
  BEGIN
    PERFORM client.add_site_photo(1164, v_uuid);
    RAISE EXCEPTION 'VERIFY: add_site_photo took a missing object';
  EXCEPTION WHEN sqlstate 'P0002' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  -- the link trigger refuses a removed location
  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role) VALUES ((SELECT min(id) FROM public.photos), 'property', 1057, 'site_photo');
    RAISE EXCEPTION 'VERIFY: link to a removed location accepted';
  EXCEPTION WHEN sqlstate '23503' THEN NULL;
  END;
  -- no upload exists yet, so the photo rule lists what it listed before for every location with a Site file
  IF EXISTS (SELECT 1 FROM public.properties p, public.fn_page_photo_ids(p.id) o
              WHERE p.id IN (SELECT property_id FROM public.property_pages) AND o.kind NOT IN ('visit', 'intake')) THEN
    RAISE EXCEPTION 'VERIFY: an upload before any upload';
  END IF;
END $verify$;

COMMIT;
