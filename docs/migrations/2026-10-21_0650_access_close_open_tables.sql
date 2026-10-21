-- 2026-10-21_0650 ET · Access switch-on, gate step G0a: five tables a signed-in user could write directly
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, A9 G0a). These five had a write grant for `authenticated` AND an
-- open write policy (or no RLS) and no access trigger, so any signed-in user could change them through PostgREST
-- whatever the HR App says:
--   public.dump_sites                                  (no RLS)
--   public.derm_required_backfill_snapshot_2026_06_24  (no RLS; a June backfill snapshot)
--   public.visit_locations                             (policy visit_locations_auth_all, every command)
--   public.visit_assignments                           (insert + delete policies)
--   public.derm_manifest_number_proposals              (three write policies)
-- Measured before closing:
--   * gateway logs, 7 days to 2026-10-21: 0 browser writes to any of them (85 visit_assignments POSTs, all from our
--     edge functions with the server key);
--   * audit.logs, 30 days: every app write to visit_locations and visit_assignments went through a SECURITY DEFINER
--     function (create_calendar_visit, edit_calendar_visit_verified, create_dump_visit, generate_visits_for_client,
--     fn_jobber_resolve_visit); the rest are the server (sql, jobber). dump_sites and the proposals table: none.
-- So: revoke INSERT/UPDATE/DELETE from authenticated (and anon), and narrow the policies the same way: the two
-- every-command policies are recreated as SELECT-only (same USING), the insert/update/delete ones are dropped.
-- Reads are unchanged. Done now rather than at the evening gate step because nothing depends on the app modes.
-- Old policy text: backups/2026-10-21_access_switch_on_snapshot.json; re-create lines in docs/runbooks/access-undo.md.

BEGIN;
SET LOCAL lock_timeout = '3s';

revoke insert, update, delete on public.dump_sites, public.derm_required_backfill_snapshot_2026_06_24,
  public.visit_locations, public.visit_assignments, public.derm_manifest_number_proposals from authenticated, anon;

drop policy visit_locations_auth_all on public.visit_locations;
create policy visit_locations_auth_select on public.visit_locations for select to authenticated using (true);

drop policy authenticated_write_dmnp on public.derm_manifest_number_proposals;
drop policy anon_insert_dmnp_authn on public.derm_manifest_number_proposals;
drop policy anon_update_dmnp_authn on public.derm_manifest_number_proposals;
create policy dmnp_auth_select on public.derm_manifest_number_proposals for select to authenticated using (true);

drop policy visit_assignments_anon_delete_authn on public.visit_assignments;
drop policy visit_assignments_anon_insert_authn on public.visit_assignments;

do $verify$
declare t text;
begin
  foreach t in array array['public.dump_sites','public.derm_required_backfill_snapshot_2026_06_24','public.visit_locations',
                           'public.visit_assignments','public.derm_manifest_number_proposals'] loop
    if has_table_privilege('authenticated', t, 'INSERT') or has_table_privilege('authenticated', t, 'UPDATE')
       or has_table_privilege('authenticated', t, 'DELETE') then raise exception 'VERIFY: % still writable by authenticated', t; end if;
    if not has_table_privilege('service_role', t, 'INSERT') then raise exception 'VERIFY: service_role lost % ', t; end if;
  end loop;
  if exists (select 1 from pg_policy p where p.polrelid in ('public.visit_locations'::regclass, 'public.derm_manifest_number_proposals'::regclass, 'public.visit_assignments'::regclass)
              and 'authenticated'::regrole = any (p.polroles) and p.polcmd::text <> 'r') then
    raise exception 'VERIFY: a write policy for authenticated is left'; end if;
  -- reads still work as a signed-in staff user
  perform set_config('request.jwt.claims', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}', true);
  perform set_config('role', 'authenticated', true);
  perform count(*) from public.visit_locations;
  perform count(*) from public.derm_manifest_number_proposals;
  perform set_config('role', 'postgres', true);
  -- a direct write as a signed-in user is now refused (rolled back either way)
  begin
    perform set_config('role', 'authenticated', true);
    delete from public.visit_locations where visit_id = -1;
    perform set_config('role', 'postgres', true);
    raise exception 'VERIFY: direct delete on visit_locations still allowed';
  exception when insufficient_privilege then perform set_config('role', 'postgres', true);
  end;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
