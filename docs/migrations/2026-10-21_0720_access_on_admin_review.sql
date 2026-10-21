-- 2026-10-21_0720 ET · Access switch-on 3 of 6: Admin Review goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1; D3 the 60-second access refresh shipped in the app first;
-- D4 Remove photo checked). From now on a person below Edit in Admin Review is refused its changing functions, its
-- four review tables (trigger aa_access_admin_review) and its edge actions; below View, the note photos.
--
-- Fixes and side doors shipped with it (plan F3 and "Side doors each app closes"):
--   * F3: public.soft_delete_photo_link (the app's "Remove photo") had no access check: it now checks Admin Review
--     Edit first. Body spliced from the live definition, md5 pinned.
--   * public.set_visit_manholes(bigint,bigint[]) could be called by any signed-in user with no check. Measured: no
--     live bundle calls it, no REST role ever has (pg_stat_statements), no function calls it. Closed to signed-in
--     users; service_role keeps it.
-- The column and table grant revokes (visits.manhole_count, properties counts, photo_links INSERT) are a separate
-- migration, after the live check (plan step 4).
--
-- Checked before: scripts/checks/access-switch-on.mjs admin_review (rolled back, this app on): every called function
-- refuses jon.v and Aaron-None by Admin Review's check except Remove photo (fixed here); the custom bonus pencil
-- refuses Diego by the Pay rates switch, by design.
-- Undo: docs/runbooks/access-undo.md.

BEGIN;

do $splice$
declare v_def text; v_old text := E'declare v_row public.photo_links;\nbegin\n';
begin
  v_def := pg_get_functiondef('public.soft_delete_photo_link(bigint,text)'::regprocedure);
  if md5(v_def) <> '1fa0b87e4c99f05a8478ffb32702a4cb' then raise exception 'soft_delete_photo_link changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(v_def, v_old, v_old || E'  perform hr.fn_check_app(''admin_review'', ''edit'', ''remove a photo'');   -- 2026-10-21_0720 access switch-on (F3)\n');
end $splice$;

revoke execute on function public.set_visit_manholes(bigint, bigint[]) from public, anon, authenticated;

update hr.access_apps set mode = 'on', on_since = now() where app = 'admin_review' and mode = 'watch';

do $verify$
declare v_state text; v_det text; v_ca text;
  jonv text := '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}';
begin
  if (select mode from hr.access_apps where app = 'admin_review') <> 'on' then raise exception 'VERIFY: admin_review is not on'; end if;
  if has_function_privilege('authenticated', 'public.set_visit_manholes(bigint,bigint[])', 'EXECUTE') then
    raise exception 'VERIFY: set_visit_manholes still executable by authenticated'; end if;
  foreach v_ca in array array[jonv,
      '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}',
      '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}'] loop
    perform set_config('request.jwt.claims', v_ca, true);
    -- F3: Remove photo
    perform set_config('role', 'authenticated', true);
    begin perform public.soft_delete_photo_link(-1, null); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=admin_review %') then
      raise exception 'VERIFY: jon.v not refused soft_delete_photo_link (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused soft_delete_photo_link (%)', v_det; end if;
    -- a function that was already checked
    perform set_config('role', 'authenticated', true);
    begin perform public.review_set_property_counts(-1, null, null, false, false); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=admin_review %') then
      raise exception 'VERIFY: jon.v not refused review_set_property_counts (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused review_set_property_counts (%)', v_det; end if;
  end loop;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
