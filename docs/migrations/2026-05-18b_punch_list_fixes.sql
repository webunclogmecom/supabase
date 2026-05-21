-- 2026-05-18b_punch_list_fixes.sql
--
-- Punch-list fixes from the 2026-05-18 prod audit. Three additive changes,
-- no destructive ops:
--   1. updated_at triggers on client_contacts, sync_cursors, webhook_tokens
--      (audit found these had the column but no trigger — Rule 7 partial miss)
--   2. webhook_events_log retention via pg_cron (90-day TTL)
--      (audit found the table at 82MB with no retention policy)
--   3. Documentation comments on client_groups + visit_recommendations
--      explaining the RLS-no-policies posture is intentional (empty tables,
--      locked down until used)
--
-- Audit opt-in per Rule 8:
--   * client_contacts is NOT in the audited set. No change here — column
--     adds without trigger don't auto-audit (per ADR 010). If we later want
--     to audit client_contacts, that's a separate migration.
--   * sync_cursors and webhook_tokens are operational tables; sync_cursors
--     is explicitly excluded in ADR 010 (sync metadata), webhook_tokens IS
--     audited (audit_webhook_tokens). Adding the updated_at trigger to
--     webhook_tokens just makes the existing audited row.updated_at correct.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. updated_at triggers — use canonical set_updated_at() function
-- ---------------------------------------------------------------------------
CREATE TRIGGER trg_client_contacts_updated_at
  BEFORE UPDATE ON public.client_contacts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_sync_cursors_updated_at
  BEFORE UPDATE ON public.sync_cursors
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_webhook_tokens_updated_at
  BEFORE UPDATE ON public.webhook_tokens
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. webhook_events_log retention — 90 days via pg_cron daily DELETE
--
-- Why a simple DELETE and not pg_partman like audit.logs:
--   * Existing table has 26,545 rows + indexes + triggers; converting to
--     partitioned would require heavy migration (new table, copy, swap,
--     rename) for marginal benefit.
--   * At ~3 MB/day, 90 days = ~270 MB max — well within Pro plan limits.
--   * Daily DELETE volume (~3 MB / 1,000 rows) is trivial for Postgres.
--   * autovacuum reclaims free pages back to Postgres (not to OS, but that's
--     fine — pages get reused immediately by new writes).
--
-- If volume ever 10×s (~30 MB/day → 30k rows/day), revisit and partition then.
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
  'webhook-events-log-retention',
  '0 3 * * *',  -- daily at 03:00 UTC (off-peak; matches Jobber sync down-cycle)
  $$DELETE FROM public.webhook_events_log WHERE created_at < now() - INTERVAL '90 days'$$
);

-- ---------------------------------------------------------------------------
-- 3. Document RLS-no-policies posture on the 2 empty tables
-- pg_comment so future audits / Fred / Claude sessions see the intent
-- ---------------------------------------------------------------------------
COMMENT ON TABLE public.client_groups IS
  'Currently unused (0 rows as of 2026-05-18). RLS enabled with zero policies = full lockdown to non-service_role; intentional until a UI surfaces this.';

COMMENT ON TABLE public.visit_recommendations IS
  'Currently unused (0 rows as of 2026-05-18). RLS enabled with zero policies = full lockdown to non-service_role; intentional until a UI surfaces this.';

COMMIT;
