-- ============================================================================
-- 2026-06-01_visit_sync_flags.sql
-- Calendar -> Jobber write-back (Phase 2): records calendar-origin visits that
-- could NOT be pushed to Jobber (no matching job, or a create error), so they
-- surface as a review list instead of failing silently. One row per visit.
--
-- Audit (Rule 8 / ADR 010): OPT-OUT. Operational sync-state table, machine-written
--   by the jobber-push-visit Edge Function; no human-editable business data and no
--   customer/billing/DERM/webhook-secret data, so it is exempt from audit triggers.
-- 3NF (Rule 2): PK = visit_id. reason/detail/created_at/updated_at/resolved_at each
--   depend on the whole key and nothing else. OK.
-- FK: real REFERENCES to public.visits is fine on Prod (no TRUNCATE refresh).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.visit_sync_flags (
  visit_id    BIGINT PRIMARY KEY REFERENCES public.visits(id) ON DELETE CASCADE,
  reason      TEXT NOT NULL,         -- no_job_match | create_error | ...
  detail      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

-- fast lookup of the open review list
CREATE INDEX IF NOT EXISTS visit_sync_flags_unresolved_idx
  ON public.visit_sync_flags (created_at) WHERE resolved_at IS NULL;

-- updated_at is trigger-managed (Rule 7 — never set manually)
DROP TRIGGER IF EXISTS trg_visit_sync_flags_updated_at ON public.visit_sync_flags;
CREATE TRIGGER trg_visit_sync_flags_updated_at
  BEFORE UPDATE ON public.visit_sync_flags
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
