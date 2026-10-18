-- ROLLBACK of 2026-10-18_1410_hr_bonus_amounts_for_admin_review.sql. Drops the two functions. Company bonus rows
-- added through the HR App stay in hr.pay_rates (history; bonuses were priced with them).
-- Republish Admin Review with its constants first, or its bonus amounts read empty.
BEGIN;
DROP FUNCTION IF EXISTS hr.get_bonus_amounts();
DROP FUNCTION IF EXISTS hr.set_company_bonus(text, numeric, date, text);
COMMIT;
