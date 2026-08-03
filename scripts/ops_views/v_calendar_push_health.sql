-- ============================================================================
-- ops.v_calendar_push_health — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_calendar_push_health AS
SELECT v.id AS visit_id,
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
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'drift_surfaced'::text AS issue,
    sv.sv ->> 'reason'::text AS reason,
        CASE sv.sv ->> 'reason'::text
            WHEN 'jobber_date_differs'::text THEN ('Jobber has this visit on a different day ('::text || COALESCE(sv.sv ->> 'jobber_date'::text, '?'::text)) || ') than we do. Decide which is right - syncing from Jobber will move the visit.'::text
            WHEN 'jobber_all_day_vs_our_time'::text THEN 'Same day in both, but Jobber has no set time (all-day) while we have one. Syncing from Jobber will clear the time.'::text
            WHEN 'jobber_time_differs'::text THEN 'Same day in both, but the times differ. Syncing from Jobber will use Jobber''s time.'::text
            WHEN 'audit_read_fail'::text THEN 'We could not read this visit''s edit history, so the difference was not classified. It is re-checked every run.'::text
            ELSE 'Our schedule and Jobber''s disagree and the reconciler could not resolve it safely.'::text
        END AS detail,
    onset.first_seen AS since
   FROM ( SELECT sync_log.started_at,
            sync_log.details
           FROM sync_log
          WHERE sync_log.sync_source = 'jobber_visit_drift'::text AND sync_log.details ? 'surfaced_visits'::text
          ORDER BY sync_log.started_at DESC
         LIMIT 1) sl
     CROSS JOIN LATERAL jsonb_array_elements(sl.details -> 'surfaced_visits'::text) sv(sv)
     JOIN visits v ON v.id = ((sv.sv ->> 'id'::text)::bigint) AND v.deleted_at IS NULL AND v.visit_status = 'scheduled'::text
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN LATERAL ( SELECT min(r.started_at) AS first_seen
           FROM sync_log r
          WHERE r.sync_source = 'jobber_visit_drift'::text AND r.details ? 'surfaced_visits'::text AND (EXISTS ( SELECT 1
                   FROM jsonb_array_elements(r.details -> 'surfaced_visits'::text) e(value)
                  WHERE ((e.value ->> 'id'::text)::bigint) = v.id)) AND r.started_at > COALESCE(( SELECT max(r2.started_at) AS max
                   FROM sync_log r2
                  WHERE r2.sync_source = 'jobber_visit_drift'::text AND r2.details ? 'surfaced_visits'::text AND NOT (EXISTS ( SELECT 1
                           FROM jsonb_array_elements(r2.details -> 'surfaced_visits'::text) e2(value)
                          WHERE ((e2.value ->> 'id'::text)::bigint) = v.id))), '-infinity'::timestamp with time zone)) onset ON true;
