-- 2026-10-21_0640 ET · Access switch-on, cross-app fix: creating a client from the Calendar (database half)
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, D6 "the two cross-app refusals").
-- create-client (allowed with Client App OR Visit Calendar Edit) and save-client-property make the client's Service
-- Call job by calling save-client-job with the person's own token, and save-client-job checks 'save_client_job'
-- (Client App only). So once the Client App is on, someone with Calendar Edit alone would create the client and then
-- be refused its Service Call job. New action 'create_service_call_job' (Client App OR Visit Calendar, Edit):
-- save-client-job uses it for action "create" with patch.kind "SC" only; every other job action keeps
-- 'save_client_job'. It must exist BEFORE the edge code (an unknown action is a 503 for everyone).
-- Body spliced from the live definition, md5 pinned; one line added.

BEGIN;

do $splice$
declare v_def text := pg_get_functiondef('hr.check_app_action(text)'::regprocedure);
  v_old text := $a$                 ('save_client_job',              array['client_app'], 'edit'),$a$;
begin
  if md5(v_def) <> '48473134cb867e0a35823312b22050c5' then raise exception 'hr.check_app_action changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(v_def, v_old, v_old || E'\n                 (''create_service_call_job'',      array[''client_app'',''visit_calendar''], ''edit''),   -- 2026-10-21_0640 (D6)');
end $splice$;

do $verify$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}', true);
  perform set_config('role', 'authenticated', true);
  v := hr.check_app_action('create_service_call_job');
  perform set_config('role', 'postgres', true);
  if v ->> 'ok' <> 'true' then raise exception 'VERIFY: create_service_call_job not ok for Diego'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
