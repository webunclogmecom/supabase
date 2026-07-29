-- 2026-07-29c  retry_visit_push must refuse anything that is not a retryable push failure
--
-- ⚠ LIVE SAFETY DEFECT, found by @Building Apps while verifying the retry UI against real board rows.
-- Four REAL client visits were one click away from having a human's Jobber edit silently overwritten.
--
-- WHAT WAS WRONG. `retry_visit_push` checked existence, checked duplicate, then pushed. It never asked
-- WHY the visit was on the health board. The board's `drift_surfaced` branch means "the DB schedule
-- disagrees with a human Jobber edit — decide adopt-from-Jobber vs re-push". Re-pushing is the WRONG
-- half of that decision, and the RPC did exactly that, unconditionally. The confirm dialog only fires
-- on `blocked:'duplicate'`, so nothing stood in the way. Verified live: all four board rows at the time
-- (6366/167-FEN, 6708/083-SHUL, 6765/189-FRE, 7065/083-SHUL) were `drift_surfaced`, and the function
-- contained no reference to `issue`, `drift` or the health view at all.
--
-- ⚠ SECOND BUG, same read: the op was hardcoded `'upsert'`. A `skipped` visit whose Jobber removal
-- failed (`skip_removal_failed`) needs `'delete'`. Pushing `'upsert'` would have RE-CREATED a visit the
-- office had deliberately skipped. `resolve-stale-visit-sync-pending` already computes this correctly
-- (`CASE WHEN visit_status='skipped' THEN 'delete' ELSE 'upsert' END`); the RPC did not.
--
-- ⚠ THE PRINCIPLE, which is why this is fixed here and not only in the UI. @Building Apps is hiding the
-- button for non-retryable issues, and that is right — but **a UI guard is not a safety property**. The
-- RPC is `authenticated`-EXECUTABLE, so any staff session can call it with any visit id via PostgREST,
-- board or no board. The refusal has to live where the write happens.
--
-- WHAT IT NOW REFUSES (all before any push, all with a machine-readable `blocked` code):
--   * visit missing / soft-deleted            -> error 'not_found'
--   * visit is not on the health board at all -> blocked 'not_failing'   (nothing to retry)
--   * issue = 'drift_surfaced'                -> blocked 'drift'         (needs a two-way decision)
--   * auto_retry_state = 'needs_data_fix'     -> blocked 'needs_data_fix' (retry fails identically)
--   * probable duplicate, no force            -> blocked 'duplicate'      (unchanged)
-- `p_force` deliberately overrides ONLY the duplicate case. It does NOT unlock drift: forcing past a
-- duplicate is a judgement a human can make from the dialog, whereas adopt-vs-repush is a different
-- decision that needs its own UI and is not in scope here.
--
-- RULE 8 (ADR 010): no table or column change.

CREATE OR REPLACE FUNCTION public.retry_visit_push(p_visit_id bigint, p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_status  text;
  v_issue   text;
  v_state   text;
  v_op      text;
  v_dup     bigint;
  v_dup_svc text;
BEGIN
  SELECT visit_status INTO v_status
    FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- WHY is it on the board? This is the guard that was missing.
  SELECT issue, auto_retry_state INTO v_issue, v_state
    FROM ops.v_calendar_push_health_by_visit WHERE visit_id = p_visit_id;

  IF v_issue IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'not_failing',
      'message', 'This visit is not reporting a sync problem, so there is nothing to retry.');
  END IF;

  IF v_issue = 'drift_surfaced' THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'drift', 'issue', v_issue,
      'message', 'This visit was edited in Jobber by a person and our copy disagrees. '
              || 'Retrying would overwrite their change. Someone must decide whether to keep '
              || 'Jobber''s version or re-send ours.');
  END IF;

  IF v_issue NOT IN ('not_in_jobber', 'push_failed', 'skip_removal_failed') THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'not_retryable', 'issue', v_issue,
      'message', 'This kind of sync problem is not fixed by retrying.');
  END IF;

  IF v_state = 'needs_data_fix' THEN
    RETURN jsonb_build_object('ok', false, 'blocked', 'needs_data_fix',
      'message', 'Retrying will fail the same way. The underlying data needs correcting first.');
  END IF;

  v_dup := public.fn_visit_push_duplicate_of(p_visit_id);
  IF v_dup IS NOT NULL AND NOT p_force THEN
    SELECT string_agg(li.name, ', ') INTO v_dup_svc
      FROM public.line_items li WHERE li.visit_id = v_dup;
    RETURN jsonb_build_object('ok', false, 'blocked', 'duplicate',
      'duplicate_of', v_dup, 'duplicate_of_service', v_dup_svc);   -- NULL when the sibling has none
  END IF;

  UPDATE public.visit_sync_flags
     SET attempts = 0, next_attempt_at = NULL, auto_retry_state = 'pending'
   WHERE visit_id = p_visit_id AND resolved_at IS NULL;

  -- A skipped visit still linked in Jobber needs its REMOVAL pushed, not an upsert that would
  -- re-create work the office deliberately cancelled.
  v_op := CASE WHEN v_status = 'skipped' THEN 'delete' ELSE 'upsert' END;
  PERFORM public.fn_request_jobber_push(p_visit_id, v_op);

  RETURN jsonb_build_object('ok', true, 'op', v_op, 'forced', COALESCE(v_dup IS NOT NULL, false));
END;
$function$;

REVOKE ALL     ON FUNCTION public.retry_visit_push(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.retry_visit_push(bigint, boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ops-readable drift text. The base view's `detail` ends with "(see project_gate4_drift_watchdog)" —
-- an internal memory/doc filename that was rendering verbatim into the Calendar for Yannick, who has
-- nowhere to go with it. The base view stays as-is (it is the engineer-facing diagnostic feed and
-- log_calendar_push_health consumes it); only the UI-facing view is rewritten.
-- ⚠ `duplicate_of_visit_id` is forced NULL on drift rows: the duplicate guard answers "would pushing
-- create a twin", which is a meaningless question for a visit that is already in Jobber and merely
-- disagrees. Leaving it populated invites a UI to offer a force.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_calendar_push_health_by_visit AS
SELECT DISTINCT ON (h.visit_id)
       h.visit_id, h.client_code, h.client_name, h.visit_date, h.source,
       h.issue, h.reason,
       CASE WHEN h.issue = 'drift_surfaced'
            THEN 'This visit was changed in Jobber by a person and our copy disagrees. '
              || 'Someone needs to decide which one is right - retrying would overwrite their change.'
            ELSE h.detail END                     AS detail,
       h.since,
       CASE WHEN h.issue = 'drift_surfaced' THEN NULL
            ELSE public.fn_visit_push_duplicate_of(h.visit_id) END AS duplicate_of_visit_id,
       COALESCE(f.attempts, 0)                    AS attempts,
       f.auto_retry_state,
       f.next_attempt_at,
       (SELECT array_agg(DISTINCT h2.issue)
          FROM ops.v_calendar_push_health h2
         WHERE h2.visit_id = h.visit_id)           AS all_issues,
       -- ⚠ APPENDED LAST, and it must stay last. CREATE OR REPLACE VIEW can only ADD columns at the
       -- END; inserting this before all_issues failed with 42P16 "cannot change name of view column".
       -- That failure rolled the whole migration back, which left the UNGUARDED retry_visit_push live
       -- while I believed the guard had shipped -- and I then pushed a real drift row with it.
       -- Lets the UI gate the "retrying automatically" line on reality rather than on a NULL state
       -- field: the driver only ever picks up these two issues, so anything else is NOT being retried
       -- and must never claim to be.
       (h.issue IN ('not_in_jobber','push_failed')) AS is_auto_retryable
  FROM ops.v_calendar_push_health h
  LEFT JOIN public.visit_sync_flags f
    ON f.visit_id = h.visit_id AND f.resolved_at IS NULL
 ORDER BY h.visit_id,
          CASE h.issue WHEN 'push_failed'         THEN 1
                       WHEN 'skip_removal_failed' THEN 2
                       WHEN 'not_in_jobber'       THEN 3
                       WHEN 'drift_surfaced'      THEN 4
                       ELSE 5 END;

REVOKE ALL    ON ops.v_calendar_push_health_by_visit FROM PUBLIC, anon;
GRANT  SELECT ON ops.v_calendar_push_health_by_visit TO authenticated, service_role, yannick_readonly;
