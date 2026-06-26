-- ============================================================================
-- 2026-06-26_visit_last_schedule_edit.sql
-- ADR 010: read-only SECURITY DEFINER over audit.logs; audit OPT-OUT.
-- ----------------------------------------------------------------------------
-- Gate #4 heal SAFETY discriminator. Returns the most recent OUR-side schedule
-- edit for a visit (an audit.logs UPDATE that changed visit_date), so the drift
-- watchdog can tell a failed-our-push from a Jobber-side edit:
--
--   heal (push DB->Jobber) ONLY when the audit shows WE set the current DB date
--   AND Jobber still holds the exact PRE-edit value -> our push simply didn't
--   land. Any other Jobber value (a deliberate Jobber-side move by a driver/Diego)
--   does NOT match and is surfaced for review, never reverted. ("Calendar is
--   master, but drivers/Diego use Jobber" — Fred, 2026-06-26.)
--
-- audit.logs.record_pk is a jsonb object {"id": <visit_id>}; visit_date lives in
-- old_row/new_row as text 'YYYY-MM-DD'.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.visit_last_schedule_edit(p_visit_id bigint)
RETURNS TABLE(old_date text, new_date text, changed_at timestamptz, app_source text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'audit'
AS $function$
  SELECT l.old_row->>'visit_date', l.new_row->>'visit_date', l.changed_at, l.app_source
  FROM audit.logs l
  WHERE l.table_name = 'visits'
    AND (l.record_pk->>'id') = p_visit_id::text
    AND l.operation = 'UPDATE'
    AND (l.new_row->>'visit_date') IS DISTINCT FROM (l.old_row->>'visit_date')
  ORDER BY l.changed_at DESC
  LIMIT 1;
$function$;

REVOKE ALL  ON FUNCTION public.visit_last_schedule_edit(bigint) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.visit_last_schedule_edit(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';
