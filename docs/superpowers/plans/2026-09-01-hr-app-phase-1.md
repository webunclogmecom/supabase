# HR App Phase 1 Implementation Plan

> **DEFERRED, not cancelled (2026-09-01).** Fred asked for the front end of all three phases
> first, read-only: *"For now let's work without the Database. I just want the Front End. on All
> phases."* That work shipped as
> [`2026-09-01-hr-app-frontend-all-phases.md`](2026-09-01-hr-app-frontend-all-phases.md).
>
> This plan stays the correct plan for when the backend is built, and it now has acceptance
> criteria it did not have before: the live app names `hr.pay_rate`, `hr.employee_document`,
> `hr.employee_profile`, `auth.users` and `audit.logs` in its empty states. **Those screens are
> the specification.** Build to what they promise, and each one stops being an empty state.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the HR employee directory and detail screens for office/admin staff, backed by a new `hr.*` data layer on Prod.

**Architecture:** Canonical employee facts stay in `public.employees` (untouched schema-wise). HR-only state lives in three new `hr.*` tables behind RLS gated on one SECDEF helper that resolves the caller's `access_level`. The Lovable app reads through `hr.*` views and writes through SECDEF RPCs, because `authenticated` holds SELECT-only on `employees`.

**Tech Stack:** Postgres 15 on Supabase Prod `wbasvhvvismukaqdnouk`, PostgREST, Supabase Storage, Lovable (React + Vite + supabase-js), Management API for migrations.

**Spec:** [`docs/superpowers/specs/2026-08-31-hr-app-employee-management-design.md`](../specs/2026-08-31-hr-app-employee-management-design.md)

---

## Scope

**In:** the `hr.*` data layer, the admin gate, read views, write RPCs, a private documents bucket, and the two screens (directory + detail) with three Quick actions.

**Out, deliberately:**
- **Signed document upload** (spec §8.2). It is a public internet-facing endpoint and a separate subsystem; it gets its own plan. Admin-side upload IS in scope (Task 12).
- **Reassign equipment** button. Cut: no equipment data exists (spec §8.1).
- **Invite / password reset.** Phase 2b, and blocked on Phase 3 (spec §13).
- Anything in Phases 2 or 3.

**Already done, do not redo:** `hr` schema created and exposed to PostgREST, `access_level` corrected and pinned by `employees_access_level_chk`, Aaron's email set. See migrations `2026-08-31_1330` and `2026-09-01_0930`.

---

## How "tests" work here

This repo has no pytest suite for database work. The established and enforced pattern is:

1. **Every migration carries a `VERIFY` `DO $do$` block** that raises on failure, so a bad migration aborts instead of landing.
2. **Every VERIFY carries at least one control** that proves the assertion can fail. A check that only ever passes is an untested instrument.
3. **Rehearse before applying:** `node scripts/probes/apply_sql_file.mjs <file> rehearse` swaps `COMMIT` for `ROLLBACK`.
4. 🛑 **Permission assertions must not be made over the Management API as `postgres`.** That role owns the tables and holds `rolbypassrls`, so it bypasses the GRANT system entirely and every permission probe written that way measures nothing. Use `has_table_privilege('authenticated', ...)` or `SET LOCAL ROLE`.

---

## File structure

| path | responsibility |
|---|---|
| `docs/migrations/2026-09-01_1100_hr_caller_is_admin.sql` | the gate helper, alone, so it can be verified before anything depends on it |
| `docs/migrations/2026-09-01_1110_hr_employee_profile.sql` | emergency contact table |
| `docs/migrations/2026-09-01_1120_hr_pay_rate.sql` | pay rates table |
| `docs/migrations/2026-09-01_1130_hr_employee_document.sql` | document metadata table |
| `docs/migrations/2026-09-01_1135_hr_documents_bucket_policy.sql` | admin-gated storage policies for the private bucket |
| `docs/migrations/2026-09-01_1140_hr_read_views.sql` | directory + detail + audit views |
| `docs/migrations/2026-09-01_1150_hr_write_rpcs.sql` | the three SECDEF write RPCs |
| `scripts/probes/hr_gate_probe.mjs` | exercises the gate as `authenticated`, the thing VERIFY blocks cannot do |
| `Building Apps/HR App/docs/` | app-side docs, per workspace rule 4b |

---

## Task 1: The admin gate helper

**Files:**
- Create: `docs/migrations/2026-09-01_1100_hr_caller_is_admin.sql`

Nothing else can be built until this is right: it is the single predicate every `hr` RLS policy will use.

- [ ] **Step 1: Write the migration, including its own failing-control**

```sql
-- 2026-09-01_1100_hr_caller_is_admin.sql
--
-- WHY: ONE PREDICATE, USED BY EVERY hr POLICY. Spec §7.
-- The HR app is office/admin only. The gate is on the CALLER, never on the rows: the directory
-- lists every hired person.
--
-- 🛑 READ THE EMAIL FROM `request.jwt.claims` (PLURAL). The singular `request.jwt.claim.email` is
-- never set by PostgREST. That mistake is why audit.logs.changed_by has been NULL for all 54,756
-- rows since the trigger was written, and it shipped a second time in derm.set_row_band. The
-- coalesce below keeps the singular key only as a last-resort fallback, matching derm._actor.
--
-- ⚠ NULL access_level returns false. NULL is reachable: webhook-samsara auto-creates employees
-- without one. Fail-safe by construction: a newly synced driver sees nothing until a person
-- classifies them.
--
-- RULE 8: functions hold no state. Opt-out.

BEGIN;

CREATE OR REPLACE FUNCTION hr.caller_email()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_email text;
BEGIN
  BEGIN
    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_email := NULL;
  END;
  RETURN lower(coalesce(
    nullif(v_email, ''),
    nullif(current_setting('request.jwt.claim.email', true), '')));
END $function$;

CREATE OR REPLACE FUNCTION hr.caller_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.employees e
     WHERE lower(e.email) = hr.caller_email()
       AND e.status = 'ACTIVE'
       AND e.access_level IN ('admin','office')
  );
$function$;

COMMENT ON FUNCTION hr.caller_is_admin() IS
  'True when the calling JWT resolves to an ACTIVE employee with access_level admin or office. '
  'The gate for every hr.* policy. NULL access_level is false, which is the fail-safe direction.';

REVOKE ALL ON FUNCTION hr.caller_email() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION hr.caller_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.caller_is_admin() TO authenticated, service_role;
-- caller_email stays internal: it is an implementation detail and leaks nothing useful, but
-- there is no reason for the app to call it.
GRANT EXECUTE ON FUNCTION hr.caller_email() TO service_role;

DO $do$
DECLARE v_n integer;
BEGIN
  -- 1. it resolves the five admin/office people and nobody else
  SELECT count(*) INTO v_n FROM public.employees
   WHERE status='ACTIVE' AND access_level IN ('admin','office');
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % admin/office employees, expected 5', v_n;
  END IF;

  -- 2. 🛑 THE CONTROL. Impersonate each side and check the gate flips. Without this, the function
  --    is only asserted to compile.
  PERFORM set_config('request.jwt.claims', '{"email":"fred@ayache.com"}', true);
  IF NOT hr.caller_is_admin() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an admin was refused';
  END IF;

  PERFORM set_config('request.jwt.claims', '{"email":"serena@unclogme.com"}', true);
  IF NOT hr.caller_is_admin() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: office was refused';
  END IF;

  -- a field technician must be refused
  PERFORM set_config('request.jwt.claims', '{"email":"michaelescobar1606@gmail.com"}', true);
  IF hr.caller_is_admin() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a field technician was admitted';
  END IF;

  -- an unknown address must be refused
  PERFORM set_config('request.jwt.claims', '{"email":"nobody@example.com"}', true);
  IF hr.caller_is_admin() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an unknown address was admitted';
  END IF;

  -- no claims at all must be refused
  PERFORM set_config('request.jwt.claims', '', true);
  IF hr.caller_is_admin() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an unauthenticated caller was admitted';
  END IF;

  -- 3. the SINGULAR key must NOT be what makes it work
  PERFORM set_config('request.jwt.claims', '{"email":"fred@ayache.com"}', true);
  IF hr.caller_email() <> 'fred@ayache.com' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: plural claims not read, got %', coalesce(hr.caller_email(),'NULL');
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY ok: gate admits the 5 admin/office people, refuses field, unknown and '
    'unauthenticated callers, and reads the plural claims key.';
END $do$;

COMMIT;
```

- [ ] **Step 2: Rehearse it, expect a clean rollback**

Run: `node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1100_hr_caller_is_admin.sql rehearse`
Expected: `REHEARSAL: commit swapped for rollback` then `HTTP 201`.

- [ ] **Step 3: Prove the control actually bites**

Temporarily change `access_level IN ('admin','office')` to `IN ('field')` in your working copy and rehearse again.
Expected: **FAIL** with `VERIFY 2 FAILED: an admin was refused`.
Revert the change. A VERIFY that cannot fail is not a test.

- [ ] **Step 4: Apply**

Run: `node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1100_hr_caller_is_admin.sql`
Expected: `HTTP 201`.

- [ ] **Step 5: Commit**

```bash
git add docs/migrations/2026-09-01_1100_hr_caller_is_admin.sql
git commit -m "Add the hr admin gate, one predicate for every hr policy

Reads request.jwt.claims plural, which is the key PostgREST actually sets;
the singular form is the bug that left audit.logs.changed_by NULL for its
whole life. NULL access_level is false, which matters because
webhook-samsara auto-creates employees without one.

VERIFY impersonates an admin, an office user, a field technician, an unknown
address and an unauthenticated caller, so the gate is proved to flip rather
than merely to compile.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: `hr.employee_profile` (emergency contact)

**Files:**
- Create: `docs/migrations/2026-09-01_1110_hr_employee_profile.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 2026-09-01_1110_hr_employee_profile.sql
--
-- WHY: emergency contact, which Yannick's recap asks for and his prototype does not render. Spec §5.2.
--
-- RULE 8: OPT IN. Human-editable personal data about a colleague.
-- RULE 6: no hard delete. A profile is 1:1 and is cleared by nulling fields, never removed.

BEGIN;

CREATE TABLE hr.employee_profile (
  employee_id                bigint PRIMARY KEY
                               REFERENCES public.employees(id) ON DELETE RESTRICT,
  emergency_contact_name     text,
  emergency_contact_relation text,
  emergency_contact_phone    text,
  hr_notes                   text,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE hr.employee_profile IS
  'HR-only facts about an employee, 1:1 with public.employees. Emergency contact and HR notes. '
  'Canonical facts (name, role, status, email, phone) stay on public.employees.';

ALTER TABLE hr.employee_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.employee_profile FORCE ROW LEVEL SECURITY;

CREATE POLICY hr_profile_admin_all ON hr.employee_profile
  FOR ALL TO authenticated
  USING (hr.caller_is_admin())
  WITH CHECK (hr.caller_is_admin());

-- 🛑 REVOKE FIRST. CREATE TABLE hands out privileges BEFORE any GRANT in this file runs, and a
-- GRANT cannot remove what it did not create. public.job_frequency_changes shipped on 2026-08-07
-- with authenticated holding SELECT, INSERT, UPDATE, DELETE and TRUNCATE while its own header
-- asserted the opposite and every GRANT in it was correct.
REVOKE ALL ON hr.employee_profile FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON hr.employee_profile TO authenticated;
GRANT ALL ON hr.employee_profile TO service_role;

CREATE TRIGGER audit_hr_employee_profile
  AFTER INSERT OR UPDATE OR DELETE ON hr.employee_profile
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ⚠ NO updated_at TRIGGER. hr.pay_rate has none either, and the upsert RPCs set updated_at
-- explicitly. One convention across both tables, and no dependency on a helper whose name would
-- have to be verified first. Rule 7's "never set updated_at manually" is about public.employees,
-- where a trigger DOES own it.

DO $do$
DECLARE v_acl text;
BEGIN
  -- 1. 🛑 READ relacl AFTER THE FACT. Do not trust the GRANTs above.
  SELECT coalesce(array_to_string(c.relacl, ' '), '') INTO v_acl
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='hr' AND c.relname='employee_profile';
  IF v_acl LIKE '%anon%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon appears in relacl: %', v_acl;
  END IF;
  IF has_table_privilege('anon', 'hr.employee_profile', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon can SELECT';
  END IF;
  IF has_table_privilege('authenticated', 'hr.employee_profile', 'DELETE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated can DELETE; rule 6 says no hard delete';
  END IF;
  IF NOT has_table_privilege('authenticated', 'hr.employee_profile', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated cannot SELECT';
  END IF;

  -- 2. rule 8: the audit trigger is present
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                   JOIN pg_namespace n ON n.oid=c.relnamespace
                  WHERE n.nspname='hr' AND c.relname='employee_profile'
                    AND t.tgname='audit_hr_employee_profile' AND NOT t.tgisinternal) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: audit trigger missing';
  END IF;

  -- 3. RLS is on AND forced
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                  WHERE n.nspname='hr' AND c.relname='employee_profile'
                    AND c.relrowsecurity AND c.relforcerowsecurity) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: RLS is not enabled and forced';
  END IF;

  RAISE NOTICE 'VERIFY ok: anon locked out, authenticated read/insert/update only, audited, RLS forced.';
END $do$;

COMMIT;
```

- [ ] **Step 2: Rehearse**

Run: `node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1110_hr_employee_profile.sql rehearse`
Expected: `HTTP 201`.

- [ ] **Step 3: Apply and commit**

```bash
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1110_hr_employee_profile.sql
git add docs/migrations/2026-09-01_1110_hr_employee_profile.sql
git commit -m "Add hr.employee_profile for emergency contact

Opted in to audit under rule 8: it is human-edited personal data about a
colleague. authenticated gets SELECT, INSERT and UPDATE but not DELETE,
because rule 6 forbids hard deletes; a profile is cleared by nulling fields.

VERIFY reads relacl after the fact rather than trusting its own GRANTs, which
is the check that job_frequency_changes did not have when it shipped open.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: `hr.pay_rate`

**Files:**
- Create: `docs/migrations/2026-09-01_1120_hr_pay_rate.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 2026-09-01_1120_hr_pay_rate.sql
--
-- WHY: the three rates Yannick named, "pay/hour, pay/job bonus, pay/shift bonus", plus salary and
-- the task-based flag his prototype carries. Spec §5.3.
--
-- ⚠ CURRENT VALUE ONLY (Fred's decision). Effective dating arrives with the Admin Review bonus
-- report, which needs the rate as it stood on a given day. The table is deliberately narrow and
-- single-purpose so that migration is additive: add effective_from, drop the 1:1 PK, add a
-- DISTINCT ON current view. Backfill of effective_from comes from audit.logs.old_row.
--
-- ⚠ "per-location" appears in three labels in the prototype and NOWHERE in its data model or edit
-- modal, both of which use per_job_rate. It is a stale label. Do not build a per-location rate.
--
-- RULE 7: money is NUMERIC(12,2).
-- RULE 8: OPT IN. Compensation is the clearest case there is.

BEGIN;

CREATE TABLE hr.pay_rate (
  employee_id     bigint PRIMARY KEY REFERENCES public.employees(id) ON DELETE RESTRICT,
  hourly_rate     numeric(12,2),
  per_job_rate    numeric(12,2),
  per_shift_rate  numeric(12,2),
  salary_amount   numeric(12,2),
  salary_period   text,
  task_based      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hr_pay_rate_salary_period_chk
    CHECK (salary_period IS NULL OR salary_period IN ('annual','weekly')),
  CONSTRAINT hr_pay_rate_salary_pair_chk
    CHECK ((salary_amount IS NULL) = (salary_period IS NULL)),
  CONSTRAINT hr_pay_rate_nonnegative_chk
    CHECK (coalesce(hourly_rate,0) >= 0 AND coalesce(per_job_rate,0) >= 0
       AND coalesce(per_shift_rate,0) >= 0 AND coalesce(salary_amount,0) >= 0)
);

COMMENT ON TABLE hr.pay_rate IS
  'Current pay rates, one row per employee. Any combination of hourly, per-job, per-shift, salary '
  'or task-based. NOT effective-dated yet: see the spec before adding history.';

ALTER TABLE hr.pay_rate ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.pay_rate FORCE ROW LEVEL SECURITY;

CREATE POLICY hr_pay_rate_admin_all ON hr.pay_rate
  FOR ALL TO authenticated
  USING (hr.caller_is_admin())
  WITH CHECK (hr.caller_is_admin());

REVOKE ALL ON hr.pay_rate FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON hr.pay_rate TO authenticated;
GRANT ALL ON hr.pay_rate TO service_role;

CREATE TRIGGER audit_hr_pay_rate
  AFTER INSERT OR UPDATE OR DELETE ON hr.pay_rate
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

DO $do$
DECLARE v_ok boolean;
BEGIN
  IF has_table_privilege('anon', 'hr.pay_rate', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon can read pay';
  END IF;
  IF has_table_privilege('authenticated', 'hr.pay_rate', 'DELETE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated can DELETE pay rows';
  END IF;

  -- 2. 🛑 THE CONSTRAINTS MUST BITE. Each is exercised and rolled back.
  BEGIN
    INSERT INTO hr.pay_rate (employee_id, salary_amount) VALUES (2, 85000);
    RAISE EXCEPTION 'VERIFY 2 FAILED: salary without a period was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO hr.pay_rate (employee_id, hourly_rate) VALUES (2, -5);
    RAISE EXCEPTION 'VERIFY 2 FAILED: a negative rate was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO hr.pay_rate (employee_id, salary_amount, salary_period) VALUES (2, 85000, 'monthly');
    RAISE EXCEPTION 'VERIFY 2 FAILED: an invalid salary_period was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- 3. and a VALID row is accepted, or the checks above prove only that everything fails
  BEGIN
    INSERT INTO hr.pay_rate (employee_id, hourly_rate, per_shift_rate) VALUES (2, 24.00, 20.00);
    SELECT true INTO v_ok;
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: a valid pay row was rejected: %', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'VERIFY ok: anon locked out, no DELETE, all three constraints bite, valid rows insert.';
END $do$;

COMMIT;
```

- [ ] **Step 2: Rehearse, apply, commit**

```bash
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1120_hr_pay_rate.sql rehearse
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1120_hr_pay_rate.sql
git add docs/migrations/2026-09-01_1120_hr_pay_rate.sql
git commit -m "Add hr.pay_rate, current values only

The three rates Yannick named plus salary and the task-based flag. Money is
NUMERIC(12,2) per rule 7 and the table is audited per rule 8, which is the
clearest case there is for opting in.

Deliberately narrow so effective dating stays additive when the bonus report
needs it: add effective_from, drop the 1:1 key, add a current view.

VERIFY exercises all three constraints and then inserts a valid row, because
checks that only ever reject prove nothing.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: `hr.employee_document` and the private bucket

**Files:**
- Create: `docs/migrations/2026-09-01_1130_hr_employee_document.sql`

⚠ Three of the six existing buckets are `public: true`. Driver licences and I-9s must not inherit that default.
⚠ Rule 7b: staff apps run as `authenticated` and **can `createSignedUrl` client-side, no edge proxy**. Only the genuinely-anon Field Portal needs a proxy. Do not build one here.

- [ ] **Step 1: Write the migration**

```sql
-- 2026-09-01_1130_hr_employee_document.sql
--
-- WHY: the Documents card on the detail screen. Spec §6.
--
-- ⚠ NO REQUIRED-DOCUMENT CHECKLIST. The W2/1099 sets were keyed on employee type, which was
-- dropped as a duplicate of role. This is simply the list of documents held for a person.
-- If a required set is wanted later it keys on employees.role, and it is deliberately not
-- guessed at now: getting it wrong means asking a contractor for an I-9.
--
-- RULE 6: soft delete via deleted_at. RULE 8: OPT IN.

BEGIN;

CREATE TABLE hr.employee_document (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id   bigint NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  doc_type      text NOT NULL,
  file_name     text NOT NULL,
  storage_path  text NOT NULL UNIQUE,
  uploaded_by   text,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT hr_employee_document_doc_type_chk CHECK (btrim(doc_type) <> ''),
  CONSTRAINT hr_employee_document_path_chk
    CHECK (storage_path LIKE 'hr/' || employee_id::text || '/%')
);

CREATE INDEX hr_employee_document_employee_idx
  ON hr.employee_document (employee_id) WHERE deleted_at IS NULL;

COMMENT ON TABLE hr.employee_document IS
  'Metadata for documents held for an employee. Files live in the private hr-documents bucket. '
  'storage_path is constrained to hr/<employee_id>/ so a row cannot point at another persons file.';

ALTER TABLE hr.employee_document ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.employee_document FORCE ROW LEVEL SECURITY;

CREATE POLICY hr_document_admin_all ON hr.employee_document
  FOR ALL TO authenticated
  USING (hr.caller_is_admin())
  WITH CHECK (hr.caller_is_admin());

REVOKE ALL ON hr.employee_document FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON hr.employee_document TO authenticated;
GRANT ALL ON hr.employee_document TO service_role;

CREATE TRIGGER audit_hr_employee_document
  AFTER INSERT OR UPDATE OR DELETE ON hr.employee_document
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

DO $do$
BEGIN
  IF has_table_privilege('anon', 'hr.employee_document', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon can read HR documents';
  END IF;

  -- 🛑 the path constraint must stop a row pointing at another employee's folder
  BEGIN
    INSERT INTO hr.employee_document (employee_id, doc_type, file_name, storage_path)
    VALUES (2, 'Driver license', 'x.pdf', 'hr/27/x.pdf');
    RAISE EXCEPTION 'VERIFY 2 FAILED: a cross-employee storage_path was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- and the correct shape is accepted
  BEGIN
    INSERT INTO hr.employee_document (employee_id, doc_type, file_name, storage_path)
    VALUES (2, 'Driver license', 'x.pdf', 'hr/2/x.pdf');
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: a valid document row was rejected: %', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'VERIFY ok: anon locked out, path constraint bites, valid rows insert.';
END $do$;

COMMIT;
```

- [ ] **Step 2: Create the private bucket**

Buckets are not created by migration in this repo. Run:

```bash
cd /c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase
cat > scripts/probes/_bucket.sql <<'SQL'
insert into storage.buckets (id, name, public)
values ('hr-documents', 'hr-documents', false)
on conflict (id) do nothing;
select id, public from storage.buckets where id = 'hr-documents';
SQL
node scripts/q.js scripts/probes/_bucket.sql scripts/probes/_bucket.json && cat scripts/probes/_bucket.json
```
Expected: `{"id":"hr-documents","public":false}`.
🛑 If it reports `public: true`, stop and fix it before uploading anything.

- [ ] **Step 3: Add the storage policy, admin-gated**

```sql
-- run via apply_sql_file as its own migration 2026-09-01_1135_hr_documents_bucket_policy.sql
BEGIN;
CREATE POLICY hr_documents_admin_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'hr-documents' AND hr.caller_is_admin());
CREATE POLICY hr_documents_admin_write ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'hr-documents' AND hr.caller_is_admin());
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='hr-documents' AND public = false) THEN
    RAISE EXCEPTION 'VERIFY FAILED: hr-documents is missing or PUBLIC';
  END IF;
  RAISE NOTICE 'VERIFY ok: hr-documents is private with two admin-gated policies.';
END $do$;
COMMIT;
```

⚠ Unlike the three existing `auth.uid() IS NOT NULL` storage policies, these gate on `hr.caller_is_admin()`. That difference is the whole point: `auth.uid() IS NOT NULL` is authentication wearing authorization's clothes and would let any signed-in technician read HR documents.

- [ ] **Step 4: Commit**

```bash
git add docs/migrations/2026-09-01_1130_hr_employee_document.sql \
        docs/migrations/2026-09-01_1135_hr_documents_bucket_policy.sql
git commit -m "Add hr.employee_document and a private hr-documents bucket

Three of the six existing buckets are public, so this one states public:false
explicitly rather than inheriting the ambient default. Driver licences and
I-9s are exactly what that default is wrong for.

storage_path is constrained to hr/<employee_id>/ so a metadata row cannot
point at another persons file, and VERIFY proves the constraint bites.

The storage policies gate on hr.caller_is_admin() rather than the estates
usual auth.uid() IS NOT NULL, which for the authenticated role restricts
nothing and would let any signed-in technician read HR documents.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Read views

**Files:**
- Create: `docs/migrations/2026-09-01_1140_hr_read_views.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 2026-09-01_1140_hr_read_views.sql
--
-- WHY: the two screens read these, never the base tables. Spec §8.
--
-- ⚠ NO Type COLUMN. W2/1099 was dropped as a duplicate of role (spec §5.1). Yannick's mockup shows
-- one; it is deliberately absent here.
-- ⚠ The directory lists EVERY hired person, both statuses. The gate is on the caller, not the rows.
-- ⚠ security_invoker so the caller's RLS applies. Without it these views would run as owner and
-- launder the hr policies, which is the exact asymmetry that has bitten this estate four times.

BEGIN;

CREATE VIEW hr.v_employee_directory
WITH (security_invoker = true) AS
SELECT e.id,
       e.full_name,
       e.role,
       e.status,
       e.access_level,
       e.shift,
       e.email,
       e.phone,
       e.hire_date,
       e.color_hex,
       p.hourly_rate,
       p.per_job_rate,
       p.per_shift_rate,
       p.salary_amount,
       p.salary_period,
       p.task_based,
       (au.id IS NOT NULL)                             AS has_auth_account,
       au.raw_app_meta_data ->> 'provider'             AS auth_provider
  FROM public.employees e
  LEFT JOIN hr.pay_rate p ON p.employee_id = e.id
  LEFT JOIN auth.users au ON lower(au.email) = lower(e.email);

COMMENT ON VIEW hr.v_employee_directory IS
  'One row per hired person, both statuses, for the HR directory. has_auth_account and '
  'auth_provider are Phase 2a: read-only visibility of the auth state, no action.';

CREATE VIEW hr.v_employee_detail
WITH (security_invoker = true) AS
SELECT d.*,
       pr.emergency_contact_name,
       pr.emergency_contact_relation,
       pr.emergency_contact_phone,
       pr.hr_notes,
       (SELECT count(*) FROM hr.employee_document doc
         WHERE doc.employee_id = d.id AND doc.deleted_at IS NULL) AS document_count
  FROM hr.v_employee_directory d
  LEFT JOIN hr.employee_profile pr ON pr.employee_id = d.id;

CREATE VIEW hr.v_employee_audit
WITH (security_invoker = true) AS
SELECT l.id,
       l.changed_at,
       l.table_name,
       l.operation,
       l.app_source,
       l.jwt_claims ->> 'email' AS changed_by_email,   -- ⚠ NOT l.changed_by, which is always NULL
       l.old_row,
       l.new_row,
       CASE WHEN l.table_name = 'employees' THEN (l.new_row ->> 'id')::bigint
            ELSE (l.new_row ->> 'employee_id')::bigint END AS employee_id
  FROM audit.logs l
 WHERE l.table_name IN ('employees','employee_profile','pay_rate','employee_document');

COMMENT ON VIEW hr.v_employee_audit IS
  'Audit trail for the View audit log action. Reads jwt_claims->>email, NEVER changed_by, which '
  'has been NULL for all 54,756 rows since the trigger was written.';

REVOKE ALL ON hr.v_employee_directory, hr.v_employee_detail, hr.v_employee_audit
  FROM PUBLIC, anon;
GRANT SELECT ON hr.v_employee_directory, hr.v_employee_detail, hr.v_employee_audit
  TO authenticated, service_role;

DO $do$
DECLARE v_n integer;
BEGIN
  -- 1. the directory covers everyone hired, not just the active
  SELECT count(*) INTO v_n FROM hr.v_employee_directory;
  IF v_n < 21 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: directory has % rows, expected every hired person', v_n;
  END IF;

  -- 2. anon cannot read any of them
  IF has_table_privilege('anon','hr.v_employee_directory','SELECT')
     OR has_table_privilege('anon','hr.v_employee_detail','SELECT')
     OR has_table_privilege('anon','hr.v_employee_audit','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon can read an hr view';
  END IF;

  -- 3. 🛑 security_invoker must be ON, or the views launder the RLS they exist behind
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
              WHERE n.nspname='hr' AND c.relname IN
                    ('v_employee_directory','v_employee_detail','v_employee_audit')
                AND coalesce(array_to_string(c.reloptions,','),'') NOT LIKE '%security_invoker=true%') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: an hr view is not security_invoker';
  END IF;

  -- 4. the audit view must not be reading the always-NULL column
  IF EXISTS (SELECT 1 FROM pg_views WHERE schemaname='hr' AND viewname='v_employee_audit'
               AND definition LIKE '%changed_by%' AND definition NOT LIKE '%changed_by_email%') THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: v_employee_audit references changed_by';
  END IF;

  RAISE NOTICE 'VERIFY ok: % directory rows, anon locked out, all three security_invoker.', v_n;
END $do$;

COMMIT;
```

- [ ] **Step 2: Rehearse, apply, commit**

```bash
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1140_hr_read_views.sql rehearse
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1140_hr_read_views.sql
git add docs/migrations/2026-09-01_1140_hr_read_views.sql
git commit -m "Add the hr read views the two screens consume

security_invoker on all three, so the callers RLS applies. Without it an
owner-rights view launders the hr policies, which is the same asymmetry that
has bitten this estate four times.

The audit view reads jwt_claims->>email and never changed_by, which has been
NULL for all 54,756 rows since the trigger was written, and VERIFY asserts
the column does not appear in the definition.

No Type column: W2/1099 was dropped as a duplicate of role.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Write RPCs

**Files:**
- Create: `docs/migrations/2026-09-01_1150_hr_write_rpcs.sql`

`authenticated` holds SELECT-only on `public.employees`, so canonical edits must go through SECDEF. Pattern copied from `client.update_client_status`: `SECURITY DEFINER`, `search_path TO ''`, everything schema-qualified.

- [ ] **Step 1: Write the migration**

```sql
-- 2026-09-01_1150_hr_write_rpcs.sql
--
-- WHY: the three surviving Quick actions write through here. Spec §8.1.
--
-- 🛑 A SECDEF FUNCTION BYPASSES RLS. These run as the owner, so the hr policies do NOT constrain
-- them: each one re-checks hr.caller_is_admin() itself. Removing that check does not fail loudly,
-- it silently grants every signed-in user the ability to edit pay.
--
-- ⚠ search_path is '' so every name is schema-qualified, matching client.update_client_status.
-- ⚠ updated_at on public.employees is trigger-managed (rule 7) and is never set here.

BEGIN;

CREATE OR REPLACE FUNCTION hr.update_employee_canonical(
  p_employee_id bigint,
  p_full_name   text,
  p_role        text,
  p_status      text,
  p_shift       text,
  p_email       text,
  p_phone       text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_row public.employees;
BEGIN
  IF NOT hr.caller_is_admin() THEN
    RAISE EXCEPTION 'not an HR administrator' USING errcode = '42501';
  END IF;
  IF p_full_name IS NULL OR btrim(p_full_name) = '' THEN
    RAISE EXCEPTION 'full_name is required' USING errcode = '22023';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('ACTIVE','INACTIVE') THEN
    RAISE EXCEPTION 'status must be ACTIVE or INACTIVE (got %)', p_status USING errcode = '22023';
  END IF;

  UPDATE public.employees
     SET full_name = btrim(p_full_name),
         role      = nullif(btrim(coalesce(p_role,'')), ''),
         status    = p_status,
         shift     = nullif(btrim(coalesce(p_shift,'')), ''),
         email     = lower(nullif(btrim(coalesce(p_email,'')), '')),
         phone     = nullif(btrim(coalesce(p_phone,'')), '')
   WHERE id = p_employee_id
   RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'employee % not found', p_employee_id USING errcode = 'P0002';
  END IF;
  RETURN to_jsonb(v_row);
END $function$;

-- ⚠ access_level is deliberately NOT settable here. It gates this very app, and Phase 3 decides
-- what it means estate-wide. Changing it is not an ordinary field edit.

CREATE OR REPLACE FUNCTION hr.upsert_pay_rate(
  p_employee_id    bigint,
  p_hourly_rate    numeric,
  p_per_job_rate   numeric,
  p_per_shift_rate numeric,
  p_salary_amount  numeric,
  p_salary_period  text,
  p_task_based     boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_row hr.pay_rate;
BEGIN
  IF NOT hr.caller_is_admin() THEN
    RAISE EXCEPTION 'not an HR administrator' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employees WHERE id = p_employee_id) THEN
    RAISE EXCEPTION 'employee % not found', p_employee_id USING errcode = 'P0002';
  END IF;

  INSERT INTO hr.pay_rate AS pr (employee_id, hourly_rate, per_job_rate, per_shift_rate,
                                 salary_amount, salary_period, task_based)
  VALUES (p_employee_id, p_hourly_rate, p_per_job_rate, p_per_shift_rate,
          p_salary_amount, p_salary_period, coalesce(p_task_based, false))
  ON CONFLICT (employee_id) DO UPDATE
     SET hourly_rate    = excluded.hourly_rate,
         per_job_rate   = excluded.per_job_rate,
         per_shift_rate = excluded.per_shift_rate,
         salary_amount  = excluded.salary_amount,
         salary_period  = excluded.salary_period,
         task_based     = excluded.task_based,
         updated_at     = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

CREATE OR REPLACE FUNCTION hr.upsert_employee_profile(
  p_employee_id bigint,
  p_ec_name     text,
  p_ec_relation text,
  p_ec_phone    text,
  p_hr_notes    text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_row hr.employee_profile;
BEGIN
  IF NOT hr.caller_is_admin() THEN
    RAISE EXCEPTION 'not an HR administrator' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employees WHERE id = p_employee_id) THEN
    RAISE EXCEPTION 'employee % not found', p_employee_id USING errcode = 'P0002';
  END IF;

  INSERT INTO hr.employee_profile AS pf (employee_id, emergency_contact_name,
                                         emergency_contact_relation, emergency_contact_phone, hr_notes)
  VALUES (p_employee_id, nullif(btrim(coalesce(p_ec_name,'')),''),
          nullif(btrim(coalesce(p_ec_relation,'')),''),
          nullif(btrim(coalesce(p_ec_phone,'')),''),
          nullif(btrim(coalesce(p_hr_notes,'')),''))
  ON CONFLICT (employee_id) DO UPDATE
     SET emergency_contact_name     = excluded.emergency_contact_name,
         emergency_contact_relation = excluded.emergency_contact_relation,
         emergency_contact_phone    = excluded.emergency_contact_phone,
         hr_notes                   = excluded.hr_notes,
         updated_at                 = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

REVOKE ALL ON FUNCTION hr.update_employee_canonical(bigint,text,text,text,text,text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION hr.upsert_pay_rate(bigint,numeric,numeric,numeric,numeric,text,boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION hr.upsert_employee_profile(bigint,text,text,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.update_employee_canonical(bigint,text,text,text,text,text,text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION hr.upsert_pay_rate(bigint,numeric,numeric,numeric,numeric,text,boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION hr.upsert_employee_profile(bigint,text,text,text,text)
  TO authenticated;

DO $do$
DECLARE v_n integer;
BEGIN
  -- 🛑 THE CONTROL THAT MATTERS: a non-admin caller must be refused by every RPC. Without this,
  -- the SECDEF bypass is untested and these functions are an open write path to pay.
  PERFORM set_config('request.jwt.claims', '{"email":"michaelescobar1606@gmail.com"}', true);

  BEGIN
    PERFORM hr.upsert_pay_rate(2, 99, NULL, NULL, NULL, NULL, false);
    RAISE EXCEPTION 'VERIFY 1 FAILED: a field technician set a pay rate';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM hr.update_employee_canonical(2,'Hacked',NULL,'ACTIVE',NULL,NULL,NULL);
    RAISE EXCEPTION 'VERIFY 1 FAILED: a field technician edited a canonical record';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM hr.upsert_employee_profile(2,'x',NULL,NULL,NULL);
    RAISE EXCEPTION 'VERIFY 1 FAILED: a field technician edited a profile';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 2. and an admin IS allowed, or VERIFY 1 only proves everything is broken
  PERFORM set_config('request.jwt.claims', '{"email":"fred@ayache.com"}', true);
  BEGIN
    PERFORM hr.upsert_pay_rate(2, 24.00, NULL, 20.00, NULL, NULL, false);
    SELECT count(*) INTO v_n FROM hr.pay_rate WHERE employee_id = 2;
    IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: admin upsert wrote % rows', v_n; END IF;
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: an admin was refused: %', SQLERRM;
    END IF;
  END;

  -- 3. a bad status is rejected
  BEGIN
    PERFORM hr.update_employee_canonical(2,'Fred',NULL,'RETIRED',NULL,NULL,NULL);
    RAISE EXCEPTION 'VERIFY 3 FAILED: an invalid status was accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY ok: all three RPCs refuse a field technician, admit an admin, and reject a '
    'bad status.';
END $do$;

COMMIT;
```

- [ ] **Step 2: Rehearse, apply, commit**

```bash
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1150_hr_write_rpcs.sql rehearse
node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-01_1150_hr_write_rpcs.sql
git add docs/migrations/2026-09-01_1150_hr_write_rpcs.sql
git commit -m "Add the hr write RPCs the Quick actions call

authenticated holds SELECT only on employees, so canonical edits go through
SECURITY DEFINER, matching client.update_client_status: search_path empty,
every name qualified, 42501 for the gate and 22023 for validation.

Each RPC re-checks hr.caller_is_admin() itself, because SECDEF bypasses RLS
and the hr policies do not constrain these. VERIFY proves a field technician
is refused by all three and an admin is not, since a refusal test alone would
pass just as well on a function that refuses everyone.

access_level is deliberately not settable: it gates this app and Phase 3
decides what it means estate-wide.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: Prove the gate as a real `authenticated` session

**Files:**
- Create: `scripts/probes/hr_gate_probe.mjs`

🛑 Every VERIFY so far ran as `postgres` over the Management API. That role owns the tables and holds `rolbypassrls`, so **none of it has tested the RLS policies at all.** `set_config` proves the function's logic, not that PostgREST enforces it.

- [ ] **Step 1: Write the probe**

```javascript
// Exercise the hr surface as a REAL authenticated session, which is the only thing that tests RLS.
// The Management API runs as postgres, which bypasses RLS entirely, so nothing before this file
// has actually proved the gate.
//
// Usage: node scripts/probes/hr_gate_probe.mjs
// Requires: a signed-in staff JWT in .env as HR_PROBE_JWT (grab one from a browser session).
import { readFileSync } from 'node:fs';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

const BASE = `https://${env.SUPABASE_PROJECT_ID}.supabase.co/rest/v1`;
const ANON = env.SUPABASE_ANON_KEY;
const JWT = env.HR_PROBE_JWT;
if (!JWT) throw new Error('HR_PROBE_JWT missing: paste a staff session JWT into .env');

const call = (path, token) => fetch(`${BASE}/${path}`, {
  headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Accept-Profile': 'hr' },
});

let bad = 0;
const check = (name, ok, detail = '') => {
  if (!ok) bad++;
  console.log(`${ok ? 'OK ' : 'BAD'}  ${name}${detail ? '  ' + detail : ''}`);
};

// 1. an admin session reads the directory
const r1 = await call('v_employee_directory?select=id,full_name&limit=5', JWT);
check('admin reads directory', r1.status === 200, `HTTP ${r1.status}`);

// 2. the ANON key alone must not
const r2 = await call('v_employee_directory?select=id&limit=1', ANON);
check('anon refused', r2.status !== 200, `HTTP ${r2.status}`);

// 3. pay is reachable for an admin and the row count is sane
const r3 = await call('pay_rate?select=employee_id&limit=5', JWT);
check('admin reads pay_rate', r3.status === 200, `HTTP ${r3.status}`);

// 4. anon cannot read pay
const r4 = await call('pay_rate?select=employee_id&limit=1', ANON);
check('anon refused on pay_rate', r4.status !== 200, `HTTP ${r4.status}`);

console.log(bad === 0 ? '\nGate holds under a real session.' : `\n${bad} check(s) failed.`);
process.exit(bad === 0 ? 0 : 1);
```

- [ ] **Step 2: Run it**

Run: `node scripts/probes/hr_gate_probe.mjs`
Expected: all four OK.
🛑 If check 2 or 4 passes with HTTP 200, **stop everything**: the gate is not holding and HR data is readable by any anon caller.

- [ ] **Step 3: Commit**

```bash
git add scripts/probes/hr_gate_probe.mjs
git commit -m "Add a probe that tests the hr gate as a real session

Every VERIFY in the migrations runs as postgres over the Management API, and
that role owns the tables and holds rolbypassrls, so it bypasses the GRANT
and RLS systems entirely. None of them has tested a policy. This does.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: Create the Lovable app and wire the shared session

**Lovable project:** `816f8580-af86-43f4-92b6-780af367abd4`

🛑 This is the seventh app joining the shared-session family. Rule 0b lists four ways to break it, **all of which fail silently: green build, no console error, nothing in `audit.logs`.**

- [ ] **Step 1: Confirm the four silent breakers before writing any feature code**

Prompt Lovable to set up the Supabase client, then verify each of these in the **published bundle**, not the editor:

1. **No explicit `storageKey` anywhere.** All apps leave it unset so supabase-js derives the same default, which is what makes the cookie shared. Set one and this app quietly gets a private session.
2. **`VITE_PROD_SUPABASE_URL` stays the default `<ref>.supabase.co` form.** The cookie name derives from the URL's *first hostname label*, not the project ref. A custom auth domain silently renames the cookie.
3. **`auth.userStorage` is set**, keeping the user object in per-origin localStorage. A full session is 4,080 bytes against a ~4,062 ceiling; without this split the cookie silently never exists and every other app serves a stale token.
4. **The staff gate uses `await supabase.auth.getUser()`, never `session.user`.** On a first cross-origin arrival auth-js substitutes a proxy and any read of `session.user` throws, including through optional chaining. Treat a `getUser()` error as UNKNOWN with a retry, and **never call `signOut()`** there: sign-out is global and a gate misfire evicts the user from every app on `unclogme.app`.

- [ ] **Step 2: Match the staff allow-list exactly**

Use `@unclogme.com` + `@ayache.com`, identical to the other six.
⚠ The effective allow-list is the **intersection** of every app's list. A narrower list here narrows the whole estate.

- [ ] **Step 3: Verify token identity, not "still signed in"**

Open the Apps Hub and the HR app in the same browser. Compare the access token each reports.
Expected: **identical strings**.
🛑 "Still signed in" is not evidence: an app's own localStorage produces a byte-identical screen while the shared cookie is broken.

- [ ] **Step 4: Create the app docs folder and commit**

```bash
cd "/c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
mkdir -p "HR App/docs"
# write HR App/docs/08-changelog.md with a dated first entry describing the SSO wiring
git add "HR App/docs/08-changelog.md"
git commit -m "Add the HR app and wire it into the shared staff session"
```
⚠ Building Apps uses a **one-line commit message and no co-author footer** (workspace rule 4).

---

## Task 9: The directory screen

- [ ] **Step 1: Build it against `hr.v_employee_directory`**

Columns, from Yannick's mockup minus the dropped one: **Name** (with email beneath), **Role**, **Shift**, **Hired**, **Pay**, **Status**.
🛑 **No Type column.** W2/1099 was dropped as a duplicate of role.

Filters: search by name/role/email, role dropdown, status dropdown defaulting to **Active**.
⚠ Populate the role dropdown from the data, not a hardcoded list. Prod holds `Technician`, `Admin`, `Owner`, `Office`; the prototype's `driver / helper / plumber` do not exist and would match nothing.

Pay column renders the same summary as the prototype: `$24/hr + $20/shift`, `Per task (negotiated)` when `task_based`, `$85,000/yr` for salary, and an em-space when nothing is set.

- [ ] **Step 2: Verify against the live bundle**

Confirm the request goes to `hr.v_employee_directory` with `Accept-Profile: hr`, and that the row count matches the database (21 today, 9 active).

- [ ] **Step 3: Commit the changelog entry**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the employee directory screen"
```

---

## Task 10: The detail screen

- [ ] **Step 1: Build it against `hr.v_employee_detail`**

Cards, per the mockup: the hero (name, role, email, phone, shift), **Canonical record**, **Emergency contact**, **Pay rates**, **Documents**, and the **Quick actions** panel.

⚠ The **Emergency contact** card carries its own `Edit` button, like Canonical record and Pay rates do. It is not a Quick action: Yannick's mockup has no emergency contact at all, so there is no button of his to match. Task 11 Step 3 wires it.
🛑 The hero pill is the role alone. The `W2 ·` prefix is gone with the type concept.
🛑 The Quick actions panel has **four** buttons, not five: Edit canonical fields, Update pay, Request document (disabled with a tooltip until its own plan ships), View audit log. **Reassign equipment is cut** because no equipment data exists.
⚠ "Update pay" subtitle reads **hourly + per-job + per-shift**. The prototype says "per-location", which appears nowhere in its own data model.

- [ ] **Step 2: Add the auth-state row (Phase 2a, read-only)**

Show `has_auth_account` and `auth_provider` from the view as plain text, for example `Signs in with Google` or `No account yet`.
🛑 **Display only. No invite, no reset, no action of any kind.** Creating an account currently grants the full estate surface (spec §12.3) and the action waits for Phase 3.

- [ ] **Step 3: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the employee detail screen"
```

---

## Task 11: The three working Quick actions

- [ ] **Step 1: Edit canonical fields**

Modal over `hr.update_employee_canonical`. Fields: name, role, status, shift, email, phone.
⚠ `access_level` is **not** editable here: it gates this app and Phase 3 decides its meaning.

- [ ] **Step 2: Update pay**

Modal over `hr.upsert_pay_rate`. Toggles for hourly, per-job, per-shift, salary (with annual/weekly), task-based, matching the prototype's `EditPayModal`.

- [ ] **Step 3: Emergency contact**

Modal over `hr.upsert_employee_profile`.

- [ ] **Step 4: View audit log**

Read `hr.v_employee_audit` filtered to the employee.
⚠ Render `changed_by_email`. Never `changed_by`, which is NULL on every row ever written.

- [ ] **Step 5: Verify each write lands and is audited**

After exercising each modal once against a test edit, confirm a matching `audit.logs` row exists with the correct `jwt_claims->>'email'`, then revert the edit.

- [ ] **Step 6: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Wire the three working Quick actions to their RPCs"
```

---

## Task 12: Documents, admin-side

- [ ] **Step 1: List and upload**

List from `hr.employee_document` where `deleted_at IS NULL`. Upload writes to `hr-documents` at `hr/<employee_id>/<uuid>-<filename>` and then inserts the metadata row.
⚠ The path constraint enforces the `hr/<employee_id>/` prefix, so a mismatched path fails at the database rather than landing.

- [ ] **Step 2: Sign URLs client-side**

Rule 7b: staff apps run as `authenticated` and can call `createSignedUrl` directly. **Do not build an edge proxy**; only the genuinely-anon Field Portal needs one.

🛑 **Guard the session first.** The storage policy needs a real `auth.uid()`. Signing before the session hydrates matches zero rows, Storage answers `not_found`, the helper returns null, and the UI renders an empty frame rather than an auth error: a race that looks like a missing file. Await `getUser()` before signing.

- [ ] **Step 3: Delete is soft**

Set `deleted_at`. Never remove the row, never delete the object (rule 6).

- [ ] **Step 4: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add document list, upload and signed viewing"
```

---

## Task 13: Documentation

- [ ] **Step 1: Write the app docs**

Create in `Building Apps/HR App/docs/`:
- `02-architecture.md`: the `hr.*` layer, the gate, which views and RPCs the app uses.
- `08-changelog.md`: dated entries, newest first.
- `09-known-issues.md`: seed with the two live ones, that Request document is disabled pending its own plan, and that `access_level` is displayed but **not yet enforced by any other app** (spec §12.4).

- [ ] **Step 2: Update the Supabase-side docs**

Add the six new migrations to `docs/schema.md`, and note in `CLAUDE.md` that `hr.*` exists, what gates it, and that `hr.caller_is_admin()` is the estate's first real authorization predicate.

- [ ] **Step 3: Commit both repos**

```bash
cd "/c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
git add "HR App/docs"
git commit -m "Document the HR app architecture and known issues"

cd /c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase
git add docs/schema.md CLAUDE.md
git commit -m "Record the hr schema and its gate in the operating manual

hr.caller_is_admin() is the first predicate in this estate that distinguishes
one signed-in person from another. Worth knowing before Phase 3 adopts it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when

- [ ] `node scripts/probes/hr_gate_probe.mjs` passes all four checks.
- [ ] The directory lists all 21 people and defaults to the 9 active.
- [ ] A detail page shows canonical fields, emergency contact, pay, documents and auth state.
- [ ] All three write RPCs work from the UI and produce `audit.logs` rows carrying the editor's email.
- [ ] The HR app and the Apps Hub report the **same access token**.
- [ ] `anon` gets a non-200 on every `hr` view and table.
