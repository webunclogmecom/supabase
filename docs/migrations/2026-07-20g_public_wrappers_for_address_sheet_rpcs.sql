-- 2026-07-20g — public wrappers for the two address-sheet RPCs (PostgREST schema resolution)
--
-- FOUND BY THE FIRST REAL GENERATION ATTEMPT (2026-07-20, manifest 1374 / ticket 999001).
-- The pdf-service builds its client with plain create_client(url, key) — no schema option — so
-- supabase-py resolves every .rpc() against the DEFAULT PostgREST schema (public). Both functions
-- added in 2026-07-20f live in `derm`, so the very first call (get_address_sheet_no) 404'd and the
-- endpoint returned 500.
--
-- ⚠ THE FAILURE WAS CLEAN, AND THAT IS THE HEADLINE: it died on the FIRST new call, so
--   * public.derm_manifests.derm_address_url stayed NULL — the uploaded-photo protection held
--     (under the pre-20f code this same request would already have overwritten it),
--   * nothing was recorded (derm.address_sheets 0 rows, address_sheet_manifests 0 rows),
--   * derm_address_seq did NOT advance (still 1026) — no sheet number was burned.
--
-- FIX: thin public wrappers that delegate to the derm functions, mirroring the existing house
-- precedent of ops.* wrappers mirroring public.* (see check_ops_app_rpcs.js). Chosen over making
-- the pdf-service schema-switch per call because the service also touches public tables and
-- public.next_derm_address_id in the same request, and because a wrapper is verifiable from SQL.
--
-- ⚠ KEEP THE SIGNATURES MIRRORED. If derm.record_generated_address_sheet ever changes arity or
-- argument names, this wrapper must change with it in the same migration — a drifted wrapper fails
-- at runtime inside the pdf-service, not here. (Same trap the 2026-07-03 ops-wrapper incident hit.)
--
-- ADR 010 audit: no new tables; wrappers only. The underlying derm functions keep their own gates
-- (the writer still refuses any ticket carrying a photo or a Stamp card).
-- Idempotent.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_address_sheet_no(p_manifest_id bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT derm.fn_address_sheet_no(p_manifest_id);
$$;

CREATE OR REPLACE FUNCTION public.record_generated_address_sheet(
  p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[])
RETURNS bigint LANGUAGE sql AS $$
  SELECT derm.record_generated_address_sheet(p_sheet_no, p_bucket, p_path, p_manifest_ids);
$$;

-- Same ACL posture as the derm originals: the writer is service_role ONLY (it is the single path
-- that can mark a sheet as ours); the reader is harmless but stays off anon.
REVOKE ALL ON FUNCTION public.record_generated_address_sheet(bigint, text, text, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_generated_address_sheet(bigint, text, text, bigint[]) TO service_role;

REVOKE ALL ON FUNCTION public.fn_address_sheet_no(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_address_sheet_no(bigint) TO authenticated, service_role;
REVOKE ALL ON FUNCTION derm.fn_address_sheet_no(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_address_sheet_no(bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_address_sheet_no(bigint) IS
  'PostgREST-facing wrapper for derm.fn_address_sheet_no. Exists because clients built with a plain create_client() resolve RPCs in the public schema.';
COMMENT ON FUNCTION public.record_generated_address_sheet(bigint, text, text, bigint[]) IS
  'PostgREST-facing wrapper for derm.record_generated_address_sheet (service_role only). Keep the signature mirrored with the derm original.';

COMMIT;

NOTIFY pgrst, 'reload schema';
