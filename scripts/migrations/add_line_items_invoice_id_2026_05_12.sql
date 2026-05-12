-- ============================================================================
-- Migration: Add line_items.invoice_id — 2026-05-12
-- TARGET: Prod (wbasvhvvismukaqdnouk). Same migration applied to Sandbox after.
-- ============================================================================
-- Background:
--   The `line_items` table currently scopes rows to `job_id` (and optionally
--   `quote_id`). But Jobber's data model has THREE distinct scopes:
--     - Job line items   = planned/template items on the job
--     - Invoice line items = what was actually billed
--     - Quote line items = what was quoted
--
--   In 77% of recent 2026 visits, the JOB line items and the INVOICE line
--   items diverge — billing can be edited independently of the job plan.
--   Today our `line_items` table only stores the job side, leaving Lovable's
--   Admin Review App (and any other invoice-detail consumer) blind to what
--   was actually charged.
--
--   The 2026-05-12 sweep on 042-MT visit 1713 surfaced this end-to-end:
--   the JOB shows "Hydrojet Unclogging Residential" qty=1, but the INVOICE
--   that was actually charged ("Hydrojet Unclogging Commercial" qty=1 $399)
--   never lands in our DB.
--
-- This migration:
--   1. Adds `invoice_id BIGINT` to line_items, nullable, FK to invoices.id.
--   2. Adds an index for fast `WHERE invoice_id = X` lookups.
--   3. Documents the scope semantics in the column comments.
--
-- Coexistence rule:
--   - Existing rows: keep job_id set, invoice_id stays NULL. Don't touch.
--   - New invoice-scoped rows from the upcoming backfill + webhook fix: have
--     invoice_id set, job_id NULL.
--   - A single line_items row represents ONE scope at a time. To compare
--     job-plan vs invoice-billing for the same job, query both sides
--     separately and JOIN at read time.
--
-- Reversal: DROP COLUMN line_items.invoice_id;
-- ============================================================================

BEGIN;

-- Drop the legacy `line_item_parent` constraint which requires
-- (job_id IS NOT NULL OR quote_id IS NOT NULL) and would block any new
-- invoice-only rows (invoice_id set, job_id+quote_id NULL).
-- We replace it with `line_items_at_least_one_scope_chk` below.
ALTER TABLE public.line_items DROP CONSTRAINT IF EXISTS line_item_parent;

ALTER TABLE public.line_items
  ADD COLUMN IF NOT EXISTS invoice_id BIGINT;

ALTER TABLE public.line_items
  ADD CONSTRAINT line_items_invoice_id_fkey
  FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL;

CREATE INDEX idx_line_items_invoice_id ON public.line_items(invoice_id) WHERE invoice_id IS NOT NULL;

-- Sanity: at least one scope must be set on any new row. Existing rows are
-- exempt because they were inserted before this constraint and all have
-- non-NULL job_id; we don't want to retroactively break them.
ALTER TABLE public.line_items
  ADD CONSTRAINT line_items_at_least_one_scope_chk
  CHECK (job_id IS NOT NULL OR invoice_id IS NOT NULL OR quote_id IS NOT NULL);

COMMENT ON COLUMN public.line_items.invoice_id IS
  'Set when this row represents an INVOICE line item (what was actually billed to the customer). Jobber distinguishes invoice line items from job line items — billing can be edited independently of the job plan, so the two often diverge. For a single invoice, query SELECT * FROM line_items WHERE invoice_id = X.';

COMMENT ON COLUMN public.line_items.job_id IS
  'Set when this row represents a JOB line item (planning/template on the job). For the same physical service, the job line items and the invoice line items can diverge — billing can be edited independently after the job is created.';

COMMENT ON COLUMN public.line_items.quote_id IS
  'Set when this row represents a QUOTE line item (a proposed bill that may or may not become an invoice).';

COMMENT ON TABLE public.line_items IS
  'Line items from Jobber across three scopes: job (planning), invoice (billed), quote (proposed). Exactly one of (job_id, invoice_id, quote_id) is set per row. To compare planned-vs-billed for the same work, query both sides separately and join at read time.';

COMMIT;
