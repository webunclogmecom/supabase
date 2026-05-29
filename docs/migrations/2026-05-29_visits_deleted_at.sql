-- 2026-05-29_visits_deleted_at.sql
--
-- Add `deleted_at TIMESTAMPTZ` soft-delete marker to public.visits.
--
-- Context: cron_jobber doesn't currently detect visits that are deleted
-- (or converted to Tasks) in Jobber, so our DB accumulates orphan rows
-- whose Jobber GID returns "Visit not found". Today's audit found 4
-- such orphans (168-AVA id=3917, Tower 41 id=3912, 112-YA id=1624,
-- 148-MOR id=1806).
--
-- Decision (Fred, 2026-05-29 chat): use a `deleted_at` column instead of
-- a new `visit_status='deleted-from-jobber'` value. Cleaner pattern,
-- avoids polluting the status enum.
--
-- Audit (ADR 010): public.visits is opted-in to audit.log_change(); this
-- column will be captured automatically (full-row JSONB) on UPDATE.
-- No trigger changes needed.
--
-- App impact: every query that reads public.visits MUST now filter
-- `deleted_at IS NULL`. Updates required in:
--   - Visit Calendar (Lovable 6533c3ee...)
--   - Field Portal (Lovable)
--   - DERM Tracker (Lovable)
--   - Admin Review
--   - ops.* views (ops_visits_full, ops_visits_with_zone, etc.)
--
-- Idempotent.

BEGIN;

ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

COMMENT ON COLUMN public.visits.deleted_at IS
  'Soft-delete marker. NOT NULL when Jobber reports the linked Visit GID '
  'as not found (deleted or converted in Jobber). Apps MUST filter '
  '`deleted_at IS NULL`. Set by scripts/sync/cron_jobber_reconcile_anomalies.js.';

-- Partial index for the common "active visits" filter path
CREATE INDEX IF NOT EXISTS visits_deleted_at_null_idx
  ON public.visits (visit_date)
  WHERE deleted_at IS NULL;

COMMIT;
