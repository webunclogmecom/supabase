-- ============================================================================
-- 2026-06-08 — Visit-scoped line items + service_type derived from them
-- ============================================================================
-- Lets public.line_items also hold each Jobber VISIT's line items (visit.lineItems),
-- captured by webhook-jobber's handleVisit. This gives every registered (scheduled) visit
-- its full service detail, and lets visits.service_type be DERIVED from the line items
-- instead of guessed from the title — defaulting to 'GT' when there is no concrete signal
-- (per Fred 2026-06-08). line_items is already polymorphic (job_id / quote_id / invoice_id);
-- visit_id is the 4th container.
--
-- service_type derivation (in handleVisit) maps line-item codes per public.service_line_items
-- (the 01-27 taxonomy): 01/02/09 -> GT, 05/06/07/12/13/14 -> CL, 08 -> WD; every other kind
-- (grey water, lift station, unclogging, camera, dye, assessment, labor, parts, fees) has no
-- GT/CL/WD -> default GT. Falls back: line items -> title inference -> 'GT'. Never NULL.
-- The full 01-27 service_line_items taxonomy is the TARGET for the later Jobber + DB reformat.
--
-- Audit (ADR 010): line_items is a sync-only append table; a column add is auto-captured if
-- the table is audited. Applied via the Management API; this file is the canonical record.
-- ============================================================================

ALTER TABLE public.line_items ADD COLUMN IF NOT EXISTS visit_id bigint REFERENCES public.visits(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_line_items_visit ON public.line_items(visit_id);

-- Widen the "at least one scope" check so a visit-only line item is valid
-- (it previously required job_id / invoice_id / quote_id, which rejected visit rows):
ALTER TABLE public.line_items DROP CONSTRAINT line_items_at_least_one_scope_chk;
ALTER TABLE public.line_items ADD CONSTRAINT line_items_at_least_one_scope_chk
  CHECK (job_id IS NOT NULL OR invoice_id IS NOT NULL OR quote_id IS NOT NULL OR visit_id IS NOT NULL);

-- Verify: SELECT count(*) FILTER (WHERE visit_id IS NOT NULL) AS visit_line_items FROM public.line_items;
