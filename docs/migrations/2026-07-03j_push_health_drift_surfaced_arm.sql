-- Migration: 2026-07-03j_push_health_drift_surfaced_arm.sql
-- Author: Claude (Supabase session)
-- The Gate #4 drift reconciler SURFACEs human Jobber edits (post 152-DAV fix) but only into
-- sync_log details JSON, which nothing reads — 10 conflicts sat unread for days, re-logged every
-- 30 min. New 'drift_surfaced' arm on ops.v_calendar_push_health reads the LATEST reconciler run's
-- surfaced_visits list (auto-clears once a run reports none), joined to live scheduled visits.
-- Companion data op (same cycle): adopted Jobber->DB for the 9 surfaced weekend visits
-- (Fred decision, 152-DAV precedent; backup backups/2026-07-03_drift_surface_adopt_backup.json).
CREATE OR REPLACE VIEW ops.v_calendar_push_health AS SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'push_failed'::text AS issue,
    f.reason,
    f.detail,
    f.created_at AS since
   FROM visit_sync_flags f
     JOIN visits v ON v.id = f.visit_id
     JOIN clients c ON c.id = v.client_id
  WHERE f.resolved_at IS NULL AND v.deleted_at IS NULL
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'not_in_jobber'::text AS issue,
    NULL::text AS reason,
    NULL::text AS detail,
    v.created_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE (v.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])) AND v.visit_status = 'scheduled'::text AND v.deleted_at IS NULL AND v.created_at < (now() - '00:15:00'::interval) AND fn_visit_in_jobber_scope(v.id) AND NOT (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'skip_removal_failed'::text AS issue,
    'skipped visit still linked to Jobber (removal did not complete)'::text AS reason,
    v.sync_state AS detail,
    v.updated_at AS since
   FROM visits v
     JOIN clients c ON c.id = v.client_id
  WHERE v.visit_status = 'skipped'::text AND v.deleted_at IS NULL AND (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE e.entity_type = 'visit'::text AND e.source_system = 'jobber'::text AND e.entity_id = v.id))
UNION ALL
 SELECT v.id AS visit_id, c.client_code, c.name AS client_name, v.visit_date, v.source,
    'drift_surfaced'::text AS issue,
    (sv.sv ->> 'reason'::text) AS reason,
    'DB schedule disagrees with a human Jobber edit - reconciler SURFACEd it; decide adopt-from-Jobber vs re-push (see project_gate4_drift_watchdog)'::text AS detail,
    sl.started_at AS since
   FROM ( SELECT sync_log.started_at, sync_log.details
           FROM sync_log
          WHERE sync_log.sync_source = 'jobber_visit_drift'::text AND sync_log.details ? 'surfaced_visits'::text
          ORDER BY sync_log.started_at DESC
         LIMIT 1) sl
     CROSS JOIN LATERAL jsonb_array_elements(sl.details -> 'surfaced_visits'::text) sv(sv)
     JOIN visits v ON v.id = ((sv.sv ->> 'id'::text))::bigint AND v.deleted_at IS NULL AND v.visit_status = 'scheduled'::text
     JOIN clients c ON c.id = v.client_id;