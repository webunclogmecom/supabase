-- 2026-05-25h_customer_views_regrant_anon.sql
--
-- HOT-FIX for 2026-05-25f: the DROP VIEW … CASCADE + CREATE VIEW pattern
-- silently dropped the SELECT grants on the recreated views, so anon
-- requests started getting 401 immediately. Re-grant SELECT on all 5
-- affected views.
--
-- This file should be kept until the schema-default grants are reconfigured
-- so future view recreations don't need a manual re-grant step.

BEGIN;

GRANT SELECT ON customer.work_orders      TO anon, authenticated;
GRANT SELECT ON customer.wo_photos        TO anon, authenticated;
GRANT SELECT ON customer.inspection_items TO anon, authenticated;
GRANT SELECT ON customer.recommendations  TO anon, authenticated;
GRANT SELECT ON customer.scheduled_visits TO anon, authenticated;

COMMIT;
