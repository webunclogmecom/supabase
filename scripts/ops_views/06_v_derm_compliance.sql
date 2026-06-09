-- ============================================================================
-- ops.v_derm_compliance — per-client DERM filing compliance status
-- ----------------------------------------------------------------------------
-- RESYNCED 2026-06-09 to the LIVE view definition. This file previously held a
-- stale, NEVER-APPLIED "ready-to-file + risk" draft that used
--   v.visit_status = 'COMPLETED'   (UPPERCASE — matches 0 rows; canonical is the
--                                   lowercase 'completed')
-- and truncated columns white_manifest_num / yellow_ticket_num, which do NOT exist
-- on derm_manifests (the real column is white_manifest_number) — so that draft would
-- have ERRORED on apply. It was a landmine, not the live view.
--
-- The LIVE view was correctly redefined by migrations:
--   * 2026-05-23c_ops_views_completed_casing_fix.sql  (the 'COMPLETED'->'completed' fix)
--   * 2026-05-25t_rewire_views_from_gdos.sql           (permit_number/expiration from gdos)
-- and is verified correct (reports risk: 54 overdue/violation/no-record clients,
-- 318 missing manifests as of 2026-06-09). This file now matches that live def.
--
-- Shape: one row per ACTIVE/RECURRING client with a GT service_config.
--   missing_manifest_count = completed GT visits in the last 120 days that have NO
--     same-day derm_manifest for that client (service happened, no paperwork).
--   compliance_status = no_service_record | derm_violation (>90d) | overdue
--     (> frequency_days) | due_soon (within 14d of frequency) | compliant.
-- Pending (CLAUDE.md soft-delete list): add `AND v.deleted_at IS NULL` to the
-- unmatched_visits CTE — must be applied to the LIVE view + here together.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH last_manifest AS (
  SELECT derm_manifests.client_id,
         max(derm_manifests.service_date) AS last_manifest_date,
         count(*)                         AS total_manifests
    FROM derm_manifests
   GROUP BY derm_manifests.client_id
),
unmatched_visits AS (
  SELECT v.client_id,
         count(*) AS missing_manifests
    FROM visits v
   WHERE v.service_type = 'GT'::text
     AND v.visit_status = 'completed'::text
     AND v.visit_date >= (CURRENT_DATE - '120 days'::interval)
     AND NOT (EXISTS (
       SELECT 1
         FROM derm_manifests dm
        WHERE dm.client_id = v.client_id
          AND dm.service_date = v.visit_date))
   GROUP BY v.client_id
)
SELECT c.id,
       c.client_code,
       c.name   AS client_name,
       c.status AS client_status,
       p.zone,
       p.address,
       p.city,
       p.county,
       cc.name  AS contact_name,
       cc.email,
       cc.phone,
       (SELECT g.gdo_number
          FROM gdos g
         WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
         ORDER BY g.id
         LIMIT 1) AS permit_number,
       (SELECT g.permit_expiration
          FROM gdos g
         WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
         ORDER BY g.id
         LIMIT 1) AS permit_expiration,
       sc.equipment_size_gallons,
       sc.frequency_days,
       lm.last_manifest_date,
       lm.total_manifests,
       COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
       CASE WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true ELSE false END AS has_missing_manifests,
       CURRENT_DATE - lm.last_manifest_date AS days_since_last_manifest,
       CASE
         WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'::text
         WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'::text
         WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'::text
         WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'::text
         ELSE 'compliant'::text
       END AS compliance_status
  FROM clients c
  JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'::text
  LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
  LEFT JOIN properties p      ON p.client_id  = c.id AND p.is_primary = true
  LEFT JOIN last_manifest lm  ON lm.client_id = c.id
  LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
 WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
 ORDER BY
   CASE
     WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
     WHEN lm.last_manifest_date IS NULL THEN 2
     WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
     WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
     ELSE 5
   END,
   COALESCE(uv.missing_manifests, 0::bigint) DESC,
   (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;
