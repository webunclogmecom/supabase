-- ============================================================================
-- 2026-06-26_audit_attribution_completeness.sql
-- ADR 010/016: read-layer + render-config only (no business table/column change).
-- ----------------------------------------------------------------------------
-- Activity-tab attribution COMPLETENESS pass. The "who did it / when" + "from
-- Jobber" model is sound, but an audit found Calendar edits that never SURFACE:
--   * SOFT-DELETE rendered operation='deleted' with an EMPTY changes array
--     (deleted_at absent from entity_render_config) -> contentless entry.
--   * TEAM edits (visit_team) and MANHOLE/location edits (visit_locations) are
--     written to CHILD tables (already audited, correctly attributed) but
--     get_record_history only ever read table_name='visits', so a crew add/remove
--     or a manhole change was INVISIBLE in the visit's Activity.
--
-- This migration (additive, no hot-write-path change):
--   (A) entity_render_config: add the visits.deleted_at render row + render rows
--       for the two child tables (visit_team.employee_id, visit_locations.
--       client_location_id) so their audit rows render a human-readable value.
--   (B) get_record_history: when p_table='visits', ALSO surface the same-visit
--       child audit rows from visit_team + visit_locations (keyed on visit_id),
--       rendered as added/removed crew + service-location changes, attributed by
--       the child row's OWN app_source/email (so a Calendar team edit = "Edited in
--       Visit Calendar by <person>", a Jobber/admin-review edit keeps its source).
--       A txid-level dedupe drops the delete-all-reinsert churn (a member/location
--       deleted AND re-inserted unchanged in one transaction = no-op, hidden), so
--       only NET adds/removes show.
--
-- NOT in this migration (deliberately deferred — see migration header note):
--   * line_items auditing. handleVisit delete-all-reinserts visit line_items on
--     EVERY inbound poll (webhook-jobber index.ts L691), so a naive audit trigger
--     would flood audit.logs. Surfacing line-item edits needs handleVisit made
--     change-conditional FIRST; tracked as a follow-up.
--
-- Everything else (allowlist visits/clients/derm_manifests, p_hide_system
-- semantics, cursor pagination, the 8-col signature, actor_label CASE, grants,
-- SET search_path='') is BYTE-PRESERVED from the live function.
-- ============================================================================

-- (A) render config -----------------------------------------------------------
-- Idempotent: clear the three rows we own here, then insert.
DELETE FROM audit.entity_render_config
 WHERE (table_name, column_name) IN (
   ('visits','deleted_at'),
   ('visit_team','employee_id'),
   ('visit_locations','client_location_id')
 );

INSERT INTO audit.entity_render_config
  (table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order)
VALUES
  ('visits',          'deleted_at',         'Deleted',          'datetime', NULL,               NULL,        160),
  ('visit_team',      'employee_id',        'Crew member',      'fk',       'employees',        'full_name', 10),
  ('visit_locations', 'client_location_id', 'Service location', 'fk',       'client_locations', 'name',      10);

-- (B) get_record_history — surface same-visit child-table changes --------------
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
    SELECT l.id, l.table_name, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source,
           (l.jwt_claims->>'email')        AS actor_email,
           (l.request_context->>'actor_name') AS actor_name_ctx
    FROM audit.logs l
    WHERE (
            (l.table_name = p_table AND l.record_pk->>'id' = p_record_id)
            -- same-visit child-table changes (already-audited M:N tables)
            OR ( p_table = 'visits'
                 AND l.table_name IN ('visit_team','visit_locations')
                 AND COALESCE(l.new_row, l.old_row)->>'visit_id' = p_record_id )
          )
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      AND (NOT p_hide_system
           OR l.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review'))
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = l.table_name
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
      -- drop delete-all-reinsert churn on the child M:N tables: a row deleted AND
      -- re-inserted unchanged within one transaction is a no-op -> hide both.
      AND NOT (
            l.table_name IN ('visit_team','visit_locations')
            AND l.operation IN ('INSERT','DELETE')
            AND EXISTS (
              SELECT 1 FROM audit.logs l2
              WHERE l2.table_name = l.table_name
                AND l2.txid = l.txid
                AND l2.operation IN ('INSERT','DELETE')
                AND l2.operation <> l.operation
                AND (COALESCE(l2.new_row, l2.old_row) - 'created_at')
                  = (COALESCE(l.new_row,  l.old_row)  - 'created_at')
            )
          )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
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
      WHEN s.app_source = 'jobber' THEN
        CASE
          WHEN s.operation = 'INSERT'
            THEN 'Created in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN (s.old_row->>'visit_status') IS DISTINCT FROM (s.new_row->>'visit_status')
               AND (s.new_row->>'visit_status') = 'completed'
            THEN 'Completed in Jobber' || COALESCE(' by ' || pg_catalog.btrim(pg_catalog.left(s.new_row->>'completed_by', 120)), '')
          ELSE 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
        END
      WHEN s.app_source LIKE 'system:%' OR s.app_source = 'jobber-reconcile'
           OR s.app_source LIKE '%-cron' OR s.app_source = 'service-agreement-cron'
        THEN 'System (Jobber sync)'
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
      WHEN s.table_name <> p_table
        THEN CASE s.operation WHEN 'INSERT' THEN 'added' WHEN 'DELETE' THEN 'removed' ELSE 'updated' END
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
      WHERE c.table_name = s.table_name
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$;

NOTIFY pgrst, 'reload schema';
