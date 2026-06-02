-- 2026-06-01_service_options_view.sql
-- Cascading 3-level service picker source for the Calendar form (per Fred's structure):
--   level1 (category): 'Service Agreement' | 'Service Call' | standalone item title (fees/GDO)
--   level2 (type):     service_kind for SA/SC items; NULL for standalone
--   level3 (detail):   location_target [ + ' - ' + method ]; NULL where terminal
-- Each path maps to its service_line_items row (id/code/title/requires_derm/service_type).
-- ALL 27 items (no schedulable filter) — the form offers the full taxonomy.
CREATE OR REPLACE VIEW ops.service_options AS
SELECT
  id, code, title, requires_derm, service_type,
  CASE WHEN reason IN ('Service Agreement','Service Call') THEN reason
       ELSE regexp_replace(title, '^[0-9]+ - ', '') END AS level1,
  CASE WHEN reason IN ('Service Agreement','Service Call') THEN service_kind
       ELSE NULL END AS level2,
  CASE WHEN location_target IS NOT NULL
       THEN location_target || COALESCE(' - ' || method, '')
       ELSE NULL END AS level3
FROM public.service_line_items
WHERE active = true;
GRANT SELECT ON ops.service_options TO anon, authenticated;
