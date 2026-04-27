-- ============================================================================
-- audit_fixes_2026_04_27.sql — apply HIGH-priority findings from AUDIT_2026-04-27
-- ============================================================================
-- Two unrelated fixes batched here:
--   §1.3 — 5 of 8 ops.* views still SECURITY DEFINER (Supabase scanner missed
--          them because it only checks public.*). Same vulnerability class as
--          the public views fixed in 9388819 — they bypass RLS on underlying
--          tables. Flip to security_invoker so they respect the caller's role.
--   §2.4 — 10 FK columns have no supporting index. Postgres scans the parent
--          table on every JOIN/DELETE check. Adding btree indexes eliminates
--          the scan and protects against cascade-delete cliffs.
--
-- Idempotent: ALTER VIEW SET reloption is a no-op when already set.
-- CREATE INDEX IF NOT EXISTS is no-op when already exists.
-- ============================================================================

-- ---- §1.3 — flip 5 ops.* views to security_invoker ----------------------------
ALTER VIEW ops.v_ar_aging          SET (security_invoker = true);
ALTER VIEW ops.v_revenue_summary   SET (security_invoker = true);
ALTER VIEW ops.v_route_today       SET (security_invoker = true);
ALTER VIEW ops.v_service_due       SET (security_invoker = true);
ALTER VIEW ops.v_truck_utilization SET (security_invoker = true);

-- ---- §2.4 — index FK columns that have no supporting index --------------------
CREATE INDEX IF NOT EXISTS idx_visits_property              ON public.visits (property_id);
CREATE INDEX IF NOT EXISTS idx_quotes_property              ON public.quotes (property_id);
CREATE INDEX IF NOT EXISTS idx_routes_employee              ON public.routes (employee_id);
CREATE INDEX IF NOT EXISTS idx_routes_vehicle               ON public.routes (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_route_stops_client           ON public.route_stops (client_id);
CREATE INDEX IF NOT EXISTS idx_route_stops_property         ON public.route_stops (property_id);
CREATE INDEX IF NOT EXISTS idx_photos_uploaded_by           ON public.photos (uploaded_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_notes_author                 ON public.notes (author_employee_id);
CREATE INDEX IF NOT EXISTS idx_notes_job                    ON public.notes (job_id);
CREATE INDEX IF NOT EXISTS idx_jobber_oversized_visit       ON public.jobber_oversized_attachments (visit_id);

-- ---- Verification -------------------------------------------------------------
DO $$
DECLARE
  bad_views text;
  fk_no_idx int;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad_views
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'ops'
    AND c.relkind = 'v'
    AND COALESCE((SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'security_invoker'), 'false') = 'false';

  IF bad_views IS NOT NULL THEN
    RAISE WARNING 'ops views still on SECURITY DEFINER: %', bad_views;
  ELSE
    RAISE NOTICE 'All ops views now use security_invoker.';
  END IF;

  SELECT count(*)::int
  INTO fk_no_idx
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
  WHERE c.contype = 'f'
    AND c.connamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND a.attnum = ANY(i.indkey)
        AND i.indkey[0] = a.attnum
    );

  IF fk_no_idx > 0 THEN
    RAISE WARNING '% FK columns still without supporting index', fk_no_idx;
  ELSE
    RAISE NOTICE 'All FK columns have supporting indexes.';
  END IF;
END $$;
