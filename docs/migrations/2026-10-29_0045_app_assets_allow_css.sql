-- 2026-10-29_0045_app_assets_allow_css.sql
--
-- Fred, 2026-10-29: "Haunted Night with Creepster, apply it to all the apps, but keep in mind this is
-- temporal only up to tuesday." The Halloween look ships as one stylesheet per app in the public UI
-- bucket app-assets (under halloween/), loaded by a small date-gated snippet in each app that stops
-- loading it at 2026-11-04 00:00 ET. The bucket accepted only jpeg/png/svg, so this adds text/css.
--
-- WHAT IT DOES
--   app-assets.allowed_mime_types gains 'text/css'. Nothing else moves: the bucket stays public-read
--   with its 5 MB cap, and no storage policy names it, so service_role alone can write to it.
--
-- WHY A HOSTED STYLESHEET AND NOT CSS INSIDE EACH APP
--   Each app's file is generated from that app's own live stylesheet (every colour rule gets a night
--   twin). Pasting ten 20-45 KB files through Lovable prompts invites a silent typo in each, and every
--   fix would cost ten more builds; one hosted file per app is fixed by one upload.
--
-- RULE 8 (audit): no table touched. Grants and policies: none changed.
-- ROLLBACK: 2026-10-29_rollback_app_assets_allow_css.sql (remove the halloween/*.css objects first,
-- or keep them: a type list only gates NEW uploads).

begin;

do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'app-assets' and public
      and allowed_mime_types = array['image/jpeg', 'image/png', 'image/svg+xml']::text[]
  ) then
    raise exception 'app-assets is not in the expected state (public, jpeg/png/svg)';
  end if;
end $$;

update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/svg+xml', 'text/css']::text[]
where id = 'app-assets';

-- VERIFY
do $$
begin
  if (select allowed_mime_types from storage.buckets where id = 'app-assets')
     is distinct from array['image/jpeg', 'image/png', 'image/svg+xml', 'text/css']::text[]
     or not (select public from storage.buckets where id = 'app-assets') then
    raise exception 'VERIFY failed: app-assets types or public flag';
  end if;
end $$;

commit;
