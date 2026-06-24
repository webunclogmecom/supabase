-- 2026-06-24  Prevent duplicate ACTIVE job rows per Jobber job_number
-- ============================================================================================
-- WHY: public.jobs had NO unique constraint on job_number. A historical GID-format drift (2 old
-- entity_source_links rows stored the RAW numeric Jobber id, e.g. '143219084', instead of the
-- base64 GID 'Z2lk...') caused 2 Jobber jobs to sync twice — job_numbers 10000317 + 10000318, both
-- now ARCHIVED, the raw-GID orphan rows (jobs 517/518) carrying 0 visits / 0 line_items. Current
-- handleJob keys ESL on the base64 GID consistently (only 2 of 1691 job ESLs are raw-numeric), so
-- the root cause is historical, not ongoing. This partial unique index is the safety net against a
-- future duplicate ACTIVE row for one job_number (which would split the one-card-per-job model in
-- ops.client_service_options and the entity_source_links bridge).
--
-- PARTIAL (non-archived) on purpose: (1) 0 current non-archived rows violate it (verified), so it
-- applies cleanly with no dedup; (2) the 2 pre-existing ARCHIVED duplicates are left in place
-- (Rule 6 — no hard-delete of job rows; they are harmless: archived, filtered out of ops views,
-- and never looked up by their raw GID). Jobber job_number is globally unique, so two NON-archived
-- rows sharing one job_number is always a bug worth blocking.
--
-- AUDIT (ADR 010): index only — no table or data change.
-- ============================================================================================

CREATE UNIQUE INDEX IF NOT EXISTS jobs_active_job_number_uniq
  ON public.jobs (job_number)
  WHERE job_number IS NOT NULL AND job_status <> 'archived';
