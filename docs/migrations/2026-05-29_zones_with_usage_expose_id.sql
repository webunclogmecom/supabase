-- 2026-05-29_zones_with_usage_expose_id.sql
--
-- Hot-fix: add z.id to public.zones_with_usage view.
--
-- The 2026-05-29 FK refactor added zones.id as the surrogate PK but the
-- view's SELECT list omitted it. PostgREST 400s when Lovable's React Query
-- tries to select id (needed for .eq('id', row.id) saves on the editable
-- code column). No id → no rows rendered → silent empty modal body.
--
-- Idempotent (Rule 5): CREATE OR REPLACE VIEW.

BEGIN;

-- DROP + CREATE because adding a column at a new position is rejected by
-- CREATE OR REPLACE VIEW (Postgres protects column position invariants).
DROP VIEW IF EXISTS public.zones_with_usage;

CREATE VIEW public.zones_with_usage AS
  SELECT
    z.id,
    z.code,
    z.label,
    z.color_hex,
    z.color_token,
    z.sort_order,
    z.is_active,
    z.created_at,
    z.updated_at,
    COALESCE(p.n_properties, 0)::int AS n_properties
  FROM public.zones z
  LEFT JOIN (
    SELECT zone_id, COUNT(*)::int AS n_properties
    FROM public.properties
    WHERE zone_id IS NOT NULL
    GROUP BY zone_id
  ) p ON p.zone_id = z.id;

GRANT SELECT ON public.zones_with_usage TO anon, authenticated;

COMMIT;
