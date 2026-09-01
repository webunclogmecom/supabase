-- 2026-08-31_1330_hr_schema_and_access_level_correction.sql
--
-- WHY: THE TWO PREREQUISITES FOR THE HR APP, BEFORE ANY UI WORK.
-- ---------------------------------------------------------------------------
-- Fred: "fix the access_level rows and expose the hr schema".
-- Design: docs/superpowers/specs/2026-08-31-hr-app-employee-management-design.md
--
-- This migration does the DATABASE half. Exposing `hr` to PostgREST is a project API setting and
-- is done separately with scripts/probes/postgrest_config.mjs --add hr, AFTER this lands, because
-- exposing a schema that does not exist yet would be meaningless.
--
-- ---------------------------------------------------------------------------
-- PART A. access_level is wrong on six rows, and this app is what makes it matter
-- ---------------------------------------------------------------------------
-- Fred's grouping, 2026-08-31:
--     Admin:  Fred, Yannick
--     Office: Aaron, Diego, Serena
--     Field:  Grecia, Mark, Anthony, Michael Escobar
--
-- 🛑 `access_level` IS DECORATIVE TODAY. Only `client.employees` reads it, as a passthrough column;
-- no function gates on it and there is no CHECK constraint. Nothing has ever depended on it, which
-- is exactly why it drifted. The HR app makes it load-bearing for the first time, after which a
-- wrong value either locks a colleague out or shows the wrong person everybody's pay.
--
-- ⚠ **id 16 `A Azoulay (admin)` IS NOT A SEPARATE PERSON.** Azoulay is Aaron's surname (Fred,
-- 2026-08-31). It is his retired duplicate: id 16 holds 0 `visit_team` rows and the live id 26
-- holds 58, so the survivor carries the history. Same consolidation pattern as Michael Escobar on
-- 2026-08-18. It is corrected to `office` to match the person, which also lets the constraint below
-- be VALIDATED rather than NOT VALID.
-- ⚠ Both rows carry their own distinct Jobber link (User/2599812 retired, User/2930566 live), so
-- Jobber genuinely holds two user records for Aaron. Out of scope; noted so nobody reads it as
-- corruption.
--
-- 🛑 WHERE `dev` CAME FROM, AND WHY A CODE CHANGE SHIPS WITH THIS MIGRATION.
-- `scripts/populate/populate.js` is the writer: line 445 maps a Jobber account owner or admin to
-- `access_level = 'dev'`. That is a JOBBER-PERMISSION heuristic, not the business grouping, which
-- is why it put Aaron, Diego and Serena (Jobber Admins) in the same bucket as Yannick, and left
-- Fred in `office`. Left alone it would re-introduce `dev` and violate the new constraint, so the
-- literal is changed to `admin` in the same commit. The mapping remains a bulk-load heuristic:
-- access_level is now a deliberate human assignment, not something to be derived from Jobber.
--
-- ⚠ THE CONSTRAINT ALLOWS NULL ON PURPOSE. `webhook-samsara` auto-creates employees (the
-- `match_method='webhook_new'` path that produced the duplicate Michael Escobar) and sets no
-- access_level, so NULL is reachable. Rejecting it would break the Samsara driver feed. NULL fails
-- the HR gate, which is the fail-safe direction: a new hire sees nothing until somebody decides
-- what they should see.
--
-- ---------------------------------------------------------------------------
-- PART B. The `hr` schema
-- ---------------------------------------------------------------------------
-- Created empty. No tables ship here yet; the employee-detail tables come with the build.
--
-- ⚠ `anon` gets NOTHING, not even USAGE. The HR app is office/admin only and there is no
-- customer-facing surface, so anon has no business reaching this schema at any point.
--
-- 🛑 THE DEFAULT-PRIVILEGES TRAP. This project carries 30 `pg_default_acl` entries across auth,
-- client, cron, derm, extensions, graphql, graphql_public, ops, public, realtime and storage.
-- `CREATE TABLE` hands out privileges BEFORE any GRANT in a migration runs, which is how
-- `public.job_frequency_changes` shipped on 2026-08-07 with `authenticated` holding SELECT, INSERT,
-- UPDATE, DELETE and TRUNCATE while its own header asserted the opposite and its GRANTs were all
-- correct. Measured now: **zero** default ACLs target `hr`, and VERIFY 5 asserts it. **Re-check
-- after the schema is exposed**, and read `relacl` on every future hr table rather than trusting
-- the GRANT statements that created it.
--
-- RULE 8 (audit trail): `public.employees` already carries the audit trigger, so all six
-- corrections are captured with `old_row` and are individually revertible. The `hr` schema holds no
-- tables yet, so there is nothing to opt in or out; each table opts IN when it is created.
-- RULE 7: `updated_at` is trigger-managed and is deliberately NOT set by the UPDATE below.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground. None of this can fire against a world that moved.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'hr') THEN
    RAISE EXCEPTION 'PART 0: schema hr already exists; re-read before creating it';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint c
               JOIN pg_class t ON t.oid = c.conrelid
               JOIN pg_namespace n ON n.oid = t.relnamespace
              WHERE n.nspname='public' AND t.relname='employees'
                AND c.conname='employees_access_level_chk') THEN
    RAISE EXCEPTION 'PART 0: employees_access_level_chk already exists';
  END IF;

  -- the six rows must be exactly as measured, by id AND name AND current value, so a
  -- re-numbered or renamed estate cannot be silently rewritten
  SELECT count(*) INTO v_n FROM public.employees
   WHERE (id, full_name, access_level) IN (
           (2,  'Fred',              'office'),
           (27, 'Yannick',           'dev'),
           (26, 'Aaron',             'dev'),
           (28, 'Diego',             'dev'),
           (42, 'Serena Natali',     'dev'),
           (16, 'A Azoulay (admin)', 'dev'));
  IF v_n <> 6 THEN
    RAISE EXCEPTION 'PART 0: expected the 6 known rows in their known state, matched %. '
      'Somebody has edited access_level; re-measure before correcting it.', v_n;
  END IF;

  -- id 16 must still be the retired duplicate and id 26 the survivor, or the "same person"
  -- reasoning above does not hold
  SELECT count(*) INTO v_n FROM public.visit_team WHERE employee_id = 16;
  IF v_n <> 0 THEN RAISE EXCEPTION 'PART 0: id 16 now has % visit_team rows; it is not inert', v_n; END IF;
  IF (SELECT status FROM public.employees WHERE id = 16) <> 'INACTIVE' THEN
    RAISE EXCEPTION 'PART 0: id 16 is no longer INACTIVE';
  END IF;

  -- nothing outside the known vocabulary, and no NULLs to reason about
  SELECT count(*) INTO v_n FROM public.employees
   WHERE access_level IS NULL OR access_level NOT IN ('dev','office','field');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PART 0: % row(s) hold a NULL or unexpected access_level', v_n;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- PART 1. The hr schema, empty.
-- ---------------------------------------------------------------------------
CREATE SCHEMA hr;

COMMENT ON SCHEMA hr IS
  'HR app state. Office/admin staff only: the gate is on the CALLER, while the directory lists '
  'every hired person. Canonical employee facts stay on public.employees. See '
  'docs/superpowers/specs/2026-08-31-hr-app-employee-management-design.md';

REVOKE ALL ON SCHEMA hr FROM PUBLIC;
GRANT USAGE ON SCHEMA hr TO authenticated, service_role;
-- anon deliberately gets nothing.

-- ---------------------------------------------------------------------------
-- PART 2. Correct the six rows.
-- ---------------------------------------------------------------------------
-- Each arm re-asserts the FROM value, so it cannot fire twice and cannot fire on a row somebody
-- else has already changed.
UPDATE public.employees SET access_level = 'admin'
 WHERE id IN (2, 27) AND access_level IN ('office', 'dev');

UPDATE public.employees SET access_level = 'office'
 WHERE id IN (26, 28, 42, 16) AND access_level = 'dev';

-- ---------------------------------------------------------------------------
-- PART 3. Pin the vocabulary so a typo fails loudly instead of changing who sees pay.
-- ---------------------------------------------------------------------------
ALTER TABLE public.employees
  ADD CONSTRAINT employees_access_level_chk
  CHECK (access_level IS NULL OR access_level IN ('admin','office','field'));

COMMENT ON COLUMN public.employees.access_level IS
  'admin | office | field, or NULL. Gates the HR app (admin+office). A deliberate human '
  'assignment, NOT derived from Jobber permissions. NULL is reachable via the Samsara auto-create '
  'path and fails the gate, which is the fail-safe direction.';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_txt text;
BEGIN
  -- 1. the grouping now matches what Fred gave, exactly, for ACTIVE people
  SELECT string_agg(full_name, ', ' ORDER BY full_name) INTO v_txt
    FROM public.employees WHERE status='ACTIVE' AND access_level='admin';
  IF v_txt IS DISTINCT FROM 'Fred, Yannick' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: active admins are [%], wanted [Fred, Yannick]', coalesce(v_txt,'');
  END IF;

  SELECT string_agg(full_name, ', ' ORDER BY full_name) INTO v_txt
    FROM public.employees WHERE status='ACTIVE' AND access_level='office';
  IF v_txt IS DISTINCT FROM 'Aaron, Diego, Serena Natali' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: active office are [%], wanted [Aaron, Diego, Serena Natali]',
      coalesce(v_txt,'');
  END IF;

  SELECT string_agg(full_name, ', ' ORDER BY full_name) INTO v_txt
    FROM public.employees WHERE status='ACTIVE' AND access_level='field';
  IF v_txt IS DISTINCT FROM 'Anthony, Grecia, Mark, Michael Escobar' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: active field are [%]', coalesce(v_txt,'');
  END IF;

  -- 2. `dev` is gone from the whole table, inactive rows included
  SELECT count(*) INTO v_n FROM public.employees WHERE access_level = 'dev';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % row(s) still hold dev', v_n; END IF;

  -- 3. 🛑 THE CONSTRAINT ACTUALLY BITES. Without this, VERIFY 2 only says today's data is clean.
  --    Rolled back.
  BEGIN
    UPDATE public.employees SET access_level = 'dev' WHERE id = 2;
    RAISE EXCEPTION 'VERIFY 3 FAILED: the constraint accepted dev';
  EXCEPTION
    WHEN check_violation THEN NULL;                       -- expected
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'VERIFY 3 FAILED%' THEN RAISE; END IF;
      RAISE EXCEPTION 'VERIFY 3 FAILED: unexpected error %', SQLERRM;
  END;

  -- 4. ...and still allows NULL, or the Samsara auto-create path breaks
  BEGIN
    UPDATE public.employees SET access_level = NULL WHERE id = 16;
    RAISE EXCEPTION 'ctrl_null_ok';
  EXCEPTION
    WHEN check_violation THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: the constraint rejects NULL; webhook-samsara would break';
    WHEN OTHERS THEN
      IF SQLERRM <> 'ctrl_null_ok' THEN RAISE; END IF;
  END;

  -- 5. the hr schema exists, anon cannot reach it, and nothing auto-grants inside it
  IF NOT has_schema_privilege('authenticated', 'hr', 'USAGE') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: authenticated cannot USE schema hr';
  END IF;
  IF has_schema_privilege('anon', 'hr', 'USAGE') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: anon can USE schema hr';
  END IF;
  SELECT count(*) INTO v_n FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname = 'hr';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % default-privilege entr(y/ies) already target hr', v_n;
  END IF;

  -- 6. the corrections were captured, so they are revertible from old_row
  SELECT count(*) INTO v_n FROM audit.logs
   WHERE table_name = 'employees' AND changed_at > now() - interval '1 minute';
  IF v_n < 6 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: only % audit row(s) for the 6 corrections', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: admin=Fred,Yannick office=Aaron,Diego,Serena field=4, dev gone, '
    'constraint rejects dev and accepts NULL, schema hr created with anon locked out and no '
    'default ACLs, and all six corrections are in audit.logs.';
END $do$;

COMMIT;
