-- 2026-08-12_2045_reservation_release_on_created.sql
--
-- WHAT: drop 'created' from the two reservation predicates added three hours earlier in
--       2026-08-12_1930, so a completed attempt RELEASES its code and number.
--
-- WHY: 'created' means the webhook replay already inserted the row into public.clients. At that
--      point the code is protected by clients_active_client_code_uniq and by create-client's own
--      DB scan, so holding it in the ledger as well makes the ledger a permanent SECOND registry
--      of client codes. That is wrong in a way that only shows up later:
--
--        - renumber a client and the ledger still blocks the old number, forever
--        - delete a client (the sanctioned test-cleanup path) and its number stays burned unless
--          someone remembers to delete the ledger row too. That happened during today's own
--          testing: releasing 300 and 301 required deleting attempt rows by hand, which is a
--          maintenance step nobody will remember at 5pm on a Friday.
--
--      A reservation should cover exactly the window where nothing else can see the claim. That
--      window closes the moment public.clients holds the row.
--
-- ⚠ WHAT IS DELIBERATELY STILL HELD: 'started', 'unknown' and 'orphaned'. Each of those means a
--    Jobber client may exist that our DB does not have, so the code is spoken for by something we
--    cannot see. Holding it is the fail-safe direction, and burning a number is cheap: per
--    docs/reference/client_code_scheme.md gaps are normal and must not be backfilled.
--
-- ⚠ AND 'failed' STAYS EXCLUDED, unchanged: it means we are certain no Jobber client exists, so
--    the code is genuinely free and the user can retry with it immediately.
--
-- AUDIT (ADR 010): unchanged, still opted out. No new columns, no new table.

BEGIN;

DROP INDEX IF EXISTS public.client_create_attempts_code_uniq;
DROP INDEX IF EXISTS public.client_create_attempts_number_uniq;

CREATE UNIQUE INDEX client_create_attempts_code_uniq
  ON public.client_create_attempts (client_code)
  WHERE client_code IS NOT NULL AND status IN ('started','unknown','orphaned');

CREATE UNIQUE INDEX client_create_attempts_number_uniq
  ON public.client_create_attempts (code_number)
  WHERE code_number IS NOT NULL AND code_number <> 0
    AND status IN ('started','unknown','orphaned');

DO $$
DECLARE k uuid; k2 uuid; n int;
BEGIN
  -- (a) the predicates really did change
  SELECT count(*) INTO n FROM pg_indexes
   WHERE schemaname='public'
     AND indexname IN ('client_create_attempts_code_uniq','client_create_attempts_number_uniq')
     AND indexdef LIKE '%created%';
  IF n <> 0 THEN RAISE EXCEPTION 'a reservation index still mentions created; the release did not apply'; END IF;

  -- (b) an IN-FLIGHT attempt still blocks a second one. Without this, (c) would pass on an
  --     index that reserves nothing at all, which is the failure this whole feature guards.
  k := gen_random_uuid(); k2 := gen_random_uuid();
  INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
  VALUES (k, 'probe', '{}'::jsonb, 'started', '996-AAA', 996);
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (k2, 'probe', '{}'::jsonb, 'started', '996-BBB', 996);
    RAISE EXCEPTION 'GUARD FAILED: an in-flight attempt no longer reserves its number';
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (c) THE CHANGE ITSELF: completing the first attempt must free the number
  UPDATE public.client_create_attempts SET status='created' WHERE idempotency_key = k;
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (k2, 'probe', '{}'::jsonb, 'started', '996-BBB', 996);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'the release did not work: a created attempt still holds its number: %', SQLERRM;
  END;

  -- (d) but 'orphaned' must STILL hold, because Jobber may have the client
  UPDATE public.client_create_attempts SET status='orphaned' WHERE idempotency_key = k2;
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (gen_random_uuid(), 'probe', '{}'::jsonb, 'started', '996-CCC', 996);
    RAISE EXCEPTION 'GUARD FAILED: an orphaned attempt released its number; an orphan Jobber client could be shadowed';
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  DELETE FROM public.client_create_attempts WHERE requested_by = 'probe';
  RAISE NOTICE 'OK: created releases the reservation, started and orphaned still hold it';
END $$;

COMMIT;
