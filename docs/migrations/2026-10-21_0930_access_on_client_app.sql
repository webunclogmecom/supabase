-- 2026-10-21_0930 ET · Access switch-on 5 of 6: Client App goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1). From now on a person below Edit in the Client App is
-- refused its changing functions and edge actions; below View, the activity, previews and the contact refresh.
-- Cancel form and the two property functions become fully checked now that both their apps are on.
--
-- Cross-app fix shipped with it (D6): the client Activity reader (client.get_client_activity, Client App View) calls
-- client.get_property_activity, which required Picture Planner View, so a person with Client App View and no Picture
-- Planner access was refused their own Activity dialog (measured: 42501 app=picture_planner, both apps on, rolled
-- back). get_property_activity now accepts View in either app: it is the same intake and Site file history the Client
-- App already shows in Activity. Done in THIS transaction on purpose: an either-app check passes everyone while one of
-- its apps is in watch, so making it earlier would have loosened Picture Planner, which is on since 06:17.
-- The other cross-app case (a client created from the Calendar) shipped earlier: 2026-10-21_0640 + save-client-job v47.
-- Body spliced from the live definition, md5 pinned; one line changes.
-- Undo: docs/runbooks/access-undo.md.

BEGIN;

do $splice$
declare v_def text := pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure);
  v_old text := $o$  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3$o$;
begin
  if md5(v_def) <> '3a4b2b632b2baae60630316776dd8a4e' then raise exception 'client.get_property_activity changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(v_def, v_old, $n$  perform hr.fn_require_any_app(array['picture_planner', 'client_app'], 'view');   -- 2026-10-21_0930 (D6): the Client App Activity reads it too$n$);
end $splice$;

update hr.access_apps set mode = 'on', on_since = now() where app = 'client_app' and mode = 'watch';

do $verify$
declare v_state text; v_det text; v_ca text;
  jonv text := '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}';
  aaron text := '{"sub":"77d4c343-1e21-44eb-98ce-c221028d028a","role":"authenticated","email":"aaron@unclogme.com"}';
begin
  if (select mode from hr.access_apps where app = 'client_app') <> 'on' then raise exception 'VERIFY: client_app is not on'; end if;
  -- jon.v refused, Fred and Diego pass (a changing function and a shared one)
  foreach v_ca in array array[jonv,
      '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}',
      '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}'] loop
    perform set_config('request.jwt.claims', v_ca, true);
    perform set_config('role', 'authenticated', true);
    begin perform client.update_client_zone(-1, null); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=client_app %') then
      raise exception 'VERIFY: jon.v not refused update_client_zone (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused (%)', v_det; end if;
    perform set_config('role', 'authenticated', true);
    begin perform client.cancel_intake(-1); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=picture_planner|client_app %') then
      raise exception 'VERIFY: jon.v not refused cancel_intake (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused cancel_intake (%)', v_det; end if;
  end loop;
  -- the mixed case: Aaron with Client App View and Picture Planner None reads Activity (undone by the marker)
  begin
    insert into hr.access_overrides (employee_id, app, level, set_by_email)
    values (26, 'client_app', 'view', 'verify 0930'), (26, 'picture_planner', 'none', 'verify 0930');
    perform set_config('request.jwt.claims', aaron, true);
    perform set_config('role', 'authenticated', true);
    begin perform client.get_client_activity(381, false, 5, null); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_state <> 'ok' then raise exception 'VERIFY: mixed Activity refused (% %)', v_state, v_det; end if;
    -- and with no access in either app, the property history is refused
    update hr.access_overrides set level = 'none' where employee_id = 26 and app = 'client_app' and set_by_email = 'verify 0930';
    perform set_config('role', 'authenticated', true);
    begin perform client.get_property_activity(162); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if not (v_state = '42501' and v_det like 'blocker=no_access app=picture_planner|client_app %') then
      raise exception 'VERIFY: property history not refused with no access (% %)', v_state, v_det; end if;
    raise exception 'undo_marker_0930';
  exception when others then
    perform set_config('role', 'postgres', true);
    if sqlerrm <> 'undo_marker_0930' then raise; end if;
  end;
  if exists (select 1 from hr.access_overrides where set_by_email = 'verify 0930') then raise exception 'VERIFY: setup leaked'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
