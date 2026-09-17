-- 2026-09-16_2030_client_reason_photos.sql
--
-- WHAT: images on a Client App "Reason for this change". Up to FIVE images per reason, images
--       only, previewable / replaceable / removable from the app.
--         1. private bucket `reason-photos` + three storage policies (read, insert, delete)
--         2. 'client_status_change' added to photo_links_entity_type_chk; role 'reason_photo'
--         3. fn_photo_link_target_exists gains the client_status_change branch (spliced)
--         4. the authenticated INSERT policy on photo_links refuses the new kind (spliced)
--         5. client.reason_photo_max()                    -> 5, the one place the cap lives
--            client.fn_reason_photo_target_exists(k, id)   -> the whitelist, postgres-only
--            client.fn_reason_photo_path_ok(name)          -> the bucket INSERT gate
--            client.fn_reason_photo_object_removable(name) -> the bucket DELETE gate
--            client.attach_reason_photo(...)               -> the ONLY writer of a reason link
--            client.remove_reason_photo(link_id, reason)   -> soft-deletes the link
--         6. view client.reason_photos (bucket is a column); client.status_changes + photo_count
--         7. client.update_client_status(bigint,text,text) returns status_change_id (spliced,
--            md5-pinned, two lines added)
--
-- WHY (Fred, voice note 2026-09-16): "Besides accepting a text of why the reason of that change, we
--      should also accept some images ... I want a maximum amount of five images per reason ... they
--      have to be images ... No videos, no files, nothing." And on the design: "go to the database,
--      read the architecture, know our rules ... set up a new architecture ... for the photos for the
--      reasons ... have a really good design." Design record:
--      docs/superpowers/specs/2026-09-16-client-reason-photos-design.md
--
-- WHERE THE APP ASKS (audited 2026-09-16, live bundle walked to closure): exactly three typed reason
--      fields. Two feed public.client_status_changes (Edit client -> Status; the header Archive /
--      Reactivate dialog; both through client.update_client_status, INACTIVE via archive-client which
--      calls the same RPC as the caller) and take no images today. The third, the job frequency
--      change, already takes 3 images through save-client-job into `approval-proof`; that path is
--      NOT moved here (see "NOT DONE" below), only its cap is raised to 5 in the edge function.
--
-- 🛑 NO NEW TABLE. ADR 009: "No new per-entity photo tables". The 2026-08-19 audit of the approval
--      proofs re-affirmed it ("a dedicated proof_images table: deliberately NOT recommended"). An
--      image is a photos row plus a photo_links row; this migration adds the layer around them.
--
-- 🛑 THE BROWSER NEVER WRITES photos OR photo_links FOR A REASON PHOTO. The 2026-08-19 audit's core
--      defect was a proof link forgeable from a browser (authenticated holds INSERT on photo_links
--      and the policy asked only auth.uid()). Here the only writer is client.attach_reason_photo,
--      SECURITY DEFINER, which validates the target, the path, the object, its owner, its mimetype
--      and the cap before it inserts; and the authenticated INSERT policy on photo_links refuses
--      entity_type='client_status_change' and role='reason_photo' exactly as it refuses
--      'approval_proof'.
--
-- 🛑 UPLOAD IS DIRECT FROM THE BROWSER, AND THE BUCKET STILL CANNOT HOLD AN OBJECT FOR A CHANGE
--      THAT DID NOT HAPPEN. `approval-proof` gets that invariant by being service_role-only (the
--      edge fn uploads after Jobber confirms). A status change is a DB-only write with nothing to
--      confirm upstream, so the object may exist as soon as the ledger row does; the INSERT policy
--      enforces exactly that: the path must name an EXISTING whitelisted record, in the required
--      shape, and the uploader must be a signed-in staff account. Five base64 images through one
--      edge-fn request would be ~13 MB of JSON; per-image storage upload gives per-tile progress.
--
-- 🛑 REMOVE ACTUALLY REMOVES. The audit measured that "Remove proof" left the object fetchable. Here
--      client.remove_reason_photo soft-deletes the LINK (audited with old_row, so who attached what
--      and when survives) and the app then deletes the OBJECT through the Storage API. A DB-side
--      `DELETE FROM storage.objects` is refused by Supabase's protect_objects_delete trigger ("Use
--      the Storage API instead") so the API is the only route, and the DELETE policy permits only an
--      object that no live reason link points at: an attached image cannot be pulled from under its
--      record, a removed or never-attached one can be cleaned up. No UPDATE policy: an object is
--      immutable once written; replace is remove + upload + attach.
--
-- AUDIT (ADR 010 / rule 8): public.photo_links carries audit_photo_links -> audit.log_change and
--      trg_photo_link_deleted_by, so every attach and remove lands in audit.logs with old_row.
--      public.photos is NOT audited and this migration does not change that: it is a shared table
--      (Jobber note photos, Admin Review uploads) and opting it in is its own decision, as the
--      2026-08-19 audit recorded. storage.objects is not audited (Supabase-owned). Stated, not skipped.
--
-- GRANTS: every new function REVOKEs from public and anon explicitly and asserts
--      has_function_privilege for anon = false (the estate's default-privilege trap). The view gets
--      authenticated SELECT from the schema's default ACL AND explicitly; anon is revoked.
--
-- ⚠ `CREATE OR REPLACE` RULE: the two live bodies touched here (fn_photo_link_target_exists,
--      client.update_client_status 3-arg) are COPIED from pg_get_functiondef with an md5 pin
--      asserted BEFORE the replace, and edited by the smallest possible diff. Nothing retyped.
--
-- NOT DONE HERE, on purpose:
--      * moving the frequency proofs onto this bucket/RPCs (13 objects in approval-proof, and the
--        read tiles pick the bucket by entity kind, so it is a migration of objects, not of rows);
--      * auditing public.photos;
--      * server-side EXIF stripping (the browser canvas re-encode remains the control, as on the
--        frequency path).

begin;

-- =============================================================================================
-- 0. pins. If either live body has moved since this was written, STOP: re-splice, do not apply.
-- =============================================================================================
do $$
declare v_md5 text;
begin
  select md5(pg_get_functiondef(p.oid)) into v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'client' and p.proname = 'update_client_status'
     and pg_get_function_identity_arguments(p.oid) = 'p_client_id bigint, p_status text, p_reason text';
  if v_md5 is distinct from 'e5ffc623376a69e77d4e1476f632c505' then
    raise exception 'PIN FAILED: client.update_client_status(bigint,text,text) is % , expected e5ffc623376a69e77d4e1476f632c505. Re-splice from the live body before applying.', v_md5;
  end if;
  select md5(pg_get_functiondef('public.fn_photo_link_target_exists'::regproc)) into v_md5;
  if v_md5 is distinct from '801ccc5b6a9d742dff7586c94958b502' then
    raise exception 'PIN FAILED: public.fn_photo_link_target_exists is %, expected 801ccc5b6a9d742dff7586c94958b502. Re-splice before applying.', v_md5;
  end if;
  if exists (select 1 from storage.buckets where id = 'reason-photos') then
    raise exception 'PIN FAILED: bucket reason-photos already exists; this migration was applied before or the name is taken';
  end if;
end $$;

-- =============================================================================================
-- 1. the bucket
-- =============================================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('reason-photos', 'reason-photos', false, 5242880, array['image/jpeg','image/png','image/webp']);

-- =============================================================================================
-- 2. the link kind
-- =============================================================================================
alter table public.photo_links drop constraint if exists photo_links_entity_type_chk;
alter table public.photo_links
  add constraint photo_links_entity_type_chk
  check (entity_type = any (array[
    'client_status_change'::text,   -- added 2026-09-16, role 'reason_photo'
    'derm_manifest'::text,
    'inspection'::text,
    'job_frequency_change'::text,   -- added 2026-08-17, role 'approval_proof'
    'note'::text,
    'visit'::text
  ]));

comment on constraint photo_links_entity_type_chk on public.photo_links is
  'Whitelist of photo-owning entity kinds. A new kind needs a migration (ADR 009''s "zero schema '
  'churn" claim does not hold because of this constraint). Roles are app-level; '
  'job_frequency_change uses role=''approval_proof'' (bucket approval-proof, written by save-client-job); '
  'client_status_change uses role=''reason_photo'' (bucket reason-photos, written ONLY by client.attach_reason_photo).';

-- =============================================================================================
-- 3. the dangling-link guard, spliced: the client_status_change branch added, both older branches
--    byte-identical to the live body pinned above.
-- =============================================================================================
create or replace function public.fn_photo_link_target_exists()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
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
  end if;
  return new;
end
$function$;

-- =============================================================================================
-- 4. the browser may not write the new kind. Live expression copied, two exclusions appended.
-- =============================================================================================
drop policy if exists "Authenticated insert photo_links" on public.photo_links;
create policy "Authenticated insert photo_links"
  on public.photo_links
  for insert
  to authenticated
  with check (
    (select auth.uid()) is not null
    and entity_type is distinct from 'job_frequency_change'
    and coalesce(role, '') is distinct from 'approval_proof'
    and entity_type is distinct from 'client_status_change'     -- 2026-09-16
    and coalesce(role, '') is distinct from 'reason_photo'      -- 2026-09-16
  );

-- =============================================================================================
-- 5. the functions
-- =============================================================================================

-- 5a. the cap, in one place. The app may read it; the attach RPC enforces it.
create or replace function client.reason_photo_max()
 returns integer
 language sql
 immutable
 set search_path to ''
as $$ select 5 $$;
comment on function client.reason_photo_max() is
  'Maximum images per reason (Fred, 2026-09-16: "a maximum amount of five images per reason"). '
  'Enforced by client.attach_reason_photo; the app reads it for the "n of 5" counter.';
revoke execute on function client.reason_photo_max() from public;
revoke execute on function client.reason_photo_max() from anon;
grant  execute on function client.reason_photo_max() to authenticated;

-- 5b. the whitelist: which reason-carrying records may own reason photos, and does this one exist.
--     postgres-only; called from the SECURITY DEFINER functions below.
create or replace function client.fn_reason_photo_target_exists(p_entity_type text, p_entity_id bigint)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $$
  select case p_entity_type
    when 'client_status_change' then
      exists (select 1 from public.client_status_changes s where s.id = p_entity_id)
    else false
  end;
$$;
comment on function client.fn_reason_photo_target_exists(text, bigint) is
  'The whitelist of reason-carrying records that may own reason photos, and whether the named one '
  'exists. ONE place: the bucket INSERT gate, the attach RPC and the path check all read it. '
  'Adding a reason site = one WHEN arm here + the photo_links_entity_type_chk value.';
revoke execute on function client.fn_reason_photo_target_exists(text, bigint) from public;
revoke execute on function client.fn_reason_photo_target_exists(text, bigint) from anon;
revoke execute on function client.fn_reason_photo_target_exists(text, bigint) from authenticated;

-- 5c. the bucket INSERT gate. Called by the storage policy AS THE UPLOADER, so it is SECURITY
--     DEFINER (it reads a ledger authenticated cannot see) and EXECUTE-granted to authenticated.
create or replace function client.fn_reason_photo_path_ok(p_name text)
 returns boolean
 language plpgsql
 stable
 security definer
 set search_path to ''
as $$
declare
  v_m     text[];
  v_email text;
begin
  if auth.uid() is null then return false; end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then return false; end if;
  -- client-app/<entity_type>/<entity_id>/<uuid>.<jpg|jpeg|png|webp>
  v_m := regexp_match(p_name,
    '^client-app/([a-z_]+)/([0-9]{1,18})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[.](jpg|jpeg|png|webp)$');
  if v_m is null then return false; end if;
  return client.fn_reason_photo_target_exists(v_m[1], v_m[2]::bigint);
end;
$$;
comment on function client.fn_reason_photo_path_ok(text) is
  'storage.objects INSERT gate for bucket reason-photos: the path must name an EXISTING whitelisted '
  'reason record in the shape client-app/<entity_type>/<entity_id>/<uuid>.<ext>, and the uploader '
  'must be a signed-in staff account. This is what keeps "no object for a change that did not '
  'happen" true on a bucket the browser uploads to directly.';
revoke execute on function client.fn_reason_photo_path_ok(text) from public;
revoke execute on function client.fn_reason_photo_path_ok(text) from anon;
grant  execute on function client.fn_reason_photo_path_ok(text) to authenticated;

-- 5d. the bucket DELETE gate: an object may be deleted only when no LIVE reason link points at it.
create or replace function client.fn_reason_photo_object_removable(p_name text)
 returns boolean
 language plpgsql
 stable
 security definer
 set search_path to ''
as $$
declare v_email text;
begin
  if auth.uid() is null then return false; end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then return false; end if;
  if p_name !~ '^client-app/[a-z_]+/[0-9]{1,18}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$' then return false; end if;
  return not exists (
    select 1
      from public.photo_links pl
      join public.photos p on p.id = pl.photo_id
     where p.storage_path = p_name
       and pl.role = 'reason_photo'
       and pl.deleted_at is null);
end;
$$;
comment on function client.fn_reason_photo_object_removable(text) is
  'storage.objects DELETE gate for bucket reason-photos: true only when no live reason_photo link '
  'references the path. So an attached image cannot be deleted from under its record; a removed '
  '(link soft-deleted) or never-attached object can be cleaned up by the app.';
revoke execute on function client.fn_reason_photo_object_removable(text) from public;
revoke execute on function client.fn_reason_photo_object_removable(text) from anon;
grant  execute on function client.fn_reason_photo_object_removable(text) to authenticated;

-- 5e. THE writer. Validates everything, then inserts photos + photo_links as the owner.
create or replace function client.attach_reason_photo(
  p_entity_type  text,
  p_entity_id    bigint,
  p_storage_path text,
  p_file_name    text default null,
  p_width_px     integer default null,
  p_height_px    integer default null
) returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $$
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
$$;
comment on function client.attach_reason_photo(text, bigint, text, text, integer, integer) is
  'The ONLY writer of a reason_photo link. Order: staff gate -> target exists -> path names THIS '
  'record -> advisory lock per record -> idempotent on the same path -> cap (client.reason_photo_max) '
  '-> object exists in bucket reason-photos, owned by the caller, mimetype image/* (read from the '
  'object, never from the caller) -> photos + photo_links. Returns the client.reason_photos row plus '
  'remaining. MESSAGE is for the operator; DETAIL carries blocker=<code>.';
revoke execute on function client.attach_reason_photo(text, bigint, text, text, integer, integer) from public;
revoke execute on function client.attach_reason_photo(text, bigint, text, text, integer, integer) from anon;
grant  execute on function client.attach_reason_photo(text, bigint, text, text, integer, integer) to authenticated;

-- 5f. remove: soft-delete the link. The app then deletes the object through the Storage API
--     (the DELETE policy allows it once no live link points at the path).
create or replace function client.remove_reason_photo(p_link_id bigint, p_reason text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $$
declare
  v_email text;
  v_link  record;
  v_live  integer;
begin
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
$$;
comment on function client.remove_reason_photo(bigint, text) is
  'Soft-deletes a reason_photo link (audit.logs keeps old_row: who attached what, when). Returns the '
  'bucket + storage_path so the app can then delete the OBJECT through the Storage API, which the '
  'reason_photos_staff_delete policy allows once no live link references it. The file is gone after '
  'both steps; the record of it is not.';
revoke execute on function client.remove_reason_photo(bigint, text) from public;
revoke execute on function client.remove_reason_photo(bigint, text) from anon;
grant  execute on function client.remove_reason_photo(bigint, text) to authenticated;

-- =============================================================================================
-- 6. the views
-- =============================================================================================
create or replace view client.reason_photos as
select pl.id                    as link_id,
       pl.entity_type,
       pl.entity_id,
       'reason-photos'::text    as bucket,       -- a COLUMN, so nobody signs against the wrong bucket
       p.storage_path,
       p.file_name,
       p.content_type,
       p.size_bytes,
       p.width_px,
       p.height_px,
       pl.caption               as uploaded_by,
       pl.created_at            as uploaded_at,
       p.id                     as photo_id
  from public.photo_links pl
  join public.photos p on p.id = pl.photo_id
 where pl.role = 'reason_photo'
   and pl.deleted_at is null;
comment on view client.reason_photos is
  'One row per LIVE reason photo (role reason_photo). bucket is a column on purpose: photos.storage_path '
  'does not carry the bucket and the Client App CLAUDE.md records the wrong-bucket signing trap. '
  'Write through client.attach_reason_photo / client.remove_reason_photo only.';
revoke all on client.reason_photos from public;
revoke all on client.reason_photos from anon;
grant select on client.reason_photos to authenticated;

-- client.status_changes: same eight columns in the same order, photo_count APPENDED.
create or replace view client.status_changes as
select s.id,
       s.client_id,
       s.old_status,
       s.new_status,
       s.reason,
       s.changed_by_email,
       s.visits_removed,
       s.changed_at,
       (select count(*)::integer
          from public.photo_links pl
         where pl.entity_type = 'client_status_change'
           and pl.entity_id = s.id
           and pl.role = 'reason_photo'
           and pl.deleted_at is null) as photo_count
  from public.client_status_changes s;
revoke all on client.status_changes from public;
revoke all on client.status_changes from anon;
grant select on client.status_changes to authenticated;

-- =============================================================================================
-- 7. client.update_client_status returns status_change_id. Live body (md5 e5ffc623..., pinned
--    above) with exactly two edits: `returning id into v_change_id` and the key in the return
--    object; `'status_change_id', null` on the no-op branch so the key is always present.
-- =============================================================================================
create or replace function client.update_client_status(p_client_id bigint, p_status text, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_old    text;
  v_row    public.clients;
  v_before int;
  v_after  int;
  v_removed int;
  v_email  text;
  v_change_id bigint;   -- 2026-09-16: the ledger row, so the app can attach reason photos to it
begin
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

-- =============================================================================================
-- 8. the storage policies (after the functions they call exist)
-- =============================================================================================
drop policy if exists reason_photos_staff_read   on storage.objects;
drop policy if exists reason_photos_staff_insert on storage.objects;
drop policy if exists reason_photos_staff_delete on storage.objects;

create policy reason_photos_staff_read on storage.objects
  for select to authenticated
  using (bucket_id = 'reason-photos' and auth.uid() is not null);

create policy reason_photos_staff_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'reason-photos' and client.fn_reason_photo_path_ok(name));

create policy reason_photos_staff_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'reason-photos' and client.fn_reason_photo_object_removable(name));

-- =============================================================================================
-- 9. VERIFY. Structure first, then the whole path EXERCISED as `authenticated` with a simulated
--    JWT inside a sub-block that is always rolled back (the flags survive the rollback; the rows
--    do not). Every refusal has a matching acceptance beside it, so a guard that refuses everything
--    cannot pass.
-- =============================================================================================
do $$
declare
  v_pub      boolean;
  n          integer;
  v_md5      text;
  v_uid      uuid;
  v_client   bigint;
  v_change   bigint;
  v_change2  bigint;
  v_good     text;
  v_foreign  text;
  v_other    text;
  v_paths    text[] := '{}';
  v_link     jsonb;
  v_links    bigint[] := '{}';
  v_rem      jsonb;
  v_res      jsonb;
  i          integer;
  -- flags set inside the rolled-back probe
  f_path_ok        boolean := false;
  f_path_badkind   boolean := false;
  f_path_missing   boolean := false;
  f_path_shape     boolean := false;
  f_ins_ok         boolean := false;
  f_ins_refused    boolean := false;
  f_attach_ok      boolean := false;
  f_attach_idem    boolean := false;
  f_view_1         boolean := false;
  f_count_1        boolean := false;
  f_attach_foreign boolean := false;
  f_attach_noobj   boolean := false;
  f_attach_owner   boolean := false;
  f_cap            boolean := false;
  f_forge_kind     boolean := false;
  f_forge_role     boolean := false;
  f_removable_no   boolean := false;
  f_remove_ok      boolean := false;
  f_removable_yes  boolean := false;
  f_remove_twice   boolean := false;
  f_audit_oldrow   boolean := false;
  f_rpc_noop       boolean := false;
  f_rpc_id         boolean := false;
begin
  -- (A) bucket private, with a public bucket as the control
  select public into v_pub from storage.buckets where id = 'reason-photos';
  if v_pub is distinct from false then raise exception 'reason-photos is not private'; end if;
  select public into v_pub from storage.buckets where id = 'GT - Visits Images';
  if v_pub is distinct from true then
    raise exception 'CONTROL FAILED: GT - Visits Images is not public, so public/private is not distinguishable here';
  end if;
  select count(*) into n from storage.buckets where id = 'reason-photos'
     and allowed_mime_types = array['image/jpeg','image/png','image/webp'] and file_size_limit = 5242880;
  if n <> 1 then raise exception 'bucket settings did not land'; end if;

  -- (B) exactly three policies on the bucket: read, insert, delete. No update.
  select count(*) into n from pg_policy
   where polrelid = 'storage.objects'::regclass and polname like 'reason_photos_%';
  if n <> 3 then raise exception 'expected 3 reason_photos policies, found %', n; end if;
  select count(*) into n from pg_policy
   where polrelid = 'storage.objects'::regclass and polcmd = 'w'
     and (coalesce(pg_get_expr(polqual, polrelid),'') like '%reason-photos%'
       or coalesce(pg_get_expr(polwithcheck, polrelid),'') like '%reason-photos%');
  if n <> 0 then raise exception 'an UPDATE policy references reason-photos; objects must be immutable'; end if;

  -- (C) grants: anon holds nothing, authenticated holds what the app needs
  if has_function_privilege('anon', 'client.attach_reason_photo(text,bigint,text,text,integer,integer)', 'EXECUTE')
     or has_function_privilege('anon', 'client.remove_reason_photo(bigint,text)', 'EXECUTE')
     or has_function_privilege('anon', 'client.fn_reason_photo_path_ok(text)', 'EXECUTE')
     or has_function_privilege('anon', 'client.fn_reason_photo_object_removable(text)', 'EXECUTE')
     or has_function_privilege('anon', 'client.fn_reason_photo_target_exists(text,bigint)', 'EXECUTE')
     or has_function_privilege('anon', 'client.reason_photo_max()', 'EXECUTE')
     or has_function_privilege('authenticated', 'client.fn_reason_photo_target_exists(text,bigint)', 'EXECUTE')
     or has_table_privilege('anon', 'client.reason_photos', 'SELECT') then
    raise exception 'GRANT FAILED: anon (or authenticated on the whitelist fn) holds a privilege it must not';
  end if;
  if not (has_function_privilege('authenticated', 'client.attach_reason_photo(text,bigint,text,text,integer,integer)', 'EXECUTE')
      and has_function_privilege('authenticated', 'client.remove_reason_photo(bigint,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'client.reason_photo_max()', 'EXECUTE')
      and has_table_privilege('authenticated', 'client.reason_photos', 'SELECT')
      and has_table_privilege('authenticated', 'client.status_changes', 'SELECT')) then
    raise exception 'GRANT FAILED: authenticated is missing a privilege the app needs';
  end if;
  -- the two policy gates are called AS the uploader, so authenticated needs EXECUTE on them
  if not (has_function_privilege('authenticated', 'client.fn_reason_photo_path_ok(text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'client.fn_reason_photo_object_removable(text)', 'EXECUTE')) then
    raise exception 'GRANT FAILED: the storage policy gates are not executable by authenticated';
  end if;

  -- (D) the spliced RPC: body changed, key present, positive control on an unchanged line
  select md5(pg_get_functiondef(p.oid)) into v_md5
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'client' and p.proname = 'update_client_status'
     and pg_get_function_identity_arguments(p.oid) = 'p_client_id bigint, p_status text, p_reason text';
  if v_md5 = 'e5ffc623376a69e77d4e1476f632c505' then raise exception 'the RPC splice did not land'; end if;
  select count(*) into n from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'client' and p.proname = 'update_client_status'
     and pg_get_function_identity_arguments(p.oid) = 'p_client_id bigint, p_status text, p_reason text'
     and p.prosrc like '%status_change_id%'
     and p.prosrc like '%status_source = ''manual''%'      -- the 2026-08-13 pin survived the splice
     and p.prosrc like '%fn_is_current_sa_job%';           -- the 2026-08-01 gate survived the splice
  if n <> 1 then raise exception 'the spliced RPC lost a line it must keep'; end if;

  -- (E) views: column order preserved on status_changes, photo_count appended at position 9
  select count(*) into n from information_schema.columns
   where table_schema = 'client' and table_name = 'status_changes'
     and ((ordinal_position, column_name) in ((1,'id'),(2,'client_id'),(3,'old_status'),(4,'new_status'),
          (5,'reason'),(6,'changed_by_email'),(7,'visits_removed'),(8,'changed_at'),(9,'photo_count')));
  if n <> 9 then raise exception 'client.status_changes columns are not the expected 8 + photo_count (matched %)', n; end if;
  select count(*) into n from information_schema.columns
   where table_schema = 'client' and table_name = 'reason_photos' and column_name = 'bucket';
  if n <> 1 then raise exception 'client.reason_photos has no bucket column'; end if;

  -- (F) the whole path, as authenticated, rolled back
  select id into v_uid from auth.users where email = 'fred@ayache.com';
  if v_uid is null then raise exception 'CONTROL FAILED: no auth user fred@ayache.com to simulate'; end if;
  select id into v_client from public.clients where client_code = '112-YA';
  if v_client is null then raise exception 'CONTROL FAILED: test client 112-YA missing'; end if;

  begin
    -- as postgres: two probe ledger rows and the objects the "browser" would have uploaded
    insert into public.client_status_changes (client_id, old_status, new_status, reason, changed_by, changed_by_email)
    values (v_client, 'ACTIVE', 'PAUSED', 'probe 2026-09-16 reason photos', v_uid, 'fred@ayache.com')
    returning id into v_change;
    insert into public.client_status_changes (client_id, old_status, new_status, reason, changed_by, changed_by_email)
    values (v_client, 'PAUSED', 'ACTIVE', 'probe 2026-09-16 reason photos (2)', v_uid, 'fred@ayache.com')
    returning id into v_change2;

    for i in 1..6 loop
      v_paths := v_paths || ('client-app/client_status_change/' || v_change || '/' || gen_random_uuid()::text || '.jpg');
    end loop;
    v_good := v_paths[1];
    -- five objects for v_change owned by the caller, one for v_change2, one owned by someone else
    for i in 1..6 loop
      insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
      values ('reason-photos', v_paths[i], v_uid, v_uid::text,
              jsonb_build_object('mimetype','image/jpeg','size','12345'));
    end loop;
    v_foreign := 'client-app/client_status_change/' || v_change2 || '/' || gen_random_uuid()::text || '.jpg';
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    values ('reason-photos', v_foreign, v_uid, v_uid::text, jsonb_build_object('mimetype','image/jpeg','size','1'));
    v_other := 'client-app/client_status_change/' || v_change || '/' || gen_random_uuid()::text || '.png';
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    values ('reason-photos', v_other, gen_random_uuid(), gen_random_uuid()::text, jsonb_build_object('mimetype','image/png','size','1'));

    -- now become the staff browser
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);

    -- F1 the path gate
    f_path_ok      := client.fn_reason_photo_path_ok(v_good);
    f_path_badkind := not client.fn_reason_photo_path_ok(replace(v_good, 'client_status_change', 'job_frequency_change'));
    f_path_missing := not client.fn_reason_photo_path_ok('client-app/client_status_change/999999999/' || gen_random_uuid()::text || '.jpg');
    f_path_shape   := not client.fn_reason_photo_path_ok('client-app/client_status_change/' || v_change || '/evil.jpg')
                  and not client.fn_reason_photo_path_ok('client-app/client_status_change/' || v_change || '/' || gen_random_uuid()::text || '.pdf');

    -- F2 the bucket INSERT policy, exercised: a good path lands, a bad one is refused
    begin
      insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
      values ('reason-photos', 'client-app/client_status_change/' || v_change || '/' || gen_random_uuid()::text || '.webp',
              v_uid, v_uid::text, jsonb_build_object('mimetype','image/webp','size','1'));
      f_ins_ok := true;
    exception when others then f_ins_ok := false; end;
    begin
      insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
      values ('reason-photos', 'client-app/client_status_change/999999999/' || gen_random_uuid()::text || '.jpg',
              v_uid, v_uid::text, jsonb_build_object('mimetype','image/jpeg','size','1'));
      f_ins_refused := false;
    exception when insufficient_privilege then f_ins_refused := true; end;

    -- F3 attach: accepted, idempotent, visible in the view and the count
    v_link := client.attach_reason_photo('client_status_change', v_change, v_good, 'proof.jpg', 640, 480);
    f_attach_ok := (v_link ->> 'link_id') is not null and (v_link ->> 'bucket') = 'reason-photos'
                   and (v_link ->> 'uploaded_by') = 'fred@ayache.com' and (v_link ->> 'remaining') = '4'
                   and (v_link ->> 'size_bytes') = '12345';
    v_res := client.attach_reason_photo('client_status_change', v_change, v_good, 'proof.jpg', 640, 480);
    f_attach_idem := (v_res ->> 'link_id') = (v_link ->> 'link_id');
    select count(*) into n from client.reason_photos where entity_type = 'client_status_change' and entity_id = v_change;
    f_view_1 := (n = 1);
    select photo_count into n from client.status_changes where id = v_change;
    f_count_1 := (n = 1);

    -- F4 refusals: a path belonging to another change; a path with no object; an object owned by someone else
    begin
      perform client.attach_reason_photo('client_status_change', v_change, v_foreign);
      f_attach_foreign := false;
    exception when others then f_attach_foreign := (sqlerrm like 'This image was uploaded for a different change%'); end;
    begin
      perform client.attach_reason_photo('client_status_change', v_change,
        'client-app/client_status_change/' || v_change || '/' || gen_random_uuid()::text || '.jpg');
      f_attach_noobj := false;
    exception when others then f_attach_noobj := (sqlerrm like 'The image did not finish uploading%'); end;
    begin
      perform client.attach_reason_photo('client_status_change', v_change, v_other);
      f_attach_owner := false;
    exception when others then f_attach_owner := (sqlerrm like 'This image was uploaded by someone else%'); end;

    -- F5 the cap: four more land (5 live), the sixth is refused in plain words
    for i in 2..5 loop
      v_res := client.attach_reason_photo('client_status_change', v_change, v_paths[i]);
      v_links := v_links || (v_res ->> 'link_id')::bigint;
    end loop;
    begin
      perform client.attach_reason_photo('client_status_change', v_change, v_paths[6]);
      f_cap := false;
    exception when others then f_cap := (sqlerrm = 'This change already has 5 images. Remove one before adding another.'); end;

    -- F6 the forgery hole stays closed: a browser-shaped INSERT of the new kind is refused by policy
    begin
      insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
      values ((select photo_id from client.reason_photos where link_id = (v_link ->> 'link_id')::bigint),
              'client_status_change', v_change2, 'reason_photo', 'forged');
      f_forge_kind := false;
    exception when insufficient_privilege then f_forge_kind := true; end;
    begin
      insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
      values ((select photo_id from client.reason_photos where link_id = (v_link ->> 'link_id')::bigint),
              'visit', (select id from public.visits where deleted_at is null order by id desc limit 1), 'reason_photo', 'forged');
      f_forge_role := false;
    exception when insufficient_privilege then f_forge_role := true; end;

    -- F7 remove: not removable while attached; soft-delete; removable after; twice is refused
    f_removable_no := not client.fn_reason_photo_object_removable(v_good);
    v_rem := client.remove_reason_photo((v_link ->> 'link_id')::bigint);
    f_remove_ok := (v_rem ->> 'storage_path') = v_good and (v_rem ->> 'live') = '4' and (v_rem ->> 'remaining') = '1';
    f_removable_yes := client.fn_reason_photo_object_removable(v_good)
                   and client.fn_reason_photo_object_removable(v_paths[6]);     -- never attached = orphan, removable
    begin
      perform client.remove_reason_photo((v_link ->> 'link_id')::bigint);
      f_remove_twice := false;
    exception when others then f_remove_twice := (sqlerrm = 'This image has already been removed.'); end;
    select count(*) into n from audit.logs
     where table_name = 'photo_links' and operation = 'UPDATE'
       and (record_pk ->> 'id')::bigint = (v_link ->> 'link_id')::bigint
       and old_row is not null and (old_row ->> 'deleted_at') is null and (new_row ->> 'deleted_at') is not null;
    f_audit_oldrow := (n = 1);

    -- F8 the spliced RPC: no-op branch carries the key as null; a real transition returns the new row's id
    v_res := client.update_client_status(v_client, (select status from public.clients where id = v_client), 'probe noop');
    f_rpc_noop := (v_res ? 'status_change_id') and (v_res -> 'status_change_id') = 'null'::jsonb and (v_res ->> 'noop') = 'true';
    v_res := client.update_client_status(v_client, 'PAUSED', 'probe 2026-09-16: real transition, rolled back');
    f_rpc_id := (v_res ->> 'status_change_id')::bigint = (select max(id) from client.status_changes where client_id = v_client)   -- through the view: authenticated holds no grant on the ledger
            and (v_res ->> 'previous_status') is not null;

    raise exception 'PROBE_ROLLBACK';
  exception
    when others then
      if sqlerrm <> 'PROBE_ROLLBACK' then raise; end if;
  end;
  execute 'reset role';

  if not f_path_ok        then raise exception 'F1: a well-formed path for an existing change was refused by the path gate'; end if;
  if not f_path_badkind   then raise exception 'F1: a non-whitelisted kind passed the path gate'; end if;
  if not f_path_missing   then raise exception 'F1: a path naming a missing change passed the path gate'; end if;
  if not f_path_shape     then raise exception 'F1: a malformed path passed the path gate'; end if;
  if not f_ins_ok         then raise exception 'F2: the bucket INSERT policy refused a good upload'; end if;
  if not f_ins_refused    then raise exception 'F2: the bucket INSERT policy accepted an upload for a missing change'; end if;
  if not f_attach_ok      then raise exception 'F3: attach did not return the expected row'; end if;
  if not f_attach_idem    then raise exception 'F3: attach is not idempotent on the same path'; end if;
  if not f_view_1         then raise exception 'F3: client.reason_photos does not show the attached image'; end if;
  if not f_count_1        then raise exception 'F3: client.status_changes.photo_count is not 1'; end if;
  if not f_attach_foreign then raise exception 'F4: an object uploaded for another change was attachable'; end if;
  if not f_attach_noobj   then raise exception 'F4: a path with no object was attachable'; end if;
  if not f_attach_owner   then raise exception 'F4: an object owned by someone else was attachable'; end if;
  if not f_cap            then raise exception 'F5: the sixth image was not refused with the plain-language message'; end if;
  if not f_forge_kind     then raise exception 'F6: a browser-shaped photo_links INSERT of client_status_change was NOT refused'; end if;
  if not f_forge_role     then raise exception 'F6: a browser-shaped photo_links INSERT with role reason_photo was NOT refused'; end if;
  if not f_removable_no   then raise exception 'F7: an attached object reads as removable'; end if;
  if not f_remove_ok      then raise exception 'F7: remove did not return the expected row'; end if;
  if not f_removable_yes  then raise exception 'F7: a removed / orphan object does not read as removable'; end if;
  if not f_remove_twice   then raise exception 'F7: removing twice was not refused'; end if;
  if not f_audit_oldrow   then raise exception 'F7: audit.logs did not capture the soft-delete with old_row'; end if;
  if not f_rpc_noop       then raise exception 'F8: the no-op branch does not carry status_change_id: null'; end if;
  if not f_rpc_id         then raise exception 'F8: a real transition did not return its ledger id'; end if;

  -- (G) nothing from the probe survived
  select count(*) into n from public.client_status_changes where reason like 'probe 2026-09-16%';
  if n <> 0 then raise exception 'probe ledger rows survived (%)', n; end if;
  select count(*) into n from storage.objects where bucket_id = 'reason-photos';
  if n <> 0 then raise exception 'probe objects survived (%)', n; end if;
  select count(*) into n from public.photo_links where role = 'reason_photo';
  if n <> 0 then raise exception 'probe links survived (%)', n; end if;

  raise notice 'OK: bucket private + 3 policies; whitelist, path gate, attach (idempotent, capped at 5, owner-checked), forgery refused, remove audited, RPC returns status_change_id; probe rolled back clean';
end $$;

commit;
