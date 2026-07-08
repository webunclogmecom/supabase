-- 2026-07-08_adopt_schedule_concurrency_confirm_and_7048.sql
-- Yan: "the Calendar day view is not in the same order and the same time as Jobber" (Jul 8).
-- Root cause: the 07-06 20:16 Calendar bulk +1-day shift (Jul 7→8, wall-clock kept via ripple)
-- landed in Jobber, THEN dispatch re-timed the stops inside Jobber (e.g. 033-LG 9:00 AM → 3:15 PM).
-- sync-jobber-visit-drift detects all 13 drifted visits every 30 min but classifies them SURFACE
-- ('jobber_value_unexpected': we edited it AND Jobber holds some other value) — by-design "never
-- auto-resolve", wrong for this case: the office edited only the DATE (which Jobber agrees with);
-- the residual delta is a pure Jobber-side TIME refinement. Fleet sweep (242 linked scheduled
-- visits, ±7/+184d, vs live Jobber): EXACTLY the 13 known visits, zero new cases.
--
-- THE PERMANENT FIX is in the edge fn (same commit): a new classify branch — after HEAL, if the
-- office's last edit was DATE-BEARING and Jobber's ET clock date still equals visit_date and
-- Jobber's start is timed, the drift is a same-date time refinement → ADOPT Jobber's times
-- (details reason 'time_refinement'). Guards per 2-skeptic adversarial review:
--   * t.start_at !== null      — an all-day re-flag in Jobber never wipes an office time (surfaces)
--   * jDate === c.visit_date   — early-AM (<06:00 ET) re-times keep SURFACING; without this the
--                                BEFORE trigger Branch 3 (visit_date = ET CLOCK date of start_at,
--                                Fred 2026-07-02) would silently flip visit_date +1 on adopt
--   * last.old_date !== last.new_date — a pure TIME-ONLY office edit whose push failed while Jobber
--                                holds a third value keeps SURFACING (today's promise kept)
-- Plus HEAL tightened to its full stated premise (DB start_at must still equal the office edit's
-- new_start_at — routine adoption otherwise lets HEAL re-push a mixed office-date+adopted-time).
--
-- THIS MIGRATION ships the two RPC hardenings the skeptics required WITH the classifier change
-- (not as follow-ups), plus one data fix:
--
-- 1) adopt_visit_schedule_from_jobber — OPTIMISTIC CONCURRENCY. The fn adopts from a snapshot
--    that is minutes old by write time; if the office drags the visit between snapshot and write,
--    the unguarded UPDATE would clobber the office's newer edit. New p_expected_visit_date /
--    p_expected_start_at / p_enforce_expected params: when enforced, the UPDATE only matches if
--    the row still holds the snapshot values; a refused adopt counts adoptFail and retries next
--    run with a fresh snapshot. Old 4-arg call shape still resolves (new params defaulted).
--
-- 2) adopt_visit_schedule_from_jobber — SYNC_STATE CONFIRM (kills the delayed echo). The adopt
--    UPDATE flips sync_state='pending' (trg_mark_visit_sync_pending is NOT gated by the suppress
--    GUC) and the suppressed direct push means nothing ever confirms it — so the */3-min
--    resolve-stale-visit-sync-pending cron re-pushed the adopted schedule to Jobber ~3-6 min
--    later via jobber-push-visit's BLIND visitEditSchedule. If dispatch re-timed the visit inside
--    that window, the echo SILENTLY REVERTED dispatch's newer Jobber edit with zero trace
--    (DB==Jobber after the echo → no drift → no surface). Fix: after a matched schedule UPDATE,
--    a second UPDATE sets sync_state='confirmed' (WHERE sync_state='pending'). Verified
--    trigger-safe: sync_state is in neither trg_push_visit_update's WHEN list, nor
--    fn_mark_visit_sync_pending's schedule-column diff, nor trg_aa's UPDATE OF list — no push,
--    no re-pending, no date rewrite; just the audit row.
--
-- 3) GRANT tightening (pre-existing looseness found in review): the 2026-06-26 migration REVOKEd
--    anon/authenticated but never PUBLIC, so PUBLIC EXECUTE leaked through. Now REVOKE PUBLIC too;
--    service_role (the edge fn) is the only caller.
--
-- 4) DATA: soft-delete visit 7048 (169-TCE, Jul 2, untimed) — deleted upstream in Jobber after the
--    Calendar created+pushed it 07-03 ("Visit not found" on per-GID query). It is the reconciler's
--    persistent read_fail=1: its GID never appears in the windowed Jobber list, which also defeats
--    the pagination early-break every run (max snapshot staleness). Canonical deleted_at pattern
--    (same as cron_jobber_reconcile_anomalies' orphan rule, which hasn't caught it). Runs under
--    the suppress GUC because trg_push_visit_update fires on deleted_at — must NOT push a delete
--    for a visit Jobber already deleted.
--
-- Audit (Rule 8): no table/trigger changes — function replace + one audited UPDATE on visits
-- (audit_visits fires; app_source='sql'). Adopt writes remain attributed app_source='jobber' via
-- the edge fn's X-App-Source header (ADR 016).
-- @Supabase (1): your drift-fn lane — Fred routed+authorized (Yan's Calendar report). Additive:
-- old call shape unchanged (defaults), classifier change is in the edge fn commit alongside this.
-- Backup: backups/2026-07-08_drift13_start_at_backup.json (the 13 rows) + 7048 row inline below.
--
-- Backup of visit 7048 pre-soft-delete (for reversal: SET deleted_at=NULL WHERE id=7048):
--   {"id":7048,"client":"169-TCE","visit_date":"2026-07-02","start_at":null,"end_at":null,
--    "visit_status":"scheduled","deleted_at":null,"gid":"gid://Jobber/Visit/2240149285"}

BEGIN;

-- 1+2+3) recreate the adopt RPC with concurrency guard + sync_state confirm
DROP FUNCTION IF EXISTS public.adopt_visit_schedule_from_jobber(bigint, date, timestamptz, timestamptz);

CREATE FUNCTION public.adopt_visit_schedule_from_jobber(
  p_visit_id            bigint,
  p_visit_date          date,
  p_start_at            timestamptz DEFAULT NULL,
  p_end_at              timestamptz DEFAULT NULL,
  p_expected_visit_date date        DEFAULT NULL,
  p_expected_start_at   timestamptz DEFAULT NULL,
  p_enforce_expected    boolean     DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_hit int;
BEGIN
  -- suppress the direct echo push for THIS transaction only
  PERFORM set_config('app.suppress_jobber_push', 'on', true);
  UPDATE public.visits
     SET visit_date = p_visit_date,
         start_at   = p_start_at,
         end_at     = p_end_at
   WHERE id = p_visit_id
     AND source IN ('visit-calendar', 'supabase_cron')   -- only DB-mastered visits
     AND visit_status = 'scheduled'
     AND deleted_at IS NULL
     -- optimistic concurrency: refuse if the row moved since the caller's snapshot
     AND (NOT p_enforce_expected
          OR (visit_date IS NOT DISTINCT FROM p_expected_visit_date
              AND start_at IS NOT DISTINCT FROM p_expected_start_at))
     AND (visit_date IS DISTINCT FROM p_visit_date
          OR start_at IS DISTINCT FROM p_start_at
          OR end_at   IS DISTINCT FROM p_end_at);
  GET DIAGNOSTICS v_hit = ROW_COUNT;
  IF v_hit > 0 THEN
    -- DB now equals Jobber: confirm so the */3-min stale-pending cron never blind-echoes the
    -- adopted schedule back to Jobber (which could revert a dispatch edit made in the window).
    -- sync_state-only UPDATE: trips no push trigger, no re-pending, no date rewrite (verified).
    UPDATE public.visits SET sync_state = 'confirmed'
     WHERE id = p_visit_id AND sync_state = 'pending';
  END IF;
  RETURN v_hit > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.adopt_visit_schedule_from_jobber(bigint, date, timestamptz, timestamptz, date, timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.adopt_visit_schedule_from_jobber(bigint, date, timestamptz, timestamptz, date, timestamptz, boolean) TO service_role;

-- 4) soft-delete the Jobber-deleted phantom (suppress: no delete push for an already-gone visit)
SELECT set_config('app.suppress_jobber_push', 'on', true);
UPDATE public.visits SET deleted_at = now()
 WHERE id = 7048 AND deleted_at IS NULL AND visit_status = 'scheduled';

COMMIT;
