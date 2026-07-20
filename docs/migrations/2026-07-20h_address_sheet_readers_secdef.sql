-- 2026-07-20h — the two address-sheet READERS become SECURITY DEFINER
--
-- FOUND BY THE FIRST REAL GENERATION (2026-07-20, second attempt, still HTTP 500). The real error,
-- surfaced by calling PostgREST directly, was:
--     42501  permission denied for table address_sheet_manifests
--
-- CAUSE: derm.fn_sheet_is_generated and derm.fn_address_sheet_no were plain (INVOKER) SQL functions
-- reading the 20f provenance tables, so they need the CALLER to hold SELECT on those tables. The
-- derm schema's default privileges granted r to anon and authenticated but NOT to service_role —
-- which is precisely the role the pdf-service uses.
--
-- ⚠ LIVE-APP IMPACT: NONE, verified by SET LOCAL ROLE probes before shipping this. Stamp Studio's
-- derm.v_stamp_rows / v_stamp_sheets and the DERM Tracker's derm.manifests all still resolved as
-- both authenticated and anon, because those two roles DID receive the default grant. Only
-- service_role was blocked. Recording this because the 20f no-op oracle ran as postgres and
-- therefore could not have caught it — a role-scoped probe is now part of the checklist.
--
-- FIX: make both readers SECURITY DEFINER with a pinned search_path, so the answer never depends on
-- who is asking. This also matches the rest of the derm function set (fn_blackout_targets,
-- set_stamp_position, auto_place_page, record_generated_address_sheet are all SECDEF). service_role
-- additionally gets SELECT so ad-hoc service queries against the tables work.
--
-- Both functions remain read-only EXISTS/lookup queries over provenance rows (a sheet number and a
-- storage path — no PII), so definer rights grant nothing beyond what they already return.
-- Signatures, return types and volatility are unchanged, so no call site needs an edit.
-- Idempotent.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_sheet_is_generated(p_sheet_no text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm','public' AS $$
  SELECT CASE WHEN p_sheet_no IS NULL THEN NULL ELSE EXISTS (
    SELECT 1
      FROM derm.address_sheet_manifests l
      JOIN derm.address_sheets   s ON s.id = l.sheet_id AND s.deleted_at IS NULL
      JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
     WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_sheet_no
  ) END;
$$;

CREATE OR REPLACE FUNCTION derm.fn_address_sheet_no(p_manifest_id bigint)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm','public' AS $$
  SELECT s.sheet_no
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = p_manifest_id
   ORDER BY s.last_generated_at DESC
   LIMIT 1;
$$;

GRANT SELECT ON derm.address_sheets, derm.address_sheet_manifests TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
