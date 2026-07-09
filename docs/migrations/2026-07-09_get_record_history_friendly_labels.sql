-- 2026-07-09_get_record_history_friendly_labels.sql
-- Activity-feed attribution: make the `actor_label` in ops/public.get_record_history
-- informative instead of a bare "System" (Fred, 2026-07-09).
--
-- Automated writers (app_source without an app/jobber value) now read as:
--   %reconcile% / %drift% / jobber-daily% / jobber-reconcile → "Auto-synced to match Jobber"
--   service-agreement-cron / sa-% / %recurring%              → "Recurring-visit scheduler"
--   %backfill% / %correction% / %-fix / %-repair             → "Data correction"
--   %-cron / system:%                                        → "Scheduled job"
--   sql / other:% / null / anything else                     → "Automated update"
-- Human app edits + raw `jobber` labels are unchanged. Pattern-based, so it auto-catches
-- new X-App-Source names the reconcile scripts set (Supabase 2 lane) with no re-coordination.
--
-- Also aligns `p_hide_system` to its documented intent: hide ONLY raw sql/other/null noise
-- (previously an explicit allow-list that would have hidden new meaningful sources).
--
-- Return shape UNCHANGED (same columns) → zero app impact; anon/authenticated EXECUTE preserved
-- (CREATE OR REPLACE keeps grants). AUDIT (ADR 010): N/A — read-only reporting function.
-- Backup of prior definition: backups/2026-07-09_get_record_history_before_friendly_labels.sql
-- ops.get_record_history is a thin wrapper over this; no change needed there.

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
      -- p_hide_system suppresses ONLY raw 'sql'/'other'/null noise. Everything with a
      -- meaningful app_source (human apps + every Jobber/cron/backfill source) is ALWAYS
      -- shown (aligns with the documented intent + auto-includes new X-App-Source names).
      AND (NOT p_hide_system
           OR NOT ( l.app_source IS NULL
                    OR l.app_source = 'sql'
                    OR l.app_source LIKE 'other:%' ))
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = l.table_name
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
      -- drop delete-all-reinsert churn on the child M:N tables (no-op within a txid)
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
      -- Human edits in one of our apps
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
      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN
        CASE
          WHEN s.operation = 'INSERT'
            THEN 'Created in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN (s.old_row->>'visit_status') IS DISTINCT FROM (s.new_row->>'visit_status')
               AND (s.new_row->>'visit_status') = 'completed'
            THEN 'Completed in Jobber' || COALESCE(' by ' || pg_catalog.btrim(pg_catalog.left(s.new_row->>'completed_by', 120)), '')
          ELSE 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
        END
      -- Automated nightly reconcile / drift-heal that pulls our DB into line with Jobber
      WHEN s.app_source LIKE '%reconcile%' OR s.app_source LIKE '%drift%'
           OR s.app_source LIKE 'jobber-daily%' OR s.app_source = 'jobber-reconcile'
        THEN 'Auto-synced to match Jobber'
      -- Automated recurring / service-agreement visit generation
      WHEN s.app_source = 'service-agreement-cron' OR s.app_source LIKE 'sa-%'
           OR s.app_source LIKE '%recurring%'
        THEN 'Recurring-visit scheduler'
      -- Automated data corrections / backfills / repairs
      WHEN s.app_source LIKE '%backfill%' OR s.app_source LIKE '%correction%'
           OR s.app_source LIKE '%-fix' OR s.app_source LIKE '%-repair'
        THEN 'Data correction'
      -- Other scheduled/system jobs
      WHEN s.app_source LIKE '%-cron' OR s.app_source LIKE 'system:%'
        THEN 'Scheduled job'
      -- Generic backend script (Management API / psql / uncategorized)
      ELSE 'Automated update'
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
$function$
