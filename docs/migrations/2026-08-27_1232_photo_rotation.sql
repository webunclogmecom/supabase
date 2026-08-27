-- 2026-08-27_1232_photo_rotation.sql
--
-- Persistent photo rotation for Admin Review. Fred: staff need to rotate a crew photo 90 degrees
-- from the preview modal, and have it stay rotated. Some photos were uploaded upside down; the
-- PIXELS are rotated, confirmed because the capture timestamp burned into the image is upside down
-- too, so an EXIF-tag-only fix would not correct the visible content.
--
-- THE APPROACH (Fred's call): rewrite the image bytes, so the fix is correct in EVERY consumer
-- (Admin Review, the Field Portal, the customer Service Report PDF, the client portal) with no
-- coordination between them. The rotation itself happens in unclogme-pdf-service (Python/Pillow);
-- this migration is the record and the guarded write path.
--
-- 🛑 THE ORIGINAL FILE IS NEVER OVERWRITTEN, AND THAT IS NOT A PREFERENCE.
--   * storage keeps ONE version per object (measured: one version id per object, no history)
--   * PITR does not cover storage objects
--   * 3,514 photos (29.2%) have NO upstream to re-fetch from: 3,490 airtable_migration against a
--     retired system, plus 24 app uploads. For those the stored bytes are the only copy anywhere.
-- So the rotated image goes to a NEW path and photos.storage_path is repointed. Undo is repointing
-- one column. `original_storage_path` is written ONCE and is immutable thereafter.
--
-- Rule 8 (audit opt-in): public.photo_rotations IS audited. It records a change to compliance
-- evidence and names the human who made it. public.photos itself is deliberately NOT given an
-- audit trigger here: it has none today and adding one would log every note-sync INSERT (3,015+
-- rows and climbing) to capture a handful of rotations. The sidecar carries the provenance instead.

begin;

-- ─── 1. photos gains its rotation state ───────────────────────────────────────────────────────
alter table public.photos
  add column if not exists original_storage_path text,
  add column if not exists rotation_deg          smallint not null default 0,
  add column if not exists base_orientation      smallint,
  add column if not exists rotated_at            timestamptz,
  add column if not exists rotated_by            uuid;

comment on column public.photos.original_storage_path is
  'The path of the ORIGINAL, never-rotated object. Written once on the first rotation and immutable '
  'after (trg_photos_original_path_immutable). This is the undo: repoint storage_path back to it. '
  'NULL means the photo has never been rotated and storage_path IS the original.';
comment on column public.photos.rotation_deg is
  'Cumulative rotation applied to the stored bytes, in DISPLAY degrees clockwise from the original '
  'as a viewer saw it. 0/90/180/270. Not a rendering instruction: the pixels are already rotated. '
  'Kept so the UI can offer an exact undo and so a backfill can tell what was done.';
comment on column public.photos.base_orientation is
  'The EXIF Orientation the ORIGINAL file carried (1/3/6/8, or NULL for no Exif). Recorded because '
  'the pixel rotation actually applied is the COMPOSITION of this and what the reviewer asked for.';

-- rotation_deg must stay one of the four legal values even if something writes it directly
alter table public.photos drop constraint if exists photos_rotation_deg_chk;
alter table public.photos add constraint photos_rotation_deg_chk
  check (rotation_deg in (0, 90, 180, 270)) not valid;
alter table public.photos validate constraint photos_rotation_deg_chk;

-- 🛑 original_storage_path is WRITE-ONCE. Without this, a second rotation would overwrite it with
-- the already-rotated path and the true original would become unreachable: the undo would restore
-- a rotated file and nobody would notice, because it still looks like an image.
create or replace function public.tg_photos_original_path_immutable()
returns trigger language plpgsql as $fn$
begin
  if old.original_storage_path is not null
     and new.original_storage_path is distinct from old.original_storage_path then
    raise exception
      'photos.original_storage_path is write-once (photo %, % -> %); it is the only route back to '
      'the unrotated file', old.id, old.original_storage_path, new.original_storage_path
      using errcode = '23514';
  end if;
  return new;
end $fn$;

drop trigger if exists trg_photos_original_path_immutable on public.photos;
create trigger trg_photos_original_path_immutable
  before update on public.photos
  for each row execute function public.tg_photos_original_path_immutable();

-- ─── 2. the append-only record of every rotation ──────────────────────────────────────────────
create table if not exists public.photo_rotations (
  id                    bigint generated always as identity primary key,
  photo_id              bigint not null references public.photos(id) on delete cascade,
  from_storage_path     text   not null,
  to_storage_path       text   not null,
  requested_delta_cw    smallint not null check (requested_delta_cw in (0, 90, 180, 270)),
  absolute_rotation_deg smallint not null check (absolute_rotation_deg in (0, 90, 180, 270)),
  pixel_rotation_cw     smallint not null check (pixel_rotation_cw in (0, 90, 180, 270)),
  source_orientation    smallint,
  source_bytes          bigint,
  result_bytes          bigint,
  width_px              integer,
  height_px             integer,
  app1_bytes_in         integer,
  app1_bytes_out        integer,
  engine                text,
  rotated_by            uuid,
  created_at            timestamptz not null default now(),
  constraint photo_rotations_paths_differ check (to_storage_path <> from_storage_path)
);

create index if not exists photo_rotations_photo_id_idx on public.photo_rotations (photo_id, created_at desc);

comment on table public.photo_rotations is
  'Append-only log of every photo rotation: where the bytes came from, where they went, what angle '
  'was baked, and who asked. Exists because a rotation edits compliance evidence, and because the '
  'from_storage_path chain is what makes the operation reversible past the first step. '
  'The paths-differ CHECK is load-bearing: it makes it structurally impossible to record a rotation '
  'that overwrote its own source.';

-- 🛑 rule 8 opt-in. This is a record of edits to evidence that reaches a municipal FOG office.
drop trigger if exists audit_photo_rotations on public.photo_rotations;
create trigger audit_photo_rotations
  after insert or update or delete on public.photo_rotations
  for each row execute function audit.log_change();

-- ─── 3. grants ────────────────────────────────────────────────────────────────────────────────
-- 🛑 Supabase ALTER DEFAULT PRIVILEGES hands a new public table to `authenticated` BEFORE any GRANT
-- here runs, and a GRANT cannot remove what it did not create. Revoke by NAME. This is the exact
-- trap that left public.lwt_filings wide open on 2026-08-26.
revoke all on public.photo_rotations from public;
revoke all on public.photo_rotations from anon;
revoke all on public.photo_rotations from authenticated;
grant select, insert on public.photo_rotations to service_role;
grant select on public.photo_rotations to authenticated;   -- the app shows "rotated by X" only
alter table public.photo_rotations enable row level security;

-- ─── 4. the guarded write path ────────────────────────────────────────────────────────────────
-- Called by unclogme-pdf-service with the service role AFTER it has written the rotated object and
-- read it back. Does the compare-and-swap plus the log in ONE transaction, so a failure can never
-- leave photos.storage_path pointing at an object whose rotation was not recorded.
create or replace function public.fn_apply_photo_rotation(
  p_photo_id            bigint,
  p_expected_path       text,
  p_new_path            text,
  p_requested_delta_cw  smallint,
  p_absolute_rotation   smallint,
  p_pixel_rotation_cw   smallint,
  p_source_orientation  smallint,
  p_source_bytes        bigint,
  p_result_bytes        bigint,
  p_width_px            integer,
  p_height_px           integer,
  p_app1_bytes_in       integer,
  p_app1_bytes_out      integer,
  p_engine              text,
  p_rotated_by          uuid
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = public, pg_catalog
as $fn$
declare
  v_photo public.photos;
  v_first boolean;
begin
  if p_new_path = p_expected_path then
    raise exception 'the rotated object must not be written to the source path' using errcode = '22023';
  end if;

  select * into v_photo from public.photos where id = p_photo_id for update;
  if not found then
    raise exception 'photo % not found', p_photo_id using errcode = '22023';
  end if;

  -- 🛑 THE ALLOWLIST, and it is structural rather than a UI convention. A DERM manifest sheet or a
  -- redacted client document must never be rotatable: the FP blackout pipeline stores its redaction
  -- bands as PERCENTAGES OF IMAGE HEIGHT, so a rotated sheet would put another client's row on a
  -- regulator-facing document. Proven twice that a sheet cannot be a photos row (zero derm.* objects
  -- depend on public.photos, control 8; and zero overlap between derm.address_row_map.image_url /
  -- stamp_image_url and photos.storage_path, control 12,053). This check is the belt to that braces.
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'GT - Visits Images' and o.name = v_photo.storage_path
  ) then
    raise exception 'photo % is not in the visit-images bucket; refusing to rotate', p_photo_id
      using errcode = '42501';
  end if;

  if exists (
    select 1 from public.photo_links pl
    where pl.photo_id = p_photo_id and pl.deleted_at is null and pl.entity_type = 'derm_manifest'
  ) then
    raise exception 'photo % is linked to a DERM manifest; refusing to rotate compliance evidence',
      p_photo_id using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.photo_links pl
    where pl.photo_id = p_photo_id and pl.deleted_at is null
      and pl.entity_type in ('visit', 'note', 'inspection')
  ) then
    raise exception 'photo % has no live visit, note or inspection link; refusing to rotate', p_photo_id
      using errcode = '42501';
  end if;

  -- Compare-and-swap. A zero-row result means SUPERSEDED (someone rotated it first), not failed.
  if v_photo.storage_path is distinct from p_expected_path then
    return jsonb_build_object(
      'applied', false,
      'superseded', true,
      'current_storage_path', v_photo.storage_path,
      'rotation_deg', v_photo.rotation_deg
    );
  end if;

  v_first := v_photo.original_storage_path is null;

  update public.photos
     set storage_path          = p_new_path,
         -- written once; the immutability trigger enforces it against every other writer too
         original_storage_path = coalesce(original_storage_path, p_expected_path),
         rotation_deg          = p_absolute_rotation,
         base_orientation      = coalesce(base_orientation, p_source_orientation),
         width_px              = p_width_px,
         height_px             = p_height_px,
         size_bytes            = p_result_bytes,
         content_type          = 'image/jpeg',
         rotated_at            = now(),
         rotated_by            = p_rotated_by
   where id = p_photo_id;

  insert into public.photo_rotations (
    photo_id, from_storage_path, to_storage_path, requested_delta_cw, absolute_rotation_deg,
    pixel_rotation_cw, source_orientation, source_bytes, result_bytes, width_px, height_px,
    app1_bytes_in, app1_bytes_out, engine, rotated_by
  ) values (
    p_photo_id, p_expected_path, p_new_path, p_requested_delta_cw, p_absolute_rotation,
    p_pixel_rotation_cw, p_source_orientation, p_source_bytes, p_result_bytes, p_width_px,
    p_height_px, p_app1_bytes_in, p_app1_bytes_out, p_engine, p_rotated_by
  );

  return jsonb_build_object(
    'applied', true,
    'superseded', false,
    'photo_id', p_photo_id,
    'storage_path', p_new_path,
    'rotation_deg', p_absolute_rotation,
    'original_storage_path', coalesce(v_photo.original_storage_path, p_expected_path),
    'first_rotation', v_first
  );
end $fn$;

comment on function public.fn_apply_photo_rotation is
  'Repoints a photo at its rotated copy and logs the rotation, atomically. Called by '
  'unclogme-pdf-service with the service role AFTER the new object is written and verified. '
  'Compare-and-swap on storage_path: a mismatch returns superseded=true rather than raising, so a '
  'rapid second rotation cannot clobber a newer one. SECURITY INVOKER on purpose: service_role '
  'already holds what this needs, so an invoker function cannot widen anything.';

revoke all on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) from public;
revoke all on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) from anon;
revoke all on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) from authenticated;
grant execute on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) to service_role;

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare
  bad text := '';
  v_id bigint;
  v_path text;
  v_res jsonb;
  v_immutable boolean := false;
begin
  -- privileges
  if has_table_privilege('anon', 'public.photo_rotations', 'SELECT') then bad := bad || 'anon can read the log; '; end if;
  if has_table_privilege('authenticated', 'public.photo_rotations', 'INSERT') then bad := bad || 'authenticated can INSERT into the log; '; end if;
  if not has_table_privilege('service_role', 'public.photo_rotations', 'INSERT') then bad := bad || 'service_role cannot INSERT; '; end if;
  if has_function_privilege('authenticated', 'public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid)', 'EXECUTE')
    then bad := bad || 'authenticated can EXECUTE the writer; '; end if;
  -- control: the privilege probe CAN return true
  if not has_table_privilege('authenticated', 'public.photos', 'SELECT') then bad := bad || 'control failed: probe cannot see a grant that exists; '; end if;
  -- rule 8
  if not exists (select 1 from pg_trigger where tgrelid='public.photo_rotations'::regclass and not tgisinternal and tgname='audit_photo_rotations')
    then bad := bad || 'the audit trigger is missing; '; end if;

  -- The immutability trigger must actually bite.
  -- 🛑 The probe is rolled back by its own sentinel rather than cleaned up with an UPDATE, because
  -- the trigger correctly refuses value -> NULL too. The first draft of this block tried to reset
  -- the field and the trigger rejected the migration, which is the check working: write-once means
  -- write-once, including erasure. A nested block is a savepoint, so raising inside it undoes the
  -- probe write and leaves no photo claiming a fake original.
  select id, storage_path into v_id, v_path from public.photos order by id limit 1;
  begin
    update public.photos set original_storage_path = 'probe/first.jpg' where id = v_id;
    begin
      update public.photos set original_storage_path = 'probe/second.jpg' where id = v_id;
      v_immutable := false;
    exception when check_violation then
      v_immutable := true;
    end;
    raise exception '__probe_rollback__';
  exception when others then
    if sqlerrm <> '__probe_rollback__' then raise; end if;
  end;
  if not v_immutable then
    bad := bad || 'original_storage_path was OVERWRITTEN; the undo path can be destroyed; ';
  end if;
  if (select original_storage_path from public.photos where id = v_id) is not null then
    bad := bad || 'the immutability probe leaked a fake original onto photo ' || v_id || '; ';
  end if;

  -- refuse to write the rotated object over its own source
  begin
    v_res := public.fn_apply_photo_rotation(v_id, v_path, v_path, 90::smallint, 90::smallint,
      90::smallint, null, null, null, null, null, null, null, 'probe', null);
    bad := bad || 'writing the rotated object to the SOURCE path was allowed; ';
  exception when others then null;   -- expected
  end;

  -- a stale expected-path must report superseded, never raise and never write
  v_res := public.fn_apply_photo_rotation(v_id, 'definitely/not/the/current/path.jpg', 'rotated/x.jpg',
    90::smallint, 90::smallint, 90::smallint, null, null, null, null, null, null, null, 'probe', null);
  if (v_res->>'superseded') <> 'true' then bad := bad || 'a stale expected-path did not report superseded; '; end if;
  if (select count(*) from public.photo_rotations) <> 0 then bad := bad || 'a superseded call still wrote a log row; '; end if;

  if bad <> '' then
    raise exception 'photo rotation verification FAILED: %', bad;
  end if;
  raise notice 'photo rotation verified: grants, audit trigger, write-once original, source-path refusal, superseded path';
end $$;

notify pgrst, 'reload schema';

commit;
