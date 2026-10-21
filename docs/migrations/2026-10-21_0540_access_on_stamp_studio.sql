-- 2026-10-21_0540 ET · Access switch-on 1 of 6: Stamp Studio goes from watch to ON
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, order D1: Stamp Studio first). From now on a person below Edit in
-- Stamp Studio is refused its 11 changing functions (hr.fn_check_app('stamp_studio','edit',...), first statement of
-- each, since 2026-10-20_1700). Who has what is set in the HR App (Yannick decides).
--
-- Side doors closed with it (plan "Side doors each app closes", D6): three SECURITY DEFINER functions that a
-- signed-in browser could call with no access check. Measured before writing this: no live bundle calls any of them
-- (fresh walk of all 8 staff apps), pg_stat_statements holds no call from a REST role, and their internal callers
-- (derm.add_client_card_and_link, derm.fn_complete_generated_sheet, derm.trg_resolve_generated_on_manifest) are
-- SECURITY DEFINER owned by postgres, so they keep working.
--   derm.file_manifest_and_link(bigint,bigint), derm.set_row_reviewed(bigint,boolean),
--   derm.fn_resolve_generated_sheet_for_ticket(text) and its public twin.
--
-- Checked before: scripts/checks/access-switch-on.mjs stamp_studio (rolled back, this app on): 13 called
-- functions, every one refuses jon.v and Aaron-None by Stamp's own check and lets Fred and Diego through; the
-- control copy without its check lets jon.v through (instrument proven).
-- Undo: docs/runbooks/access-undo.md (section 1 and the Stamp re-grants).

BEGIN;

revoke execute on function derm.file_manifest_and_link(bigint, bigint) from public, anon, authenticated;
revoke execute on function derm.set_row_reviewed(bigint, boolean) from public, anon, authenticated;
revoke execute on function derm.fn_resolve_generated_sheet_for_ticket(text) from public, anon, authenticated;
revoke execute on function public.fn_resolve_generated_sheet_for_ticket(text) from public, anon, authenticated;

update hr.access_apps set mode = 'on', on_since = now() where app = 'stamp_studio' and mode = 'watch';

do $verify$
declare v_state text; v_det text; n int;
begin
  select count(*) into n from hr.access_apps where app = 'stamp_studio' and mode = 'on' and on_since is not null;
  if n <> 1 then raise exception 'VERIFY: stamp_studio is not on'; end if;
  if has_function_privilege('authenticated', 'derm.file_manifest_and_link(bigint,bigint)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.set_row_reviewed(bigint,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.fn_resolve_generated_sheet_for_ticket(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_resolve_generated_sheet_for_ticket(text)', 'EXECUTE') then
    raise exception 'VERIFY: a side door is still executable by authenticated';
  end if;
  if not has_function_privilege('service_role', 'derm.set_row_reviewed(bigint,boolean)', 'EXECUTE') then
    raise exception 'VERIFY: service_role lost a side door';
  end if;
  -- negative: jon.v (no employee row) is refused by Stamp's check
  perform set_config('request.jwt.claims', '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}', true);
  perform set_config('role', 'authenticated', true);
  begin
    perform derm.clear_stamp_position(-1);
    v_state := 'ok';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail;
  end;
  perform set_config('role', 'postgres', true);
  if v_state <> '42501' or v_det not like 'blocker=no_access app=stamp_studio %' then
    raise exception 'VERIFY: jon.v not refused by stamp_studio (% %)', v_state, v_det;
  end if;
  -- positive: Fred (admin) and Diego (office) pass the access check (the dummy card then fails on its own)
  foreach v_det in array array['{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}',
                               '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}'] loop
    perform set_config('request.jwt.claims', v_det, true);
    perform set_config('role', 'authenticated', true);
    begin
      perform derm.clear_stamp_position(-1);
      v_state := 'ok';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail;
    end;
    perform set_config('role', 'postgres', true);
    if coalesce(v_det, '') like 'blocker=no_access%' then raise exception 'VERIFY: staff refused (%)', v_det; end if;
  end loop;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
