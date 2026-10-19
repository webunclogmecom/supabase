-- 2026-10-19_1240_hr_drop_company_bonus_fns
-- Fred, 2026-10-19: "yes remove them" (asked whether to retire the company bonus functions now that no app calls them).
-- Bonuses are per person since 2026-10-19_1200. Admin Review reads hr.get_person_bonus_amounts (live App-f_mSh_ov.js,
-- 0 mentions of get_bonus_amounts) and the HR App edits through hr.set_person_bonus (live bundle: 0 mentions of either
-- old name). Measured before writing: no function or view calls them (three function bodies name them in COMMENTS only:
-- fn_rate_on, set_person_bonus, get_person_bonus_amounts), no repo code calls them outside docs and probes.
-- ⚠ A browser tab still holding an Admin Review bundle older than the per-person build will show "$—" until reloaded.
-- Drops:
--   hr.get_bonus_amounts()                           md5 7c9195c94fe9c5a554b7893749bc159d
--   hr.set_company_bonus(text,numeric,date,text)     md5 aea37b768a8b9a40977eb012f7ee8bb9
-- Kept on purpose: the company rows in hr.pay_rates (employee_id NULL) are history, and hr.fn_rate_on(NULL, ...) still
-- reads them (get_employee_record's company_bonus key). Nothing pays from them.
-- Rule 8: no table touched. Rollback: 2026-10-19_rollback_hr_drop_company_bonus_fns.sql (the exact bodies + grants).
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_bonus_amounts()'::regprocedure)) <> '7c9195c94fe9c5a554b7893749bc159d'
     OR md5(pg_get_functiondef('hr.set_company_bonus(text,numeric,date,text)'::regprocedure)) <> 'aea37b768a8b9a40977eb012f7ee8bb9' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild the rollback first';
  END IF;
END $guard$;

DROP FUNCTION hr.get_bonus_amounts();
DROP FUNCTION hr.set_company_bonus(text, numeric, date, text);

-- VERIFY
DO $verify$
DECLARE n int;
BEGIN
  IF to_regprocedure('hr.get_bonus_amounts()') IS NOT NULL OR to_regprocedure('hr.set_company_bonus(text,numeric,date,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: a function is still there';
  END IF;
  -- the six the apps use are untouched and still callable by authenticated
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'hr' AND p.proname IN ('update_employee','get_employee_record','get_pay_summary','set_pay_rates','set_person_bonus','get_person_bonus_amounts')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
  IF n <> 6 THEN RAISE EXCEPTION 'VERIFY: expected 6 app functions callable by authenticated, got %', n; END IF;
  -- control: a person's rate still reads, and the company rows still answer for NULL
  IF (SELECT r.amount FROM hr.fn_rate_on(40, 'per_visit_bonus', current_date) r) IS NULL
     OR (SELECT r.amount FROM hr.fn_rate_on(NULL, 'per_visit_bonus', current_date) r) IS NULL THEN
    RAISE EXCEPTION 'VERIFY: fn_rate_on control failed';
  END IF;
END $verify$;
COMMIT;
