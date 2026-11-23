-- 2026-11-23_1610_customer_thumbnail_url_contain.sql
--
-- WHAT: customer.thumbnail_url asks Storage for `resize=contain` instead of `resize=cover`.
--       One word. Body copied from the live pg_get_functiondef (md5 pinned below), not retyped.
--
-- WHY: measured 2026-11-23 (Trello #244 follow-up, the task chip Supabase 2 left: "check and fix the
--   cropping in every app"). Supabase Storage's render endpoint, asked with a WIDTH ONLY and
--   resize=cover, returns WIDTH x ORIGINAL HEIGHT: the middle columns of the photo, not a smaller photo.
--   On real rows of customer.wo_photos (stored -> what this helper's URL returns):
--     810x1080  -> 400x1080   the middle 49% of the photo's width
--     1080x810  -> 400x810    37%
--     720x1280  -> 400x1280   56%   (stored 1280x720 + EXIF rotation)
--     608x1080  -> 400x1080   66%
--   The same URL with resize=contain returns the whole photo, upright, 400 wide (400x533, 400x300, 400x711).
--
-- WHO READS IT: the views customer.wo_photos (6,099 visit photos) and customer.client_access_photos
--   (3 rows, all 112-YA test). Through customer.get_work_order(_internal), customer.get_client_portal and
--   derm.get_visit_report they reach: the Field Portal (client page, visit page, report page), the DERM
--   Tracker visit report, and the PDF service, which prints those two pages in a browser.
--   EVERY ONE OF THEM ALREADY REWRITES `resize=cover` TO `resize=contain` IN THE BROWSER (Field Portal
--   since 2026-07-08, see its 08-changelog; the DERM report page carries the same rewrite). So no screen
--   showed a cut photo; the helper was a trap for the next reader that does not know the rewrite.
--   After this migration the browsers fetch the SAME URL, byte for byte, as before: the rewrite becomes a
--   no-op. No customer-visible change. The rewrites stay in the apps (harmless, and they cover a payload
--   cached before this migration).
--
-- NOT HERE (Trello #244, Supabase 2's claim): the Picture Planner Page Builder, the Ops Portal copy
--   (PageBuilder.tsx, PageBuilderList.tsx) and the driver-page edge function, which ask supabase-js /
--   the render endpoint for `{ width }` with no resize at all (same crop).
--
-- ROLLBACK: 2026-11-23_1610_customer_thumbnail_url_contain_rollback.sql (md5-guarded on the new body).

BEGIN;

-- Guard: the live body is the one this file was copied from.
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('customer.thumbnail_url(text,integer,integer,integer)'::regprocedure))
     <> 'c6427b2a71596c442d5baa1a39b56fe7' THEN
    RAISE EXCEPTION 'customer.thumbnail_url changed since this migration was written: re-copy the live body';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION customer.thumbnail_url(storage_path text, width integer DEFAULT 400, height integer DEFAULT NULL::integer, quality integer DEFAULT 80)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN storage_path IS NULL OR storage_path = '' THEN NULL
    ELSE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/render/image/public/GT%20-%20Visits%20Images/'
         || storage_path
         || '?width=' || width::text
         || '&quality=' || quality::text
         || '&resize=contain'
         || CASE WHEN height IS NOT NULL THEN '&height=' || height::text ELSE '' END
  END
$function$
;

-- VERIFY
DO $verify$
DECLARE
  base text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/render/image/public/GT%20-%20Visits%20Images/';
  def  text := pg_get_functiondef('customer.thumbnail_url(text,integer,integer,integer)'::regprocedure);
BEGIN
  -- nothing else moved: putting the one word back gives the old body exactly
  IF md5(replace(def, '&resize=contain', '&resize=cover')) <> 'c6427b2a71596c442d5baa1a39b56fe7' THEN
    RAISE EXCEPTION 'VERIFY: the body differs from the live one by more than the resize word';
  END IF;
  IF customer.thumbnail_url('a/b.jpg') IS DISTINCT FROM base || 'a/b.jpg?width=400&quality=80&resize=contain' THEN
    RAISE EXCEPTION 'VERIFY: default URL is %', customer.thumbnail_url('a/b.jpg');
  END IF;
  IF customer.thumbnail_url('a/b.jpg', 400, 300) IS DISTINCT FROM base || 'a/b.jpg?width=400&quality=80&resize=contain&height=300' THEN
    RAISE EXCEPTION 'VERIFY: width+height URL is %', customer.thumbnail_url('a/b.jpg', 400, 300);
  END IF;
  IF customer.thumbnail_url(NULL) IS NOT NULL OR customer.thumbnail_url('') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: an empty path must still give NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM customer.wo_photos WHERE thumbnail_url ~ 'resize=cover')
     OR EXISTS (SELECT 1 FROM customer.client_access_photos WHERE thumbnail_url ~ 'resize=cover') THEN
    RAISE EXCEPTION 'VERIFY: a view still carries resize=cover';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM customer.wo_photos WHERE thumbnail_url ~ 'resize=contain') THEN
    RAISE EXCEPTION 'VERIFY: customer.wo_photos has no contain URL (positive control)';
  END IF;
END
$verify$;

COMMIT;
