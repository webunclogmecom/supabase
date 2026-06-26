-- ============================================================================
-- 2026-06-26b_audit_jobber_always_on_and_seeds.sql
-- ADR 010/016: read-layer + employee email seed (no business table/column change).
-- ----------------------------------------------------------------------------
-- Two requests from Fred (2026-06-26):
--   1. "Show Jobber sync ALWAYS on" — Jobber-originated changes must ALWAYS be
--      visible in the Activity tab, never hidden by the p_hide_system toggle.
--      get_record_history: the p_hide_system=true branch now ALSO admits every
--      Jobber-origin source (jobber / jobber-reconcile / *-cron /
--      service-agreement-cron / system:*), so "hide system" only ever suppresses
--      the raw 'sql'/'other:%' background noise — Jobber sync is always shown.
--      (The Calendar UI toggle becomes redundant for Jobber and is being removed.)
--   2. Seed Diego's Calendar login -> his name. Diego's login email is
--      contact@unclogme.com (per Fred). employees.email is matched
--      case-insensitively to the JWT email, so seeding it makes Diego's Calendar
--      edits/completions render "Edited in Visit Calendar by Diego ...".
--
-- Forward note (Aaron / Grecia / Mark): when each starts using the Calendar,
-- seed public.employees.email = their real login email; if their personal email
-- isn't name-clear, create an alias like aaron@unclogme.com and seed that. Mark
-- (id35) already has marknoltion872@gmail.com seeded but no matching login yet.
-- Do NOT route a real operator through the shared unclogme@unclogme.com login
-- (it is excluded from attribution by design).
--
-- Everything else in get_record_history (child-table surfacing from
-- 2026-06-26_audit_attribution_completeness.sql, allowlist, cursor, labels,
-- 8-col signature, SET search_path='') is preserved verbatim.
-- ============================================================================

-- 2. Seed the ACTIVE crew Diego (ops.v_calendar_driver), NOT the INACTIVE former
--    "Diego Martin Sarachaga". Idempotent: clears any stale assignment of this
--    login on another/inactive row first, then seeds the active Diego.
DO $$
DECLARE v_diego bigint;
BEGIN
  SELECT id INTO v_diego FROM public.employees
   WHERE full_name ILIKE 'Diego%' AND status = 'ACTIVE' ORDER BY id LIMIT 1;
  IF v_diego IS NULL THEN
    RAISE NOTICE 'No ACTIVE Diego found — skipping seed';
  ELSE
    UPDATE public.employees SET email = NULL
      WHERE lower(email) = lower('contact@unclogme.com') AND id <> v_diego;
    UPDATE public.employees SET email = 'contact@unclogme.com'
      WHERE id = v_diego AND COALESCE(email,'') = '';
    RAISE NOTICE 'Seeded crew Diego (id %) email=contact@unclogme.com', v_diego;
  END IF;
END $$;

-- 1. get_record_history — Jobber sync always visible -------------------------
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
      -- p_hide_system suppresses ONLY raw 'sql'/'other' noise. Human-app edits AND
      -- every Jobber-origin sync source are ALWAYS shown ("show Jobber sync always on").
      AND (NOT p_hide_system
           OR l.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
           OR l.app_source = 'jobber'
           OR l.app_source = 'jobber-reconcile'
           OR l.app_source = 'service-agreement-cron'
           OR l.app_source LIKE '%-cron'
           OR l.app_source LIKE 'system:%')
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
