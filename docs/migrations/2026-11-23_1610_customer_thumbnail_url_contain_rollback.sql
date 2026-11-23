-- 2026-11-23_1610_customer_thumbnail_url_contain_rollback.sql
-- Puts customer.thumbnail_url back to `resize=cover` (the body before 2026-11-23_1610).
-- Guarded: refuses unless the live body is exactly the one 2026-11-23_1610 created.
-- Nothing on screen changes either way: every reader rewrites cover to contain in the browser.

BEGIN;

DO $guard$
BEGIN
  IF md5(replace(pg_get_functiondef('customer.thumbnail_url(text,integer,integer,integer)'::regprocedure),
                 '&resize=contain', '&resize=cover')) <> 'c6427b2a71596c442d5baa1a39b56fe7'
     OR pg_get_functiondef('customer.thumbnail_url(text,integer,integer,integer)'::regprocedure) !~ '&resize=contain' THEN
    RAISE EXCEPTION 'customer.thumbnail_url is not the 2026-11-23_1610 body: rollback refused';
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
         || '&resize=cover'
         || CASE WHEN height IS NOT NULL THEN '&height=' || height::text ELSE '' END
  END
$function$
;

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('customer.thumbnail_url(text,integer,integer,integer)'::regprocedure))
     <> 'c6427b2a71596c442d5baa1a39b56fe7' THEN
    RAISE EXCEPTION 'VERIFY: rollback body is not the pre-2026-11-23_1610 body';
  END IF;
END
$verify$;

COMMIT;
