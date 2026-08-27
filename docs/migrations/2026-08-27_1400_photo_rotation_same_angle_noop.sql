-- 2026-08-27_1400_photo_rotation_same_angle_noop.sql
--
-- FIX: rotating a photo back to the angle it is ALREADY at raised, and surfaced in Admin Review as
-- "Rotation not saved. Edge Function returned a non-2xx status code".
--
-- HOW IT HAPPENED. Fred rotated a photo four times (270, 90, 270, 90), all four succeeded, leaving
-- storage_path = 'rotated/23212/90.jpg'. Four more clicks coalesce to 90 again, so the service
-- uploaded to the same deterministic path and called this function with
-- p_new_path = p_expected_path = 'rotated/23212/90.jpg'. The guard below raised.
--
-- 🛑 THE GUARD WAS PROTECTING THE WRONG THING. What must never be overwritten is the ORIGINAL, the
-- only copy of the crew's evidence. Refusing "new equals expected" was a proxy for that, and it is
-- both too strict (it refuses a harmless no-op) and too loose (it would happily allow a write to
-- the original path whenever the current path is something else). Now it names the real invariant.
--
-- ⚠ Reproduced before changing anything, rather than inferred:
--     select public.fn_apply_photo_rotation(23212, 'rotated/23212/90.jpg', 'rotated/23212/90.jpg', ...)
--     ERROR 22023: the rotated object must not be written to the source path
--
-- ⚠ Photo 23212 was restored to its original by hand. Its four photo_rotations rows are KEPT: they
-- are the audit record of what happened, and deleting them to tidy up would erase the evidence
-- that made this diagnosis possible.

begin;

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
  select * into v_photo from public.photos where id = p_photo_id for update;
  if not found then
    raise exception 'photo % not found', p_photo_id using errcode = '22023';
  end if;

  -- 🛑 THE REAL INVARIANT: never write over the ORIGINAL. Storage keeps one version per object,
  -- PITR does not cover storage, and 29.2% of photos have no upstream, so the original is the only
  -- copy that exists. This replaces the old "new must differ from expected" test, which refused a
  -- harmless no-op while not actually naming the file it existed to protect.
  if p_new_path = coalesce(v_photo.original_storage_path, v_photo.storage_path) then
    raise exception 'refusing to write a rotated image over the ORIGINAL (%), which is the only copy',
      coalesce(v_photo.original_storage_path, v_photo.storage_path) using errcode = '22023';
  end if;

  -- allowlist, unchanged
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'GT - Visits Images' and o.name = coalesce(v_photo.original_storage_path, v_photo.storage_path)
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

  if v_photo.storage_path is distinct from p_expected_path then
    return jsonb_build_object(
      'applied', false, 'superseded', true,
      'current_storage_path', v_photo.storage_path, 'rotation_deg', v_photo.rotation_deg);
  end if;

  -- ✅ ALREADY AT THIS ANGLE. Four clicks return a photo to where it started, which is a normal
  -- thing for a person to do and must read as success, not as a failed save. The object the service
  -- just uploaded is byte-equivalent to the one already there, so there is nothing to change.
  if v_photo.storage_path = p_new_path and v_photo.rotation_deg = p_absolute_rotation then
    return jsonb_build_object(
      'applied', false, 'superseded', false, 'unchanged', true,
      'photo_id', p_photo_id, 'storage_path', v_photo.storage_path,
      'rotation_deg', v_photo.rotation_deg);
  end if;

  v_first := v_photo.original_storage_path is null;

  update public.photos
     set storage_path          = p_new_path,
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
    'applied', true, 'superseded', false, 'photo_id', p_photo_id,
    'storage_path', p_new_path, 'rotation_deg', p_absolute_rotation,
    'original_storage_path', coalesce(v_photo.original_storage_path, p_expected_path),
    'first_rotation', v_first);
end $fn$;

revoke all on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) from public, anon, authenticated;
grant execute on function public.fn_apply_photo_rotation(bigint,text,text,smallint,smallint,smallint,smallint,bigint,bigint,integer,integer,integer,integer,text,uuid) to service_role;

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare bad text := ''; v jsonb; v_before int; v_after int;
begin
  select count(*) into v_before from public.photo_rotations;

  -- 1. THE BUG: same angle, same path, must now be a clean no-op rather than a raise
  begin
    v := public.fn_apply_photo_rotation(23212,
      (select storage_path from public.photos where id = 23212),
      (select storage_path from public.photos where id = 23212),
      0::smallint, 0::smallint, 0::smallint, 1::smallint, 1, 1, 1, 1, 1, 1, 'verify', null);
    -- photo 23212 now points at its ORIGINAL, so this correctly hits the original-path guard first.
    bad := bad || 'writing over the original was ALLOWED; ';
  exception when others then
    if sqlerrm not like '%over the ORIGINAL%' then
      bad := bad || 'unexpected error on the original-path probe: ' || sqlerrm || '; ';
    end if;
  end;

  -- 2. the same-angle no-op, on a photo whose current path is NOT the original
  --    (simulated in a rolled-back block so no real row is disturbed)
  begin
    update public.photos set storage_path = 'rotated/23212/90.jpg', rotation_deg = 90 where id = 23212;
    v := public.fn_apply_photo_rotation(23212, 'rotated/23212/90.jpg', 'rotated/23212/90.jpg',
      90::smallint, 90::smallint, 90::smallint, 1::smallint, 1, 1, 1, 1, 1, 1, 'verify', null);
    if coalesce(v->>'unchanged', 'false') <> 'true' then
      bad := bad || 'the same-angle case did not report unchanged: ' || coalesce(v::text, 'null') || '; ';
    end if;
    if (v->>'applied') <> 'false' then bad := bad || 'the no-op claimed it applied; '; end if;
    raise exception '__probe_rollback__';
  exception when others then
    if sqlerrm <> '__probe_rollback__' then raise; end if;
  end;

  -- 3. it wrote nothing
  select count(*) into v_after from public.photo_rotations;
  if v_after <> v_before then bad := bad || 'the probes wrote ' || (v_after - v_before) || ' log row(s); '; end if;

  -- 4. control: the probe CAN see a real difference, so a clean result means something
  if (select storage_path from public.photos where id = 23212)
     is distinct from (select original_storage_path from public.photos where id = 23212) then
    bad := bad || 'control failed: photo 23212 no longer points at its original, so the rollback leaked; ';
  end if;

  if bad <> '' then raise exception 'same-angle no-op verification FAILED: %', bad; end if;
  raise notice 'verified: writing over the original still raises, the same-angle case is a clean no-op, nothing written';
end $$;

notify pgrst, 'reload schema';

commit;
