-- ============================================================================
-- 2026-09-29_2126_page_photo_collector_comment.sql (applied 2026-09-29 21:26 ET)
-- 2026-09-29 · The Page Builder sees the collector's comment on a form photo
-- ============================================================================
-- Fred, 2026-09-29: "When uploading a photo we need to also have a comment for the photo, this is for the intake form"
-- and, on the Page Builder photo card: "the lock we had there before it's to put the notes from the collector." The
-- collector's comment is photo_links.caption on the form's photo link (intake-submit v21 writes it at submit). The page
-- builder reads its photos through this function, whose INTAKE arm hard-coded null::text for the caption (the
-- 2026-09-25_1330 design: "the collector sends no caption"). ONE line changes: that arm passes
-- nullif(btrim(pl.caption), ''). Everything else stays byte for byte (the visit arm, the filters, the storage check).
-- Who reads it (all six callers checked 2026-09-29): client.get_page_builder puts it in pool[] and referenced[] (staff
-- only; its own body is NOT touched, so the Restore md5 on it holds); get_page_builder_forms, page_builder_list,
-- submit_property_page and fn_page_content_problem never read the caption; fn_driver_page copies only bucket, path and
-- rotation, so the comment NEVER reaches the Site file (the staff note stays the only text drivers and clients read).
-- It is never copied into page content: the builder looks it up live, so a Restore shows today's comment.
-- Built by mk_mig_f.mjs from the LIVE body (md5 a776b3bc150fcfa3e505d63a770ba67b). Rule 8 (audit): no table change. ATOMIC: no COMMIT; the
-- VERIFY's writes (a caption on a live form link of 1164, a Site file open) run only inside its sentinel block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('public.fn_page_photo_ids(bigint)'::regprocedure)) <> 'a776b3bc150fcfa3e505d63a770ba67b' then
    raise exception 'PIN: public.fn_page_photo_ids changed since this migration was written';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_page_photo_ids') <> 1 then
    raise exception 'PIN: public.fn_page_photo_ids has more than one overload';
  end if;
end $pin$;

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

revoke all on function public.fn_page_photo_ids(bigint) from public, anon, authenticated;
grant execute on function public.fn_page_photo_ids(bigint) to service_role;

-- VERIFY (on 112-YA property 1164, the test client: its live version holds form photos). The caption write and the
-- Site file open are inside the sentinel block and rolled back; the builder reads run as Fred with the role the Page
-- Builder uses (authenticated), the rest as postgres.
do $verify$
declare
  v_def   text := pg_get_functiondef('public.fn_page_photo_ids(bigint)'::regprocedure);
  v_link  bigint;
  v_photo bigint;
  v_code  text;
  v_pb    jsonb;
  v_forms jsonb;
  v_drv   jsonb;
  v_c     jsonb;
begin
  -- V1: one overload
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_page_photo_ids') <> 1 then
    raise exception 'VERIFY 1: public.fn_page_photo_ids is not exactly one overload';
  end if;
  -- V2a: fixture, a live form photo of 1164 that is on its live version, with no comment today, and a Site file link
  select l.id, l.photo_id into v_link, v_photo
    from public.photo_links l join public.property_intakes i on i.id = l.entity_id
   where l.entity_type = 'property_intake' and l.deleted_at is null and i.property_id = 1164
     and i.submitted_at is not null and i.cancelled_at is null and l.caption is null
     and exists (select 1 from public.fn_page_photo_ids(1164) o where o.photo_id = l.photo_id)
     and exists (select 1 from public.property_pages pg, jsonb_array_elements(pg.content -> 'photos') ph
                  where pg.property_id = 1164 and pg.approved_at is not null and (ph ->> 'photo_id')::bigint = l.photo_id)
   order by l.id limit 1;
  select public_id into v_code from public.property_page_links where property_id = 1164;
  if v_link is null or v_code is null then
    raise exception 'VERIFY 2a: fixture: 1164 needs a form photo on an approved version with no caption, and a Site file link';
  end if;
  begin
    -- 2b: a comment on that link reaches the builder's pool and referenced
    update public.photo_links set caption = '[TEST] F verify comment' where id = v_link;
    perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    set local role authenticated;
    v_pb := client.get_page_builder(1164);
    v_forms := client.get_page_builder_forms(1164);
    reset role;
    select x into v_c from jsonb_array_elements(v_pb -> 'pool') x where (x ->> 'photo_id')::bigint = v_photo;
    if v_c ->> 'caption' is distinct from '[TEST] F verify comment' then raise exception 'VERIFY 2b: pool caption %', v_c ->> 'caption'; end if;
    select x into v_c from jsonb_array_elements(v_pb -> 'referenced') x where (x ->> 'photo_id')::bigint = v_photo;
    if v_c ->> 'caption' is distinct from '[TEST] F verify comment' then raise exception 'VERIFY 2b: referenced caption %', v_c ->> 'caption'; end if;
    -- 2c: the form reply the builder fills from never carries it
    if v_forms::text like '%F verify comment%' then raise exception 'VERIFY 2c: get_page_builder_forms carries the comment'; end if;
    -- 2d: the Site file never shows it (fn_driver_page, as the driver-page edge function calls it)
    v_drv := public.fn_driver_page(v_code, true, 'migration verify');
    if v_drv is null then raise exception 'VERIFY 2d: fixture: the Site file of 1164 did not open'; end if;
    if v_drv::text like '%F verify comment%' then raise exception 'VERIFY 2d: the Site file carries the comment'; end if;
    -- 2e: a comment of spaces only is no comment
    update public.photo_links set caption = '   ' where id = v_link;
    perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    set local role authenticated;
    v_pb := client.get_page_builder(1164);
    reset role;
    select x into v_c from jsonb_array_elements(v_pb -> 'pool') x where (x ->> 'photo_id')::bigint = v_photo;
    if v_c is null or jsonb_typeof(v_c -> 'caption') is distinct from 'null' then raise exception 'VERIFY 2e: a blank caption reads %', v_c -> 'caption'; end if;
    raise exception 'VERIFY_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_SENTINEL' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  -- V3: exactly the one line changed; the visit arm still passes its caption as before
  if (length(v_def) - length(replace(v_def, 'nullif(btrim(pl.caption), '''')', ''))) / length('nullif(btrim(pl.caption), '''')') <> 1
     or strpos(v_def, 'pl.role, null::text') > 0 or strpos(v_def, 'null::text, pl.caption, p.rotation_deg') = 0 then
    raise exception 'VERIFY 3: the body is not the old body with the one intake caption line changed';
  end if;
  -- V4: EXECUTE as before: postgres and service_role only
  if has_function_privilege('authenticated', 'public.fn_page_photo_ids(bigint)', 'execute') or has_function_privilege('anon', 'public.fn_page_photo_ids(bigint)', 'execute')
     or not has_function_privilege('service_role', 'public.fn_page_photo_ids(bigint)', 'execute') then
    raise exception 'VERIFY 4: EXECUTE must stay service_role (and the owner) only';
  end if;
end $verify$;

notify pgrst, 'reload schema';
