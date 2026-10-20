-- 2026-10-20_1430 · Access phase 2: Admin Review's edge functions check access as the caller
--
-- Part of "Now start Admin Review phase 2" (Fred, 2026-10-20). send-visit-photos-email, rotate-photo and
-- visit-client-note-photos are called only by Admin Review (read off every live bundle). Each now calls
-- hr.check_app_action(<action>) WITH THE CALLER'S TOKEN before doing anything, through _shared/access-check.ts.
-- The function accepts only a fixed list of actions (so it cannot be used to fill the watch log) and maps each to
-- (app, level): sending the report email and rotating a photo need Edit in Admin Review; reading the Jobber note photos
-- needs View. It calls hr.fn_check_app, so: off passes, watch passes and logs, on refuses with the plain sentence.
-- Rule 8: no table. Rollback: DROP FUNCTION hr.check_app_action(text); (redeploy the three functions without the helper first).
BEGIN;

CREATE FUNCTION hr.check_app_action(p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_app text; v_level text;
begin
  select a.app, a.lvl into v_app, v_level
    from (values ('send_visit_photos_email', 'admin_review', 'edit'),
                 ('rotate_photo',            'admin_review', 'edit'),
                 ('visit_client_note_photos','admin_review', 'view')) a(action, app, lvl)
   where a.action = p_action;
  if v_app is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  perform hr.fn_check_app(v_app, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$;

REVOKE ALL ON FUNCTION hr.check_app_action(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.check_app_action(text) TO authenticated, service_role;

DO $v$ DECLARE c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  c_nobody text := json_build_object('sub', gen_random_uuid(), 'email','nobody@unclogme.com','role','authenticated')::text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    PERFORM hr.check_app_action('send_visit_photos_email');
    IF EXISTS (SELECT 1 FROM hr.access_refusals WHERE what = 'send visit photos email') THEN RAISE EXCEPTION 'V1 office logged'; END IF;
    BEGIN PERFORM hr.check_app_action('anything else'); RAISE EXCEPTION 'V2 unknown accepted';
    EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
    PERFORM set_config('request.jwt.claims', c_nobody, true);
    PERFORM hr.check_app_action('rotate_photo');
    IF NOT EXISTS (SELECT 1 FROM hr.access_refusals WHERE what = 'rotate photo') THEN RAISE EXCEPTION 'V3 not logged'; END IF;
    RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
  IF has_function_privilege('anon', 'hr.check_app_action(text)', 'EXECUTE') THEN RAISE EXCEPTION 'V4 anon'; END IF;
END $v$;
COMMIT;
