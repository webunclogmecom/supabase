-- ============================================================================
-- ops.v_calendar_push_health_by_visit — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_calendar_push_health_by_visit AS
SELECT DISTINCT ON (h.visit_id) h.visit_id,
    h.client_code,
    h.client_name,
    h.visit_date,
    h.source,
    h.issue,
    h.reason,
    h.detail,
    h.since,
        CASE
            WHEN h.issue = 'drift_surfaced'::text THEN NULL::bigint
            ELSE fn_visit_push_duplicate_of(h.visit_id)
        END AS duplicate_of_visit_id,
    COALESCE(f.attempts, 0) AS attempts,
    f.auto_retry_state,
    f.next_attempt_at,
    ( SELECT array_agg(DISTINCT h2.issue) AS array_agg
           FROM ops.v_calendar_push_health h2
          WHERE h2.visit_id = h.visit_id) AS all_issues,
    h.issue = ANY (ARRAY['not_in_jobber'::text, 'push_failed'::text]) AS is_auto_retryable
   FROM ops.v_calendar_push_health h
     LEFT JOIN visit_sync_flags f ON f.visit_id = h.visit_id AND f.resolved_at IS NULL
  ORDER BY h.visit_id, (
        CASE h.issue
            WHEN 'push_failed'::text THEN 1
            WHEN 'skip_removal_failed'::text THEN 2
            WHEN 'not_in_jobber'::text THEN 3
            WHEN 'drift_surfaced'::text THEN 4
            ELSE 5
        END);
