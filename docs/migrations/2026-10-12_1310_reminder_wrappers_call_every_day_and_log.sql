-- 2026-10-12_1310 reminder wrappers: call the edge function every day at 11 AM, and log a missing vault key
--
-- THE ASK
--   Audit 2026-10-12, critic P3: "Every reminder run writes one sync_log row: posted, nothing to post, skipped (no
--   key), or HTTP error. Then silence means something." Its finding 2: "A failed post looks the same as 'nothing to
--   post'. fn_request_admin_review_reminder returns without a call when nothing is waiting, and it returns with only a
--   `raise warning` when the vault key is missing. pg_cron logs both as succeeded."
--   The edge-fns review (blocking): the wrappers keep their own copy of the "is anything waiting" rule, so a quiet
--   day writes no row and the new health check (reminder_not_run) would email Fred a false "the reminder did not run".
--   Integrator decision D2: both wrappers stop returning early when nothing is waiting; they keep the 11 AM New York
--   gate and always call the edge function (one call a day), which posts nothing when nothing is waiting and writes
--   its run record. On a missing vault key the wrapper INSERTs a sync_log row with status 'error'.
--
-- WHAT CHANGES (bodies copied from the live pg_get_functiondef, md5 pinned below; diff in the bundle's tests/*.diff)
--   public.fn_request_admin_review_reminder(): the call to public.fn_admin_review_pending() and its early return are
--     removed (and the v_p variable that held it); a missing vault key now also inserts one public.sync_log row
--     (sync_source 'admin_review_reminder', status 'error', a plain-words message).
--   public.fn_request_stamp_sheets_reminder(): the derm.fn_stamp_open_sheets() early return is removed; the same
--     missing-key row (sync_source 'stamp_sheets_reminder').
--   Unchanged: the 11 AM gate (cron '0 15,16 * * *', only the run that is 11 AM in New York goes on), the vault read,
--   the net.http_post call, SECURITY DEFINER, search_path, the cron jobs.
--   Cost: one edge call a day per reminder, also on a quiet day. The edge functions already answer a quiet day with
--   "nothing is waiting" / "every sheet is completed" and post nothing (deployed code and the new code alike), so this
--   migration changes no Slack post. Deploy the new edge functions (run record) in the same window: until then a
--   quiet day calls the old function, which answers and writes no row (harmless, the health check is not live yet).
--
-- MEASURED 2026-10-12 13:07 ET: both wrappers ran at 15:00 and 16:00 UTC today, the 15:00 run called each edge
--   function (admin-review: posted, city 7, photos 127; stamp: posted, 2 sheets). net.http_request_queue empty.
--   Neither wrapper has another caller (pg_proc search) and no app reads them.
--
-- VERIFY (below), every probe inside a sub-block that always rolls back:
--   W1 shape: the hour gate is there exactly once; the body names neither fn_admin_review_pending /
--      fn_stamp_open_sheets nor jsonb_array_length (the early return is gone); it calls net.http_post on its own FULL
--      edge URL (https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/<fn>, so a wrong host fails too) and carries
--      its own sync_source.
--   W2 a copy of the NEW body with only the hour gate switched off (pg_temp, built from pg_proc.prosrc, the replace
--      asserted to hit): it queues exactly ONE net.http_request_queue row for that exact URL and writes no sync_log row.
--   W3 the same copy with the vault secret name changed to one that does not exist: it queues nothing and writes
--      exactly ONE sync_log row, its own source, status 'error', reason 'no vault key', a message with no em dash.
--   W4 the real function right now: it queues a call only when it is 11 AM in New York (so applying the migration
--      cannot post), and writes no row.
--   W5 grants: EXECUTE for service_role, none for PUBLIC, anon or authenticated (REVOKEd by name above).
--   W6 the cron jobs still call these wrappers at '0 15,16 * * *', active.
--   Mutation controls run against this file before apply (bundle tests/run_migrations.cjs): early return
--   kept, hour gate removed, missing-key insert removed, wrong sync_source, insert on every call, http_post removed,
--   wrong project host, anon grant, live body changed under the pin. Each must make this migration abort.
--
-- Rule 8: no table or column change. The only write is new public.sync_log rows on the missing-key path. sync_log is
--   the append-only run log every cron job writes; it has no audit trigger (existing opt-out, unchanged).
-- Grants: CREATE OR REPLACE keeps the ACL (postgres, service_role); REVOKE from PUBLIC, anon, authenticated by name.
-- Locks: a function replace locks only these two functions; their one caller is pg_cron at 15:00 and 16:00 UTC.
--   Apply outside 14:55 to 16:05 UTC. lock_timeout 3s so a wait cannot pile up.
-- ROLLBACK: re-apply the two live bodies saved in the bundle (work/live_fn_request_*_reminder__.sql, md5s below)
--   with CREATE OR REPLACE, then REVOKE as here. The edge functions work with either wrapper.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.fn_request_admin_review_reminder()'::regprocedure)) <> 'c4900b719e34e6728997dbb518e7138b' THEN
    RAISE EXCEPTION 'public.fn_request_admin_review_reminder changed since this migration was written: copy the new live body';
  END IF;
  IF md5(pg_get_functiondef('public.fn_request_stamp_sheets_reminder()'::regprocedure)) <> '064205c1f75b85031392e6f39e3ec0e2' THEN
    RAISE EXCEPTION 'public.fn_request_stamp_sheets_reminder changed since this migration was written: copy the new live body';
  END IF;
END $pin$;

CREATE OR REPLACE FUNCTION public.fn_request_admin_review_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  -- 11 AM Eastern whatever the season: the job runs at 15:00 and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  -- 2026-10-12 (audit): no "is anything waiting" test here any more. The edge function decides (it posts nothing when
  -- nothing is waiting) and writes its run record in public.sync_log on every call, so a quiet day leaves a row too.
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the Admin Review reminder';
    -- 2026-10-12 (audit): the edge function is never called on this path, so the wrapper writes the run record itself
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('admin_review_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The Admin Review Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/admin-review-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;

CREATE OR REPLACE FUNCTION public.fn_request_stamp_sheets_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  -- 11 AM Eastern whatever the season (Fred, 2026-10-07: every scheduled notification at 11): the job runs at 15:00
  -- and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  -- every sheet completed: post nothing (Fred, 2026-10-05). Since 2026-10-12 (audit) the edge function decides that,
  -- not this wrapper: it is called once a day and writes its run record in public.sync_log even when it posts nothing.
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the Stamp Studio reminder';
    -- 2026-10-12 (audit): the edge function is never called on this path, so the wrapper writes the run record itself
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('stamp_sheets_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The Stamp Studio Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;

REVOKE ALL ON FUNCTION public.fn_request_admin_review_reminder() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_request_stamp_sheets_reminder() FROM PUBLIC, anon, authenticated;

DO $verify$
DECLARE
  w record; src text; nogate text; nokey text;
  q0 bigint; q1 bigint; l0 bigint; l1 bigint; bad text;
  gate constant text := $g$if extract(hour from now() at time zone 'America/New_York') <> 11 then$g$;
  keyname constant text := $k$name = 'edge_invoke_service_key'$k$;
  -- W4: applying this at 11 AM New York would let the real wrapper queue its call (rolled back by the probe)
  want_calls constant bigint := CASE WHEN extract(hour from now() at time zone 'America/New_York') = 11 THEN 1 ELSE 0 END;
BEGIN
  FOR w IN SELECT * FROM (VALUES
      ('public.fn_request_admin_review_reminder()', 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/admin-review-reminder',
       'admin_review_reminder', 'fn_admin_review_pending', 'admin-review-reminder'),
      ('public.fn_request_stamp_sheets_reminder()', 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder',
       'stamp_sheets_reminder', 'fn_stamp_open_sheets', 'stamp-sheets-reminder')) AS t(fname, url, source, list_fn, job)
  LOOP
    SELECT prosrc INTO src FROM pg_proc WHERE oid = w.fname::regprocedure;

    -- W1
    IF (length(src) - length(replace(src, gate, ''))) / length(gate) <> 1 THEN
      RAISE EXCEPTION 'VERIFY W1: % must keep the 11 AM gate exactly once', w.fname;
    END IF;
    IF position(w.list_fn IN src) > 0 OR position('jsonb_array_length' IN src) > 0 THEN
      RAISE EXCEPTION 'VERIFY W1: % still reads % (the "nothing waiting" early return must be gone)', w.fname, w.list_fn;
    END IF;
    IF position('net.http_post' IN src) = 0 OR position(quote_literal(w.url) IN src) = 0 THEN
      RAISE EXCEPTION 'VERIFY W1: % no longer calls %', w.fname, w.url;
    END IF;
    IF position(quote_literal(w.source) IN src) = 0 THEN
      RAISE EXCEPTION 'VERIFY W1: % does not write its run record as %', w.fname, w.source;
    END IF;

    -- W2: the new body with only the hour gate switched off
    nogate := replace(src, gate, 'if false then');
    nokey := replace(nogate, keyname, $k$name = 'verify_missing_key_never_set'$k$);
    IF nokey = nogate THEN RAISE EXCEPTION 'VERIFY W3: the vault read was not found in %', w.fname; END IF;
    EXECUTE format('CREATE OR REPLACE FUNCTION pg_temp.verify_wrapper_nogate() RETURNS void LANGUAGE plpgsql SET search_path TO public AS %L', nogate);
    EXECUTE format('CREATE OR REPLACE FUNCTION pg_temp.verify_wrapper_nokey() RETURNS void LANGUAGE plpgsql SET search_path TO public AS %L', nokey);
    BEGIN
      SELECT count(*) INTO q0 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l0 FROM public.sync_log WHERE sync_source LIKE w.source || '%';
      PERFORM pg_temp.verify_wrapper_nogate();
      SELECT count(*) INTO q1 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l1 FROM public.sync_log WHERE sync_source LIKE w.source || '%';
      IF q1 - q0 <> 1 THEN
        RAISE EXCEPTION 'VERIFY W2: % queued % calls with the gate open, want exactly 1', w.fname, q1 - q0;
      END IF;
      IF l1 <> l0 THEN
        RAISE EXCEPTION 'VERIFY W2: % wrote % sync_log rows with the key present, want 0 (the edge function logs)', w.fname, l1 - l0;
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'UCM02', MESSAGE = 'roll back the W2 probe';
    EXCEPTION WHEN SQLSTATE 'UCM02' THEN NULL;
    END;

    -- W3: the same copy with no vault key
    BEGIN
      SELECT count(*) INTO q0 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l0 FROM public.sync_log WHERE sync_source = w.source;
      PERFORM pg_temp.verify_wrapper_nokey();
      SELECT count(*) INTO q1 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l1 FROM public.sync_log WHERE sync_source = w.source;
      IF q1 <> q0 THEN RAISE EXCEPTION 'VERIFY W3: % called the edge function without a key', w.fname; END IF;
      IF l1 - l0 <> 1 THEN
        RAISE EXCEPTION 'VERIFY W3: % wrote % sync_log rows for a missing key, want exactly 1', w.fname, l1 - l0;
      END IF;
      SELECT CASE
               WHEN s.status IS DISTINCT FROM 'error' THEN 'status ' || coalesce(s.status, 'null')
               WHEN s.details->>'reason' IS DISTINCT FROM 'no vault key' THEN 'reason ' || coalesce(s.details->>'reason', 'null')
               WHEN coalesce(s.error_details->>'message', '') = '' THEN 'no message'
               WHEN position(chr(8212) IN s.error_details->>'message') > 0 THEN 'em dash in the message'
               WHEN s.finished_at IS NULL OR s.rows_errored IS DISTINCT FROM 1 THEN 'finished_at / rows_errored'
             END INTO bad
        FROM public.sync_log s WHERE s.sync_source = w.source ORDER BY s.id DESC LIMIT 1;
      IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY W3: % missing-key row is wrong: %', w.fname, bad; END IF;
      RAISE EXCEPTION USING ERRCODE = 'UCM02', MESSAGE = 'roll back the W3 probe';
    EXCEPTION WHEN SQLSTATE 'UCM02' THEN NULL;
    END;
    DROP FUNCTION pg_temp.verify_wrapper_nogate();
    DROP FUNCTION pg_temp.verify_wrapper_nokey();

    -- W4: the real function, now
    BEGIN
      SELECT count(*) INTO q0 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l0 FROM public.sync_log WHERE sync_source LIKE w.source || '%';
      EXECUTE format('SELECT %s', w.fname);
      SELECT count(*) INTO q1 FROM net.http_request_queue WHERE url = w.url;
      SELECT count(*) INTO l1 FROM public.sync_log WHERE sync_source LIKE w.source || '%';
      IF q1 - q0 <> want_calls OR l1 <> l0 THEN
        RAISE EXCEPTION 'VERIFY W4: % queued % calls and wrote % rows at New York hour %', w.fname, q1 - q0, l1 - l0,
          extract(hour from now() at time zone 'America/New_York');
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'UCM02', MESSAGE = 'roll back the W4 probe';
    EXCEPTION WHEN SQLSTATE 'UCM02' THEN NULL;
    END;

    -- W5
    IF has_function_privilege('anon', w.fname, 'EXECUTE') OR has_function_privilege('authenticated', w.fname, 'EXECUTE')
       OR NOT has_function_privilege('service_role', w.fname, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = w.fname::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION 'VERIFY W5: % grants changed (want service_role only)', w.fname;
    END IF;

    -- W6
    IF NOT EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = w.job AND j.active AND j.schedule = '0 15,16 * * *'
                    AND j.command = 'select ' || w.fname) THEN
      RAISE EXCEPTION 'VERIFY W6: cron job % no longer calls % at 15:00 and 16:00 UTC', w.job, w.fname;
    END IF;
  END LOOP;
  RAISE NOTICE 'VERIFY ok: both wrappers call their edge function once a day at 11 AM and log a missing key';
END $verify$;

COMMIT;
