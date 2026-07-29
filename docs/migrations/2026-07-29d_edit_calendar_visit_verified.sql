-- 2026-07-29d  edit_calendar_visit_verified — the commit half of the verified-write path
--
-- Companion to the `save-calendar-visit` edge function (Fred, 2026-07-29): a Calendar change must
-- reach Jobber and be verified BEFORE our DB is written. This is the write that happens last.
--
-- ⚠ ITS ONLY JOB IS THE SUPPRESSION. By the time this runs, the edge function has already pushed the
-- change to Jobber and re-read it to confirm. If we called plain `edit_calendar_visit`, the BEFORE
-- trigger `fn_push_visit_to_jobber` would fire and push the SAME change a second time. Setting
-- `app.suppress_jobber_push` inside the same transaction short-circuits that trigger.
--
-- ⚠ SET LOCAL, not SET. It must expire with the transaction. A session-level SET would silently
-- disable outbound pushes for every subsequent statement on that connection, and PostgREST pools
-- connections — so the next unrelated Calendar edit on the same backend would stop syncing to Jobber
-- with no error anywhere. That is exactly the silent-failure class this whole feature exists to
-- remove, and it would be introduced by the feature itself.
--
-- ⚠ service_role ONLY. This bypasses the Jobber push, so a caller who reaches it directly can change
-- a visit without Jobber ever hearing about it. Only the edge function (which has just done the
-- verification) may call it. NOT authenticated, and certainly not anon — the 2026-07-12 harden made
-- anon read-only on business data and this must not reopen that.
--
-- Returns `visits` unchanged, so it is a drop-in for the existing RPC's shape.
--
-- RULE 8 (ADR 010): no table or column change; the underlying edit_calendar_visit keeps its own audit
-- behaviour, and `visits` remains audited, so the write is still attributed.

CREATE OR REPLACE FUNCTION public.edit_calendar_visit_verified(p_visit_id bigint, p_patch jsonb)
RETURNS public.visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v public.visits;
BEGIN
  -- Transaction-scoped ONLY. See the header: a session-level SET would leak across pooled requests.
  PERFORM set_config('app.suppress_jobber_push', 'on', true);
  v := public.edit_calendar_visit(p_visit_id, p_patch);

  -- ⚠ CLOSE THE QUEUE, or the verified write gets pushed a SECOND time.
  -- Suppressing the trigger stops the synchronous push, but `trg_mark_visit_sync_pending` still sets
  -- sync_state='pending' on any watched-field change, and `resolve-stale-visit-sync-pending` (*/3)
  -- drains exactly (scheduled + pending). So a verified save would sit in that queue and be re-pushed
  -- three minutes later -- undoing the whole point of having verified it, and racing with any edit
  -- made in between. Caught by testing, not by reading: the first successful save left sync_state
  -- 'pending' (same trap as the staged test visits that reached Jobber on 2026-07-29).
  -- Marking 'confirmed' is honest here and ONLY here: the caller has already re-read Jobber and
  -- confirmed the values before calling this.
  UPDATE public.visits SET sync_state = 'confirmed' WHERE id = p_visit_id;
  SELECT * INTO v FROM public.visits WHERE id = p_visit_id;
  RETURN v;
END;
$function$;

REVOKE ALL     ON FUNCTION public.edit_calendar_visit_verified(bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.edit_calendar_visit_verified(bigint, jsonb) TO service_role;

-- Post-condition to check after applying:
--   has_function_privilege('anon',          'public.edit_calendar_visit_verified(bigint,jsonb)','EXECUTE') = false
--   has_function_privilege('authenticated', ...)                                                          = false
--   has_function_privilege('service_role',  ...)                                                          = true
