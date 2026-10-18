-- ROLLBACK of 2026-10-18_0400_hr_pay_rates_and_bonus_history.sql.
-- Removes the hourly sweep, the two triggers on the Admin Review tables, the HR pay functions, the drift view
-- and the two tables. Admin Review's own rows (visit_reviews, shift_reviews) are untouched.
-- !! hr.pay_rates rows typed in the HR App are LOST by this rollback (the bonus ledger can be rebuilt from the
-- reviews by re-applying the migration). Export them first:
--   select * from hr.pay_rates where employee_id is not null;   -> backups/<date>_hr_pay_rates.json
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT cron.unschedule('hr-bonus-sweep') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hr-bonus-sweep');
DROP TRIGGER IF EXISTS zz_hr_bonus_sync ON public.visit_reviews;
DROP TRIGGER IF EXISTS zz_hr_bonus_sync ON public.shift_reviews;
DROP FUNCTION IF EXISTS hr.set_pay_rates(bigint, jsonb, date, text);
DROP FUNCTION IF EXISTS hr.get_pay_summary();
DROP FUNCTION IF EXISTS hr.get_employee_record(bigint);
DROP FUNCTION IF EXISTS hr.fn_person_label(text);
DROP VIEW IF EXISTS hr.v_bonus_drift;
DROP FUNCTION IF EXISTS hr.fn_sync_all_bonuses(text);
DROP FUNCTION IF EXISTS hr.trg_visit_review_bonus();
DROP FUNCTION IF EXISTS hr.trg_shift_review_bonus();
DROP FUNCTION IF EXISTS hr.fn_sync_visit_bonus(bigint, text, text);
DROP FUNCTION IF EXISTS hr.fn_sync_shift_bonus(bigint, date, text, text);
DROP FUNCTION IF EXISTS hr.fn_visit_bonus_expected(bigint);
DROP FUNCTION IF EXISTS hr.fn_review_decider(text, jsonb);
DROP FUNCTION IF EXISTS hr.fn_rate_on(bigint, text, date);
DROP FUNCTION IF EXISTS hr.fn_payroll_week_start(date);
DROP TABLE IF EXISTS hr.bonus_events;
DROP TABLE IF EXISTS hr.pay_rates;
DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zz_hr_bonus_sync') THEN RAISE EXCEPTION 'ROLLBACK VERIFY: trigger left'; END IF;
  IF to_regclass('hr.bonus_events') IS NOT NULL OR to_regclass('hr.pay_rates') IS NOT NULL THEN RAISE EXCEPTION 'ROLLBACK VERIFY: table left'; END IF;
END $v$;
COMMIT;
