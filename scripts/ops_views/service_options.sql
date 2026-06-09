-- ============================================================================
-- ops.service_options — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.service_options AS
SELECT id,
    code,
    title,
    requires_derm,
    service_type,
        CASE
            WHEN reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text]) THEN reason
            ELSE regexp_replace(title, '^[0-9]+ - '::text, ''::text)
        END AS level1,
        CASE
            WHEN reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text]) THEN service_kind
            ELSE NULL::text
        END AS level2,
        CASE
            WHEN location_target IS NOT NULL THEN location_target || COALESCE(' - '::text || method, ''::text)
            ELSE NULL::text
        END AS level3
   FROM service_line_items
  WHERE active = true;
