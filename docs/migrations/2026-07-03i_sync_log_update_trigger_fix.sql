-- Migration: 2026-07-03i_sync_log_update_trigger_fix.sql
-- Author: Claude (Supabase session)
BEGIN;
-- sync_log has no updated_at column, so this generic trigger made EVERY UPDATE on sync_log fail
-- with 42703 since creation (unnoticed: all writers were insert-only until the 2026-07-03
-- heartbeat rework of sync-jobber-upcoming-visits). started_at/finished_at already cover the need.
DROP TRIGGER IF EXISTS trg_sync_log_updated_at ON public.sync_log;
-- complete the orphaned heartbeat row from the verification run (the fn's update hit the trigger bug)
UPDATE public.sync_log SET finished_at=now(), duration_seconds=21, rows_inserted=26, rows_errored=0, status='success',
  details='{"pulled":242,"eligible":242,"missing":1,"replayed":26,"replayed_ok":26,"replayed_fail":0,"residual_gap":0,"next_offset":25,"budget_hit":false,"note":"completed manually - in-fn update was blocked by trg_sync_log_updated_at (now dropped)"}'::jsonb
WHERE id=9032;
COMMIT;