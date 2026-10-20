-- 2026-10-21_0915 · Access phase 5 follow-up: the Client App's contact refresh needs View, not Edit
--
-- save-client-contact action "refresh" (mirror Jobber's contacts) runs every time a client page opens. With the
-- save_client_contact action (Edit) a View-only person would be logged in watch and refused at switch-on just for
-- opening a page. hr.check_app_action gains refresh_client_contacts (Client App, View); the function picks it for
-- action "refresh" (deployed with this). Spliced from the live body (md5-pinned). Rule 8: no table.
-- Rollback: put back the body read from 2026-10-21_0900 (its line without this entry), AFTER redeploying
-- save-client-contact without the refresh branch, or every page open fails the check ("Unknown action").
BEGIN;
DO $g$ BEGIN
  if md5(pg_get_functiondef('hr.check_app_action(text)'::regprocedure)) <> 'c777a5f490412a84750ab8923abc99c6' then raise exception 'hr.check_app_action changed since it was read'; end if;
END $g$;
CREATE OR REPLACE FUNCTION hr.check_app_action(p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_apps text[]; v_level text;
begin
  -- 2026-10-21_0900: each action names the app(s) whose level allows it; several apps = allowed in ANY of them
  select a.apps, a.lvl into v_apps, v_level
    from (values ('send_visit_photos_email',      array['admin_review'], 'edit'),
                 ('rotate_photo',                 array['admin_review'], 'edit'),
                 ('visit_client_note_photos',     array['admin_review'], 'view'),
                 ('send_derm_email',              array['derm_tracker'], 'edit'),
                 ('generate_derm_address_pdf',    array['derm_tracker'], 'edit'),
                 ('generate_derm_address_preview',array['derm_tracker'], 'view'),
                 ('record_manual_gdo_report',     array['derm_tracker'], 'edit'),
                 ('derm_visit_report',            array['derm_tracker'], 'view'),
                 ('create_client',                array['client_app','visit_calendar'], 'edit'),
                 ('save_calendar_task',           array['client_app','visit_calendar'], 'edit'),
                 ('save_client_job',              array['client_app'], 'edit'),
                 ('save_client_property',         array['client_app'], 'edit'),
                 ('save_client_contact',          array['client_app'], 'edit'),
                 ('refresh_client_contacts',      array['client_app'], 'view'),   -- 2026-10-21_0915: runs on every client page open
                 ('archive_client',               array['client_app'], 'edit'),
                 ('unarchive_client',             array['client_app'], 'edit'),
                 ('save_client_fields',           array['client_app'], 'edit'),
                 ('parse_gdo_permit',             array['client_app'], 'edit'),
                 ('save_day_marker',              array['visit_calendar'], 'edit'),
                 ('adopt_visit_from_jobber',      array['visit_calendar'], 'edit'),
                 ('push_visit_to_jobber',         array['visit_calendar'], 'edit'),
                 ('save_calendar_visit',          array['visit_calendar'], 'edit'),
                 ('calculate_driving_time',       array['visit_calendar'], 'view')) a(action, apps, lvl)
   where a.action = p_action;
  if v_apps is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  perform hr.fn_check_any_app(v_apps, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$;

DO $v$ DECLARE c text := json_build_object('sub','8bdb9ba7-e917-466d-bdb1-c525dbf90194','email','jon.v@ayache.com','role','authenticated')::text; n int;
BEGIN
  BEGIN
    perform set_config('request.jwt.claims', c, true);
    perform hr.check_app_action('refresh_client_contacts');   -- watch: jon (no employee) is below View, so one row is logged
    select count(*) into n from hr.access_refusals where email = 'jon.v@ayache.com' and what = 'refresh client contacts' and needs = 'view';
    if n <> 1 then raise exception 'V1 expected one view row for jon, got %', n; end if;
    perform set_config('request.jwt.claims', json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text, true);
    perform hr.check_app_action('refresh_client_contacts');
    select count(*) into n from hr.access_refusals where email = 'aaron@unclogme.com';
    if n <> 0 then raise exception 'V2 aaron logged'; end if;
    raise exception 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
END $v$;
COMMIT;
