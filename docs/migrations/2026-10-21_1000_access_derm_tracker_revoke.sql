-- 2026-10-21 ET · Access switch-on 4 of 6, step 4: DERM Tracker's old direct write grants go
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, A2 to A7 step 4, DERM row). Since 2026-10-20_1700 the DERM Tracker
-- links, unlinks, deletes and saves sheet photos through checked SECURITY DEFINER functions (derm_link_visits,
-- derm_unlink_visit, derm_delete_manifests, derm_set_manifest_photos), so these direct grants only let a signed-in user
-- skip the access check:
--   INSERT, DELETE on public.manifest_visits      + policies anon_insert_manifest_visits_authn, anon_delete_manifest_visits_authn
--   INSERT, UPDATE on public.derm_manifests       + policies anon_insert_derm_manifests_authn, anon_update_derm_manifests_authn
--   UPDATE(gdo_id) on public.derm_manifests
--   UPDATE(derm_required) on public.visits
-- After this and Admin Review's revoke, `authenticated` holds no UPDATE on any column of public.visits, so its three
-- update policies (visits_calendar_update, visits_authenticated_update_derm_required, visits_app_update_authn) can no
-- longer apply to anything; they are dropped so a policy is never the only thing left if a grant comes back.
--
-- 🛑 APPLY ONLY AFTER (plan, DERM row): Diego and Serena have reloaded DERM; the gateway logs show at least one 200 on
-- /rpc/derm_set_manifest_photos and one on /rpc/derm_link_visits; and 0 direct browser writes to these tables in the
-- previous 24 hours. Until then a tab opened before the 2026-10-20 publish would file a manifest with no photos.
-- Re-grant lines: docs/runbooks/access-undo.md.

BEGIN;
SET LOCAL lock_timeout = '3s';

revoke insert, delete on public.manifest_visits from authenticated;
drop policy anon_insert_manifest_visits_authn on public.manifest_visits;
drop policy anon_delete_manifest_visits_authn on public.manifest_visits;

revoke insert, update on public.derm_manifests from authenticated;
revoke update (gdo_id) on public.derm_manifests from authenticated;
drop policy anon_insert_derm_manifests_authn on public.derm_manifests;
drop policy anon_update_derm_manifests_authn on public.derm_manifests;

revoke update (derm_required) on public.visits from authenticated;
drop policy visits_calendar_update on public.visits;
drop policy visits_authenticated_update_derm_required on public.visits;
drop policy visits_app_update_authn on public.visits;

do $verify$
declare n int;
begin
  if has_table_privilege('authenticated', 'public.manifest_visits', 'INSERT') or has_table_privilege('authenticated', 'public.manifest_visits', 'DELETE')
     or has_table_privilege('authenticated', 'public.derm_manifests', 'INSERT') or has_table_privilege('authenticated', 'public.derm_manifests', 'UPDATE')
     or has_column_privilege('authenticated', 'public.derm_manifests', 'gdo_id', 'UPDATE')
     or has_column_privilege('authenticated', 'public.visits', 'derm_required', 'UPDATE') then
    raise exception 'VERIFY: a revoked grant is still there';
  end if;
  select count(*) into n from pg_attribute a where a.attrelid = 'public.visits'::regclass and a.attnum > 0
     and has_column_privilege('authenticated', 'public.visits', a.attname, 'UPDATE');
  if n > 0 then raise exception 'VERIFY: authenticated still updates % columns of visits', n; end if;
  -- the checked path still works for staff: derm_unlink_visit passes the access check (dummy ids then fail on their own)
  perform set_config('request.jwt.claims', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}', true);
  perform set_config('role', 'authenticated', true);
  begin perform public.derm_unlink_visit(-1, -1);
  exception when insufficient_privilege then perform set_config('role', 'postgres', true); raise exception 'VERIFY: staff refused the checked path';
            when others then null; end;
  perform set_config('role', 'postgres', true);
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
