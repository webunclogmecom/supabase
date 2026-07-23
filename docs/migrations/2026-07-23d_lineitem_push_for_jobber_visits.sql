-- ============================================================================
-- 2026-07-23d — push office LINE-ITEM edits to Jobber for Jobber-mastered visits
-- ============================================================================
-- WHY: The Calendar drawer lets the office edit a visit's line items (services +
-- per-line description). For Calendar/SA-generated visits (source IN
-- ('visit-calendar','supabase_cron')) that edit already reaches Jobber. But for a
-- visit BORN IN JOBBER (source='jobber', e.g. a Service Call Diego creates in
-- Jobber) the whole Calendar->Jobber push is gated OFF by source, so an office
-- line-item / description edit was written to our DB and never pushed. Confirmed on
-- visit 7100 (job 99901019, "22 - Service Call - Labor"): our DB held description
-- 'Taking pictures', Jobber held ''. (The description field itself was already fully
-- wired into edit_calendar_visit + syncVisitLineItems; the ONLY gap was the source
-- gate — see the 2026-06-27 "jobber_push_on_purpose" design.)
--
-- Fred 2026-07-23: enable line-item edits to reach Jobber for source='jobber' visits,
-- WITHOUT re-opening schedule/crew/title/completion (Jobber must stay master of those
-- for born-in-Jobber visits — that is the driver/schedule-clobber class the 2026-06-27
-- work fixed). So we push the 'lineitems' group ONLY.
--
-- This migration is HALF the fix: it makes trg_push_visit_update FIRE on a line-items
-- change for a Jobber-mastered visit. The edge fn jobber-push-visit is the other half:
-- it now honors ONLY the 'lineitems' group for a non-calendar/cron visit and never
-- CREATEs a Jobber visit for one (deployed same cycle).
--
-- SAFETY (verified before enabling): the reverse-sync cannot loop. Inbound
-- handleVisit rewrites public.line_items for a source='jobber' visit but does NOT bump
-- visits.line_items_rev (only edit_calendar_visit does), so the push trigger cannot
-- re-fire from an inbound rewrite. And once pushed, Jobber == our DB, so future inbound
-- rewrites PRESERVE the description (today it is actually at risk of being wiped by
-- inbound sync because it never reached Jobber). fn_push_visit_to_jobber already builds
-- changed=['lineitems'] on a line_items_rev change and does not gate an UPSERT on source,
-- so no function change is needed; only the trigger WHEN clause is widened.
--
-- fn_mark_visit_sync_pending is intentionally left unchanged: after this fix the push
-- fires and converges, and any failure is surfaced via visit_sync_flags, so leaving
-- sync_state='confirmed' for these visits is not a false green. (Flipping it to 'pending'
-- risks a stuck-pending state, since nothing clears pending for source='jobber' rows.)
--
-- AUDIT (ADR 010): no schema change, no new table — this only recreates an existing
-- AFTER trigger's WHEN clause on the already-audited public.visits. No audit action.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;

CREATE TRIGGER trg_push_visit_update
AFTER UPDATE ON public.visits
FOR EACH ROW
WHEN (
  (
    (new.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text]))
    AND (
      old.visit_date IS DISTINCT FROM new.visit_date
      OR old.start_at IS DISTINCT FROM new.start_at
      OR old.end_at IS DISTINCT FROM new.end_at
      OR old.title IS DISTINCT FROM new.title
      OR old.notes IS DISTINCT FROM new.notes
      OR old.job_id IS DISTINCT FROM new.job_id
      OR old.service_line_item_id IS DISTINCT FROM new.service_line_item_id
      OR old.line_items_rev IS DISTINCT FROM new.line_items_rev
      OR old.team_rev IS DISTINCT FROM new.team_rev
      OR old.deleted_at IS DISTINCT FROM new.deleted_at
      OR old.visit_status IS DISTINCT FROM new.visit_status
    )
  )
  OR ((old.deleted_at IS DISTINCT FROM new.deleted_at) AND (new.deleted_at IS NOT NULL))
  OR ((old.visit_status IS DISTINCT FROM new.visit_status) AND (new.visit_status = 'cancelled'::text))
  -- NEW 2026-07-23d: office LINE-ITEM edits on a Jobber-MASTERED visit (source='jobber')
  -- must reach Jobber. Fire on a line-items change for a non-calendar/cron, non-deleted
  -- visit. The edge fn honors ONLY the 'lineitems' group for these; schedule/crew/title/
  -- completion stay Jobber-mastered.
  OR (
    new.source <> 'visit-calendar'
    AND new.source <> 'supabase_cron'
    AND new.deleted_at IS NULL
    AND (
      old.line_items_rev IS DISTINCT FROM new.line_items_rev
      OR old.service_line_item_id IS DISTINCT FROM new.service_line_item_id
    )
  )
)
EXECUTE FUNCTION fn_push_visit_to_jobber();
