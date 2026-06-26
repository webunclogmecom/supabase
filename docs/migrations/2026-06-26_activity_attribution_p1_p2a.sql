-- ============================================================================
-- 2026-06-26_activity_attribution_p1_p2a.sql
-- ADR 010: (1) seeds public.employees.email (audited table — intentional data
--          backfill, audit fires); (2) CREATE OR REPLACE read-only get_record_history.
-- ADR 016: actor attribution read layer; no app_source/trigger change.
-- ----------------------------------------------------------------------------
-- Activity-tab "who did it" — P1 (Calendar person) + P2a ("Changed in Jobber").
-- Spec: docs/superpowers/specs/2026-06-26-activity-who-did-it-attribution-design.md
-- Folds in the impact-review fixes (GO-WITH-CHANGES, 2026-06-26):
--   * Person resolved as a SCALAR correlated subquery (LIMIT 1) — never a JOIN onto
--     src (employees.email has no unique constraint -> a JOIN would multiply rows
--     across all 4 apps + corrupt LIMIT pagination).
--   * src selects ONLY the two scalars it needs (jwt_claims->>'email',
--     request_context->>'actor_name') — NOT raw jwt_claims (15 PII keys; the fn is
--     GRANTed to anon). RETURNS TABLE signature unchanged (8 cols).
--   * Person-resolution lives STRICTLY inside the existing human-app WHEN branch;
--     the p_hide_system allowlist + the system/cron branches are byte-identical, so
--     field-portal/derm-tracker/admin-review + cron/reconcile labels are preserved.
--   * Shared login unclogme@unclogme.com -> NO by-line (collapses N humans -> 1).
--   * NO audit.log_change change here (the changed_by hygiene fix is dropped — the
--     display reads jwt_claims->>'email', already captured; that risky ::uuid cast is
--     out of scope). P2b (inbound app_source='jobber' + x-actor-name on a dedicated
--     per-write client) is GATED — see the spec.
-- The 'jobber' branch renders request_context->>'actor_name' when present (inert
-- until P2b populates it) so no further get_record_history change is needed for P2b.
-- ============================================================================

-- (1) Seed the two real logins -> their employee rows so names resolve (full_name is
--     UNIQUE; only-if-empty; idempotent). Until a person's login email matches an
--     employees.email, their edits show the login email (fallback).
UPDATE public.employees SET email = 'fred@ayache.com'
  WHERE full_name = 'Fred'    AND COALESCE(email, '') = '';
UPDATE public.employees SET email = 'yannick@ayache.com'
  WHERE full_name = 'Yannick' AND COALESCE(email, '') = '';

-- (2) get_record_history with person + Jobber attribution -------------------
CREATE OR REPLACE FUNCTION public.get_record_history(p_table text, p_record_id text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hide_system boolean DEFAULT true, p_limit integer DEFAULT 50, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(entry_id bigint, changed_at timestamp with time zone, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF p_table NOT IN ('visits','clients','derm_manifests') THEN
    RAISE EXCEPTION 'get_record_history: table % is not allowed', p_table;
  END IF;
  IF p_record_id IS NULL OR p_record_id = '' THEN
    RAISE EXCEPTION 'get_record_history: p_record_id is required';
  END IF;

  RETURN QUERY
  WITH src AS (
    SELECT l.id, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source,
           -- scalars only (never raw jwt_claims / request_context -> PII / anon-exposed fn)
           (l.jwt_claims->>'email')        AS actor_email,
           (l.request_context->>'actor_name') AS actor_name_ctx
    FROM audit.logs l
    WHERE l.table_name = p_table
      AND l.record_pk->>'id' = p_record_id
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      AND (NOT p_hide_system
           OR l.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review'))
      -- drop UPDATEs with no surfaced field change (e.g. line_items_rev-only bumps);
      -- keep INSERT/DELETE and soft-deletes (deleted_at transition)
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = p_table
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
      -- human apps: resolve the logged-in person. employee name -> login email ->
      -- bare app label. Shared unclogme@ login -> no by-line (not a single human).
      WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
        THEN 'Edited in ' || pg_catalog.initcap(pg_catalog.replace(s.app_source, '-', ' '))
          || COALESCE(
               ' by ' || (SELECT e.full_name FROM public.employees e
                          WHERE pg_catalog.lower(e.email) = pg_catalog.lower(s.actor_email)
                            AND COALESCE(e.email,'') <> ''
                          ORDER BY e.id LIMIT 1),
               CASE WHEN COALESCE(s.actor_email,'') <> ''
                         AND s.actor_email <> 'unclogme@unclogme.com'
                    THEN ' by ' || s.actor_email ELSE '' END
             )
      -- Jobber-originated change (gate-#4 adopt today; inbound poll after P2b).
      WHEN s.app_source = 'jobber'
        THEN 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
      WHEN s.app_source LIKE 'system:%' OR s.app_source = 'jobber-reconcile'
           OR s.app_source LIKE '%-cron' OR s.app_source = 'service-agreement-cron'
        THEN 'System (Jobber sync)'
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
      WHEN s.operation = 'INSERT' THEN 'created'
      WHEN s.operation = 'DELETE' THEN 'deleted'
      WHEN (s.old_row->>'deleted_at') IS NULL AND (s.new_row->>'deleted_at') IS NOT NULL THEN 'deleted'
      ELSE 'updated'
    END AS operation,
    COALESCE((
      SELECT pg_catalog.jsonb_agg(
               pg_catalog.jsonb_build_object(
                 'field', c.column_name,
                 'label', c.label,
                 'old',   audit.render_value(s.old_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col),
                 'new',   audit.render_value(s.new_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col)
               ) ORDER BY c.sort_order, c.column_name)
      FROM audit.entity_render_config c
      WHERE c.table_name = p_table
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$;

NOTIFY pgrst, 'reload schema';
