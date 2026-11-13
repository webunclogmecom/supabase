-- ROLLBACK of 2026-11-13_1600_derm_visit_sheets_follow_manifest_life.sql (Trello #192)
--
-- Puts public.record_manifest_visit_sheet back to its 2026-10-20_1700 body (verbatim, md5 4339ddcc46f82cbea933da9097907a1b)
-- and drops the two triggers and derm.fn_retire_visit_sheets(). Guarded: refuses unless the live body is the one
-- 2026-11-13_1600 applied (md5 b47675311f8b46848c557bf8493a196d as stored; the guards compare the body with its
-- carriage returns removed, 8ffc030f... before and bff8d24a... after, because the live body has Windows line breaks
-- and git changes them in this file, so a byte md5 could never match a checkout).
--
-- It does NOT un-retire sheet rows. A retired row sits on a deleted manifest or an unlinked visit, where no reader shows
-- it, and its number may already be live again on the visit's new manifest (Diego's 317956 sheets 10103, 10104, 10105,
-- 10107 once he attaches them), so putting it back would collide with manifest_visit_sheets_sheet_no_uniq. After this
-- rollback a delete or an unlink leaves the sheet live again, and a re-file of such a visit is refused with 409 (the bug).

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure), chr(13), '')) <> '8ffc030f766b602b9fd0a279a0488571' then
    raise exception 'public.record_manifest_visit_sheet is not the 2026-11-13_1600 body; do not roll back blindly';
  end if;
end
$pin$;

drop trigger trg_zs_retire_visit_sheet_on_unlink on public.manifest_visits;
drop trigger trg_zs_retire_visit_sheets_on_delete on public.derm_manifests;
drop function derm.fn_retire_visit_sheets();

CREATE OR REPLACE FUNCTION public.record_manifest_visit_sheet(p_manifest_id bigint, p_visit_id bigint, p_photo_bucket text, p_photo_path text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm', 'pg_temp'
AS $function$
declare
  v_client  bigint;
  v_bucket  text;
  v_sheet   bigint;
begin
  perform hr.fn_check_app('derm_tracker', 'edit', 'record a visit address sheet');   -- 2026-10-20_1700 access phase 4
  if p_manifest_id is null or p_visit_id is null then
    raise exception 'A manifest and a visit are both required to record an address sheet.'
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_photo_bucket), '') = '' or coalesce(btrim(p_photo_path), '') = '' then
    raise exception 'The uploaded sheet needs both a storage bucket and a path. Got bucket %, path %.',
      coalesce(quote_literal(p_photo_bucket), 'NULL'), coalesce(quote_literal(p_photo_path), 'NULL')
      using errcode = '22023';
  end if;

  select m.client_id into v_client
    from public.derm_manifests m
   where m.id = p_manifest_id and m.deleted_at is null;

  if v_client is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- The visit must be ON this manifest. See refusal 2 in the header.
  if not exists (select 1 from public.manifest_visits mv
                  where mv.manifest_id = p_manifest_id and mv.visit_id = p_visit_id) then
    raise exception 'Visit % is not linked to manifest %, so a sheet cannot be attached to it. Link the visit first.',
      p_visit_id, p_manifest_id
      using errcode = '22023';
  end if;

  v_bucket := derm.fn_manifest_dump_bucket(p_manifest_id);
  if v_bucket <> 'BROWARD' then
    raise exception 'Manifest % was dumped at a % site. One address sheet per visit is the Broward FDEP form only; a Miami-Dade sheet covers several clients at once.',
      p_manifest_id, v_bucket
      using errcode = '22023';
  end if;

  -- Allocate a number only the first time. See the header: the paper is already printed.
  select s.sheet_no into v_sheet
    from derm.manifest_visit_sheets s
   where s.manifest_id = p_manifest_id and s.visit_id = p_visit_id;

  -- ===================== ADOPTION (2026-09-07_2240) =======================
  -- If the office GENERATED a sheet for this visit, the driver is holding paper
  -- with that number on it. Adopt it. Minting here instead would put a second,
  -- different number in the register for the same physical sheet, and nothing
  -- in the schema could see the divergence: the unique index on sheet_no is
  -- per-row within this table and cannot reach the generation register.
  if v_sheet is null then
    select g.sheet_no into v_sheet
      from derm.generated_visit_sheets g
     where g.visit_id = p_visit_id and g.deleted_at is null;
  end if;
  -- ========================================================================

  -- Still null means genuinely un-generated: a sheet filled on a blank pad the
  -- office never printed. That is how every Broward manifest in history was
  -- filed, so it stays supported rather than refused.
  if v_sheet is null then
    v_sheet := nextval('public.derm_broward_address_seq');
  end if;

  insert into derm.manifest_visit_sheets
    (manifest_id, visit_id, client_id, sheet_no, photo_bucket, photo_path, uploaded_at, deleted_at)
  values
    (p_manifest_id, p_visit_id, v_client, v_sheet, btrim(p_photo_bucket), btrim(p_photo_path), now(), null)
  on conflict (manifest_id, visit_id) do update
    set photo_bucket = excluded.photo_bucket,
        photo_path   = excluded.photo_path,
        uploaded_at  = excluded.uploaded_at,
        deleted_at   = null;
        -- sheet_no deliberately NOT updated: the number is on paper the driver carried.

  return v_sheet;
end;
$function$
;

do $verify$
begin
  if md5(replace(pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure), chr(13), '')) <> 'bff8d24ad9cb3588a518d1fe086aed8e' then
    raise exception 'VERIFY: record_manifest_visit_sheet is not back to the 2026-10-20_1700 body';
  end if;
  if to_regprocedure('derm.fn_retire_visit_sheets()') is not null then
    raise exception 'VERIFY: derm.fn_retire_visit_sheets() still exists';
  end if;
end
$verify$;

COMMIT;
