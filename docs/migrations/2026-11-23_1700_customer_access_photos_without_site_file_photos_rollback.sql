-- 2026-11-23_1700_customer_access_photos_without_site_file_photos_rollback.sql
-- Puts customer.client_access_photos back to the body before 2026-11-23_1700_customer_access_photos_without_site_file_photos (Site file photos published again).
-- Guarded: refuses unless the live body is exactly the one that migration created.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_viewdef('customer.client_access_photos'::regclass)) <> md5($q$ WITH resolved AS (
         SELECT pl.id AS link_id,
            pl.caption,
            ph.storage_path,
            ph.created_at,
            COALESCE(
                CASE
                    WHEN (pl.entity_type = 'client'::text) THEN pl.entity_id
                    ELSE NULL::bigint
                END, p.client_id) AS client_id_resolved
           FROM ((photo_links pl
             JOIN photos ph ON ((ph.id = pl.photo_id)))
             LEFT JOIN properties p ON (((p.id = pl.entity_id) AND (pl.entity_type = 'property'::text))))
          WHERE ((pl.entity_type = ANY (ARRAY['client'::text, 'property'::text])) AND (pl.deleted_at IS NULL) AND (ph.source IS DISTINCT FROM 'site_file_upload'::text) AND (ph.storage_path !~ '^intake-photos/'::text))
        )
 SELECT customer.uuid_from_bigint(link_id) AS id,
    customer.uuid_from_bigint(client_id_resolved) AS client_id,
    customer.public_url(storage_path) AS url,
    caption,
    ((row_number() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1))::integer AS "position",
    created_at,
    customer.thumbnail_url(storage_path, 400) AS thumbnail_url
   FROM resolved
  WHERE (client_id_resolved IS NOT NULL);$q$) THEN
    RAISE EXCEPTION 'customer.client_access_photos is not the 2026-11-23_1700_customer_access_photos_without_site_file_photos body: rollback refused';
  END IF;
END
$guard$;

CREATE OR REPLACE VIEW customer.client_access_photos AS
 WITH resolved AS (
         SELECT pl.id AS link_id,
            pl.caption,
            ph.storage_path,
            ph.created_at,
            COALESCE(
                CASE
                    WHEN (pl.entity_type = 'client'::text) THEN pl.entity_id
                    ELSE NULL::bigint
                END, p.client_id) AS client_id_resolved
           FROM ((photo_links pl
             JOIN photos ph ON ((ph.id = pl.photo_id)))
             LEFT JOIN properties p ON (((p.id = pl.entity_id) AND (pl.entity_type = 'property'::text))))
          WHERE ((pl.entity_type = ANY (ARRAY['client'::text, 'property'::text])) AND (pl.deleted_at IS NULL))
        )
 SELECT customer.uuid_from_bigint(link_id) AS id,
    customer.uuid_from_bigint(client_id_resolved) AS client_id,
    customer.public_url(storage_path) AS url,
    caption,
    ((row_number() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1))::integer AS "position",
    created_at,
    customer.thumbnail_url(storage_path, 400) AS thumbnail_url
   FROM resolved
  WHERE (client_id_resolved IS NOT NULL);

DO $verify$
BEGIN
  IF md5(pg_get_viewdef('customer.client_access_photos'::regclass)) <> '4811b5e4c1004dcb4078eb494e2d16af' THEN
    RAISE EXCEPTION 'VERIFY: rollback body is not the pre-2026-11-23_1700_customer_access_photos_without_site_file_photos body';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'customer.client_access_photos'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
     OR (SELECT c.reloptions FROM pg_class c WHERE c.oid = 'customer.client_access_photos'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: grants or options of the view moved';
  END IF;
END
$verify$;

COMMIT;
