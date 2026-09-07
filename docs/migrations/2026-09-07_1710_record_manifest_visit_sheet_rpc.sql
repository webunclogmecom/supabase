-- 2026-09-07_1710_record_manifest_visit_sheet_rpc.sql
--
-- STEP 4b. The write path for derm.manifest_visit_sheets, which step 4 created with no way in.
-- The DERM Tracker's Broward upload branch calls this once per selected visit, after the existing
-- per-client public.file_manifest loop has created the manifests and linked the visits.
--
-- WHY AN RPC AND NOT A TABLE GRANT. derm.manifest_visit_sheets deliberately grants `authenticated`
-- SELECT only. A table INSERT grant would let any signed-in browser write a compliance document
-- pointer with no validation at all: any manifest id, any visit id, any bucket, any path, with no
-- check that the visit is even on that manifest. Everything this function refuses is something a
-- raw INSERT would have accepted.
--
-- WHAT IT REFUSES, and each of these is a real failure mode rather than a formality:
--   1. A manifest that does not exist or is soft-deleted.
--   2. A visit that is not actually LINKED to that manifest. Without this the app could attach a
--      sheet describing visit A to a manifest documenting visit B, which is precisely the
--      wrong-document-to-the-customer failure this whole table exists to prevent.
--   3. A manifest whose dump is not BROWARD. A per-visit FDEP sheet is meaningless on a Miami-Dade
--      dump, where one sheet covers up to five GDO rows. Fails closed: UNKNOWN and MIXED are
--      refused too, via derm.fn_manifest_dump_bucket, which never returns NULL.
--   4. A blank bucket or path.
--
-- SHEET NUMBERS. Allocated from public.derm_broward_address_seq (the 10000 series) on FIRST write,
-- and never re-allocated on a re-upload: the number is printed on paper the driver already carried,
-- so re-running the upload must not renumber it. That is why the upsert's DO UPDATE deliberately
-- does not touch sheet_no.
--
-- ⚠ IDEMPOTENT BY (manifest_id, visit_id), which is the table's primary key. Re-uploading a photo
-- for the same visit REPLACES the pointer rather than creating a second row. An upsert is not a
-- lock and ON CONFLICT DO UPDATE never raises, so this is a genuine replace, not a guard.
--
-- 🛑 STORES BUCKET AND PATH, NEVER AN ABSOLUTE URL. Same reason as step 4: 2,755 absolute
-- /object/public/ URLs stored elsewhere in this estate are why flipping a bucket to private would
-- break 15 consumers at once, 13 of them silently. A Broward sheet must be movable to a private
-- bucket without rewriting a single stored string.
--
-- RULE 8: no new table, and derm.manifest_visit_sheets already carries audit_manifest_visit_sheets.
-- The audit row records who wrote it, via app_source and jwt_claims->>'email'. Note
-- audit.logs.changed_by is NULL on every row ever written and must not be read.

create or replace function public.record_manifest_visit_sheet(
  p_manifest_id   bigint,
  p_visit_id      bigint,
  p_photo_bucket  text,
  p_photo_path    text
)
returns bigint
language plpgsql
security definer
set search_path = public, derm, pg_temp
as $fn$
declare
  v_client  bigint;
  v_bucket  text;
  v_sheet   bigint;
begin
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
$fn$;

comment on function public.record_manifest_visit_sheet(bigint, bigint, text, text) is
  'Records the uploaded Broward FDEP address sheet for ONE visit. Refuses a visit not linked to the '
  'manifest, and refuses any manifest whose dump is not BROWARD. Idempotent per (manifest, visit); '
  'a re-upload replaces the pointer and NEVER renumbers the sheet.';

revoke all on function public.record_manifest_visit_sheet(bigint, bigint, text, text) from public;
revoke all on function public.record_manifest_visit_sheet(bigint, bigint, text, text) from anon;
grant execute on function public.record_manifest_visit_sheet(bigint, bigint, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- VERIFY. Every refusal is exercised, and there is a positive control that the happy path works,
-- because a function that refuses everything would pass a suite made only of refusals.
-- ---------------------------------------------------------------------------------------------

do $$
declare
  v_bm   bigint; v_bv bigint;
  v_dm   bigint; v_dv bigint;
  v_no   bigint; v_no2 bigint;
  v_c    text;   v_n int;
begin
  if not has_function_privilege('authenticated','public.record_manifest_visit_sheet(bigint,bigint,text,text)','EXECUTE')
    then raise exception 'VERIFY 0 FAILED: authenticated cannot execute the RPC'; end if;
  if has_function_privilege('anon','public.record_manifest_visit_sheet(bigint,bigint,text,text)','EXECUTE')
    then raise exception 'VERIFY 0b FAILED: anon can execute the RPC'; end if;

  -- A real linked BROWARD (manifest, visit), and a real linked DADE one as the negative case.
  select mv.manifest_id, mv.visit_id into v_bm, v_bv
    from public.manifest_visits mv join public.derm_manifests m on m.id = mv.manifest_id
   where m.deleted_at is null and derm.fn_manifest_dump_bucket(m.id) = 'BROWARD'
   order by mv.manifest_id limit 1;
  select mv.manifest_id, mv.visit_id into v_dm, v_dv
    from public.manifest_visits mv join public.derm_manifests m on m.id = mv.manifest_id
   where m.deleted_at is null and derm.fn_manifest_dump_bucket(m.id) = 'DADE'
   order by mv.manifest_id limit 1;
  if v_bm is null or v_dm is null then raise exception 'VERIFY setup FAILED: no probe pair'; end if;

  begin
    -- POSITIVE CONTROL: the happy path writes and returns a 10000-series number.
    v_no := public.record_manifest_visit_sheet(v_bm, v_bv, 'derm-broward-sheets', 'derm/probe/a.jpg');
    if v_no is null or v_no < 10000 then
      raise exception 'VERIFY A FAILED: expected a 10000-series sheet number, got %', coalesce(v_no::text,'NULL');
    end if;

    -- IDEMPOTENCE: a re-upload replaces the pointer and keeps the SAME number.
    v_no2 := public.record_manifest_visit_sheet(v_bm, v_bv, 'derm-broward-sheets', 'derm/probe/b.jpg');
    if v_no2 <> v_no then
      raise exception 'VERIFY B FAILED: a re-upload renumbered the sheet, % then %', v_no, v_no2;
    end if;
    select count(*) into v_n from derm.manifest_visit_sheets
     where manifest_id = v_bm and visit_id = v_bv;
    if v_n <> 1 then raise exception 'VERIFY B2 FAILED: re-upload made % rows', v_n; end if;
    select photo_path into v_c from derm.manifest_visit_sheets
     where manifest_id = v_bm and visit_id = v_bv;
    if v_c <> 'derm/probe/b.jpg' then raise exception 'VERIFY B3 FAILED: pointer not replaced, got %', v_c; end if;

    -- C. A DADE manifest is refused.
    begin
      perform public.record_manifest_visit_sheet(v_dm, v_dv, 'derm-broward-sheets', 'derm/probe/c.jpg');
      raise exception 'ZZ_NOT_RAISED';
    exception when others then
      if sqlerrm = 'ZZ_NOT_RAISED' then raise exception 'VERIFY C FAILED: a DADE manifest was accepted'; end if;
      if position('is the Broward FDEP form only' in sqlerrm) = 0
        then raise exception 'VERIFY C FAILED: wrong guard fired: %', sqlerrm; end if;
    end;

    -- D. A visit not linked to the manifest is refused. Uses the DADE visit against the BROWARD
    --    manifest, so it must trip the LINK guard, not the bucket guard.
    begin
      perform public.record_manifest_visit_sheet(v_bm, v_dv, 'derm-broward-sheets', 'derm/probe/d.jpg');
      raise exception 'ZZ_NOT_RAISED';
    exception when others then
      if sqlerrm = 'ZZ_NOT_RAISED' then raise exception 'VERIFY D FAILED: an unlinked visit was accepted'; end if;
      if position('is not linked to manifest' in sqlerrm) = 0
        then raise exception 'VERIFY D FAILED: wrong guard fired: %', sqlerrm; end if;
    end;

    -- E. A blank path is refused.
    begin
      perform public.record_manifest_visit_sheet(v_bm, v_bv, 'derm-broward-sheets', '   ');
      raise exception 'ZZ_NOT_RAISED';
    exception when others then
      if sqlerrm = 'ZZ_NOT_RAISED' then raise exception 'VERIFY E FAILED: a blank path was accepted'; end if;
      if position('storage bucket and a path' in sqlerrm) = 0
        then raise exception 'VERIFY E FAILED: wrong guard fired: %', sqlerrm; end if;
    end;

    -- F. A missing manifest is refused.
    begin
      perform public.record_manifest_visit_sheet(999999999, v_bv, 'b', 'p');
      raise exception 'ZZ_NOT_RAISED';
    exception when others then
      if sqlerrm = 'ZZ_NOT_RAISED' then raise exception 'VERIFY F FAILED: a missing manifest was accepted'; end if;
      if position('does not exist' in sqlerrm) = 0
        then raise exception 'VERIFY F FAILED: wrong guard fired: %', sqlerrm; end if;
    end;

    raise exception 'ZZ_ROLLBACK';
  exception when others then
    if sqlerrm <> 'ZZ_ROLLBACK' then raise; end if;
  end;

  -- G. Nothing survived, and the sequence is handed back so the first real sheet is 10000.
  select count(*) into v_n from derm.manifest_visit_sheets;
  if v_n <> 0 then raise exception 'VERIFY G FAILED: % probe rows survived', v_n; end if;
  perform setval('public.derm_broward_address_seq', 10000, false);

  raise notice 'VERIFY PASSED: happy path returns a 10000-series number; a re-upload replaces the pointer without renumbering; DADE, unlinked-visit, blank-path and missing-manifest all refused by their own guards; 0 probe rows survived; sequence reset to 10000';
end $$;
