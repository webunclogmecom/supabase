-- 2026-10-21_0730 ET · Access switch-on 3 of 6, step 4: Admin Review's old direct write grants go
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, A2 to A7 step 4). Since 2026-10-20 Admin Review writes these
-- through checked SECURITY DEFINER functions (review_set_visit_manholes, review_set_property_counts,
-- review_add_visit_photo), so the direct grants only let a signed-in user skip the access check:
--   UPDATE(manhole_count) on public.visits
--   UPDATE(grease_trap_manhole_count, sample_port_count) on public.properties  + policy properties_anon_update_manhole_authn
--   INSERT on public.photo_links + policy "Authenticated insert photo_links"
--   INSERT on public.photos      + policy "Authenticated insert app-uploaded photos" (its check: source = admin_review_upload)
-- Measured before revoking (root CLAUDE.md 5.5(b)):
--   * none of the 10 live staff bundles writes these directly (scripts/checks/access-switch-on.mjs bundle sweep);
--   * gateway logs, 7 days to 2026-10-21: every POST/PATCH on /rest/v1/photo_links (120 + 8) and /rest/v1/photos (121)
--     came from our edge functions with the server key (Deno user agent), none from a browser. photo_links and photos
--     have NO audit trigger, so the gateway logs are the evidence here, not audit.logs;
--   * audit.logs, 3 days: direct /visits and /properties updates are all from the server (app_source sql / jobber).
-- Other writes on these tables stay (service_role, and the SECURITY DEFINER functions running as owner).
-- Re-grant lines: docs/runbooks/access-undo.md.

BEGIN;
SET LOCAL lock_timeout = '3s';

revoke update (manhole_count) on public.visits from authenticated;
revoke update (grease_trap_manhole_count, sample_port_count) on public.properties from authenticated;
drop policy properties_anon_update_manhole_authn on public.properties;

revoke insert, update, delete on public.photo_links, public.photos from authenticated;
drop policy "Authenticated insert photo_links" on public.photo_links;
drop policy "Authenticated insert app-uploaded photos" on public.photos;

do $verify$
begin
  if has_column_privilege('authenticated', 'public.visits', 'manhole_count', 'UPDATE')
     or has_column_privilege('authenticated', 'public.properties', 'grease_trap_manhole_count', 'UPDATE')
     or has_column_privilege('authenticated', 'public.properties', 'sample_port_count', 'UPDATE')
     or has_table_privilege('authenticated', 'public.photo_links', 'INSERT')
     or has_table_privilege('authenticated', 'public.photos', 'INSERT') then
    raise exception 'VERIFY: a revoked grant is still there';
  end if;
  if not has_table_privilege('service_role', 'public.photo_links', 'INSERT') or not has_table_privilege('service_role', 'public.photos', 'INSERT') then
    raise exception 'VERIFY: service_role lost a write';
  end if;
  -- reads still work for staff
  perform set_config('request.jwt.claims', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}', true);
  perform set_config('role', 'authenticated', true);
  perform count(*) from public.photo_links where id < 10;
  perform manhole_count from public.visits where id = 8742;
  perform set_config('role', 'postgres', true);
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
