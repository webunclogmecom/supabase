-- ============================================================================
-- Performance indexes: 2026-05-04
-- webhook_events_log is the largest non-telemetry table (~21K rows). Two
-- queries against it run on every audit + daily cleanup:
--   1. "When did the latest webhook event for source X land?" — needs
--      created_at ordering. Now indexed.
--   2. "Which webhook events touched entity X?" — needs entity_type +
--      entity_id lookup. Now indexed (partial — exclude NULL entity_id).
-- Discovered during 2026-05-04 exhaustive index sweep (full_session_audit
-- followup probe).
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_wel_entity
  ON webhook_events_log(entity_type, entity_id)
  WHERE entity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_wel_created_at
  ON webhook_events_log(created_at DESC);
