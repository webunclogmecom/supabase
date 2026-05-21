-- 2026-05-16b_customer_thumbnail_url.sql
--
-- Image transformation was enabled on Prod storage 2026-05-16. This migration
-- adds a thumbnail_url helper and exposes it on the customer.wo_photos view so
-- the Field Portal app can request resized thumbnails for the photo grid
-- (much smaller payloads than the full-size originals).
--
-- The existing customer.public_url helper continues to return the full-size
-- public URL. The new helper builds a /render/image/public/... URL with
-- width/quality params.
--
-- URL pattern:
--   https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/render/image/public/
--     GT%20-%20Visits%20Images/{path}?width={W}&quality={Q}&resize=cover
--   (optional &height={H})
--
-- Defaults chosen for typical mobile photo-grid cell:
--   width=400, height=NULL (auto from aspect), quality=80, resize=cover

BEGIN;

-- 1. New helper
CREATE OR REPLACE FUNCTION customer.thumbnail_url(
  storage_path text,
  width int DEFAULT 400,
  height int DEFAULT NULL,
  quality int DEFAULT 80
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN storage_path IS NULL OR storage_path = '' THEN NULL
    ELSE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/render/image/public/GT%20-%20Visits%20Images/'
         || storage_path
         || '?width=' || width::text
         || '&quality=' || quality::text
         || '&resize=cover'
         || CASE WHEN height IS NOT NULL THEN '&height=' || height::text ELSE '' END
  END
$$;

-- 2. Grant execute to the same roles that already use public_url
GRANT EXECUTE ON FUNCTION customer.thumbnail_url(text, int, int, int) TO anon, authenticated, service_role;

-- 3. Extend customer.wo_photos to expose thumbnail_url at the end
-- (CREATE OR REPLACE VIEW can't reorder existing columns; appended at end is fine)
CREATE OR REPLACE VIEW customer.wo_photos AS
SELECT
  customer.uuid_from_bigint(pl.id) AS id,
  customer.uuid_from_bigint(pl.entity_id) AS work_order_id,
  pc.service_phase AS variant,
  customer.public_url(ph.storage_path) AS url,
  pl.caption,
  (row_number() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS "position",
  -- NEW (appended):
  customer.thumbnail_url(ph.storage_path, 400) AS thumbnail_url
FROM photo_links pl
  JOIN photos ph ON ph.id = pl.photo_id
  JOIN photo_classifications pc ON pc.photo_link_id = pl.id
WHERE pl.entity_type = 'visit'::text
  AND (pc.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'extra'::text]));

-- 4. Same pattern for client_access_photos. Preserves existing CTE shape;
--    only appends thumbnail_url at the end (CREATE OR REPLACE rules).
CREATE OR REPLACE VIEW customer.client_access_photos AS
WITH resolved AS (
  SELECT pl.id AS link_id,
    pl.caption,
    ph.storage_path,
    ph.created_at,
    COALESCE(
      CASE WHEN pl.entity_type = 'client'::text THEN pl.entity_id ELSE NULL::bigint END,
      p.client_id
    ) AS client_id_resolved
  FROM photo_links pl
    JOIN photos ph ON ph.id = pl.photo_id
    LEFT JOIN properties p ON p.id = pl.entity_id AND pl.entity_type = 'property'::text
  WHERE pl.entity_type = ANY (ARRAY['client'::text, 'property'::text])
)
SELECT
  customer.uuid_from_bigint(link_id) AS id,
  customer.uuid_from_bigint(client_id_resolved) AS client_id,
  customer.public_url(storage_path) AS url,
  caption,
  (row_number() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1)::integer AS "position",
  created_at,
  -- NEW (appended):
  customer.thumbnail_url(storage_path, 400) AS thumbnail_url
FROM resolved
WHERE client_id_resolved IS NOT NULL;

COMMIT;
