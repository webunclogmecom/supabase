-- 2026-05-20a_derm_required_default_true.sql
--
-- Flip the default DERM-required rule. Fred decision 2026-05-20:
-- "all are DERM required unless we change it manually, it doesn't matter
--  if it is or not GT."
--
-- Before (2026-05-19c): needs_manifest = COALESCE(derm_required, service_type='GT')
--   → CL/LS visits auto-classified as not needing DERM. 108 visits dropped
--     off the "Missing Docs" tab automatically.
--
-- After (this migration): needs_manifest = COALESCE(derm_required, TRUE)
--   → every completed visit needs a manifest unless ops explicitly marks
--     it FALSE via the DERM Tracker toggle/bulk button.
--
-- Compliance-first posture: presume coverage required, opt out per-visit.
-- Avoids any false-negative where a CL/LS visit actually DID need DERM
-- paperwork (e.g. a "cleaning" line item that included grease pumping).
--
-- Audit opt-in per Rule 8: this is a view-only change. Underlying
-- public.visits is already audited (audit_visits since 2026-05-17).

BEGIN;

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
  COALESCE(v.derm_required, TRUE)           AS needs_manifest
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id AND p2.is_billing = false
  ORDER BY p2.id LIMIT 1
) p ON true
WHERE v.visit_status = 'completed';

COMMENT ON VIEW derm.visits IS
'DERM Tracker source view. needs_manifest defaults TRUE for all completed visits unless ops explicitly sets visits.derm_required=FALSE (per Fred 2026-05-20).';

UPDATE public.visits SET updated_at = updated_at WHERE FALSE;  -- noop to refresh dependent caches

COMMIT;

-- Verification (run after deploy):
--   SELECT COUNT(*) FILTER (WHERE needs_manifest AND NOT has_manifest) AS missing,
--          COUNT(*) FILTER (WHERE NOT needs_manifest) AS not_required
--   FROM derm.visits;
-- Expected: missing ≈ 160, not_required = 0 (until ops marks some).
