-- ============================================================================
-- 2026-09-29_2133_page_pin_far_warning.sql (applied 2026-09-29 21:34 ET)
-- 2026-09-29 · A pin far from the property is a WARNING in the Page Builder, no longer a refusal here
-- ============================================================================
-- Fred, 2026-09-29, on /property/162: "I see this error "A pin on the site map is more than about 5 km from this
-- property's address..." ... at most it should be a warning that we can continue". His pick: the same sentence under the
-- map and in the Submit confirm row, whose button then reads "Submit anyway" (Picture Planner, same cycle).
-- The refusal lived only here (blocker=pin_far, a 0.05 degree box: 5.0 km east-west, 5.6 km north-south). A raise cannot
-- be a warning: it aborts the insert. So the bound goes; everything else in client.submit_property_page stays exactly as
-- the Restore migration left it (the 6 arguments, not_restorable, version_clash, source_changed, site_map, content, the
-- rounding, the freeze). The page approver still checks every version before drivers see it.
-- Not changed: client.update_property_site_map keeps its own copy of the bound (retired from staff, postgres only).
-- Built by mk_mig.mjs from the LIVE body (md5 a4b02cb9916f9d9ef6fda587203a5614), each edit anchored once; the diff is exactly: v_far and the
-- latitude/longitude read removed, two comment lines rewritten, the 12-line bound removed.
-- Rule 8 (audit): no table change. ATOMIC: no COMMIT; the VERIFY's writes run only inside its sentinel block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure)) <> 'a4b02cb9916f9d9ef6fda587203a5614' then
    raise exception 'PIN: client.submit_property_page changed since this migration was written';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'client' and p.proname = 'submit_property_page') <> 1 then
    raise exception 'PIN: client.submit_property_page has more than one overload';
  end if;
end $pin$;

CREATE OR REPLACE FUNCTION client.submit_property_page(p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb, p_restored_from_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_email   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p       record;
  v_newest  int;
  v_problem text;
  v_block   text;
  v_source  jsonb;
  v_in      jsonb;
  v_content jsonb;
  v_bad     text;
  v_id      bigint;
  v_map     jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.submit_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.submit_property_page';
  end if;
  if p_property_id is null or p_expected_version is null or p_expected_map_rev is null or p_expected_source is null then
    raise exception 'The page could not be sent. Reload the Page Builder and try again.' using errcode = '22023',
      detail = 'blocker=expected_version_required in client.submit_property_page';
  end if;

  -- One submit at a time per property, so the version check below is exact.
  perform pg_advisory_xact_lock(7342, p_property_id::int);

  v_block := public.fn_page_blocker(p_property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.submit_property_page';
  end if;

  -- FOR SHARE: the map check and the frozen map copy come from this one read.
  select p.id, p.site_map into v_p from public.properties p where p.id = p_property_id for share;

  select coalesce(max(version), 0) into v_newest from public.property_pages where property_id = p_property_id;
  if v_newest <> p_expected_version then
    raise exception 'Someone submitted a newer version of this page since you opened it. Reload to see it before you submit.'
      using errcode = '40001', detail = format('blocker=version_clash in client.submit_property_page (you had %s, newest is %s)', p_expected_version, v_newest);
  end if;
  -- A restore (2026-09-29, Fred: "i want like a go back way ... without removing the version 4"): the draft started
  -- from an older version, recorded as restored_from_version. Only a REPLACED version (approved, below the live one):
  -- the live one is already what drivers see, and a waiting or superseded one was never approved. The content
  -- is not compared with it: Fred adjusts the draft before sending, and everything below checks it as usual.
  if p_restored_from_version is not null and not exists (
       select 1 from public.property_pages r
        where r.property_id = p_property_id and r.version = p_restored_from_version and r.approved_at is not null
          and r.version < (select max(l.version) from public.property_pages l
                            where l.property_id = p_property_id and l.approved_at is not null)) then
    raise exception 'Only a version that was live before can be restored. Reload the Page Builder and try again.'
      using errcode = '22023', detail = format('blocker=not_restorable in client.submit_property_page (version %s)', p_restored_from_version);
  end if;
  -- Since 2026-09-27 the site map is part of the DRAFT (Fred: "Make it draft-only"). A builder that sends
  -- content.site_map gets THAT map checked and frozen below, and the property's map is not read, so this
  -- revision check does not apply to it. A builder that does not send the key (the Planner before this
  -- change, which saves the map to the property as it is drawn) still freezes the property's map, guarded
  -- by its revision exactly as before.
  if not (p_content ? 'site_map')
     and (coalesce((v_p.site_map ->> 'rev')::int, 0) <> p_expected_map_rev
          -- The revision alone repeats after a clear (update_property_site_map clears to NULL, rev 0),
          -- so the map is also compared by content, as fn_page_source did before it lost the map.
          or (jsonb_typeof(p_expected_source) = 'object' and p_expected_source ? 'site_map'
              and nullif(p_expected_source -> 'site_map', 'null'::jsonb) is distinct from (v_p.site_map - 'rev'))) then
    raise exception 'The site map changed since you opened this page. Reload to see it before you submit.'
      using errcode = '40001', detail = 'blocker=map_changed in client.submit_property_page';
  end if;
  v_source := public.fn_page_source(p_property_id);
  -- fn_page_source stopped carrying the map on 2026-09-27; a builder from before still sends it in its
  -- baseline, so it is ignored here rather than refused (the older builder's map check is above).
  if v_source is distinct from (case when jsonb_typeof(p_expected_source) = 'object'
                                     then p_expected_source - 'site_map' else p_expected_source end) then
    raise exception 'The property''s details changed since you opened this page (hours, lock box, capacity, counts or notes). Reload to see them before you submit.'
      using errcode = '40001', detail = 'blocker=source_changed in client.submit_property_page';
  end if;

  -- The server owns site_map and each photo's rot: strip them so a stored version can be sent
  -- back as it is (the freeze below adds them again).
  v_in := p_content - 'site_map';
  if jsonb_typeof(v_in -> 'photos') = 'array' then
    v_in := v_in || jsonb_build_object('photos', (
      select coalesce(jsonb_agg(case when jsonb_typeof(ph) = 'object' then ph - 'rot' else ph end order by e.ord), '[]'::jsonb)
        from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)));
  end if;

  -- The draft's map: rounded first (as client.update_property_site_map does), then validated. A pin far from the
  -- property's address is NOT refused (2026-09-29, Fred: "at most it should be a warning that we can continue"):
  -- the Page Builder warns under the map and in its Submit confirm. A draft map is ALWAYS stored as an object
  -- without rev ({} when it has no pin and no arrow): that shape is what tells approve the version's map
  -- came from the draft. An older builder's version holds the property's map (NULL, or an object WITH rev).
  if p_content ? 'site_map' then
    begin
      v_map := public.fn_site_map_round(nullif(p_content -> 'site_map', 'null'::jsonb));
    exception when others then
      v_map := p_content -> 'site_map';   -- a text lat cannot be rounded: let the validator name the problem
    end;
    v_problem := public.fn_site_map_problem(v_map);
    if v_problem is not null then
      raise exception 'The site map could not be sent (%). Reload the Page Builder and try again.', v_problem
        using errcode = '22023', detail = 'blocker=site_map in client.submit_property_page';
    end if;
    v_map := coalesce(v_map, '{}'::jsonb) - 'rev';
    if coalesce(v_map -> 'pins', '{}'::jsonb) = '{}'::jsonb and coalesce(v_map -> 'arrows', '[]'::jsonb) = '[]'::jsonb then
      v_map := '{}'::jsonb;
    end if;
  else
    v_map := v_p.site_map;
  end if;

  v_problem := public.fn_page_content_problem(p_property_id, v_in);
  if v_problem is not null then
    select ph ->> 'photo_id' into v_bad
      from jsonb_array_elements(case when jsonb_typeof(v_in -> 'photos') = 'array' then v_in -> 'photos' else '[]'::jsonb end) ph
     where (ph ->> 'photo_id') ~ '^[1-9][0-9]{0,11}$'
       and not exists (select 1 from public.fn_page_photo_ids(p_property_id) o where o.photo_id = (ph ->> 'photo_id')::bigint)
     limit 1;
    raise exception '%', v_problem using errcode = '22023',
      detail = 'blocker=content in client.submit_property_page' || coalesce(' photo_id=' || v_bad, '');
  end if;

  -- Freeze: the site map (the draft's, or the property's for an older builder), and each photo's
  -- rotation at submit (to remap marks later).
  v_content := v_in
    || jsonb_build_object('site_map', v_map)
    || jsonb_build_object('photos', coalesce((
         select jsonb_agg(ph || jsonb_build_object('rot', ph2.rotation_deg) order by e.ord)
           from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)
           join public.photos ph2 on ph2.id = (ph ->> 'photo_id')::bigint), '[]'::jsonb));

  insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, restored_from_version)
  values (p_property_id, v_newest + 1, v_content, v_source, v_uid, v_email, p_restored_from_version)
  returning id into v_id;

  insert into public.property_page_links (property_id, created_by)
  values (p_property_id, v_uid)
  on conflict (property_id) do nothing;

  return jsonb_build_object('ok', true, 'page_id', v_id, 'version', v_newest + 1);
end $function$;

revoke all on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb, integer) from public, anon, authenticated, service_role;
grant execute on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb, integer) to authenticated;

-- VERIFY (as Fred, a developer approver, on 112-YA property 162: the test client; the three submits run with
-- set local role authenticated, the reads as postgres). Every write is inside the sentinel block and rolled back.
-- The far pins are intake 742's (9.2 km from 162's point): the ones Fred's refusal came from.
do $verify$
declare
  v_def    text := pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure);
  v_p      record;
  v_newest int;
  v_live   int;
  v_c      jsonb;
  v_src    jsonb;
  v_r      jsonb;
  v_d      text;
  v_m      jsonb;
  v_far    jsonb := '{"pins": {"gt": {"lat": 25.807052, "lng": -80.206652}, "truck": {"lat": 25.807056, "lng": -80.206473}}, "arrows": []}';
  v_bad    jsonb := '{"pins": {"gt": {"lat": "x", "lng": -80.2}}, "arrows": []}';
begin
  -- V1: one overload, the Restore signature
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'client' and p.proname = 'submit_property_page') <> 1
     or pg_get_function_identity_arguments('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure)
        <> 'p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb, p_restored_from_version integer' then
    raise exception 'VERIFY 1: client.submit_property_page is not exactly one overload with the Restore signature';
  end if;
  -- V2 (behaviour first, so each broken copy is caught by what it breaks)
  select id, latitude, longitude, site_map into v_p from public.properties where id = 162;
  select coalesce(max(version), 0), max(version) filter (where approved_at is not null) into v_newest, v_live
    from public.property_pages where property_id = 162;
  if v_p.latitude is null or v_live is null
     or not (abs(25.807052 - v_p.latitude) > 0.05 or abs(-80.206652 - v_p.longitude) > 0.05) then
    raise exception 'VERIFY 2a: fixture: 162 needs a lat/lng, a live version, and the far pins outside the old box (else this proves nothing)';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  begin
    select content into v_c from public.property_pages where property_id = 162 and version = v_newest;
    v_src := public.fn_page_source(162);
    -- the three submits run AS authenticated, the role the Page Builder calls with (the house template); the reads stay postgres
    set local role authenticated;
    -- 2b: the Restore rule survived (restoring the Live version is refused)
    begin
      perform client.submit_property_page(162, v_c || jsonb_build_object('site_map', v_far), v_newest, 0, v_src, v_live);
      v_d := 'accepted';
    exception when others then
      get stacked diagnostics v_d = pg_exception_detail;
    end;
    if coalesce(v_d, '') not like 'blocker=not_restorable%' then raise exception 'VERIFY 2b: restoring the Live version gave %', v_d; end if;
    -- 2c: the map validator survived (a text latitude is refused)
    begin
      perform client.submit_property_page(162, v_c || jsonb_build_object('site_map', v_bad), v_newest, 0, v_src, null);
      v_d := 'accepted';
    exception when others then
      get stacked diagnostics v_d = pg_exception_detail;
    end;
    if coalesce(v_d, '') not like 'blocker=site_map%' then raise exception 'VERIFY 2c: a malformed map gave %', v_d; end if;
    -- 2d: the far pins are ACCEPTED and frozen as sent; 2e: submit still writes no property map
    begin
      v_r := client.submit_property_page(162, v_c || jsonb_build_object('site_map', v_far), v_newest, 0, v_src, null);
    exception when others then
      get stacked diagnostics v_d = pg_exception_detail;
      raise exception 'VERIFY 2d: refused (%)', v_d;
    end;
    reset role;
    if (v_r ->> 'ok') is distinct from 'true' or (v_r ->> 'version')::int <> v_newest + 1 then raise exception 'VERIFY 2d: %', v_r; end if;
    select content -> 'site_map' into v_m from public.property_pages where property_id = 162 and version = v_newest + 1;
    if v_m -> 'pins' is distinct from v_far -> 'pins' then raise exception 'VERIFY 2d: stored map %', v_m; end if;
    if (select site_map from public.properties where id = 162) is distinct from v_p.site_map then raise exception 'VERIFY 2e: submit wrote the property map'; end if;
    raise exception 'VERIFY_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_SENTINEL' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  -- V3: the body lost the bound and kept every other refusal
  -- strpos, never LIKE: in a LIKE pattern _ matches any character, so '%pin_far%' matched this body's own comment
  -- "a pin far from" (found by the dry run of 2026-09-29 17:50 ET)
  if strpos(v_def, 'pin_far') > 0 or strpos(v_def, '0.05') > 0 or strpos(v_def, 'v_far') > 0 or strpos(v_def, 'latitude') > 0
     or strpos(v_def, 'fn_site_map_problem(v_map)') = 0 or strpos(v_def, 'blocker=site_map') = 0 or strpos(v_def, 'blocker=not_restorable') = 0
     or strpos(v_def, 'blocker=version_clash') = 0 or strpos(v_def, 'blocker=source_changed') = 0 or strpos(v_def, 'blocker=content') = 0 then
    raise exception 'VERIFY 3: the body is not the Restore body minus the pin bound';
  end if;
  -- V4: EXECUTE for authenticated only
  if not has_function_privilege('authenticated', 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)', 'execute')
     or has_function_privilege('anon', 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)', 'execute') then
    raise exception 'VERIFY 4: EXECUTE must be authenticated only';
  end if;
end $verify$;

notify pgrst, 'reload schema';
