-- 2026-10-21_0900_hr_access_watch_client_app_and_calendar · Access phase 5: Client App and Visit Calendar in WATCH
--
-- Fred, 2026-10-20: "start phase 5 Client App and Visit Calendar". Plan: Building Apps/HR App/docs/specs/2026-10-19-access-
-- privileges-plan.md (rows Client App: View = clients, properties, jobs, invoices; Edit = create, change, archive (goes to
-- Jobber). Visit Calendar: View = visits, crews, trucks, hours; Edit = create, move, complete or skip visits, tasks, zones).
-- Same shape as phases 2 to 4 (2026-10-20_1400, _1600, _1700).
--
-- MAP (step 1), read off the live bundles and the catalogue on 2026-10-21:
--   Client App (11 chunks): 21 client.* functions, 10 edge functions, no direct table write.
--   Visit Calendar (3 chunks, 1.4 MB): about 30 ops / public functions (most ops ones are one-line SQL wrappers of the
--   public function of the same name), 7 edge functions, direct writes to public.zones (zone editor) and
--   ops.calendar_day_markers.dump_visit_id (a column grant).
--   Shared: edge fns create-client and save-calendar-task (both apps), client.cancel_intake (Client App + Picture Planner),
--   client.update_property_capacity / update_property_operational (also called by Picture Planner's accept_intake_answers),
--   public.get_record_history (also read by client.get_client_activity).
-- WHAT THIS DOES (steps 3 + 4):
--   * NEW hr.fn_check_any_app(apps[], level, what) (VOLATILE) and hr.fn_require_any_app(apps[], level) (STABLE): allowed when
--     the caller's level in ANY of the apps is enough; an app still 'off' lets it through; watch logs one row per app.
--   * 16 Client App and 14 Calendar changing functions check Edit (the shared ones in either app); 9 readers and automatic
--     functions check View (refresh_start_flags and request_drive_fill run by themselves, so a View-only person is never
--     logged for opening the Calendar).
--   * client.cancel_intake: Edit in Picture Planner OR the Client App (phase 3 had Picture Planner only and missed this caller).
--   * hr.check_app_action takes a list of apps per action and gains the 13 edge actions of the two apps.
--   * NEW trigger aa_access_zones on public.zones (the Calendar's own table: only its zone editor and SQL write it).
--   * NEW ops.link_day_marker_dump_visit: the Calendar's one direct day-marker write, behind its check.
--   * hr.access_apps client_app and visit_calendar: off -> watch.
--   Left alone: the SQL-language ops wrappers (each hands off to the checked public function), SQL / INVOKER readers
--   (global_search, recurring_eligibility, calendar_hours_estimates, dump_site_status, start_first_visit), the list views
--   (last phase), storage.
-- Bodies are spliced from the live pg_get_functiondef (md5-pinned), never retyped; each added line carries "-- 2026-10-21_0900 access phase 5".
-- Rule 8: no table. Rollback: 2026-10-21_rollback_hr_access_watch_client_app_and_calendar.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  if md5(pg_get_functiondef('client.attach_reason_photo(text,bigint,text,text,integer,integer)'::regprocedure)) <> 'cbe79d7dedf350986987db948fff6c24' then raise exception 'client.attach_reason_photo(text,bigint,text,text,integer,integer) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.cancel_intake(bigint)'::regprocedure)) <> '78fa3eeb9aab060c6371361f1414eec8' then raise exception 'client.cancel_intake(bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.create_client_contact(bigint,jsonb)'::regprocedure)) <> 'cbfaa1ccb66051fe70c747813b7b6c20' then raise exception 'client.create_client_contact(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.delete_client_contact(bigint)'::regprocedure)) <> '57d009a4cc6a9f0aeb9b58e5d18ae5f6' then raise exception 'client.delete_client_contact(bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.generate_visits_for_client(bigint)'::regprocedure)) <> '1c62b4f95b04929e3bbcfd4c6dc02624' then raise exception 'client.generate_visits_for_client(bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) <> '6b9756653587d446adda73223e3e4811' then raise exception 'client.get_client_activity(bigint,boolean,integer,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.preview_client_status_change(bigint,text)'::regprocedure)) <> '33106c10025ce1e61cbfc08f8e1aface' then raise exception 'client.preview_client_status_change(bigint,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.preview_job_action(bigint,bigint,text)'::regprocedure)) <> 'd7e15bb2e3c55b2bef7a3be4bd6343eb' then raise exception 'client.preview_job_action(bigint,bigint,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.remove_reason_photo(bigint,text)'::regprocedure)) <> 'c7376f5958a2cd060fbf613071460ad5' then raise exception 'client.remove_reason_photo(bigint,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.save_contact_settings(text,bigint,jsonb)'::regprocedure)) <> '305444d9494b2b02953c8cd2f8ad6768' then raise exception 'client.save_contact_settings(text,bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) <> 'e50ad96898b5eaa6866a155acea93650' then raise exception 'client.schedule_property_intake(bigint,text[],jsonb,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_client_contact(bigint,jsonb)'::regprocedure)) <> '9437ea5a8ab47ddbb0f602f3fd20330b' then raise exception 'client.update_client_contact(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_client_fields(bigint,jsonb)'::regprocedure)) <> '74026068743ee6f425a36888924d66e3' then raise exception 'client.update_client_fields(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_client_status(bigint,text)'::regprocedure)) <> 'e1a6ec1ee549c4546c2325bce486fe98' then raise exception 'client.update_client_status(bigint,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure)) <> 'cb528c2e12796001aa00d7222ca9d0e3' then raise exception 'client.update_client_status(bigint,text,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_client_zone(bigint,bigint)'::regprocedure)) <> 'bd1d3d931ec741d3b7a2a031427065ca' then raise exception 'client.update_client_zone(bigint,bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_property_capacity(bigint,integer)'::regprocedure)) <> 'ee90e86a382b6c15a5c25a2f4a6e466f' then raise exception 'client.update_property_capacity(bigint,integer) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_property_city_email(bigint,text[])'::regprocedure)) <> '56b22a48fd0e50e2e94b2667bcb3c3e1' then raise exception 'client.update_property_city_email(bigint,text[]) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.update_property_operational(bigint,jsonb)'::regprocedure)) <> 'a027f3aab19f40d2a9893b13a89768dd' then raise exception 'client.update_property_operational(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) <> '6dcdc8bf1ad8f7bcf64d7d057a32993f' then raise exception 'client.upsert_gdo_permit(bigint,bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamp with time zone,timestamp with time zone,text,text,bigint,bigint,jsonb,bigint[],jsonb)'::regprocedure)) <> '88c8de37b0ce801b185e4be54e5dbba1' then raise exception 'create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamp with time zone,timestamp with time zone,text,text,bigint,bigint,jsonb,bigint[],jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.create_dump_visit(bigint,bigint,bigint[],date,bigint,timestamp with time zone,timestamp with time zone,text,text,bigint,bigint[],boolean,bigint)'::regprocedure)) <> 'b13a9bd30d46a145aedf664e9d40872a' then raise exception 'create_dump_visit(bigint,bigint,bigint[],date,bigint,timestamp with time zone,timestamp with time zone,text,text,bigint,bigint[],boolean,bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.delete_calendar_visit(bigint)'::regprocedure)) <> 'ddbaf4bafee6efc64960268e92c8b08c' then raise exception 'delete_calendar_visit(bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.edit_calendar_visit(bigint,jsonb)'::regprocedure)) <> 'da989827f06d37203068ccc104ac7bc3' then raise exception 'edit_calendar_visit(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.fn_visit_edit_clash(bigint,jsonb)'::regprocedure)) <> '9617f1e70a30bd6a173329749aab4b61' then raise exception 'fn_visit_edit_clash(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.get_record_history(text,text,timestamp with time zone,boolean,integer,jsonb)'::regprocedure)) <> 'e17ad32d135e03a26046e9f626d1412d' then raise exception 'get_record_history(text,text,timestamp with time zone,boolean,integer,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('hr.check_app_action(text)'::regprocedure)) <> '7deef417e9b870801384fba4ce062c6a' then raise exception 'hr.check_app_action(text) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.calendar_drive_days(date,date)'::regprocedure)) <> '956a5cd54a9efe60817d7634f5d95a81' then raise exception 'ops.calendar_drive_days(date,date) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.calendar_grease_estimates(date,date)'::regprocedure)) <> '7e2839e39941f71c71d705a6f21c51c7' then raise exception 'ops.calendar_grease_estimates(date,date) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.cancel_visit_request(bigint,text)'::regprocedure)) <> '9379e3d7e72062f69bd57410fc89ad62' then raise exception 'ops.cancel_visit_request(bigint,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])'::regprocedure)) <> 'ec7d0a41b0554dcc7082b774c1f2b3bd' then raise exception 'ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[]) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.preview_sa_reanchor(bigint,date)'::regprocedure)) <> '4ad3924ef65fa70d45889ae01556d93f' then raise exception 'ops.preview_sa_reanchor(bigint,date) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.preview_start_impact(jsonb)'::regprocedure)) <> '93e44cb6856df4f2a44db8c23a0abfc9' then raise exception 'ops.preview_start_impact(jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.refresh_start_flags()'::regprocedure)) <> '9b3be441b7c6169586976d82fdcf549c' then raise exception 'ops.refresh_start_flags() changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.request_drive_fill(date,date,boolean)'::regprocedure)) <> '1cc2083811ea7cff39dc33b16636dbb1' then raise exception 'ops.request_drive_fill(date,date,boolean) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.schedule_visit_request(bigint,date,timestamp with time zone,timestamp with time zone,bigint,bigint[])'::regprocedure)) <> '105db8e217a736d5c5939fba6eb08385' then raise exception 'ops.schedule_visit_request(bigint,date,timestamp with time zone,timestamp with time zone,bigint,bigint[]) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.snooze_call_request(bigint,date)'::regprocedure)) <> 'b6fa647e4ba757ba8670b5accaed9da5' then raise exception 'ops.snooze_call_request(bigint,date) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.unschedule_calendar_visit(bigint)'::regprocedure)) <> 'f9ad1be1677ea32f15e456336fbb0fa1' then raise exception 'ops.unschedule_calendar_visit(bigint) changed since it was read'; end if;
  if md5(pg_get_functiondef('ops.update_visit_request(bigint,jsonb)'::regprocedure)) <> 'eaf0faa3a062adc325a3fc5f25a2a898' then raise exception 'ops.update_visit_request(bigint,jsonb) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.retry_visit_push(bigint,boolean)'::regprocedure)) <> '0443fd7930993b7a9e4971dd85a415fe' then raise exception 'retry_visit_push(bigint,boolean) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.ripple_reschedule_visit(bigint,date,timestamp with time zone,timestamp with time zone,boolean)'::regprocedure)) <> 'd41d9c5db0bebead521b17092871ec7c' then raise exception 'ripple_reschedule_visit(bigint,date,timestamp with time zone,timestamp with time zone,boolean) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.set_visit_status(bigint,text,text)'::regprocedure)) <> 'e1c03243eeae9334f77485f0555ca615' then raise exception 'set_visit_status(bigint,text,text) changed since it was read'; end if;
  if md5(pg_get_functiondef('public.unskip_visit(bigint)'::regprocedure)) <> '14d01369ab34395899c303a109499501' then raise exception 'unskip_visit(bigint) changed since it was read'; end if;
  if exists (select 1 from hr.access_apps where app in ('client_app','visit_calendar') and mode <> 'off') then raise exception 'client_app or visit_calendar is not off'; end if;
END $g$;

CREATE FUNCTION hr.fn_check_any_app(p_apps text[], p_level text, p_what text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- -- 2026-10-21_0900 access phase 5: allowed when the caller's level in ANY of p_apps is enough. An app still 'off' lets everything through (not
-- checked yet). When every app is 'on' it refuses; otherwise (watch) it lets it through and logs one row per app, at most
-- once a minute per person and action, like hr.fn_check_app.
declare v_app text; v_modes text[]; v_emp bigint; v_email text;
begin
  if p_apps is null or cardinality(p_apps) = 0 then
    raise exception 'No app given.' using errcode = '22023', detail = 'blocker=no_app in hr.fn_check_any_app';
  end if;
  select array_agg(a.mode) into v_modes from hr.access_apps a where a.app = any (p_apps);
  if v_modes is null or cardinality(v_modes) <> cardinality(p_apps) then
    raise exception 'Unknown app.' using errcode = '22023', detail = 'blocker=unknown_app in hr.fn_check_any_app';
  end if;
  if 'off' = any (v_modes) then return; end if;
  foreach v_app in array p_apps loop
    if hr.fn_access_rank(hr.fn_app_level(v_app)) >= hr.fn_access_rank(p_level) then return; end if;
  end loop;
  if not ('watch' = any (v_modes)) then
    raise exception 'You do not have access to do this. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=' || array_to_string(p_apps, '|') || ' needs=' || p_level;
  end if;
  v_emp := hr.fn_access_caller();
  select u.email into v_email from auth.users u where u.id = auth.uid();
  foreach v_app in array p_apps loop
    if not exists (select 1 from hr.access_refusals r where r.app = v_app and r.what = p_what
                     and r.email is not distinct from v_email and r.at > now() - interval '1 minute') then
      insert into hr.access_refusals (app, needs, has, employee_id, email, what)
      values (v_app, p_level, coalesce(hr.fn_app_level(v_app), 'none'), v_emp, v_email, left(p_what, 200));
    end if;
  end loop;
end $function$;
REVOKE ALL ON FUNCTION hr.fn_check_any_app(text[], text, text) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION hr.fn_require_any_app(p_apps text[], p_level text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- -- 2026-10-21_0900 access phase 5: the read check for something two apps read. Passes unless EVERY app is 'on' and the caller is below the level in all.
declare v_app text;
begin
  if exists (select 1 from hr.access_apps a where a.app = any (p_apps) and a.mode <> 'on') then return; end if;
  foreach v_app in array p_apps loop
    if hr.fn_access_rank(hr.fn_app_level(v_app)) >= hr.fn_access_rank(p_level) then return; end if;
  end loop;
  raise exception 'You do not have access to do this. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=' || array_to_string(p_apps, '|') || ' needs=' || p_level;
end $function$;
REVOKE ALL ON FUNCTION hr.fn_require_any_app(text[], text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION client.attach_reason_photo(p_entity_type text, p_entity_id bigint, p_storage_path text, p_file_name text DEFAULT NULL::text, p_width_px integer DEFAULT NULL::integer, p_height_px integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email   text;
  v_uid     uuid;
  v_m       text[];
  v_obj     record;
  v_live    integer;
  v_max     integer := client.reason_photo_max();
  v_photo   bigint;
  v_link    bigint;
  v_emp     bigint;
  v_size    bigint;
  v_mime    text;
  v_out     jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'add a reason photo');   -- 2026-10-21_0900 access phase 5
  -- the same gate every client.* RPC uses
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  -- the target
  if not client.fn_reason_photo_target_exists(p_entity_type, p_entity_id) then
    raise exception 'The change this image belongs to could not be found. Save the change first, then add the image.'
      using errcode = 'P0002', detail = 'blocker=target_missing entity_type=' || coalesce(p_entity_type,'') || ' entity_id=' || coalesce(p_entity_id::text,'');
  end if;

  -- the path must be THIS record's: no attaching an object uploaded for another change
  v_m := regexp_match(coalesce(p_storage_path, ''),
    '^client-app/([a-z_]+)/([0-9]{1,18})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[.](jpg|jpeg|png|webp)$');
  if v_m is null or v_m[1] <> p_entity_type or v_m[2]::bigint <> p_entity_id then
    raise exception 'This image was uploaded for a different change and cannot be attached here.'
      using errcode = '22023', detail = 'blocker=path_mismatch storage_path=' || coalesce(p_storage_path,'');
  end if;

  -- serialise per record so two concurrent attaches cannot both pass the cap
  perform pg_advisory_xact_lock(hashtext('reason_photo:' || p_entity_type || ':' || p_entity_id::text));

  -- idempotent: the same object attached twice returns the existing link (rule 5)
  select pl.id, pl.photo_id into v_link, v_photo
    from public.photo_links pl
    join public.photos p on p.id = pl.photo_id
   where p.storage_path = p_storage_path
     and pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;
  if v_link is null then
    select count(*) into v_live
      from public.photo_links pl
     where pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
       and pl.role = 'reason_photo' and pl.deleted_at is null;
    if v_live >= v_max then
      raise exception 'This change already has % images. Remove one before adding another.', v_max
        using errcode = '23514', detail = 'blocker=cap live=' || v_live || ' max=' || v_max;
    end if;

    -- the object: it must exist in THIS bucket, uploaded by THIS caller, and be an image.
    -- size and mimetype come from the object's own metadata, never from the caller.
    select o.owner_id, o.metadata into v_obj
      from storage.objects o
     where o.bucket_id = 'reason-photos' and o.name = p_storage_path;
    if not found or v_obj.owner_id is null then
      raise exception 'The image did not finish uploading. Try adding it again.'
        using errcode = 'P0002', detail = 'blocker=object_missing storage_path=' || p_storage_path;
    end if;
    if v_obj.owner_id <> v_uid::text then
      raise exception 'This image was uploaded by someone else and cannot be attached here.'
        using errcode = '42501', detail = 'blocker=object_owner';
    end if;
    v_mime := v_obj.metadata ->> 'mimetype';
    v_size := nullif(v_obj.metadata ->> 'size', '')::bigint;
    if v_mime is null or v_mime not like 'image/%' then
      raise exception 'Only images can be attached to a reason.'
        using errcode = '22023', detail = 'blocker=not_image mimetype=' || coalesce(v_mime,'');
    end if;

    select e.id into v_emp
      from public.employees e
     where e.email is not null and lower(e.email) = v_email
     order by (e.status = 'ACTIVE') desc, e.id
     limit 1;

    insert into public.photos
      (storage_path, file_name, content_type, size_bytes, width_px, height_px,
       uploaded_by_employee_id, uploaded_at, source)
    values
      (p_storage_path, coalesce(nullif(btrim(p_file_name), ''), v_m[3] || '.' || v_m[4]), v_mime, v_size,
       p_width_px, p_height_px, v_emp, now(), 'client_app_upload')
    returning id into v_photo;

    -- caption = the uploader's GoTrue email: the estate's documented author convention for a link
    insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
    values (v_photo, p_entity_type, p_entity_id, 'reason_photo', v_email)
    returning id into v_link;
  end if;

  select count(*) into v_live
    from public.photo_links pl
   where pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;

  select to_jsonb(r) || jsonb_build_object('remaining', v_max - v_live) into v_out
    from client.reason_photos r
   where r.link_id = v_link;
  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION client.create_client_contact(p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['property_id','first_name','last_name','contact_role','email','phone'];
  v_roles    text[] := array['primary','accounting'];
  v_bad      text[];
  v_first    text;
  v_last     text;
  v_role     text;
  v_email    text;
  v_phone    text;
  v_prop     bigint;
  v_name     text;
  v_row      public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'add a contact');   -- 2026-10-21_0900 access phase 5
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated`
  -- token with no `sub` claim would otherwise pass. Mirrors public.set_visit_status.
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % does not exist', p_client_id using errcode = '23503';
  end if;

  v_first := nullif(btrim(coalesce(p_patch->>'first_name','')), '');
  v_last  := nullif(btrim(coalesce(p_patch->>'last_name','')),  '');
  v_email := nullif(btrim(coalesce(p_patch->>'email','')),      '');
  v_phone := nullif(btrim(coalesce(p_patch->>'phone','')),      '');
  v_role  := lower(nullif(btrim(coalesce(p_patch->>'contact_role','')), ''));

  -- Guarded cast: a bare ::bigint on junk raises 22P02 ("invalid input syntax for
  -- type bigint"), which surfaces in the UI as an unreadable Postgres string. The
  -- error mapper only passes through the codes it knows, so give it a 22023.
  declare v_prop_txt text := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
  begin
    if v_prop_txt is not null then
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
    end if;
  end;

  -- Fred's required set: Name, Property, and either Phone or Email.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_prop is null then
    raise exception 'A property must be selected for the contact.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.'
      using errcode = '22023';
  end if;

  -- The property must belong to THIS client. Without this check the RPC would happily
  -- attach a contact to another client's property -- the same cross-client hole the
  -- wave-1 review caught on gdos.property_id.
  if not exists (select 1 from public.properties p
                 where p.id = v_prop and p.client_id = p_client_id) then
    raise exception 'Property % does not belong to client %', v_prop, p_client_id
      using errcode = '22023';
  end if;

  -- contact_role is NOT NULL on the table; default to the app's own default.
  v_role := coalesce(v_role, 'primary');
  if v_role <> all (v_roles) then
    if v_role = 'city' then
      raise exception 'The City role has been retired. City email addresses now live on the location itself, under City email.'
        using errcode = '22023',
              detail  = 'blocker=contact_role_city_retired value=city';
    end if;
    raise exception 'Pick a role for this contact: Main contact, or Accounting.'
      using errcode = '22023',
            detail  = 'blocker=contact_role_unknown value=' || coalesce(v_role, '(null)');
  end if;

  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- `name` stays the display value every existing reader already uses
  -- (send-derm-email, the app list). Composed here, never stored redundantly split.
  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    insert into public.client_contacts
      (client_id, property_id, contact_role, name, first_name, last_name, email, phone)
    values
      (p_client_id, v_prop, v_role, v_name, v_first, v_last, v_email, v_phone)
    returning * into v_row;
  exception when unique_violation then
    raise exception 'This property already has a % contact. Edit that contact instead of adding a second one.',
      v_role using errcode = '23505';
  end;

  return to_jsonb(v_row);
end
$function$;

CREATE OR REPLACE FUNCTION client.delete_client_contact(p_contact_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'delete a contact');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  if v_row.property_id is null and v_row.contact_role = 'primary' then
    raise exception 'This is the client''s main contact and it comes from Jobber, so deleting it here would not stick — the next sync re-creates it within about five minutes. Clear its email and phone instead, which updates Jobber too.'
      using errcode = '42501';
  end if;

  delete from public.client_contacts where id = p_contact_id;

  return jsonb_build_object(
    'deleted_id',   v_row.id,
    'client_id',    v_row.client_id,
    'contact_role', v_row.contact_role,
    'property_id',  v_row.property_id,
    'email',        v_row.email,
    'phone',        v_row.phone
  );
end;
$function$;

CREATE OR REPLACE FUNCTION client.generate_visits_for_client(p_client_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text;
  v_res   jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'generate visits');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    -- Guard the shape of the call itself: a null here would run the FULL sweep,
    -- including the destructive cleanup branch. The app must never do that.
    raise exception 'a client is required' using errcode = '22023';
  end if;

  select public.fn_generate_sa_visits(p_client_id) into v_res;
  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION client.remove_reason_photo(p_link_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text;
  v_link  record;
  v_live  integer;
begin
  perform hr.fn_check_app('client_app', 'edit', 'remove a reason photo');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select pl.id, pl.entity_type, pl.entity_id, pl.deleted_at, p.storage_path
    into v_link
    from public.photo_links pl
    join public.photos p on p.id = pl.photo_id
   where pl.id = p_link_id and pl.role = 'reason_photo';
  if not found then
    raise exception 'That image could not be found.'
      using errcode = 'P0002', detail = 'blocker=link_missing link_id=' || coalesce(p_link_id::text,'');
  end if;
  if v_link.deleted_at is not null then
    raise exception 'This image has already been removed.'
      using errcode = '22023', detail = 'blocker=already_removed link_id=' || p_link_id;
  end if;

  update public.photo_links
     set deleted_at = now(),
         deleted_by = auth.uid(),
         deleted_reason = coalesce(nullif(btrim(p_reason), ''), 'Removed in the Client App by ' || v_email)
   where id = p_link_id;

  select count(*) into v_live
    from public.photo_links pl
   where pl.entity_type = v_link.entity_type and pl.entity_id = v_link.entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;

  return jsonb_build_object(
    'link_id',      p_link_id,
    'entity_type',  v_link.entity_type,
    'entity_id',    v_link.entity_id,
    'bucket',       'reason-photos',
    'storage_path', v_link.storage_path,
    'remaining',    client.reason_photo_max() - v_live,
    'live',         v_live);
end;
$function$;

CREATE OR REPLACE FUNCTION client.save_contact_settings(p_source text, p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array['person_role','person_role_other','communication'];
  v_types   text[] := array['invoice','quote_approval','service_report','city_report'];
  v_bad text[]; v_client bigint; v_email text; v_label text; v_deleted timestamptz;
  v_role text; v_other text; v_comm jsonb; v_item jsonb; v_t text;
  v_prop bigint; v_prop_txt text; v_holder text; v_out jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'change contact settings');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_source is null or p_source <> all (array['ours','jobber']) then
    raise exception 'p_source must be ''ours'' or ''jobber''.' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object.' using errcode = '22023';
  end if;
  select array_agg(k) into v_bad from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s): %. Allowed: %', v_bad, v_allowed using errcode = '22023';
  end if;

  if p_source = 'ours' then
    select cc.client_id, cc.email,
           coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name, 'This contact'),
           cc.person_role, cc.person_role_other
      into v_client, v_email, v_label, v_role, v_other
      from public.client_contacts cc where cc.id = p_contact_id;
  else
    select jc.client_id, jc.email,
           coalesce(nullif(btrim(jc.name),''),
                    nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),''), 'This contact'),
           jc.person_role, jc.person_role_other, jc.deleted_at
      into v_client, v_email, v_label, v_role, v_other, v_deleted
      from public.client_jobber_contacts jc where jc.id = p_contact_id;
  end if;
  if v_client is null then
    raise exception 'That contact no longer exists.'
      using errcode = 'P0002', detail = 'blocker=contact_not_found id=' || p_contact_id;
  end if;
  if v_deleted is not null then
    raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023', detail = 'blocker=jobber_contact_removed id=' || p_contact_id;
  end if;

  ---- role ------------------------------------------------------------------------------
  if p_patch ? 'person_role' then
    v_role := lower(nullif(btrim(coalesce(p_patch->>'person_role','')),''));
  end if;
  if p_patch ? 'person_role_other' then
    v_other := nullif(btrim(coalesce(p_patch->>'person_role_other','')),'');
  end if;
  if v_role is not null and v_role <> all (array['store_manager','accounting','owner','other']) then
    raise exception 'Unknown role "%".', v_role
      using errcode = '22023', detail = 'blocker=person_role_unknown value=' || coalesce(v_role,'(null)');
  end if;
  if v_role = 'other' and v_other is null then
    raise exception 'Say what the role is, or pick one from the list.'
      using errcode = '22023', detail = 'blocker=person_role_other_blank';
  end if;
  if v_role is distinct from 'other' then v_other := null; end if;   -- never keep stale free text

  if p_patch ? 'person_role' or p_patch ? 'person_role_other' then
    if p_source = 'ours' then
      update public.client_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    else
      update public.client_jobber_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    end if;
  end if;

  ---- communication ---------------------------------------------------------------------
  if p_patch ? 'communication' then
    v_comm := p_patch->'communication';
    if jsonb_typeof(v_comm) <> 'array' then
      raise exception 'communication must be a list.' using errcode = '22023';
    end if;

    -- replace-the-set: unticking is a delete that leaves no row behind
    delete from public.client_communication_prefs
     where (p_source = 'ours'   and contact_id        = p_contact_id)
        or (p_source = 'jobber' and jobber_contact_id = p_contact_id);

    -- 🛑 AN EMPTY EMAIL CLEARS THE SET, IT DOES NOT RAISE. The modal lets you remove an address
    -- from a contact that holds boxes, and warns that the boxes go with it. If this raised, that
    -- save would be impossible and the warning would be a lie. So the guard sits AFTER the
    -- delete and only fires when something is being TICKED.
    if coalesce(btrim(v_email),'') = '' and jsonb_array_length(v_comm) > 0 then
      raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023', detail = 'blocker=contact_has_no_email id=' || p_contact_id;
    end if;

    for v_item in select * from jsonb_array_elements(v_comm) loop
      v_t := lower(nullif(btrim(coalesce(v_item->>'type','')),''));
      if v_t is null or v_t <> all (v_types) then
        raise exception 'Unknown communication type "%".', coalesce(v_t,'')
          using errcode = '22023', detail = 'blocker=communication_type_unknown value=' || coalesce(v_t,'(null)');
      end if;
      -- 🛑 the comma-bag guard, in the DATABASE and not only in the UI. Rows holding several
      -- addresses in one field exist; Resend would send to a single malformed address and
      -- report success.
      if v_email like '%,%' then
        raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023', detail = 'blocker=contact_email_is_a_list id=' || p_contact_id;
      end if;

      v_prop_txt := nullif(btrim(coalesce(v_item->>'property_id','')),'');
      if v_prop_txt is not null then
        if v_prop_txt !~ '^[0-9]+$' then   -- a bare ::bigint on junk raises an unreadable 22P02
          raise exception 'property_id must be a positive integer, got %', v_prop_txt using errcode = '22023';
        end if;
        v_prop := v_prop_txt::bigint;
      else
        v_prop := null;
      end if;

      if v_t = 'city_report' then
        if v_prop is null then
          raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023', detail = 'blocker=city_report_needs_location';
        end if;
        if not exists (select 1 from public.properties p
                        where p.id = v_prop and p.client_id = v_client and p.deleted_at is null) then
          raise exception 'That location does not belong to this client.'
            using errcode = '22023', detail = 'blocker=location_not_on_this_client property_id=' || v_prop;
        end if;
      elsif v_prop is not null then
        raise exception 'That communication covers the whole client, not one location.'
          using errcode = '22023', detail = 'blocker=communication_is_client_wide type=' || coalesce(v_t,'(null)');
      end if;

      -- ✅ TAKE-OVER RETIRED 2026-09-23. All four communications are now MULTI-HOLDER, so
      -- ticking one on a second person no longer deletes it from the first. The two DELETEs that
      -- used to sit here (invoice client-wide, city_report per property) were the real enforcement;
      -- the two partial unique indexes dropped in this migration were only the backstop, and
      -- dropping those ALONE would have looked fixed while still silently overwriting.
      -- Why: Jobber's defaultEmails(INVOICE_SENT) is an ARRAY and already holds more than one
      -- address on real clients (measured: of 34 read, 25 hold one, 8 hold two, 1 holds three -
      -- accounts@ + admin@, gaston@ + invoices@, and so on). An invoice genuinely goes to several
      -- people, so a record that can name only one could not express the truth, and the take-over
      -- destroyed the first name while trying. City report is a CC on an email WE send, and
      -- send-derm-email already resolves it into a de-duplicated Set - it was built for many all
      -- along. service_report and quote_approval were already multi-holder and are unchanged.

      begin
        insert into public.client_communication_prefs
          (client_id, comm_type, contact_id, jobber_contact_id, property_id)
        values (v_client, v_t,
                case when p_source = 'ours'   then p_contact_id end,
                case when p_source = 'jobber' then p_contact_id end,
                v_prop);
      exception when unique_violation then
        -- 🛑 name the holder. A raw 23505 in front of a person is the error this catch exists
        -- to stop, and the sentence is the operator-message rule: plain language in MESSAGE.
        select coalesce(
          (select coalesce(nullif(btrim(concat_ws(' ', c2.first_name, c2.last_name)),''), c2.name)
             from public.client_communication_prefs q
             join public.client_contacts c2 on c2.id = q.contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          (select coalesce(nullif(btrim(j2.name),''),
                           nullif(btrim(concat_ws(' ', j2.first_name, j2.last_name)),''))
             from public.client_communication_prefs q
             join public.client_jobber_contacts j2 on j2.id = q.jobber_contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          'Another contact') into v_holder;
        if v_t = 'invoice' then
          -- 🛑 OUR RULE, NOT JOBBER'S. Never "receives", never "only one person can receive".
          raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=invoice_already_held';
        elsif v_t = 'city_report' then
          raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=city_report_already_held';
        else
          raise exception '% already has that ticked.', v_holder
          using errcode = '23505', detail = 'blocker=duplicate_in_one_submission type=' || coalesce(v_t,'(null)');
        end if;
      end;
    end loop;
  end if;

  if p_source = 'ours' then
    select to_jsonb(v) into v_out from client.client_contacts v where v.id = p_contact_id;
  else
    select to_jsonb(v) into v_out from client.jobber_contacts  v where v.id = p_contact_id;
  end if;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION client.schedule_property_intake(p_property_id bigint, p_requested text[], p_form_snapshot jsonb DEFAULT NULL::jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_token text;
  v_exp   timestamptz;
  v_bad text[];
  v_valid text[];
  v_req text[];
  v_dropped text[];
  v_added text[];
  v_snapshot jsonb := coalesce(p_form_snapshot, public.fn_intake_form_current());
begin
  perform hr.fn_check_app('client_app', 'edit', 'schedule an intake form');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  -- 2026-09-27: every intake uses the current form. A custom question list could pin any tree (a probe stored
  -- version 99 with an HTML label); no caller passes one (the Client App never does, the test fixture inserts).
  if p_form_snapshot is not null then
    raise exception 'A site survey form always uses the current questions.'
      using errcode = '22023', detail = 'blocker=custom_form in client.schedule_property_intake';
  end if;
  if p_requested is null or array_length(p_requested, 1) is null then
    raise exception 'pick at least one question to collect' using errcode = '22023';
  end if;
  if jsonb_typeof(v_snapshot) <> 'object' or not (v_snapshot ? 'sections') then
    raise exception 'the form definition is not valid' using errcode = '22023';
  end if;

  perform 1 from public.properties
   where id = p_property_id and deleted_at is null and coalesce(is_billing, false) = false;
  if not found then
    raise exception 'This property was removed or is a billing address, so it cannot get a site survey form.'
      using errcode = 'P0002', detail = format('blocker=not_a_service_property in client.schedule_property_intake (property %s)', p_property_id);
  end if;

  -- Every requested key must exist as an L2 question in the pinned tree. A typo'd key
  -- can never be answered, so the intake would sit at Incomplete for ever with no way
  -- to tell a typo from a lazy collector.
  select array_agg(q ->> 'key') into v_valid
  from jsonb_array_elements(v_snapshot -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q;

  select array_agg(k) into v_bad
  from unnest(p_requested) k
  where k is null or btrim(k) = '' or v_valid is null or k <> all (v_valid);   -- a NULL or blank key is unknown too
  if v_bad is not null then
    raise exception 'unknown question key(s) for this form: %', v_bad using errcode = '22023';
  end if;

  -- A follow-up is asked only together with the question it depends on (fourth review, 2026-09-24).
  -- The dialog unchecks a question whose value we already hold, and an empty "key=" condition reads a
  -- parent that was never asked as blank, so "Measurements, if the gallons are not written anywhere"
  -- was being asked of every property whose gallons the office already has. Dropped here, once, for
  -- every caller; the stored set is the one the form, the status and the office all read.
  -- ...and (fifth review) an optional question is asked together with its ALTERNATIVE, the question
  -- shown when it is left blank ("key="), or a blank gallons answer would read Complete with no capacity.
  v_req := public.fn_intake_normalise_requested(v_snapshot, p_requested);
  select array_agg(k) into v_added from unnest(v_req) k where not coalesce(k = any (p_requested), false);
  select array_agg(k) into v_dropped from unnest(p_requested) k where not coalesce(k = any (v_req), false);
  -- Any follow-up whose parent was not ticked is refused in words, naming it (eighth review: a follow-up
  -- sent next to a required question used to be pruned silently and only reported in `dropped`).
  if v_dropped is not null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake: ' || array_to_string(v_dropped, ', ');
  end if;
  -- A request of only optional questions reads Complete with nothing answered (sixth review).
  if not exists (select 1 from unnest(v_req) k
                  join lateral (select q from jsonb_array_elements(v_snapshot -> 'sections') s, jsonb_array_elements(s -> 'questions') q
                                 where q ->> 'key' = k limit 1) qq on true
                 where coalesce(qq.q -> 'optional', 'false'::jsonb) <> 'true'::jsonb) then
    raise exception 'Pick at least one question that is not optional.'
      using errcode = '22023', detail = 'blocker=optional_only in client.schedule_property_intake';
  end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(v_req), auth.jwt() ->> 'email')
  returning id, token, expires_at into v_id, v_token, v_exp;

  -- The bare token is no longer returned (2026-09-27): the Client App uses url only since CA1, and the token
  -- belongs in one place. expires_at lets the office see when the link stops working.
  return jsonb_build_object('ok', true, 'intake_id', v_id, 'url', public.fn_intake_link_url(v_token), 'expires_at', v_exp,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;

CREATE OR REPLACE FUNCTION client.update_client_contact(p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['first_name','last_name','email','phone','contact_role','property_id'];
  v_roles    text[] := array['primary','accounting'];
  v_bad      text[];
  v_row      public.client_contacts;
  v_first    text;
  v_last     text;
  v_email    text;
  v_phone    text;
  v_role     text;
  v_prop     bigint;
  v_prop_txt text;
  v_jobber   boolean;
  v_name     text;
  v_out      public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'edit a contact');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %', v_bad, v_allowed
      using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  -- The ownership boundary (see header).
  v_jobber := v_row.property_id is null and v_row.contact_role = 'primary';
  if v_jobber then
    raise exception 'This is the client''s main contact. Its email and phone are saved through the save-client-contact edge function, which pushes to Jobber first and verifies — a direct write here would be overwritten by the next Jobber poll.'
      using errcode = '42501';
  end if;

  v_first := case when p_patch ? 'first_name'
                  then nullif(btrim(coalesce(p_patch->>'first_name','')),'') else v_row.first_name end;
  v_last  := case when p_patch ? 'last_name'
                  then nullif(btrim(coalesce(p_patch->>'last_name','')),'')  else v_row.last_name end;
  v_email := case when p_patch ? 'email'
                  then nullif(btrim(coalesce(p_patch->>'email','')),'')      else v_row.email end;
  v_phone := case when p_patch ? 'phone'
                  then nullif(btrim(coalesce(p_patch->>'phone','')),'')      else v_row.phone end;
  v_role  := case when p_patch ? 'contact_role'
                  then lower(nullif(btrim(coalesce(p_patch->>'contact_role','')),''))
                  else v_row.contact_role end;

  if p_patch ? 'property_id' then
    v_prop_txt := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
    if v_prop_txt is null then
      v_prop := null;
    else
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
      if not exists (select 1 from public.properties p
                     where p.id = v_prop and p.client_id = v_row.client_id) then
        raise exception 'Property % does not belong to this client.', v_prop
          using errcode = '22023';
      end if;
    end if;
  else
    v_prop := v_row.property_id;
  end if;

  -- Same required set as create: a name, and at least one contact method.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.' using errcode = '22023';
  end if;
  if v_role is null or v_role <> all (v_roles) then
    if v_role = 'city' then
      raise exception 'The City role has been retired. City email addresses now live on the location itself, under City email.'
        using errcode = '22023',
              detail  = 'blocker=contact_role_city_retired value=city';
    end if;
    raise exception 'Pick a role for this contact: Main contact, or Accounting.'
      using errcode = '22023',
            detail  = 'blocker=contact_role_unknown value=' || coalesce(v_role, '(null)');
  end if;
  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- ⚠ Moving a contact TO client-level primary would collide with the
  -- Jobber-synced row (UNIQUE NULLS NOT DISTINCT) or, worse, become one.
  if v_prop is null and v_role = 'primary' then
    raise exception 'This client already has a client-level main contact and there can only be one. Pick a location, or use the accounting role.'
      using errcode = '22023';
  end if;

  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    update public.client_contacts set
      first_name   = v_first,
      last_name    = v_last,
      email        = v_email,
      phone        = v_phone,
      contact_role = v_role,
      property_id  = v_prop,
      -- keep the display value coherent; `name` is what existing readers use
      name         = case when v_name = '' then name else v_name end
    where id = p_contact_id
    returning * into v_out;
  exception when unique_violation then
    raise exception 'That property already has a % contact. Edit that one instead.', v_role
      using errcode = '23505';
  end;

  return to_jsonb(v_out);
end
$function$;

CREATE OR REPLACE FUNCTION client.update_client_fields(p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array['notes','group_id','client_class'];
  v_bad     text[];
  v_row     public.clients;
begin
  perform hr.fn_check_app('client_app', 'edit', 'edit client fields');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for clients: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'group_id' and nullif(p_patch->>'group_id','') is not null then
    if not exists (select 1 from public.client_groups g
                   where g.id = (p_patch->>'group_id')::bigint) then
      raise exception 'client_groups id % does not exist', p_patch->>'group_id'
        using errcode = '23503';
    end if;
  end if;

  -- client_class: a human assertion. Value is strict (no NULL — unclassifying
  -- from the app is not a thing); the write pins the row as manual so the
  -- Jobber poll can never flip it back (trg_clients_protect_manual_class).
  if p_patch ? 'client_class' then
    if coalesce(p_patch->>'client_class','') not in ('commercial','residential') then
      raise exception 'client_class must be ''commercial'' or ''residential'''
        using errcode = '22023';
    end if;
    -- Two-step past the guard: on an already-manual row a single UPDATE that
    -- changes class while keeping source='manual' is SILENTLY reverted by
    -- fn_clients_protect_manual_class. Flip source first (class untouched →
    -- passes), then the main UPDATE sets class + re-pins manual.
    update public.clients
       set client_class_source = 'jobber'
     where id = p_client_id and client_class_source = 'manual';
  end if;

  update public.clients c set
    notes    = case when p_patch ? 'notes'
                    then nullif(p_patch->>'notes','') else c.notes end,
    group_id = case when p_patch ? 'group_id'
                    then nullif(p_patch->>'group_id','')::bigint else c.group_id end,
    client_class = case when p_patch ? 'client_class'
                        then p_patch->>'client_class' else c.client_class end,
    client_class_source = case when p_patch ? 'client_class'
                               then 'manual' else c.client_class_source end
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$function$;

CREATE OR REPLACE FUNCTION client.update_client_status(p_client_id bigint, p_status text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old    text;
  v_row    public.clients;
  v_before int;
  v_after  int;
  v_removed int;
  v_email  text;
  v_change_id bigint;   -- 2026-09-16: the ledger row, so the app can attach reason photos to it
begin
  perform hr.fn_check_app('client_app', 'edit', 'change client status');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- PAUSED added 2026-07-31 (Fred). All four states are now settable.
  if p_status is null or p_status not in ('ACTIVE','RECURRING','INACTIVE','PAUSED') then
    raise exception 'status must be ACTIVE, RECURRING, INACTIVE or PAUSED (got %)', p_status
      using errcode = '22023';
  end if;
  -- The proof is the point: no reason, no change.
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required when changing a client''s status'
      using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'reason is too long (500 characters max)' using errcode = '22023';
  end if;

  -- 2026-09-18: a client deleted in the Jobber UI has no Jobber record to serve it; it stays as
  -- history and only ever moves to INACTIVE. Create the client again instead (a new GID, a new row).
  if p_status <> 'INACTIVE' and exists (
       select 1 from public.client_status_changes s
        where s.client_id = p_client_id and s.event = 'deleted_in_jobber') then
    raise exception 'This client was deleted in Jobber, so it cannot be reactivated here. Create the client again instead; this record stays as history.'
      using errcode = '22023', detail = 'blocker=deleted_in_jobber client_id=' || p_client_id;
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if v_old = p_status then
    select c.* into v_row from public.clients c where c.id = p_client_id;
    return jsonb_build_object('client', to_jsonb(v_row), 'visits_removed', 0, 'noop', true, 'status_change_id', null);
  end if;

  -- ▼▼▼ ADDED 2026-08-01 — THE ONLY CHANGE ▼▼▼
  -- RECURRING requires a current-format SA job that can actually generate
  -- visits. Without one the client sits in RECURRING forever with an empty
  -- schedule and nothing reports it. Checked AFTER the no-op branch so that
  -- re-saving an already-RECURRING client can never be blocked by it.
  if p_status = 'RECURRING' then
    if not exists (
      select 1 from public.jobs j
      where j.client_id = p_client_id
        and j.job_status NOT IN ('archived', 'destroyed')
        and client.fn_is_current_sa_job(j.id)
    ) then
      raise exception
        'cannot set RECURRING: this client has no open Service Agreement job in the current format. Create one, or reopen a closed current-format agreement first.'
        using errcode = '23514';
    end if;
  end if;
  -- ▲▲▲ END OF ADDED BLOCK ▲▲▲

  select count(*) into v_before
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  update public.clients c set status = p_status, status_source = 'manual'
   where c.id = p_client_id
  returning c.* into v_row;          -- AFTER trigger performs the SA cleanup

  select count(*) into v_after
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;
  v_removed := greatest(v_before - v_after, 0);

  insert into public.client_status_changes
    (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed)
  values (p_client_id, v_old, p_status, btrim(p_reason), auth.uid(), v_email, v_removed)
  returning id into v_change_id;

  return jsonb_build_object(
    'client', to_jsonb(v_row),
    'previous_status', v_old,
    'visits_removed', v_removed,
    'status_change_id', v_change_id,
    'note', case when p_status = 'RECURRING'
                 then 'SA visits are generated by the nightly run at 06:00 ET, not on save.'
                 else null end);
end;
$function$;

CREATE OR REPLACE FUNCTION client.update_client_status(p_client_id bigint, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform hr.fn_check_app('client_app', 'edit', 'change client status');   -- 2026-10-21_0900 access phase 5
  raise exception 'a reason is now required: call update_client_status(client_id, status, reason)'
    using errcode = '22023';
end;
$function$;

CREATE OR REPLACE FUNCTION client.update_client_zone(p_client_id bigint, p_zone_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_n    integer;
  v_code text;
begin
  perform hr.fn_check_app('client_app', 'edit', 'change client zone');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if p_zone_id is not null then
    select z.code into v_code from public.zones z where z.id = p_zone_id;
    if v_code is null then
      raise exception 'zones id % does not exist', p_zone_id using errcode = '23503';
    end if;
  end if;

  update public.properties p
     set zone_id = p_zone_id
   where p.client_id = p_client_id
     and p.zone_id is distinct from p_zone_id;
  get diagnostics v_n = row_count;

  return jsonb_build_object(
    'client_id', p_client_id,
    'zone_id', p_zone_id,
    'zone_code', v_code,
    'properties_updated', v_n);
end;
$function$;

CREATE OR REPLACE FUNCTION client.update_property_city_email(p_property_id bigint, p_emails text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_clean text[];
  v_bad   text;
  v_city  text;
begin
  perform hr.fn_check_app('client_app', 'edit', 'edit a city email');   -- 2026-10-21_0900 access phase 5
  if p_property_id is null then
    raise exception 'A property id is required.' using errcode = '22023';
  end if;

  select btrim(p.city) into v_city
    from public.properties p
   where p.id = p_property_id and p.deleted_at is null;

  if not found then
    raise exception 'Property % does not exist.', p_property_id using errcode = '22023';
  end if;

  -- normalise: trim, lower-case, drop blanks, de-duplicate, stable order
  select array_agg(e ORDER BY e)
    into v_clean
    from (select distinct lower(btrim(x)) as e
            from unnest(coalesce(p_emails, '{}'::text[])) as x
           where btrim(x) <> '') s;
  v_clean := coalesce(v_clean, '{}'::text[]);

  select e into v_bad
    from unnest(v_clean) e
   where e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
   limit 1;
  if v_bad is not null then
    raise exception 'That does not look like an email address: %', v_bad using errcode = '22023';
  end if;

  -- 🛑 ONE ROW. The p.id predicate is the whole point of this migration: the previous version
  --    resolved the property's CITY and wrote a shared row, so this same call changed 230
  --    properties across 114 clients.
  update public.properties
     set city_emails = v_clean
   where id = p_property_id;

  return jsonb_build_object(
    'property_id', p_property_id,
    'city',        v_city,
    'emails',      to_jsonb(v_clean)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION client.upsert_gdo_permit(p_gdo_id bigint, p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id'
  ];
  v_bad         text[];
  v_row         public.gdos;
  v_wanted      text;
  v_out         jsonb;
  v_old_status  text;
  v_old_notes   text;
  v_old_client  bigint;
  v_new_notes   text;
  v_marked      boolean;
  v_prop        bigint;
  v_freq        integer;
begin
  perform hr.fn_check_app('client_app', 'edit', 'save a GDO permit');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for gdos: %. Wave 1 allows only %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  v_wanted := nullif(btrim(coalesce(p_patch->>'status','')),'');

  if p_patch ? 'gdo_number'
     and nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
    raise exception 'gdo_number cannot be blank' using errcode = '22023';
  end if;
  if p_patch ? 'status' and v_wanted is null then
    raise exception 'status cannot be blank; expected ACTIVE, EXPIRED or INACTIVE'
      using errcode = '22023';
  end if;
  if v_wanted is not null and v_wanted <> all (array['ACTIVE','EXPIRED','INACTIVE']) then
    raise exception 'status must be one of ACTIVE, EXPIRED, INACTIVE (got %)', v_wanted
      using errcode = '22023';
  end if;
  if p_patch ? 'property_id'
     and nullif(btrim(coalesce(p_patch->>'property_id','')),'') is null then
    raise exception 'property_id cannot be blank; a permit is bound to a location'
      using errcode = '22023';
  end if;
  if p_patch ? 'permit_expiration'
     and nullif(p_patch->>'permit_expiration','') is not null
     and p_patch->>'permit_expiration' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_expiration must be a bare date YYYY-MM-DD, never a timestamp (got %)',
      p_patch->>'permit_expiration' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound. This column drives customer.permits.over_gdo_max
  -- and `compliant`, which the Field Portal shows to the CLIENT, so an inflated
  -- ceiling silently reports a non-compliant site as compliant. Real values are
  -- 30/60/90; 365 is a generous ceiling that still catches 900-for-90.
  if p_patch ? 'max_frequency_days' then
    v_freq := nullif(btrim(coalesce(p_patch->>'max_frequency_days','')),'')::integer;
    if v_freq is not null and (v_freq < 1 or v_freq > 365) then
      raise exception 'max_frequency_days must be between 1 and 365 days (got %). This is the DERM permit ceiling; typical values are 30, 60 or 90.',
        v_freq using errcode = '22023';
    end if;
  end if;

  v_prop := nullif(btrim(coalesce(p_patch->>'property_id','')),'')::bigint;

  if p_gdo_id is null then
    -- ---- ADD ----
    if p_client_id is null then
      raise exception 'p_client_id is required when creating a permit' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
      raise exception 'gdo_number is required when creating a permit' using errcode = '22023';
    end if;
    if v_prop is null then
      raise exception 'property_id is required when creating a permit (a GDO is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.properties pr
                   where pr.id = v_prop and pr.client_id = p_client_id) then
      raise exception 'property % does not belong to client %', v_prop, p_client_id
        using errcode = '23503';
    end if;
    -- Readable duplicate message. The bare 23505 from gdos_client_gdo_unique was
    -- being rendered verbatim to the user, and it is highly reachable in the
    -- PDF-first flow because re-uploading a permit the client already holds hits it.
    if exists (select 1 from public.gdos g
               where g.client_id = p_client_id
                 and g.gdo_number = btrim(p_patch->>'gdo_number')) then
      raise exception 'This client already has permit %. Edit the existing permit instead of adding it again.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    insert into public.gdos (
      client_id, gdo_number, nickname, location_label, permit_expiration,
      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values (
      p_client_id,
      btrim(p_patch->>'gdo_number'),
      nullif(p_patch->>'nickname',''),
      nullif(p_patch->>'location_label',''),
      nullif(p_patch->>'permit_expiration','')::date,
      v_freq,
      nullif(p_patch->>'permit_document_path',''),
      coalesce(v_wanted, 'ACTIVE'),
      nullif(p_patch->>'notes',''),
      v_prop,
      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;
  else
    -- ---- EDIT ----
    select g.status, g.notes, g.client_id
      into v_old_status, v_old_notes, v_old_client
    from public.gdos g where g.id = p_gdo_id for update;
    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;
    if p_client_id is not null and p_client_id <> v_old_client then
      raise exception 'p_client_id % does not match this permit''s client %', p_client_id, v_old_client
        using errcode = '22023';
    end if;
    if v_prop is not null and not exists (
         select 1 from public.properties pr where pr.id = v_prop and pr.client_id = v_old_client) then
      raise exception 'property % does not belong to client %', v_prop, v_old_client
        using errcode = '23503';
    end if;
    if p_patch ? 'gdo_number' and exists (
         select 1 from public.gdos g
         where g.client_id = v_old_client
           and g.gdo_number = btrim(p_patch->>'gdo_number')
           and g.id <> p_gdo_id) then
      raise exception 'This client already has permit %. Two permits for one client cannot share a number.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    -- ⚠⚠ BUG 2 FIX — ONE RULE THAT CLOSES ALL THREE BYPASSES.
    -- On a row whose notes carry DEMOTED/DEDUP evidence:
    --   (i)  notes are APPEND-ONLY  -> closes route B (notes-only disarm) and
    --        route C (5-char "DEDUP" replacing 431 chars of evidence), because
    --        containment of the old text is what the error message already promises;
    --   (ii) any transition TO ACTIVE needs a real append, REGARDLESS of the
    --        current status -> closes route A (INACTIVE->EXPIRED->ACTIVE), which
    --        mattered most because parse-gdo-permit derives EXPIRED for a lapsed
    --        permit and so performed hop 1 automatically.
    v_marked := coalesce(v_old_notes,'') ~* '(DEMOTED|DEDUP)';
    if v_marked then
      v_new_notes := case when p_patch ? 'notes'
                          then nullif(btrim(coalesce(p_patch->>'notes','')),'') end;

      if p_patch ? 'notes' and position(btrim(coalesce(v_old_notes,'')) in coalesce(v_new_notes,'')) = 0 then
        raise exception 'This permit was demoted with recorded evidence, so its notes are append-only. Keep the existing text and add your reason at the end. (The evidence is what stops a wrong permit being silently reactivated.)'
          using errcode = '22023';
      end if;

      if v_wanted = 'ACTIVE' then
        if v_new_notes is null or btrim(coalesce(v_old_notes,'')) = v_new_notes then
          raise exception 'Permit % was demoted with recorded evidence. To reactivate it deliberately, keep the existing notes and append your reason in the same save.',
            p_gdo_id using errcode = '22023';
        end if;
      end if;
    end if;

    update public.gdos g set
      gdo_number = case when p_patch ? 'gdo_number'
                        then btrim(p_patch->>'gdo_number') else g.gdo_number end,
      nickname = case when p_patch ? 'nickname'
                      then nullif(p_patch->>'nickname','') else g.nickname end,
      location_label = case when p_patch ? 'location_label'
                            then nullif(p_patch->>'location_label','') else g.location_label end,
      permit_expiration = case when p_patch ? 'permit_expiration'
                               then nullif(p_patch->>'permit_expiration','')::date
                               else g.permit_expiration end,
      max_frequency_days = case when p_patch ? 'max_frequency_days'
                                then v_freq else g.max_frequency_days end,
      permit_document_path = case when p_patch ? 'permit_document_path'
                                  then nullif(p_patch->>'permit_document_path','')
                                  else g.permit_document_path end,
      status = case when p_patch ? 'status'
                    then v_wanted else g.status end,
      notes = case when p_patch ? 'notes'
                   then nullif(p_patch->>'notes','') else g.notes end,
      property_id = case when p_patch ? 'property_id'
                         then v_prop else g.property_id end,
      client_location_id = case when p_patch ? 'client_location_id'
                                then nullif(p_patch->>'client_location_id','')::bigint
                                else g.client_location_id end
    where g.id = p_gdo_id
    returning g.* into v_row;

    -- The warn-only DB trigger can still rewrite NEW.status; report that honestly
    -- rather than claiming a success the row does not reflect.
    if v_wanted is not null and v_row.status <> v_wanted then
      v_out := to_jsonb(v_row) || jsonb_build_object(
        'status_change_refused', true,
        'requested_status', v_wanted,
        'message', 'A database guard refused this status change because the permit was demoted with recorded evidence.');
      return v_out;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$function$;

CREATE OR REPLACE FUNCTION client.update_property_capacity(p_property_id bigint, p_gallons integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client bigint;
begin
  perform hr.fn_check_any_app(array['client_app', 'picture_planner'], 'edit', 'edit property capacity');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;

  -- 🛑 Writes public.properties, NOT service_configs. The previous body looked up service_configs by
  -- property and INSERTed when it found none, which violated UNIQUE(client_id, service_type) for any
  -- client that already had a Pumping config on a different property (209 properties, 184 clients).
  -- A single UPDATE on the property has no uniqueness to violate.
  update public.properties
     set grease_trap_size_gallons = p_gallons
   where id = p_property_id
  returning client_id into v_client;

  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('property_id', p_property_id, 'gallons', p_gallons);
end
$function$;

CREATE OR REPLACE FUNCTION client.update_property_operational(p_property_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    -- 2026-09-02. Lock Box/Key. Jobber holds this as an ALL_PROPERTIES text custom field
    -- (config 3061112) and it is mirrored into public.lock_box_key by the same shadow sync
    -- that carries the grease trap size. EDITABLE HERE ON PURPOSE (Fred, 2026-09-02), with
    -- the same consequence the capacity field already has: outbound push to Jobber does not
    -- exist, so an edit made here stays here until somebody edits it in Jobber, which then
    -- wins. That is a known, accepted divergence, not an oversight.
    'lock_box_key',
    -- RETIRED 2026-08-07 (Fred: "remove the Default disposal facility, we don't need that").
    -- Deliberately STILL ACCEPTED so a cached bundle that keeps sending the key is not
    -- refused mid-save; it is simply no longer WRITTEN (see the UPDATE list below).
    -- Measured before removing it: 0 of 856 properties ever carried a value.
    'default_disposal_facility_id',
    'access_schedule',  -- NEW 2026-07-30_2103: per-day windows
    'grease_trap_location'  -- NEW 2026-10-16_1530: Inside / Outside (Serena's indoor-trap list)
  ];
  -- The ONLY vocabulary public.properties.access_days uses (verified: 201 rows,
  -- 0 non-conforming). Long names are accepted as ALIASES and normalised down,
  -- so a stale client cannot introduce a second vocabulary.
  v_days     text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_bad      text[];
  v_row      public.properties;
  v_in       text[];
  v_norm     text[];
  v_d        text;
  v_sched    jsonb;
  v_k        text;
  v_open     text;
  v_close    text;
begin
  perform hr.fn_check_any_app(array['client_app', 'picture_planner'], 'edit', 'edit property details');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for properties: %. Wave 1 allows only %. Address fields are Jobber-owned and geofence/lat/long are Samsara-owned; both would be reverted by the inbound sync.',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BUG 1 FIX. Type check first, then VALUE check. The old version stopped at
  -- the type check, which is how ["Monday","Tuesday"] was accepted.
  if p_patch ? 'access_days' then
    if jsonb_typeof(p_patch->'access_days') not in ('array','null') then
      raise exception 'access_days must be a JSON array of day codes (got %)',
        jsonb_typeof(p_patch->'access_days') using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch->'access_days') = 'array' then
      select array_agg(x) into v_in from jsonb_array_elements_text(p_patch->'access_days') x;
      v_norm := array[]::text[];
      foreach v_d in array coalesce(v_in, array[]::text[]) loop
        -- ⚠ A JSON null becomes SQL NULL here, and `NULL <> all(v_days)` evaluates
        -- to NULL rather than true, so the check below would NOT fire and the NULL
        -- would land in the text[]. Caught by the fix's own test run. Reject first.
        if v_d is null then
          raise exception 'access_days cannot contain a null entry' using errcode = '22023';
        end if;
        v_d := lower(btrim(v_d));
        -- accept the long form as an alias, store the canonical short code
        v_d := case v_d
                 when 'monday' then 'mon' when 'tuesday'   then 'tue'
                 when 'wednesday' then 'wed' when 'thursday' then 'thu'
                 when 'friday' then 'fri' when 'saturday'  then 'sat'
                 when 'sunday' then 'sun' else v_d end;
        if v_d <> all (v_days) then
          raise exception 'access_days: % is not a valid day. Use %', v_d, v_days
            using errcode = '22023';
        end if;
        if v_d <> all (v_norm) then v_norm := v_norm || v_d; end if;  -- de-dup
      end loop;
    end if;
  end if;


  -- NEW: access_schedule validation. Object; keys in mon..sun; values
  -- {open:"HH:MM", close:"HH:MM"} 24h. Overnight open>close is legal (into the
  -- next morning), exactly like the legacy single window.
  if p_patch ? 'access_schedule' then
    if jsonb_typeof(p_patch->'access_schedule') = 'null' then
      v_sched := null;
    elsif jsonb_typeof(p_patch->'access_schedule') <> 'object' then
      raise exception 'access_schedule must be an object keyed by day (mon..sun)'
        using errcode = '22023';
    else
      v_sched := p_patch->'access_schedule';
      for v_k in select jsonb_object_keys(v_sched) loop
        if v_k <> all (v_days) then
          raise exception 'access_schedule: % is not a valid day key. Use %', v_k, v_days
            using errcode = '22023';
        end if;
        v_open  := v_sched->v_k->>'open';
        v_close := v_sched->v_k->>'close';
        if v_open is null or v_close is null
           or v_open  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'access_schedule.%: open/close must be 24h "HH:MM" strings', v_k
            using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- A patch that carries the legacy access keys but NO access_schedule can no
  -- longer be honoured: there is nowhere to put it. Silently ignoring it would show
  -- the user "saved" while discarding the edit, so it raises. Only reachable from a
  -- browser tab cached from before access_schedule shipped (2026-07-30); the live
  -- Client App always sends all four keys together (verified in the published bundle).
  if (p_patch ? 'access_hours_start' or p_patch ? 'access_hours_end' or p_patch ? 'access_days')
     and not (p_patch ? 'access_schedule') then
    raise exception 'access hours are now set through access_schedule -- reload the app'
      using errcode = '22023';
  end if;

  -- 2026-10-16_1530, 1745. Inside / Outside / Inside and Outside or empty (stored NULL). Refused here in words; the column CHECK is the backstop.
  if p_patch ? 'grease_trap_location'
     and coalesce(nullif(btrim(p_patch->>'grease_trap_location'),''), 'Inside') not in ('Inside','Outside','Inside and Outside') then
    raise exception 'grease_trap_location must be Inside, Outside, Inside and Outside or empty' using errcode = '22023';
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    -- access_hours_start / access_hours_end / access_days were DROPPED by this
    -- migration. The keys remain ACCEPTED above (removing one makes this RPC refuse
    -- the whole patch, breaking every save from a cached bundle) and are now ignored;
    -- access_schedule is the single store. A legacy-ONLY patch is rejected loudly by
    -- the guard above rather than silently discarded.
    access_schedule = case when p_patch ? 'access_schedule' then v_sched
                           else p.access_schedule end,
    access_notes = case when p_patch ? 'access_notes'
                        then nullif(p_patch->>'access_notes','') else p.access_notes end,
    notes = case when p_patch ? 'notes'
                 then nullif(p_patch->>'notes','') else p.notes end,
    grease_trap_manhole_count = case when p_patch ? 'grease_trap_manhole_count'
                                     then (p_patch->>'grease_trap_manhole_count')::integer
                                     else p.grease_trap_manhole_count end,
    sample_port_count = case when p_patch ? 'sample_port_count'
                             then nullif(p_patch->>'sample_port_count','')::integer
                             else p.sample_port_count end,
    -- btrim then nullif: a field cleared to spaces in the UI stores NULL, not '   ',
    -- so "no lock box" has exactly one representation.
    lock_box_key = case when p_patch ? 'lock_box_key'
                        then nullif(btrim(p_patch->>'lock_box_key'),'')
                        else p.lock_box_key end,
    grease_trap_location = case when p_patch ? 'grease_trap_location'
                                then nullif(btrim(p_patch->>'grease_trap_location'),'')
                                else p.grease_trap_location end
  where p.id = p_property_id
  returning p.* into v_row;

  if not found then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$function$;

CREATE OR REPLACE FUNCTION client.get_client_activity(p_client_id bigint, p_include_system boolean DEFAULT false, p_limit integer DEFAULT NULL::integer, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(key text, at timestamp with time zone, area text, area_label text, subject text, title text, actor_label text, actor_kind text, is_system boolean, changes jsonb, status_card jsonb, cadence_card jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_cid   text := p_client_id::text;
  v_inc   boolean := coalesce(p_include_system, false);
begin
  perform hr.fn_require_app('client_app', 'view');   -- 2026-10-21_0900 access phase 5
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_client_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_client_activity';
  end if;
  if p_client_id is null then
    raise exception 'No client was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_client in client.get_client_activity';
  end if;

  return query
  with
  -- every job the client has or had, so line items of a deleted or moved job still count
  job_ids as (
    select j.id::text as id from public.jobs j where j.client_id = p_client_id
    union
    select l.record_pk ->> 'id' from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'jobs'
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
  ),
  cfg as (
    select c.table_name, c.column_name,
           -- the Calendar's clients labels stay as they are for get_record_history; this reader says it in full
           case when c.table_name = 'clients' and c.column_name = 'client_code' then 'Client code' else c.label end,
           case when c.table_name = 'visits' and c.column_name = 'visit_status' then 'enum' else c.render_type end,
           c.fk_table, c.fk_label_col, c.sort_order, c.is_system
      from audit.entity_render_config c
     -- visits since 2026-10-15 (Fred: "I said to not put the Visits there in the history because each app has their own
     -- activity history, but add it"): the Calendar's visit fields, the Calendar's own labels
     where c.table_name in ('clients','properties','jobs','gdos','client_contacts','client_jobber_contacts',
                            'client_locations','invoices','line_items','visits')
    union all
    -- rendered by the function, never a config row: get_record_history('clients') renders every clients row
    select 'clients', 'primary_contact_ref', 'Primary contact', 'contact_ref', null, null, 70, false
  ),
  -- 1. the audit rows of this client. An explicit table list: never "every row with a client_id".
  --    Every arm stays on this client's rows; nothing below joins back to all of audit.logs.
  raw as (
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'clients' and l.record_pk ->> 'id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public'
       and l.table_name in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                            'client_communication_prefs','invoices')
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
    union all
    -- visits by id (logs_table_record_changed_idx): a client_id filter over every visit row costs a full scan
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'visits'
       and l.record_pk ->> 'id' in (select vi.id::text from public.visits vi where vi.client_id = p_client_id)
       and coalesce(l.new_row, l.old_row) ->> 'client_id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name in ('client_status_changes','job_frequency_changes')
       and l.operation = 'INSERT' and l.new_row ->> 'client_id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'line_items'
       and coalesce(l.new_row, l.old_row) ->> 'job_id' in (select ji.id from job_ids ji)
       and coalesce(l.new_row, l.old_row) ->> 'visit_id' is null
       and coalesce(l.new_row, l.old_row) ->> 'invoice_id' is null
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'property_intake_accepts' and l.operation = 'INSERT'
       and l.new_row ->> 'property_id' in (select pr.id::text from public.properties pr where pr.client_id = p_client_id)
  ),
  -- the Client App creation ledger (not audited): matched by client_id, or by the Jobber gid when client_id is empty
  creation as (
    select a.requested_by from public.client_create_attempts a
     where a.status = 'created'
       and (a.client_id = p_client_id
            or (a.client_id is null and exists (
                  select 1 from public.entity_source_links e
                   where e.entity_type = 'client' and e.source_system = 'jobber'
                     and e.entity_id = p_client_id and e.source_id = a.jobber_client_gid)))
     order by a.created_at limit 1
  ),
  src as (
    select r.id, r.table_name as tbl, r.operation as op, r.old_row as o, r.new_row as n,
           coalesce(r.new_row, r.old_row) as rec, r.changed_at as at, coalesce(r.txid, -r.id) as tx,
           coalesce(r.app_source, '') as app, r.request_context ->> 'path' as path,
           -- who: the JWT email; the intent row's email; actor_name only behind service_role (a free header otherwise);
           -- the creation ledger's requester for the client INSERT
           coalesce(
             nullif(btrim(r.jwt_claims ->> 'email'), ''),
             case when r.table_name in ('client_status_changes','job_frequency_changes') then nullif(btrim(r.new_row ->> 'changed_by_email'), '')
                  when r.table_name = 'property_intake_accepts' then nullif(btrim(r.new_row ->> 'actor'), '') end,
             case when r.jwt_claims ->> 'role' = 'service_role' and coalesce(r.app_source, '') <> 'jobber'
                  then nullif(btrim(r.request_context ->> 'actor_name'), '') end,
             case when r.table_name = 'clients' and r.operation = 'INSERT' then (select cr.requested_by from creation cr) end
           ) as person,
           case when r.app_source = 'jobber' then nullif(btrim(r.request_context ->> 'actor_name'), '') end as jobber_name,
           coalesce(r.app_source, '') in ('jobber','jobber-custom-field-sync') as is_jobber,
           coalesce(r.app_source, '') ~ '(backfill|import|probe|migration|revert|uitest|smoke)' as is_script,
           (coalesce(r.app_source, '') in ('','sql') and r.request_context ->> 'path' is null) as is_direct_sql
      from raw r
  ),
  -- 2. replace-style saves cancel (rule 3.3.1): a DELETE and an INSERT of equal rows, minus id / created_at /
  --    updated_at (and total_price on line items), paired one to one inside a transaction
  di as (
    select s.id, s.tbl, s.op, s.tx, s.at, s.person, s.rec ->> 'job_id' as job_key,
           s.rec - array['id','created_at','updated_at','total_price']::text[] as body
      from src s
     where s.op in ('INSERT','DELETE')
       and s.tbl in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                     'client_communication_prefs','line_items','invoices')
  ),
  di_rank as (
    select d.*, row_number() over (partition by d.tbl, d.tx, md5(d.body::text), d.op order by d.id) as rn from di d
  ),
  cancelled as (
    select a.id from di_rank a
      join di_rank b on b.tbl = a.tbl and b.tx = a.tx and b.body = a.body and b.op <> a.op and b.rn = a.rn
    union
    -- line items also cancel across transactions: the Jobber sync rewrites them in separate requests
    select a.id from di a
      join di b on a.tbl = 'line_items' and b.tbl = 'line_items' and b.job_key = a.job_key and b.body = a.body
             and b.op <> a.op and b.tx <> a.tx and a.person is null and b.person is null
             and b.at between a.at - interval '2 minutes' and a.at + interval '2 minutes'
  ),
  -- what is left of a line-item replace that DID change something pairs up into one "changed" row
  li_left as (
    select d.*, row_number() over (partition by d.tx, d.job_key, d.body ->> 'name', d.op order by d.id) as rn
      from di d where d.tbl = 'line_items' and d.id not in (select c.id from cancelled c)
  ),
  li_pairs as (
    select del.id as del_id, ins.id as ins_id
      from li_left del
      join li_left ins on del.op = 'DELETE' and ins.op = 'INSERT' and ins.tx = del.tx and ins.job_key = del.job_key
                      and ins.body ->> 'name' = del.body ->> 'name' and ins.rn = del.rn
  ),
  members as (
    select s.id, s.tbl,
           case when lp.ins_id is not null then 'UPDATE' else s.op end as op,
           case when lp.ins_id is not null then dd.rec else s.o end as o,
           s.n, s.rec, s.at, s.tx, s.app, s.path, s.person, s.jobber_name, s.is_jobber, s.is_script, s.is_direct_sql,
           (s.tbl = 'invoices' and s.op = 'UPDATE' and s.o ->> 'client_id' is null and s.n ->> 'client_id' is not null) as is_inv_created
      from src s
      left join li_pairs lp on lp.ins_id = s.id
      left join src dd on dd.id = lp.del_id
     where s.id not in (select c.id from cancelled c)
       and s.id not in (select lp2.del_id from li_pairs lp2)
  ),
  -- a person-less writer that touched 20 or more clients in the hour around this row is bookkeeping
  burst as (
    select m.id from members m
     where m.person is null and m.op <> 'DELETE' and not m.is_script and not m.is_direct_sql
       and m.tbl not in ('client_status_changes','job_frequency_changes','property_intake_accepts')
       and (select count(distinct case l.table_name
                                    when 'clients' then l.record_pk ->> 'id'
                                    when 'line_items' then (select jj.client_id::text from public.jobs jj
                                                             where jj.id = (coalesce(l.new_row, l.old_row) ->> 'job_id')::bigint)
                                    else coalesce(l.new_row, l.old_row) ->> 'client_id' end)
              from audit.logs l
             where l.table_name = m.tbl
               and l.changed_at between m.at - interval '30 minutes' and m.at + interval '30 minutes'
               and coalesce(l.app_source, '') = m.app
               and coalesce(l.request_context ->> 'path', '') = coalesce(m.path, '')) >= 20
  ),
  -- 3. field changes of UPDATE rows (composites compare all their columns)
  upd as (
    select m.id as mid, f.column_name as col, f.label, f.render_type, f.fk_table, f.fk_label_col, f.sort_order,
           coalesce(f.is_system, false) as cfg_sys,
           case f.render_type
             when 'address'  then jsonb_build_array(m.o -> 'address', m.o -> 'city', m.o -> 'zip')
             when 'pin'      then jsonb_build_array(m.o -> 'latitude', m.o -> 'longitude')
             when 'geofence' then jsonb_build_array(m.o -> 'geofence_type', m.o -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.o -> 'person_role', m.o -> 'person_role_other')
             else m.o -> f.column_name end as ov,
           case f.render_type
             when 'address'  then jsonb_build_array(m.n -> 'address', m.n -> 'city', m.n -> 'zip')
             when 'pin'      then jsonb_build_array(m.n -> 'latitude', m.n -> 'longitude')
             when 'geofence' then jsonb_build_array(m.n -> 'geofence_type', m.n -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.n -> 'person_role', m.n -> 'person_role_other')
             else m.n -> f.column_name end as nv
      from members m join cfg f on f.table_name = m.tbl
     where m.op = 'UPDATE'
  ),
  ch0 as (
    select u.*, m.tbl, m.at, m.person, m.rec
      from upd u join members m on m.id = u.mid
     where audit.fn_activity_norm(u.ov) is distinct from audit.fn_activity_norm(u.nv)
       -- the status card carries the same move with its reason and person
       and not (m.tbl = 'clients' and u.col = 'status' and exists (
             select 1 from public.client_status_changes c
              where c.client_id = p_client_id and c.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
       -- the cadence card carries the same change (the client.job_activity rule)
       and not (m.tbl = 'jobs' and u.col = 'frequency_days' and exists (
             select 1 from public.job_frequency_changes f
              where f.job_id = (m.rec ->> 'id')::bigint and f.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
  ),
  -- 4. job status chains (rule 3.3.4): person-less legs on one job, each within 2 minutes of the last, become
  --    one net change on the first leg; a chain that ends where it began disappears
  js as (
    select c.mid, c.at, c.rec ->> 'id' as job_id, c.ov, c.nv,
           case when lag(c.at) over w is null or c.at - lag(c.at) over w > interval '2 minutes' then 1 else 0 end as brk
      from ch0 c where c.tbl = 'jobs' and c.col = 'job_status' and c.person is null
    window w as (partition by c.rec ->> 'id' order by c.at, c.mid)
  ),
  js2 as (select js.*, sum(js.brk) over (partition by js.job_id order by js.at, js.mid) as chain from js),
  js3 as (
    select js2.mid, js2.job_id, js2.chain,
           first_value(js2.ov) over cw as chain_ov, last_value(js2.nv) over cw as chain_nv,
           row_number() over (partition by js2.job_id, js2.chain order by js2.at, js2.mid) as leg
      from js2
    window cw as (partition by js2.job_id, js2.chain order by js2.at, js2.mid rows between unbounded preceding and unbounded following)
  ),
  ch as (
    select c.mid, c.col, c.label, c.render_type, c.fk_table, c.fk_label_col, c.sort_order, c.cfg_sys,
           coalesce(j.chain_ov, c.ov) as ov, coalesce(j.chain_nv, c.nv) as nv
      from ch0 c
      left join js3 j on j.mid = c.mid and c.col = 'job_status' and c.tbl = 'jobs'
     where j.mid is null
        or (j.leg = 1 and audit.fn_activity_norm(j.chain_ov) is distinct from audit.fn_activity_norm(j.chain_nv))
  ),
  -- 5. each change rendered, and whether it is bookkeeping (rule 3.4)
  crow as (
    select c.mid, c.col, c.label, c.sort_order, c.render_type,
           audit.fn_activity_value(c.ov, c.render_type, c.fk_table, c.fk_label_col) as old_txt,
           audit.fn_activity_value(c.nv, c.render_type, c.fk_table, c.fk_label_col) as new_txt,
           c.col in ('notes','access_notes') as long,
           c.ov #>> '{}' as ov_s, c.nv #>> '{}' as nv_s,
           case
             when m.person is not null then false
             -- never background: key moves of a job, invoice key events, the creation of an invoice
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and (coalesce(c.ov #>> '{}', '') in ('archived','closed','destroyed','active')
                       or coalesce(c.nv #>> '{}', '') in ('archived','closed','destroyed','active')) then false
             when m.tbl = 'invoices' and c.col = 'invoice_status'
                  and (c.nv #>> '{}' in ('paid','voided','bad_debt','destroyed')
                       or (c.nv #>> '{}' = 'awaiting_payment' and coalesce(c.ov #>> '{}', 'draft') = 'draft')) then false
             when m.is_inv_created and c.col in ('invoice_status','total') then false
             when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
             when c.cfg_sys then true
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and c.ov #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing')
                  and c.nv #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing') then true
             when m.tbl = 'invoices' and c.col = 'invoice_status' then true
             when m.tbl = 'invoices' and m.o ->> 'invoice_status' = 'draft' and m.n ->> 'invoice_status' = 'draft' then true
             else false
           end as sys
      from ch c join members m on m.id = c.mid
     where c.render_type <> 'removed'
  ),
  rem as (
    select c.mid, audit.fn_activity_norm(c.nv) is not null as removed_now from ch c where c.render_type = 'removed'
  ),
  cagg as (
    select c.mid, count(*) as n_ch,
           (array_agg(c.label order by c.sort_order))[1] as first_label,
           (array_agg(c.long order by c.sort_order))[1] as first_long,
           (array_agg(c.old_txt is null order by c.sort_order))[1] as first_old_empty,
           (array_agg(c.render_type order by c.sort_order))[1] as first_type,
           (array_agg(c.col order by c.sort_order))[1] as first_col,
           max(c.nv_s) filter (where c.col = 'job_status') as js_new,
           max(c.ov_s) filter (where c.col = 'job_status') as js_old,
           bool_and(c.sys) as all_sys
      from crow c group by c.mid
  ),
  pia as (
    select m.id, m.at, m.tx, m.n ->> 'property_id' as property_id, (m.n ->> 'intake_id')::bigint as intake_id
      from members m where m.tbl = 'property_intake_accepts'
  ),
  -- 6. one row per kept record change: area, subject, title, bookkeeping flag
  mrow as (
    select m.id as mid, m.tbl, m.op, m.at, m.tx, m.app, m.person, m.jobber_name, m.is_jobber,
           case when m.tbl in ('clients','client_status_changes') then 'client'
                when m.tbl = 'properties' then 'property'
                when m.tbl in ('jobs','line_items','job_frequency_changes') then 'job'
                when m.tbl = 'gdos' then 'gdo'
                when m.tbl = 'invoices' then 'invoice'
                when m.tbl = 'visits' then 'visit'
                else 'contacts' end as area,
           case m.tbl when 'client_status_changes' then 1 when 'jobs' then 2 when 'line_items' then 2 when 'visits' then 2
                      when 'job_frequency_changes' then 2 when 'properties' then 3 when 'client_contacts' then 4
                      when 'client_jobber_contacts' then 4 when 'client_communication_prefs' then 4
                      when 'client_locations' then 4 when 'gdos' then 5 when 'invoices' then 6 else 7 end as rank,
           case when m.tbl = 'client_communication_prefs'
                then 'contact:' || coalesce(m.rec ->> 'contact_id', 'j' || (m.rec ->> 'jobber_contact_id'), m.id::text)
                else m.tbl || ':' || coalesce(case when m.tbl = 'line_items' then m.rec ->> 'job_id' else m.rec ->> 'id' end, m.id::text)
           end as rec_key,
           case
             when m.tbl = 'clients' then null
             when m.tbl = 'client_status_changes' then null
             when m.tbl = 'properties' then coalesce(nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'name'), ''), 'Property #' || (m.rec ->> 'id'))
                                            || coalesce(' (' || nullif(btrim(m.rec ->> 'name'), '') || ')', '')
             when m.tbl = 'jobs' then '#' || coalesce(m.rec ->> 'job_number', m.rec ->> 'id') || coalesce(' ' || nullif(btrim(m.rec ->> 'title'), ''), '')
             when m.tbl in ('line_items','job_frequency_changes') then (
                    select '#' || coalesce(jj.job_number, jj.id::text) || coalesce(' ' || nullif(btrim(jj.title), ''), '')
                      from public.jobs jj where jj.id = (m.rec ->> 'job_id')::bigint)
             when m.tbl = 'gdos' then coalesce(nullif(btrim(m.rec ->> 'gdo_number'), ''), 'GDO permit #' || (m.rec ->> 'id'))
             when m.tbl = 'invoices' then 'Invoice #' || coalesce(m.rec ->> 'invoice_number', m.rec ->> 'id')
             when m.tbl = 'visits' then 'Visit ' || coalesce(to_char((m.rec ->> 'visit_date')::date, 'Mon FMDD, YYYY'), 'with no date')
                                        || ' (#' || (m.rec ->> 'id') || ')'
             when m.tbl in ('client_contacts','client_jobber_contacts') then coalesce(nullif(btrim(m.rec ->> 'name'), ''), m.rec ->> 'email', 'Contact #' || (m.rec ->> 'id'))
             when m.tbl = 'client_locations' then coalesce(nullif(btrim(m.rec ->> 'name'), ''), 'Location #' || (m.rec ->> 'id'))
             when m.tbl = 'client_communication_prefs' then coalesce(
                    (select coalesce(nullif(btrim(cc.name), ''), cc.email) from public.client_contacts cc where cc.id = (m.rec ->> 'contact_id')::bigint),
                    (select coalesce(nullif(btrim(jc.name), ''), jc.email) from public.client_jobber_contacts jc where jc.id = (m.rec ->> 'jobber_contact_id')::bigint),
                    'A contact no longer on file')
           end as subject,
           case
             when m.tbl = 'client_status_changes' then
               case m.n ->> 'event' when 'archived' then 'Client archived' when 'archived_here_only' then 'Client archived here only'
                                    when 'deleted_in_jobber' then 'Client deleted in Jobber' else 'Status changed' end
             when m.tbl = 'job_frequency_changes' then 'Frequency changed'
             when m.tbl = 'client_communication_prefs' then 'Who receives what changed'
             when m.op = 'INSERT' then
               case m.tbl when 'clients' then 'Client created' when 'properties' then 'Property added' when 'jobs' then 'Job added'
                          when 'gdos' then 'GDO permit added' when 'client_locations' then 'Location added'
                          when 'line_items' then 'Line item added' when 'invoices' then 'Invoice created'
                          when 'visits' then 'Visit added' else 'Contact added' end
             when m.op = 'DELETE' then
               case m.tbl when 'clients' then 'Client removed' when 'properties' then 'Property removed' when 'jobs' then 'Job removed'
                          when 'gdos' then 'GDO permit removed' when 'client_locations' then 'Location removed'
                          when 'line_items' then 'Line item removed' when 'invoices' then 'Invoice removed'
                          when 'visits' then 'Visit removed' else 'Contact removed' end
             when r.mid is not null then
               case m.tbl when 'properties' then 'Property' when 'client_jobber_contacts' then 'Contact' else 'Record' end
               || case when r.removed_now then ' removed' else ' restored' end
             when m.is_inv_created then 'Invoice created'
             when m.tbl = 'properties' and pa.intake_id is not null then 'Accepted from Site survey form #' || pa.intake_id
             when m.tbl = 'invoices' and a.js_new is null and (m.o ->> 'invoice_status') is distinct from (m.n ->> 'invoice_status') then
               case when m.n ->> 'invoice_status' = 'paid' then 'Invoice paid'
                    when m.n ->> 'invoice_status' = 'awaiting_payment' and coalesce(m.o ->> 'invoice_status', 'draft') = 'draft' then 'Invoice sent'
                    when m.n ->> 'invoice_status' = 'voided' then 'Invoice voided'
                    when m.n ->> 'invoice_status' = 'bad_debt' then 'Invoice marked bad debt'
                    when m.n ->> 'invoice_status' = 'destroyed' then 'Invoice deleted in Jobber'
                    else 'Invoice status changed' end
             when a.js_new is not null then
               case when a.js_new = 'archived' then 'Archived' when a.js_new = 'closed' then 'Closed'
                    when a.js_new = 'destroyed' then 'Deleted in Jobber'
                    when a.js_old in ('archived','closed','destroyed') then 'Reopened'
                    else 'Status changed' end
             when m.tbl = 'line_items' and m.op = 'UPDATE' then 'Line item changed'
             -- a visit's key moves get their own title (the change lines still say every field)
             when m.tbl = 'visits' and m.o ->> 'deleted_at' is null and m.n ->> 'deleted_at' is not null then 'Visit deleted'
             when m.tbl = 'visits' and m.o ->> 'deleted_at' is not null and m.n ->> 'deleted_at' is null then 'Visit restored'
             when m.tbl = 'visits' and (m.o ->> 'visit_status') is distinct from (m.n ->> 'visit_status') then
               case when m.n ->> 'visit_status' = 'completed' then 'Visit completed'
                    when m.n ->> 'visit_status' = 'cancelled' then 'Visit cancelled'
                    when m.n ->> 'visit_status' = 'skipped' then 'Visit skipped'
                    when m.o ->> 'visit_status' in ('completed','cancelled','skipped') then 'Visit reopened'
                    else 'Visit status changed' end
             when a.n_ch = 1 and a.first_type = 'changed' then a.first_label || case when a.first_col = 'permit_document_path' then ' replaced' else ' changed' end
             when a.n_ch = 1 then a.first_label || case when a.first_long then ' edited' when a.first_old_empty then ' set' else ' changed' end
             else case m.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                             when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'invoices' then 'Invoice'
                             when 'visits' then 'Visit' else 'Contact' end || ' details changed'
           end as title,
           -- bookkeeping at the record level
           case
             when m.tbl in ('client_status_changes','job_frequency_changes') then false
             when m.op = 'DELETE' then false
             when r.mid is not null then false
             when m.is_inv_created then false
             when m.op = 'INSERT' then
               case when m.tbl in ('clients','invoices') then false
                    when m.person is not null then false
                    when m.tbl = 'client_jobber_contacts' then true
                    when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
                    else false end
             else coalesce(a.all_sys, true)
           end as member_sys,
           case when m.tbl = 'client_status_changes' then (
             select jsonb_build_object('id', sc.id, 'event', sc.event, 'old_status', sc.old_status, 'new_status', sc.new_status,
                                       'reason', sc.reason, 'visits_removed', sc.visits_removed, 'photo_count', sc.photo_count,
                                       'changed_by_label', case when sc.changed_by_email is null then 'Jobber'
                                                                when public.fn_page_staff_name(sc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(sc.changed_by_email) end)
               from client.status_changes sc where sc.id = (m.n ->> 'id')::bigint) end as status_card,
           case when m.tbl = 'job_frequency_changes' then (
             select jsonb_build_object('id', fc.id, 'job_id', fc.job_id, 'old_frequency_days', fc.old_frequency_days,
                                       'new_frequency_days', fc.new_frequency_days, 'reason', fc.reason, 'proof_count', fc.proof_count,
                                       'changed_by_label', case when fc.changed_by_email is null then 'System'
                                                                when public.fn_page_staff_name(fc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(fc.changed_by_email) end)
               from client.job_frequency_changes fc where fc.id = (m.n ->> 'id')::bigint) end as cadence_card,
           a.n_ch
      from members m
      left join cagg a on a.mid = m.id
      left join rem r on r.mid = m.id
      left join lateral (
        select p.intake_id from pia p
         where m.tbl = 'properties' and m.op = 'UPDATE' and p.property_id = m.rec ->> 'id'
           and (p.tx = m.tx or p.at between m.at - interval '10 seconds' and m.at + interval '10 seconds')
         order by p.id limit 1) pa on true
     where m.tbl <> 'property_intake_accepts'
       -- an UPDATE with nothing left to show is not an entry (a card, an insert, a delete or a removal always is)
       and (m.op <> 'UPDATE' or m.tbl in ('client_status_changes','job_frequency_changes')
            or coalesce(a.n_ch, 0) > 0 or r.mid is not null or m.is_inv_created)
  ),
  -- the card rows exist through their audit INSERT, so the live card must still be there
  mrow_live as (
    select * from mrow mr
     where not (mr.tbl = 'client_status_changes' and mr.status_card is null)
       and not (mr.tbl = 'job_frequency_changes' and mr.cadence_card is null)
  ),
  -- 7. the change lines: field changes, plus one summary line for an insert or a delete
  lines as (
    select c.mid, c.sort_order as ord, c.sys, c.label, mr.subject,
           jsonb_build_object('subject', mr.subject, 'label', c.label,
                              'old', case when c.render_type = 'changed' then null else coalesce(c.old_txt, 'Not set') end,
                              'new', case when c.render_type = 'changed' then null else coalesce(c.new_txt, 'Not set') end,
                              'is_system', c.sys, 'long', c.long) as line,
           c.old_txt, c.new_txt, mr.tbl, c.col
      from crow c join mrow_live mr on mr.mid = c.mid
     where mr.op = 'UPDATE'
    union all
    select mr.mid, 0, mr.member_sys,
           case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                 when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                 when 'invoices' then 'Invoice' when 'visits' then 'Visit' else 'Contact' end end,
           mr.subject,
           jsonb_build_object('subject', mr.subject,
             'label', case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                           else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                            when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                            when 'invoices' then 'Invoice' when 'visits' then 'Visit' else 'Contact' end end,
             'old', case when mr.op = 'DELETE' then sm.summary end,
             'new', case when mr.op = 'INSERT' then sm.summary end,
             'is_system', mr.member_sys, 'long', false),
           null::text, null::text, mr.tbl, null::text
      from mrow_live mr
      join members m on m.id = mr.mid
      cross join lateral (
        select case mr.tbl
                 when 'clients' then concat_ws(' ', m.rec ->> 'client_code', m.rec ->> 'name')
                 when 'properties' then concat_ws(', ', nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'city'), ''))
                 when 'jobs' then concat_ws(' ', '#' || (m.rec ->> 'job_number'), m.rec ->> 'title')
                 when 'gdos' then concat_ws(' ', m.rec ->> 'gdo_number', nullif(btrim(m.rec ->> 'location_label'), ''))
                 when 'client_locations' then m.rec ->> 'name'
                 when 'line_items' then concat(m.rec ->> 'name', ' (', coalesce(m.rec ->> 'quantity', '1'), ' x ',
                                               coalesce(audit.render_value(m.rec -> 'unit_price', 'money', null, null), '$0.00'), ')')
                 when 'client_communication_prefs' then
                   case m.rec ->> 'comm_type' when 'invoice' then 'Invoices' when 'quote_approval' then 'Quote approvals'
                                              when 'service_report' then 'Service reports' when 'city_report' then 'City reports'
                                              else m.rec ->> 'comm_type' end
                   || coalesce(' (' || (select coalesce(nullif(btrim(pp.address), ''), pp.name) from public.properties pp
                                         where pp.id = (m.rec ->> 'property_id')::bigint) || ')', '')
                 when 'invoices' then concat_ws(' ', 'Invoice #' || (m.rec ->> 'invoice_number'))
                 when 'visits' then concat_ws(' · ', to_char((m.rec ->> 'visit_date')::date, 'Mon FMDD, YYYY'), nullif(btrim(m.rec ->> 'title'), ''))
                 else concat_ws(' · ', nullif(btrim(m.rec ->> 'name'), ''), nullif(btrim(m.rec ->> 'email'), ''), nullif(btrim(m.rec ->> 'phone'), ''))
               end as summary) sm
     where mr.op in ('INSERT','DELETE')
       -- a status or cadence card is the whole entry: no summary line under it
       and mr.tbl not in ('client_status_changes','job_frequency_changes')
  ),
  -- 8. one save is one entry (rule 3.3.2): a transaction is a group; groups of the same writer starting within
  --    5 s of each other chain; two groups naming different people never chain
  g as (
    select mr.tx, min(mr.at) as start, min(mr.app) as app,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           min(mr.mid) as first_mid
      from mrow_live mr group by mr.tx
  ),
  g1 as (
    select g.*, lag(g.start) over o as prev_start, lag(g.app) over o as prev_app
      from g window o as (order by g.start, g.first_mid)
  ),
  g2 as (
    select g1.*, sum(case when g1.prev_start is null or g1.app <> g1.prev_app or g1.start - g1.prev_start > interval '5 seconds'
                          then 1 else 0 end) over (order by g1.start, g1.first_mid) as tchain
      from g1
  ),
  g3 as (
    select g2.*, array_remove(array_agg(g2.person) over (partition by g2.tchain order by g2.start, g2.first_mid
                                                         rows between unbounded preceding and 1 preceding), null) as prev_persons
      from g2
  ),
  g4 as (
    select g3.tx, g3.tchain, g3.person,
           sum(case when g3.person is not null and g3.prev_persons is not null and cardinality(g3.prev_persons) > 0
                         and g3.prev_persons[cardinality(g3.prev_persons)] <> g3.person then 1 else 0 end)
             over (partition by g3.tchain order by g3.start, g3.first_mid) as sub
      from g3
  ),
  ent_of as (select g4.tx, g4.tchain || '.' || g4.sub as eid from g4),
  -- the same zone move on several properties of one entry reads "on N sites" (rule 3.3.5)
  lines_e as (
    select e.eid, l.*,
           count(*) over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt) as same_n,
           row_number() over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt order by l.mid) as same_rn
      from lines l join mrow_live mr on mr.mid = l.mid join ent_of e on e.tx = mr.tx
  ),
  lines_z as (
    select le.eid, le.mid, le.ord, le.sys,
           case when le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1
                then jsonb_set(jsonb_set(le.line, '{new}', to_jsonb(coalesce(le.new_txt, 'Not set') || ' on ' || le.same_n || ' sites')),
                               '{subject}', 'null'::jsonb)
                else le.line end as line
      from lines_e le
     where not (le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1 and le.same_rn > 1)
  ),
  ent as (
    select e.eid,
           min(mr.at) as at,
           (array_agg(case when mr.tbl = 'client_status_changes' then 'csc:' || (mr.status_card ->> 'id')
                           when mr.tbl = 'job_frequency_changes' then 'jfc:' || (mr.cadence_card ->> 'id')
                           else 'a:' || mr.mid end order by mr.at, mr.mid))[1] as key,
           (array_agg(mr.area order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as area,
           (array_agg(mr.subject order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as subject1,
           (array_agg(mr.title order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as title,
           count(distinct mr.rec_key) filter (where v_inc or not mr.member_sys) as n_records,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           bool_or(mr.is_jobber) as any_jobber,
           max(mr.jobber_name) as jobber_name,
           (array_agg(mr.app order by mr.at, mr.mid) filter (where mr.app in ('client-app','picture-planner')))[1] as app_nobody,
           bool_and(mr.member_sys) as is_system,
           (array_agg(mr.status_card order by mr.at, mr.mid) filter (where mr.status_card is not null))[1] as status_card,
           (array_agg(mr.cadence_card order by mr.at, mr.mid) filter (where mr.cadence_card is not null))[1] as cadence_card
      from mrow_live mr join ent_of e on e.tx = mr.tx
     group by e.eid
  ),
  ent_lines as (
    select lz.eid, jsonb_agg(lz.line order by mr.member_sys, mr.rank, mr.at, lz.mid, lz.ord) as changes
      from lines_z lz join mrow_live mr on mr.mid = lz.mid
     where v_inc or not lz.sys
     group by lz.eid
  ),
  audit_entries as (
    select en.key, en.at, en.area,
           en.subject1 || case when en.n_records > 1 then ' and ' || (en.n_records - 1) || ' more' else '' end as subject,
           en.title,
           case when en.person is not null then
                  case when public.fn_page_staff_name(en.person) like '%@%' then 'Staff (no name on file)' else public.fn_page_staff_name(en.person) end
                when en.any_jobber then 'Jobber' || coalesce(' · ' || en.jobber_name, '')
                when en.app_nobody = 'client-app' then 'Client App (person not recorded)'
                when en.app_nobody = 'picture-planner' then 'Picture Planner (person not recorded)'
                else 'System' end as actor_label,
           case when en.person is not null then 'person' when en.any_jobber then 'jobber'
                when en.app_nobody is not null then 'app' else 'system' end as actor_kind,
           en.is_system, coalesce(el.changes, '[]'::jsonb) as changes, en.status_card, en.cadence_card
      from ent en left join ent_lines el on el.eid = en.eid
  ),
  -- 9. property events (forms, site file) from the property reader; an accepted answer is already the property diff
  prop_events as (
    select 'pe:' || pr.id || ':' || (ev ->> 'kind') || ':' || coalesce(ev ->> 'intake_id', ev ->> 'version', '') || ':' || (ev ->> 'at') as key,
           (ev ->> 'at')::timestamptz as at, 'property' as area,
           coalesce(nullif(btrim(pr.address), ''), nullif(btrim(pr.name), ''), 'Property #' || pr.id) as subject,
           case ev ->> 'kind'
             when 'form_requested' then 'Site survey form #' || (ev ->> 'intake_id') || ' requested'
             when 'form_link_shown' then 'Link to site survey form #' || (ev ->> 'intake_id') || ' shown'
             when 'form_filled' then 'Site survey form #' || (ev ->> 'intake_id') || ' filled in'
             when 'form_cancelled' then 'Site survey form #' || (ev ->> 'intake_id') || ' cancelled'
             when 'page_submitted' then 'Version ' || (ev ->> 'version') || ' of the site file submitted for approval'
             when 'page_approved' then 'Version ' || (ev ->> 'version') || ' of the site file approved'
             when 'driver_link_created' then 'Site file link created'
             when 'driver_link_replaced' then 'Site file link replaced'
             else ev ->> 'text' end as title,
           case when ev ->> 'kind' = 'form_filled' then coalesce(nullif(btrim(ev ->> 'who'), ''), 'Someone') || ' (name typed on the form)'
                when nullif(btrim(ev ->> 'who'), '') is null then 'System'
                when ev ->> 'who' like '%@%' then 'Staff (no name on file)'
                else ev ->> 'who' end as actor_label,
           case when ev ->> 'kind' = 'form_filled' then 'form'
                when nullif(btrim(ev ->> 'who'), '') is null then 'system' else 'person' end as actor_kind,
           (ev ->> 'kind') = 'form_link_shown' as is_system,
           '[]'::jsonb as changes, null::jsonb as status_card, null::jsonb as cadence_card
      from public.properties pr
      cross join lateral jsonb_array_elements(client.get_property_activity(pr.id)) ev
     where pr.client_id = p_client_id and ev ->> 'kind' <> 'intake_accepted'
  ),
  -- 10. notes not tied to a visit (Jobber), at their own date
  note_entries as (
    select 'note:' || nt.id as key, coalesce(nt.note_date, nt.created_at) as at, 'note' as area, null::text as subject,
           'Note added' as title, 'Jobber' || coalesce(' · ' || nullif(btrim(nt.author_name), ''), '') as actor_label,
           'jobber' as actor_kind, false as is_system,
           case when nullif(btrim(nt.body), '') is null then '[]'::jsonb
                -- a note is new text, never "edited": long stays false and the app wraps it
                else jsonb_build_array(jsonb_build_object('subject', null, 'label', 'Note', 'old', null, 'new', nt.body,
                                                          'is_system', false, 'long', false)) end as changes,
           null::jsonb as status_card, null::jsonb as cadence_card
      from public.notes nt
     where nt.client_id = p_client_id and nt.visit_id is null
  ),
  -- 11. one "on record" entry per record that existed before its own history began (Fred, 2026-10-15: "did you also
  --     added when a job was created since early entry? and so on with other data from the client too?" then "yes
  --     build it that way"). A record whose FIRST audit row is not its INSERT (or that has none) has no "added" entry, so
  --     its story would start mid-way. The entry sits at the record's created_at (when it reached our database) and shows
  --     the EARLIEST state we hold: the old row of its first audit row, else the row as it is now (no row: never changed).
  --     A record created before its table's history began adds "Changes recorded from: <date>", so the entry never
  --     claims more than we know. Old visits and invoices are background (about 3,200 across all clients would bury the
  --     rest); clients, properties, jobs and contacts show. The Client App draws "Start of this record. Nothing earlier."
  --     under any entry whose key starts with 'start:'. Replaces the frequency-only "Starting frequency" entry
  --     (2026-10-15_1257 / _1343): a job's entry carries its frequency. Lines never repeat the subject.
  start_recs as (
    select 'clients'::text as tbl, c.id, c.created_at, to_jsonb(c) as cur from public.clients c where c.id = p_client_id
    union all select 'properties', p.id, p.created_at, to_jsonb(p) from public.properties p where p.client_id = p_client_id
    union all select 'jobs', j.id, j.created_at, to_jsonb(j) from public.jobs j where j.client_id = p_client_id
    union all select 'client_contacts', cc.id, cc.created_at, to_jsonb(cc) from public.client_contacts cc where cc.client_id = p_client_id
    union all select 'visits', vi.id, vi.created_at, to_jsonb(vi) from public.visits vi where vi.client_id = p_client_id
    union all select 'invoices', i.id, i.created_at, to_jsonb(i) from public.invoices i where i.client_id = p_client_id
  ),
  start_hist as (
    select t.tbl, (select min(l.changed_at) from audit.logs l where l.table_schema = 'public' and l.table_name = t.tbl) as since
      from (values ('clients'), ('properties'), ('jobs'), ('client_contacts'), ('visits'), ('invoices')) t(tbl)
  ),
  start_snap as (
    select r.tbl, r.id, r.created_at, coalesce(fa.old_row, r.cur) as s, h.since
      from start_recs r
      join start_hist h on h.tbl = r.tbl
      left join lateral (
        select l.operation as op, l.old_row from audit.logs l
         where l.table_schema = 'public' and l.table_name = r.tbl and l.record_pk ->> 'id' = r.id::text
         order by l.changed_at, l.id limit 1) fa on true
     where fa.op is distinct from 'INSERT' and r.created_at is not null
  ),
  start_entries as (
    select 'start:' || ss.tbl || ':' || ss.id as key, ss.created_at as at,
           case ss.tbl when 'clients' then 'client' when 'properties' then 'property' when 'jobs' then 'job'
                       when 'visits' then 'visit' when 'invoices' then 'invoice' else 'contacts' end as area,
           case ss.tbl
             when 'clients' then null
             when 'properties' then coalesce(nullif(btrim(ss.s ->> 'address'), ''), nullif(btrim(ss.s ->> 'name'), ''), 'Property #' || ss.id)
                                    || coalesce(' (' || nullif(btrim(ss.s ->> 'name'), '') || ')', '')
             when 'jobs' then '#' || coalesce(ss.s ->> 'job_number', ss.id::text) || coalesce(' ' || nullif(btrim(ss.s ->> 'title'), ''), '')
             when 'visits' then 'Visit ' || coalesce(to_char((ss.s ->> 'visit_date')::date, 'Mon FMDD, YYYY'), 'with no date') || ' (#' || ss.id || ')'
             when 'invoices' then 'Invoice #' || coalesce(ss.s ->> 'invoice_number', ss.id::text)
             else coalesce(nullif(btrim(ss.s ->> 'name'), ''), ss.s ->> 'email', 'Contact #' || ss.id)
           end as subject,
           case ss.tbl when 'clients' then 'Client on record' when 'properties' then 'Property on record' when 'jobs' then 'Job on record'
                       when 'visits' then 'Visit on record' when 'invoices' then 'Invoice on record' else 'Contact on record' end as title,
           'System' as actor_label, 'system' as actor_kind, ss.tbl in ('visits','invoices') as is_system,
           coalesce(ln.lines, '[]'::jsonb) as changes, null::jsonb as status_card, null::jsonb as cadence_card
      from start_snap ss
      cross join lateral (
        select jsonb_agg(jsonb_build_object('subject', null, 'label', x.l, 'old', null, 'new', x.v,
                                            'is_system', ss.tbl in ('visits','invoices'), 'long', false) order by x.o) as lines
          from (values
            (1,  'Client code', case when ss.tbl = 'clients' then ss.s ->> 'client_code' end),
            (2,  'Name', case when ss.tbl = 'clients' then ss.s ->> 'name' end),
            (3,  'Address', case when ss.tbl = 'properties' then concat_ws(', ', nullif(btrim(ss.s ->> 'address'), ''), nullif(btrim(ss.s ->> 'city'), '')) end),
            (4,  'Email', case when ss.tbl = 'client_contacts' then ss.s ->> 'email' end),
            (5,  'Phone', case when ss.tbl = 'client_contacts' then ss.s ->> 'phone' end),
            (8,  'Date', case when ss.tbl = 'visits' then to_char((ss.s ->> 'visit_date')::date, 'Mon FMDD, YYYY') end),
            (10, 'Status', case ss.tbl when 'clients' then audit.fn_activity_sentence(ss.s ->> 'status')
                                       when 'jobs' then audit.fn_activity_sentence(ss.s ->> 'job_status')
                                       when 'visits' then audit.fn_activity_sentence(ss.s ->> 'visit_status')
                                       when 'invoices' then audit.fn_activity_sentence(ss.s ->> 'invoice_status') end),
            (11, 'Frequency', case when ss.tbl = 'jobs' and coalesce((ss.s ->> 'frequency_days')::int, 0) > 0
                                   then audit.fn_activity_value(ss.s -> 'frequency_days', 'days', null, null) end),
            (12, 'Truck', case when ss.tbl = 'visits' then (select ve.name from public.vehicles ve where ve.id = (ss.s ->> 'vehicle_id')::bigint) end),
            (13, 'Total', case when ss.tbl = 'invoices' and ss.s ? 'total' then audit.render_value(ss.s -> 'total', 'money', null, null) end),
            (14, 'Changes recorded from', case when ss.since is not null and ss.created_at < ss.since
                                               then to_char(ss.since at time zone 'America/New_York', 'Mon FMDD, YYYY') end)
          ) x(o, l, v)
         where nullif(btrim(x.v), '') is not null) ln
  ),
  all_entries as (
    select ae.key, ae.at, ae.area, ae.subject, ae.title, ae.actor_label, ae.actor_kind, ae.is_system, ae.changes, ae.status_card, ae.cadence_card
      from audit_entries ae
    union all
    select pe.key, pe.at, pe.area, pe.subject, pe.title, pe.actor_label, pe.actor_kind, pe.is_system, pe.changes, pe.status_card, pe.cadence_card
      from prop_events pe
    union all
    select ne.key, ne.at, ne.area, ne.subject, ne.title, ne.actor_label, ne.actor_kind, ne.is_system, ne.changes, ne.status_card, ne.cadence_card
      from note_entries ne
    union all
    select se.key, se.at, se.area, se.subject, se.title, se.actor_label, se.actor_kind, se.is_system, se.changes, se.status_card, se.cadence_card
      from start_entries se
  )
  select x.key, x.at, x.area,
         case x.area when 'client' then 'Client' when 'property' then 'Property' when 'job' then 'Job' when 'contacts' then 'Contacts'
                     when 'gdo' then 'GDO permit' when 'invoice' then 'Invoice' when 'note' then 'Note' else initcap(x.area) end,
         x.subject, x.title, x.actor_label, x.actor_kind, x.is_system, x.changes, x.status_card, x.cadence_card
    from all_entries x
   where (v_inc or not x.is_system)
     and (p_cursor is null or (x.at, x.key) < ((p_cursor ->> 'at')::timestamptz, p_cursor ->> 'key'))
   order by x.at desc, x.key desc
   limit p_limit;
end $function$;

CREATE OR REPLACE FUNCTION client.preview_client_status_change(p_client_id bigint, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old  text;
  v_will boolean;
  v_n    int := 0;
  v_sc   int := 0;
  v_sa   bigint[];
begin
  perform hr.fn_require_app('client_app', 'view');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  v_will := (v_old = 'RECURRING' and p_status <> 'RECURRING')
         or (p_status in ('INACTIVE','PAUSED') and v_old not in ('INACTIVE','PAUSED'));

  if v_will then
    select count(*) into v_n
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
    select count(*) into v_sc
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and not exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
  end if;

  v_sa := client.fn_client_live_sa_jobs(p_client_id);

  return jsonb_build_object(
    'current_status', v_old,
    'new_status', p_status,
    'will_clean_up', v_will,
    'sa_visits_to_remove', v_n,
    'service_call_visits_kept', v_sc,

    -- Does this client actually hold a live, current-format Service Agreement?
    'has_live_sa_job',  (cardinality(v_sa) > 0),
    'live_sa_job_ids',  to_jsonb(v_sa),

    -- CORRECTED 2026-09-08. Was `(v_will and p_status = 'ACTIVE')`, which never looked at
    -- the client and whose premise (the JS generator keying on ACTIVE OR RECURRING) has
    -- been dead since 2026-06-02. The live generator public.fn_generate_sa_visits requires
    -- c.status = 'RECURRING', so an ACTIVE client is never regenerated, by any path.
    -- Kept as a key so the deployed app does not break on a missing field.
    'reschedules_unless_job_closed', false,

    -- The honest warning: leaving RECURRING with a real SA in hand STOPS generation.
    -- This is what stranded 084-ULT and 201-ALA.
    'stops_sa_generation',
      (v_will and p_status <> 'RECURRING' and cardinality(v_sa) > 0)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION client.preview_job_action(p_client_id bigint, p_job_id bigint, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status        text;
  v_job           jsonb;
  v_kind          text;
  v_jobs_to_close jsonb := '[]'::jsonb;
  v_upcoming      int   := 0;
  v_other_sa      int   := 0;
  v_from          text;
  v_to            text  := null;
  v_arch          bool  := false;
  v_unarch        bool  := false;
BEGIN
  perform hr.fn_require_app('client_app', 'view');   -- 2026-10-21_0900 access phase 5
  SELECT status INTO v_status FROM public.clients WHERE id = p_client_id;
  v_from := v_status;

  -- classify the acted job (title-only). p_job_id NULL (the 'create' case) leaves v_job/v_kind NULL.
  SELECT jsonb_build_object(
           'job_number', j.job_number,
           'title', j.title,
           'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                        WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                        ELSE 'legacy' END,
           'frequency_days', j.frequency_days,
           'job_status', j.job_status),
         (CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
               WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
               ELSE 'legacy' END)
    INTO v_job, v_kind
    FROM public.jobs j
   WHERE j.id = p_job_id;

  IF p_action = 'create' THEN
    IF v_status = 'ACTIVE' THEN v_to := 'RECURRING'; END IF;

  ELSIF p_action = 'reopen' AND v_kind = 'SA' AND v_status = 'ACTIVE' THEN
    v_to := 'RECURRING';

  ELSIF p_action = 'reopen' AND v_kind = 'SC' AND v_status = 'INACTIVE' THEN
    v_to := 'ACTIVE';
    v_unarch := true;

  ELSIF p_action = 'close' AND v_kind = 'SA' THEN
    SELECT count(*) INTO v_other_sa
      FROM public.jobs
     WHERE client_id = p_client_id AND id <> p_job_id
       AND title ILIKE 'Service Agreement%' AND job_status NOT IN ('archived', 'destroyed');
    IF v_other_sa = 0 THEN v_to := 'ACTIVE'; END IF;
    v_jobs_to_close := (SELECT jsonb_agg(x) FROM (SELECT v_job AS x) t);
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live
     WHERE job_id = p_job_id AND visit_status = 'scheduled'
       AND deleted_at IS NULL AND start_at >= now();

  ELSIF p_action = 'close' AND v_kind = 'SC' THEN
    v_to := 'INACTIVE';
    v_arch := true;
    SELECT jsonb_agg(jsonb_build_object(
             'job_number', j.job_number,
             'title', j.title,
             'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                          WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                          ELSE 'legacy' END,
             'upcoming_visits', (SELECT count(*) FROM client.v_visits_live vv
                                   WHERE vv.job_id = j.id AND vv.visit_status = 'scheduled'
                                     AND vv.deleted_at IS NULL AND vv.start_at >= now())))
      INTO v_jobs_to_close
      FROM public.jobs j
     WHERE j.client_id = p_client_id AND j.job_status NOT IN ('archived', 'destroyed');
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live vv
      JOIN public.jobs j ON j.id = vv.job_id
     WHERE j.client_id = p_client_id AND j.job_status NOT IN ('archived', 'destroyed')
       AND vv.visit_status = 'scheduled' AND vv.deleted_at IS NULL AND vv.start_at >= now();
  END IF;

  RETURN jsonb_build_object(
    'job', v_job,
    'action', p_action,
    'status_change', CASE WHEN v_to IS NULL THEN null
                          ELSE jsonb_build_object('from', v_from, 'to', v_to) END,
    'jobs_to_close', COALESCE(v_jobs_to_close, '[]'::jsonb),
    'upcoming_visits_removed', v_upcoming,
    'other_open_sa_count', v_other_sa,
    'will_archive_client', v_arch,
    'will_unarchive_client', v_unarch);
END
$function$;

CREATE OR REPLACE FUNCTION ops.cancel_visit_request(p_request_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'cancel a visit request');   -- 2026-10-21_0900 access phase 5
  UPDATE ops.visit_requests
     SET status = 'cancelled', cancel_reason = p_reason, deleted_at = coalesce(deleted_at, now())
   WHERE id = p_request_id AND status = 'open' AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_visit_request: request % is not open', p_request_id;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION ops.create_visit_request(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_line_item_descriptions jsonb DEFAULT NULL::jsonb, p_vehicle_id bigint DEFAULT NULL::bigint, p_team_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id bigint; v_bad int;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'create a visit request');   -- 2026-10-21_0900 access phase 5
  IF p_client_id IS NULL OR p_job_id IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids,1) IS NULL THEN
    RAISE EXCEPTION 'create_visit_request: client_id, job_id and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status NOT IN ('archived', 'destroyed');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_visit_request: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  SELECT count(*) INTO v_bad FROM unnest(p_service_line_item_ids) x
   WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                      WHERE s.id = x AND s.active AND ((s.reason = 'Service Call' AND s.schedulable) OR s.code = '27'));
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'create_visit_request: % non Service-Call service(s) supplied', v_bad;
  END IF;

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes, vehicle_id)
  VALUES (p_client_id, p_job_id, p_property_id, p_title, p_notes, p_vehicle_id)
  RETURNING id INTO v_id;

  INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
  SELECT v_id, x.id, x.ord::smallint,
         (p_line_item_prices -> x.id::text ->> 'quantity')::numeric,
         (p_line_item_prices -> x.id::text ->> 'unit_price')::numeric,
         nullif(btrim(p_line_item_descriptions ->> x.id::text), '')
    FROM unnest(p_service_line_item_ids) WITH ORDINALITY AS x(id, ord);

  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_locations (request_id, client_location_id)
    SELECT v_id, l FROM unnest(p_client_location_ids) l ON CONFLICT DO NOTHING;
  END IF;

  IF p_team_ids IS NOT NULL AND array_length(p_team_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
    SELECT v_id, x.id, x.ord::smallint
      FROM unnest(p_team_ids) WITH ORDINALITY AS x(id, ord)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION ops.schedule_visit_request(p_request_id bigint, p_visit_date date, p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_vehicle_id bigint DEFAULT NULL::bigint, p_team_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r ops.visit_requests; v public.visits;
        v_ids bigint[]; v_locs bigint[]; v_prices jsonb; v_desc jsonb;
        v_vehicle bigint; v_team bigint[];
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'schedule a visit request');   -- 2026-10-21_0900 access phase 5
  IF p_visit_date IS NULL THEN
    RAISE EXCEPTION 'schedule_visit_request: p_visit_date is required';
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'schedule_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'schedule_visit_request: request % is already %', p_request_id, r.status;
  END IF;

  SELECT array_agg(s.service_line_item_id ORDER BY s.seq_no),
         jsonb_object_agg(s.service_line_item_id::text,
           jsonb_strip_nulls(jsonb_build_object('unit_price', s.unit_price, 'quantity', s.quantity)))
             FILTER (WHERE s.unit_price IS NOT NULL OR s.quantity IS NOT NULL),
         jsonb_object_agg(s.service_line_item_id::text, s.description) FILTER (WHERE s.description IS NOT NULL)
    INTO v_ids, v_prices, v_desc
    FROM ops.visit_request_services s WHERE s.request_id = r.id;

  SELECT array_agg(client_location_id) INTO v_locs
    FROM ops.visit_request_locations WHERE request_id = r.id;

  -- Caller wins; otherwise use what the dispatcher chose when the request was created.
  v_vehicle := COALESCE(p_vehicle_id, r.vehicle_id);
  IF p_team_ids IS NOT NULL AND array_length(p_team_ids,1) IS NOT NULL THEN
    v_team := p_team_ids;
  ELSE
    SELECT array_agg(employee_id ORDER BY seq_no, employee_id) INTO v_team
      FROM ops.visit_request_team WHERE request_id = r.id;
  END IF;

  v := public.create_calendar_visit(
         p_client_id             => r.client_id,
         p_job_id                => r.job_id,
         p_service_line_item_ids => v_ids,
         p_visit_date            => p_visit_date,
         p_property_id           => r.property_id,
         p_client_location_ids   => v_locs,
         p_start_at              => p_start_at,
         p_end_at                => p_end_at,
         p_title                 => r.title,
         p_notes                 => r.notes,
         p_vehicle_id            => v_vehicle,
         p_driver_id             => NULL,
         p_line_item_prices      => v_prices,
         p_team_ids              => v_team,
         p_line_item_descriptions=> v_desc);

  UPDATE ops.visit_requests
     SET status = 'scheduled', converted_visit_id = v.id, converted_at = now()
   WHERE id = r.id;

  RETURN v;
END $function$;

CREATE OR REPLACE FUNCTION ops.snooze_call_request(p_request_id bigint, p_next_call_at date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops'
AS $function$
DECLARE v_client bigint; v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'snooze a call request');   -- 2026-10-21_0900 access phase 5
  IF p_next_call_at IS NULL OR p_next_call_at <= v_today THEN
    RAISE EXCEPTION 'Pick a date after today for the next call.' USING ERRCODE = '22023';
  END IF;
  IF p_next_call_at > v_today + 365 THEN
    RAISE EXCEPTION 'Pick a date within the next year for the next call.' USING ERRCODE = '22023';
  END IF;
  SELECT r.client_id INTO v_client FROM ops.visit_requests r
   WHERE r.id = p_request_id AND r.call_required AND r.status = 'open' AND r.deleted_at IS NULL;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'This call reminder is no longer waiting. Refresh the list.' USING ERRCODE = 'P0002', DETAIL = 'request=' || p_request_id;
  END IF;
  UPDATE ops.client_call_policy SET next_call_at = p_next_call_at WHERE client_id = v_client;
  PERFORM ops.cancel_visit_request(p_request_id, 'Not now: call again ' || to_char(p_next_call_at, 'Mon FMDD, YYYY'));
END $function$;

CREATE OR REPLACE FUNCTION ops.unschedule_calendar_visit(p_visit_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v          public.visits;
  j          public.jobs;
  v_today    date := (now() AT TIME ZONE 'America/New_York')::date;
  v_is_sa    boolean;
  v_ids      bigint[];
  v_team     bigint[];
  v_locs     bigint[];
  v_orphan   text;
  v_id       bigint;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'unschedule a visit');   -- 2026-10-21_0900 access phase 5
  IF p_visit_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'No visit was given.', DETAIL = 'blocker=no_visit_id in ops.unschedule_calendar_visit';
  END IF;

  SELECT * INTO v FROM visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND OR v.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit is no longer on the calendar. Close the drawer and open it again.', DETAIL = 'blocker=visit_not_found in ops.unschedule_calendar_visit';
  END IF;
  IF v.visit_status = 'completed' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'A completed visit cannot be unscheduled. Mark it incomplete first.', DETAIL = 'blocker=visit_completed in ops.unschedule_calendar_visit';
  ELSIF v.visit_status = 'skipped' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'A skipped visit cannot be unscheduled. Un-skip it first.', DETAIL = 'blocker=visit_skipped in ops.unschedule_calendar_visit';
  ELSIF v.visit_status IS DISTINCT FROM 'scheduled' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('Only a scheduled visit can be unscheduled. This one is %s.', coalesce(v.visit_status, 'without a status')), DETAIL = 'blocker=visit_not_scheduled in ops.unschedule_calendar_visit';
  END IF;
  IF v.client_id IS NULL OR v.job_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit has no client or no job on record, so it cannot go to the To Be Scheduled list. Delete it instead.', DETAIL = 'blocker=no_client_or_job in ops.unschedule_calendar_visit';
  END IF;

  SELECT * INTO j FROM jobs WHERE id = v.job_id;
  IF NOT FOUND OR j.job_status IN ('archived', 'destroyed') THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit''s job is closed in Jobber, so it cannot go to the To Be Scheduled list. Delete the visit instead.', DETAIL = 'blocker=job_closed in ops.unschedule_calendar_visit';
  END IF;
  IF j.client_id IS DISTINCT FROM v.client_id THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit''s job belongs to a different client, so it cannot go to the To Be Scheduled list. Delete the visit instead.', DETAIL = 'blocker=job_other_client in ops.unschedule_calendar_visit';
  END IF;
  v_is_sa := j.title ILIKE 'Service Agreement%';

  -- The last future visit of an agreement: the nightly generator would put it back (header).
  IF v_is_sa AND coalesce(j.frequency_days, 0) > 0 AND v.visit_date >= v_today
     AND NOT EXISTS (SELECT 1 FROM visits o
                      WHERE o.job_id = v.job_id AND o.id <> v.id AND o.deleted_at IS NULL
                        AND o.visit_status = 'scheduled' AND o.visit_date >= v.visit_date) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This is the last scheduled visit of this Service Agreement. If it is unscheduled, the nightly schedule run puts a visit back on this date. Move it to another date, or skip it, instead.', DETAIL = 'blocker=agreement_tail in ops.unschedule_calendar_visit';
  END IF;

  -- Services (header, point 3).
  IF EXISTS (SELECT 1 FROM line_items WHERE visit_id = v.id) THEN
    SELECT string_agg(li.name, ', ' ORDER BY li.id) INTO v_orphan
      FROM line_items li
     WHERE li.visit_id = v.id
       AND NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.active AND (s.title = li.name OR s.code = split_part(li.name, ' - ', 1)));
    IF v_orphan IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = format('This visit carries a service that is not in the service list any more (%s), so it cannot go to the To Be Scheduled list. Edit its services first.', v_orphan), DETAIL = 'blocker=service_unknown in ops.unschedule_calendar_visit';
    END IF;
    SELECT array_agg(x.sid ORDER BY x.first_id) INTO v_ids
      FROM (SELECT m.sid, min(m.li_id) AS first_id
              FROM (SELECT li.id AS li_id,
                           (SELECT s.id FROM service_line_items s
                             WHERE s.active AND (s.title = li.name OR s.code = split_part(li.name, ' - ', 1))
                             ORDER BY (s.title = li.name) DESC, s.id LIMIT 1) AS sid
                      FROM line_items li WHERE li.visit_id = v.id) m
             GROUP BY m.sid) x;
  ELSE
    SELECT array_agg(x.id ORDER BY x.pri, x.code) INTO v_ids
      FROM (SELECT DISTINCT s.id, s.code,
                   CASE WHEN s.service_type IS NOT DISTINCT FROM v.service_type THEN 0 ELSE 1 END AS pri
              FROM line_items li
              JOIN service_line_items s ON s.code = lpad(substring(btrim(li.name) FROM '^([0-9]+)'), 2, '0')
             WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.quantity > 0
               AND s.schedulable AND s.active AND s.code <> '08') x;
    IF v_ids IS NULL AND v.service_line_item_id IS NOT NULL THEN
      v_ids := ARRAY[v.service_line_item_id];
    END IF;
  END IF;
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit has no service on record, so it cannot go to the To Be Scheduled list. Delete it instead.', DETAIL = 'blocker=no_service in ops.unschedule_calendar_visit';
  END IF;

  SELECT array_agg(t.employee_id ORDER BY (t.employee_id = v.assigned_driver_id) DESC, t.employee_id)
    INTO v_team FROM visit_team t WHERE t.visit_id = v.id;
  IF v_team IS NULL AND v.assigned_driver_id IS NOT NULL THEN
    v_team := ARRAY[v.assigned_driver_id];
  END IF;

  SELECT array_agg(l.client_location_id ORDER BY l.client_location_id)
    INTO v_locs FROM visit_locations l WHERE l.visit_id = v.id;

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes, vehicle_id, unscheduled_from_visit_id)
  VALUES (v.client_id, v.job_id, v.property_id, v.title, v.notes, v.vehicle_id, v.id)
  RETURNING id INTO v_id;

  -- Quantity, unit price and description ride along only when the visit had its own line items.
  INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
  SELECT v_id, x.id, x.ord::smallint, li.quantity, li.unit_price, nullif(btrim(li.description), '')
    FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord)
    LEFT JOIN LATERAL (
      SELECT l.quantity, l.unit_price, l.description
        FROM line_items l JOIN service_line_items s ON s.id = x.id
       WHERE l.visit_id = v.id AND (s.title = l.name OR s.code = split_part(l.name, ' - ', 1))
       ORDER BY (s.title = l.name) DESC, l.id LIMIT 1) li ON true;

  IF v_locs IS NOT NULL THEN
    INSERT INTO ops.visit_request_locations (request_id, client_location_id)
    SELECT v_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
  END IF;

  IF v_team IS NOT NULL THEN
    INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
    SELECT v_id, x.id, x.ord::smallint FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
    ON CONFLICT DO NOTHING;
  END IF;

  -- The canonical soft delete: deleted_at = now(), audited as "deleted by <person>", and its
  -- trg_push_visit_update transition is what removes the visit from Jobber.
  PERFORM public.delete_calendar_visit(v.id);

  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION ops.update_visit_request(p_request_id bigint, p_patch jsonb)
 RETURNS ops.visit_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r ops.visit_requests; v_ids bigint[]; v_bad int; v_locs bigint[]; v_team bigint[]; v_is_sa boolean;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'edit a visit request');   -- 2026-10-21_0900 access phase 5
  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'update_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'update_visit_request: request % is % and can no longer be edited', p_request_id, r.status;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN r; END IF;

  -- Refuse loudly rather than silently ignoring a key the caller believed would apply.
  IF p_patch ?| ARRAY['client_id','job_id','status','converted_visit_id','converted_at','deleted_at','cancel_reason','unscheduled_from_visit_id'] THEN
    RAISE EXCEPTION 'update_visit_request: client_id, job_id and lifecycle fields are not editable; remove and recreate instead';
  END IF;

  -- Scalars. Key presence decides; an absent key leaves the column untouched.
  UPDATE ops.visit_requests SET
    title       = CASE WHEN p_patch ? 'title'       THEN NULLIF(p_patch->>'title','')      ELSE title END,
    notes       = CASE WHEN p_patch ? 'notes'       THEN NULLIF(p_patch->>'notes','')      ELSE notes END,
    property_id = CASE WHEN p_patch ? 'property_id' THEN (p_patch->>'property_id')::bigint ELSE property_id END,
    vehicle_id  = CASE WHEN p_patch ? 'vehicle_id'  THEN (p_patch->>'vehicle_id')::bigint  ELSE vehicle_id END
  WHERE id = p_request_id;

  -- Services: replace on presence. Service Call services (and 27) as in create_visit_request, plus
  -- Service Agreement services when the request's job is a Service Agreement (2026-09-21_0925: an
  -- unscheduled agreement visit lands here with the agreement's services).
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids
      FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids,1) IS NULL THEN
      RAISE EXCEPTION 'update_visit_request: at least one service is required';
    END IF;
    SELECT (title ILIKE 'Service Agreement%') INTO v_is_sa FROM jobs WHERE id = r.job_id;
    SELECT count(*) INTO v_bad FROM unnest(v_ids) x
     WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.id = x AND s.active
                          AND ((s.reason = 'Service Call' AND s.schedulable) OR s.code = '27'
                               OR (coalesce(v_is_sa, false) AND s.reason = 'Service Agreement' AND s.schedulable)));
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'update_visit_request: % service(s) supplied that a % job cannot carry', v_bad,
        CASE WHEN coalesce(v_is_sa, false) THEN 'Service Agreement' ELSE 'Service Call' END;
    END IF;

    DELETE FROM ops.visit_request_services WHERE request_id = p_request_id;
    INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
    SELECT p_request_id, x.id, x.ord::smallint,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'quantity')::numeric,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'unit_price')::numeric,
           nullif(btrim(p_patch -> 'line_item_descriptions' ->> x.id::text), '')
      FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord);
  END IF;

  IF p_patch ? 'client_location_ids' THEN
    SELECT array_agg(x::bigint) INTO v_locs
      FROM jsonb_array_elements_text(p_patch->'client_location_ids') AS x;
    DELETE FROM ops.visit_request_locations WHERE request_id = p_request_id;
    IF v_locs IS NOT NULL AND array_length(v_locs,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_locations (request_id, client_location_id)
      SELECT p_request_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  IF p_patch ? 'team_ids' THEN
    SELECT array_agg(x::bigint) INTO v_team
      FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
    DELETE FROM ops.visit_request_team WHERE request_id = p_request_id;
    IF v_team IS NOT NULL AND array_length(v_team,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
      SELECT p_request_id, x.id, x.ord::smallint
        FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id;
  RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.create_calendar_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_vehicle_id bigint DEFAULT NULL::bigint, p_driver_id bigint DEFAULT NULL::bigint, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary bigint; v_service_type text; v_derm boolean; v_property bigint; v_visit public.visits;
  v_team bigint[]; v_end_at timestamptz; v_clash jsonb; v_eff_vehicle bigint;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'create a visit');   -- 2026-10-21_0900 access phase 5
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status NOT IN ('archived', 'destroyed');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_team := COALESCE(p_team_ids, CASE WHEN p_driver_id IS NOT NULL THEN ARRAY[p_driver_id] ELSE '{}'::bigint[] END);
  v_primary := COALESCE(p_team_ids[1], p_driver_id);
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1];
  SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(p_property_id, (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1));

  -- A visit lasts one hour unless the caller says otherwise (Fred, 2026-09-06). The create form can
  -- send a start with no end, and a NULL end made the visit read as untimed downstream.
  v_end_at := COALESCE(p_end_at, CASE WHEN p_start_at IS NOT NULL THEN p_start_at + interval '30 minutes' END);

  -- HARD REFUSE a second visit on the same TRUCK inside the hour. One truck cannot be in two places.
  -- The same-DRIVER case is deliberately NOT refused: a driver can ride as a second crew member, so
  -- it is advisory and surfaced by fn_check_visit_clash for the app to warn on. (Fred, 2026-09-06.)
  -- The EFFECTIVE truck is used, not p_vehicle_id: the Calendar shows a truck defaulted from the
  -- job's line items when none is assigned, and the live clash this guard exists for has a NULL
  -- vehicle_id on one side. Reading the stored column would return a confident zero on that case.
  v_eff_vehicle := public.fn_effective_vehicle_for_job(p_vehicle_id, p_job_id);
  IF p_start_at IS NOT NULL AND v_eff_vehicle IS NOT NULL THEN
    v_clash := public.fn_check_visit_clash(p_start_at, v_eff_vehicle, v_team, NULL);
    IF jsonb_array_length(v_clash -> 'truck') > 0
     AND public.fn_visit_clash_guard_enabled() THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('visit_truck_clash: truck %s already has %s at %s',
          COALESCE((SELECT name FROM vehicles WHERE id = v_eff_vehicle), v_eff_vehicle::text),
          v_clash -> 'truck' -> 0 ->> 'client_code',
          v_clash -> 'truck' -> 0 ->> 'start_local'),
        HINT = 'Pick another time or another truck. A visit lasts one hour.';
    END IF;
  END IF;

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes, visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, v_primary, p_visit_date, p_start_at, v_end_at,
          p_title, v_service_type, p_service_line_item_ids[1], v_derm, p_notes, 'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO visit_team (visit_id, employee_id)
  SELECT v_visit.id, e FROM unnest(v_team) AS e WHERE e IS NOT NULL ON CONFLICT DO NOTHING;

  -- Per-line-item description/note (like Jobber's line-item description). p_line_item_descriptions
  -- is a jsonb map { "<service_line_item_id>": "note text" }; absent/blank -> '' (Fred 2026-07-02).
  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title,
    COALESCE(NULLIF(btrim(p_line_item_descriptions ->> s.id::text), ''), ''),
    COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
      * COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1), false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id LIMIT 1 ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_visit;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_dump_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_driver_id bigint DEFAULT NULL::bigint, p_team_ids bigint[] DEFAULT NULL::bigint[], p_push_to_jobber boolean DEFAULT false, p_vehicle_id bigint DEFAULT NULL::bigint)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v public.visits;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'create a dump visit');   -- 2026-10-21_0900 access phase 5
  -- TEST MODE: suppress the AFTER INSERT push for THIS transaction only.
  IF NOT p_push_to_jobber THEN
    PERFORM set_config('app.suppress_jobber_push', 'on', true);
  END IF;

  -- The one sanctioned visit-creating path. Unchanged, so all its validation + children still apply.
  -- ⚠ POSITIONAL call: the 11th argument is create_calendar_visit's p_vehicle_id. It used to be a
  -- hardcoded NULL, which is why every app dump had no truck (fixed 2026-07-27).
  v := public.create_calendar_visit(
         p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
         p_property_id, NULL, p_start_at, p_end_at, p_title, p_notes,
         p_vehicle_id, p_driver_id, NULL, p_team_ids, NULL);

  -- TEST MODE: make the row permanently inert to every Jobber path (trigger, cron, and push gate).
  IF NOT p_push_to_jobber THEN
    UPDATE public.visits
       SET source = 'manual', sync_state = 'confirmed'
     WHERE id = v.id;
    SELECT * INTO v FROM public.visits WHERE id = v.id;
  END IF;

  RETURN v;
END $function$;

CREATE OR REPLACE FUNCTION public.delete_calendar_visit(p_visit_id bigint)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v public.visits;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'delete a visit');   -- 2026-10-21_0900 access phase 5
  UPDATE public.visits SET deleted_at = now()
   WHERE id = p_visit_id AND deleted_at IS NULL
  RETURNING * INTO v;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delete_calendar_visit: visit % not found or already deleted', p_visit_id;
  END IF;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
        v_new_start timestamptz; v_new_vehicle bigint; v_clash jsonb; v_old_vehicle bigint;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'edit a visit');   -- 2026-10-21_0900 access phase 5
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id; END IF;
  -- A skipped visit is removed from Jobber and holds its cadence slot — editing it would silently move
  -- that slot. Un-skip first (parity with ripple_reschedule_visit's guard). Added 2026-07-03.
  IF v_visit.visit_status = 'skipped' THEN
    RAISE EXCEPTION 'edit_calendar_visit: visit % is skipped — un-skip it first (unskip_visit)', p_visit_id;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN v_visit; END IF;

  -- ONE implementation of the refusal decision, shared with the pre-flight check in the
  -- `save-calendar-visit` edge function. It used to live here as inline SQL; the edge function then
  -- had no way to ask the question BEFORE pushing to Jobber, so the refusal arrived at COMMIT time,
  -- after Jobber had already been written and verified -- turning a clash into a real Jobber/DB
  -- divergence. Measured live 2026-09-06 on visit 8001: Jobber 08:00, our DB 08:30.
  -- The no-op exemption and the effective-truck resolution now live in fn_visit_edit_clash.
  v_clash := public.fn_visit_edit_clash(p_visit_id, p_patch);
  IF COALESCE((v_clash ->> 'refuse')::boolean, false) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = v_clash ->> 'message',
      HINT    = v_clash ->> 'hint';
  END IF;

  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Team: replace + bump team_rev ONLY when the set actually changes (on-purpose signal).
  IF p_patch ? 'team_ids' THEN
    DECLARE v_incoming bigint[]; v_current bigint[];
    BEGIN
      SELECT COALESCE(array_agg(DISTINCT x::bigint ORDER BY x::bigint), '{}')
        INTO v_incoming FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
      SELECT COALESCE(array_agg(DISTINCT employee_id ORDER BY employee_id), '{}')
        INTO v_current FROM visit_team WHERE visit_id = p_visit_id;
      IF v_incoming IS DISTINCT FROM v_current THEN
        DELETE FROM visit_team WHERE visit_id = p_visit_id;
        INSERT INTO visit_team (visit_id, employee_id) SELECT p_visit_id, unnest(v_incoming) ON CONFLICT DO NOTHING;
        UPDATE visits SET assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint, team_rev = team_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Catalog path: services chosen from the catalog. Replace + bump ONLY on a real change.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      -- snapshot existing descriptions (name -> note) BEFORE any delete, to carry forward notes the
      -- patch does not explicitly provide (preserves descriptions on a qty/price-only edit).
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT s.title || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'quantity')::numeric, 1), 3)::text
               || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'unit_price')::numeric, s.unit_price, 0), 2)::text
               || '|' || COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                                       THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, '') AS sig
        FROM service_line_items s WHERE s.id = ANY (v_ids)) z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, s.title,
          COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                        THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                        ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, ''),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
            * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1), false
        FROM service_line_items s WHERE s.id = ANY (v_ids);
        v_primary := v_ids[1];
        SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
        SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
        UPDATE visits SET service_line_item_id = v_primary, service_type = v_stype,
          derm_required = CASE WHEN v_derm IS NOT TRUE AND (visit_status = 'completed' OR EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = p_visit_id)) THEN derm_required ELSE v_derm END /* 2026-09-24: a completed or filed visit is only ever promoted */, line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Arbitrary path: full line list. Replace + bump ONLY on a real change.
  IF p_patch ? 'line_items' THEN
    IF jsonb_typeof(p_patch->'line_items') <> 'array' OR jsonb_array_length(p_patch->'line_items') = 0 THEN
      RAISE EXCEPTION 'edit_calendar_visit: line_items must be a non-empty array';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT (li->>'name') || '|' || round(COALESCE((li->>'quantity')::numeric,1),3)::text
               || '|' || round(COALESCE((li->>'unit_price')::numeric,0),2)::text
               || '|' || COALESCE(CASE WHEN li ? 'description'
                                       THEN NULLIF(btrim(li->>'description'), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, '') AS sig
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '') z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, li->>'name',
          COALESCE(CASE WHEN li ? 'description'
                        THEN NULLIF(btrim(li->>'description'), '')
                        ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, ''),
          COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'unit_price')::numeric, 0),
          COALESCE((li->>'unit_price')::numeric, 0) * COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'taxable')::boolean, false)
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '';
        SELECT s.id, s.service_type INTO v_primary, v_stype
        FROM jsonb_array_elements(p_patch->'line_items') WITH ORDINALITY AS t(li, ord)
        JOIN service_line_items s ON s.code = split_part(t.li->>'name', ' - ', 1)
        ORDER BY t.ord LIMIT 1;
        SELECT bool_or(public.fn_line_item_requires_derm(li->>'name')) INTO v_derm
        FROM jsonb_array_elements(p_patch->'line_items') AS li;
        UPDATE visits SET
          service_line_item_id = COALESCE(v_primary, service_line_item_id),
          service_type = COALESCE(v_stype, service_type),
          derm_required = CASE WHEN v_derm IS NOT TRUE AND (visit_status = 'completed' OR EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL WHERE mv.visit_id = p_visit_id)) THEN derm_required ELSE v_derm END /* 2026-09-24: a completed or filed visit is only ever promoted */,
          line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$;

CREATE OR REPLACE FUNCTION public.retry_visit_push(p_visit_id bigint, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_status  text;
  v_issue   text;
  v_state   text;
  v_op      text;
  v_dup     bigint;
  v_dup_svc text;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'retry a Jobber push');   -- 2026-10-21_0900 access phase 5
  SELECT visit_status INTO v_status
    FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- WHY is it on the board? This is the guard that was missing.
  SELECT issue, auto_retry_state INTO v_issue, v_state
    FROM ops.v_calendar_push_health_by_visit WHERE visit_id = p_visit_id;

  IF v_issue IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'not_failing',
      'message', 'This visit is not reporting a sync problem, so there is nothing to retry.');
  END IF;

  IF v_issue = 'drift_surfaced' THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'drift', 'issue', v_issue,
      'message', 'This visit was edited in Jobber by a person and our copy disagrees. '
              || 'Retrying would overwrite their change. Someone must decide whether to keep '
              || 'Jobber''s version or re-send ours.');
  END IF;

  IF v_issue NOT IN ('not_in_jobber', 'push_failed', 'skip_removal_failed') THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'not_retryable', 'issue', v_issue,
      'message', 'This kind of sync problem is not fixed by retrying.');
  END IF;

  IF v_state = 'needs_data_fix' THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'needs_data_fix',
      'message', 'Retrying will fail the same way. The underlying data needs correcting first.');
  END IF;

  v_dup := public.fn_visit_push_duplicate_of(p_visit_id);
  IF v_dup IS NOT NULL AND NOT p_force THEN
    SELECT string_agg(li.name, ', ') INTO v_dup_svc
      FROM public.line_items li WHERE li.visit_id = v_dup;
    RETURN jsonb_build_object('ok', false, 'blocked', 'duplicate',
      'duplicate_of', v_dup, 'duplicate_of_service', v_dup_svc);   -- NULL when the sibling has none
  END IF;

  UPDATE public.visit_sync_flags
     SET attempts = 0, next_attempt_at = NULL, auto_retry_state = 'pending'
   WHERE visit_id = p_visit_id AND resolved_at IS NULL;

  -- A skipped visit still linked in Jobber needs its REMOVAL pushed, not an upsert that would
  -- re-create work the office deliberately cancelled.
  v_op := CASE WHEN v_status = 'skipped' THEN 'delete' ELSE 'upsert' END;
  PERFORM public.fn_request_jobber_push(p_visit_id, v_op);

  RETURN jsonb_build_object('ok', true, 'op', v_op, 'forced', COALESCE(v_dup IS NOT NULL, false));
END;
$function$;

CREATE OR REPLACE FUNCTION public.ripple_reschedule_visit(p_visit_id bigint, p_new_date date, p_new_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_new_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(visit_id bigint, old_date date, new_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_max_ripple CONSTANT int := 24;  -- cap on the Jobber-PUSH burst (in-horizon), not the DB chain
  m            RECORD;
  v_freq       int;
  v_lower      date;
  v_set        bigint[];
  v_n          int;
  v_n_push     int;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'move a visit');   -- 2026-10-21_0900 access phase 5
  SELECT id, job_id, client_id, visit_date, visit_status, source, deleted_at, start_at
    INTO m FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF m.deleted_at IS NOT NULL OR m.visit_status IN ('completed','cancelled','skipped') THEN
    RAISE EXCEPTION 'visit % is %/deleted; not reschedulable', p_visit_id, m.visit_status;
  END IF;
  -- A Jobber-mastered visit edited in the Calendar is ADOPTED as Calendar-mastered (promote in the
  -- target UPDATE below, non-dry-run only), so the move pushes back to Jobber instead of no-op'ing.

  SELECT j.frequency_days INTO v_freq FROM public.jobs j WHERE j.id = m.job_id;
  v_lower := LEAST(m.visit_date, p_new_date);

  -- gather + lock the forward ripple set (job-scoped, calendar/cron, live, future).
  SELECT array_agg(s.id ORDER BY s.visit_date, s.id) INTO v_set
  FROM (
    SELECT v.id, v.visit_date
    FROM public.visits v
    WHERE v.job_id = m.job_id AND v.id <> m.id
      AND v.source IN ('visit-calendar','supabase_cron')
      AND v.visit_status NOT IN ('completed','cancelled','skipped')
      AND v.deleted_at IS NULL
      AND v.visit_date > v_lower
    ORDER BY v.visit_date, v.id
    FOR UPDATE
  ) s;
  v_n := COALESCE(array_length(v_set,1),0);

  IF v_freq IS NULL OR v_freq <= 0 THEN v_set := '{}'; v_n := 0; END IF;  -- move-only, no chain

  -- Cap on the JOBBER-PUSH burst, NOT the DB chain size. Only re-anchored visits whose NEW date
  -- lands inside the 60-day push horizon actually push to Jobber; out-of-horizon ones are cheap
  -- DB-only updates. If even the in-horizon push set exceeds the cap (e.g. a daily SA), fall back
  -- to moving ONLY the target so the move still SUCCEEDS (graceful) instead of erroring.
  IF v_n > 0 THEN
    SELECT count(*) INTO v_n_push
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    WHERE (p_new_date + (i.ord * v_freq)::int) <= ((now() AT TIME ZONE 'America/New_York')::date + 60);
    IF v_n_push > v_max_ripple THEN
      RAISE WARNING 'ripple: % in-horizon downstream visits exceed cap % for job % — moving target only',
        v_n_push, v_max_ripple, m.job_id;
      v_set := '{}'; v_n := 0;  -- chain too large to push safely -> move target only
    END IF;
  END IF;

  IF p_dry_run THEN
    RETURN QUERY SELECT m.id, m.visit_date, p_new_date;
    IF v_n > 0 THEN
      RETURN QUERY
      SELECT v.id, v.visit_date, (p_new_date + (i.ord * v_freq)::int)::date
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
      JOIN public.visits v ON v.id = i.vid;
    END IF;
    RETURN;
  END IF;

  -- move the target; preserve ET wall-clock by shifting the day count IN the local
  -- ('America/New_York') zone so US DST boundaries don't drift the hour.
  UPDATE public.visits
     SET visit_date = p_new_date,
         source     = CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END,
         start_at   = COALESCE(
                        p_new_start_at,
                        ((start_at AT TIME ZONE 'America/New_York'
                          + make_interval(days => (p_new_date - visit_date)))
                         AT TIME ZONE 'America/New_York')
                      ),
         end_at     = COALESCE(
                        p_new_end_at,
                        ((end_at AT TIME ZONE 'America/New_York'
                          + make_interval(days => (p_new_date - visit_date)))
                         AT TIME ZONE 'America/New_York')
                      )
   WHERE id = m.id;
  RETURN QUERY SELECT m.id, m.visit_date, p_new_date;

  -- re-anchor the forward chain at +freq; shift start/end by the same day delta IN the
  -- local zone (DST-safe); skip no-ops.
  IF v_n > 0 THEN
    RETURN QUERY
    WITH tgt AS (
      SELECT i.vid, (p_new_date + (i.ord * v_freq)::int)::date AS nd
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    ), upd AS (
      UPDATE public.visits v
         SET visit_date = t.nd,
             start_at   = ((v.start_at AT TIME ZONE 'America/New_York'
                            + make_interval(days => (t.nd - v.visit_date)))
                           AT TIME ZONE 'America/New_York'),
             end_at     = ((v.end_at   AT TIME ZONE 'America/New_York'
                            + make_interval(days => (t.nd - v.visit_date)))
                           AT TIME ZONE 'America/New_York')
      FROM tgt t WHERE v.id = t.vid AND v.visit_date IS DISTINCT FROM t.nd
      RETURNING v.id, t.nd
    )
    SELECT u.id, v0.visit_date, u.nd
    FROM upd u JOIN public.visits v0 ON v0.id = u.id;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits; v_email text;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'change a visit status');   -- 2026-10-21_0900 access phase 5
  -- AUTH: logged-in staff only (@ayache.com / @unclogme.com). Defense-in-depth over the
  -- authenticated-only EXECUTE grant so even a mis-grant can't let the public anon key through.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'set_visit_status requires a logged-in staff user' USING ERRCODE='insufficient_privilege';
  END IF;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF v_email NOT LIKE '%@ayache.com' AND v_email NOT LIKE '%@unclogme.com' THEN
    RAISE EXCEPTION 'set_visit_status: % is not a staff account', v_email USING ERRCODE='insufficient_privilege';
  END IF;

  IF p_status NOT IN ('completed','scheduled','skipped','cancelled') THEN
    RAISE EXCEPTION 'set_visit_status: unsupported status %', p_status USING ERRCODE='check_violation';
  END IF;

  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;

  IF p_status = 'completed' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='completed', completed_at=now()
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'scheduled' THEN  -- uncomplete ONLY (un-skip lives in unskip_visit)
    IF v_row.visit_status = 'skipped' THEN
      RAISE EXCEPTION 'visit % is skipped; use unskip_visit to restore it', p_visit_id USING ERRCODE='check_violation';
    ELSIF v_row.visit_status <> 'completed' THEN
      RAISE EXCEPTION 'only a completed visit can be un-completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='scheduled', completed_at=NULL
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'skipped' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits
       SET visit_status='skipped',
           skip_reason=NULLIF(btrim(coalesce(p_reason,'')),''),
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);

  ELSE  -- 'cancelled'
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be cancelled (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    -- cancel == skip in Jobber: the AFTER push trigger deletes THIS occurrence (visit_status IN
    -- (cancelled,skipped) -> op='delete'); normalizing source makes that delete fire + bypass the
    -- origin gate, exactly as skip does. Reason not stored (no cancel_reason column in Phase 1).
    UPDATE public.visits
       SET visit_status='cancelled',
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);
  END IF;

  RETURN v_row;
END; $function$;

CREATE OR REPLACE FUNCTION public.unskip_visit(p_visit_id bigint)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'unskip a visit');   -- 2026-10-21_0900 access phase 5
  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;
  IF v_row.visit_status <> 'skipped' THEN RAISE EXCEPTION 'visit % is not skipped (is %)', p_visit_id, v_row.visit_status; END IF;
  UPDATE public.visits SET visit_status='scheduled', skip_reason=NULL WHERE id=p_visit_id RETURNING * INTO v_row;
  RETURN v_row;
END; $function$;

CREATE OR REPLACE FUNCTION ops.calendar_drive_days(p_from date, p_to date)
 RETURNS TABLE(visit_date date, grain text, group_id bigint, group_name text, group_color text, default_stops integer, stops integer, untimed_stops integer, not_completed_stops integer, stops_without_location integer, yard_returns jsonb, ordered_by text, legs integer, legs_known integer, drive_seconds integer, distance_mi numeric, complete boolean, pending boolean, blocked_reason text, blocked_code text, blocked_from_code text, depot_missing boolean, chain jsonb, visit_ids jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_role    text := coalesce(current_setting('role', true), 'none');
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_calls   integer;
  v_cap     integer := ops.plan_routing_cap();
  v_last_status text; v_last_details jsonb;
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_drive_days: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_drive_days: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  SELECT u.calls INTO v_calls FROM ops.plan_routing_usage u WHERE u.day = v_today;
  SELECT l.status, l.details INTO v_last_status, v_last_details
    FROM public.sync_log l WHERE l.sync_source = 'plan-drive-fill' AND l.started_at > now() - interval '24 hours'
    ORDER BY l.started_at DESC LIMIT 1;

  RETURN QUERY
  WITH ch AS (
    SELECT * FROM ops.fn_drive_chain(p_from, p_to)
  ), legs AS (
    SELECT ch.*,
      (ch.seq > 0 AND ch.o_lat_r = ch.d_lat_r AND ch.o_lng_r = ch.d_lng_r) AS same_cell,
      c.secs, c.dist,
      coalesce(f.blocked, false) AS blocked
    FROM ch
    LEFT JOIN LATERAL (
      SELECT CASE WHEN rc.duration_seconds IS NOT NULL
                   AND (round(rc.duration_seconds / 60.0) = rc.duration_minutes OR (rc.duration_minutes = 1 AND rc.duration_seconds < 90))
                  THEN rc.duration_seconds ELSE rc.duration_minutes * 60 END AS secs,
             rc.distance_mi AS dist
      FROM ops.route_leg_cache rc
      WHERE ch.seq > 0
        AND rc.origin_lat_r = ch.o_lat_r AND rc.origin_lng_r = ch.o_lng_r
        AND rc.dest_lat_r = ch.d_lat_r AND rc.dest_lng_r = ch.d_lng_r
        AND rc.traffic_aware = false AND rc.computed_at > now() - interval '30 days'
      LIMIT 1
    ) c ON true
    LEFT JOIN LATERAL (
      SELECT true AS blocked
      FROM ops.route_leg_fail rf
      WHERE ch.seq > 0
        AND rf.origin_lat_r = ch.o_lat_r AND rf.origin_lng_r = ch.o_lng_r
        AND rf.dest_lat_r = ch.d_lat_r AND rf.dest_lng_r = ch.d_lng_r
        AND rf.failures >= 3
        AND rf.last_failed_at > now() - (CASE rf.kind WHEN 'no_route' THEN interval '7 days' ELSE interval '24 hours' END)
      LIMIT 1
    ) f ON true
  ), scored AS (
    SELECT l.*,
      CASE WHEN l.seq = 0 THEN NULL
           WHEN l.leg_reason = 'implausible' THEN NULL
           WHEN l.same_cell THEN 60
           ELSE l.secs END AS seconds,
      CASE WHEN l.seq = 0 THEN NULL WHEN l.same_cell THEN 0 ELSE l.dist END AS miles,
      CASE WHEN l.seq = 0 THEN NULL
           WHEN l.leg_reason = 'implausible' OR (l.secs IS NOT NULL AND l.secs > 300 * 60) THEN 'implausible'
           WHEN l.same_cell THEN 'same-cell'
           WHEN l.secs IS NOT NULL THEN 'cache'
           WHEN l.blocked THEN 'failed'
           ELSE 'missing' END AS src
    FROM legs l
  )
  SELECT s.visit_date, s.grain, s.group_id, s.group_name, s.group_color,
    max(s.default_stops) FILTER (WHERE s.seq = 0)        AS default_stops,
    max(s.stops) FILTER (WHERE s.seq = 0)                AS stops,
    max(s.untimed_stops) FILTER (WHERE s.seq = 0)        AS untimed_stops,
    max(s.not_completed_stops) FILTER (WHERE s.seq = 0)  AS not_completed_stops,
    max(jsonb_array_length(s.no_location_ids)) FILTER (WHERE s.seq = 0) AS stops_without_location,
    (array_agg(s.yard_returns) FILTER (WHERE s.seq = 0))[1] AS yard_returns,
    max(s.ordered_by) FILTER (WHERE s.seq = 0)           AS ordered_by,
    (count(*) FILTER (WHERE s.seq > 0))::integer         AS legs,
    (count(s.seconds))::integer                          AS legs_known,
    CASE WHEN count(*) FILTER (WHERE s.seq > 0) = count(s.seconds) AND count(*) FILTER (WHERE s.seq > 0) > 0
         THEN sum(s.seconds)::integer END                AS drive_seconds,
    CASE WHEN count(*) FILTER (WHERE s.seq > 0) = count(s.seconds) AND count(*) FILTER (WHERE s.seq > 0) > 0
         THEN round(sum(s.miles)::numeric, 1) END        AS distance_mi,
    (count(*) FILTER (WHERE s.seq > 0) = count(s.seconds)) AS complete,
    -- pending = a leg is simply not fetched yet (nothing blocks it): the ONLY condition that polls or kicks
    (coalesce(bool_or(s.src = 'missing'), false)
      AND NOT bool_or(s.depot_missing)
      AND NOT bool_or(s.src = 'implausible')
      AND NOT bool_or(s.src = 'failed')
      AND NOT coalesce(v_last_details ->> 'key_rejected' = 'true' OR v_last_details ->> 'quota' = 'true' OR v_last_details ->> 'outage' = 'true' OR v_last_details ->> 'key_missing' = 'true', false)
      AND NOT (coalesce(v_calls, 0) >= v_cap)
      AND NOT EXISTS (SELECT 1 FROM ops.plan_fill_request r
                       WHERE r.range_from <= s.visit_date AND r.range_to >= s.visit_date
                         AND r.requested_at < now() - interval '120 seconds'
                         AND NOT EXISTS (SELECT 1 FROM public.sync_log sl WHERE sl.sync_source = 'plan-drive-fill' AND sl.started_at > r.requested_at))
      AND NOT coalesce(v_last_status = 'error', false)
    ) AS pending,
    CASE
      WHEN bool_or(s.depot_missing) THEN 'no_depot'
      WHEN bool_or(s.src = 'implausible') THEN 'implausible'
      WHEN bool_or(s.src = 'failed') THEN 'failed'
      WHEN NOT coalesce(bool_or(s.src = 'missing'), false) THEN NULL
      WHEN v_last_details ->> 'key_rejected' = 'true' THEN 'key_rejected'
      WHEN v_last_details ->> 'quota' = 'true' THEN 'quota'
      WHEN v_last_details ->> 'outage' = 'true' THEN 'outage'
      WHEN v_last_details ->> 'key_missing' = 'true' THEN 'no_key'
      WHEN coalesce(v_calls, 0) >= v_cap THEN 'budget'
      WHEN EXISTS (SELECT 1 FROM ops.plan_fill_request r
                    WHERE r.range_from <= s.visit_date AND r.range_to >= s.visit_date
                      AND r.requested_at < now() - interval '120 seconds'
                      AND NOT EXISTS (SELECT 1 FROM public.sync_log sl WHERE sl.sync_source = 'plan-drive-fill' AND sl.started_at > r.requested_at))
           THEN 'stalled'
      WHEN v_last_status = 'error' THEN 'stalled'
      ELSE NULL
    END AS blocked_reason,
    (array_agg(coalesce(s.to_code, 'yard') ORDER BY s.seq) FILTER (WHERE s.src IN ('implausible', 'failed')))[1] AS blocked_code,
    (array_agg(coalesce(s.from_code, 'yard') ORDER BY s.seq) FILTER (WHERE s.src IN ('implausible', 'failed')))[1] AS blocked_from_code,
    bool_or(s.depot_missing) AS depot_missing,
    coalesce(jsonb_agg(jsonb_build_object('seq', s.seq, 'to_kind', s.to_kind, 'to_code', s.to_code, 'to_visit_id', s.to_visit_id,
                                          'to_truck_name', s.to_truck_name, 'seconds', s.seconds, 'source', s.src)
                       ORDER BY s.seq) FILTER (WHERE s.seq > 0), '[]'::jsonb) AS chain,
    (array_agg(s.chain_visit_ids) FILTER (WHERE s.seq = 0))[1] AS visit_ids
  FROM scored s
  GROUP BY s.visit_date, s.grain, s.group_id, s.group_name, s.group_color
  ORDER BY s.visit_date, s.grain, s.group_name;
END $function$;

CREATE OR REPLACE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_grease_estimates: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_grease_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live'
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
   WHERE r.pump_kind IS NOT NULL;
END $function$;

CREATE OR REPLACE FUNCTION ops.preview_sa_reanchor(p_job_id bigint, p_anchor_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_max_ripple CONSTANT int := 24;   -- must match ripple_reschedule_visit
  v_freq    int;
  v_set     bigint[];
  v_n       int;
  v_n_push  int;
  v_moves   jsonb := '[]'::jsonb;
  v_unchanged int := 0;
  v_excluded  jsonb := '[]'::jsonb;
  v_status  text := 'ok';
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF p_job_id IS NULL OR p_anchor_date IS NULL THEN
    RAISE EXCEPTION 'preview_sa_reanchor: job_id and anchor_date are required';
  END IF;

  SELECT j.frequency_days INTO v_freq FROM public.jobs j WHERE j.id = p_job_id;

  -- Jobber-born visits ripple will leave behind. Surfaced, never silently dropped.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('visit_id', v.id, 'date', v.visit_date)
                            ORDER BY v.visit_date, v.id), '[]'::jsonb)
    INTO v_excluded
  FROM public.visits v
  WHERE v.job_id = p_job_id
    AND v.source NOT IN ('visit-calendar','supabase_cron')
    AND v.visit_status NOT IN ('completed','cancelled','skipped')
    AND v.deleted_at IS NULL
    AND v.visit_date > p_anchor_date;

  -- Same set, same ordering, same predicates as ripple's forward gather.
  SELECT array_agg(s.id ORDER BY s.visit_date, s.id) INTO v_set
  FROM (
    SELECT v.id, v.visit_date
    FROM public.visits v
    WHERE v.job_id = p_job_id
      AND v.source IN ('visit-calendar','supabase_cron')
      AND v.visit_status NOT IN ('completed','cancelled','skipped')
      AND v.deleted_at IS NULL
      AND v.visit_date > p_anchor_date
    ORDER BY v.visit_date, v.id
  ) s;
  v_n := COALESCE(array_length(v_set,1),0);

  IF v_freq IS NULL OR v_freq <= 0 THEN
    v_status := 'no_frequency'; v_set := '{}'; v_n := 0;
  END IF;

  IF v_n > 0 THEN
    SELECT count(*) INTO v_n_push
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    WHERE (p_anchor_date + (i.ord * v_freq)::int) <= ((now() AT TIME ZONE 'America/New_York')::date + 60);
    IF v_n_push > v_max_ripple THEN
      v_status := 'cap_exceeded'; v_set := '{}'; v_n := 0;
    END IF;
  END IF;

  IF v_n > 0 THEN
    SELECT COALESCE(jsonb_agg(x.row ORDER BY x.ord), '[]'::jsonb),
           COALESCE(sum(x.same), 0)
      INTO v_moves, v_unchanged
    FROM (
      SELECT i.ord,
             jsonb_build_object('visit_id', v.id,
                                'old_date', v.visit_date,
                                'new_date', (p_anchor_date + (i.ord * v_freq)::int)::date) AS row,
             CASE WHEN (p_anchor_date + (i.ord * v_freq)::int)::date = v.visit_date THEN 1 ELSE 0 END AS same
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
      JOIN public.visits v ON v.id = i.vid
    ) x
    WHERE (x.row->>'new_date')::date <> (x.row->>'old_date')::date;

    SELECT count(*) INTO v_unchanged
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    JOIN public.visits v ON v.id = i.vid
    WHERE (p_anchor_date + (i.ord * v_freq)::int)::date = v.visit_date;
  END IF;

  RETURN jsonb_build_object(
    'status',               v_status,
    'frequency_days',       v_freq,
    'anchor_date',          p_anchor_date,
    'move_count',           jsonb_array_length(v_moves),
    'unchanged_count',      v_unchanged,
    'moves',                v_moves,
    'excluded_jobber_born', v_excluded
  );
END;
$function$;

CREATE OR REPLACE FUNCTION ops.preview_start_impact(p_changes jsonb)
 RETURNS TABLE(marker_id bigint, marker_date date, vehicle_id bigint, truck_name text, minutes smallint, employee_id bigint, driver_name text, leaving jsonb, anytime_codes text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
begin
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  -- p_changes: one object per visit the gesture writes, with the keys the write changes:
  --   {"visit_id": 5994, "visit_date": "2026-09-26"}                 a date move (a ripple link too);
  --   {"visit_id": 5994, "start_at": "...", "end_at": "..."}         a time change; start_at null = Anytime;
  --   {"visit_id": 5994, "vehicle_id": 2 | null}                     a truck change (null = No truck);
  --   {"visit_id": 5994, "visit_status": "completed" | "skipped"}   a status change;
  --   {"visit_id": 5994, "deleted": true}                            a delete or an unschedule.
  -- As in the real write: a date move without start_at keeps the ET wall-clock time
  -- (ripple_reschedule_visit), and a start_at without visit_date moves the date with it
  -- (trg_aa_reconcile_operating_date). Returns one row per unfrozen truck Start whose truck-day HAS a
  -- timed visit now and would have NONE after the gesture.
  if p_changes is null or jsonb_typeof(p_changes) <> 'array' then
    raise exception 'The Start of day check needs the list of visit changes.'
      using errcode = '22023', detail = 'blocker=bad_changes in ops.preview_start_impact';
  end if;

  return query
  with ch as (
    select v.id, v.visit_date as old_date, v.vehicle_id as old_vehicle,
           v.visit_status as old_status, v.start_at as old_start, v.end_at as old_end,
           d.nd as new_date,
           case when c ? 'start_at' then (c->>'start_at')::timestamptz
                else ((v.start_at at time zone 'America/New_York') + make_interval(days => d.nd - v.visit_date))
                       at time zone 'America/New_York' end as new_start,
           case when c ? 'end_at' then (c->>'end_at')::timestamptz
                else ((v.end_at at time zone 'America/New_York') + make_interval(days => d.nd - v.visit_date))
                       at time zone 'America/New_York' end as new_end,
           case when c ? 'vehicle_id' then (c->>'vehicle_id')::bigint else v.vehicle_id end as new_vehicle,
           coalesce(c->>'visit_status', v.visit_status) as new_status,
           coalesce((c->>'deleted')::boolean, false) as new_deleted,
           coalesce(prop.latitude, pp.latitude) is not null
             and coalesce(prop.longitude, pp.longitude) is not null as has_coords,
           cl.client_code, cl.name as client_name
      from jsonb_array_elements(p_changes) as x(c)
      join public.visits v on v.id = (c->>'visit_id')::bigint and v.deleted_at is null
      join public.clients cl on cl.id = v.client_id
      left join public.properties prop on prop.id = v.property_id
      left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true
     cross join lateral (select coalesce((c->>'visit_date')::date,
                                         case when c ? 'start_at' and c->>'start_at' is not null
                                              then ((c->>'start_at')::timestamptz at time zone 'America/New_York')::date end,
                                         v.visit_date) as nd) d
  ),
  -- the same timed-visit test as public.fn_start_first_visit, applied to the proposed state
  q as (
    select ch.*,
           (ch.new_status = 'scheduled' and not ch.new_deleted and ch.new_start is not null and ch.has_coords
            and not ((ch.new_start at time zone 'America/New_York')::time = '00:00:00'::time
                     and ch.new_end is not null and (ch.new_end - ch.new_start) >= '23:00:00'::interval)) as new_timed,
           (ch.old_status = 'scheduled' and ch.old_start is not null and ch.has_coords
            and not ((ch.old_start at time zone 'America/New_York')::time = '00:00:00'::time
                     and ch.old_end is not null and (ch.old_end - ch.old_start) >= '23:00:00'::interval)) as old_timed
      from ch
  ),
  starts as (
    select distinct m.id, m.marker_date, m.vehicle_id, m.minutes, m.employee_id
      from ops.calendar_day_markers m
      join q on q.old_date = m.marker_date and q.old_vehicle = m.vehicle_id and q.old_timed
     where m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
       and public.fn_start_frozen(m.marker_date, m.minutes) is not true
  )
  select s.id, s.marker_date, s.vehicle_id, t.name, s.minutes, s.employee_id, e.full_name,
         (select jsonb_agg(jsonb_build_object('visit_id', q.id, 'client_code', q.client_code,
                                              'client_name', q.client_name, 'new_date', q.new_date,
                                              'new_vehicle_id', q.new_vehicle, 'new_status', q.new_status,
                                              'deleted', q.new_deleted, 'anytime', q.new_start is null)
                           order by q.old_start, q.id)
            from q where q.old_date = s.marker_date and q.old_vehicle = s.vehicle_id and q.old_timed),
         array(select distinct c2.client_code
                 from public.visits v2 join public.clients c2 on c2.id = v2.client_id
                where v2.deleted_at is null and v2.visit_status = 'scheduled'
                  and v2.visit_date = s.marker_date and v2.vehicle_id = s.vehicle_id
                  and v2.id not in (select q.id from q)
                  and (v2.start_at is null
                       or ((v2.start_at at time zone 'America/New_York')::time = '00:00:00'::time
                           and v2.end_at is not null and (v2.end_at - v2.start_at) >= '23:00:00'::interval))
                order by c2.client_code)
    from starts s
    left join public.vehicles t on t.id = s.vehicle_id
    left join public.employees e on e.id = s.employee_id
   where exists (select 1 from public.fn_start_first_visit(s.marker_date, s.vehicle_id))
     and not exists (select 1 from public.fn_start_first_visit(s.marker_date, s.vehicle_id,
                                                               array(select q.id from q)))
     and not exists (select 1 from q where q.new_date = s.marker_date and q.new_vehicle = s.vehicle_id
                                         and q.new_timed)
   order by s.marker_date, s.vehicle_id;
end
$function$;

CREATE OR REPLACE FUNCTION ops.refresh_start_flags()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
declare
  v_dates date[];
  v_n     integer;                                                              -- PHASE 2
begin
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  if not public.fn_start_recheck_enabled() then return 0; end if;   -- keep the notes for when it is back on
  perform set_config('lock_timeout', '3s', true);
  with d as (
    delete from ops.start_recheck_queue q
     where q.id in (select id from ops.start_recheck_queue for update skip locked)
    returning q.marker_date)
  select array_agg(distinct marker_date) into v_dates from d;
  -- PHASE 2: also every day that still carries a flag, so a heal that was skipped (a young link, a
  -- missing driver) is retried, and a Start that freezes while flagged is caught within two minutes.
  v_dates := array(
    select distinct x from unnest(coalesce(v_dates, '{}'::date[]) || array(
      select m.marker_date from ops.calendar_day_markers m
       where m.marker_type = 'start' and m.vehicle_id is not null and m.stale_reason is not null)) x);
  if cardinality(v_dates) = 0 then return 0; end if;
  v_n := ops.fn_judge_starts(v_dates);
  -- PHASE 2: a 'first visit changed' needs a drive time: hand it to heal-day-starts. Never let the kick
  -- undo the judging above.
  begin
    perform public.fn_request_start_heal();
  exception when others then
    insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
    values ('start-flags-heal', clock_timestamp(), clock_timestamp(), 'error', 1,
            jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm), jsonb_build_object('action', 'kick'));
  end;
  return v_n;
end
$function$;

CREATE OR REPLACE FUNCTION ops.request_drive_fill(p_from date, p_to date, p_retry_failed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
  v_key  text;
  v_run  timestamptz;
  v_hit  integer;
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'request_drive_fill: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'bad range');
  END IF;
  IF EXISTS (SELECT 1 FROM ops.plan_fill_request r WHERE r.requested_at > now() - interval '10 seconds') THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'recent');
  END IF;
  IF EXISTS (SELECT 1 FROM ops.plan_fill_request r
              WHERE r.range_from <= p_to AND r.range_to >= p_from AND r.requested_at > now() - interval '30 seconds') THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'recent');
  END IF;
  SELECT running_since INTO v_run FROM ops.plan_fill_run WHERE id = 1;
  IF v_run IS NOT NULL AND v_run > now() - interval '3 minutes' THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'busy');
  END IF;
  IF coalesce(p_retry_failed, false) THEN
    DELETE FROM ops.route_leg_fail rf
     USING (SELECT DISTINCT c.o_lat_r, c.o_lng_r, c.d_lat_r, c.d_lng_r FROM ops.fn_drive_chain(p_from, p_to) c WHERE c.seq > 0) p
     WHERE rf.origin_lat_r = p.o_lat_r AND rf.origin_lng_r = p.o_lng_r AND rf.dest_lat_r = p.d_lat_r AND rf.dest_lng_r = p.d_lng_r;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.fn_drive_missing_pairs(p_from, p_to)) THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'nothing missing');
  END IF;
  -- the gate IS the write: two tabs kicking together cannot both post
  INSERT INTO ops.plan_fill_request (range_from, range_to, requested_at) VALUES (p_from, p_to, now())
  ON CONFLICT (range_from, range_to) DO UPDATE SET requested_at = excluded.requested_at
    WHERE ops.plan_fill_request.requested_at < now() - interval '30 seconds';
  GET DIAGNOSTICS v_hit = ROW_COUNT;
  IF v_hit = 0 THEN RETURN jsonb_build_object('queued', false, 'reason', 'recent'); END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, status, details)
    VALUES ('plan-drive-fill', now(), now(), 'error', jsonb_build_object('trigger', 'kick', 'key_missing', true));
    RETURN jsonb_build_object('queued', false, 'reason', 'not set up');
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/plan-drive-fill',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('from', p_from, 'to', p_to, 'trigger', 'kick', 'limit', 60),
    timeout_milliseconds := 120000);
  RETURN jsonb_build_object('queued', true);
END $function$;

CREATE OR REPLACE FUNCTION public.fn_visit_edit_clash(p_visit_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_visit       public.visits;
  v_new_start   timestamptz;
  v_old_vehicle bigint;
  v_new_vehicle bigint;
  v_clash       jsonb;
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  SELECT * INTO v_visit FROM public.visits WHERE id = p_visit_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'visit_not_found',
                              'truck', '[]'::jsonb, 'driver', '[]'::jsonb);
  END IF;

  -- Resolve the EFFECTIVE values first, because a patch that changes only the time must still be
  -- checked against the truck the visit already has. When the patch does not set a truck, take the
  -- CALENDAR's effective one (which may be defaulted from line items), not visits.vehicle_id, or
  -- the check is blind to a defaulted truck.
  v_new_start   := CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE v_visit.start_at END;
  SELECT cv.vehicle_id INTO v_old_vehicle FROM ops.v_calendar_visit cv WHERE cv.id = p_visit_id;
  v_new_vehicle := CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint
                        ELSE v_old_vehicle END;

  -- Refuse ONLY when the edit actually MOVES the visit onto a different truck or a different time.
  -- The Calendar shows an EFFECTIVE truck, so a visit can already display a truck it does not store
  -- (visit 6997 / 032-LG shows Moises with vehicle_source='default'). Pinning that same truck changes
  -- nothing anyone can see and cannot create a clash that did not already exist -- but the first
  -- version of this guard refused it, which is exactly what made "selecting a Truck" look broken.
  IF NOT ((p_patch ? 'start_at' OR p_patch ? 'vehicle_id')
          AND v_new_start IS NOT NULL AND v_new_vehicle IS NOT NULL
          AND (v_new_vehicle IS DISTINCT FROM v_old_vehicle
               OR v_new_start IS DISTINCT FROM v_visit.start_at)) THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'no_move',
                              'truck', '[]'::jsonb, 'driver', '[]'::jsonb);
  END IF;

  v_clash := public.fn_check_visit_clash(v_new_start, v_new_vehicle, NULL, p_visit_id);

  IF jsonb_array_length(v_clash -> 'truck') = 0 THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'clear',
                              'truck', v_clash -> 'truck', 'driver', v_clash -> 'driver');
  END IF;

  -- ===================================================================================
  -- 2026-09-08 KILL SWITCH. Fred: "i need that to be turned off, for now ... it seems
  -- Diego can't work with it." The DETECTOR above still runs and its findings are still
  -- returned, so the clash stays MEASURABLE and the app can still choose to warn; only
  -- the REFUSAL is suppressed. Flip public.app_config.visit_clash_guard_enabled back to
  -- 'true' to restore blocking. This single branch also disables the edge function's
  -- pre-flight check and the drag-and-drop guard, because both read `refuse` from here.
  -- ===================================================================================
  IF NOT public.fn_visit_clash_guard_enabled() THEN
    RETURN jsonb_build_object(
      'refuse',  false,
      'reason',  'guard_disabled',
      'message', format('clash detected but the guard is OFF: truck %s already has %s at %s',
                   COALESCE((SELECT name FROM vehicles WHERE id = v_new_vehicle), v_new_vehicle::text),
                   v_clash -> 'truck' -> 0 ->> 'client_code',
                   v_clash -> 'truck' -> 0 ->> 'start_local'),
      'truck',   v_clash -> 'truck',
      'driver',  v_clash -> 'driver');
  END IF;

  RETURN jsonb_build_object(
    'refuse',  true,
    'reason',  'visit_truck_clash',
    'message', format('visit_truck_clash: truck %s already has %s at %s',
                 COALESCE((SELECT name FROM vehicles WHERE id = v_new_vehicle), v_new_vehicle::text),
                 v_clash -> 'truck' -> 0 ->> 'client_code',
                 v_clash -> 'truck' -> 0 ->> 'start_local'),
    'hint',    'Pick another time or another truck. A visit lasts one hour.',
    'truck',   v_clash -> 'truck',
    'driver',  v_clash -> 'driver');
END
$function$;

CREATE OR REPLACE FUNCTION public.get_record_history(p_table text, p_record_id text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hide_system boolean DEFAULT true, p_limit integer DEFAULT 50, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(entry_id bigint, changed_at timestamp with time zone, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  perform hr.fn_require_any_app(array['visit_calendar', 'client_app'], 'view');   -- 2026-10-21_0900 access phase 5
  IF p_table NOT IN ('visits','clients','derm_manifests','calendar_tasks') THEN
    RAISE EXCEPTION 'get_record_history: table % is not allowed', p_table;
  END IF;
  IF p_record_id IS NULL OR p_record_id = '' THEN
    RAISE EXCEPTION 'get_record_history: p_record_id is required';
  END IF;

  RETURN QUERY
  WITH src AS (
    SELECT l.id, l.table_name, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source,
           (l.jwt_claims->>'email')        AS actor_email,
           -- actor_effective: browser writes carry the email in jwt_claims; headless writers
           -- (save-calendar-visit, save-calendar-task) carry it in request_context.actor_name via the x-actor-name
           -- header. Prefer the JWT, fall back to the header. Kept as a SEPARATE column so the
           -- 'jobber' branch's use of actor_name_ctx (a person NAME, not an email) is untouched.
           COALESCE(NULLIF(l.jwt_claims->>'email',''),
                    NULLIF(l.request_context->>'actor_name','')) AS actor_effective,
           (l.request_context->>'actor_name') AS actor_name_ctx,
           (l.request_context->>'change_reason') AS change_reason_ctx
    FROM audit.logs l
    WHERE (
            (l.table_name = p_table AND l.record_pk->>'id' = p_record_id)
            -- same-visit child-table changes (already-audited M:N tables)
            OR ( p_table = 'visits'
                 AND l.table_name IN ('visit_team','visit_locations')
                 AND COALESCE(l.new_row, l.old_row)->>'visit_id' = p_record_id )
            -- same-task child-table changes: ops.calendar_task_assignees, pk = (task_id, employee_id),
            -- so record_pk->>'id' is NULL on those rows and the first arm can never match them.
            OR ( p_table = 'calendar_tasks'
                 AND l.table_name = 'calendar_task_assignees'
                 AND COALESCE(l.new_row, l.old_row)->>'task_id' = p_record_id )
          )
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      -- p_hide_system suppresses ONLY raw 'sql'/'other'/null noise. Everything with a
      -- meaningful app_source (human apps + every Jobber/cron/backfill source) is ALWAYS
      -- shown (aligns with the documented intent + auto-includes new X-App-Source names).
      AND (NOT p_hide_system
           OR NOT ( l.app_source IS NULL
                    OR l.app_source = 'sql'
                    OR l.app_source LIKE 'other:%' ))
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = l.table_name
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
      -- drop delete-all-reinsert churn on the child M:N tables (no-op within a txid)
      AND NOT (
            l.table_name IN ('visit_team','visit_locations','calendar_task_assignees')
            AND l.operation IN ('INSERT','DELETE')
            AND EXISTS (
              SELECT 1 FROM audit.logs l2
              WHERE l2.table_name = l.table_name
                AND l2.txid = l.txid
                AND l2.operation IN ('INSERT','DELETE')
                AND l2.operation <> l.operation
                AND (COALESCE(l2.new_row, l2.old_row) - 'created_at')
                  = (COALESCE(l.new_row,  l.old_row)  - 'created_at')
            )
          )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
      -- Human edits in one of our apps
      WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
        THEN 'Edited in ' || pg_catalog.initcap(pg_catalog.replace(s.app_source, '-', ' '))
          || COALESCE(
               ' by ' || (SELECT e.full_name FROM public.employees e
                          WHERE pg_catalog.lower(e.email) = pg_catalog.lower(s.actor_effective)
                            AND COALESCE(e.email,'') <> ''
                          ORDER BY e.id LIMIT 1),
               CASE WHEN COALESCE(s.actor_effective,'') <> ''
                         AND s.actor_effective <> 'unclogme@unclogme.com'
                    THEN ' by ' || s.actor_effective ELSE '' END
             )
      -- Viktor, the AI coworker, acting on a person's request in Slack (2026-10-13_0300). Who asked and
      -- why come from public.viktor_set_visit_truck, which sets them itself.
      WHEN s.app_source = 'viktor'
        THEN 'Viktor, asked by ' || COALESCE(NULLIF(pg_catalog.left(s.actor_name_ctx, 120), ''), 'someone not recorded')
          || COALESCE(': "' || NULLIF(pg_catalog.left(s.change_reason_ctx, 300), '') || '"', '')
      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN
        CASE
          -- Calendar Tasks (ops.calendar_tasks), mirrored by poll-calendar-tasks with X-App-Source: jobber.
          -- An assignee child row the poll adds or removes is a CHANGE to the task, never a creation, so
          -- it must not fall into the INSERT arm below. Completion lives in is_complete, not visit_status,
          -- so the visits completion arm below cannot see it.
          WHEN s.table_name = 'calendar_task_assignees'
            THEN 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN s.table_name = 'calendar_tasks' AND s.operation = 'UPDATE'
               AND (s.old_row->>'is_complete') IS DISTINCT FROM (s.new_row->>'is_complete')
            THEN (CASE WHEN (s.new_row->>'is_complete') = 'true' THEN 'Completed in Jobber'
                       ELSE 'Reopened in Jobber' END) || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN s.operation = 'INSERT'
            THEN 'Created in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN (s.old_row->>'visit_status') IS DISTINCT FROM (s.new_row->>'visit_status')
               AND (s.new_row->>'visit_status') = 'completed'
            THEN 'Completed in Jobber' || COALESCE(' by ' || pg_catalog.btrim(pg_catalog.left(s.new_row->>'completed_by', 120)), '')
          ELSE 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
        END
      -- Automated nightly reconcile / drift-heal that pulls our DB into line with Jobber
      WHEN s.app_source LIKE '%reconcile%' OR s.app_source LIKE '%drift%'
           OR s.app_source LIKE 'jobber-daily%' OR s.app_source = 'jobber-reconcile'
        THEN 'System · Synced to match Jobber'
      -- Automated recurring / service-agreement visit generation
      WHEN s.app_source = 'service-agreement-cron' OR s.app_source LIKE 'sa-%'
           OR s.app_source LIKE '%recurring%'
        THEN 'System · Recurring-visit generator'
      -- Automated data corrections / backfills / repairs
      WHEN s.app_source LIKE '%backfill%' OR s.app_source LIKE '%correction%'
           OR s.app_source LIKE '%-fix' OR s.app_source LIKE '%-repair'
        THEN 'System · Data correction'
      -- Other scheduled/system jobs
      WHEN s.app_source LIKE '%-cron' OR s.app_source LIKE 'system:%'
        THEN 'System · Scheduled job'
      -- DUMP Schedule: the truck-QR driver tool. The DRIVER is the actor, but he has no auth
      -- identity (no login by design), so the actor is read off the visit's own assigned driver
      -- rather than actor_email. Reads as "Anthony · DUMP app created this visit".
      WHEN s.app_source = 'dump-schedule' THEN
        COALESCE(
          (SELECT e.full_name FROM public.employees e
            WHERE e.id = NULLIF(s.new_row->>'assigned_driver_id', '')::bigint
            LIMIT 1) || ' · DUMP app',
          'DUMP app')
      -- Generic backend script (Management API / psql / uncategorized)
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review','dump-schedule')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
      WHEN s.table_name <> p_table
        THEN CASE s.operation WHEN 'INSERT' THEN 'added' WHEN 'DELETE' THEN 'removed' ELSE 'updated' END
      WHEN s.operation = 'INSERT' THEN 'created'
      WHEN s.operation = 'DELETE' THEN 'deleted'
      WHEN (s.old_row->>'deleted_at') IS NULL AND (s.new_row->>'deleted_at') IS NOT NULL THEN 'deleted'
      ELSE 'updated'
    END AS operation,
    COALESCE((
      SELECT pg_catalog.jsonb_agg(
               pg_catalog.jsonb_build_object(
                 'field', c.column_name,
                 'label', c.label,
                 'old',   audit.render_value(s.old_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col),
                 'new',   audit.render_value(s.new_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col)
               ) ORDER BY c.sort_order, c.column_name)
      FROM audit.entity_render_config c
      WHERE c.table_name = s.table_name
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION client.cancel_intake(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_at    timestamptz;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.cancel_intake';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.cancel_intake';
  end if;
  perform hr.fn_check_any_app(array['picture_planner', 'client_app'], 'edit', 'cancel a form');   -- 2026-10-20_1600 access phase 3; 2026-10-21_0900 access phase 5: the Client App cancels a link too
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.cancel_intake';
  end if;

  -- The row lock makes a cancel and a collector's submit take turns (see the trigger below).
  select i.id, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id
   for update;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.cancel_intake';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was already cancelled. Its link no longer opens.'
      using errcode = '22023', detail = 'blocker=already_cancelled in client.cancel_intake';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so it stays as a record and cannot be cancelled.'
      using errcode = '22023', detail = 'blocker=submitted in client.cancel_intake';
  end if;

  -- Guarded write: race-safe on its own under READ COMMITTED, the lock above is belt and braces.
  update public.property_intakes
     set cancelled_at = now()
   where id = v_i.id and submitted_at is null and cancelled_at is null
  returning cancelled_at into v_at;
  if not found then
    raise exception 'This form changed a moment ago. Reload the forms to see its state.'
      using errcode = '22023', detail = 'blocker=changed in client.cancel_intake';
  end if;

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'cancelled_at', v_at);
end
$function$;

CREATE OR REPLACE FUNCTION hr.check_app_action(p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_apps text[]; v_level text;
begin
  -- 2026-10-21_0900: each action names the app(s) whose level allows it; several apps = allowed in ANY of them
  select a.apps, a.lvl into v_apps, v_level
    from (values ('send_visit_photos_email',      array['admin_review'], 'edit'),
                 ('rotate_photo',                 array['admin_review'], 'edit'),
                 ('visit_client_note_photos',     array['admin_review'], 'view'),
                 ('send_derm_email',              array['derm_tracker'], 'edit'),
                 ('generate_derm_address_pdf',    array['derm_tracker'], 'edit'),
                 ('generate_derm_address_preview',array['derm_tracker'], 'view'),
                 ('record_manual_gdo_report',     array['derm_tracker'], 'edit'),
                 ('derm_visit_report',            array['derm_tracker'], 'view'),
                 ('create_client',                array['client_app','visit_calendar'], 'edit'),
                 ('save_calendar_task',           array['client_app','visit_calendar'], 'edit'),
                 ('save_client_job',              array['client_app'], 'edit'),
                 ('save_client_property',         array['client_app'], 'edit'),
                 ('save_client_contact',          array['client_app'], 'edit'),
                 ('archive_client',               array['client_app'], 'edit'),
                 ('unarchive_client',             array['client_app'], 'edit'),
                 ('save_client_fields',           array['client_app'], 'edit'),
                 ('parse_gdo_permit',             array['client_app'], 'edit'),
                 ('save_day_marker',              array['visit_calendar'], 'edit'),
                 ('adopt_visit_from_jobber',      array['visit_calendar'], 'edit'),
                 ('push_visit_to_jobber',         array['visit_calendar'], 'edit'),
                 ('save_calendar_visit',          array['visit_calendar'], 'edit'),
                 ('calculate_driving_time',       array['visit_calendar'], 'view')) a(action, apps, lvl)
   where a.action = p_action;
  if v_apps is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  perform hr.fn_check_any_app(v_apps, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$;

CREATE FUNCTION hr.trg_check_zones()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- -- 2026-10-21_0900 access phase 5: public.zones belongs to the Visit Calendar (its zone editor; zones_hard_delete). Edit in the Calendar.
begin
  perform hr.fn_check_app('visit_calendar', 'edit', 'change a zone');
  return coalesce(new, old);
end $function$;
REVOKE ALL ON FUNCTION hr.trg_check_zones() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER aa_access_zones BEFORE INSERT OR UPDATE OR DELETE ON public.zones
  FOR EACH ROW EXECUTE FUNCTION hr.trg_check_zones();

CREATE FUNCTION ops.link_day_marker_dump_visit(p_marker_id bigint, p_dump_visit_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- -- 2026-10-21_0900 access phase 5: the Calendar linked a dump marker to its dump visit with a direct column write
-- (authenticated holds UPDATE on dump_visit_id only, policy calendar_day_markers_rw USING true). Now behind Edit in the
-- Calendar. SECURITY DEFINER widens nothing: it writes that one column, as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in ops.link_day_marker_dump_visit';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in ops.link_day_marker_dump_visit';
  end if;
  perform hr.fn_check_app('visit_calendar', 'edit', 'link a dump visit to its marker');
  update ops.calendar_day_markers set dump_visit_id = p_dump_visit_id where id = p_marker_id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;
REVOKE ALL ON FUNCTION ops.link_day_marker_dump_visit(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.link_day_marker_dump_visit(bigint, bigint) TO authenticated, service_role;

UPDATE hr.access_apps SET mode = 'watch' WHERE app IN ('client_app', 'visit_calendar');

-- VERIFY (rolled back probes; raises only on failure)
DO $v$
DECLARE
  c_fred   text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_yan    text := json_build_object('sub','71e294b9-9898-4c21-a48d-d970e32d829c','email','yannick@ayache.com','role','authenticated')::text;
  c_aaron  text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  c_serena text := json_build_object('sub','5c5df96c-1924-410a-a996-e3e58c44e3c2','email','serena@unclogme.com','role','authenticated')::text;
  c_diego  text := json_build_object('sub','cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8','email','contact@unclogme.com','role','authenticated')::text;
  c_jon    text := json_build_object('sub','8bdb9ba7-e917-466d-bdb1-c525dbf90194','email','jon.v@ayache.com','role','authenticated')::text;
  c_unc    text := json_build_object('sub','ebd7aebe-d77d-4e18-a33d-00e1dc55be9f','email','unclogme@unclogme.com','role','authenticated')::text;
  c_test   text := json_build_object('sub','46ff7904-faef-45c2-8aa2-a5a185c042ec','email','test.agent@ayache.com','role','authenticated')::text;
  claims text; d text; n int; expect int; q text; refused boolean; fails text := ''; v_zone bigint;
  calls text[] := array[
    'client_app|select client.attach_reason_photo(null::text, null::bigint, null::text, null::text, null::integer, null::integer)',
    'client_app|select client.create_client_contact(null::bigint, null::jsonb)',
    'client_app|select client.delete_client_contact(null::bigint)',
    'client_app|select client.generate_visits_for_client(null::bigint)',
    'client_app|select client.remove_reason_photo(null::bigint, null::text)',
    'client_app|select client.save_contact_settings(null::text, null::bigint, null::jsonb)',
    'client_app|select client.schedule_property_intake(null::bigint, null::text[], null::jsonb, null::text)',
    'client_app|select client.update_client_contact(null::bigint, null::jsonb)',
    'client_app|select client.update_client_fields(null::bigint, null::jsonb)',
    'client_app|select client.update_client_status(null::bigint, null::text, null::text)',
    'client_app|select client.update_client_status(null::bigint, null::text)',
    'client_app|select client.update_client_zone(null::bigint, null::bigint)',
    'client_app|select client.update_property_city_email(null::bigint, null::text[])',
    'client_app|select client.upsert_gdo_permit(null::bigint, null::bigint, null::jsonb)',
    'client_app,picture_planner|select client.update_property_capacity(null::bigint, null::integer)',
    'client_app,picture_planner|select client.update_property_operational(null::bigint, null::jsonb)',
    'client_app|select client.get_client_activity(null::bigint, null::boolean, null::integer, null::jsonb)',
    'client_app|select client.preview_client_status_change(null::bigint, null::text)',
    'client_app|select client.preview_job_action(null::bigint, null::bigint, null::text)',
    'visit_calendar|select ops.cancel_visit_request(null::bigint, null::text)',
    'visit_calendar|select ops.create_visit_request(null::bigint, null::bigint, null::bigint[], null::bigint, null::bigint[], null::text, null::text, null::jsonb, null::jsonb, null::bigint, null::bigint[])',
    'visit_calendar|select ops.schedule_visit_request(null::bigint, null::date, null::timestamp with time zone, null::timestamp with time zone, null::bigint, null::bigint[])',
    'visit_calendar|select ops.snooze_call_request(null::bigint, null::date)',
    'visit_calendar|select ops.unschedule_calendar_visit(null::bigint)',
    'visit_calendar|select ops.update_visit_request(null::bigint, null::jsonb)',
    'visit_calendar|select public.create_calendar_visit(null::bigint, null::bigint, null::bigint[], null::date, null::bigint, null::bigint[], null::timestamp with time zone, null::timestamp with time zone, null::text, null::text, null::bigint, null::bigint, null::jsonb, null::bigint[], null::jsonb)',
    'visit_calendar|select public.create_dump_visit(null::bigint, null::bigint, null::bigint[], null::date, null::bigint, null::timestamp with time zone, null::timestamp with time zone, null::text, null::text, null::bigint, null::bigint[], null::boolean, null::bigint)',
    'visit_calendar|select public.delete_calendar_visit(null::bigint)',
    'visit_calendar|select public.edit_calendar_visit(null::bigint, null::jsonb)',
    'visit_calendar|select public.retry_visit_push(null::bigint, null::boolean)',
    'visit_calendar|select public.ripple_reschedule_visit(null::bigint, null::date, null::timestamp with time zone, null::timestamp with time zone, null::boolean)',
    'visit_calendar|select public.set_visit_status(null::bigint, null::text, null::text)',
    'visit_calendar|select public.unskip_visit(null::bigint)',
    'visit_calendar|select ops.calendar_drive_days(null::date, null::date)',
    'visit_calendar|select ops.calendar_grease_estimates(null::date, null::date)',
    'visit_calendar|select ops.preview_sa_reanchor(null::bigint, null::date)',
    'visit_calendar|select ops.preview_start_impact(null::jsonb)',
    'visit_calendar|select ops.refresh_start_flags()',
    'visit_calendar|select ops.request_drive_fill(null::date, null::date, null::boolean)',
    'visit_calendar|select public.fn_visit_edit_clash(null::bigint, null::jsonb)',
    'visit_calendar,client_app|select public.get_record_history(null::text, null::text, null::timestamp with time zone, null::boolean, null::integer, null::jsonb)',
    'picture_planner,client_app|select client.cancel_intake(null::bigint)'];
BEGIN
  select min(id) into v_zone from public.zones;
  BEGIN
    -- V1 WATCH logging through the shared helper and the two own-write paths (calls that SUCCEED; a failing call
    -- rolls its own log row back): the 5 people are never logged; jon.v (no employee) is.
    foreach claims in array array[c_fred, c_yan, c_aaron, c_serena, c_diego, c_jon] loop
      begin
        perform set_config('request.jwt.claims', claims, true);
        perform hr.check_app_action('create_client');          -- either app: logs one row per app
        perform hr.check_app_action('save_client_job');        -- Client App
        perform ops.link_day_marker_dump_visit(-1, null);      -- Calendar (0 rows, succeeds)
        update public.zones set label = label where id = v_zone;   -- Calendar, by trigger
        perform set_config('request.jwt.claims', '', true);
        select count(*) into n from hr.access_refusals where app in ('client_app','visit_calendar') and email = (claims::json->>'email');
        expect := (case when claims = c_jon then 5 else 0 end);   -- create client x2 apps, client job, marker, zone
        if n <> expect then fails := fails || 'V1 ' || (claims::json->>'email') || ' logged ' || n || ' expected ' || expect || E'\n'; end if;
        raise exception 'undo_person';
      exception when raise_exception then
        if sqlerrm <> 'undo_person' then raise; end if;
      when others then
        fails := fails || 'V1 ' || (claims::json->>'email') || ' call failed: ' || sqlerrm || E'\n';
      end;
    end loop;

    -- V2 ON: the 5 people are never refused by the access check; the 3 sign-ins with no employee are refused on every call
    update hr.access_apps set mode = 'on' where app in ('client_app','visit_calendar','picture_planner');
    foreach claims in array array[c_fred, c_yan, c_aaron, c_serena, c_diego, c_jon, c_unc, c_test] loop
      perform set_config('request.jwt.claims', claims, true);
      foreach q in array calls loop
        refused := false;
        begin execute split_part(q, '|', 2); exception when others then
          get stacked diagnostics d = pg_exception_detail;
          refused := coalesce(d,'') like 'blocker=no_access%';
        end;
        if refused <> (claims in (c_jon, c_unc, c_test)) then
          fails := fails || 'V2 ' || (claims::json->>'email') || ' refused=' || refused || ': ' || q || E'\n';
        end if;
      end loop;
      refused := false;
      begin update public.zones set label = label where id = v_zone; exception when others then
        get stacked diagnostics d = pg_exception_detail; refused := coalesce(d,'') like 'blocker=no_access%'; end;
      if refused <> (claims in (c_jon, c_unc, c_test)) then fails := fails || 'V2 zones ' || (claims::json->>'email') || ' refused=' || refused || E'\n'; end if;
    end loop;
    -- V2b a server job (no claims) and the server key are never refused
    perform set_config('request.jwt.claims', '', true);
    begin perform hr.check_app_action('save_client_job'); exception when others then fails := fails || 'V2b no-claims refused' || E'\n'; end;
    perform set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
    begin perform hr.check_app_action('save_calendar_visit'); exception when others then fails := fails || 'V2b service_role refused' || E'\n'; end;

    -- V3 CONTROL: the old body of unskip_visit lets jon through when on (proves V2 can fail)
    perform set_config('request.jwt.claims', c_jon, true);
    execute $ctl$CREATE OR REPLACE FUNCTION public.unskip_visit(p_visit_id bigint)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits;
BEGIN
  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;
  IF v_row.visit_status <> 'skipped' THEN RAISE EXCEPTION 'visit % is not skipped (is %)', p_visit_id, v_row.visit_status; END IF;
  UPDATE public.visits SET visit_status='scheduled', skip_reason=NULL WHERE id=p_visit_id RETURNING * INTO v_row;
  RETURN v_row;
END; $function$
$ctl$;
    refused := false;
    begin perform public.unskip_visit(null::bigint); exception when others then
      get stacked diagnostics d = pg_exception_detail; refused := coalesce(d,'') like 'blocker=no_access%'; end;
    if refused then fails := fails || 'V3 control: the old body still refused' || E'\n'; end if;
    perform set_config('request.jwt.claims', '', true);
    raise exception 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF;
  END;

  -- V4 grants
  if has_function_privilege('anon', 'ops.link_day_marker_dump_visit(bigint,bigint)', 'EXECUTE')
     or has_function_privilege('authenticated', 'hr.fn_check_any_app(text[],text,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'hr.fn_require_any_app(text[],text)', 'EXECUTE') then
    fails := fails || 'V4 a grant is too wide' || E'\n';
  end if;
  -- V5 the spliced bodies carry the phase 5 line, both apps are in watch
  select count(*) into n from pg_proc p where p.prokind = 'f' and p.prolang = (select oid from pg_language where lanname = 'plpgsql')
     and p.pronamespace in ('public'::regnamespace, 'client'::regnamespace, 'ops'::regnamespace, 'hr'::regnamespace)
     and pg_get_functiondef(p.oid) like '%2026-10-21_0900 access phase 5%';
  if n <> 46 then fails := fails || 'V5 bodies with the phase 5 line: ' || n || ' expected 46' || E'\n'; end if;
  if (select count(*) from hr.access_apps where app in ('client_app','visit_calendar') and mode = 'watch') <> 2 then fails := fails || 'V5 mode' || E'\n'; end if;
  if fails <> '' then raise exception 'VERIFY failed:%', E'\n' || fails; end if;
END $v$;
COMMIT;
