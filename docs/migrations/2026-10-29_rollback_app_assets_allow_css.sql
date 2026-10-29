-- Rollback of 2026-10-29_0045_app_assets_allow_css.sql: app-assets back to jpeg/png/svg only.
-- Objects already uploaded stay served; the type list only gates new uploads.

begin;

update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/svg+xml']::text[]
where id = 'app-assets';

do $$
begin
  if (select allowed_mime_types from storage.buckets where id = 'app-assets')
     is distinct from array['image/jpeg', 'image/png', 'image/svg+xml']::text[] then
    raise exception 'VERIFY failed';
  end if;
end $$;

commit;
