-- ============================================================================================
-- 2026-09-15_1300_generated_sheet_finisher_cron.sql
--
-- Schedules the generated-sheet finisher: every ten minutes, complete what can be completed (no
-- HTTP, and it is what a HAND-measured generated sheet needs too), then request at most two page
-- measurements from the edge function measure-generated-page, budgeted three attempts per image by
-- derm.generated_measure_attempts. No HTTP call when there is nothing to do (same shape as
-- city-email-sweep and sheet-row-ocr-sweep).
--
-- Minute offset 6-59/10: after sheet-number-ocr-sweep (2-59/10) and sheet-row-ocr-sweep (4-59/10),
-- so a freshly filed sheet's page map and row reads have usually landed by the time it runs, and
-- before redact-manifest-sweep's next 3-59/5 tick picks up the completion.
--
-- The attempt is recorded BEFORE the request is posted (derm.generated_measure_attempts, same rule
-- as row_ocr_attempts): a worker that dies still consumes its budget, which is the fail-safe side.
-- RULE 8: no table changes.
-- ============================================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_generated_measure()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_key text; t record; f record;
BEGIN
  -- 1. completion first: no HTTP, and a generated sheet a person measured by hand completes here
  FOR f IN SELECT dump_folder FROM derm.v_generated_complete_backlog WHERE blocker IS NULL LOOP
    PERFORM derm.fn_complete_generated_sheet(f.dump_folder);
  END LOOP;

  -- 2. measurement requests, budgeted
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping generated-sheet measure';
    RETURN;
  END IF;
  FOR t IN SELECT * FROM derm.fn_generated_measure_targets(2) LOOP
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome)
    VALUES (t.dump_folder, t.page, t.image_url, t.source_etag, 1, 'requested')
    ON CONFLICT (dump_folder, page) DO UPDATE
       SET attempts = CASE
                        WHEN derm.generated_measure_attempts.image_url IS DISTINCT FROM EXCLUDED.image_url
                          OR derm.generated_measure_attempts.source_etag IS DISTINCT FROM EXCLUDED.source_etag
                        THEN 1                                            -- new scan, fresh budget
                        ELSE derm.generated_measure_attempts.attempts + 1
                      END,
           image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
           last_outcome = 'requested', last_attempt_at = now();
    PERFORM net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-generated-page',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('dump_folder', t.dump_folder, 'ticket', t.ticket, 'page', t.page, 'image_url', t.image_url),
      timeout_milliseconds := 120000);
  END LOOP;
END $function$;
REVOKE ALL ON FUNCTION public.fn_request_generated_measure() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('generated-sheet-finisher', '6-59/10 * * * *',
                     'SELECT public.fn_request_generated_measure()');

-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_n int; v_q0 bigint; v_q1 bigint; v_att int;
  -- only OUR requests: completing a sheet inside this VERIFY also queues the blackout kick
  -- (trg_zz_publish_on_complete -> fn_request_blackout_sweep), which is not a measure request
  v_mine constant text := '%/functions/v1/measure-generated-page';
BEGIN
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'generated-sheet-finisher') <> 1 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: job'; END IF;
  IF (SELECT schedule FROM cron.job WHERE jobname = 'generated-sheet-finisher') <> '6-59/10 * * * *' THEN RAISE EXCEPTION 'VERIFY 1a FAILED: schedule'; END IF;
  IF (SELECT count(*) FROM cron.job WHERE schedule = '6-59/10 * * * *') <> 1 THEN RAISE EXCEPTION 'VERIFY 1b FAILED: another job shares the minute'; END IF;

  -- 2. with an empty measure backlog the wrapper queues NO request (in a savepoint, so the
  --    completion loop's real work, if any, is left to the first scheduled run, not to this file)
  IF EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5)) THEN
    RAISE EXCEPTION 'VERIFY 2 SETUP: the measure backlog is not empty right now; re-run when it is, or read it first';
  END IF;
  BEGIN
    SELECT count(*) INTO v_q0 FROM net.http_request_queue WHERE url LIKE v_mine;
    PERFORM public.fn_request_generated_measure();
    SELECT count(*) INTO v_q1 FROM net.http_request_queue WHERE url LIKE v_mine;
    IF v_q1 <> v_q0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % measure request(s) queued with nothing to do', v_q1 - v_q0; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- 3. with one page in the backlog (ticket-834742 p2, stripped inside a savepoint) it queues exactly
  --    one request and records the attempt first; a second run counts the second attempt
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = 'ticket-834742';
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = 'ticket-834742';
    DELETE FROM derm.page_block_extents WHERE dump_folder = 'ticket-834742' AND effective_page = 2;
    DELETE FROM derm.page_rule_scans WHERE dump_folder = 'ticket-834742' AND effective_page = 2 AND source LIKE 'human-v1-%';
    SELECT count(*) INTO v_q0 FROM net.http_request_queue WHERE url LIKE v_mine;
    PERFORM public.fn_request_generated_measure();
    SELECT count(*) INTO v_q1 FROM net.http_request_queue WHERE url LIKE v_mine;
    IF v_q1 - v_q0 <> 1 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % request(s) queued for one page', v_q1 - v_q0; END IF;
    SELECT attempts INTO v_att FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742' AND page = 2 AND last_outcome = 'requested';
    IF v_att IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'VERIFY 3a FAILED: attempts %', v_att; END IF;
    PERFORM public.fn_request_generated_measure();
    SELECT attempts INTO v_att FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742' AND page = 2;
    IF v_att IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'VERIFY 3b FAILED: attempts %', v_att; END IF;
    -- the queued request carries the page and the live image
    IF NOT EXISTS (SELECT 1 FROM net.http_request_queue q
                    WHERE q.url LIKE '%/functions/v1/measure-generated-page'
                      AND convert_from(q.body, 'UTF8')::jsonb->>'dump_folder' = 'ticket-834742'
                      AND (convert_from(q.body, 'UTF8')::jsonb->>'page')::int = 2) THEN
      RAISE EXCEPTION 'VERIFY 3c FAILED: the queued body is not the page';
    END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742') THEN RAISE EXCEPTION 'CLEANUP FAILED'; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: job scheduled at 6-59/10; no request with an empty backlog; one request per backlog page, attempt recorded first, second run counts 2.';
END
$verify$;

COMMIT;
