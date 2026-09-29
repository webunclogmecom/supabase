-- ============================================================================
-- 2026-09-29_1411_page_restore.sql (applied 2026-09-29 14:11 ET)
-- 2026-09-29 · Restore an older site file version as a NEW version ("Restored from version N")
-- ============================================================================
-- Fred, 2026-09-29, looking at the Activity modal on 112-YA property 1164 (v4 Live; v3, v2, v1 Replaced):
--   "I love this activity details we have now, and i see we have it by versioning, any way we can go back to a previous
--    version, like we're at version 4, but i liked version 2 or version 3 more, i want like a go back way. Obviously
--    without removing the version 4, it's just like the Live version would be another one instead."
-- His answers:
--   Numbering "Copy as new version": the old version's content becomes a NEW version (v5 "Restored from version 2"),
--     which becomes Live when approved; v4 then shows "Replaced by version 5"; nothing is deleted.
--   Approval "Yes, same approval" as any version (another approver, or Fred's developer approval).
--   Flow "Open as a draft first": Restore loads that version into the Page Builder as the draft, with a line
--     "Restored from version 2"; he can adjust it, then Submit for approval as usual.
--
-- What already works, measured 2026-09-29 11:25 ET by a rolled-back probe as Fred's claims: submit_property_page takes
-- an old version's content UNCHANGED (1164 v1..v4, 162 v1..v2 all accepted; v2..v4 stored byte-equal, map included),
-- with p_expected_version = the NEWEST version (the old number is refused, blocker=version_clash), p_expected_source =
-- TODAY's get_page_builder.property.source (the old row's source is refused, blocker=source_changed), and any non-null
-- p_expected_map_rev (not compared when the content carries site_map). So a restore needs no new write path: the
-- Planner loads the version into its draft and submits it as usual. This migration only RECORDS where the draft came
-- from:
--
-- 1. public.property_pages.restored_from_version int NULL: the version the draft was restored from. A label ("started
--    from version N"), not a copy guarantee: Fred adjusts the draft before sending, so the content is not compared.
--    CHECK (restored_from_version >= 1 and restored_from_version < version) and a FOREIGN KEY (property_id,
--    restored_from_version) -> (property_id, version): it names a real, earlier version of the SAME property, even for a
--    raw write. The append-only trigger compares the whole row (to_jsonb), so the value is frozen at insert like the
--    content; no trigger change is needed (VERIFY S6 proves it). The audit trigger logs it with the row.
-- 2. client.submit_property_page gains p_restored_from_version integer DEFAULT NULL (the signature changes, so DROP and
--    CREATE; grants revoked by name, EXECUTE to authenticated only, as before). The Planner calls it with NAMED
--    arguments and the new one has a default, so today's builder keeps working unchanged (VERIFY S1). A restore is
--    allowed only from a REPLACED version: approved and below the Live one (22023, blocker=not_restorable). Not the
--    Live one (it is already what drivers see), not a Waiting or Superseded one (never
--    approved, never seen by a driver; "Restored from version N" would read as if it had been live). Widening that
--    later is this one predicate; the column's CHECK and FK already allow any earlier version.
--    The check runs after the version clash check, inside the same advisory lock, so a stale screen hears
--    "Someone submitted a newer version" first.
-- 3. client.get_page_versions adds restored_from_version (null when the version was not a restore) and source (the
--    property data the version was made with, the same object get_page_builder already sends for the live and the
--    waiting version). The builder needs the RESTORED version's source as the draft's baseline, or its "Changed in the
--    Client App's property data since ..." notice compares today with today and never shows. On 1164 (2026-09-29)
--    versions 1 to 3 were made before the property data had a lock box code, gallons, sample ports and hours (manholes
--    0, now 1), and the lock box code in versions 1 and 3 differs from today's: restoring either would send that old
--    code with nothing on screen, the stale-draft hole the notice exists to close.
-- 4. client.get_property_activity: the page_submitted sentence of a restore ends with its origin:
--    "Version 5 of the site file submitted for approval by Fred (restored from version 2)" (the tail column, after the
--    name, as intake_accepted already does). The approval sentence is unchanged.
-- 5. client.get_page_builder: 'referenced' lists the photos of EVERY version of the property (was: the live and the
--    waiting version only), each with owned true (bucket, path, rotation) or false. A restored version can hold a photo
--    that is in neither of those nor in the pool (12 newest visits): without this the builder has no path to show it
--    and cannot tell whether it still belongs to the property, so a photo that is gone surfaces only at Submit as
--    blocker=content photo_id=N. Nothing else in its reply changes (VERIFY V2 compares it before and after).
--
-- Not changed, on purpose: approve_property_page (a restore is approved like any version, and its draft-built map is
-- copied to properties.site_map on approval, so the pins go back too: VERIFY S4), the append-only trigger,
-- fn_page_content_problem (a photo removed since the old version still refuses the whole submit: blocker=content
-- photo_id=N; the builder warns and leaves owned=false photos out on the user's choice, below).
--
-- What the Planner does with it (its rules land in Picture Planner CLAUDE.md rule 22 with the build):
-- - Restore loads the version into the browser draft as {base_version: pb.newest_version (the NEWEST number,
--   never the restored one), source: that version's source, content: its content, restored_from_version: N}. A base of N would
--   raise "Version 4 ... is newer than your draft" with "Discard my draft" on the restore itself, and submit would
--   refuse it (blocker=version_clash). restored_from_version is carried through every autosave, "Use the new values" and
--   "Keep my draft", cleared by Discard and by a successful Submit, and sent as p_restored_from_version.
-- - Photos the reply marks owned=false stay in the restored draft behind one sentence ("2 photos from version 2 are no
--   longer on this property. The page cannot be submitted with them.") and a "Leave them out" button; Submit waits.
-- - Submit still sends p_expected_version = newest and p_expected_source = today's property.source (probe above).
--
-- Rule 8 (audit): no new table; the new column rides the existing audit_property_pages trigger. yannick_readonly has no
-- grant on property_pages, so it gets no column (asserted). ATOMIC: no COMMIT; the VERIFY's writes (a restore on 1164,
-- its approval, the refusals, raw-write controls) run only inside its sentinel sub-block, which is rolled back. The
-- before-copy of get_page_builder's reply is a temp table dropped at the end of the VERIFY (and on commit).
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)'::regprocedure)) <> '0882778cae55f275c794251621c16ab3'
     or md5(pg_get_functiondef('client.get_page_versions(bigint)'::regprocedure)) <> 'a1d29dc1ed6d78927143d245070836ba'
     or md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> '676b58d9c7bec63b2c0ee528e3e34236'
     or md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '73acbd96ba7a98e724c830ed15dc3893'
     -- relied on, not copied: approve takes only the newest version and copies a draft map; the trigger freezes the row;
     -- the validator decides which photos a restore may carry.
     or md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> 'cad8783dda41a9c0d60d96dff2be7daf'
     or md5(pg_get_functiondef('public.fn_property_pages_append_only()'::regprocedure)) <> '668fb9e3ef3fa8857d102946251833e7'
     or md5(pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure)) <> '2a2d6a4165245db82c9dfb90c9d4d5c6' then
    raise exception 'PIN: a page function changed since this migration was written';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'client' and p.proname = 'submit_property_page') <> 1
     or exists (select 1 from pg_attribute where attrelid = 'public.property_pages'::regclass and attname = 'restored_from_version') then
    raise exception 'PIN: submit_property_page has another overload, or the column already exists';
  end if;
  -- VERIFY S4 approves a restore as Fred who made it (developer approval).
  if not exists (select 1 from auth.users where id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' and lower(email) = 'fred@ayache.com')
     or not ('5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid = any (public.fn_page_self_approver_ids()))
     or not ('5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid = any (public.fn_page_approver_ids())) then
    raise exception 'PIN: Fred''s login is not a developer approver any more';
  end if;
end $pin$;

-- get_page_builder's reply BEFORE this migration, as Fred's claims, for VERIFY V2 (only 'referenced' may change).
create temp table _restore_pb_before (property_id bigint primary key, pb jsonb not null) on commit drop;
do $before$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  insert into _restore_pb_before select p.id, client.get_page_builder(p.id) from unnest(array[162, 1164]::bigint[]) p(id);
  perform set_config('request.jwt.claims', '', true);
end $before$;

alter table public.property_pages
  add column restored_from_version integer,
  add constraint property_pages_restored_from_check check (restored_from_version >= 1 and restored_from_version < version),
  add constraint property_pages_restored_from_fkey foreign key (property_id, restored_from_version)
    references public.property_pages (property_id, version);

comment on column public.property_pages.restored_from_version is
  'The earlier version of the same property this version''s draft was restored from (Page Builder Restore, 2026-09-29), else NULL. A label, not a copy guarantee: the draft may be adjusted before submit. submit_property_page accepts only a REPLACED version (approved, below the live one). Frozen at insert by the append-only trigger.';

drop function client.submit_property_page(bigint, jsonb, integer, integer, jsonb);

CREATE FUNCTION client.submit_property_page(p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb, p_restored_from_version integer DEFAULT NULL::integer)
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
  v_far     int;
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

  -- FOR SHARE: the map check, the frozen map copy and the pin bound come from this one read.
  select p.id, p.site_map, p.latitude, p.longitude into v_p from public.properties p where p.id = p_property_id for share;

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

  -- The draft's map: rounded first (as client.update_property_site_map does), then validated, then the
  -- same sanity bound against the property's own geocode. A draft map is ALWAYS stored as an object
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
    -- ⚠ Like update_property_site_map, this does NOT catch a pin on the wrong building of the same
    -- client; it catches a grossly wrong pin, the wrong city or a swapped lat/lng.
    if v_map <> '{}'::jsonb and v_p.latitude is not null and v_p.longitude is not null then
      select count(*) into v_far
        from jsonb_each(coalesce(v_map -> 'pins', '{}'::jsonb)) e(k, v)
       where abs((v ->> 'lat')::numeric - v_p.latitude) > 0.05
          or abs((v ->> 'lng')::numeric - v_p.longitude) > 0.05;
      if v_far > 0 then
        raise exception 'A pin on the site map is more than about 5 km from this property''s address. Check the map is on the right property.'
          using errcode = '22023', detail = 'blocker=pin_far in client.submit_property_page';
      end if;
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
end $function$
;

revoke all on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb, integer) from public, anon, authenticated, service_role;
grant execute on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb, integer) to authenticated;

CREATE OR REPLACE FUNCTION client.get_page_versions(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_versions';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_versions';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_versions';
  end if;

  -- ponytail: every version's whole content in one reply (about 2 KB each today); page it if a property ever keeps hundreds.
  return coalesce((
    with v as (
      select pg.*,
             max(pg.version) over () as newest,
             max(pg.version) filter (where pg.approved_at is not null) over () as live_version
        from public.property_pages pg
       where pg.property_id = p_property_id)
    select jsonb_agg(jsonb_build_object(
             'page_id', v.id, 'version', v.version, 'status', s.status, 'content', v.content,
             'submitted_at', v.submitted_at, 'submitted_by_name', public.fn_page_staff_name(v.submitted_by_email),
             'approved_at', v.approved_at, 'approved_by_name', public.fn_page_staff_name(v.approved_by_email),
             'self_approved', coalesce(v.approved_by = v.submitted_by, false),
             'replaced_by_version', r.version, 'replaced_at', r.at,
             'restored_from_version', v.restored_from_version, 'source', v.source)
           order by v.version desc)
      from v
      cross join lateral (select case
               when v.approved_at is not null and v.version = v.live_version then 'live'
               when v.approved_at is not null then 'replaced'
               when v.version = v.newest then 'waiting'
               else 'superseded' end as status) s
      -- replaced: the next APPROVED version and when it was approved; superseded: the next version and when it was submitted
      left join lateral (
        select n.version, case when v.approved_at is not null then n.approved_at else n.submitted_at end as at
          from public.property_pages n
         where s.status in ('replaced', 'superseded')
           and n.property_id = v.property_id and n.version > v.version
           and (v.approved_at is null or n.approved_at is not null)
         order by n.version
         limit 1) r on true), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION client.get_property_activity(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_property_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_property_activity';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_property_activity';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', ev.at, 'kind', ev.kind, 'who', ev.who, 'intake_id', ev.intake_id, 'version', ev.version,
             'text', ev.what || coalesce(' by ' || ev.who, '')
                     -- a developer approval of one's own version says so (2026-09-27)
                     || case when ev.kind = 'page_approved' and exists (
                               select 1 from public.property_pages x
                                where x.property_id = p_property_id and x.version = ev.version
                                  and x.approved_by = x.submitted_by)
                             then ', who also made it (developer approval)' else '' end
                     -- what an accept changed comes after the name (2026-09-28)
                     || coalesce(ev.tail, ''))
           order by ev.at desc, ev.ord desc, ev.sub)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who,
               null::text as tail, null::bigint as sub
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email), null, null
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), ''), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.submitted_at is not null
        union all
        select i.cancelled_at, 4, 'form_cancelled', i.id, null,
               'Site survey form #' || i.id || ' cancelled',
               public.fn_page_staff_name((
                 select l.jwt_claims ->> 'email' from audit.logs l
                  where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                    and l.table_schema = 'public' and l.operation = 'UPDATE'
                    and l.old_row ->> 'cancelled_at' is null and l.new_row ->> 'cancelled_at' is not null
                  order by l.changed_at desc limit 1)), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the site file submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email),
               -- a restore names its origin after the name (2026-09-29); null otherwise
               ' (restored from version ' || pg.restored_from_version || ')', null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the site file approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Site file link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by)), null, null
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Site file link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email'), null, null
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
        union all
        -- An approver saved a form answer to the property record (Picture Planner, 2026-09-28). One row per field;
        -- the rows of one save share accepted_at, so the ledger id keeps them in the order they were saved.
        -- The lock box code is shown: staff already see it on the property card.
        select a.accepted_at, 9, 'intake_accepted', a.intake_id, null,
               'Accepted from Site survey form #' || a.intake_id,
               public.fn_page_staff_name(a.actor),
               ': ' || case a.question_key
                         when 'access_entry.lock_box_code'   then 'Lock box code'
                         when 'access_hours.schedule'        then 'When we can come'
                         when 'grease_trap.capacity_gallons' then 'Grease trap gallons'
                         when 'grease_trap.manhole_count'    then 'Manholes'
                         when 'grease_trap.sample_ports'     then 'Sample ports'
                         else a.question_key end
                    || case when a.question_key = 'access_hours.schedule' then ' replaced'
                            else ' ' || coalesce(a.old_value #>> '{}', 'Not on file') || ' → '
                                     || coalesce(a.new_value #>> '{}', 'Not on file') end,
               a.id
          from public.property_intake_accepts a
         where a.property_id = p_property_id
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$
;

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
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_builder';
  end if;
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
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and version > coalesce(v_live.version, 0)
   order by version desc limit 1;

  v_block := case
    when v_pend.id is null then 'There is nothing waiting for approval.'
    when not (v_uid = any (public.fn_page_approver_ids())) then
      'Only ' || public.fn_page_approver_names() || ' can approve a page.'
    when v_pend.submitted_by = v_uid and not (v_uid = any (public.fn_page_self_approver_ids()))
      then 'You submitted this version, so another person has to approve it.'
    else public.fn_page_blocker(p_property_id) end;

  with owned as (
    select o.*, q.label from public.fn_page_photo_ids(p_property_id) o
      left join client.v_intake_questions q on q.question_key = o.question_key),
  item as (
    select o.photo_id, jsonb_build_object(
             'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
             'visit_id', case when o.kind = 'visit' then o.entity_id end,
             'intake_id', case when o.kind = 'intake' then o.entity_id end,
             'visit_date', o.visit_date, 'question_key', o.question_key,
             'label', coalesce(o.label, o.question_key), 'caption', o.caption,
             'rotation_deg', o.rotation_deg, 'content_type', o.content_type) as j,
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
                       where it.kind = 'intake' or it.entity_id in (select entity_id from recent_visits)), '[]'::jsonb),
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
end $function$
;

-- CREATE OR REPLACE keeps the grants of the three readers; asserted in V1.

-- VERIFY. Fred's own case on 1164 (restore a replaced version, approve it, the pins go back), the refusals on 162, and
-- raw writes against the constraints and the trigger, all inside the sentinel block, which is rolled back.
do $verify$
declare
  v_fred     uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_claims   text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  v_pb       jsonb;
  v_r        jsonb;
  v_v        jsonb;
  v_a        jsonb;
  v_row      public.property_pages;
  v_src      public.property_pages;
  v_state    text; v_detail text; v_msg text;
  v_try      int;
  v_new      int;
  v_pages0   bigint := (select count(*) from public.property_pages);
  v_aud0     bigint := (select count(*) from audit.logs where table_name = 'property_pages');
  v_map0     jsonb  := (select site_map from public.properties where id = 1164);
  v_n1164    int    := (select max(version) from public.property_pages where property_id = 1164);
  v_n162     int    := (select max(version) from public.property_pages where property_id = 162);
  v_live1164 int    := (select max(version) from public.property_pages where property_id = 1164 and approved_at is not null);
  v_live162  int    := (select max(version) from public.property_pages where property_id = 162 and approved_at is not null);
  -- Fred's case: the oldest REPLACED version of 1164 whose draft-built map differs from the property's map today (v2 on
  -- 2026-09-29), so approving the restore MUST move the map: a check that can fail.
  v_from     int    := (select min(pg.version) from public.property_pages pg
                         where pg.property_id = 1164 and pg.approved_at is not null
                           and pg.version < (select max(x.version) from public.property_pages x where x.property_id = 1164 and x.approved_at is not null)
                           and jsonb_typeof(pg.content -> 'site_map') = 'object' and not (pg.content -> 'site_map' ? 'rev')
                           and pg.content -> 'site_map' is distinct from (coalesce((select site_map from public.properties where id = 1164), '{}'::jsonb) - 'rev'));
  -- the photos of 1164's live version that the restored one does not carry (27546 and 27610 on 2026-09-29): once the
  -- restore is live they are in no live or waiting version, so only the every-version 'referenced' can list them
  v_gone     bigint[] := array(select (ph ->> 'photo_id')::bigint from public.property_pages pg, jsonb_array_elements(pg.content -> 'photos') ph
                                where pg.property_id = 1164 and pg.version = v_live1164
                               except
                               select (ph ->> 'photo_id')::bigint from public.property_pages pg, jsonb_array_elements(pg.content -> 'photos') ph
                                where pg.property_id = 1164 and pg.version = v_from);
  -- a Replaced version of 1164 with no pin and no arrow (v1 on 2026-09-29, its map stored as null), sent with its
  -- site_map key as the builder always sends it: VERIFY S5c
  v_nomap    int    := (select min(pg.version) from public.property_pages pg
                         where pg.property_id = 1164 and pg.approved_at is not null and pg.version < v_live1164
                           and pg.content ? 'site_map'
                           and coalesce(pg.content -> 'site_map' -> 'pins', '{}'::jsonb) = '{}'::jsonb
                           and coalesce(pg.content -> 'site_map' -> 'arrows', '[]'::jsonb) = '[]'::jsonb);
begin
  -- V1. Shape and grants.
  if (select format_type(atttypid, atttypmod) || '/' || attnotnull from pg_attribute
       where attrelid = 'public.property_pages'::regclass and attname = 'restored_from_version') is distinct from 'integer/false'
     or (select pg_get_constraintdef(oid) from pg_constraint where conname = 'property_pages_restored_from_check' and conrelid = 'public.property_pages'::regclass)
          is distinct from 'CHECK (((restored_from_version >= 1) AND (restored_from_version < version)))'
     or (select pg_get_constraintdef(oid) from pg_constraint where conname = 'property_pages_restored_from_fkey' and conrelid = 'public.property_pages'::regclass)
          is distinct from 'FOREIGN KEY (property_id, restored_from_version) REFERENCES property_pages(property_id, version)'
     or to_regprocedure('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)') is not null
     or (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'client' and p.proname = 'submit_property_page') <> 1
     or (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure)
          <> '{postgres=X/postgres,authenticated=X/postgres}'
     or (select not prosecdef or proconfig is distinct from array['search_path=""'] or pronargdefaults <> 1
           from pg_proc where oid = 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure)
     or has_function_privilege('anon', 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)', 'EXECUTE')
     or (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.get_page_versions(bigint)'::regprocedure)
          <> '{postgres=X/postgres,authenticated=X/postgres}'
     or (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.get_property_activity(bigint)'::regprocedure)
          <> '{postgres=X/postgres,authenticated=X/postgres}'
     or (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.get_page_builder(bigint)'::regprocedure)
          <> '{postgres=X/postgres,authenticated=X/postgres}'
     or (exists (select 1 from pg_roles where rolname = 'yannick_readonly')
         and has_column_privilege('yannick_readonly', 'public.property_pages', 'restored_from_version', 'SELECT')) then
    raise exception 'VERIFY 1: the column, its constraints, the function signature or a grant is wrong';
  end if;
  if v_from is null or v_live1164 is null or v_live162 is null or cardinality(v_gone) = 0 or v_nomap is null then
    raise exception 'VERIFY 1b: no replaced version on 1164 with a map that differs from today''s and fewer photos than the live one, no replaced version on 1164 without a map, or no live version on 162; the checks would prove nothing';
  end if;

  begin
    -- The RPCs run as authenticated with Fred's claims; every direct table read runs as postgres (authenticated has no
    -- grant on property_pages), so the role is switched around each call.
    perform set_config('request.jwt.claims', v_claims, true);

    -- V2. get_page_builder answers exactly as before this migration except 'referenced', which is now every version's
    -- photos (a superset of before), each owned exactly when the property still has it.
    for v_try in select property_id from _restore_pb_before order by property_id loop
      set local role authenticated;
      v_pb := client.get_page_builder(v_try);
      reset role;
      if (v_pb - 'referenced') is distinct from ((select pb from _restore_pb_before where property_id = v_try) - 'referenced')
         or exists (select 1 from jsonb_array_elements((select pb from _restore_pb_before where property_id = v_try) -> 'referenced') o
                     where not (v_pb -> 'referenced') @> jsonb_build_array(o))
         or (select coalesce(array_agg((e ->> 'photo_id')::bigint order by (e ->> 'photo_id')::bigint), '{}') from jsonb_array_elements(v_pb -> 'referenced') e)
            is distinct from (select coalesce(array_agg(distinct (ph ->> 'photo_id')::bigint order by (ph ->> 'photo_id')::bigint), '{}')
                                from public.property_pages pg, jsonb_array_elements(pg.content -> 'photos') ph where pg.property_id = v_try)
         or exists (select 1 from jsonb_array_elements(v_pb -> 'referenced') e
                     where (e ->> 'owned')::boolean is distinct from
                           exists (select 1 from public.fn_page_photo_ids(v_try) o where o.photo_id = (e ->> 'photo_id')::bigint)) then
        raise exception 'VERIFY 2: get_page_builder(%) changed beyond referenced, or referenced is not every version''s photos', v_try;
      end if;
    end loop;

    -- S1. Today's builder: the five NAMED arguments, no restore. On 162 (its live version's content, unchanged).
    select * into v_src from public.property_pages where property_id = 162 and version = v_live162;
    set local role authenticated;
    v_pb := client.get_page_builder(162);
    v_r := client.submit_property_page(p_property_id => 162, p_content => v_src.content,
             p_expected_version => (v_pb ->> 'newest_version')::int, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
             p_expected_source => v_pb -> 'property' -> 'source');
    v_a := client.get_property_activity(162);
    reset role;
    select * into v_row from public.property_pages where id = (v_r ->> 'page_id')::bigint;
    if v_row.version <> v_n162 + 1 or v_row.restored_from_version is not null then
      raise exception 'VERIFY S1: a plain submit stored version % restored from %', v_row.version, v_row.restored_from_version;
    end if;
    if (select count(*) from jsonb_array_elements(v_a) e
         where e ->> 'kind' = 'page_submitted' and (e ->> 'version')::int = v_n162 + 1
           and e ->> 'text' = 'Version ' || (v_n162 + 1) || ' of the site file submitted for approval by ' || public.fn_page_staff_name('fred@ayache.com')) <> 1 then
      raise exception 'VERIFY S1b: a plain submit''s activity sentence changed';
    end if;

    -- S2. Refusals on 162, each with the newest number so only the restore rule can refuse: the Live version, the one
    -- that was waiting before S1 (superseded now; the Live one again when nothing was waiting), S1's own waiting version,
    -- and a version that does not exist.
    set local role authenticated;
    foreach v_try in array array[v_live162, v_n162, v_n162 + 1, 999] loop
      begin
        perform client.submit_property_page(p_property_id => 162, p_content => v_src.content,
                  p_expected_version => v_n162 + 1, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
                  p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_try);
        raise exception 'VERIFY S2: a restore from version % of 162 was accepted', v_try using errcode = 'P0003';
      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
        if v_state <> '22023' or v_detail is distinct from format('blocker=not_restorable in client.submit_property_page (version %s)', v_try)
           or v_msg is distinct from 'Only a version that was live before can be restored. Reload the Page Builder and try again.' then
          raise exception 'VERIFY S2 (version %): gave % / % / %', v_try, v_state, v_detail, v_msg;
        end if;
      end;
    end loop;
    reset role;

    -- S2b. A SUPERSEDED version (never approved, below the Live one) is refused too. 162 has none of its own, so one is
    -- made: a newer version is submitted over S1's and approved (raw, as S6d does), which leaves S1's superseded.
    set local role authenticated;
    v_r := client.submit_property_page(p_property_id => 162, p_content => v_src.content,
             p_expected_version => v_n162 + 1, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
             p_expected_source => v_pb -> 'property' -> 'source');
    reset role;
    update public.property_pages
       set approved_at = now(), approved_by = gen_random_uuid(), approved_by_email = 'verify.restore@ayache.com'
     where id = (v_r ->> 'page_id')::bigint and version = v_n162 + 2;
    if not found then
      raise exception 'VERIFY S2b: the approval over S1''s version matched no row';
    end if;
    set local role authenticated;
    v_v := client.get_page_versions(162);
    begin
      perform client.submit_property_page(p_property_id => 162, p_content => v_src.content,
                p_expected_version => v_n162 + 2, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
                p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_n162 + 1);
      raise exception 'VERIFY S2b: a restore from the superseded version % of 162 was accepted', v_n162 + 1 using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from format('blocker=not_restorable in client.submit_property_page (version %s)', v_n162 + 1) then
        raise exception 'VERIFY S2b: gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    if (select e ->> 'status' from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_n162 + 1) is distinct from 'superseded' then
      raise exception 'VERIFY S2b: version % of 162 is not superseded, so the refusal proved nothing', v_n162 + 1;
    end if;

    -- S3. Fred's case on 1164: the replaced version's content, unchanged, restored as the next version.
    select * into v_src from public.property_pages where property_id = 1164 and version = v_from;
    set local role authenticated;
    v_pb := client.get_page_builder(1164);
    v_r := client.submit_property_page(p_property_id => 1164, p_content => v_src.content,
             p_expected_version => (v_pb ->> 'newest_version')::int, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
             p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_from);
    v_v := client.get_page_versions(1164);
    v_a := client.get_property_activity(1164);
    reset role;
    v_new := (v_r ->> 'version')::int;
    select * into v_row from public.property_pages where id = (v_r ->> 'page_id')::bigint;
    if v_new <> v_n1164 + 1 or v_row.version <> v_new or v_row.restored_from_version is distinct from v_from
       or v_row.content <> v_src.content or v_row.submitted_by <> v_fred or v_row.approved_at is not null then
      raise exception 'VERIFY S3a: the restore stored version % from % (content equal: %)', v_row.version, v_row.restored_from_version, v_row.content = v_src.content;
    end if;
    if (select count(*) from jsonb_array_elements(v_v) e where e -> 'restored_from_version' <> 'null'::jsonb) <> 1
       or (select (e ->> 'restored_from_version')::int from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_new) is distinct from v_from
       or (select e ->> 'status' from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_new) is distinct from 'waiting'
       or exists (select 1 from jsonb_array_elements(v_v) e where not (e ? 'restored_from_version') or not (e ? 'source'))
       or v_src.source is null
       or (select e -> 'source' from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_from) is distinct from v_src.source then
      raise exception 'VERIFY S3b: get_page_versions reads %', (select jsonb_agg(e - 'content' - 'source') from jsonb_array_elements(v_v) e);
    end if;
    if (select count(*) from jsonb_array_elements(v_a) e
         where e ->> 'kind' = 'page_submitted' and (e ->> 'version')::int = v_new
           and e ->> 'text' = 'Version ' || v_new || ' of the site file submitted for approval by '
                              || public.fn_page_staff_name('fred@ayache.com') || ' (restored from version ' || v_from || ')') <> 1
       or (select count(*) from jsonb_array_elements(v_a) e where e ->> 'text' like '%(restored from version%') <> 1 then
      raise exception 'VERIFY S3c: the activity reads %', (select jsonb_agg(e ->> 'text') from jsonb_array_elements(v_a) e where e ->> 'kind' like 'page%');
    end if;

    -- S4. Approved like any version (Fred's developer approval): it goes Live, the old Live is replaced BY it, and its
    -- draft-built map reaches the property with the revision + 1.
    set local role authenticated;
    v_r := client.approve_property_page(v_row.id);
    v_v := client.get_page_versions(1164);
    v_pb := client.get_page_builder(1164);
    reset role;
    if (select e ->> 'status' from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_new) is distinct from 'live'
       or (select (e ->> 'restored_from_version')::int from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_new) is distinct from v_from
       or (select e ->> 'status' from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_live1164) is distinct from 'replaced'
       or (select (e ->> 'replaced_by_version')::int from jsonb_array_elements(v_v) e where (e ->> 'version')::int = v_live1164) is distinct from v_new
       or (v_pb -> 'live' ->> 'version')::int is distinct from v_new
       or v_pb -> 'live' -> 'content' <> v_src.content
       or (select site_map - 'rev' from public.properties where id = 1164) is distinct from v_src.content -> 'site_map'
       or (select (site_map ->> 'rev')::int from public.properties where id = 1164) is distinct from coalesce((v_map0 ->> 'rev')::int, 0) + 1 then
      raise exception 'VERIFY S4: after approval the versions read %', (select jsonb_agg(e - 'content' - 'source') from jsonb_array_elements(v_v) e);
    end if;
    -- S4b. The old live version's photos that the restore dropped are still listed, with their path, for a later restore.
    if exists (select 1 from unnest(v_gone) g(id)
                where not exists (select 1 from jsonb_array_elements(v_pb -> 'referenced') e
                                   where (e ->> 'photo_id')::bigint = g.id and (e ->> 'owned')::boolean and e ? 'path')) then
      raise exception 'VERIFY S4b: once the restore is live, version %''s photos % are missing from get_page_builder.referenced', v_live1164, v_gone;
    end if;

    -- S5. The restore is now Live: restoring IT is refused; the version it replaced (the old Live) is restorable.
    select * into v_row from public.property_pages where property_id = 1164 and version = v_live1164;
    set local role authenticated;
    begin
      perform client.submit_property_page(p_property_id => 1164, p_content => v_src.content,
                p_expected_version => v_new, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
                p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_new);
      raise exception 'VERIFY S5a: the live version was restored' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from format('blocker=not_restorable in client.submit_property_page (version %s)', v_new) then
        raise exception 'VERIFY S5a: gave % / %', v_state, v_detail;
      end if;
    end;
    v_r := client.submit_property_page(p_property_id => 1164, p_content => v_row.content,
             p_expected_version => v_new, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
             p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_live1164);
    reset role;
    if (select restored_from_version from public.property_pages where id = (v_r ->> 'page_id')::bigint) is distinct from v_live1164
       or (v_r ->> 'version')::int <> v_new + 1 then
      raise exception 'VERIFY S5b: going forward again to version % did not record it', v_live1164;
    end if;

    -- S5c. A Replaced version with no site map (its key holds null): submit stores {} and the approval clears the
    -- property's pins and arrows. That is what the builder warns about before such a restore.
    select * into v_row from public.property_pages where property_id = 1164 and version = v_nomap;
    set local role authenticated;
    v_r := client.submit_property_page(p_property_id => 1164, p_content => v_row.content,
             p_expected_version => v_new + 1, p_expected_map_rev => (v_pb -> 'property' ->> 'site_map_rev')::int,
             p_expected_source => v_pb -> 'property' -> 'source', p_restored_from_version => v_nomap);
    perform client.approve_property_page((v_r ->> 'page_id')::bigint);
    reset role;
    if (select content -> 'site_map' from public.property_pages where id = (v_r ->> 'page_id')::bigint) is distinct from '{}'::jsonb
       or (select site_map - 'rev' from public.properties where id = 1164) is distinct from '{}'::jsonb
       or (select (site_map ->> 'rev')::int from public.properties where id = 1164) is distinct from coalesce((v_map0 ->> 'rev')::int, 0) + 2 then
      raise exception 'VERIFY S5c: restoring version % (no site map) and approving it left the map %', v_nomap, (select site_map from public.properties where id = 1164);
    end if;

    -- S6. Raw writes (as postgres): the CHECK, the FOREIGN KEY, and the append-only trigger freezing the column.
    begin
      insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, restored_from_version)
      values (162, 900, '{"v": 1, "photos": []}', '{}', gen_random_uuid(), 'verify.restore@ayache.com', 900);
      raise exception 'VERIFY S6a: a version restored from itself was stored' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = constraint_name;
      if v_state <> '23514' or v_msg is distinct from 'property_pages_restored_from_check' then raise exception 'VERIFY S6a: gave % / %', v_state, v_msg; end if;
    end;
    begin
      insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, restored_from_version)
      values (162, 900, '{"v": 1, "photos": []}', '{}', gen_random_uuid(), 'verify.restore@ayache.com', 899);
      raise exception 'VERIFY S6b: a version restored from a missing version was stored' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = constraint_name;
      if v_state <> '23503' or v_msg is distinct from 'property_pages_restored_from_fkey' then raise exception 'VERIFY S6b: gave % / %', v_state, v_msg; end if;
    end;
    -- S1's version on 162 is still unapproved: recording its approval AND a label is refused ...
    begin
      update public.property_pages
         set approved_at = now(), approved_by = gen_random_uuid(), approved_by_email = 'verify.restore@ayache.com',
             restored_from_version = v_live162
       where property_id = 162 and version = v_n162 + 1;
      raise exception 'VERIFY S6c: the restore label of a stored version was changed' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '55000' or v_detail is distinct from 'blocker=append_only in public.property_pages' then
        raise exception 'VERIFY S6c: gave % / %', v_state, v_detail;
      end if;
    end;
    -- ... while the same approval without the label is accepted, so S6c was refused for the label.
    update public.property_pages
       set approved_at = now(), approved_by = gen_random_uuid(), approved_by_email = 'verify.restore@ayache.com'
     where property_id = 162 and version = v_n162 + 1;
    if not found then
      raise exception 'VERIFY S6d: the control approval matched no row';
    end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  reset role;

  -- V7. Nothing from the test survived.
  if (select count(*) from public.property_pages) <> v_pages0
     or (select max(version) from public.property_pages where property_id = 1164) <> v_n1164
     or (select max(version) from public.property_pages where property_id = 162) <> v_n162
     or exists (select 1 from public.property_pages where restored_from_version is not null)
     or (select site_map from public.properties where id = 1164) is distinct from v_map0
     or (select count(*) from audit.logs where table_name = 'property_pages') <> v_aud0 then
    raise exception 'VERIFY 7: test rows survived the rollback';
  end if;
  raise notice 'VERIFY: a replaced version restores as the next version, labelled in versions and activity with its source, approves Live with its map (one with no map clears the pins), and every version''s photos stay listed; Live, waiting, superseded and missing versions refused; the label is frozen; get_page_builder otherwise unchanged';
end $verify$;

drop table _restore_pb_before;

notify pgrst, 'reload schema';
