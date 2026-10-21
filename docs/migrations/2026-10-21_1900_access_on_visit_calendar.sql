-- 2026-10-21 (evening) ET · Access switch-on 6 of 6: Visit Calendar goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1, step A9). The last app. It runs OUTSIDE dispatch hours,
-- with the read gate turned off just before (G3) and back on just after (G5, its own migration, run whatever happens
-- here), so the Calendar switch-on and the gate are two separate steps (D5).
-- From now on a person below Edit in the Visit Calendar is refused its changing functions, the zone editor (trigger
-- aa_access_zones) and its edge actions; below View, drive days, grease, previews and the clash check.
--
-- Side doors closed with it (D6): public.skip_visit(bigint,text) and its ops wrapper had no access check. Measured:
-- the Calendar does not call either (its only match is inside "unskip_visit"), no REST role ever has
-- (pg_stat_statements), and the two only call each other. Closed to signed-in users; service_role keeps them.
-- The column grant revoke (ops.calendar_day_markers.dump_visit_id) is a separate step after the live check.
-- Undo: docs/runbooks/access-undo.md.

BEGIN;

revoke execute on function public.skip_visit(bigint, text) from public, anon, authenticated;
revoke execute on function ops.skip_visit(bigint, text) from public, anon, authenticated;

update hr.access_apps set mode = 'on', on_since = now() where app = 'visit_calendar' and mode = 'watch';

do $verify$
declare v_state text; v_det text; v_ca text;
  jonv text := '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}';
begin
  if (select mode from hr.access_apps where app = 'visit_calendar') <> 'on' then raise exception 'VERIFY: visit_calendar is not on'; end if;
  if has_function_privilege('authenticated', 'public.skip_visit(bigint,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.skip_visit(bigint,text)', 'EXECUTE') then
    raise exception 'VERIFY: a skip function is still executable by authenticated'; end if;
  foreach v_ca in array array[jonv,
      '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}',
      '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}'] loop
    perform set_config('request.jwt.claims', v_ca, true);
    perform set_config('role', 'authenticated', true);
    begin perform ops.link_day_marker_dump_visit(-1, null); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=visit_calendar %') then
      raise exception 'VERIFY: jon.v not refused link_day_marker_dump_visit (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused (%)', v_det; end if;
    perform set_config('role', 'authenticated', true);
    begin perform hr.check_app_action('create_client'); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=client_app|visit_calendar %') then
      raise exception 'VERIFY: jon.v not refused create_client (% %)', v_state, v_det; end if;
    if v_ca <> jonv and v_state <> 'ok' then raise exception 'VERIFY: staff refused create_client (% %)', v_state, v_det; end if;
  end loop;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
