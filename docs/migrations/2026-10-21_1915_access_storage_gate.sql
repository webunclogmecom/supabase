-- 2026-10-21 (evening) ET · Access switch-on, gate step G0b: files and photos close to a person with no access
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, A9 G0b, D8 "required"). The read gate (public.fn_request_gate) covers
-- every PostgREST request, but Storage does not go through PostgREST: its policies only ask for a signed-in user. So
-- once every app is on, a sign-in with no access anywhere could still read, upload, overwrite and delete files in the
-- buckets that allow signed-in users (manifests, GT - Visits Images, employee-photos, reason-photos, rpa-evidence,
-- intake-photos, approval-proof).
--
-- ONE restrictive policy for `authenticated`, every command, ANDed with all the existing ones:
--   storage_access_gate: hr.fn_storage_open()
-- hr.fn_storage_open() is the read gate's rule (hr.fn_any_app_open) with one deliberate difference: it decides by
-- auth.uid(), not by the presence of request.jwt.claims. hr.fn_any_app_open treats "no claims" as the server and lets
-- it through; Storage may set only the per-claim settings, and that shortcut would then open every bucket to everyone,
-- silently. auth.uid() reads both forms. The server key never reaches this policy (it is for `authenticated` only),
-- and anon upload paths (the collector form, through edge functions with the server key) are unaffected.
-- While any app is not on, the policy changes nothing.
-- 🛑 The check is wrapped in a sub-select ON PURPOSE (applied 2026-10-22 ~11:00 ET). Rehearsed first as a bare
-- hr.fn_storage_open() call: Postgres ran it once PER FILE and counting the 33,146 'GT - Visits Images' objects hit the
-- 8 s statement timeout, so every staff photo list would have failed. As (select hr.fn_storage_open()) it is evaluated
-- once per statement: rehearsed (rolled back) as Fred, Diego, Serena, Aaron, Yannick and jon.v over the 7 buckets, staff
-- counts identical to before the policy (1152 / 33146 / 4 / 4 / 89 / 92 / 14) at the same speed (~80 ms on the
-- largest), jon.v 0 in every bucket. Never unwrap it.
-- Undo: drop policy storage_access_gate on storage.objects;  (docs/runbooks/access-undo.md section 5)

BEGIN;

create or replace function hr.fn_storage_open()
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  -- 2026-10-21_1915 (G0b): true unless every top-level app is on and the signed-in caller has View/Edit in none of them
  select auth.uid() is null
      or exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on')
      or exists (select 1 from hr.fn_effective_access(hr.fn_access_caller()) f
                  where f.parent is null and f.mode = 'on' and f.level in ('view', 'edit'))
$function$;
revoke all on function hr.fn_storage_open() from public, anon;
grant execute on function hr.fn_storage_open() to authenticated, service_role;

create policy storage_access_gate on storage.objects as restrictive for all to authenticated
  using ((select hr.fn_storage_open())) with check ((select hr.fn_storage_open()));

do $verify$
declare n_fred int; n_jon int; v text;
begin
  -- with every app on (inside a block undone by the marker): Fred sees files, jon.v sees none and cannot delete
  begin
    update hr.access_apps set mode = 'on', on_since = coalesce(on_since, now()) where parent is null;
    perform set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}', true);
    perform set_config('role', 'authenticated', true);
    select count(*) into n_fred from storage.objects where bucket_id = 'intake-photos';
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}', true);
    perform set_config('role', 'authenticated', true);
    select count(*) into n_jon from storage.objects where bucket_id = 'intake-photos';
    perform set_config('role', 'postgres', true);
    if n_fred = 0 then raise exception 'VERIFY: Fred sees no intake photo (control failed)'; end if;
    if n_jon <> 0 then raise exception 'VERIFY: jon.v still sees % intake photos', n_jon; end if;
    raise exception 'undo_marker_1915';
  exception when others then
    perform set_config('role', 'postgres', true);
    if sqlerrm <> 'undo_marker_1915' then raise; end if;
  end;
  -- and in the real state right now, the policy lets a staff person through
  perform set_config('request.jwt.claims', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}', true);
  perform set_config('role', 'authenticated', true);
  perform count(*) from storage.objects where bucket_id = 'manifests';
  perform set_config('role', 'postgres', true);
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
