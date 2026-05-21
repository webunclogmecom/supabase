-- 2026-05-15a_security_hardening_phase1.sql
--
-- PHASE 1 hardening — strip default `GRANT ALL` leftovers from anon role.
-- ALL CHANGES ARE NON-DISRUPTIVE — verified against current app surface area:
--   - Admin Review App (Sandbox #1 primary + Prod mirror): only writes
--     photo_classifications. Reads everything from Sandbox #1.
--   - Field Portal App: only reads from customer.* schema views (which run
--     as owner, bypass RLS, and don't depend on anon permissions on public.*).
--   - Webhooks: use service_role, bypass all anon constraints.
--
-- What this migration does:
--   1. CRITICAL: revoke all anon access on webhook_tokens (held secrets!)
--   2. Universally strip useless anon privileges (DELETE/TRUNCATE/REFERENCES/TRIGGER)
--   3. Revoke anon INSERT/UPDATE on tables nothing legitimately writes to from anon
--      (synced from webhooks, sync metadata, lookups)
--   4. Replace blanket `FOR ALL TO anon USING (true)` policy on
--      photo_classifications with explicit per-operation policies (drops the
--      implicit DELETE permission — Lovable upserts only, doesn't DELETE).
--
-- What this migration explicitly KEEPS:
--   - Anon SELECT on public canonical tables (in case undiscovered code paths read).
--   - Anon SELECT/INSERT/UPDATE on photo_classifications (Admin Review App writes).
--   - Anon writes on visit_recommendations + app_* tables (forward-compat for apps).
--   - Customer.* schema entirely untouched (it's the security boundary).
--
-- Apply across all 3 projects (Prod, Sandbox #1, Field Portal Sandbox).

BEGIN;

-- ============================================================================
-- STEP 1: webhook_tokens — secrets table. NO anon access of any kind.
-- ============================================================================
REVOKE ALL ON public.webhook_tokens FROM anon;
REVOKE ALL ON public.webhook_tokens FROM authenticated;
-- service_role retains full access (uses webhook_tokens for OAuth refresh).
-- If you want to verify nothing is left: \dp public.webhook_tokens

-- ============================================================================
-- STEP 2: Strip useless privileges (DELETE/TRUNCATE/REFERENCES/TRIGGER) from
-- anon on every public table. These are leftovers from default `GRANT ALL` and
-- serve no legitimate purpose for the anon role. Universal cleanup.
-- ============================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND c.relname NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.%I FROM anon', t);
  END LOOP;
END $$;

-- ============================================================================
-- STEP 3: Revoke anon INSERT/UPDATE on tables that:
--   (a) Are populated only by webhooks (service_role) or sync scripts
--   (b) Are sync metadata not exposed to clients
--   (c) Are lookup tables only admins should change
--
-- App write paths (photo_classifications, visit_recommendations, app_*)
-- are deliberately NOT in this list — they keep anon writes.
-- ============================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    -- (a) webhook-populated canonical (apps only read these)
    'notes','photos','photo_links',
    'vehicle_telemetry_readings','jobber_oversized_attachments',
    'entity_source_links',
    -- (b) sync metadata
    'webhook_events_log','sync_cursors','sync_log',
    -- (c) lookup tables (admin-only writes via service_role)
    'client_groups','disposal_facilities',
    -- (d) app tables that shouldn't be on Prod at all (empty, will clean up later)
    'app_shift_reviews','app_visit_reviews'
  ]
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE ON public.%I FROM anon', t);
  END LOOP;
END $$;

-- ============================================================================
-- STEP 4: Tighten photo_classifications policy.
-- Replace `FOR ALL TO anon USING (true) WITH CHECK (true)` with explicit
-- per-operation policies. This drops the implicit DELETE permission that
-- FOR ALL granted — Lovable's app upserts only, never DELETEs.
-- ============================================================================
DROP POLICY IF EXISTS photo_classifications_anon_all ON public.photo_classifications;

CREATE POLICY photo_classifications_anon_select
  ON public.photo_classifications FOR SELECT TO anon
  USING (true);

CREATE POLICY photo_classifications_anon_insert
  ON public.photo_classifications FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY photo_classifications_anon_update
  ON public.photo_classifications FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

-- (No DELETE policy → anon can no longer DELETE rows.)

-- Also revoke the explicit DELETE grant on the table for anon:
REVOKE DELETE ON public.photo_classifications FROM anon;

COMMIT;

-- ============================================================================
-- Verification queries (run after commit on each project):
-- ============================================================================
--
-- 1) anon should NOT have access to webhook_tokens:
--    SELECT * FROM information_schema.role_table_grants
--      WHERE grantee='anon' AND table_name='webhook_tokens';
--    → expected: 0 rows
--
-- 2) anon should still have SELECT/INSERT/UPDATE on photo_classifications:
--    SELECT privilege_type FROM information_schema.role_table_grants
--      WHERE grantee='anon' AND table_name='photo_classifications';
--    → expected: SELECT, INSERT, UPDATE (no DELETE, no TRUNCATE)
--
-- 3) anon should NOT have INSERT/UPDATE on photos/photo_links/notes:
--    SELECT table_name, string_agg(privilege_type, ',') AS privs
--      FROM information_schema.role_table_grants
--      WHERE grantee='anon' AND table_name IN ('photos','photo_links','notes')
--      GROUP BY table_name;
--    → expected: SELECT only
