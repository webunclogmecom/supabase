-- 2026-05-21c_gdos_backfill_property_id.sql
--
-- Per Fred 2026-05-21: GDO is location-specific and stable across permit
-- renewals or tenant changes — should be linked to property, not just client.
--
-- Current state: all 104 gdos.property_id are NULL (only client_id set).
--
-- This migration links the GDO to the client's primary property when the
-- linkage is unambiguous (1 GDO + 1 property per client → trivial; multiple
-- properties → use is_primary as the canonical service location).
--
-- Multi-GDO clients (today: Casa Neos 009-CN with 3 GDOs) are left for
-- Yannick to disambiguate manually — we can't guess which GDO goes with
-- which property from the data alone.
--
-- Audit (Rule 8): data-only UPDATE on already-audited table (gdos).

BEGIN;

-- A) Single-GDO clients: link to client's primary property
WITH single_gdo AS (
  SELECT client_id
  FROM gdos
  GROUP BY client_id
  HAVING COUNT(*) = 1
),
primary_props AS (
  SELECT DISTINCT ON (client_id) client_id, id AS property_id
  FROM properties
  WHERE is_primary = true
  ORDER BY client_id, id
)
UPDATE gdos g
SET property_id = pp.property_id
FROM single_gdo sg
JOIN primary_props pp ON pp.client_id = sg.client_id
WHERE g.client_id = sg.client_id
  AND g.property_id IS NULL;

-- B) Verify
SELECT
  COUNT(*) AS total_gdos,
  COUNT(property_id) AS linked_to_property,
  COUNT(*) - COUNT(property_id) AS still_unlinked,
  COUNT(DISTINCT client_id) FILTER (WHERE property_id IS NULL) AS clients_needing_manual_link
FROM gdos;

COMMIT;
