-- 2026-05-19c_visits_derm_required.sql
--
-- Adds per-visit DERM exemption to support the "DERM not required" button
-- Yannick/Fred added to DERM Tracker on 2026-05-19. Some visits genuinely
-- don't need a manifest (CL, LS, or one-off GT exemptions) — without this
-- column the app shows them forever under "Missing Docs".
--
-- Semantics (3-state):
--   NULL  → use default: TRUE if service_type='GT', FALSE otherwise
--   TRUE  → ops marked "DERM required" explicitly
--   FALSE → ops marked "DERM not required" via the button
--
-- Audit opt-in per Rule 8: visits is already in the audited set
-- (audit_visits trigger since 2026-05-17) — column add is auto-captured
-- in full-row JSONB. No action needed.
--
-- Anon writes per Rule 4 trust hierarchy: DERM Tracker UI runs as anon
-- (same pattern as 2026-05-18a anon_update_derm_manifests). Column-level
-- GRANT scopes the write surface to JUST derm_required — anon cannot
-- mutate visit_status, visit_date, client_id, etc.

BEGIN;

ALTER TABLE public.visits ADD COLUMN derm_required BOOLEAN;

COMMENT ON COLUMN public.visits.derm_required IS
'NULL = use default (TRUE if service_type=GT, FALSE otherwise). Explicit TRUE/FALSE = ops override via DERM Tracker.';

GRANT UPDATE (derm_required) ON public.visits TO anon, authenticated;

CREATE POLICY "anon_update_visit_derm_required"
  ON public.visits
  AS PERMISSIVE
  FOR UPDATE
  TO anon, authenticated
  USING (visit_status = 'completed')
  WITH CHECK (visit_status = 'completed');

-- Updated derm.visits view exposes derm_required + a computed needs_manifest
-- so the DERM Tracker app doesn't have to re-implement the default rule.
CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                                       AS client_name,
  COALESCE(p.address, '')                   AS address,
  COALESCE(p.county,  '')                   AS county,
  v.visit_date::text                        AS visit_date,
  NULL::text                                AS technician,
  NULL::text                                AS notes,
  v.created_at::text                        AS created_at,
  v.client_id,
  v.service_type,
  EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id) AS has_manifest,
  v.derm_required,
  COALESCE(v.derm_required, v.service_type = 'GT')                          AS needs_manifest
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id AND p2.is_billing = false
  ORDER BY p2.id LIMIT 1
) p ON true
WHERE v.visit_status = 'completed';

COMMIT;

-- Verification:
-- 1. SELECT COUNT(*) FROM derm.visits WHERE needs_manifest=true AND NOT has_manifest;
--    → list of visits the app should surface under "Missing Docs"
-- 2. UPDATE public.visits SET derm_required=false WHERE id=<some_GT_visit>;
--    → next query, that visit drops from "Missing Docs" into "Not Required"
