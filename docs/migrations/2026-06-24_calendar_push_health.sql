-- 2026-06-24  Calendar -> Jobber push completeness probe (audit follow-up #4)
-- ============================================================================================
-- WHY: the Calendar/SA-cron -> Jobber push is fire-and-forget (trigger -> pg_net -> jobber-push-visit).
-- A failed push (no job match, Jobber API error/down) leaves a visit silently NOT in Jobber: the form
-- shows success, the only trace is a public.visit_sync_flags row (written by jobber-push-visit on
-- failure). This surfaces both signals so ops (and a future Calendar "sync pending" icon) can see and
-- re-push. NOT a retry queue — just visibility (per the audit). Currently healthy: 0 flags, 0 orphans.
-- AUDIT (ADR 010): view + function + cron only. No table/data change.
-- ============================================================================================

-- Surface: (a) explicit unresolved push failures, (b) calendar/cron SCHEDULED visits that never got a
-- Jobber link (re-pushable orphans), with a 15-min grace so a just-created visit's async push can land.
CREATE OR REPLACE VIEW ops.v_calendar_push_health AS
  SELECT v.id AS visit_id, c.client_code, c.name AS client_name, v.visit_date, v.source,
         'push_failed'::text AS issue, f.reason, f.detail, f.created_at AS since
  FROM public.visit_sync_flags f
  JOIN public.visits v ON v.id = f.visit_id
  JOIN public.clients c ON c.id = v.client_id
  WHERE f.resolved_at IS NULL AND v.deleted_at IS NULL
UNION ALL
  SELECT v.id, c.client_code, c.name, v.visit_date, v.source,
         'not_in_jobber'::text AS issue, NULL::text, NULL::text, v.created_at
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE v.source IN ('visit-calendar','supabase_cron')
    AND v.visit_status = 'scheduled'
    AND v.deleted_at IS NULL
    AND v.created_at < now() - interval '15 minutes'
    AND NOT EXISTS (SELECT 1 FROM public.entity_source_links e
                     WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id=v.id);

GRANT SELECT ON ops.v_calendar_push_health TO anon, authenticated, service_role;

-- Nightly logger: write the count + items to sync_log so the backlog is visible/trendable (and a
-- watchdog can alert when status='attention'). Returns the count.
CREATE OR REPLACE FUNCTION public.log_calendar_push_health()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE n integer; det jsonb;
BEGIN
  SELECT count(*),
         COALESCE(jsonb_agg(jsonb_build_object('visit_id', visit_id, 'client', client_code,
                                               'issue', issue, 'reason', reason)), '[]'::jsonb)
    INTO n, det
  FROM ops.v_calendar_push_health;

  INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  VALUES ('calendar-push-health', now(), now(), COALESCE(n,0),
          CASE WHEN COALESCE(n,0) > 0 THEN 'attention' ELSE 'ok' END,
          jsonb_build_object('count', COALESCE(n,0), 'items', det));
  RETURN COALESCE(n,0);
END;
$$;

-- Nightly at ~3:30am ET (after derm-required-rederive at 3:20).
SELECT cron.schedule('calendar-push-health-check', '30 7 * * *',
  $$SELECT public.log_calendar_push_health();$$);
