-- ============================================================================
-- Migration: normalize clients.status 'Recuring' → 'RECURRING'
-- ============================================================================
-- Context:
--   132 clients had status='Recuring' (typo from Airtable import — missing
--   second 'r'). The documented status vocabulary is ACTIVE / RECURRING /
--   PAUSED / INACTIVE. Several views (ops.v_service_due, originally) had
--   to ARRAY['ACTIVE','Recuring'] to work around this.
--
-- Fix: one-shot UPDATE to normalize. Safe — 'Recuring' is a typo, not a
-- distinct business state.
--
-- Run date: 2026-04-20 (already applied via inline SQL during the 3NF
-- migration session). File committed as historical record.
-- ============================================================================

BEGIN;

UPDATE clients SET status = 'RECURRING' WHERE status = 'Recuring';

COMMIT;
