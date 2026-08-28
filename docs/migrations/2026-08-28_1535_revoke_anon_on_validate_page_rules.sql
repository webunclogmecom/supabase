-- 2026-08-28_1535_revoke_anon_on_validate_page_rules.sql
--
-- WHY: `2026-08-28_1520` created derm.fn_validate_page_rules and revoked anon on its sibling
-- record_page_rules but not on this one, so Supabase's ALTER DEFAULT PRIVILEGES handed anon EXECUTE
-- on it. Measured immediately after that migration: anon=true.
--
-- This is the default-privileges trap this repo already documents: a GRANT written in a migration
-- cannot remove what CREATE handed out before it ran, and REVOKE FROM PUBLIC does not cover the
-- roles default privileges name explicitly.
--
-- ⚠ Substance: nothing leaked. The function is IMMUTABLE, takes jsonb, returns text and touches no
-- table, so an anon caller learns only whether a rule set they already hold is well formed. This is
-- hygiene and consistency, not an incident. Recorded because "we checked the new object's ACL and
-- fixed it" is the habit that catches the case where it DOES matter.
--
-- RULE 8: grants only, no table touched. Opt-out.

BEGIN;

-- 🛑 BOTH REVOKES ARE REQUIRED AND THE FIRST ATTEMPT AT THIS MIGRATION PROVED IT.
-- Revoking the ROLE alone left anon still holding EXECUTE, because a function is created with
-- EXECUTE granted to PUBLIC and anon inherits it from there. Revoking PUBLIC alone is equally
-- insufficient on this platform, because Supabase's ALTER DEFAULT PRIVILEGES names anon directly.
-- The memory note reference_supabase_function_default_privileges records the second half; this is
-- the first half, and the VERIFY below is what caught it.
REVOKE ALL ON FUNCTION derm.fn_validate_page_rules(jsonb) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.fn_validate_page_rules(jsonb) FROM anon';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION derm.fn_validate_page_rules(jsonb) TO authenticated, service_role;

DO $do$
DECLARE v_anon boolean; v_authn boolean;
BEGIN
  SELECT has_function_privilege('anon','derm.fn_validate_page_rules(jsonb)','EXECUTE'),
         has_function_privilege('authenticated','derm.fn_validate_page_rules(jsonb)','EXECUTE')
    INTO v_anon, v_authn;
  IF v_anon THEN RAISE EXCEPTION 'VERIFY FAILED: anon still holds EXECUTE'; END IF;
  IF NOT v_authn THEN RAISE EXCEPTION 'VERIFY FAILED: authenticated lost EXECUTE'; END IF;
  -- control: the sibling is still correctly configured
  IF has_function_privilege('anon',
       'derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY FAILED: anon holds EXECUTE on record_page_rules';
  END IF;
  RAISE NOTICE 'VERIFY ok: anon revoked, authenticated retained, sibling unchanged.';
END $do$;

COMMIT;
