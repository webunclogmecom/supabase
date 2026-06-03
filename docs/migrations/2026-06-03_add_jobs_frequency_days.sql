-- Migration: add public.jobs.frequency_days
-- Date:   2026-06-03
-- Author: Claude, directed by Fred — Service Agreement visit-generation (Calendar app = source of truth)
-- Spec:   Supabase/docs/service-agreement-visit-generation.md (§9)
--
-- Audit (ADR 010): public.jobs is a Jobber sync-only table -> OPT-OUT of audit.logs triggers
--   (no trigger added). frequency_days is synced from the Jobber job's "Frequency" numeric
--   custom field by scripts/sync/fetch_service_agreement_jobs.js -- not human-edited in our DB.
--
-- 3NF: frequency_days is a genuine attribute of the agreement job (its interval in days),
--   not derivable from existing columns -> stored. service_kind (service agreement vs service
--   call) IS derivable from the job title -> computed in a view, NOT stored here.

ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS frequency_days INTEGER;

COMMENT ON COLUMN public.jobs.frequency_days IS
  'Recurring service interval in days, synced from the Jobber job''s "Frequency" numeric custom field. NULL or 0 = not a generating service agreement. Drives Calendar-app visit generation; the Calendar app is the source of truth for visits (Jobber decoupled).';
