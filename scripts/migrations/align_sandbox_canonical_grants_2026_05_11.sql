-- ============================================================================
-- Migration: Align Sandbox canonical-table GRANTs with RLS intent — 2026-05-11
-- TARGET: Sandbox only (ubtlwpcyntelgbykdatn). Do NOT apply to Production.
-- ============================================================================
-- Background:
--   5 canonical tables (photos, photo_links, notes, vehicle_telemetry_readings,
--   jobber_oversized_attachments) have table-wide DELETE/INSERT/UPDATE/TRUNCATE
--   /REFERENCES/TRIGGER GRANTs to anon and authenticated. These grants are
--   misleading: RLS already denies all anon/auth write operations on these
--   tables (only service_role has an "ALL" policy + photo_links has an
--   "Authenticated insert" policy). So queries fail at the RLS check anyway
--   — but the GRANTs suggest writes are possible.
--
--   This is what caused the 2026-05-11 useSavePhotoClassifications silent
--   no-op: code looked like it should work (because grants existed), but RLS
--   denied every UPDATE, returning 200/empty. supabase-js does NOT throw on
--   0-rows-affected → green toast for weeks of failed writes.
--
-- This migration:
--   1. Revokes ALL writes (INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER)
--      from anon on all 5 tables.
--   2. Revokes UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER from authenticated
--      on all 5 tables.
--   3. Retains authenticated INSERT on photo_links (supports the existing
--      "Authenticated insert photo_links" RLS policy — needed for future
--      Lovable photo upload features).
--   4. SELECT stays on anon + authenticated everywhere (read access unchanged).
--   5. service_role keeps ALL (untouched).
--
-- After this migration:
--   - anon role: SELECT only on all 5 tables
--   - authenticated role: SELECT + INSERT on photo_links; SELECT only on the
--     other 4
--   - service_role: full access on all 5 (unchanged)
--   - Lovable bad writes will now fail with "permission denied for table"
--     IMMEDIATELY, not silently no-op. Easier to debug.
--
-- Reversal: see align_sandbox_canonical_grants_rollback_2026_05_11.sql
--   (just re-grants the original blanket privileges).
-- ============================================================================

BEGIN;

-- photos
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.photos FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.photos FROM authenticated;

-- photo_links: keep authenticated INSERT (matches existing "Authenticated insert" RLS policy)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.photo_links FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.photo_links FROM authenticated;
-- NOTE: INSERT for authenticated retained intentionally.

-- notes
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.notes FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.notes FROM authenticated;

-- vehicle_telemetry_readings (Samsara owns this — app never writes)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.vehicle_telemetry_readings FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.vehicle_telemetry_readings FROM authenticated;

-- jobber_oversized_attachments (Jobber migration script owns this)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.jobber_oversized_attachments FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.jobber_oversized_attachments FROM authenticated;

COMMIT;

-- Verification queries (run after COMMIT to confirm intended state):
--
-- 1. List remaining grants per table (should match the "After this migration" comment):
--    SELECT table_name, grantee, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privs
--    FROM information_schema.role_table_grants
--    WHERE table_schema = 'public'
--      AND grantee IN ('anon', 'authenticated', 'service_role')
--      AND table_name IN ('photos','photo_links','notes','vehicle_telemetry_readings','jobber_oversized_attachments')
--    GROUP BY table_name, grantee
--    ORDER BY table_name, grantee;
--
-- 2. Test the failure mode is now LOUD (run as anon — should error with
--    "permission denied", not silently no-op):
--    SET ROLE anon; UPDATE photo_links SET role='before' WHERE id=1; RESET ROLE;
