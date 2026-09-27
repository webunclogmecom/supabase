-- ============================================================================
-- 2026-09-27_0652_page_map_in_draft_and_activity.sql (applied 2026-09-27_0652 ET)
-- 2026-09-27 · Driver page: the site map lives in the DRAFT until approved; Activity History; staff names
-- ============================================================================
-- Fred, 2026-09-27, asking for the audit this follows:
--   "make sure all is logic is correct ... from the Clients App up to the Picture Planner, that is also saved
--    in the DB, and we have Activity History too. Also at the picture Planner when doing the Draft, it shows
--    who did it also when approved it shows who also approved it, that's also part of the Activity History.
--    Also we need to make sure the lines, and icons a person adds at the Intake Building Phase at the picture
--    planner, they get saved correctly where they placed it, and it's shown at the Approved view."
-- and his answer when asked whether the pins and lines should keep saving to the property at once:
--   "Make it draft-only" (pins and lines stay in the draft until a second person approves it).
--
-- 1. THE MAP IS PART OF THE DRAFT.
--    - client.submit_property_page: when the builder sends content.site_map, THAT map is rounded
--      (public.fn_site_map_round), validated (public.fn_site_map_problem), bounded against the property's
--      geocode (the same 0.05 degree check client.update_property_site_map applies, pins only) and frozen
--      into the version as an object WITHOUT rev ({} when it has no pin and no arrow). That shape is the
--      marker approve reads: a draft map is never NULL and never carries rev. The property's map is NOT
--      read and p_expected_map_rev is ignored on that path; concurrency is the existing p_expected_version
--      check. New refusals, both 22023: blocker=site_map (a malformed map, which the builder never builds;
--      a text lat is caught too) and blocker=pin_far (plain sentence).
--      A builder that does NOT send the key (the Planner before its matching change) keeps the old
--      server behaviour: the property's map is frozen (NULL or an object WITH rev), guarded by
--      p_expected_map_rev AND, because the revision repeats after a clear, by comparing the map in its
--      baseline by content (what fn_page_source used to do). So this ships first and the Planner second.
--    - client.approve_property_page: after recording the approval, a version whose map came from the draft
--      (an object without rev) is copied to properties.site_map with the revision + 1, only when it
--      differs, and never as NULL ({} + rev when the version has no pin and no arrow; a NULL would restart
--      the revision at 0). A version from an older builder is NOT copied: that builder saves to the
--      property as it draws, so copying would undo drawing done after its submit. The row is locked only
--      when there is something to write. Once the Planner's draft build is live and update_property_site_map
--      is revoked (follow-up), properties.site_map equals the map of the newest approved draft-built version.
--    - public.fn_page_source no longer carries `site_map`: the map is authored in the page, not taken from
--      the property. get_page_builder still returns the source WITH the map (fn_page_source || site_map),
--      because the builder from before this change uses it in its "Nothing changed" check and sends it
--      back as its baseline; submit strips it before comparing (a non-object baseline is compared as it is,
--      so it gets the plain source_changed sentence). page_builder_list compares (live.source - 'site_map')
--      so the versions stored before today do not all read "changed since live". Stored versions keep
--      their `source` untouched (append-only).
--    - client.update_property_site_map: its read now takes the row lock (FOR UPDATE), so an approval that
--      commits between its read and its write cannot be overwritten by a stale save. Nothing else in it
--      changes. A follow-up migration revokes it once the Planner stops calling it.
--    - Nothing else reads properties.site_map (swept 2026-09-27: every function whose body names site_map;
--      0 views). No property holds a map today (0 rows), and both stored versions with a map key hold null.
--
-- 2. STAFF NAMES. public.fn_page_staff_name(email): the employee's full name, else the login email itself,
--    else null. Staff screens use it (client.get_page_builder, client.page_builder_list and the activity
--    below), so a person with no employee row (Jonathan's jon.v@ayache.com, the shared
--    unclogme@unclogme.com, a test login) is named by email instead of "the office". The PUBLIC driver
--    page keeps public.fn_page_person_name (first name, else "the office"): it must not show a login email
--    to anyone holding the link.
--
-- 3. ACTIVITY HISTORY. client.get_property_activity(p_property_id) -> jsonb array, newest first:
--      {at, kind, text, who, intake_id, version}
--    kinds (every one from data that already exists; nothing new is recorded):
--      form_requested       property_intakes.requested_at / requested_by (Client App, Schedule intake)
--      form_link_shown      property_intake_link_reveals (Planner /forms, Share form: every reveal is logged)
--      form_filled          property_intakes.submitted_at / collector (the name the collector typed)
--      form_cancelled       property_intakes.cancelled_at; the person from audit.logs when there is one
--      page_submitted       property_pages.submitted_at / submitted_by_email   ("who made the draft")
--      page_approved        property_pages.approved_at / approved_by_email     ("who approved it")
--      driver_link_created  property_page_links.created_at / created_by
--      driver_link_replaced audit.logs UPDATEs of property_page_links where rotated_at moved (the table keeps
--                           only the newest rotation; public_id is a redacted audit column, so rotated_at is
--                           the only thing that CAN show a rotation there)
--    Not included, on purpose: driver opens (page_builder_list already shows the last one), photo uploads,
--    and map saves under the old save-as-you-draw builder (the map is now inside the submitted version, so
--    "Version N submitted by X" is who drew it). The collector link and the driver link are never read
--    into the result (VERIFY 3b compares).
--    A staff JWT only, the same gate and words as client.get_page_builder. EXECUTE: authenticated only.
--
-- Rule 8 (audit): no new table. The one write this adds (approve -> properties.site_map) lands on
-- public.properties, which has audit_properties, in the approving request, so the audit row carries the
-- approver's JWT and app_source. It fires trg_properties_updated_at and not the Jobber outbound trigger
-- (that one fires only on the grease trap size and the lock box code). Grants: new functions revoked by name, whole proacl asserted; replaced
-- functions keep theirs (asserted). ATOMIC: no COMMIT. The VERIFY's writes (two versions, an approval, a
-- temporary approver, a driver open, a link rotation, a test intake and its cancel) run in a sentinel
-- sub-block and are rolled back; VERIFY 4 checks the property, the versions, the approver list, the opens,
-- the driver link and the test intake by value.
--
-- Reviewed before apply by an adversarial pass (dry runs only). Its findings, all fixed here: approving a
-- version without a map set the column to NULL and restarted the revision (so a stale save was accepted);
-- approve overwrote a map the older builder was still drawing; the older builder's "Nothing changed" check
-- lost its map baseline; update_property_site_map could overwrite a concurrent approval; approve locked the
-- property on every call; a non-object baseline raised a raw error; and the VERIFY did not cover an
-- approval without a map, an older builder's approval, the no-op approval or the two audit-read events.
--
-- SHIP WITH, same cycle (workspace CLAUDE.md 4b):
--   - Supabase/docs/reference/client-intake-system.md rule 18 (map in the draft, approve syncs the
--     property, staff names, activity).
--   - Building Apps/Picture Planner/CLAUDE.md + docs/08-changelog.md when the Planner batch ships.
-- ============================================================================

-- ----------------------------------------------------------------- 0. the bodies this was built from are the live ones
do $pin$
begin
  if md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)'::regprocedure)) <> '4c7ad1ee1ec69fdf2c55d2ce68e7253b' then
    raise exception 'PIN: client.submit_property_page changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> '5bf7530c548772aa8c7bc4c33891ad27' then
    raise exception 'PIN: client.approve_property_page changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '17a68767dcc8060f78529783f3cf29fb' then
    raise exception 'PIN: client.get_page_builder changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.page_builder_list()'::regprocedure)) <> '916efb8c1f3a7f94a88303b4df89b93d' then
    raise exception 'PIN: client.page_builder_list changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_page_source(bigint)'::regprocedure)) <> 'cce019df417094afe2e67ef15681f037' then
    raise exception 'PIN: public.fn_page_source changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_site_map_round(jsonb)'::regprocedure)) <> '910fcc3b7ec75141571afc9cb6d5ca00'
     or md5(pg_get_functiondef('public.fn_site_map_problem(jsonb)'::regprocedure)) <> '58f0be06097db41f404c1fc715435562' then
    raise exception 'PIN: fn_site_map_round or fn_site_map_problem changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.update_property_site_map(bigint,jsonb,integer)'::regprocedure)) <> '9a1055daa9b62ac6b3bb3cc50291235a' then
    raise exception 'PIN: client.update_property_site_map changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_property_pages_append_only()'::regprocedure)) <> '96f7a72acc9d404ad1fab03960063b13' then
    raise exception 'PIN: fn_property_pages_append_only changed since this migration was written';
  end if;
  if exists (select 1 from public.properties where site_map is not null) then
    raise exception 'PIN: a property now holds a site map; re-read the plan (it assumed none)';
  end if;
end $pin$;

-- ----------------------------------------------------------------- 1. a staff screen names a person by name, else by login email
create function public.fn_page_staff_name(p_email text)
returns text
language sql
stable
set search_path to ''
as $function$
  select case when nullif(btrim(p_email), '') is null then null
    else coalesce((select btrim(e.full_name) from public.employees e
                    where lower(e.email) = lower(btrim(p_email)) and btrim(coalesce(e.full_name, '')) <> ''
                    order by (e.status = 'ACTIVE') desc, e.id limit 1),
                  lower(btrim(p_email))) end
$function$;
revoke all on function public.fn_page_staff_name(text) from public, anon, authenticated, service_role;
grant execute on function public.fn_page_staff_name(text) to service_role;

-- ----------------------------------------------------------------- 2. the page is built from these property facts (no map any more)
CREATE OR REPLACE FUNCTION public.fn_page_source(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
           'lock_box_key',   cp.lock_box_key,
           'access_schedule', cp.access_schedule,
           'gallons',        cp.grease_capacity_gallons,
           'manholes',       cp.grease_trap_manhole_count,
           'sample_ports',   cp.sample_port_count,
           'access_notes',   nullif(btrim(cp.access_notes), ''))
    from client.properties cp
    join public.properties p on p.id = cp.id
   where cp.id = p_property_id
$function$;

-- ----------------------------------------------------------------- 3. submit: the draft's map is the version's map
CREATE OR REPLACE FUNCTION client.submit_property_page(p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb)
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

  insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
  values (p_property_id, v_newest + 1, v_content, v_source, v_uid, v_email)
  returning id into v_id;

  insert into public.property_page_links (property_id, created_by)
  values (p_property_id, v_uid)
  on conflict (property_id) do nothing;

  return jsonb_build_object('ok', true, 'page_id', v_id, 'version', v_newest + 1);
end $function$;

-- ----------------------------------------------------------------- 4. approve: the approved map becomes the property's map
CREATE OR REPLACE FUNCTION client.approve_property_page(p_page_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_page  public.property_pages;
  v_newest int;
  v_block text;
  v_map   jsonb;
  v_cur   jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.approve_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.approve_property_page';
  end if;
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can approve a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.approve_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.approve_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved.' using errcode = '22023',
      detail = 'blocker=already_approved in client.approve_property_page';
  end if;
  select max(version) into v_newest from public.property_pages where property_id = v_page.property_id;
  if v_page.version <> v_newest then
    raise exception 'A newer version of this page was submitted. Approve that one instead.' using errcode = '22023',
      detail = 'blocker=not_newest in client.approve_property_page';
  end if;
  if v_page.submitted_by = v_uid then
    raise exception 'You submitted this version, so another person has to approve it.' using errcode = '42501',
      detail = 'blocker=own_version in client.approve_property_page';
  end if;
  v_block := public.fn_page_blocker(v_page.property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.approve_property_page';
  end if;

  update public.property_pages
     set approved_at = now(), approved_by = v_uid, approved_by_email = v_email
   where id = p_page_id;

  -- Since 2026-09-27 the map is drawn in the draft and reaches the property only here, when a second
  -- person approves it (Fred: "Make it draft-only"). Only a version whose map came from the draft is
  -- copied: submit stores that map as an object WITHOUT rev. A version from an older builder froze the
  -- property's own map (NULL or an object WITH rev) while that builder may still be drawing on the
  -- property, so it is left alone. The revision always moves and the column is never set to NULL (a
  -- NULL restarts the revision at 0, and a stale save at that number would be accepted). The row is
  -- locked only when there is something to write.
  v_map := v_page.content -> 'site_map';
  if jsonb_typeof(v_map) = 'object' and not (v_map ? 'rev') then
    select p.site_map into v_cur from public.properties p where p.id = v_page.property_id;
    if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
      select p.site_map into v_cur from public.properties p where p.id = v_page.property_id for update;
      if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
        update public.properties
           set site_map = v_map || jsonb_build_object('rev', coalesce((v_cur ->> 'rev')::int, 0) + 1)
         where id = v_page.property_id;
      end if;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$;

-- ----------------------------------------------------------------- 5. staff names on the builder and the list
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
    when v_pend.submitted_by = v_uid then 'You submitted this version, so another person has to approve it.'
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
  refd as (
    select distinct (ph ->> 'photo_id')::bigint as photo_id
      from (select v_live.content as c union all select v_pend.content) s,
           jsonb_array_elements(s.c -> 'photos') ph
     where s.c is not null)
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
    'approvers', public.fn_page_approver_names())
  into v_out;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION client.page_builder_list()
 RETURNS TABLE(property_id bigint, client_id bigint, client_code text, client_name text, property_name text, address text, city text, intake_status text, intake_id bigint, live_version integer, live_approved_at timestamp with time zone, live_approved_by_name text, pending_version integer, pending_submitted_at timestamp with time zone, pending_submitted_by_name text, property_changed_since_live boolean, photos_no_longer_available integer, has_link boolean, link_blocker text, last_opened_at timestamp with time zone, last_open_was_staff boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.page_builder_list';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.page_builder_list';
  end if;
  return query
  select pi.property_id,
         pi.client_id,
         c.client_code::text,
         c.name::text,
         nullif(btrim(p.name), '')::text,
         p.address::text,
         p.city::text,
         pi.intake_status::text,
         pi.intake_id,
         lv.version,
         lv.approved_at,
         case when lv.id is null then null else public.fn_page_staff_name(lv.approved_by_email) end,
         pv.version,
         pv.submitted_at,
         case when pv.id is null then null else public.fn_page_staff_name(pv.submitted_by_email) end,
         (lv.id is not null and (lv.source - 'site_map') is distinct from public.fn_page_source(p.id)),
         case when lv.id is null then 0 else (
           select count(*)::int from jsonb_array_elements(lv.content -> 'photos') ph
            where not exists (select 1 from public.fn_page_photo_ids(p.id) o
                               where o.photo_id = (ph ->> 'photo_id')::bigint)) end,
         (l.property_id is not null),
         public.fn_page_blocker(p.id),
         lo.opened_at,
         lo.staff
    from client.v_property_intake pi
    join public.properties p on p.id = pi.property_id
    join public.clients c    on c.id = pi.client_id
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is not null
                        order by x.version desc limit 1) lv on true
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is null
                          and x.version > coalesce(lv.version, 0)
                        order by x.version desc limit 1) pv on true
    left join lateral (select o.opened_at, o.staff from public.property_page_opens o
                        where o.property_id = p.id order by o.opened_at desc limit 1) lo on true
    left join public.property_page_links l on l.property_id = p.id
   where nullif(btrim(c.client_code), '') is not null
   order by c.client_code, p.id;
end $function$;

-- ----------------------------------------------------------------- 5b. the older builder's map save takes the row lock
CREATE OR REPLACE FUNCTION client.update_property_site_map(p_property_id bigint, p_site_map jsonb, p_expected_rev integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_problem text;
  v_cur     jsonb;
  v_cur_rev integer;
  v_next    jsonb;
  v_lat     numeric;
  v_lng     numeric;
  v_far     int;
begin
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

  select site_map, latitude, longitude into v_cur, v_lat, v_lng
    from public.properties
   where id = p_property_id and deleted_at is null
   for update;   -- 2026-09-27: an approval committing between this read and the UPDATE must not be overwritten
  if not found then
    raise exception 'property % is not a live property', p_property_id using errcode = 'P0002';
  end if;

  v_cur_rev := coalesce((v_cur ->> 'rev')::integer, 0);
  -- Optimistic lock. Cheap insurance rather than a measured contention problem: two
  -- office people building maps at once has not been observed, and Fred's decision 8b
  -- is explicitly that a silent last-write-wins is not acceptable.
  if p_expected_rev is not null and p_expected_rev <> v_cur_rev then
    raise exception 'the site map changed since you opened it (you had revision %, stored revision is %)',
      p_expected_rev, v_cur_rev using errcode = '40001';
  end if;

  if p_site_map is null then                      -- clearing the map is legal
    update public.properties set site_map = null where id = p_property_id;
    return jsonb_build_object('ok', true, 'cleared', true, 'rev', v_cur_rev);
  end if;

  -- Round FIRST, then validate, so precision cannot push a legal map over the cap.
  v_next := public.fn_site_map_round(p_site_map);
  v_problem := public.fn_site_map_problem(v_next);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '22023';
  end if;

  -- Sanity bound against the property's own geocode. ⚠ THIS DOES NOT CATCH A PIN ON
  -- THE WRONG BUILDING OF THE SAME CLIENT: the six-property client's buildings are
  -- metres apart. It catches a grossly wrong pin, the wrong city or a swapped
  -- lat/lng, and that is all it claims.
  if v_lat is not null and v_lng is not null then
    select count(*) into v_far
      from jsonb_each(coalesce(v_next->'pins','{}'::jsonb)) e(k,v)
     where abs((v->>'lat')::numeric - v_lat) > 0.05
        or abs((v->>'lng')::numeric - v_lng) > 0.05;
    if v_far > 0 then
      raise exception '% pin(s) are more than about 5 km from this property''s address; check the map is on the right property',
        v_far using errcode = '22023';
    end if;
  end if;

  v_next := v_next || jsonb_build_object('rev', v_cur_rev + 1);
  -- updated_at is set by trg_properties_updated_at; never set it here.
  update public.properties set site_map = v_next where id = p_property_id;

  return jsonb_build_object('ok', true, 'rev', v_cur_rev + 1, 'site_map', v_next);
end $function$;

-- ----------------------------------------------------------------- 6. Activity History
create function client.get_property_activity(p_property_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
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
             'text', ev.what || coalesce(' by ' || ev.who, ''))
           order by ev.at desc, ev.ord desc)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email)
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), '')
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
                  order by l.changed_at desc limit 1))
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the driver page submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email)
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the driver page approved',
               public.fn_page_staff_name(pg.approved_by_email)
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Driver link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by))
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Driver link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email')
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$;
revoke all on function client.get_property_activity(bigint) from public, anon, authenticated, service_role;
grant execute on function client.get_property_activity(bigint) to authenticated;

-- ----------------------------------------------------------------- 7. VERIFY
do $verify$
declare
  v_fred    uuid;
  v_maker   uuid := gen_random_uuid();
  v_checker uuid := gen_random_uuid();
  v_pb      jsonb;
  v_base    jsonb;
  v_draft   jsonb;
  v_r       jsonb;
  v_act     jsonb;
  v_dp      jsonb;
  v_row     record;
  v_stored  jsonb;
  v_state   text; v_detail text;
  v_t       text;
  v_lat     numeric;
  v_lng     numeric;
  v_rev     int;
  v_int     bigint;
  v_newlink text;
  v_pid     bigint;
  v_ver0    int    := (select coalesce(max(version), 0) from public.property_pages where property_id = 1164);
  v_map0    jsonb  := (select site_map from public.properties where id = 1164);
  v_appr0   text   := (select value from public.app_config where key = 'page_approvers');
  v_opens0  int    := (select count(*) from public.property_page_opens where property_id = 1164);
  v_link    text   := (select public_id from public.property_page_links where property_id = 1164);
begin
  select id into v_fred from auth.users where lower(email) = 'fred@ayache.com';
  if v_fred is null then raise exception 'VERIFY 0: fred@ayache.com is missing from auth.users'; end if;
  if v_link is null then raise exception 'VERIFY 0: property 1164 has no driver link to read back'; end if;
  if not exists (select 1 from public.property_pages where property_id = 1164 and approved_at is not null and source ? 'site_map') then
    raise exception 'VERIFY 0: property 1164 no longer has an approved version with an old-shaped source (V2d needs one)';
  end if;

  -- V1. Grants and flags: new functions exactly; replaced ones kept theirs.
  if (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = 'client.get_property_activity(bigint)'::regprocedure)
     <> '{postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 1a: get_property_activity proacl is %',
      (select p.proacl::text from pg_proc p where p.oid = 'client.get_property_activity(bigint)'::regprocedure);
  end if;
  if (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = 'public.fn_page_staff_name(text)'::regprocedure)
     <> '{postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 1b: fn_page_staff_name proacl is %',
      (select p.proacl::text from pg_proc p where p.oid = 'public.fn_page_staff_name(text)'::regprocedure);
  end if;
  foreach v_t in array array['anon', 'service_role', 'yannick_readonly', 'pg_read_all_data', 'supabase_read_only_user'] loop
    if has_function_privilege(v_t, 'client.get_property_activity(bigint)', 'EXECUTE') then
      raise exception 'VERIFY 1c: % can execute client.get_property_activity', v_t;
    end if;
  end loop;
  if not coalesce((select p.prosecdef and p.provolatile = 's' and 'search_path=""' = any (p.proconfig)
                     from pg_proc p where p.oid = 'client.get_property_activity(bigint)'::regprocedure), false) then
    raise exception 'VERIFY 1d: get_property_activity is not SECURITY DEFINER, STABLE and search_path pinned to empty';
  end if;
  if (select string_agg(coalesce(p.proacl::text, 'NULL'), ' ' order by p.oid::regprocedure::text) from pg_proc p
       where p.oid in ('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)'::regprocedure,
                       'client.approve_property_page(bigint)'::regprocedure, 'client.get_page_builder(bigint)'::regprocedure,
                       'client.page_builder_list()'::regprocedure))
     <> '{postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres}'
     or (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = 'public.fn_page_source(bigint)'::regprocedure)
        <> '{postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 1e: a replaced function lost or gained a grant';
  end if;

  -- V2. Names and the source, no writes.
  if public.fn_page_staff_name('fred@ayache.com') is distinct from 'Fred'
     or public.fn_page_staff_name('  FRED@ayache.com ') is distinct from 'Fred'
     or public.fn_page_staff_name('verify.maker@ayache.com') is distinct from 'verify.maker@ayache.com'
     or public.fn_page_staff_name(null) is not null or public.fn_page_staff_name(' ') is not null then
    raise exception 'VERIFY 2a: fn_page_staff_name is wrong';
  end if;
  if public.fn_page_person_name('verify.maker@ayache.com') is distinct from 'the office' then
    raise exception 'VERIFY 2b: the public driver page name changed (it must not show a login email)';
  end if;
  if public.fn_page_source(1164) ? 'site_map' or not (public.fn_page_source(1164) ? 'lock_box_key') then
    raise exception 'VERIFY 2c: fn_page_source is %', public.fn_page_source(1164);
  end if;
  -- 2d. A version stored before today (its source still carries site_map) does not read "changed since live"
  -- just for that key. 1164's live v1 has the same facts as today (checked when this was written).
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  select * into v_row from client.page_builder_list() x where x.property_id = 1164;
  reset role;
  if v_row.property_changed_since_live is distinct from false then
    raise exception 'VERIFY 2d: 1164 reads changed since live (%) after the source lost its map key', v_row.property_changed_since_live;
  end if;

  begin
    -- A temporary approver for this test only, a fake login with no employee row (so the email fallback
    -- is what every staff screen must show, and the public driver page must still say "the office").
    -- No real approver's identity is used.
    update public.app_config set value = value || ',' || v_checker::text where key = 'page_approvers';

    -- V3a. Draft-only submit: the draft's map is frozen, rounded, without rev, and the property is untouched.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_maker, 'email', 'verify.maker@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    v_base := coalesce(v_pb -> 'pending' -> 'content', v_pb -> 'live' -> 'content');
    v_lat := (v_pb -> 'property' ->> 'lat')::numeric;
    v_lng := (v_pb -> 'property' ->> 'lng')::numeric;
    v_draft := jsonb_build_object(
      'pins', jsonb_build_object(
        'truck', jsonb_build_object('lat', v_lat + 0.00012345678, 'lng', v_lng - 0.0002),
        'gt',    jsonb_build_object('lat', v_lat - 0.0001, 'lng', v_lng + 0.00009876543)),
      'arrows', jsonb_build_array(jsonb_build_object('points', jsonb_build_array(
        jsonb_build_object('lat', v_lat + 0.0003, 'lng', v_lng - 0.0003),
        jsonb_build_object('lat', v_lat + 0.0001, 'lng', v_lng - 0.00011111111)))),
      'rev', 7);
    v_r := client.submit_property_page(1164, v_base || jsonb_build_object('site_map', v_draft),
             (v_pb ->> 'newest_version')::int, 99, v_pb -> 'property' -> 'source');
    if not coalesce((v_r ->> 'ok')::boolean, false) or (v_r ->> 'version')::int <> v_ver0 + 1 then
      raise exception 'VERIFY 3a: the draft-only submit was not accepted (%)', v_r;
    end if;
    reset role;
    select content -> 'site_map' into v_stored from public.property_pages where property_id = 1164 and version = v_ver0 + 1;
    if v_stored is distinct from public.fn_site_map_round(v_draft) - 'rev'
       or (v_stored -> 'pins' -> 'truck' ->> 'lat')::numeric <> round(v_lat + 0.00012345678, 6)
       or jsonb_array_length(v_stored -> 'arrows') <> 1 then
      raise exception 'VERIFY 3a: the stored map is %', v_stored;
    end if;
    if (select site_map from public.properties where id = 1164) is distinct from v_map0 then
      raise exception 'VERIFY 3a: a submit wrote the property''s map (it must wait for the approval)';
    end if;

    -- V3b. The activity names the maker by email (no employee row) and never carries a link.
    set local role authenticated;
    v_act := client.get_property_activity(1164);
    reset role;
    if v_act -> 0 ->> 'kind' is distinct from 'page_submitted' or (v_act -> 0 ->> 'version')::int <> v_ver0 + 1
       or v_act -> 0 ->> 'who' is distinct from 'verify.maker@ayache.com'
       or v_act -> 0 ->> 'text' is distinct from 'Version ' || (v_ver0 + 1) || ' of the driver page submitted for approval by verify.maker@ayache.com' then
      raise exception 'VERIFY 3b: the newest activity is %', v_act -> 0;
    end if;
    if not exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'kind' = 'form_filled' and (e ->> 'intake_id')::bigint = 686)
       or not exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'kind' = 'form_requested' and (e ->> 'intake_id')::bigint = 686)
       or not exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'kind' = 'page_approved' and (e ->> 'version')::int = 1)
       or not exists (select 1 from jsonb_array_elements(v_act) e where e ->> 'kind' = 'driver_link_created') then
      raise exception 'VERIFY 3b: an expected event of property 1164 is missing (%)', v_act;
    end if;
    -- A regression guard (the function selects neither column today; V3g repeats it after a rotation).
    if position(v_link in v_act::text) > 0
       or exists (select 1 from public.property_intakes i where i.property_id = 1164 and position(i.token in v_act::text) > 0) then
      raise exception 'VERIFY 3b: a driver link or collector link reached the activity';
    end if;

    -- V3c. Approve as another person: the approved map becomes the property's map (rev + 1); every
    -- staff screen and the driver page read the same map and the names.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_checker, 'email', 'verify.checker@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    if v_pb -> 'pending' ->> 'submitted_by_name' is distinct from 'verify.maker@ayache.com' or not (v_pb ->> 'can_approve')::boolean then
      raise exception 'VERIFY 3c: the builder shows % / can_approve %', v_pb -> 'pending' ->> 'submitted_by_name', v_pb ->> 'can_approve';
    end if;
    v_r := client.approve_property_page((v_pb -> 'pending' ->> 'page_id')::bigint);
    if not coalesce((v_r ->> 'ok')::boolean, false) then raise exception 'VERIFY 3c: the approval failed (%)', v_r; end if;
    v_pb := client.get_page_builder(1164);
    select * into v_row from client.page_builder_list() x where x.property_id = 1164;
    v_act := client.get_property_activity(1164);
    reset role;
    if (select site_map - 'rev' from public.properties where id = 1164) is distinct from v_stored
       or (select (site_map ->> 'rev')::int from public.properties where id = 1164) <> coalesce((v_map0 ->> 'rev')::int, 0) + 1 then
      raise exception 'VERIFY 3c: the property''s map after approval is %', (select site_map from public.properties where id = 1164);
    end if;
    if (v_pb -> 'live' ->> 'version')::int <> v_ver0 + 1
       or v_pb -> 'live' ->> 'submitted_by_name' is distinct from 'verify.maker@ayache.com'
       or v_pb -> 'live' ->> 'approved_by_name' is distinct from 'verify.checker@ayache.com'
       or v_pb -> 'live' -> 'content' -> 'site_map' is distinct from v_stored then
      raise exception 'VERIFY 3c: the builder''s live version is %', (v_pb -> 'live') - 'content';
    end if;
    if v_row.live_version <> v_ver0 + 1 or v_row.live_approved_by_name is distinct from 'verify.checker@ayache.com'
       or v_row.property_changed_since_live then
      raise exception 'VERIFY 3c: the list row is v% by % changed=%', v_row.live_version, v_row.live_approved_by_name, v_row.property_changed_since_live;
    end if;
    if v_act -> 0 ->> 'kind' is distinct from 'page_approved' or v_act -> 0 ->> 'who' is distinct from 'verify.checker@ayache.com'
       or v_act -> 1 ->> 'kind' is distinct from 'page_submitted' then
      raise exception 'VERIFY 3c: the newest activity is % then %', v_act -> 0, v_act -> 1;
    end if;
    v_dp := public.fn_driver_page(v_link, true, 'verify 2026-09-27');
    if (v_dp ->> 'version')::int <> v_ver0 + 1 or v_dp -> 'content' -> 'site_map' is distinct from v_stored
       or v_dp ->> 'approved_by' is distinct from 'the office' then
      raise exception 'VERIFY 3c: the driver page shows v% map % by %', v_dp ->> 'version', v_dp -> 'content' -> 'site_map', v_dp ->> 'approved_by';
    end if;

    -- V3d. A builder from before this change (no site_map key) still works: it freezes the property's map,
    -- guarded by the revision, and its baseline may still carry the map.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_maker, 'email', 'verify.maker@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    begin
      perform client.submit_property_page(1164, v_base - 'site_map', (v_pb ->> 'newest_version')::int, 0, v_pb -> 'property' -> 'source');
      raise exception 'VERIFY 3d: an old-style submit with a stale map revision went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail is distinct from 'blocker=map_changed in client.submit_property_page' then
        raise exception 'VERIFY 3d: the stale-revision submit gave % / %', v_state, v_detail;
      end if;
    end;
    if v_pb -> 'property' -> 'source' -> 'site_map' is distinct from v_stored then
      raise exception 'VERIFY 3d: the builder''s source does not carry the property''s map for the older builder (%)',
        v_pb -> 'property' -> 'source' -> 'site_map';
    end if;
    begin
      perform client.submit_property_page(1164, v_base - 'site_map', (v_pb ->> 'newest_version')::int,
                (v_pb -> 'property' ->> 'site_map_rev')::int,
                (v_pb -> 'property' -> 'source') || jsonb_build_object('site_map', '{}'::jsonb));
      raise exception 'VERIFY 3d: an old-style submit whose baseline map differs went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail is distinct from 'blocker=map_changed in client.submit_property_page' then
        raise exception 'VERIFY 3d: the different-map submit gave % / %', v_state, v_detail;
      end if;
    end;
    v_r := client.submit_property_page(1164, v_base - 'site_map', (v_pb ->> 'newest_version')::int,
             (v_pb -> 'property' ->> 'site_map_rev')::int, v_pb -> 'property' -> 'source');
    reset role;
    if (v_r ->> 'version')::int <> v_ver0 + 2
       or (select content -> 'site_map' from public.property_pages where property_id = 1164 and version = v_ver0 + 2)
          is distinct from (select site_map from public.properties where id = 1164) then
      raise exception 'VERIFY 3d: the old-style submit did not freeze the property''s map (%)', v_r;
    end if;
    -- Its approval must NOT copy the map (the older builder may still be drawing on the property).
    v_rev := (select (site_map ->> 'rev')::int from public.properties where id = 1164);
    v_pid := (select id from public.property_pages where property_id = 1164 and version = v_ver0 + 2);
    update public.properties set site_map = site_map || jsonb_build_object('pins', jsonb_build_object(
             'truck', jsonb_build_object('lat', round(v_lat + 0.0003, 6), 'lng', round(v_lng, 6))), 'rev', v_rev + 1)
     where id = 1164;          -- the older builder keeps drawing after its submit
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_checker, 'email', 'verify.checker@ayache.com', 'role', 'authenticated')::text, true);
    perform client.approve_property_page(v_pid);
    reset role;
    if (select (site_map ->> 'rev')::int from public.properties where id = 1164) <> v_rev + 1
       or (select site_map -> 'pins' -> 'truck' ->> 'lat' from public.properties where id = 1164)::numeric <> round(v_lat + 0.0003, 6) then
      raise exception 'VERIFY 3d: approving an older builder''s version changed the property''s map (%)',
        (select site_map from public.properties where id = 1164);
    end if;
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_maker, 'email', 'verify.maker@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);

    -- V3e. Refusals of the draft map, and an empty map stored as no map.
    set local role authenticated;
    begin
      perform client.submit_property_page(1164, v_base || jsonb_build_object('site_map',
                jsonb_build_object('pins', jsonb_build_object('truck', jsonb_build_object('lat', v_lat + 1, 'lng', v_lng)))),
                v_ver0 + 2, 0, v_pb -> 'property' -> 'source');
      raise exception 'VERIFY 3e: a pin 100 km away went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=pin_far in client.submit_property_page' then
        raise exception 'VERIFY 3e: the far pin gave % / %', v_state, v_detail;
      end if;
    end;
    begin
      perform client.submit_property_page(1164, v_base || jsonb_build_object('site_map',
                jsonb_build_object('pins', jsonb_build_object('truck', jsonb_build_object('lat', 'x', 'lng', v_lng)))),
                v_ver0 + 2, 0, v_pb -> 'property' -> 'source');
      raise exception 'VERIFY 3e: a malformed map went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=site_map in client.submit_property_page' then
        raise exception 'VERIFY 3e: the malformed map gave % / %', v_state, v_detail;
      end if;
    end;
    v_r := client.submit_property_page(1164, v_base || jsonb_build_object('site_map', jsonb_build_object('pins', '{}'::jsonb, 'arrows', '[]'::jsonb)),
             v_ver0 + 2, 0, v_pb -> 'property' -> 'source');
    reset role;
    if (select content -> 'site_map' from public.property_pages where property_id = 1164 and version = v_ver0 + 3) is distinct from '{}'::jsonb then
      raise exception 'VERIFY 3e: an empty draft map was not stored as {}';
    end if;
    -- Approving it clears the pins but keeps a revision (never NULL, never back to 0).
    v_rev := (select (site_map ->> 'rev')::int from public.properties where id = 1164);
    v_pid := (select id from public.property_pages where property_id = 1164 and version = v_ver0 + 3);
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_checker, 'email', 'verify.checker@ayache.com', 'role', 'authenticated')::text, true);
    perform client.approve_property_page(v_pid);
    reset role;
    if (select site_map from public.properties where id = 1164) is distinct from jsonb_build_object('rev', v_rev + 1) then
      raise exception 'VERIFY 3e: approving a version without pins left %', (select site_map from public.properties where id = 1164);
    end if;
    -- A second version with the same (empty) map: the approval writes nothing (no-op path).
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_maker, 'email', 'verify.maker@ayache.com', 'role', 'authenticated')::text, true);
    perform client.submit_property_page(1164, v_base || jsonb_build_object('site_map', null), v_ver0 + 3, 0,
              client.get_page_builder(1164) -> 'property' -> 'source');
    reset role;
    v_pid := (select id from public.property_pages where property_id = 1164 and version = v_ver0 + 4);
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_checker, 'email', 'verify.checker@ayache.com', 'role', 'authenticated')::text, true);
    perform client.approve_property_page(v_pid);
    reset role;
    if (select site_map from public.properties where id = 1164) is distinct from jsonb_build_object('rev', v_rev + 1) then
      raise exception 'VERIFY 3e: approving the same map again changed the property (%)', (select site_map from public.properties where id = 1164);
    end if;

    -- V3g. The two events read from audit.logs: a driver link rotation and a cancelled form, each with its person.
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (select array_agg(question_key) from client.v_intake_questions))),
           '[TEST] activity verify 2026-09-27'
      from (select public.fn_intake_form_current() s) x
    returning id into v_int;
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_maker, 'email', 'verify.maker@ayache.com', 'role', 'authenticated')::text, true);
    v_newlink := client.rotate_driver_link(1164) ->> 'public_id';
    perform client.cancel_intake(v_int);
    v_act := client.get_property_activity(1164);
    reset role;
    if not exists (select 1 from jsonb_array_elements(v_act) e
                    where e ->> 'kind' = 'driver_link_replaced' and e ->> 'who' = 'verify.maker@ayache.com')
       or not exists (select 1 from jsonb_array_elements(v_act) e
                       where e ->> 'kind' = 'form_cancelled' and (e ->> 'intake_id')::bigint = v_int
                         and e ->> 'who' = 'verify.maker@ayache.com'
                         and e ->> 'text' = 'Site survey form #' || v_int || ' cancelled by verify.maker@ayache.com') then
      raise exception 'VERIFY 3g: a rotation or a cancel is missing from the activity, or names the wrong person (%)', v_act;
    end if;
    if v_newlink is null or position(v_newlink in v_act::text) > 0 or position(v_link in v_act::text) > 0 then
      raise exception 'VERIFY 3g: a driver link reached the activity (or the rotation returned none)';
    end if;

    -- V3f. Activity refusals, exact code and DETAIL.
    set local role authenticated;
    begin
      perform client.get_property_activity(null);
      raise exception 'VERIFY 3f: a null property was not refused' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=no_property in client.get_property_activity' then
        raise exception 'VERIFY 3f: a null property gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'someone@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.get_property_activity(1164);
      raise exception 'VERIFY 3f: a non-staff email read the activity' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=not_staff in client.get_property_activity' then
        raise exception 'VERIFY 3f: non-staff gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', '', true);
    begin
      perform client.get_property_activity(1164);
      raise exception 'VERIFY 3f: no JWT read the activity' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '28000' or v_detail is distinct from 'blocker=not_signed_in in client.get_property_activity' then
        raise exception 'VERIFY 3f: no JWT gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    set local role anon;
    begin
      perform client.get_property_activity(1164);
      raise exception 'VERIFY 3f: anon read the activity' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 3f: anon gave %', v_state; end if;
    end;
    reset role;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V4. Nothing from the test survived, checked by value.
  if (select coalesce(max(version), 0) from public.property_pages where property_id = 1164) <> v_ver0
     or (select site_map from public.properties where id = 1164) is distinct from v_map0
     or (select value from public.app_config where key = 'page_approvers') is distinct from v_appr0
     or (select count(*) from public.property_page_opens where property_id = 1164) <> v_opens0
     or (select public_id from public.property_page_links where property_id = 1164) is distinct from v_link
     or exists (select 1 from public.property_intakes where requested_by = '[TEST] activity verify 2026-09-27') then
    raise exception 'VERIFY 4: test rows survived the rollback';
  end if;

  raise notice 'VERIFY: all map-in-draft, staff name and activity assertions passed';
end $verify$;

notify pgrst, 'reload schema';
