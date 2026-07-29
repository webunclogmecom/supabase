-- 2026-07-29f  Point the three jobber sync crons at the wrapper (part 2 of 2: the live cutover)
--
-- Prerequisite: 2026-07-29e applied and its post-conditions 1-4 all passed. They did:
--   vault_rows=1, vault_matches_cron=true, anon/authenticated/service_role EXECUTE all false,
--   and a real invocation of all three targets returned HTTP 202 {"accepted":true}
--   (net._http_response ids 31946-31951; the 500 alongside them is the pre-existing
--   redact-manifest-sheet 'targets rpc failed' / 57014 statement timeout, unrelated to this work).
--
-- WHAT THIS DOES. Replaces the inline net.http_post in each of the three cron commands with a call
-- to public.fn_request_jobber_sync(<target>). After this, cron.job.command holds NO secret.
--
-- ⚠ WHY THIS IS SAFE TO DO BEFORE THE EDGE FUNCTIONS CHANGE. The wrapper sends BOTH
-- 'Authorization: Bearer <service_role>' AND 'x-sync-key'. The handlers currently check only
-- x-sync-key and are verify_jwt=false, so behaviour is byte-for-byte what it was: same URL, same
-- body, same x-sync-key value (md5-verified equal to what cron was sending), plus one extra header
-- that is ignored. There is no window where neither credential works.
--
-- ⚠ pg_cron 1.6.4: cron.schedule(jobname, ...) UPSERTS on the existing job name, so this replaces
-- rather than duplicating. A duplicate would mean double-syncing, which is why the version was
-- checked before writing this. jobid MAY change; the job NAME is the stable identifier.
--
-- ⚠ DO NOT VERIFY THIS WITH cron.job_run_details. It reports status='succeeded' as soon as the
-- net.http_post queue insert commits -- pg_net is fire-and-forget, so a 401/403/500 from the far end
-- still reads 'succeeded'. Verify by reading net._http_response. Stated again here because this is
-- the single most likely way this change ends with inbound Jobber sync silently dead.
--
-- ROLLBACK. Fully reversible without needing the secret in hand, because the value is now in Vault:
--   SELECT cron.schedule('jobber-poll-sync', '*/5 * * * *', format(
--     $q$SELECT net.http_post(
--          url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-poll',
--          headers := jsonb_build_object('Content-Type','application/json','x-sync-key',%L),
--          body := '{}'::jsonb)$q$,
--     (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='sync_trigger_key')));
--   ...and likewise for the other two. Note this REINTRODUCES the plaintext, so it is a
--   break-glass step, not a resting state.
--
-- RULE 8 (ADR 010): no table or column change.

SELECT cron.schedule('jobber-poll-sync',             '*/5 * * * *',
                     $$SELECT public.fn_request_jobber_sync('poll')$$);

SELECT cron.schedule('jobber-upcoming-visits-sync',  '*/15 * * * *',
                     $$SELECT public.fn_request_jobber_sync('upcoming')$$);

SELECT cron.schedule('jobber-visit-drift-reconcile', '*/30 * * * *',
                     $$SELECT public.fn_request_jobber_sync('drift')$$);

-- ---------------------------------------------------------------------------
-- Post-conditions:
--   1. NO cron command contains the secret any more:
--        SELECT count(*) FROM cron.job WHERE command ~* 'x-sync-key';        -- must be 0
--   2. all three still active, still owned by postgres, schedules unchanged:
--        SELECT jobid, jobname, schedule, username, active, command FROM cron.job
--         WHERE jobname IN ('jobber-poll-sync','jobber-upcoming-visits-sync',
--                           'jobber-visit-drift-reconcile') ORDER BY jobname;
--   3. exactly one row per job name (no duplicate from the upsert):
--        SELECT jobname, count(*) FROM cron.job GROUP BY 1 HAVING count(*) > 1;   -- 0 rows
--   4. the NEXT scheduled run really reaches the function -- read the RESPONSE, not the cron log:
--        SELECT id, status_code, left(content,80) FROM net._http_response
--         WHERE id > <watermark> ORDER BY id;                                -- expect 202 accepted
-- ---------------------------------------------------------------------------
