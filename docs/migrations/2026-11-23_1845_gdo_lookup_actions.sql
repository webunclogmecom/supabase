-- 2026-11-23_1845_gdo_lookup_actions.sql
-- Trello #242 (ebj6IVxa), the GDO lookup. Fred, 2026-11-24 (round 3): "go with D1 and all recommended, build it".
--
-- WHAT: two new action rows in hr.check_app_action, for the new edge function gdo-lookup:
--   gdo_lookup       Client App OR DERM Tracker, View: search Miami-Dade's public permit list, read one permit, see its file
--                    (round 1 default: "Open to whoever can open DERM visits; View is enough"; the site lookup lives in the
--                    Client App's City permits section, so View there is enough too).
--   gdo_lookup_take  Client App, Edit: copy a county permit file into the gdo-permits bucket so a site can carry it (the
--                    same app and level as parse_gdo_permit, which stores a dropped PDF; the save itself stays
--                    client.upsert_gdo_permit with its own Client App Edit check).
-- NOTHING ELSE MOVES. The body is the live pg_get_functiondef (md5 1ae79b161e7cafbffc36a8a91182cd3e, read 2026-11-23
-- 18:40 ET) with the two rows inserted after parse_gdo_permit by one anchored edit. VERIFY proves it: removing the two
-- rows gives back the old md5 exactly.
-- Audit (rule 8): no table changes. Grants: CREATE OR REPLACE keeps the function's ACL (checked in VERIFY).
-- Rollback: 2026-11-23_1845_gdo_lookup_actions_rollback.sql (retire gdo-lookup first, or it answers 503).

begin;
set local lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_functiondef('hr.check_app_action(text)'::regprocedure)) <> '1ae79b161e7cafbffc36a8a91182cd3e' then
    raise exception 'hr.check_app_action changed since this migration was written: rebuild it from the live body';
  end if;
end $guard$;

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
                 ('preview_derm_email',           array['derm_tracker'], 'view'),   -- 2026-10-21_0700 (D2)
                 ('generate_derm_address_pdf',    array['derm_tracker'], 'edit'),
                 ('generate_derm_address_preview',array['derm_tracker'], 'edit'),   -- 2026-10-21_0700: it assigns a printed sheet number (D6)
                 ('record_manual_gdo_report',     array['derm_tracker'], 'edit'),
                 ('lwt_monthly_view',             array['derm_tracker'], 'view'),   -- 2026-11-05_0245: the Monthly Report page
                 ('lwt_monthly_edit',             array['derm_tracker'], 'edit'),   -- 2026-11-05_0245
                 ('derm_visit_report',            array['derm_tracker'], 'view'),
                 ('view_derm_doc',                array['derm_tracker'], 'view'),   -- 2026-10-26_1030: get-derm-doc address / fog sheets
                 ('create_client',                array['client_app','visit_calendar'], 'edit'),
                 ('save_calendar_task',           array['client_app','visit_calendar'], 'edit'),
                 ('save_client_job',              array['client_app'], 'edit'),
                 ('create_service_call_job',      array['client_app','visit_calendar'], 'edit'),   -- 2026-10-21_0640 (D6)
                 ('save_client_property',         array['client_app'], 'edit'),
                 ('save_client_contact',          array['client_app'], 'edit'),
                 ('refresh_client_contacts',      array['client_app'], 'view'),   -- 2026-10-21_0915: runs on every client page open
                 ('archive_client',               array['client_app'], 'edit'),
                 ('unarchive_client',             array['client_app'], 'edit'),
                 ('save_client_fields',           array['client_app'], 'edit'),
                 ('parse_gdo_permit',             array['client_app'], 'edit'),
                 ('gdo_lookup',                   array['client_app','derm_tracker'], 'view'),   -- 2026-11-23_1845 (Trello #242): search the county's permits, read one, see its file
                 ('gdo_lookup_take',              array['client_app'], 'edit'),   -- 2026-11-23_1845: copy a county permit file into gdo-permits to add it to a site
                 ('save_day_marker',              array['visit_calendar'], 'edit'),
                 ('adopt_visit_from_jobber',      array['visit_calendar'], 'edit'),
                 ('push_visit_to_jobber',         array['visit_calendar'], 'edit'),
                 ('save_calendar_visit',          array['visit_calendar'], 'edit'),
                 ('calculate_driving_time',       array['visit_calendar'], 'view')) a(action, apps, lvl)
   where a.action = p_action;
  if v_apps is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  -- 2026-10-26_1030 (Send invite phase 1): an app that is not on lets the action through (off) or logs it (watch) only for a
  -- caller with View or Edit in some top-level app. hr.fn_app_level gives no claims / service_role edit, so they pass.
  if exists (select 1 from hr.access_apps a where a.app = any (v_apps) and a.mode <> 'on')
     and not exists (select 1 from hr.access_apps a where a.parent is null and hr.fn_access_rank(hr.fn_app_level(a.app)) >= 1) then
    raise exception 'You do not have access to do this. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=any needs=' || v_level || ' in hr.check_app_action';
  end if;
  perform hr.fn_check_any_app(v_apps, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$
;

do $verify$
declare d text := pg_get_functiondef('hr.check_app_action(text)'::regprocedure);
begin
  if md5(d) <> 'bb1ad831f470db013be28ee4cff59461' then raise exception 'VERIFY: new body md5 %', md5(d); end if;
  if md5(replace(d, $add$                 ('gdo_lookup',                   array['client_app','derm_tracker'], 'view'),   -- 2026-11-23_1845 (Trello #242): search the county's permits, read one, see its file
                 ('gdo_lookup_take',              array['client_app'], 'edit'),   -- 2026-11-23_1845: copy a county permit file into gdo-permits to add it to a site
$add$, '')) <> '1ae79b161e7cafbffc36a8a91182cd3e' then
    raise exception 'VERIFY: something other than the two rows moved';
  end if;
  -- no claims (this connection) has Edit everywhere: both new actions pass, an unknown one still refuses
  perform hr.check_app_action('gdo_lookup');
  perform hr.check_app_action('gdo_lookup_take');
  begin
    perform hr.check_app_action('gdo_lookup_nope');
    raise exception 'VERIFY: an unknown action passed';
  exception when sqlstate '22023' then null;
  end;
  if has_function_privilege('anon', 'hr.check_app_action(text)', 'EXECUTE') then
    raise exception 'VERIFY: anon can execute';
  end if;
  if not has_function_privilege('authenticated', 'hr.check_app_action(text)', 'EXECUTE') then
    raise exception 'VERIFY: authenticated lost EXECUTE';
  end if;
end $verify$;

commit;
