-- ============================================================================
-- Drop dormant tables — 2026-04-30
-- ============================================================================
-- Per ADR 011 (source-of-truth canonicalization 2026-04-29), these 5 tables
-- are no longer populated and have no consumers (verified via pg_views search
-- on 2026-04-30: no public.* or ops.* view references any of them).
--
-- - routes, route_stops:  routing moves to Viktor's skill in Slack
-- - receivables:          past-due reads from Jobber `invoices` directly
-- - leads:                lead capture moves to Odoo (May 2026 cutover)
-- - expenses:             expenses live in Ramp; Fillout source dropped
--
-- These were originally going to be dropped at Odoo cutover but Fred decided
-- (2026-04-30) to drop them now as part of the clean-redo to remove confusion
-- for future agents reading the schema.
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS route_stops CASCADE;
DROP TABLE IF EXISTS routes      CASCADE;
DROP TABLE IF EXISTS receivables CASCADE;
DROP TABLE IF EXISTS leads       CASCADE;
DROP TABLE IF EXISTS expenses    CASCADE;

COMMIT;
