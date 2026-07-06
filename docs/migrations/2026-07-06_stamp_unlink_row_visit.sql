-- 2026-07-06_stamp_unlink_row_visit.sql
-- Stamp Studio: make "Link" a TOGGLE — click links, click again UNLINKS.
-- (Fred, 2026-07-06. Design + adversarial review workflow wf_6499e029-a06.)
--
--   * derm.unlink_row_visit(p_row_id, p_visit_id) — mirror of link_row_visit,
--     hard-DELETEs the single (matched_manifest_id, p_visit_id) pair.
--     - Same x-stamp-key gate (derm._require_stamp_key) + X-App-Source attribution.
--     - Manifest derived from p_row_id → the ONLY safety boundary: you can only
--       remove a link on the manifest THIS card depicts. Never "all visits".
--     - NO same-client guard (unlike link). Review blocker: 13 manifests hold
--       legitimate cross-client links (shared multi-client WWTP receipts) or
--       heuristic mis-links; a client guard would make those links un-removable
--       and Stamp Studio strictly weaker than DERM Tracker's own unlink. A DELETE
--       of an existing pair has no cross-client corruption risk (unlike INSERT).
--     - Idempotent (DELETE of an absent row = no-op). Also removes links to a
--       since-soft-deleted visit (stale-link cleanup) — no visit lookup needed.
--     - Returns was_last/remaining (POST-delete live count) so the UI trusts DB
--       truth for the orphan confirm, not a stale per-card view read (review:
--       multiple cards can depict one manifest → a UI pre-count can drift).
--   * derm.v_stamp_row_candidate_visits += manifest_linked_count (live count of
--     links on the row's manifest) so the UI can gate the last-link confirm on a
--     fresh value, re-fetched after every write.
--   * derm.v_orphan_manifests — the orphan safety net (Fred: "yes, add a monitor
--     view"): live manifests with ZERO linked visits, from ANY app. Surfaces the
--     15 that already exist + anything a future unlink empties.
--
-- HARD DELETE, not soft: manifest_visits is a thin 2-col junction (no deleted_at)
-- and is AUDITED — audit.log_change stores old_row on DELETE (verified: 78 prior
-- DELETEs all retain old_row), so history + the audit_pack chain-of-custody
-- survive; recovery is a re-INSERT. Matches DERM Tracker's useUnlinkVisit.
-- Audit Rule 8: no new tables (function + 2 views only).
-- CAVEAT: the last-link confirm is an APP-layer guard; it does NOT cover FK
-- ON DELETE CASCADE from a parent hard-delete (derm_manifests/visits) — those
-- already require Fred sign-off (Rule 6). The AFTER-DELETE audit trigger still
-- fires on cascade, so history is preserved either way.

BEGIN;

-- 1) The unlink RPC (parity with link_row_visit, minus the same-client guard).
CREATE OR REPLACE FUNCTION derm.unlink_row_visit(
  p_row_id bigint, p_visit_id bigint,
  OUT was_last boolean, OUT remaining int)
RETURNS record LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_mid bigint;
BEGIN
  PERFORM derm._require_stamp_key();                       -- same gate as link
  SELECT matched_manifest_id INTO v_mid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest — nothing to unlink', p_row_id;
  END IF;
  DELETE FROM public.manifest_visits                       -- hard delete, idempotent
   WHERE manifest_id = v_mid AND visit_id = p_visit_id;
  SELECT count(*) INTO remaining
    FROM public.manifest_visits WHERE manifest_id = v_mid;
  was_last := (remaining = 0);
END $$;
GRANT EXECUTE ON FUNCTION derm.unlink_row_visit(bigint, bigint) TO anon, authenticated;

-- 2) Candidate view: append manifest_linked_count (fresh per-manifest live count).
--    Same leading columns/order (CREATE OR REPLACE safe); new column appended.
CREATE OR REPLACE VIEW derm.v_stamp_row_candidate_visits AS
SELECT DISTINCT ON (row_id, visit_id)
       row_id, visit_id, visit_date, service_type, assigned_driver_id,
       driver_name, already_linked, visit_title, service_kind,
       (SELECT count(*) FROM public.manifest_visits mvc WHERE mvc.manifest_id = u.mid)::int
         AS manifest_linked_count
FROM (
  SELECT r.id AS row_id, r.matched_manifest_id AS mid, v.id AS visit_id, v.visit_date,
         v.service_type, v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id) AS driver_name,
         EXISTS (SELECT 1 FROM public.manifest_visits mv
                  WHERE mv.manifest_id = r.matched_manifest_id AND mv.visit_id = v.id) AS already_linked,
         coalesce(nullif(btrim(j.title), ''),
                  nullif(substring(v.title from ' - (.*)$'), ''),
                  v.title) AS visit_title,
         CASE
           WHEN lower(coalesce(j.title, v.title, '')) ~ '(service call|emergency)' THEN 'SC'
           WHEN (SELECT count(*) FROM public.visits v2
                  WHERE v2.job_id = v.job_id AND v.job_id IS NOT NULL) > 1
             OR lower(coalesce(j.title, v.title, '')) ~ '(grease|grey water|service agreement)'
           THEN 'SA'
           ELSE 'SC'
         END AS service_kind
  FROM derm.address_row_map r
  JOIN public.derm_manifests m ON m.id = r.matched_manifest_id
  JOIN public.visits v ON v.client_id = r.matched_client_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.visit_date BETWEEN m.service_date - INTERVAL '14 days' AND m.service_date + INTERVAL '14 days'
  LEFT JOIN public.jobs j ON j.id = v.job_id
  WHERE r.matched_client_id IS NOT NULL
  UNION ALL
  -- already-linked visits on this row's manifest (any date, ANY client — so a
  -- cross-client or out-of-window link still shows and can be unlinked)
  SELECT r.id, r.matched_manifest_id, v.id, v.visit_date, v.service_type, v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id),
         true,
         coalesce(nullif(btrim(j.title), ''),
                  nullif(substring(v.title from ' - (.*)$'), ''),
                  v.title),
         CASE
           WHEN lower(coalesce(j.title, v.title, '')) ~ '(service call|emergency)' THEN 'SC'
           WHEN (SELECT count(*) FROM public.visits v2
                  WHERE v2.job_id = v.job_id AND v.job_id IS NOT NULL) > 1
             OR lower(coalesce(j.title, v.title, '')) ~ '(grease|grey water|service agreement)'
           THEN 'SA'
           ELSE 'SC'
         END
  FROM derm.address_row_map r
  JOIN public.manifest_visits mv ON mv.manifest_id = r.matched_manifest_id
  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
  LEFT JOIN public.jobs j ON j.id = v.job_id
  WHERE r.matched_client_id IS NOT NULL
) u
ORDER BY row_id, visit_id, already_linked DESC;
GRANT SELECT ON derm.v_stamp_row_candidate_visits TO anon, authenticated;

-- 3) Orphan monitor: live manifests with zero linked visits (from any app).
CREATE OR REPLACE VIEW derm.v_orphan_manifests AS
SELECT m.id AS manifest_id,
       m.white_manifest_number,
       m.service_date,
       m.client_id,
       c.client_code,
       c.name AS client_name,
       lu.last_unlinked_at,
       lu.last_unlinked_by
FROM public.derm_manifests m
LEFT JOIN public.clients c ON c.id = m.client_id
LEFT JOIN LATERAL (
  SELECT l.changed_at AS last_unlinked_at, l.app_source AS last_unlinked_by
  FROM audit.logs l
  WHERE l.table_schema = 'public' AND l.table_name = 'manifest_visits'
    AND l.operation = 'DELETE'
    AND (l.old_row->>'manifest_id') = m.id::text
  ORDER BY l.changed_at DESC LIMIT 1
) lu ON true
WHERE m.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id);
GRANT SELECT ON derm.v_orphan_manifests TO anon, authenticated;

COMMIT;
