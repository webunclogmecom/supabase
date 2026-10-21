-- 2026-10-21 19:10 ET · Access step G5: the shared read gate back on, now that every app is on
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, step A9). G3 turned the gate off at about 19:02 ET
-- (alter role authenticator reset pgrst.db_pre_request) so the last switch-on and the gate are separate steps (D5);
-- the Visit Calendar went on at 19:05:10 (2026-10-21_1900). This puts back the exact statement from
-- 2026-10-21_0145. With every top-level app on, a signed-in person with View in no app is now refused every PostgREST
-- request (403, "You do not have access to any UnclogMe app. Ask Fred or Yannick to change it."), except
-- /rpc/get_my_access. anon and service_role are not affected.
--
-- Checked before (G1, rolled back): Fred, Diego, Yannick, Aaron, Serena pass; jon.v, unclogme@, test.agent refused (all
-- three are also banned, G0c); get_my_access, anon and service_role pass; Fred with x-access-rehearsal: refuse-me
-- refused. G2: a week of signed-in traffic is browsers and our own edge functions only. Lockout guard:
-- authenticated holds USAGE on schema hr and EXECUTE on hr.fn_any_app_open and public.fn_request_gate.
--
-- A role setting is not transactional, so this is not wrapped in BEGIN/COMMIT. It passes only on behaviour: after the
-- NOTIFY, refuse-me from a staff browser returns 403 and a plain request returns 200 (recorded in the HR App switch-on log).
-- Off switch: alter role authenticator reset pgrst.db_pre_request; notify pgrst, 'reload config';
-- (or put any one app back to watch: the gate then passes everyone with no NOTIFY).

alter role authenticator set pgrst.db_pre_request to 'public.fn_request_gate';
notify pgrst, 'reload config';
