-- 2026-09-01_0930_aaron_company_email.sql
--
-- WHY: AARON IS IN THE OFFICE GROUP AND CANNOT BE RESOLVED BY ANY JWT GATE.
-- ---------------------------------------------------------------------------
-- Fred, 2026-09-01: "for now leave aaron email as aaron@unclogme.com so his auth account would be
-- for now at Gmail oauth until he do the flow of Forget password etc."
--
-- The HR app gates on `employees.access_level IN ('admin','office')`, resolved from the caller's
-- JWT email. Aaron is `office` (corrected in 2026-08-31_1330) and held NO email on either of his
-- rows, so the gate could never match him and he could not open the app at all. This is the
-- prerequisite recorded as still-open in the design doc.
--
-- ⚠ THIS IS THE DATABASE HALF ONLY. It does not create an auth account: that is a Supabase Auth
-- operation, and Auth (GoTrue) is DOWN as of 2026-09-01 13:17 UTC (`public.auth_recovery_state`
-- reads `status='down'`, with jwks, health, login and settings all 503). Aaron signs in with Google
-- OAuth on `aaron@unclogme.com` once Auth is back; nothing here can be tested until then.
--
-- ⚠ `unclogme.com` is a Google Workspace domain: `serena@unclogme.com` and `contact@unclogme.com`
-- are both live Google-provider accounts in `auth.users`, so the address shape is right.
--
-- 🛑 ONLY id 26 IS TOUCHED. Aaron has TWO employee rows: id 26 (ACTIVE, 58 visit_team rows, the
-- survivor) and id 16 `A Azoulay (admin)` (INACTIVE, 0 visit_team rows, his retired duplicate).
-- Giving the retired row an address would create a second employee matching the same auth user,
-- which is exactly the ambiguity the Michael Escobar consolidation existed to remove.
--
-- RULE 8: `public.employees` is audited, so this is captured with `old_row` and is revertible.
-- RULE 7: `updated_at` is trigger-managed and is deliberately not set here.

BEGIN;

DO $do$
DECLARE v_n integer;
BEGIN
  -- the row must be the live Aaron, still without an address
  SELECT count(*) INTO v_n FROM public.employees
   WHERE id = 26 AND full_name = 'Aaron' AND status = 'ACTIVE'
     AND access_level = 'office' AND coalesce(email, '') = '';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PART 0: id 26 is not the live, office, email-less Aaron; re-read before writing';
  END IF;

  -- nobody else may already hold that address, or the gate would resolve to two people
  SELECT count(*) INTO v_n FROM public.employees WHERE lower(email) = 'aaron@unclogme.com';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PART 0: % employee row(s) already hold aaron@unclogme.com', v_n;
  END IF;
END $do$;

UPDATE public.employees
   SET email = 'aaron@unclogme.com'
 WHERE id = 26 AND coalesce(email, '') = '';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_txt text;
BEGIN
  SELECT email INTO v_txt FROM public.employees WHERE id = 26;
  IF v_txt IS DISTINCT FROM 'aaron@unclogme.com' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: id 26 email is %', coalesce(v_txt, 'NULL');
  END IF;

  -- the retired duplicate must still have none
  SELECT coalesce(email, '') INTO v_txt FROM public.employees WHERE id = 16;
  IF v_txt <> '' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the retired row id 16 now holds an email (%)', v_txt;
  END IF;

  -- exactly one employee holds the address
  SELECT count(*) INTO v_n FROM public.employees WHERE lower(email) = 'aaron@unclogme.com';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % rows hold the address', v_n; END IF;

  -- ✅ the point of the change: every admin/office employee can now be resolved by email
  SELECT count(*) INTO v_n FROM public.employees
   WHERE status = 'ACTIVE' AND access_level IN ('admin','office') AND coalesce(email,'') = '';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % admin/office employee(s) still have no email', v_n;
  END IF;

  -- and it was audited
  SELECT count(*) INTO v_n FROM audit.logs
   WHERE table_name = 'employees' AND changed_at > now() - interval '1 minute';
  IF v_n < 1 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: the change was not audited'; END IF;

  RAISE NOTICE 'VERIFY ok: Aaron (id 26) is aaron@unclogme.com, the retired id 16 still has none, '
    'and all 5 admin/office employees can now be resolved by email. Auth account still to be '
    'created once GoTrue is back.';
END $do$;

COMMIT;
