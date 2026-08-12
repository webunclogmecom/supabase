-- 2026-08-12_1930_client_create_reservation.sql
--
-- WHAT: turn public.client_create_attempts from a passive ledger into the ATOMIC RESERVATION
--       for a create-client attempt. Adds client_code, code_number, client_id, a new terminal
--       status 'orphaned', two partial unique indexes, and an ops view for attempts needing a human.
--
-- WHY, Fred 2026-08-12: "if when on moment of creation to do a transaction to first check nothing
--       that should be unique (like the client code) already exists, and if it does then to stop the
--       creation and let the user to keep editing on the same form".
--
-- 🛑 THE RACE IS MEASURED, NOT THEORETICAL. Three concurrent propose_only calls on 2026-08-12 all
--    returned number 300 ("300-ADG", "300-BBG", "300-GGG"). The proposal is max(number)+1 from a
--    plain SELECT and every uniqueness check is a plain SELECT with no lock, so N staff opening the
--    form together are all handed the same number, all pass the pre-checks, and all reach the
--    irreversible Jobber clientCreate.
--
-- ⚠ AND THE OBVIOUS FIX IS THE WRONG ONE. A unique index on client_code alone does NOT close it:
--    the three racing codes above are three DISTINCT strings sharing one NUMBER. Per
--    docs/reference/client_code_scheme.md the NUMBER "is what must be globally unique" and the tag
--    is cosmetic, but the only constraint that exists (clients_active_client_code_uniq) is on the
--    whole string. So the thing the convention calls the identity has never been enforced anywhere.
--    Hence TWO indexes below, and the number one is the one that closes the measured race.
--
-- ⚠ WHY THIS IS NOT A CONSTRAINT ON public.clients. It cannot be: the number is already duplicated
--    on live rows, measured 2026-08-12.
--      000-DP  DUMP Pompano          + 000-DH  Homestead Dump              <- DELIBERATE dump band
--      247-EC  Excelsior Condo       + 247-LOU Skinny Louie Coral Gables   <- ACCIDENTAL
--    The 247 pair was introduced by the 2026-07-06 bulk wave: audit.logs shows client 44 receiving
--    247-EC from app_source='sql' on 2026-07-06 while client 500 already held 247-LOU (created
--    2026-07-03). **So this exact bug has already happened once in production, by a different
--    route.** Neither pair is touched here: renumbering a live client rewrites Jobber and the DB and
--    is Fred's call, not a migration's. Reported, not fixed.
--
-- ⚠ SCOPE OF THE GUARANTEE, stated so nobody over-reads it. These indexes make CONCURRENT ATTEMPTS
--    mutually exclusive. They do NOT retrofit uniqueness onto history, they do NOT see codes held
--    only in Jobber (the edge function's Jobber check covers that, and only for an exact full-code
--    match), and they cannot make the external Jobber mutation transactional. What they buy is that
--    two racing attempts can no longer BOTH reach clientCreate with the same identity.
--
-- ⚠ 000 IS EXCLUDED FROM THE NUMBER INDEX ON PURPOSE. It is a real band with two live members, so
--    reserving it would block a legitimate third dump site.
--
-- AUDIT (ADR 010): still opted OUT, unchanged from 2026-08-11_1900. This is operational plumbing for
--    an in-flight request, not business data, and it holds no human-editable field. The business
--    record it leads to is public.clients, which IS audited.
--
-- GRANTS: unchanged (service_role, plus yannick_readonly arriving from a schema default privilege).
--    Re-asserted below rather than assumed, because ALTER TABLE ADD COLUMN does not re-run grants
--    but the assertions are cheap and this file is the last word on the table's shape.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.client_create_attempts
  ADD COLUMN IF NOT EXISTS client_code text,
  ADD COLUMN IF NOT EXISTS code_number int,
  ADD COLUMN IF NOT EXISTS client_id   bigint;

COMMENT ON COLUMN public.client_create_attempts.client_code IS
  'The exact code this attempt is claiming. Half of the reservation; see client_create_attempts_code_uniq.';
COMMENT ON COLUMN public.client_create_attempts.code_number IS
  'The NNN part of client_code as an int. This is the real identity per client_code_scheme.md, and it '
  'is what the measured 2026-08-12 race collided on (three distinct codes, one number). 0 is the dump '
  'band and is deliberately not reserved.';
COMMENT ON COLUMN public.client_create_attempts.client_id IS
  'Our local clients.id, written only once the import is confirmed. Lets already_created point the '
  'user at the client instead of dead-ending with a bare Jobber GID.';

-- ---------------------------------------------------------------------------
-- 2. NO BACKFILL, and that is a decision rather than an omission
-- ---------------------------------------------------------------------------
-- 🛑 THE FIRST VERSION OF THIS FILE BACKFILLED client_code FROM payload AND THE MIGRATION REFUSED
--    ITSELF: "could not create unique index ... Key (client_code)=(299-AIC) is duplicated". That was
--    the right answer to the wrong question, and it exposed a modelling error worth recording.
--
--    A RESERVATION IS A STATEMENT ABOUT THE FUTURE, NOT A SUMMARY OF THE PAST. The historical rows
--    are development attempts whose clients were created and then deliberately hard-deleted during
--    testing. Backfilling them would have reserved 300-BSC, 300-CS and 300-PV forever -- three codes
--    that are genuinely FREE, because their clients no longer exist -- and would have reserved
--    299-AIC twice over. The ledger has no vocabulary for "created, then deleted", and inventing one
--    purely to satisfy an index would be tail-wagging-dog.
--
--    So historical rows keep client_code = NULL and simply do not participate. The partial indexes
--    are NULL-tolerant by construction. Codes already held by a LIVE client are still protected by
--    clients_active_client_code_uniq and by the function's own DB check; the reservation only has to
--    cover the window those two cannot see, which is the gap between concurrent in-flight attempts.

-- ---------------------------------------------------------------------------
-- 3. a terminal status for "Jobber has it and we do not"
-- ---------------------------------------------------------------------------
-- 🛑 THE BUG THIS EXISTS FOR. The function wrote status='created' immediately after the mutation
--    returned, BEFORE the re-read verify and BEFORE the webhook replay. Both of those failure paths
--    then returned without touching the ledger, so an attempt that created a Jobber client we never
--    imported was recorded as 'created' -- which 2026-08-11_1900's own header defines as "Jobber
--    confirmed on re-read AND webhook-jobber returned a positive entity_id", precisely the two things
--    that did not happen. The documented reconcile query over status='unknown' therefore returned
--    nothing, and the orphan was invisible. 'orphaned' is that missing state.
ALTER TABLE public.client_create_attempts DROP CONSTRAINT IF EXISTS client_create_attempts_status_check;
ALTER TABLE public.client_create_attempts
  ADD CONSTRAINT client_create_attempts_status_check
  CHECK (status IN ('started','unknown','created','failed','orphaned'));

-- ---------------------------------------------------------------------------
-- 4. THE RESERVATION. Two partial unique indexes over the statuses that mean "spoken for".
-- ---------------------------------------------------------------------------
-- 'failed' is excluded: it means we are CERTAIN no Jobber client exists, so the code is free again
-- and the user can retry with it. Every other status either holds a real client or might.
CREATE UNIQUE INDEX IF NOT EXISTS client_create_attempts_code_uniq
  ON public.client_create_attempts (client_code)
  WHERE client_code IS NOT NULL AND status IN ('started','unknown','created','orphaned');

CREATE UNIQUE INDEX IF NOT EXISTS client_create_attempts_number_uniq
  ON public.client_create_attempts (code_number)
  WHERE code_number IS NOT NULL AND code_number <> 0
    AND status IN ('started','unknown','created','orphaned');

-- ---------------------------------------------------------------------------
-- 5. observability: nothing watched this table at all before today
-- ---------------------------------------------------------------------------
-- Measured 2026-08-12: zero pg_cron jobs reference client_create_attempts, and there is no view.
-- A wedged 'started' row or an 'unknown' would have sat forever with nobody able to find it.
CREATE OR REPLACE VIEW public.v_client_create_attention AS
SELECT a.idempotency_key,
       a.requested_by,
       a.client_code,
       a.status,
       a.failure_reason,
       a.jobber_client_gid,
       a.created_at,
       now() - a.created_at AS age,
       CASE
         WHEN a.status = 'orphaned' THEN 'Jobber holds this client and we never imported it. Check Jobber, then import or delete it there.'
         WHEN a.status = 'unknown'  THEN 'We do not know whether Jobber created this. Check Jobber BEFORE anyone retries.'
         WHEN a.status = 'started'  THEN 'Stuck mid-flight. It holds its code reserved. Confirm against Jobber before releasing.'
       END AS what_to_do
  FROM public.client_create_attempts a
 WHERE a.status IN ('orphaned','unknown')
    OR (a.status = 'started' AND a.created_at < now() - interval '5 minutes');

COMMENT ON VIEW public.v_client_create_attention IS
  'Create-client attempts needing a human. A stuck ''started'' row still HOLDS its code reservation, '
  'which is fail-safe (Jobber may hold the client) but burns the number until someone resolves it. '
  'Gaps in the number sequence are normal per client_code_scheme.md, so burning one is acceptable.';

REVOKE ALL ON public.v_client_create_attention FROM PUBLIC;
REVOKE ALL ON public.v_client_create_attention FROM anon;
REVOKE ALL ON public.v_client_create_attention FROM authenticated;
GRANT SELECT ON public.v_client_create_attention TO service_role;

-- ---------------------------------------------------------------------------
-- 6. assertions. Read the catalogue AFTER the fact; never trust the statements above.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int; k uuid; k2 uuid;
BEGIN
  -- (a) both reservation indexes exist and are UNIQUE and PARTIAL
  SELECT count(*) INTO n FROM pg_indexes
   WHERE schemaname='public' AND tablename='client_create_attempts'
     AND indexname IN ('client_create_attempts_code_uniq','client_create_attempts_number_uniq')
     AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%WHERE%';
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 partial unique reservation indexes, found %', n; END IF;

  -- (b) 🛑 THE RESERVATION MUST ACTUALLY BITE. Asserting the index exists is not asserting it works;
  --     that is the "a migration that verifies its own GRANT statements" trap from CLAUDE.md. Insert
  --     two rows racing for the SAME NUMBER with DIFFERENT codes -- the exact measured failure -- and
  --     require the second to raise.
  k  := gen_random_uuid();
  k2 := gen_random_uuid();
  INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
  VALUES (k, 'probe', '{}'::jsonb, 'started', '997-AAA', 997);
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (k2, 'probe', '{}'::jsonb, 'started', '997-BBB', 997);
    RAISE EXCEPTION 'GUARD FAILED: two attempts took number 997 with different tags; the number reservation does not bite';
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
      RAISE EXCEPTION 'number reservation raised an unexpected error: % / %', SQLSTATE, SQLERRM;
  END;

  -- (c) NEGATIVE CONTROL: releasing the first attempt must free the number, or the index is simply
  --     blocking everything and (b) proved nothing.
  UPDATE public.client_create_attempts SET status='failed' WHERE idempotency_key = k;
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (k2, 'probe', '{}'::jsonb, 'started', '997-BBB', 997);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'CONTROL FAILED: a ''failed'' attempt still holds its number, so the index is over-blocking: % / %', SQLSTATE, SQLERRM;
  END;

  -- (d) the 000 dump band must remain insertable twice, or a third dump site is blocked
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (gen_random_uuid(), 'probe', '{}'::jsonb, 'started', '000-XA', 0);
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status, client_code, code_number)
    VALUES (gen_random_uuid(), 'probe', '{}'::jsonb, 'started', '000-XB', 0);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'CONTROL FAILED: the 000 dump band is being reserved; a third dump site would be blocked: %', SQLERRM;
  END;

  DELETE FROM public.client_create_attempts WHERE requested_by = 'probe';

  -- (e) the new status is accepted and a bogus one still is not
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status)
    VALUES (gen_random_uuid(), 'probe2', '{}'::jsonb, 'orphaned');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'the new ''orphaned'' status was rejected by the CHECK: %', SQLERRM;
  END;
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status)
    VALUES (gen_random_uuid(), 'probe2', '{}'::jsonb, 'not_a_status');
    RAISE EXCEPTION 'GUARD FAILED: the status CHECK accepted an invalid value';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;
  DELETE FROM public.client_create_attempts WHERE requested_by = 'probe2';

  -- (f) grants unchanged and still not reachable by the browser roles
  IF has_table_privilege('authenticated','public.client_create_attempts','SELECT') THEN
    RAISE EXCEPTION 'authenticated can SELECT the attempts table'; END IF;
  IF has_table_privilege('anon','public.v_client_create_attention','SELECT') THEN
    RAISE EXCEPTION 'anon can SELECT the attention view'; END IF;
  IF NOT has_table_privilege('service_role','public.v_client_create_attention','SELECT') THEN
    RAISE EXCEPTION 'service_role cannot read the attention view'; END IF;
  -- POSITIVE CONTROL: the probe must return TRUE for something authenticated really can read.
  IF NOT has_table_privilege('authenticated','public.clients','SELECT') THEN
    RAISE EXCEPTION 'CONTROL FAILED: the privilege probe is not discriminating';
  END IF;

  RAISE NOTICE 'OK: reservation indexes bite, failed releases, 000 band free, orphaned status live';
END $$;

COMMIT;
