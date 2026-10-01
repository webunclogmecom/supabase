-- ============================================================================
-- 2026-09-30_2027_page_sections_lift_station_water_tank.sql (applied 2026-09-30 20:27 ET, DB clock)
-- 2026-09-30 · A page photo may sit in the new "Lift station" and "Water tank" sections (form v3, B2)
-- ============================================================================
-- Fred, 2026-09-30: "put 2 required photos, one for the Access and one for the Lift Station ... and how that would be
-- for the building phase too", and "two required photos, Capacity and Watertank ... where it clear which one is which".
-- He picked B2: the Page Builder and the Site file get two photo sections, "Lift station" and "Water tank", beside
-- Access photos, Grease trap and Job pictures. A page photo's section is checked here, and ONLY here: submit calls this
-- function, approve copies nothing about sections, fn_driver_page passes each photo's section to the Site file, which
-- shows the sections it knows. ONE line changes: the allowed section list gains 'lift_station' and 'water_tank'.
-- Inert until the Planner publish sends one (no page holds such a photo today; 0 of the page photos measured).
-- 🛑 Once a page holds a lift_station or water_tank photo, never roll the Planner back past the B2 publish: the Site
-- file keeps only photos whose section it knows, so they would vanish from what drivers and clients see, silently.
-- Built by mk_mig_sections.mjs from the LIVE body (md5 2a2d6a4165245db82c9dfb90c9d4d5c6). Rule 8 (audit): no table change. ATOMIC: no COMMIT;
-- the VERIFY's writes (a page version on the test property 1164, its approval, a Site file open) run only inside its
-- sentinel block and are rolled back.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure)) <> '2a2d6a4165245db82c9dfb90c9d4d5c6' then
    raise exception 'PIN: public.fn_page_content_problem changed since this migration was written';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_page_content_problem') <> 1 then
    raise exception 'PIN: public.fn_page_content_problem has more than one overload';
  end if;
end $pin$;

CREATE OR REPLACE FUNCTION public.fn_page_content_problem(p_property_id bigint, p jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_n int;
begin
  if p is null or jsonb_typeof(p) <> 'object'
     or exists (select 1 from jsonb_object_keys(p) k
                 where k not in ('v','facts','hours','notes','contacts','include_map','photos'))
     or coalesce(p ->> 'v', '') <> '1' then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if octet_length(p::text) > 262144 then return 'The page is too large. Remove some photos or notes.'; end if;

  if p ? 'facts' and jsonb_typeof(p -> 'facts') <> 'null' then
    if jsonb_typeof(p -> 'facts') <> 'object' then return 'The page could not be read. Reload the Page Builder and try again.'; end if;
    if (select count(*) from jsonb_object_keys(p -> 'facts')) > 40 then return 'A page holds at most 40 facts.'; end if;
    if exists (select 1 from jsonb_each(p -> 'facts') e(k, val)
                where length(k) > 60
                   or jsonb_typeof(val) not in ('string','number','null')
                   or (jsonb_typeof(val) = 'string' and (length(val #>> '{}') > 500
                        or translate(val #>> '{}', E'\n\t', '') ~ '[[:cntrl:]]'))) then
      return 'Each fact must be a short text (500 characters at most), a number, or empty.';
    end if;
  end if;

  if p ? 'hours' and jsonb_typeof(p -> 'hours') <> 'null' then
    if jsonb_typeof(p -> 'hours') <> 'object'
       or exists (select 1 from jsonb_each(p -> 'hours') e(k, val)
                   where k not in ('mon','tue','wed','thu','fri','sat','sun')
                      or jsonb_typeof(val) <> 'object'
                      or exists (select 1 from jsonb_object_keys(val) kk where kk not in ('open','close'))
                      or coalesce(val ->> 'open', '')  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                      or coalesce(val ->> 'close', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
      return 'Each day we can come needs an opening and a closing time.';
    end if;
  end if;

  if p ? 'notes' and jsonb_typeof(p -> 'notes') not in ('string','null') then return 'The page could not be read. Reload the Page Builder and try again.'; end if;
  if length(coalesce(p ->> 'notes', '')) > 4000 then return 'The notes are too long (4,000 characters at most).'; end if;
  if p ? 'include_map' and jsonb_typeof(p -> 'include_map') <> 'boolean' then return 'The page could not be read. Reload the Page Builder and try again.'; end if;

  if p ? 'contacts' and jsonb_typeof(p -> 'contacts') <> 'null' then
    if jsonb_typeof(p -> 'contacts') <> 'array' or jsonb_array_length(p -> 'contacts') > 10 then
      return 'A page lists at most 10 contacts.';
    end if;
    if exists (select 1 from jsonb_array_elements(p -> 'contacts') c
                where jsonb_typeof(c) <> 'object'
                   or exists (select 1 from jsonb_each(c) e(k, val)
                               where k not in ('name','phone','role')
                                  or jsonb_typeof(val) not in ('string','null')
                                  or length(coalesce(val #>> '{}', '')) > 200)) then
      return 'Each contact has a name, a phone and a role, each 200 characters at most.';
    end if;
  end if;

  -- photos must be a list (the table CHECK requires it; submit strips server-owned keys first).
  if not (p ? 'photos') or jsonb_typeof(p -> 'photos') <> 'array' then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if jsonb_array_length(p -> 'photos') > 80 then return 'A page holds at most 80 photos.'; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where jsonb_typeof(ph) <> 'object'
                 or exists (select 1 from jsonb_object_keys(ph) k where k not in ('photo_id','section','note','marks'))
                 or jsonb_typeof(ph -> 'photo_id') is distinct from 'number'
                 or (ph ->> 'photo_id') !~ '^[1-9][0-9]{0,11}$'
                 or coalesce(ph ->> 'section', '') not in ('access','grease_trap','lift_station','water_tank','job')) then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where (ph ? 'note' and jsonb_typeof(ph -> 'note') not in ('string','null'))
                 or length(coalesce(ph ->> 'note', '')) > 1000) then
    return 'A photo note is too long (1,000 characters at most).';
  end if;
  select count(*) - count(distinct (ph ->> 'photo_id')::bigint) into v_n from jsonb_array_elements(p -> 'photos') ph;
  if v_n > 0 then return 'The same photo is on the page twice.'; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where ph ? 'marks' and jsonb_typeof(ph -> 'marks') <> 'null'
                and (jsonb_typeof(ph -> 'marks') <> 'array' or jsonb_array_length(ph -> 'marks') > 30)) then
    return 'A photo carries at most 30 marks.';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph,
                           jsonb_array_elements(case when jsonb_typeof(ph -> 'marks') = 'array' then ph -> 'marks' else '[]'::jsonb end) m
              where jsonb_typeof(m) <> 'object'
                 or exists (select 1 from jsonb_object_keys(m) k
                             where k not in ('id','kind','x','y','w','h','x1','y1','x2','y2','number','text','color'))
                 or coalesce(m ->> 'kind', '') not in ('circle','ring','rect','arrow','text')
                 or (m ? 'color' and coalesce(m ->> 'color', '') not in ('red','blue','green','yellow','orange','white'))
                 or (m ? 'id' and (jsonb_typeof(m -> 'id') <> 'string' or length(m ->> 'id') > 64))
                 or (m ? 'text' and (jsonb_typeof(m -> 'text') <> 'string' or length(m ->> 'text') > 200))
                 or (m ? 'number' and (jsonb_typeof(m -> 'number') <> 'number' or (m ->> 'number') !~ '^[1-9][0-9]?$'))
                 or exists (select 1 from jsonb_each(m) e(k, val)
                             where k in ('x','y','w','h','x1','y1','x2','y2')
                               and (jsonb_typeof(val) <> 'number' or (val #>> '{}')::numeric not between 0 and 1))) then
    return 'A mark on a photo is not valid (its shape, colour, text or position).';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where not exists (select 1 from public.fn_page_photo_ids(p_property_id) o
                                 where o.photo_id = (ph ->> 'photo_id')::bigint)) then
    return 'A photo on the page no longer belongs to this property (it was removed from its visit or its form). Reload the Page Builder to see it.';
  end if;

  return null;
end $function$;

revoke all on function public.fn_page_content_problem(bigint,jsonb) from public, anon, authenticated;
grant execute on function public.fn_page_content_problem(bigint,jsonb) to service_role;

-- VERIFY (on 112-YA property 1164, the test client: its live version holds 8 photos and it has a Site file link).
do $verify$
declare
  v_fred  uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_def   text := pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure);
  v_live  public.property_pages;
  v_code  text;
  v_c     jsonb;
  v_r     jsonb;
  v_drv   jsonb;
  v_secs  text[];
  mk      jsonb;
  v_newest int;
  v_rev   int;
  v_src   jsonb;
begin
  -- V1: one overload
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_page_content_problem') <> 1 then
    raise exception 'VERIFY 1: public.fn_page_content_problem is not exactly one overload';
  end if;
  select * into v_live from public.property_pages where property_id = 1164 and approved_at is not null order by version desc limit 1;
  select public_id into v_code from public.property_page_links where property_id = 1164;
  if v_live.id is null or v_code is null or jsonb_array_length(v_live.content -> 'photos') < 3 then
    raise exception 'VERIFY 2: fixture: 1164 needs an approved version with 3 photos or more, and a Site file link';
  end if;
  -- the live content as submit hands it over (no site_map, no rot); v_c puts photo 1 in lift_station, photo 2 in water_tank
  mk := (v_live.content - 'site_map') || jsonb_build_object('photos', (
          select jsonb_agg(e.ph - 'rot' order by e.ord) from jsonb_array_elements(v_live.content -> 'photos') with ordinality e(ph, ord)));
  v_c := jsonb_set(jsonb_set(mk, '{photos,0,section}', '"lift_station"'), '{photos,1,section}', '"water_tank"');
  -- V2a/V2b: each new section passes on its own; V2c: an unknown section, or the right word in the wrong case, is refused
  if public.fn_page_content_problem(1164, mk) is not null then
    raise exception 'VERIFY 2: fixture: the live content itself is refused: %', public.fn_page_content_problem(1164, mk);
  end if;
  if public.fn_page_content_problem(1164, jsonb_set(mk, '{photos,0,section}', '"lift_station"')) is not null then
    raise exception 'VERIFY 2a: lift_station is refused';
  end if;
  if public.fn_page_content_problem(1164, jsonb_set(mk, '{photos,0,section}', '"water_tank"')) is not null then
    raise exception 'VERIFY 2b: water_tank is refused';
  end if;
  if public.fn_page_content_problem(1164, jsonb_set(mk, '{photos,0,section}', '"pump_room"')) is distinct from 'The page could not be read. Reload the Page Builder and try again.'
     or public.fn_page_content_problem(1164, jsonb_set(mk, '{photos,0,section}', '"Lift_station"')) is distinct from 'The page could not be read. Reload the Page Builder and try again.' then
    raise exception 'VERIFY 2c: a section that is not one of the five is accepted';
  end if;
  begin
    -- V3: the real path as Fred (the Page Builder's role): submit a version with the two sections, approve it (Fred may
    -- approve his own: developer approval), and the Site file serves both photos with their sections.
    -- the arguments are read first, as postgres (authenticated reads none of these tables)
    v_newest := (select max(version) from public.property_pages where property_id = 1164);
    v_rev := coalesce((select (site_map ->> 'rev')::int from public.properties where id = 1164), 0);
    v_src := public.fn_page_source(1164);
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    set local role authenticated;
    v_r := client.submit_property_page(1164, v_c || jsonb_build_object('site_map', v_live.content -> 'site_map'), v_newest, v_rev, v_src, null);
    if (v_r ->> 'ok') is distinct from 'true' then raise exception 'VERIFY 3a: submit did not take the two sections: %', v_r; end if;
    v_r := client.approve_property_page((v_r ->> 'page_id')::bigint);
    reset role;
    if (v_r ->> 'ok') is distinct from 'true' then raise exception 'VERIFY 3b: approve failed: %', v_r; end if;
    v_drv := public.fn_driver_page(v_code, true, 'migration verify');
    select array_agg(distinct x ->> 'section' order by x ->> 'section') into v_secs from jsonb_array_elements(v_drv -> 'photos') x;
    if not (v_secs @> array['lift_station','water_tank']) or (v_drv ->> 'photos_unavailable')::int <> 0 then
      raise exception 'VERIFY 3c: the Site file does not serve the two sections: % (unavailable %)', v_secs, v_drv ->> 'photos_unavailable';
    end if;
    raise exception 'VERIFY_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_SENTINEL' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  -- V4: exactly the one line changed
  if strpos(v_def, $s$not in ('access','grease_trap','lift_station','water_tank','job')$s$) = 0
     or strpos(v_def, $s$not in ('access','grease_trap','job')$s$) > 0 then
    raise exception 'VERIFY 4: the body is not the old body with the one section line changed';
  end if;
  -- V5: EXECUTE as before: postgres and service_role only
  if has_function_privilege('authenticated', 'public.fn_page_content_problem(bigint,jsonb)', 'execute') or has_function_privilege('anon', 'public.fn_page_content_problem(bigint,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.fn_page_content_problem(bigint,jsonb)', 'execute') then
    raise exception 'VERIFY 5: EXECUTE must stay service_role (and the owner) only';
  end if;
end $verify$;

notify pgrst, 'reload schema';
