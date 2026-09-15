-- 2026-09-15_0907_city_email_go_live.sql
--
-- WHY: THE AUTOMATIC CITY EMAIL AND THE MANUAL CITY SENDS GO TO PRODUCTION.
-- ---------------------------------------------------------------------------
-- Fred, 2026-09-15: "i think is ready, i have done some testing myself looks good. So make it on
-- production now, check visually that no test mode is still on it, specially the UI ones, we need
-- now production".
--
-- This file is the DATABASE half of the cutover: the 2026-09-12 test mode (t7_apply / t7_cron3,
-- Building Apps session) is restored to the standard values and the four go-live steps of
-- Supabase/CLAUDE.md run in ONE transaction, in the documented order, with the data step first.
-- The other halves ship in the same hour, in this order, after this commits:
--   2026-09-15_0925_visit_city_email_exposes_addresses.sql   To line for the Admin Review dialog
--   supabase/functions/send-visit-photos-email                IS_TEST retired, To resolved from
--                                                             public.properties.city_emails,
--                                                             test_recipient refused with 400
--   Admin Review + DERM Tracker (Lovable)                     Test mode boxes and test fields gone
--
-- APPLIED 2026-09-15 09:07:34 ET as one Management API body; VERIFY passed (read-back below the file in the commit message).
-- What changes here (measured before, 2026-09-15 08:39 ET):
--   city_email_delay           '5 minutes'                     -> '24 hours'
--   city_email_live_sends      'false'                         -> 'true'
--   city_email_test_recipient  'fred@ayache.com'               -> ''
--   city_email_start_from      '2026-09-12 10:39:44.333224+00' -> now()::text   (LAST)
--   cron city-email-sweep      '*/3 * * * *'                   -> '7 * * * *'
--   asserted unchanged:        city_email_retry_after '20 hours', city_email_batch_limit '5',
--                              client_email_live_sends 'true'
--   properties.city_emails     cleared on 42 (009-CN), 973 (249-LOU), 363 (client 42), 162 and
--                              1057 (both 112-YA, the non_customer_clients kind='test' client)
--
-- WHY THIS ORDER, AND WHY ONE TRANSACTION. fn_request_city_email_sweep copies
-- city_email_test_recipient into every request body unconditionally, and send-derm-email only
-- FORCES that value while the gate is closed; it never clears it once the gate is open. Gate open
-- with the recipient still set = every automatic send goes to Fred as is_test=true, never
-- satisfies already_sent (which filters is_test=false once live), and is retried every 20 hours.
-- Recipient cleared with the gate closed = 503 city_gate_misconfigured on every DERM email, city
-- and client. Both statements in one transaction means no observer can see either half-state.
--
-- WHY start_from = now(), AND WHY THE FLIP MAILS NOTHING. The live view body was simulated with
-- these exact values (scenario A: live_sends true, delay 24 hours, start_from now()):
--   already_sent 16, awaiting_manual_send 128, no_city_email 576, no_property 12,
--   recently_attempted 2, ready 0, waiting 0, before_go_live 0
-- identical to the census with the 2026-09-12 test value. Under live mode only is_test=false rows
-- count as the unlocking manual send, and public.visit_photo_email_sends holds ZERO such rows
-- (send-visit-photos-email has hard-coded IS_TEST = true since 2026-08-15), so every otherwise
-- eligible pair is held at awaiting_manual_send before the cutoff arm is even reached. The queue
-- is empty at commit and stays empty until a REAL manual Admin Review send, without the manifest,
-- lands after this instant; that pair is swept 24 hours later at the next :07.
-- now() rather than the test instant because with now() every admitted pair needs an event
-- strictly after go-live (the 2026-08-28 "start from now" decision, honoured at the real go-live
-- instant), whereas the test instant would admit the 18 pairs blacked out on 09-14/15 (7 with a
-- city inbox) on the strength of a real manual send that predates the flip.
--
-- WHY THE PROPERTIES ARE CLEARED. Nothing rejects an internal address in properties.city_emails,
-- and from this commit a send is real: 42, 973 and 363 would mail Fred or Yan as if they were the
-- city and the real city would never get it; 162 is fred@ayache.com on the test client 112-YA;
-- 1057 is the same test client carrying two REAL Town of Surfside inboxes, so a real send on
-- visits 8107/8108 (the rehearsal visits) would mail a municipality a fake client's report.
-- Backed up first to backups/2026-09-15_city_emails_before_go_live.json (git-ignored). Re-add an
-- @ayache.com address to 162 deliberately if a live-path fixture is ever wanted, and remove it
-- afterwards.
--
-- The cron change sits in the same transaction as the config, matching 2026-08-28_0838 and
-- 2026-09-14_0620 (cron.job is a plain table; pg_cron picks the row up at commit). A */3 tick
-- that lands before the commit sees the old config and an empty queue; one after sees the new
-- config and an empty queue.
--
-- RULE 8: public.app_config and public.properties are both audited (2026-08-28_0605 and
-- 2026-05-17b), so every value change lands in audit.logs with old_row and is revertible.
-- cron.job is not audited; the schedule change is recorded in this header. app_config.updated_at
-- is a plain default with no trigger, so it is set explicitly here; audit.logs stays the timeline.

BEGIN;

-- ---------------------------------------------------------------------------
-- PRECONDITIONS: the exact state this file was written against. Anything else = re-read the live
-- state and re-measure; do not edit the expected values to make it pass.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_txt text; v_ids bigint[];
BEGIN
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_delay';
  IF v_txt IS DISTINCT FROM '5 minutes' THEN
    RAISE EXCEPTION 'PRE 1: city_email_delay is % (expected the 2026-09-12 test value 5 minutes)', coalesce(v_txt, 'NULL');
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_live_sends';
  IF lower(btrim(coalesce(v_txt, ''))) = 'true' THEN
    RAISE EXCEPTION 'PRE 2: city_email_live_sends already reads true; this file has run or someone flipped it. Stop.';
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_test_recipient';
  IF v_txt IS DISTINCT FROM 'fred@ayache.com' THEN
    RAISE EXCEPTION 'PRE 3: city_email_test_recipient is % (expected fred@ayache.com)', coalesce(v_txt, 'NULL');
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_start_from';
  IF v_txt IS DISTINCT FROM '2026-09-12 10:39:44.333224+00' THEN
    RAISE EXCEPTION 'PRE 4: city_email_start_from is % (expected the t7_apply instant)', coalesce(v_txt, 'NULL');
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_retry_after';
  IF v_txt IS DISTINCT FROM '20 hours' THEN
    RAISE EXCEPTION 'PRE 5: city_email_retry_after is %', coalesce(v_txt, 'NULL');
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_batch_limit';
  IF v_txt IS DISTINCT FROM '5' THEN
    RAISE EXCEPTION 'PRE 6: city_email_batch_limit is %', coalesce(v_txt, 'NULL');
  END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'client_email_live_sends';
  IF lower(btrim(coalesce(v_txt, ''))) <> 'true' THEN
    RAISE EXCEPTION 'PRE 7: client_email_live_sends is % (expected true; a DERM client send would vanish)', coalesce(v_txt, 'NULL');
  END IF;

  SELECT count(*) INTO v_n FROM cron.job WHERE jobname = 'city-email-sweep' AND active;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PRE 8: % active cron job(s) named city-email-sweep (expected 1)', v_n;
  END IF;
  SELECT schedule INTO v_txt FROM cron.job WHERE jobname = 'city-email-sweep';
  IF v_txt IS DISTINCT FROM '*/3 * * * *' THEN
    RAISE EXCEPTION 'PRE 9: city-email-sweep schedule is % (expected the test value */3 * * * *)', v_txt;
  END IF;

  -- the queue is empty BEFORE the flip (0 on every read since 2026-09-12 outside the rehearsal sends)
  SELECT count(*) INTO v_n FROM derm.v_city_email_queue;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 10: the queue holds % pair(s) before the flip; explain them first', v_n;
  END IF;

  -- the four properties, and ONLY those four, hold an internal address as a city email
  -- (the documented step-0 query tested two literals and could not see yan@ayache.com on 363)
  SELECT coalesce(array_agg(p.id ORDER BY p.id), '{}'::bigint[]) INTO v_ids
    FROM public.properties p
   WHERE p.deleted_at IS NULL
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e(e)
                  WHERE lower(e.e) LIKE '%@ayache.com' OR lower(e.e) LIKE '%@unclogme.com');
  IF v_ids IS DISTINCT FROM ARRAY[42, 162, 363, 973]::bigint[] THEN
    RAISE EXCEPTION 'PRE 11: live properties with an internal city email are % (expected {42,162,363,973}); re-measure before clearing', v_ids;
  END IF;

  -- 1057 is still the 112-YA Surfside row with two inboxes, and 112-YA is still a non-customer
  SELECT count(*) INTO v_n FROM public.properties p
   WHERE p.id = 1057 AND p.client_id = 381 AND p.deleted_at IS NULL AND p.city = 'Surfside'
     AND cardinality(coalesce(p.city_emails, '{}'::text[])) = 2;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PRE 12: property 1057 is not the 112-YA Surfside row with two inboxes any more; re-measure';
  END IF;
  SELECT count(*) INTO v_n FROM public.non_customer_clients WHERE client_id = 381;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PRE 13: client 381 (112-YA) is not on non_customer_clients; re-check before clearing its inboxes';
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- STEP 0: data. No internal address as a city email, and no municipality behind a test client.
-- ---------------------------------------------------------------------------
UPDATE public.properties
   SET city_emails = '{}'::text[]
 WHERE id IN (42, 973, 363, 162, 1057)
   AND deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- STEP 1: the standard delay back (5 minutes was the 2026-09-12 test value)
-- ---------------------------------------------------------------------------
UPDATE public.app_config
   SET value = '24 hours', updated_at = now()
 WHERE key = 'city_email_delay';

-- ---------------------------------------------------------------------------
-- STEP 2: open the gate BEFORE clearing the recipient
-- ---------------------------------------------------------------------------
UPDATE public.app_config
   SET value = 'true', updated_at = now()
 WHERE key = 'city_email_live_sends';

-- ---------------------------------------------------------------------------
-- STEP 3: now clear the recipient. Empty = the sweep sends no test_recipient and send-derm-email
-- resolves the real inboxes; the compliance BCC (derm@ayache.com) comes back with it.
-- ---------------------------------------------------------------------------
UPDATE public.app_config
   SET value = '', updated_at = now()
 WHERE key = 'city_email_test_recipient';

-- ---------------------------------------------------------------------------
-- STEP 4: the sweep back to hourly at :07
-- ---------------------------------------------------------------------------
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'city-email-sweep'),
                      schedule := '7 * * * *');

-- ---------------------------------------------------------------------------
-- STEP 5, LAST: the switch that admits pairs. now() is this transaction's start; nothing that
-- happened before it is ever swept unless a real manual send after it unlocks it.
-- ---------------------------------------------------------------------------
UPDATE public.app_config
   SET value = now()::text, updated_at = now()
 WHERE key = 'city_email_start_from';

-- ---------------------------------------------------------------------------
-- VERIFY (a raise rolls the whole transaction back; test mode stays exactly as it was)
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_txt text; v_ts timestamptz;
  v_ready integer; v_waiting integer; v_bgl integer; v_await integer;
BEGIN
  -- 1. the seven keys read exactly the production values
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_delay';
  IF v_txt IS DISTINCT FROM '24 hours' THEN RAISE EXCEPTION 'VERIFY 1a FAILED: city_email_delay = %', coalesce(v_txt, 'NULL'); END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_live_sends';
  IF v_txt IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'VERIFY 1b FAILED: city_email_live_sends = %', coalesce(v_txt, 'NULL'); END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_test_recipient';
  IF v_txt IS DISTINCT FROM '' THEN RAISE EXCEPTION 'VERIFY 1c FAILED: city_email_test_recipient = %', coalesce(v_txt, 'NULL'); END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_retry_after';
  IF v_txt IS DISTINCT FROM '20 hours' THEN RAISE EXCEPTION 'VERIFY 1d FAILED: city_email_retry_after = %', coalesce(v_txt, 'NULL'); END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'city_email_batch_limit';
  IF v_txt IS DISTINCT FROM '5' THEN RAISE EXCEPTION 'VERIFY 1e FAILED: city_email_batch_limit = %', coalesce(v_txt, 'NULL'); END IF;
  SELECT value INTO v_txt FROM public.app_config WHERE key = 'client_email_live_sends';
  IF v_txt IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'VERIFY 1f FAILED: client_email_live_sends = %', coalesce(v_txt, 'NULL'); END IF;

  -- 2. start_from parses with the exact cast the view performs, and it is this instant
  SELECT nullif(btrim(value), '')::timestamptz INTO v_ts FROM public.app_config WHERE key = 'city_email_start_from';
  IF v_ts IS NULL OR v_ts < now() - interval '1 minute' OR v_ts > now() THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: city_email_start_from = % (expected this transaction''s now())', v_ts;
  END IF;

  -- 3. the two interval readers parse (an unparseable value raises HERE, not on the first sweep)
  IF public.fn_city_email_delay() <> interval '24 hours' THEN
    RAISE EXCEPTION 'VERIFY 3a FAILED: fn_city_email_delay() = %', public.fn_city_email_delay();
  END IF;
  IF public.fn_city_email_retry_after() <> interval '20 hours' THEN
    RAISE EXCEPTION 'VERIFY 3b FAILED: fn_city_email_retry_after() = %', public.fn_city_email_retry_after();
  END IF;

  -- 4. the cron is hourly at :07 and still active
  SELECT schedule INTO v_txt FROM cron.job WHERE jobname = 'city-email-sweep' AND active;
  IF v_txt IS DISTINCT FROM '7 * * * *' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: city-email-sweep schedule = %', coalesce(v_txt, 'NULL / inactive');
  END IF;

  -- 5. the point of the value choice: the flip itself mails nothing, and nothing is timed to fire
  SELECT count(*) INTO v_n FROM derm.v_city_email_queue;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5a FAILED: the queue holds % pair(s) at the flip; the first :07 sweep would mail them', v_n;
  END IF;
  SELECT count(*) FILTER (WHERE status = 'ready'),
         count(*) FILTER (WHERE status = 'waiting'),
         count(*) FILTER (WHERE status = 'before_go_live'),
         count(*) FILTER (WHERE status = 'awaiting_manual_send')
    INTO v_ready, v_waiting, v_bgl, v_await
    FROM derm.v_city_email_candidates;
  IF v_ready <> 0 OR v_waiting <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5b FAILED: ready=% waiting=% (expected 0/0: no pair may be timed to fire off the flip)', v_ready, v_waiting;
  END IF;
  -- positive control on the census reading: the backlog must be sitting in awaiting_manual_send
  -- (128 in the simulation, fewer after step 0), or the view is not reading live mode the way the
  -- simulation did
  IF v_await = 0 THEN
    RAISE EXCEPTION 'VERIFY 5c FAILED: awaiting_manual_send = 0; the live-mode census does not match the simulation';
  END IF;

  -- 6. no live property holds an internal address, the five are cleared, and the test client
  --    resolves no inbox anywhere (recently_attempted is allowed: 1939/1940 sit there until the
  --    20-hour window after the 2026-09-15 12:30Z test send closes, then read no_city_email)
  SELECT count(*) INTO v_n FROM public.properties p
   WHERE p.deleted_at IS NULL
     AND EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e(e)
                  WHERE lower(e.e) LIKE '%@ayache.com' OR lower(e.e) LIKE '%@unclogme.com');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6a FAILED: % live propert(ies) still hold an internal city email', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.properties
   WHERE id IN (42, 973, 363, 162, 1057) AND cardinality(coalesce(city_emails, '{}'::text[])) = 0;
  IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 6b FAILED: only % of the 5 properties are cleared', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.v_city_email_candidates
   WHERE client_id = 381 AND status IN ('ready', 'waiting', 'before_go_live', 'awaiting_manual_send');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6c FAILED: % 112-YA pair(s) still resolve a city inbox', v_n; END IF;

  -- 7. it was audited (the trigger rows are visible inside this transaction)
  SELECT count(*) INTO v_n FROM audit.logs
   WHERE table_name = 'app_config' AND changed_at > now() - interval '1 minute';
  IF v_n < 4 THEN RAISE EXCEPTION 'VERIFY 7a FAILED: only % app_config audit row(s) in this transaction (expected 4)', v_n; END IF;
  SELECT count(*) INTO v_n FROM audit.logs
   WHERE table_name = 'properties' AND changed_at > now() - interval '1 minute';
  IF v_n < 5 THEN RAISE EXCEPTION 'VERIFY 7b FAILED: only % properties audit row(s) in this transaction (expected 5)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: live_sends=true, recipient empty, delay 24h, retry 20h, batch 5, start_from=%, cron 7 * * * *, queue 0, ready 0, waiting 0, before_go_live %, awaiting_manual_send %, 5 properties cleared. Next: migration 2 (v_visit_city_email.city_emails), deploy send-visit-photos-email, publish Admin Review + DERM Tracker.',
    v_ts, v_bgl, v_await;
END $do$;

COMMIT;