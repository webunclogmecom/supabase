-- ============================================================================
-- 2026-08-14_1400: let a signed-in staff user INSERT a photo (Admin Review "Add image")
-- ============================================================================
-- Fred, 2026-08-14: "add a new placeholder box there which is 'Add image' which could
-- also be a drag-n-drop of an image too (PNG, JPEG only)".
--
-- 🛑 THE GRANT ALREADY SAID YES AND THE POLICY SAID NO. This is the grant-vs-policy trap
-- the repo has been bitten by before, and it is invisible in the catalogue:
--     has_table_privilege('authenticated','public.photos','INSERT')  ->  TRUE
--     RLS enabled on public.photos                                   ->  TRUE
--     INSERT policies for authenticated on public.photos             ->  ZERO
-- Three SELECT policies exist, no INSERT one, so every insert is denied at runtime while
-- the GRANT reads as permissive. Probed with SET LOCAL ROLE + a simulated JWT before
-- writing this: photos INSERT = DENIED (42501), photo_links INSERT = ALLOWED,
-- storage upload to 'GT - Visits Images' = ALLOWED. So `photos` was the ONLY blocker.
--
-- ⚠ The first probe reported photo_links as DENIED too. That was the INSTRUMENT: a bare
-- SET LOCAL ROLE has no JWT, and that policy's check is auth.uid()-based. With a
-- simulated JWT it passes. A failing control means stop, not "the target is broken".
--
-- WHAT THIS ALLOWS, deliberately narrow:
--   * INSERT only. No UPDATE and no DELETE policy is added; a staff user still cannot
--     mutate or remove a photos row. Removing an image from a visit is a SOFT DELETE of
--     the LINK via public.soft_delete_photo_link (2026-08-14_0500), which leaves the
--     photo row and its storage object untouched and keeps the classification.
--   * source must be 'admin_review_upload'. 🛑 THIS IS LOAD-BEARING, NOT COSMETIC.
--     sync_jobber_note_photos.js only ever unlinks photos whose source is one of
--     jobber_migration / jobber_late_recovery / jobber_note_sync. An upload that reused a
--     Jobber source could be unlinked by that job, taking its classification with it.
--     The CHECK makes that impossible rather than relying on the app to pass the right
--     string.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.photos has no audit trigger and this does
-- not add one. The meaningful audit surface for this feature is public.photo_links, which
-- got its first-ever trigger in 2026-08-14_0500, and every uploaded photo must be linked
-- to a visit to be visible at all. Documented here rather than silently skipped.
-- ============================================================================

do $do$
declare v_ins int; v_rls boolean;
begin
  select count(*) into v_ins from pg_policy p join pg_class c on c.oid=p.polrelid
   where c.relname='photos' and p.polcmd='a'
     and 'authenticated' = any (select r.rolname from pg_roles r where r.oid = any(p.polroles));
  if v_ins <> 0 then
    raise exception 'public.photos already has % INSERT policy/policies for authenticated', v_ins;
  end if;
  select relrowsecurity into v_rls from pg_class where oid = 'public.photos'::regclass;
  if not v_rls then raise exception 'RLS is OFF on public.photos -- a policy would be pointless'; end if;
end
$do$;

create policy "Authenticated insert app-uploaded photos"
  on public.photos for insert to authenticated
  with check (
    (select auth.uid()) is not null
    and source = 'admin_review_upload'
  );

do $do$
declare v_ok boolean; v_denied boolean; v_ctl boolean;
begin
  -- (a) a signed-in user can now insert an app-sourced photo
  begin
    perform set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
    set local role authenticated;
    insert into public.photos (storage_path, file_name, content_type, source)
      values ('probe/policy-check.jpg','policy-check.jpg','image/jpeg','admin_review_upload');
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  if not v_ok then raise exception 'authenticated still cannot insert an admin_review_upload photo'; end if;

  -- (b) NEGATIVE CONTROL. The source CHECK must actually bite, or the policy is
  -- decoration and an upload could masquerade as Jobber-sourced and be unlinked by the sync.
  begin
    perform set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
    set local role authenticated;
    insert into public.photos (storage_path, file_name, content_type, source)
      values ('probe/policy-check-2.jpg','x.jpg','image/jpeg','jobber_note_sync');
    v_denied := false;
  exception when others then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'authenticated inserted a jobber_note_sync photo -- the source CHECK does not bite';
  end if;

  -- (c) CONTROL: anon must still be refused outright
  begin
    set local role anon;
    insert into public.photos (storage_path, file_name, content_type, source)
      values ('probe/anon.jpg','a.jpg','image/jpeg','admin_review_upload');
    v_ctl := false;
  exception when others then v_ctl := true;
  end;
  reset role;
  if not v_ctl then raise exception 'anon can insert into public.photos'; end if;

  -- ⚠ clean up the probe row EXPLICITLY. An earlier draft ended this block with
  -- `raise exception 'PROBE_ROLLBACK_OK'` to discard it, which would have rolled back
  -- the CREATE POLICY above with it and shipped nothing while reporting success.
  delete from public.photos where storage_path in ('probe/policy-check.jpg','probe/policy-check-2.jpg','probe/anon.jpg');

  raise notice 'photos INSERT allowed for authenticated, restricted to admin_review_upload; anon refused';
end
$do$;

-- final state, asserted after the probe cleanup
do $do$
declare v_left int; v_pol int;
begin
  select count(*) into v_left from public.photos where storage_path like 'probe/%';
  if v_left <> 0 then raise exception '% probe photo rows survived the cleanup', v_left; end if;
  select count(*) into v_pol from pg_policy p join pg_class c on c.oid=p.polrelid
   where c.relname='photos' and p.polcmd='a';
  if v_pol <> 1 then raise exception 'expected exactly 1 INSERT policy on photos, found %', v_pol; end if;
  raise notice 'policy in place, no probe rows left behind';
end
$do$;
