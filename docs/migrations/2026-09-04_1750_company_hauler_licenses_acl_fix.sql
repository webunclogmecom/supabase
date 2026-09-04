-- 2026-09-04_1750_company_hauler_licenses_acl_fix.sql
--
-- Fixes `2026-09-04_1738_company_hauler_licenses.sql`, applied minutes earlier.
--
-- WHAT WENT WRONG. That migration shipped `authenticated` with `arwdDxtm` on
-- public.company_hauler_licenses: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER.
-- A signed-in staff browser could have edited or truncated a credential that is printed on a state
-- regulatory form, through PostgREST, with RLS enabled and no policy permitting it (the grant is
-- what PostgREST checks first, and the table had no restrictive policy to stop a write once the
-- grant let it through).
--
-- WHY, and it is EXACTLY the failure CLAUDE.md already documents under
-- "Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote", including the 2026-08-07
-- `public.job_frequency_changes` incident it cites. `CREATE TABLE` applies Supabase's default
-- privileges BEFORE any statement in the migration body runs. My `revoke all ... from public` then
-- removed nothing relevant, because the grant was made BY NAME to `authenticated`, not to PUBLIC.
-- Every GRANT statement in that migration was correct, and every one of them was also irrelevant:
-- a GRANT cannot remove what it did not create.
--
-- HOW IT WAS CAUGHT. The migration's own verification read `relacl` AFTER the fact and compared it
-- to the sibling table `public.vehicle_decals`, which is the check CLAUDE.md prescribes for this
-- exact reason. Reading the GRANT statements, or asserting that the grants I wrote took effect,
-- would have passed. So would any probe over the Management API, which runs as the table OWNER and
-- bypasses the grant system entirely.
--
--   new table     authenticated=arwdDxtm      <- wrong
--   vehicle_decals authenticated=r            <- the intended shape
--
-- `anon` was correctly denied throughout (SELECT and INSERT both false), so there was no anonymous
-- exposure at any point.
--
-- AFTER THIS: authenticated=r only, matching vehicle_decals byte for byte.

revoke all on public.company_hauler_licenses from authenticated;
grant select on public.company_hauler_licenses to authenticated;

-- The sequence got the same treatment from the same default-privilege rule.
revoke all on sequence public.company_hauler_licenses_id_seq from authenticated;
