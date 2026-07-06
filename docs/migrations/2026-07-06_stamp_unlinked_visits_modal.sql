-- 2026-07-06_stamp_unlinked_visits_modal.sql
-- Stamp Studio: after "+ Add client" adds a roster client, a modal lists that
-- client's completed visits BEFORE the sheet's dump date that are NOT linked to
-- ANY manifest — as data cards to link the right one immediately (Fred).
--
--   * derm.v_stamp_unlinked_visits — per-visit card data, keyed by client_id so
--     the modal filters `?client_id=eq.X&visit_date=lte.<dump_date>`. Source =
--     public.manifest_pickable_visits (already: completed + derm-required
--     COALESCE(true) + not-deleted + NOT linked to any live manifest) enriched
--     with the same cleaned-title / SA-SC / driver expressions as
--     v_stamp_row_candidate_visits, plus a line_items summary (matched on
--     visit_id OR job-scoped fallback — 92% of pickable visits only have
--     job-scoped items; fee lines excluded).
--   * v_stamp_sheets += dump_date = max(dump_ticket_date) fallback
--     max(service_date) over the sheet's live manifests — the app's existing
--     `service_date` (min service_date) understates it (827989: shows 06-11,
--     real dump 06-21). Appended (CREATE OR REPLACE safe). The modal filters
--     visits with visit_date <= dump_date (lte — same-day dumps are normal).
--
-- Read-only views; audit N/A. Note: usually 0-1 cards (backlog is small) — the
-- modal's empty state matters. Linking a chosen visit uses the existing
-- link_row_visit(row_id, visit_id) on the just-added row; if the added client
-- has no manifest on the sheet, that RPC raises "file it in DERM Tracker first"
-- (handled in the UI).

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_unlinked_visits AS
SELECT
  p.visit_id,
  p.client_id,
  p.client_code,
  p.client_name,
  p.visit_date,
  p.completed_at,
  p.service_type,
  CASE
    WHEN lower(coalesce(j.title, v.title, '')) ~ '(service call|emergency)' THEN 'SC'
    WHEN (SELECT count(*) FROM public.visits v2
           WHERE v2.job_id = v.job_id AND v.job_id IS NOT NULL) > 1
      OR lower(coalesce(j.title, v.title, '')) ~ '(grease|grey water|service agreement)'
    THEN 'SA'
    ELSE 'SC'
  END AS service_kind,
  coalesce(nullif(btrim(j.title), ''),
           nullif(substring(v.title from ' - (.*)$'), ''),
           v.title) AS visit_title,
  (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id) AS driver_name,
  (SELECT string_agg(li.name || CASE WHEN li.quantity <> 1 THEN ' ×' || li.quantity::int ELSE '' END, '; '
                     ORDER BY li.name)
     FROM public.line_items li
    WHERE (li.visit_id = v.id OR (li.visit_id IS NULL AND li.job_id = v.job_id))
      AND li.name !~* '(credit card fee|ach fee|processing fee|convenience fee)') AS line_items_summary,
  p.address,
  p.city,
  v.derm_required
FROM public.manifest_pickable_visits p
JOIN public.visits v ON v.id = p.visit_id
LEFT JOIN public.jobs j ON j.id = v.job_id;
GRANT SELECT ON derm.v_stamp_unlinked_visits TO anon, authenticated;

-- Append dump_date to v_stamp_sheets (existing column order preserved).
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 WITH agg AS (
         SELECT r.dump_folder,
            max(r.white_manifest_number) AS white_manifest_number,
            count(DISTINCT r.page) AS page_count,
            count(*) AS total_rows,
            count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched_rows,
            count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed_rows
           FROM derm.address_row_map r
          WHERE r.white_manifest_number IS NOT NULL
          GROUP BY r.dump_folder
        ), pages AS (
         SELECT d.dump_folder,
            array_agg(d.image_url ORDER BY d.page) AS page_image_urls
           FROM ( SELECT address_row_map.dump_folder,
                    address_row_map.page,
                    min(address_row_map.image_url) AS image_url
                   FROM derm.address_row_map
                  WHERE address_row_map.white_manifest_number IS NOT NULL
                  GROUP BY address_row_map.dump_folder, address_row_map.page) d
          GROUP BY d.dump_folder
        )
 SELECT a.dump_folder,
    a.white_manifest_number,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE m.white_manifest_number = a.white_manifest_number) AS service_date,
    a.page_count,
    p.page_image_urls,
    a.total_rows,
    a.matched_rows,
    a.placed_rows,
    COALESCE(s.completed, false) AS completed,
    s.completed_at,
    COALESCE(
      (SELECT max(m.dump_ticket_date) FROM derm_manifests m
        WHERE m.white_manifest_number = a.white_manifest_number AND m.deleted_at IS NULL),
      (SELECT max(m.service_date) FROM derm_manifests m
        WHERE m.white_manifest_number = a.white_manifest_number AND m.deleted_at IS NULL)
    ) AS dump_date
   FROM agg a
     LEFT JOIN pages p USING (dump_folder)
     LEFT JOIN derm.stamp_sheet_status s USING (dump_folder);
GRANT SELECT ON derm.v_stamp_sheets TO anon, authenticated;

COMMIT;
