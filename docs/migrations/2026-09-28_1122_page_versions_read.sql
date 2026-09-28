-- ============================================================================
-- 2026-09-28_1122_page_versions_read.sql (applied 2026-09-28_1321 ET)
-- 2026-09-28 · Driver page versions for the Page Builder's Activity modal (read only)
-- ============================================================================
-- Fred, 2026-09-28, picking mockup C:
--   "Also the 'Activity' section at the bottom, don't show it there, create a button, next to the top button that
--    'View drivers page' is on the header, called 'Activity' there when clicked it opens a modal, also I like you go
--    with versioning for it, so do a research on how to display versioning for Activity Trails."
-- Plan: Building Apps/Picture Planner/docs/specs/2026-09-28-intake-accept-tab-plan.md (addendum, Activity C).
--
-- 1. NEW client.get_page_versions(p_property_id bigint) returns every version of the property's driver page as a jsonb
--    array, newest first:
--      {page_id, version, status, content, submitted_at, submitted_by_name, approved_at, approved_by_name,
--       self_approved, replaced_by_version, replaced_at}
--    status is one of four, all derived, none stored:
--      live        the highest APPROVED version (the same row client.get_page_builder returns as 'live').
--      replaced    approved, below the live one. replaced_by_version = the next APPROVED version, replaced_at = when
--                  that one was approved (approve only takes the newest version, so approvals go up in order and the
--                  next approved version is the one that took over).
--      waiting     not approved and the NEWEST version (the same row get_page_builder returns as 'pending').
--      superseded  not approved and not the newest: somebody submitted again before it was approved. submit does not
--                  refuse over a waiting version and approve refuses anything but the newest (blocker=not_newest), so
--                  it can never go live; no withdraw exists. replaced_by_version = the next version, replaced_at = when
--                  that one was SUBMITTED. None exists today (measured 2026-09-28 11:22 ET: 5 versions, 4 approved,
--                  1 waiting), so VERIFY 4 builds one.
--    Names come from public.fn_page_staff_name (employee name, else login email), exactly as get_page_builder does.
--    self_approved = approved_by = submitted_by (a developer approval, rule 18), false while not approved.
-- 2. content is returned whole so the Planner can diff two versions with its existing review diff (it compares two
--    contents). The live and waiting versions' content already reaches staff through get_page_builder. The REPLACED
--    and SUPERSEDED versions' content, their old lock box and gate codes included, reaches a staff screen for the
--    FIRST time through this function: audit.logs holds it (audit_property_pages) and authenticated holds SELECT on
--    it, but schema audit is not exposed by PostgREST and get_record_history refuses property_pages, so no staff
--    screen could read it before (a privilege is not reachability). The modal's "What changed" prints old and new
--    values as the review does ("Lock box code: OLD -> NEW"), as mockup C, which Fred picked, showed. Staff JWT only,
--    read only; hiding the codes of non-live versions is Fred's call (plan Task 6 Step 1). Today only 112-YA pages
--    have versions. Its keys are fixed by fn_page_content_problem (v, facts, hours, notes, contacts, include_map,
--    photos, plus the server's site_map and per-photo rot). No intake token and no driver link code is ever in it
--    (0 of 5 rows match a 22-character code).
-- 3. A version does NOT record the form(s) it came from: no column, no content key, and get_page_builder's
--    'referenced' lists photos, not forms. The only trace is a photo owned by an intake, and it cannot be read as
--    "made from this form": 1164 v3 carries photos of forms 167, 715 and 717 (carried forward). So the modal groups
--    the activity by time around each version, and this function adds no form link.
--
-- Mirrors get_page_builder's live/pending choice and relies on submit (version = newest + 1), approve (newest only)
-- and the append-only trigger (a version never changes after its approval): all four md5-pinned below.
-- Applies after 2026-09-28_1015 (file order) and does not depend on it: it neither reads nor pins
-- client.get_property_activity, which 1015 replaces.
--
-- Rule 8 (audit): no new table, no write. Grants: revoked by name from public, anon, authenticated and service_role,
-- then EXECUTE to authenticated only (the same proacl as get_property_activity). STABLE, SECURITY DEFINER,
-- search_path ''. ATOMIC: no COMMIT; the VERIFY's test rows are written only inside its sentinel sub-block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('public.fn_page_staff_name(text)'::regprocedure)) <> '24b7a15362dec11c2e28498487dd069d'
     or md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '73acbd96ba7a98e724c830ed15dc3893'
     or md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> 'cad8783dda41a9c0d60d96dff2be7daf'
     or md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)'::regprocedure)) <> '0882778cae55f275c794251621c16ab3'
     or md5(pg_get_functiondef('public.fn_property_pages_append_only()'::regprocedure)) <> '668fb9e3ef3fa8857d102946251833e7' then
    raise exception 'PIN: a page function changed since this migration was written';
  end if;
  -- VERIFY 4 records a developer approval by Fred on a test row.
  if not exists (select 1 from auth.users where id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' and lower(email) = 'fred@ayache.com')
     or not ('5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid = any (public.fn_page_self_approver_ids())) then
    raise exception 'PIN: Fred''s login is not a developer approver any more';
  end if;
end $pin$;

create function client.get_page_versions(p_property_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
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
             'replaced_by_version', r.version, 'replaced_at', r.at)
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
end $function$;

revoke all on function client.get_page_versions(bigint) from public, anon, authenticated, service_role;
grant execute on function client.get_page_versions(bigint) to authenticated;

-- VERIFY. Reads real data first (1164: live v3 over two replaced; 162: live v1 under a waiting v2), then builds a
-- superseded version on 162 inside the sentinel block, which is rolled back.
do $verify$
declare
  v_fred    uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_claims  text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  v_phase   text;
  v_p       bigint;
  v_r       jsonb;
  v_pb      jsonb;
  v_bad     text;
  v_state   text; v_detail text; v_msg text;
  v_seen    int := 0;
  v_live    int := 0;
  v_repl    int := 0;
  v_n       int;
  v_l       int;
  v_b       public.property_pages;
  v_pages0  bigint := (select count(*) from public.property_pages);
  v_aud0    bigint := (select count(*) from audit.logs where table_name = 'property_pages');
  v_n162    int    := (select coalesce(max(version), 0) from public.property_pages where property_id = 162);
begin
  -- V1. Shape and grants.
  if (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.get_page_versions(bigint)'::regprocedure)
       <> '{postgres=X/postgres,authenticated=X/postgres}'
     or (select not prosecdef or provolatile <> 's' or proconfig is distinct from array['search_path=""']
           from pg_proc where oid = 'client.get_page_versions(bigint)'::regprocedure)
     or has_function_privilege('anon', 'client.get_page_versions(bigint)', 'EXECUTE') then
    raise exception 'VERIFY 1: the function''s grant or attributes are wrong';
  end if;

  begin
    -- V2 (real data) and V4 (a built superseded version), checked by the same rules.
    foreach v_phase in array array['real', 'built'] loop
      if v_phase = 'built' then
        -- V4 setup on 162: A (n+1) never approved, B (n+2) approved by Fred who made it, C (n+3) waiting above it.
        -- Four different moments (A made, B made, B approved, C made), so each successor time can only match one.
        insert into public.property_pages (property_id, version, content, source, submitted_at, submitted_by, submitted_by_email)
        values (162, v_n162 + 1, jsonb_build_object('v', 1, 'photos', '[]'::jsonb, 'notes', '[TEST] verify versions A'), '{}'::jsonb,
                now() - interval '40 minutes', gen_random_uuid(), 'verify.versions@ayache.com'),
               (162, v_n162 + 2, jsonb_build_object('v', 1, 'photos', '[]'::jsonb, 'notes', '[TEST] verify versions B'), '{}'::jsonb,
                now() - interval '30 minutes', v_fred, 'fred@ayache.com'),
               (162, v_n162 + 3, jsonb_build_object('v', 1, 'photos', '[]'::jsonb, 'notes', '[TEST] verify versions C'), '{}'::jsonb,
                now() - interval '10 minutes', gen_random_uuid(), 'verify.versions@ayache.com');
        update public.property_pages set approved_at = now() - interval '20 minutes', approved_by = v_fred, approved_by_email = 'fred@ayache.com'
         where property_id = 162 and version = v_n162 + 2;
        select * into v_b from public.property_pages where property_id = 162 and version = v_n162 + 2;
      end if;

      foreach v_p in array (case when v_phase = 'real' then array[1164, 162] else array[162] end)::bigint[] loop
        set local role authenticated;
        perform set_config('request.jwt.claims', v_claims, true);
        v_r  := client.get_page_versions(v_p);
        v_pb := client.get_page_builder(v_p);
        reset role;

        -- one element per stored version, newest first
        if jsonb_typeof(v_r) <> 'array'
           or jsonb_array_length(v_r) <> (select count(*) from public.property_pages where property_id = v_p)
           or exists (select 1 from jsonb_array_elements(v_r) with ordinality a(e, i)
                        join jsonb_array_elements(v_r) with ordinality b(e, i) on b.i = a.i + 1
                       where (b.e ->> 'version')::int >= (a.e ->> 'version')::int) then
          raise exception 'VERIFY 2a (%, %): wrong count or order', v_phase, v_p;
        end if;
        -- every field equals the stored row
        select string_agg(e ->> 'version', ',') into v_bad
          from jsonb_array_elements(v_r) e
          left join public.property_pages pg on pg.id = (e ->> 'page_id')::bigint
         where pg.id is null or pg.property_id <> v_p
            or (e ->> 'version')::int <> pg.version
            or e -> 'content' <> pg.content
            or (e ->> 'submitted_at')::timestamptz <> pg.submitted_at
            or (e ->> 'approved_at')::timestamptz is distinct from pg.approved_at
            or (e ->> 'self_approved')::boolean <> coalesce(pg.approved_by = pg.submitted_by, false)
            or e ->> 'submitted_by_name' is distinct from public.fn_page_staff_name(pg.submitted_by_email)
            or e ->> 'approved_by_name' is distinct from public.fn_page_staff_name(pg.approved_by_email)
            or e ->> 'status' not in ('live', 'replaced', 'waiting', 'superseded');
        if v_bad is not null then
          raise exception 'VERIFY 2b (%, %): versions % do not match the table', v_phase, v_p, v_bad;
        end if;
        -- live and waiting are the rows get_page_builder shows (an independent reader; it sends JSON null, not a missing key)
        if (select count(*) from jsonb_array_elements(v_r) e where e ->> 'status' = 'live')
             <> (coalesce(jsonb_typeof(v_pb -> 'live'), '') = 'object')::int
           or (select count(*) from jsonb_array_elements(v_r) e where e ->> 'status' = 'waiting')
             <> (coalesce(jsonb_typeof(v_pb -> 'pending'), '') = 'object')::int
           or exists (select 1 from jsonb_array_elements(v_r) e
                       where (e ->> 'status' = 'live'
                              and (e ->> 'page_id' is distinct from v_pb -> 'live' ->> 'page_id'
                                   or e -> 'content' <> v_pb -> 'live' -> 'content'
                                   or e ->> 'approved_by_name' is distinct from v_pb -> 'live' ->> 'approved_by_name'))
                          or (e ->> 'status' = 'waiting'
                              and (e ->> 'page_id' is distinct from v_pb -> 'pending' ->> 'page_id'
                                   or e -> 'content' <> v_pb -> 'pending' -> 'content'))) then
          raise exception 'VERIFY 2c (%, %): live or waiting differs from get_page_builder', v_phase, v_p;
        end if;
        -- every replaced / superseded version names a version that exists, at the right moment; the others name none
        if exists (select 1 from jsonb_array_elements(v_r) e
                     left join lateral (select t from jsonb_array_elements(v_r) t
                                         where (t ->> 'version')::int = (e ->> 'replaced_by_version')::int) x on true
                    where case e ->> 'status'
                            when 'replaced' then x.t is null or x.t ->> 'status' not in ('live', 'replaced')
                                                 or (e ->> 'replaced_at')::timestamptz is distinct from (x.t ->> 'approved_at')::timestamptz
                            when 'superseded' then x.t is null
                                                 or (e ->> 'replaced_at')::timestamptz is distinct from (x.t ->> 'submitted_at')::timestamptz
                            else e -> 'replaced_by_version' <> 'null'::jsonb or e -> 'replaced_at' <> 'null'::jsonb end
                       -- and it is the NEXT one: no version between (superseded), no approved version between (replaced)
                       or exists (select 1 from jsonb_array_elements(v_r) y
                                   where (y ->> 'version')::int > (e ->> 'version')::int
                                     and (y ->> 'version')::int < (e ->> 'replaced_by_version')::int
                                     and (e ->> 'status' = 'superseded' or y ->> 'status' in ('live', 'replaced')))) then
          raise exception 'VERIFY 2d (%, %): a replaced or superseded version names the wrong successor', v_phase, v_p;
        end if;

        if v_phase = 'real' then
          v_seen := v_seen + jsonb_array_length(v_r);
          v_live := v_live + (select count(*) from jsonb_array_elements(v_r) e where e ->> 'status' = 'live');
          v_repl := v_repl + (select count(*) from jsonb_array_elements(v_r) e where e ->> 'status' = 'replaced');
        else
          -- V4 expectations, stated as numbers
          v_l := (select max(version) from public.property_pages where property_id = 162 and approved_at is not null and version <= v_n162);
          if (select e ->> 'status' from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 3) is distinct from 'waiting'
             or (select e ->> 'status' from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 2) is distinct from 'live'
             or (select (e ->> 'self_approved')::boolean from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 2) is distinct from true
             or (select e ->> 'approved_by_name' from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 2)
                  is distinct from public.fn_page_staff_name('fred@ayache.com')
             or (select e ->> 'status' from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 1) is distinct from 'superseded'
             or (select (e ->> 'replaced_by_version')::int from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 1)
                  is distinct from v_n162 + 2
             or (select (e ->> 'replaced_at')::timestamptz from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_n162 + 1)
                  is distinct from v_b.submitted_at
             or (v_l is not null
                 and ((select e ->> 'status' from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_l) is distinct from 'replaced'
                      or (select (e ->> 'replaced_by_version')::int from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_l)
                           is distinct from v_n162 + 2
                      or (select (e ->> 'replaced_at')::timestamptz from jsonb_array_elements(v_r) e where (e ->> 'version')::int = v_l)
                           is distinct from v_b.approved_at)) then
            raise exception 'VERIFY 4: the built versions read %', (select jsonb_agg(e - 'content') from jsonb_array_elements(v_r) e);
          end if;
        end if;
      end loop;

      if v_phase = 'real' then
        -- positive control: the rules above ran on real rows, and at least one replaced version (1164 v1, v2 are
        -- replaced for good: pages are append-only)
        if v_seen < 2 or v_live < 1 or v_repl < 1 then
          raise exception 'VERIFY 2e: the real read saw % versions, % live, % replaced; the checks proved nothing', v_seen, v_live, v_repl;
        end if;
        -- it wrote nothing
        if (select count(*) from public.property_pages) <> v_pages0
           or (select count(*) from audit.logs where table_name = 'property_pages') <> v_aud0 then
          raise exception 'VERIFY 2f: a read wrote a row';
        end if;

        -- V3. Refusals, and an unknown property reads as no versions.
        set local role authenticated;
        perform set_config('request.jwt.claims', v_claims, true);
        if client.get_page_versions(-1) is distinct from '[]'::jsonb then
          raise exception 'VERIFY 3a: an unknown property did not read []';
        end if;
        begin
          perform client.get_page_versions(null);
          raise exception 'VERIFY 3b: a null property was read' using errcode = 'P0003';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
          if v_state <> '22023' or v_detail is distinct from 'blocker=no_property in client.get_page_versions' then
            raise exception 'VERIFY 3b: gave % / %', v_state, v_detail;
          end if;
        end;
        perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'verify.outsider@gmail.com', 'role', 'authenticated')::text, true);
        begin
          perform client.get_page_versions(1164);
          raise exception 'VERIFY 3c: a non-staff login read the versions' using errcode = 'P0003';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
          if v_state <> '42501' or v_detail is distinct from 'blocker=not_staff in client.get_page_versions'
             or v_msg is distinct from 'This page is for UnclogMe staff only.' then
            raise exception 'VERIFY 3c: gave % / % / %', v_state, v_detail, v_msg;
          end if;
        end;
        perform set_config('request.jwt.claims', json_build_object('email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
        begin
          perform client.get_page_versions(1164);
          raise exception 'VERIFY 3d: a token with no user read the versions' using errcode = 'P0003';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
          if v_state <> '28000' or v_detail is distinct from 'blocker=not_signed_in in client.get_page_versions' then
            raise exception 'VERIFY 3d: gave % / %', v_state, v_detail;
          end if;
        end;
        reset role;
        -- 3e proves only the schema wall: anon has no USAGE on schema client, so it is refused before EXECUTE is checked.
        -- The grant itself is V1's has_function_privilege('anon', ...).
        set local role anon;
        begin
          perform client.get_page_versions(1164);
          raise exception 'VERIFY 3e: anon got past schema client' using errcode = 'P0003';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate;
          if v_state <> '42501' then raise exception 'VERIFY 3e: anon gave %', v_state; end if;
        end;
        reset role;
      end if;
    end loop;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V5. Nothing from the test survived.
  if (select count(*) from public.property_pages) <> v_pages0
     or (select coalesce(max(version), 0) from public.property_pages where property_id = 162) <> v_n162
     or exists (select 1 from public.property_pages where submitted_by_email = 'verify.versions@ayache.com')
     or (select count(*) from audit.logs where table_name = 'property_pages') <> v_aud0 then
    raise exception 'VERIFY 5: test rows survived the rollback';
  end if;
  raise notice 'VERIFY: every version, newest first, live and waiting as the builder shows them, replaced and superseded name their successor; staff only; writes nothing';
end $verify$;

notify pgrst, 'reload schema';
