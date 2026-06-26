-- ============================================================================
-- 2026-06-26_fn_request_jobber_push.sql
-- ADR 010: SECURITY DEFINER helper that only fires an HTTP push (no table writes);
--          audit OPT-OUT (nothing to audit).
-- ----------------------------------------------------------------------------
-- Re-push primitive for the gate #4 drift watchdog (sync-jobber-visit-drift).
--
-- The watchdog cannot re-fire a push by calling the verify_jwt=true jobber-push-visit
-- over HTTP from the Edge runtime (the SERVICE_ROLE_KEY env did not satisfy the
-- gateway's JWT check in testing). Instead it re-uses the EXACT proven path the
-- trigger fn_push_visit_to_jobber uses: read the vault 'jobber_push_service_key'
-- and net.http_post {op, visit_id} to jobber-push-visit. Factored out so the
-- watchdog can invoke it per drifted visit via rpc('fn_request_jobber_push').
--
-- Fire-and-forget (pg_net), same as the trigger; the watchdog confirms actual
-- convergence by RE-READING Jobber after a short delay, not by trusting this call.
-- Idempotent: op='upsert' on a linked visit only edits schedule/title/team/lines,
-- never creates or deletes. service_role only.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_request_jobber_push(p_visit_id bigint, p_op text DEFAULT 'upsert')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', p_visit_id;
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', p_op, 'visit_id', p_visit_id)
  );
END;
$function$;

REVOKE ALL  ON FUNCTION public.fn_request_jobber_push(bigint, text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_request_jobber_push(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';
