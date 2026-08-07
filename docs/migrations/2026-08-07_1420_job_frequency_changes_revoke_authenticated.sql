-- ============================================================================
-- 2026-08-07_1420: REVOKE the grants nobody wrote on public.job_frequency_changes
-- ============================================================================
-- 🛑 THIS FIXES A REAL HOLE OPENED BY 2026-08-07_1235, FOUND THE SAME DAY BY A
-- SMOKE TEST THAT WAS BRIEFED TO ATTACK THE CLAIM RATHER THAN RE-CHECK THE NUMBERS.
--
-- WHAT WAS WRONG. The 1235 migration's header says, of the new table:
--     "Grants: EXACT parity with public.client_status_changes (measured 2026-08-07).
--      Note what is absent on purpose: `authenticated` holds nothing."
-- That sentence was FALSE against the live table from the moment it was applied.
-- Measured, both tables, same statement:
--     job_frequency_changes  {postgres=arwdDxtm, authenticated=arwdDxtm,
--                             service_role=arwdDxtm, yannick_readonly=r}
--     client_status_changes  {postgres=arwdDxtm,
--                             service_role=arwdDxtm, yannick_readonly=r}
-- So `authenticated` held SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and
-- TRIGGER. RLS is off and there are no policies (correctly, matching the sibling),
-- so NOTHING stood between a signed-in staff browser and these rows: via PostgREST
-- they could edit, delete or truncate the compliance history the table exists to
-- preserve. Proven under `SET LOCAL ROLE authenticated` in a rolled-back probe, with
-- the same role refused 42501 on client_status_changes as the control.
--
-- WHY IT HAPPENED, AND WHY WRITING THE RIGHT GRANTS DID NOT PREVENT IT.
-- Supabase's ALTER DEFAULT PRIVILEGES hands `authenticated` full DML on every new
-- postgres-owned table in `public`. CREATE TABLE had therefore already granted it
-- everything BEFORE the migration's own GRANT lines ran. Those GRANT lines are
-- correct as far as they go; they simply cannot remove a grant they did not create.
-- **A migration that verifies its own GRANT statements passes while the table stays
-- wide open.** The only check that catches this reads `relacl` (or
-- has_table_privilege) AFTER the fact, and compares against the intended set rather
-- than against the statements written.
--
-- ⚠ This exact trap is already written down in CLAUDE.md, under "Grants, views and
-- functions": *"Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote ...
-- Check every new object, and revoke explicitly."* It was read the same day and the
-- table still shipped open, because the pre-apply probe tested constraints, the audit
-- trigger and the grants that were WRITTEN. It never asked what else was there.
-- ⇒ **Every future CREATE TABLE in `public` gets an explicit REVOKE and an asserted
--   relacl check in the same migration.** Not a comment saying it was considered.
--
-- SCOPE. This migration touches ONE table. The wider default-ACL footprint is real
-- (a sweep found `authenticated` holding TRUNCATE on 18 of 55 public tables) but it
-- is pre-existing, unrelated to today's work, and narrowing it is a security review
-- with its own blast radius. It is recorded for Fred, not silently changed here.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table is added or renamed; the audit
-- trigger installed by 1235 is untouched. Nothing to opt in or out of.
-- ============================================================================

revoke all on public.job_frequency_changes from authenticated;
revoke all on public.job_frequency_changes from anon;

-- Re-assert the intended set, so this file alone describes the end state.
-- (REVOKE above targets only authenticated/anon, so these are unchanged; restating
-- them means a reader does not have to hold two migrations in their head.)
grant select, insert, update, delete, truncate, references, trigger
  on public.job_frequency_changes to service_role;
grant select on public.job_frequency_changes to yannick_readonly;

-- ---------------------------------------------------------------------------
-- PROVE IT, in the same transaction that changed it. A migration that asserts its
-- own outcome cannot leave the object in the state this file exists to fix.
-- The sibling is used as the positive control: if the comparison logic were broken,
-- client_status_changes would fail it too.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad text[] := array[]::text[];
  p     text;
begin
  foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
    if has_table_privilege('authenticated', 'public.job_frequency_changes', p) then
      v_bad := v_bad || ('authenticated:' || p);
    end if;
    if has_table_privilege('anon', 'public.job_frequency_changes', p) then
      v_bad := v_bad || ('anon:' || p);
    end if;
  end loop;
  if array_length(v_bad, 1) is not null then
    raise exception 'REVOKE did not take: % still granted', v_bad;
  end if;

  -- the writer must keep working
  if not has_table_privilege('service_role', 'public.job_frequency_changes', 'INSERT') then
    raise exception 'service_role lost INSERT; save-client-job would break';
  end if;
  if not has_table_privilege('yannick_readonly', 'public.job_frequency_changes', 'SELECT') then
    raise exception 'yannick_readonly lost SELECT';
  end if;

  -- POSITIVE CONTROL: the same assertion must already hold on the sibling. If it
  -- does not, the check above is measuring the wrong thing.
  if has_table_privilege('authenticated', 'public.client_status_changes', 'SELECT') then
    raise exception 'control failed: authenticated can read client_status_changes, so the intended model is not what this file assumes';
  end if;

  raise notice 'job_frequency_changes: authenticated and anon hold nothing; service_role and yannick_readonly intact; sibling control passed';
end
$$;
