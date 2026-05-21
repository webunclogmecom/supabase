-- 2026-05-14e_customer_wo_photos_service_phase.sql
--
-- Update customer.wo_photos to source `variant` from canonical
-- photo_classifications.service_phase when present, falling back to
-- photo_links.role only for un-classified photos.
--
-- Prereq: migration 2026-05-14d_photo_classifications.sql (creates the
-- canonical photo_classifications table). If 14d hasn't been applied,
-- the LEFT JOIN below returns NULL for all rows and the COALESCE
-- effectively reverts to the legacy behavior, so applying 14e before
-- 14d is harmless (just doesn't improve anything).
--
-- Why LEFT JOIN: most photos won't have a human classification.
-- Fallback chain: service_phase  >  photo_links.role  >  'other'

BEGIN;

CREATE OR REPLACE VIEW customer.wo_photos AS
SELECT
  customer.uuid_from_bigint(pl.id) AS id,
  customer.uuid_from_bigint(pl.entity_id) AS work_order_id,
  pc.service_phase AS variant,  -- always one of: 'before', 'after', 'extra' (filter below guarantees this)
  customer.public_url(ph.storage_path) AS url,
  pl.caption,
  (ROW_NUMBER() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS position
FROM public.photo_links pl
JOIN public.photos ph ON ph.id = pl.photo_id
JOIN public.photo_classifications pc ON pc.photo_link_id = pl.id  -- INNER JOIN so unclassified photos don't appear
WHERE pl.entity_type = 'visit'
  AND pc.service_phase IN ('before', 'after', 'extra');
  -- Customer view shows ONLY photos explicitly classified for customer eyes.
  -- Hidden: 'internal' (admin-only), 'unknown' (driver said don't know), unclassified
  -- (no photo_classifications row), and any photo_links.role-only photos. Updated 2026-05-15.

COMMIT;
