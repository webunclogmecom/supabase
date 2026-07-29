-- 2026-07-29g  Drop the now-dead sync_trigger_key from Vault (cleanup, last step of the retirement)
--
-- Prerequisites, all verified before running this:
--   * 2026-07-29e + f applied; cron.job holds 0 commands matching 'x-sync-key'.
--   * All three functions redeployed with verify_jwt=true and a fail-closed
--     `bearerRole(req) !== 'service_role'` gate. Committed as 44fb5d4.
--   * grep confirms 'TRIGGER_KEY' now appears ONLY inside comments in all three index.ts files,
--     i.e. no code path reads the old header any more.
--   * Positive proof: all three return HTTP 202 through public.fn_request_jobber_sync post-deploy
--     (net._http_response ids 31955-31957), and the 20:40 scheduled tick of jobber-poll-sync
--     returned 202 as well (id 31958).
--   * Negative proof: an unauthenticated POST to all three now returns 401 at the gateway. Before
--     this change the same call would have been ACCEPTED whenever SYNC_TRIGGER_KEY was empty.
--
-- WHY DROP IT. fn_request_jobber_sync wraps its headers in jsonb_strip_nulls, so once this secret is
-- gone the 'x-sync-key' header simply stops being sent. No function change is needed. The value is
-- already inert (nothing checks it), so this is hygiene rather than a fix: a dead secret still named
-- `sync_trigger_key` sitting in Vault is an invitation for someone to wire it back up, and the value
-- itself is compromised (it reached a session transcript, which is what started this work).
--
-- ⚠ THIS REMOVES THE ROLLBACK PATH documented in 2026-07-29f. That is deliberate. That rollback
-- reintroduced BOTH the plaintext literal in cron.job.command AND the fail-open gate, so it was never
-- a state worth returning to. If the bearer path ever needs undoing, revert 44fb5d4, redeploy the
-- three functions, and issue a FRESH secret. Do not resurrect this value.
--
-- ⚠ STILL OUTSTANDING, and it needs Fred (dashboard/CLI, not SQL): the Supabase Functions secret
-- `SYNC_TRIGGER_KEY` is still set. It is inert today because no deployed code reads it, so this is
-- not urgent and nothing breaks either way. Deleting it is the last loose end:
--     supabase secrets unset SYNC_TRIGGER_KEY --project-ref wbasvhvvismukaqdnouk
-- Left for Fred on purpose: it is the only irreversible step here, and the value is worthless, so
-- there is no cost to it waiting for a deliberate decision.
--
-- RULE 8 (ADR 010): no table or column change.

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'sync_trigger_key') THEN
    RAISE NOTICE 'sync_trigger_key already absent; nothing to do';
    RETURN;
  END IF;

  DELETE FROM vault.secrets WHERE name = 'sync_trigger_key';
  RAISE NOTICE 'sync_trigger_key removed from vault';
END
$do$;

-- ---------------------------------------------------------------------------
-- Post-conditions:
--   1. gone:
--        SELECT count(*) FROM vault.secrets WHERE name='sync_trigger_key';           -- 0
--   2. the bearer secret is UNTOUCHED (the wrapper hard-fails without it):
--        SELECT count(*) FROM vault.secrets WHERE name='edge_invoke_service_key';    -- 1
--   3. sync still works, read from the RESPONSE not the cron log:
--        SELECT public.fn_request_jobber_sync('poll');
--        SELECT id, status_code FROM net._http_response ORDER BY id DESC LIMIT 3;    -- expect 202
-- ---------------------------------------------------------------------------
