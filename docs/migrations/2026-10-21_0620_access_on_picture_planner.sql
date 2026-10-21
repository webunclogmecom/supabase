-- 2026-10-21_0620 ET · Access switch-on 2 of 6: Picture Planner goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1). From now on a person below View in Picture Planner is
-- refused its 7 readers and the forms list, and a person below Edit its 6 changing functions (checks since
-- 2026-10-20_1600). cancel_intake stays allowed through the Client App until the Client App is on (shared action).
--
-- Side door closed with it (plan "Side doors each app closes", D6): client.update_property_capacity and
-- client.update_property_operational were allowed with Edit in EITHER the Client App or Picture Planner
-- (2026-10-21_0900), only because accept_intake_answers (the Planner's Property record tab) calls them. So Picture
-- Planner Edit alone could change a lock box or the gallons by calling them directly. Now:
--   * called directly          -> Client App Edit (the Client App property dialog is their only direct caller);
--   * reached through accept   -> Picture Planner Edit; accept_intake_answers sets the transaction-local marker
--     unclogme.intake_accept = 'on' around its two calls (and already checks Planner Edit and the page approver).
--   A PostgREST client cannot set that marker: it sets only request.* settings, and nothing else writes it.
-- Bodies spliced from the live definitions, md5 pinned; only the marked lines change.
--
-- Checked before: scripts/checks/access-switch-on.mjs picture_planner (rolled back, this app on): 14 called
-- functions; every reader refuses jon.v and Aaron-None and lets Aaron-View through; every changing function refuses
-- Aaron-View with needs=edit; cancel_intake pending (Client App still in watch); the control copy without its check
-- lets jon.v through.
-- Undo: docs/runbooks/access-undo.md section 1; the splice is undone by re-running 2026-10-21_0900's bodies.

BEGIN;

do $splice$
declare v_def text; v_new text; v_sig text; v_md5 text; v_old text; v_rep text;
begin
  for v_sig, v_md5, v_old, v_rep in select * from (values
    ('client.update_property_capacity(bigint,integer)', 'c57a1732a26c8ecb6288ed55085cb840',
     $o$  perform hr.fn_check_any_app(array['client_app', 'picture_planner'], 'edit', 'edit property capacity');   -- 2026-10-21_0900 access phase 5$o$,
     $n$  if coalesce(current_setting('unclogme.intake_accept', true), '') = 'on' then   -- 2026-10-21_0620: reached through accept_intake_answers
    perform hr.fn_check_app('picture_planner', 'edit', 'edit property capacity');
  else
    perform hr.fn_check_app('client_app', 'edit', 'edit property capacity');
  end if;$n$),
    ('client.update_property_operational(bigint,jsonb)', '43f387305a6163562c2f32d1a1768a34',
     $o$  perform hr.fn_check_any_app(array['client_app', 'picture_planner'], 'edit', 'edit property details');   -- 2026-10-21_0900 access phase 5$o$,
     $n$  if coalesce(current_setting('unclogme.intake_accept', true), '') = 'on' then   -- 2026-10-21_0620: reached through accept_intake_answers
    perform hr.fn_check_app('picture_planner', 'edit', 'edit property details');
  else
    perform hr.fn_check_app('client_app', 'edit', 'edit property details');
  end if;$n$),
    ('client.accept_intake_answers(bigint,text[],jsonb)', '32eabcbb13a39419e32a8177af04fd1f',
     $o$perform client.update_property_operational(v_i.property_id, v_patch);$o$,
     $n$perform set_config('unclogme.intake_accept', 'on', true); perform client.update_property_operational(v_i.property_id, v_patch); perform set_config('unclogme.intake_accept', '', true);$n$)
  ) x(sig, md5, old, rep)
  loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if md5(v_def) <> v_md5 then raise exception '% changed since the plan; re-splice from the live body', v_sig; end if;
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once in %', v_sig; end if;
    v_new := replace(v_def, v_old, v_rep);
    if v_sig like 'client.accept_intake_answers%' then
      v_old := 'perform client.update_property_capacity(v_i.property_id, v_gallons);';
      if (length(v_new) - length(replace(v_new, v_old, ''))) / length(v_old) <> 1 then raise exception 'capacity anchor not found once'; end if;
      v_new := replace(v_new, v_old, 'perform set_config(''unclogme.intake_accept'', ''on'', true); ' || v_old || ' perform set_config(''unclogme.intake_accept'', '''', true);');
    end if;
    execute v_new;
  end loop;
end $splice$;

update hr.access_apps set mode = 'on', on_since = now() where app = 'picture_planner' and mode = 'watch';

do $verify$
declare v_state text; v_det text; n int; v_ca text;
  fred text := '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}';
  diego text := '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}';
  jonv text := '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}';
  aaron text := '{"sub":"77d4c343-1e21-44eb-98ce-c221028d028a","role":"authenticated","email":"aaron@unclogme.com"}';
begin
  select count(*) into n from hr.access_apps where app = 'picture_planner' and mode = 'on' and on_since is not null;
  if n <> 1 then raise exception 'VERIFY: picture_planner is not on'; end if;

  -- 1. jon.v refused a reader and a writer by Picture Planner's check; Fred and Diego pass both
  foreach v_ca in array array[jonv, fred, diego] loop
    perform set_config('request.jwt.claims', v_ca, true);
    perform set_config('role', 'authenticated', true);
    begin perform client.page_builder_list(); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=picture_planner %') then
      raise exception 'VERIFY: jon.v not refused page_builder_list (% %)', v_state, v_det; end if;
    if v_ca <> jonv and v_state <> 'ok' then raise exception 'VERIFY: staff refused page_builder_list (% %)', v_state, v_det; end if;
    perform set_config('role', 'authenticated', true);
    begin perform client.rotate_driver_link(-1); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=picture_planner %') then
      raise exception 'VERIFY: jon.v not refused rotate_driver_link (% %)', v_state, v_det; end if;
    if v_ca <> jonv and v_det like 'blocker=no_access%' then raise exception 'VERIFY: staff refused rotate_driver_link (%)', v_det; end if;
  end loop;

  -- 2. the side door: Aaron with Picture Planner Edit and Client App None, both apps on.
  --    Run inside a block that always ends in a marker exception, so its setup leaves no row and no audit line.
  begin
  update hr.access_apps set mode = 'on', on_since = coalesce(on_since, now()) where app = 'client_app';
  delete from hr.access_overrides where employee_id = 26 and app in ('client_app', 'picture_planner');
  insert into hr.access_overrides (employee_id, app, level, set_by_email) values (26, 'client_app', 'none', 'verify 0620');
  perform set_config('request.jwt.claims', aaron, true);
  perform set_config('role', 'authenticated', true);
  begin perform client.update_property_capacity(-1, 100); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  if not (v_state = '42501' and v_det like 'blocker=no_access app=client_app %') then
    raise exception 'VERIFY: direct capacity call not refused for Planner-only Edit (% %)', v_state, v_det; end if;
  perform set_config('role', 'authenticated', true);
  begin perform client.update_property_operational(-1, '{}'::jsonb); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  if not (v_state = '42501' and v_det like 'blocker=no_access app=client_app %') then
    raise exception 'VERIFY: direct operational call not refused for Planner-only Edit (% %)', v_state, v_det; end if;
  -- through accept (the marker): the Planner's check decides, so Aaron passes the access check
  perform set_config('unclogme.intake_accept', 'on', true);
  perform set_config('role', 'authenticated', true);
  begin perform client.update_property_capacity(-1, 100); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  perform set_config('unclogme.intake_accept', '', true);
  if coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: marked accept path refused (%)', v_det; end if;
  -- and accept_intake_answers itself still sets the marker around both calls
  if (select count(*) from regexp_matches(pg_get_functiondef('client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure), 'unclogme[.]intake_accept', 'g')) <> 4 then
    raise exception 'VERIFY: accept_intake_answers does not set the marker around both calls';
  end if;
    raise exception 'undo_marker_0620';
  exception when others then
    if sqlerrm <> 'undo_marker_0620' then raise; end if;
  end;
  if (select mode from hr.access_apps where app = 'client_app') <> 'watch' then raise exception 'VERIFY: client_app setup leaked'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
