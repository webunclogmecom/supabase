-- 2026-10-21_0830 ET · Access switch-on 4 of 6: DERM Tracker goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1). From now on a person below Edit in DERM Tracker is
-- refused its changing functions and its edge actions (send, print, manual GDO filing, address PDF); below View, the
-- visit report and the email preview. Who has what is set in the HR App (Yannick decides).
--
-- Shipped before this, the same morning: F1a/F1b (send-derm-email checks preview at View and send at Edit, v67+),
-- print (generate_derm_address_preview) raised to Edit (2026-10-21_0700), F2 (the refusal sentence reaches the app),
-- F5 (generate-fog-manifest server key only).
-- Side door closed here: public.fn_requeue_derm_portal could be called by any signed-in user with no check. Measured:
-- no app calls it, no REST role ever has (pg_stat_statements), no function or edge function calls it. It is an
-- operator tool: closed to signed-in users, service_role keeps it.
-- The table grant revokes (manifest_visits, derm_manifests, visits.derm_required) are a later, separate migration,
-- after a real filing on the new functions (plan step 4).
-- Undo: docs/runbooks/access-undo.md.

BEGIN;

revoke execute on function public.fn_requeue_derm_portal(bigint, bigint, text, text) from public, anon, authenticated;

update hr.access_apps set mode = 'on', on_since = now() where app = 'derm_tracker' and mode = 'watch';

do $verify$
declare v_state text; v_det text; v_ca text;
  jonv text := '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}';
begin
  if (select mode from hr.access_apps where app = 'derm_tracker') <> 'on' then raise exception 'VERIFY: derm_tracker is not on'; end if;
  if has_function_privilege('authenticated', 'public.fn_requeue_derm_portal(bigint,bigint,text,text)', 'EXECUTE') then
    raise exception 'VERIFY: fn_requeue_derm_portal still executable by authenticated'; end if;
  foreach v_ca in array array[jonv,
      '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}',
      '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}'] loop
    perform set_config('request.jwt.claims', v_ca, true);
    perform set_config('role', 'authenticated', true);
    begin perform public.derm_unlink_visit(-1, -1); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=derm_tracker %') then
      raise exception 'VERIFY: jon.v not refused derm_unlink_visit (% %)', v_state, v_det; end if;
    if v_ca <> jonv and coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused (%)', v_det; end if;
    perform set_config('role', 'authenticated', true);
    begin perform hr.check_app_action('send_derm_email'); v_state := 'ok'; v_det := '';
    exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
    perform set_config('role', 'postgres', true);
    if v_ca = jonv and not (v_state = '42501' and v_det like 'blocker=no_access app=derm_tracker %') then
      raise exception 'VERIFY: jon.v not refused send_derm_email (% %)', v_state, v_det; end if;
    if v_ca <> jonv and v_state <> 'ok' then raise exception 'VERIFY: staff refused send_derm_email (% %)', v_state, v_det; end if;
  end loop;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
