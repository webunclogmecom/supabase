-- 2026-05-26_visits_source_add_visit_calendar.sql
--
-- Extend visits_source_chk to accept source='visit-calendar' for visits
-- created via the Visit Calendar Lovable app. Companion to the anon INSERT
-- policy (2026-05-26_calendar_visit_anon_insert_rls.sql) which enforces
-- WITH CHECK (source = 'visit-calendar').
--
-- Existing allowed values: jobber, supabase_cron, airtable, manual, odoo.
-- Adding: visit-calendar.
--
-- Rationale (CLAUDE.md trust hierarchy): we knowingly create canonical
-- visits without a Jobber GID via the Calendar drawer. Tagging them with
-- a distinct source value (vs the generic 'manual') makes them easy to
-- audit, back-sync to Jobber later, and exclude from purity-of-source
-- migrations.
--
-- Idempotent (Rule 5): DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT.
-- 3NF (Rule 2): no schema change beyond extending an allowed-values list.
-- Audit (Rule 8): visits already has audit_visits trigger.

BEGIN;

ALTER TABLE public.visits
  DROP CONSTRAINT IF EXISTS visits_source_chk;

ALTER TABLE public.visits
  ADD CONSTRAINT visits_source_chk
  CHECK (source = ANY (ARRAY[
    'jobber'::text,
    'supabase_cron'::text,
    'airtable'::text,
    'manual'::text,
    'odoo'::text,
    'visit-calendar'::text
  ]));

COMMIT;

-- ============================================================
-- VERIFY
-- ============================================================
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='visits_source_chk';
-- (expect ARRAY to include 'visit-calendar')
