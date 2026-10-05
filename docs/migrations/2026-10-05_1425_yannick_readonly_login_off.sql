-- ============================================================================
-- 2026-10-05_1425  yannick_readonly: login switched off, password removed
-- ============================================================================
-- WHY. Fred, 2026-10-05: "About yannick password, then remove it." (system audit
-- 2026-10-05, finding SECURITY-01). The full connection string of this login, password
-- included, was committed in the PUBLIC supabase repo (two handoff docs, first in
-- c1ede05 on 2026-05-11), and the role could log in, bypassed RLS and had no expiry, so
-- anyone holding that text could read every client, contact, address and lock box code.
-- On 2026-09-24 Fred chose to have Yannick change the password; nothing showed it was done,
-- and a rotation cannot be verified without logging in with the old value (not done).
--
-- MEASURED BEFORE (2026-10-05 14:23 ET, read-only):
--   rolcanlogin = true, rolbypassrls = true, rolvaliduntil = null, 0 live sessions.
--   pg_stat_statements since its 2026-09-03 reset: ONE statement by this role, "SELECT $1",
--   8 calls (a client testing its connection; no data read). The buffer is evictable, so
--   this is a hint, not proof; it is consistent with nobody using the login.
--   No .env, settings or config file in the workspace logs in with it (grep by name).
--   postgres holds ADMIN on the role (PG 17.6), so it may change LOGIN and BYPASSRLS.
--
-- WHAT THIS DOES:
--   * NOLOGIN, NOBYPASSRLS, PASSWORD NULL. The published password no longer opens anything,
--     and re-enabling LOGIN alone would not bring it back.
--   * Ends any live session of the role (there were none).
--   * Removes the role from postgres' DEFAULT PRIVILEGES (public tables, public sequences,
--     ops tables), so new objects stop granting it SELECT.
--
-- WHAT IT DELIBERATELY KEEPS: the role and its existing grants (154 rows in
-- information_schema.role_table_grants). Without LOGIN they are inert. Dropping the role
-- would break the re-runnability of every migration that grants or revokes on it (e.g. the
-- property_intakes column grant that leaves out token) and the control in
-- scripts/probes/job_step_ledger.js. If Yannick needs direct read access again:
--   ALTER ROLE yannick_readonly LOGIN PASSWORD '<new value from the password manager>';
-- (decide BYPASSRLS separately; a person's read login should not need it), and never put the
-- value in a file.
--
-- RULE 8 (audit trail): no table is created or changed; not applicable.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _yro_before ON COMMIT DROP AS
SELECT count(*)::int AS grants FROM information_schema.role_table_grants WHERE grantee = 'yannick_readonly';

ALTER ROLE yannick_readonly NOLOGIN NOBYPASSRLS PASSWORD NULL;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES    FROM yannick_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM yannick_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA ops    REVOKE ALL ON TABLES    FROM yannick_readonly;

SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'yannick_readonly';

-- VERIFY
DO $verify$
DECLARE r record; v_before int; v_after int; v_acl int;
BEGIN
  SELECT rolcanlogin, rolbypassrls INTO r FROM pg_roles WHERE rolname = 'yannick_readonly';
  IF r IS NULL THEN RAISE EXCEPTION 'VERIFY: role yannick_readonly not found'; END IF;
  IF r.rolcanlogin THEN RAISE EXCEPTION 'VERIFY: yannick_readonly can still log in'; END IF;
  IF r.rolbypassrls THEN RAISE EXCEPTION 'VERIFY: yannick_readonly still bypasses RLS'; END IF;

  SELECT count(*) INTO v_acl FROM pg_default_acl WHERE defaclacl::text LIKE '%yannick_readonly%';
  IF v_acl <> 0 THEN RAISE EXCEPTION 'VERIFY: % default-privilege entries still name yannick_readonly', v_acl; END IF;

  -- The existing grants are kept on purpose; the count must not move.
  SELECT grants INTO v_before FROM _yro_before;
  SELECT count(*) INTO v_after FROM information_schema.role_table_grants WHERE grantee = 'yannick_readonly';
  IF v_after <> v_before THEN RAISE EXCEPTION 'VERIFY: grants moved % -> %', v_before, v_after; END IF;

  -- Positive control: the instrument sees the role (a kept grant is visible).
  IF NOT has_table_privilege('yannick_readonly', 'public.clients', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: control failed, expected the kept SELECT grant on public.clients';
  END IF;

  RAISE NOTICE 'VERIFY ok: NOLOGIN, NOBYPASSRLS, 0 default-privilege entries, % grants kept', v_after;
END
$verify$;

COMMIT;
