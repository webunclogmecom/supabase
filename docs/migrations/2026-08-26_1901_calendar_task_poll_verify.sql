-- 2026-08-26_1901_calendar_task_poll_verify.sql
--
-- WHAT: proves a real invocation of poll-calendar-tasks reaches the edge function AND runs its body.
--       Not part of 2026-08-26_1900, and not one statement either. Read the next paragraph before
--       "simplifying" it back into a DO block, because that version cannot work.
--
-- ============================================================================================
-- 🛑 YOU CANNOT POST AND OBSERVE THE RESPONSE IN ONE TRANSACTION. EVER.
-- ============================================================================================
-- net.http_post ENQUEUES: it inserts into net.http_request_queue and the pg_net background worker
-- drains that queue only once the transaction COMMITS. So any block that posts and then waits for
-- its own response is waiting for something that cannot happen until the block itself has ended.
-- A DO block is a single statement and therefore atomic, so wrapping the post and the read together
-- guarantees a null.
--
-- Measured, rather than reasoned:
--   * request 6146 -- post + read inside the migration's transaction, which then rolled back:
--     NO ROW in net._http_response at all, i.e. never sent.
--   * request 6147 -- the same block moved after a `COMMIT;` in the same submitted body: still no
--     response after 20 polls / 40 seconds.
--   * request 6150 -- the same block as its OWN separate submission: still null.
--     ⇒ All three fail for ONE reason, and it is not the transaction boundary: a DO block is a
--       single statement, so the post can never be dispatched while the same block is still polling
--       for its result. Position in the file is irrelevant; the atomicity of the block is the wall.
--   * request 6152 -- posted by STEP 1 below, read by STEP 2 below: **HTTP 200**, body
--     `{"ok":true,"status":"ok","checked":0,...}`, and 2 fresh sync_log rows. This shape works.
--
-- ⚠⚠ A CORRECTION TO WHAT THIS FILE FIRST CLAIMED, kept because the wrong version is the more
--    dangerous one to act on. It said "the Management API wraps an entire submitted body in ONE
--    transaction, so that COMMIT released nothing". **FALSE.** A controlled probe -- BEGIN; CREATE
--    TABLE; COMMIT; then a deliberate RAISE after it -- shows the table SURVIVES when queried from
--    a second submission. A mid-body COMMIT; genuinely commits and starts a new transaction.
--    ⇒ The real consequence runs the other way and is sharper: **a migration containing `COMMIT;`
--      IS NOT ATOMIC, and a failure after that COMMIT leaves the first half applied.** Assume a
--      partial apply is possible and make the pre-COMMIT half independently safe.
--
-- ⚠ RUN STEP 1 AND STEP 2 AS TWO SEPARATE SUBMISSIONS, and run them PROMPTLY: net._http_response
--   has NO url column and roughly six hours of retention, after which there is no evidence that a
--   given invocation ever happened.
-- ⚠ Calling the function once is harmless and idempotent: the poll only READS Jobber, and writes at
--   most one sync_log row plus any genuinely-changed completions.
-- ⚠ An HTTP 2xx proves the request ARRIVED. The fresh sync_log row is what proves the BODY RAN --
--   a function can return 200 from an early branch. Check both.

-- =============================================================================================
-- STEP 1 -- submit this on its own. Note the request id it returns.
-- =============================================================================================
SELECT net.http_post(
  url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/poll-calendar-tasks',
  headers := jsonb_build_object(
               'Content-Type', 'application/json',
               'Authorization', 'Bearer ' || (SELECT decrypted_secret
                                                FROM vault.decrypted_secrets
                                               WHERE name = 'edge_invoke_service_key')),
  body    := '{}'::jsonb,
  timeout_milliseconds := 60000) AS request_id;

-- =============================================================================================
-- STEP 2 -- submit this SEPARATELY, a few seconds later, with the id from STEP 1.
-- PASS = status_code 2xx AND fresh_sync_log_rows >= 1.
-- A NULL status_code means the worker has not drained the queue yet; re-run before concluding
-- anything, and only treat it as a failure once error_msg or timed_out is set.
-- =============================================================================================
-- SELECT r.id, r.status_code, r.error_msg, r.timed_out,
--        left(r.content, 200) AS body_head,
--        (SELECT count(*) FROM public.sync_log
--          WHERE sync_source = 'calendar-task-poll'
--            AND started_at > now() - interval '3 minutes') AS fresh_sync_log_rows
--   FROM net._http_response r
--  WHERE r.id = <request_id from STEP 1>;
