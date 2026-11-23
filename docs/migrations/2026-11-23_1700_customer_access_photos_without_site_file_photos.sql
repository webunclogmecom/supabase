-- 2026-11-23_1700_customer_access_photos_without_site_file_photos.sql
--
-- WHAT: customer.client_access_photos leaves out the Page Builder's Site file photos (photos.source 'site_file_upload',
--       and anything stored in the private bucket intake-photos). One condition added to the CTE's WHERE; the body is
--       copied from the live pg_get_viewdef (md5 pinned), same columns, same grants.
--
-- WHY: Fred, 2026-11-23, asked "Should Page Builder Site file photos show on the customer's Field Portal page?":
--   "No, hide them". client.add_site_photo (Trello #219, 2026-11-17_1300) links a Site file photo to the property
--   (photo_links.entity_type 'property'), and this view publishes every live 'property' link to the Field Portal's
--   Location Info tab ("Access Pictures"). The file sits in the PRIVATE bucket intake-photos while customer.public_url
--   and customer.thumbnail_url build GT - Visits Images links, so the customer got broken images, each captioned with
--   the uploading staff member's email (measured live 2026-11-23 on 112-YA: 3 photos, 3 broken, caption = an email).
--   The intake form already links its photos as 'property_intake' for this reason (intake-submit: "customer.
--   client_access_photos publishes 'property' rows to an anon-reachable portal"). Fixing the bucket instead would have
--   published private site photos, which can show lock boxes and gates.
--
-- REACH (measured): the only 'client' / 'property' photo links in the database are those 3 (all 112-YA, all
--   site_file_upload), and client.add_site_photo is the only writer of 'property' links. So the view goes 3 -> 0 rows
--   and the Field Portal hides the empty section (its rule 8). Nothing else reads the view (customer.get_client_portal).
--
-- ROLLBACK: 2026-11-23_1700_customer_access_photos_without_site_file_photos_rollback.sql (md5-guarded on the new body).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_viewdef('customer.client_access_photos'::regclass)) <> '4811b5e4c1004dcb4078eb494e2d16af' THEN
    RAISE EXCEPTION 'customer.client_access_photos changed since this migration was written: re-copy the live body';
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
  WHERE (client_id_resolved IS NOT NULL);

DO $verify$
BEGIN
  -- nothing else moved: taking the added condition out gives the old body exactly
  IF md5(replace(pg_get_viewdef('customer.client_access_photos'::regclass), ' AND (ph.source IS DISTINCT FROM ''site_file_upload''::text) AND (ph.storage_path !~ ''^intake-photos/''::text)', ''))
     <> '4811b5e4c1004dcb4078eb494e2d16af' THEN
    RAISE EXCEPTION 'VERIFY: the view differs from the live one by more than the added condition';
  END IF;
  IF EXISTS (SELECT 1 FROM customer.client_access_photos WHERE url ~ 'intake-photos/') THEN
    RAISE EXCEPTION 'VERIFY: a private intake-photos file is still published';
  END IF;
  IF EXISTS (SELECT 1 FROM public.photo_links pl JOIN public.photos ph ON ph.id = pl.photo_id
              WHERE ph.source = 'site_file_upload' AND customer.uuid_from_bigint(pl.id) IN (SELECT id FROM customer.client_access_photos)) THEN
    RAISE EXCEPTION 'VERIFY: a Site file photo is still published';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c WHERE c.oid = 'customer.client_access_photos'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
     OR (SELECT c.reloptions FROM pg_class c WHERE c.oid = 'customer.client_access_photos'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: grants or options of the view moved';
  END IF;
END
$verify$;

COMMIT;
