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

Putting any one app back to watch also relaxes the read gate, the Storage gate and the edge checks, but since
`2026-10-26_1030` only for people with View or Edit in at least one app. A sign-in with no access anywhere (for example
an invited driver) stays refused whatever the modes, so this switch is safe once invites exist.
🛑 **Never use an app's mode as the invite switch.** Invites have their own switch (section 6).

## 2. Put every app back to watch

```sql
update hr.access_apps set mode = 'watch', on_since = null
 where parent is null and app <> 'hr';
```

## 3. Turn the read gate off (a signed-in person with no access can read again)

🛑 **Since invites (2026-10-26), a sign-in can exist that is not staff.** With the gate off, EVERY sign-in with no
access (an invited driver, a pending invite) can read every shared list again, lock box codes included. So turn those
sign-ins off FIRST, then the gate.

3a. List them (every sign-in not turned off whose person has no View or Edit in any app, or has no active HR row):

```sql
select u.id, u.email, u.email_confirmed_at is not null as confirmed, u.last_sign_in_at
  from auth.users u
 where u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
   and not exists (select 1 from public.employees e
                    cross join lateral hr.fn_effective_access(e.id) f
                    where e.status = 'ACTIVE' and lower(btrim(e.email)) = lower(btrim(u.email))
                      and f.parent is null and f.level in ('view', 'edit'));
```

3b. Turn them off (100 years, the same as the HR App's Turn off; the HR App's Turn on undoes one) and end their
sessions. An access token already issued still works for up to an hour.

```sql
with turned_off as (
  update auth.users u set banned_until = now() + interval '100 years'
   where u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
     and not exists (select 1 from public.employees e
                      cross join lateral hr.fn_effective_access(e.id) f
                      where e.status = 'ACTIVE' and lower(btrim(e.email)) = lower(btrim(u.email))
                        and f.parent is null and f.level in ('view', 'edit'))
  returning u.id, u.email)
delete from auth.sessions s using turned_off t where s.user_id = t.id
returning t.email;
```

(The `returning` lists only people who had a session; 3a is the full check.)

Run 3a again: it must return 0 rows. Then the gate:

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

```sql
-- Admin Review (2026-10-21_0730): direct write grants
grant update (manhole_count) on public.visits to authenticated;
grant update (grease_trap_manhole_count, sample_port_count) on public.properties to authenticated;
create policy properties_anon_update_manhole_authn on public.properties for update to authenticated using (true) with check (true);
grant insert, update, delete on public.photo_links, public.photos to authenticated;
create policy "Authenticated insert photo_links" on public.photo_links for insert to authenticated
  with check (((select auth.uid()) is not null) and (entity_type is distinct from 'job_frequency_change')
    and (coalesce(role, '') is distinct from 'approval_proof') and (entity_type is distinct from 'client_status_change')
    and (coalesce(role, '') is distinct from 'reason_photo') and (entity_type is distinct from 'property_intake'));
create policy "Authenticated insert app-uploaded photos" on public.photos for insert to authenticated
  with check (((select auth.uid()) is not null) and (source = 'admin_review_upload'));
-- Admin Review functions closed with its switch-on (2026-10-21_0720)
grant execute on function public.set_visit_manholes(bigint, bigint[]) to authenticated;
-- DERM Tracker (2026-10-21_0830)
grant execute on function public.fn_requeue_derm_portal(bigint, bigint, text, text) to authenticated;
-- DERM Tracker direct writes (2026-10-21_1000)
grant insert, delete on public.manifest_visits to authenticated;
create policy anon_insert_manifest_visits_authn on public.manifest_visits for insert to authenticated with check (true);
create policy anon_delete_manifest_visits_authn on public.manifest_visits for delete to authenticated using (true);
grant insert, update on public.derm_manifests to authenticated;
grant update (gdo_id) on public.derm_manifests to authenticated;
create policy anon_insert_derm_manifests_authn on public.derm_manifests for insert to authenticated with check (true);
create policy anon_update_derm_manifests_authn on public.derm_manifests for update to authenticated using (true) with check (true);
grant update (derm_required) on public.visits to authenticated;
create policy visits_calendar_update on public.visits for update to authenticated using (source = 'visit-calendar') with check (source = 'visit-calendar');
create policy visits_authenticated_update_derm_required on public.visits for update to authenticated using (visit_status = 'completed') with check (visit_status = 'completed');
create policy visits_app_update_authn on public.visits for update to authenticated using (deleted_at is null) with check (deleted_at is null);
-- Visit Calendar (2026-10-21_1900)
grant execute on function public.skip_visit(bigint, text) to authenticated;
grant execute on function ops.skip_visit(bigint, text) to authenticated;
```

## 5. Storage (gate step only)

The policies as they were before the gate step are saved in `backups/2026-10-21_access_switch_on_snapshot.json`
(key `policies`, schema `storage`). Added here as SQL when that step ships.

## 2026-10-21_1920 · Calendar day marker dump link (column grant)
```sql
grant update (dump_visit_id) on ops.calendar_day_markers to authenticated;
```

## 2026-10-21_1910 · Read gate off (same as G3)
🛑 Since 2026-10-26: run section 3a and 3b first (turn off the sign-ins with no access), then:
```sql
alter role authenticator reset pgrst.db_pre_request; notify pgrst, 'reload config';
```

## 6. Stop invites (Send invite, 2026-10-26)

One line. A missing key or any value but `true` means invites are off; `public.app_config.value` is text.

```sql
update public.app_config set value = 'false' where key = 'hr_invites_on';
```

🛑 Never use an app's mode as the invite switch: putting an app in watch does not stop invites, and the other checks
are built around every app being on. Second line of defence: a revert commit of the `hr-sign-in` change, deployed and
read back (never deploy an old version from a modified tree).
