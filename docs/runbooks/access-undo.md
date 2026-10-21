# Access switch-on: the undo sheet

For Fred. Paste any block into the Supabase dashboard SQL editor (project `wbasvhvvismukaqdnouk`). The editor runs
as the database owner, so neither the access checks nor the read gate apply to it. Every block takes effect on the
next request; nothing needs a deploy.

Plan: `Building Apps/HR App/docs/specs/2026-10-21-access-switch-on-and-invite-plan.md`. Kept current with each
switch-on (the "Re-grants" section grows as grants are revoked).

## 1. Put one app back to watch (nobody is refused by that app any more)

```sql
update hr.access_apps set mode = 'watch', on_since = null where app = 'stamp_studio';
-- app names: stamp_studio, picture_planner, admin_review, derm_tracker, client_app, visit_calendar
```

Putting any one app back to watch also turns the read gate off for everyone (the gate engages only while every
app is on).

## 2. Put every app back to watch

```sql
update hr.access_apps set mode = 'watch', on_since = null
 where parent is null and app <> 'hr';
```

## 3. Turn the read gate off (a signed-in person with no access can read again)

```sql
alter role authenticator reset pgrst.db_pre_request;
notify pgrst, 'reload config';
```

Turn it back on:

```sql
alter role authenticator set pgrst.db_pre_request to 'public.fn_request_gate';
notify pgrst, 'reload config';
```

## 4. Re-grants (only if a revoke itself broke something)

Each line undoes one revoke made at a switch-on. Added as each revoke ships.

```sql
-- Stamp Studio (2026-10-21): three functions closed to signed-in users
grant execute on function derm.file_manifest_and_link(bigint, bigint) to authenticated;
grant execute on function derm.set_row_reviewed(bigint, boolean) to authenticated;
grant execute on function derm.fn_resolve_generated_sheet_for_ticket(text) to authenticated;
grant execute on function public.fn_resolve_generated_sheet_for_ticket(text) to authenticated;
```

```sql
-- Gate step G0a (2026-10-21_0650): five tables closed to direct writes by signed-in users
grant insert, update, delete on public.dump_sites, public.derm_required_backfill_snapshot_2026_06_24,
  public.visit_locations, public.derm_manifest_number_proposals to authenticated;
grant insert, delete on public.visit_assignments to authenticated;
drop policy if exists visit_locations_auth_select on public.visit_locations;
create policy visit_locations_auth_all on public.visit_locations for all to authenticated using (true) with check (true);
drop policy if exists dmnp_auth_select on public.derm_manifest_number_proposals;
create policy authenticated_write_dmnp on public.derm_manifest_number_proposals for all to authenticated using (true) with check (true);
create policy visit_assignments_anon_delete_authn on public.visit_assignments for delete to authenticated using (true);
create policy visit_assignments_anon_insert_authn on public.visit_assignments for insert to authenticated with check (true);
```

## 5. Storage (gate step only)

The policies as they were before the gate step are saved in `backups/2026-10-21_access_switch_on_snapshot.json`
(key `policies`, schema `storage`). Added here as SQL when that step ships.
