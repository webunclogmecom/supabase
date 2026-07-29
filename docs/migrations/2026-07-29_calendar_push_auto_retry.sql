-- 2026-07-29  Calendar push: auto-retry with a manual escape hatch (BACKEND HALF)
--
-- Spec: docs/superpowers/specs/2026-07-29-calendar-retry-push-design.md (64267f3, amended 7e4b1ce).
-- Approved by Fred 2026-07-29. UI half (drawer + button) is @Building Apps on Lovable 6533c3ee.
--
-- WHY. A visit whose push to Jobber fails shows `Sync issue: not_in_jobber` in the Calendar and
-- nothing retries it. A ~25-minute Jobber outage on 2026-07-28 stranded visits 7409 and 7410 that way.
-- Measured over 30 days: ~19 failures (0.6/day), and of 17 distinct visits that ever failed, 16 later
-- reached 'confirmed' on their own, 0 still failing. So failures are RARE AND TRANSIENT — the problem
-- is latency and visibility, not permanent breakage. Hence auto-retry as the primary mechanism, with
-- the manual button as an escape hatch for when it gives up.
--
-- ============================================================================
-- ⚠ DEVIATION FROM SPEC §4.5, DELIBERATE AND SAFER
-- ============================================================================
-- The spec said "append columns to ops.v_calendar_push_health". This migration does NOT touch that
-- view. It has FOUR UNION ALL branches (push_failed / not_in_jobber / skip_removal_failed /
-- drift_surfaced, the last one reading a JSONB array out of sync_log), and appending three columns
-- means editing all four in lockstep. `public.log_calendar_push_health()` aggregates every row of it
-- into sync_log, so a mistake there silently corrupts the ops log rather than erroring.
-- Wrapping is strictly better: the base view stays the untouched diagnostic feed, and the retry state
-- lives only on the UI-facing view that actually needs it. Same outcome, no blast radius.
--
-- ============================================================================
-- 1. DUPLICATE GUARD
-- ============================================================================
-- Retrying a push for an unlinked visit CREATES a Jobber visit. If the same work already reached
-- Jobber under a different row, the retry puts a phantom stop on a real crew's schedule. That is the
-- 7409/7417 shape: same client (283-PIK), same date, same job, 2 hours apart — 7409 was a mis-picked
-- service code (Fred soft-deleted it 2026-07-29).
--
-- ⚠ ADVISORY, NEVER ABSOLUTE. Measured live: 45 client/day pairs already carry more than one visit,
-- and some are genuinely two distinct services in one day. So the machine refuses (it cannot judge)
-- and the human may override (they can). Do NOT promote this to a hard block.
-- ⚠ It cannot see a Jobber sibling that is missing from entity_source_links, so it REDUCES the risk of
-- a duplicate; it does not eliminate it. UI copy must say "likely duplicate", never "duplicate".

CREATE OR REPLACE FUNCTION public.fn_visit_push_duplicate_of(p_visit_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT sib.id
  FROM public.visits me
  JOIN public.visits sib
    ON sib.id         <> me.id
   AND sib.client_id   = me.client_id
   AND sib.visit_date  = me.visit_date
   AND sib.job_id IS NOT DISTINCT FROM me.job_id
   AND sib.deleted_at IS NULL
  WHERE me.id = p_visit_id
    AND me.deleted_at IS NULL
    -- only a risk when WE are unlinked...
    AND NOT EXISTS (SELECT 1 FROM public.entity_source_links e
                     WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id = me.id)
    -- ...and the sibling IS in Jobber
    AND EXISTS (SELECT 1 FROM public.entity_source_links e2
                 WHERE e2.entity_type='visit' AND e2.source_system='jobber' AND e2.entity_id = sib.id)
  ORDER BY sib.created_at DESC   -- most recent linked sibling = most likely the intended replacement
  LIMIT 1;
$function$;

-- ⚠ Supabase default privileges auto-grant new functions to anon/authenticated/service_role, and
-- REVOKE ... FROM PUBLIC alone does NOT undo that (memory: reference_supabase_function_default_privileges).
-- ⚠ This is SECURITY INVOKER and is called from a view. Function EXECUTE is NOT laundered through an
-- owner-rights view (bitten three times: 2026-07-28h, 2026-07-28t). Every role that may read the view
-- must hold EXECUTE or it gets 42501 on a view it is explicitly allowed to read. yannick_readonly
-- holds SELECT on ops.*, so it is included deliberately.
REVOKE ALL     ON FUNCTION public.fn_visit_push_duplicate_of(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_visit_push_duplicate_of(bigint) TO service_role, authenticated, yannick_readonly;

-- ============================================================================
-- 2. RETRY STATE
-- ============================================================================
-- Stored on visit_sync_flags (PK visit_id) because that table already holds WHY a push failed; retry
-- bookkeeping is the same concern. RULE 8 (ADR 010): audit OPT-OUT, unchanged — this is sync-control
-- machinery, not human-editable business data, and it carries no audit trigger today (only
-- trg_visit_sync_flags_updated_at). The visits rows a retry ultimately writes stay fully audited.

ALTER TABLE public.visit_sync_flags
  ADD COLUMN IF NOT EXISTS attempts         integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS next_attempt_at  timestamptz,
  ADD COLUMN IF NOT EXISTS auto_retry_state text;

COMMENT ON COLUMN public.visit_sync_flags.auto_retry_state IS
  'pending | exhausted | blocked_duplicate | needs_data_fix. NULL = never picked up by the driver.';

-- ============================================================================
-- 3. UI-FACING VIEW — one row per visit
-- ============================================================================
-- ⚠ WHY THIS EXISTS: @Building Apps found during spec review that the Calendar drawer collapses health
-- rows into a Map keyed on visit_id, which assumes one row per visit. The base view does NOT guarantee
-- that — its branch predicates overlap. Reproduced live: visit 7409 returned TWO rows at once
-- (not_in_jobber + push_failed).
-- ⚠ And c865608 made that the NORM: now that every unanticipated failure records a reason, any failed
-- push on an unlinked Calendar visit produces both rows — and push_failed is the ONLY branch carrying
-- reason/detail, so a Map could keep the bare row and drop the only one explaining the failure.
-- Priority below therefore puts push_failed first. all_issues preserves the full set.

CREATE OR REPLACE VIEW ops.v_calendar_push_health_by_visit AS
SELECT DISTINCT ON (h.visit_id)
       h.visit_id, h.client_code, h.client_name, h.visit_date, h.source,
       h.issue, h.reason, h.detail, h.since,
       public.fn_visit_push_duplicate_of(h.visit_id) AS duplicate_of_visit_id,
       COALESCE(f.attempts, 0)                       AS attempts,
       f.auto_retry_state,
       f.next_attempt_at,
       (SELECT array_agg(DISTINCT h2.issue)
          FROM ops.v_calendar_push_health h2
         WHERE h2.visit_id = h.visit_id)             AS all_issues
  FROM ops.v_calendar_push_health h
  LEFT JOIN public.visit_sync_flags f
    ON f.visit_id = h.visit_id AND f.resolved_at IS NULL
 ORDER BY h.visit_id,
          CASE h.issue WHEN 'push_failed'         THEN 1   -- carries reason/detail: most informative
                       WHEN 'skip_removal_failed' THEN 2
                       WHEN 'not_in_jobber'       THEN 3
                       WHEN 'drift_surfaced'      THEN 4
                       ELSE 5 END;

-- New views in an exposed schema come out anon-readable under Supabase default privileges. Revoke
-- explicitly; mirror the base view's grants otherwise.
REVOKE ALL    ON ops.v_calendar_push_health_by_visit FROM PUBLIC, anon;
GRANT  SELECT ON ops.v_calendar_push_health_by_visit TO authenticated, service_role, yannick_readonly;

-- ============================================================================
-- 4. MANUAL RETRY RPC (the escape hatch)
-- ============================================================================
-- SECURITY DEFINER because it writes visit_sync_flags and calls fn_request_jobber_push, which is
-- definer-only. The pinned search_path is therefore mandatory, not decorative.
-- ⚠ authenticated + service_role ONLY. anon must never reach this: it triggers a WRITE to Jobber, and
-- the 2026-07-12 harden made anon read-only on all business data. Do not widen.

CREATE OR REPLACE FUNCTION public.retry_visit_push(p_visit_id bigint, p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dup      bigint;
  v_dup_svc  text;
  v_exists   boolean;
BEGIN
  SELECT true INTO v_exists FROM public.visits
   WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_exists IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_dup := public.fn_visit_push_duplicate_of(p_visit_id);

  IF v_dup IS NOT NULL AND NOT p_force THEN
    SELECT string_agg(li.name, ', ') INTO v_dup_svc
      FROM public.line_items li WHERE li.visit_id = v_dup;
    RETURN jsonb_build_object(
      'ok', false, 'blocked', 'duplicate',
      'duplicate_of', v_dup,
      'duplicate_of_service', COALESCE(v_dup_svc, '(no line items)')
    );
  END IF;

  -- A human retry restores the automatic ladder rather than fighting it.
  UPDATE public.visit_sync_flags
     SET attempts = 0, next_attempt_at = NULL, auto_retry_state = 'pending'
   WHERE visit_id = p_visit_id AND resolved_at IS NULL;

  PERFORM public.fn_request_jobber_push(p_visit_id, 'upsert');

  RETURN jsonb_build_object('ok', true, 'forced', COALESCE(v_dup IS NOT NULL, false));
END;
$function$;

REVOKE ALL     ON FUNCTION public.retry_visit_push(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.retry_visit_push(bigint, boolean) TO authenticated, service_role;

-- ============================================================================
-- 5. AUTO-RETRY DRIVER
-- ============================================================================
-- ⚠ Drives off ops.v_calendar_push_health, NOT off visit_sync_flags alone. Today's stranded visits
-- (7409/7410) had sync_state='failed' with NO flag row at all, because the reason-recording fix
-- (c865608) shipped after them. Driving off flags only would have missed the exact incident that
-- motivated this work. A tracking row is created when one is absent.
--
-- ⚠ Only TRANSIENT reasons are retried. unmapped_employee / no_job_match / complete_push_rejected are
-- data problems: retrying them just burns Jobber calls and produces an identical failure. Those are
-- marked needs_data_fix so the UI can say "automatic retry will not help" instead of pretending.
--
-- ⚠ Calls fn_request_jobber_push IN SQL — deliberately NOT net.http_post with an inline key.
-- jobber-poll-sync / jobber-upcoming-visits-sync / jobber-visit-drift-reconcile all embed an
-- x-sync-key literal in cron.job.command, where it is unmasked in every query output, log and
-- transcript. Do not copy that pattern (rotation flagged to Fred 2026-07-29, three jobs must move
-- together or inbound sync degrades silently).

CREATE OR REPLACE FUNCTION public.fn_calendar_push_auto_retry()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r          record;
  v_pushed   integer := 0;
  v_delay    interval;
  RETRYABLE  text[] := ARRAY['push_pending','push_exception','link_write_failed','dup_create_cleanup_failed'];
BEGIN
  FOR r IN
    SELECT h.visit_id, h.issue
      FROM ops.v_calendar_push_health h
     WHERE h.issue IN ('not_in_jobber','push_failed')
     GROUP BY h.visit_id, h.issue
  LOOP
    -- Ensure a tracking row. ON CONFLICT DO NOTHING preserves a REAL recorded reason if one exists.
    INSERT INTO public.visit_sync_flags (visit_id, reason, detail)
    VALUES (r.visit_id, 'push_pending', 'auto-retry tracking; no push error was recorded')
    ON CONFLICT (visit_id) DO NOTHING;

    -- Re-read the authoritative row for this visit.
    DECLARE
      f public.visit_sync_flags%ROWTYPE;
      v_dup bigint;
    BEGIN
      SELECT * INTO f FROM public.visit_sync_flags
       WHERE visit_id = r.visit_id AND resolved_at IS NULL;
      CONTINUE WHEN NOT FOUND;

      IF NOT (f.reason = ANY (RETRYABLE)) THEN
        UPDATE public.visit_sync_flags
           SET auto_retry_state = 'needs_data_fix', next_attempt_at = NULL
         WHERE visit_id = r.visit_id AND auto_retry_state IS DISTINCT FROM 'needs_data_fix';
        CONTINUE;
      END IF;

      IF f.attempts >= 4 THEN
        UPDATE public.visit_sync_flags
           SET auto_retry_state = 'exhausted', next_attempt_at = NULL
         WHERE visit_id = r.visit_id AND auto_retry_state IS DISTINCT FROM 'exhausted';
        CONTINUE;
      END IF;

      CONTINUE WHEN f.next_attempt_at IS NOT NULL AND f.next_attempt_at > now();

      -- The machine never pushes a probable duplicate, and does NOT burn an attempt deciding so.
      v_dup := public.fn_visit_push_duplicate_of(r.visit_id);
      IF v_dup IS NOT NULL THEN
        UPDATE public.visit_sync_flags
           SET auto_retry_state = 'blocked_duplicate', next_attempt_at = NULL
         WHERE visit_id = r.visit_id AND auto_retry_state IS DISTINCT FROM 'blocked_duplicate';
        CONTINUE;
      END IF;

      -- Backoff ladder. Approximate by design: a */5 cron cannot honour the 1-minute rung exactly,
      -- so each rung is "at least this long". Do NOT add a faster cron to sharpen it.
      v_delay := (ARRAY['1 minute','5 minutes','15 minutes','60 minutes'])[f.attempts + 1]::interval;

      UPDATE public.visit_sync_flags
         SET attempts         = f.attempts + 1,
             next_attempt_at  = now() + v_delay,
             auto_retry_state = 'pending'
       WHERE visit_id = r.visit_id;

      PERFORM public.fn_request_jobber_push(r.visit_id, 'upsert');
      v_pushed := v_pushed + 1;
    END;
  END LOOP;

  RETURN v_pushed;
END;
$function$;

REVOKE ALL     ON FUNCTION public.fn_calendar_push_auto_retry() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_calendar_push_auto_retry() TO service_role;

-- Success needs no handling here: jobber-push-visit calls clearFlag() when a visit settles
-- (c865608), which resolves the flag and drops it off the board.
SELECT cron.schedule('calendar-push-auto-retry', '*/5 * * * *',
                     $$SELECT public.fn_calendar_push_auto_retry();$$);
