-- 2026-07-07_derm_service_before_dump_check.sql
-- Fred approved (follow-up from the end-of-day fleet hunt): a manifest's grease
-- is dumped AFTER (or same day as) the service, never before — #827989's 14
-- reconstruction rows carried the data-entry date as service_date (after the
-- dump) and nothing caught it. CHECK enforces service_date <= dump_ticket_date
-- at entry, for every writer (DERM Tracker, RPCs, scripts).
-- NULLs pass (either date unknown -> constraint is not violated), matching the
-- fill-later workflow; the inherit trigger fills dump dates from siblings.
-- Verified 0 violators fleet-wide INCLUDING soft-deleted rows before adding
-- (plain validated constraint, no NOT VALID needed).
-- Audit (Rule 8): constraint only — no column/trigger change; audit_derm_manifests
-- unaffected.

ALTER TABLE public.derm_manifests
  ADD CONSTRAINT derm_manifests_service_before_dump_chk
  CHECK (service_date <= dump_ticket_date);
