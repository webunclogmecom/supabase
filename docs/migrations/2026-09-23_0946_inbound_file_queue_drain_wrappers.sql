-- 2026-09-23_0946_inbound_file_queue_drain_wrappers.sql
--
-- WHY
-- ---
-- Fred, 2026-09-23: "let's go with a testing phase first, to make sure we are ready for it."
-- Nothing drains sync.inbound_file_queue yet, so there is no complete path to test. These are the
-- claim/settle wrappers a drainer needs. `sync` is not an exposed PostgREST schema, so an edge
-- function cannot touch the queue directly (same reason fn_enqueue_inbound_file exists).
--
-- 🛑 WHY A CLAIM AND NOT A PLAIN SELECT. Two overlapping runs that both SELECT ... WHERE
-- status='pending' would both fetch the same file and create TWO photos rows pointing at two copies
-- of one image, with two photo_links, which a customer-facing gallery then shows twice. The claim is
-- an atomic UPDATE ... RETURNING behind FOR UPDATE SKIP LOCKED, so a row is handed to exactly one
-- worker. This is cheap now and unfixable-by-inspection later.
--
-- ⚠ THE RETRY BUDGET IS SPENT AT CLAIM TIME, NOT AT FAILURE TIME, AND THAT IS DELIBERATE.
-- attempts is incremented when a row is HANDED OUT. A worker that is OOM-killed or times out mid
-- fetch never reports anything, so a budget spent only on reported failures would let that row be
-- retried forever. Spending it at claim time means a silent death still costs an attempt, which is
-- the fail-safe direction. This repo already learned it on derm.row_ocr_attempts.
--
-- RULE 8: opts out. Machine-only plumbing, same as sync.outbound_queue. The photos and photo_links
-- rows the drainer ultimately writes are the durable record; the queue is scaffolding.

-- 🛑 A DEFECT THIS MIGRATION'S OWN VERIFY CAUGHT, RECORDED BECAUSE THE FIX IS NOT THE OBVIOUS ONE.
-- The first draft claimed a row by incrementing attempts and leaving status='pending', relying on
-- FOR UPDATE SKIP LOCKED for exclusivity. That is wrong, and the VERIFY failed with "the same row
-- was claimed twice". SKIP LOCKED only excludes transactions running CONCURRENTLY; the moment the
-- claim commits, the row is pending again and the next worker takes it. Two workers would then
-- fetch one file into two storage objects with two photos rows and two photo_links, and a customer
-- gallery would show the image twice. Exclusivity has to be in the ROW STATE, not in a lock that
-- ends at commit.
--
-- So a claim moves the row to 'claimed' with claimed_at, and a claim is reclaimable only after the
-- lease expires. The lease is what stops a worker that died mid-fetch from stranding the row
-- forever, and `attempts` is what stops the reclaim loop being infinite.

BEGIN;

ALTER TABLE sync.inbound_file_queue
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

ALTER TABLE sync.inbound_file_queue
  DROP CONSTRAINT IF EXISTS inbound_file_queue_status_chk;
ALTER TABLE sync.inbound_file_queue
  ADD  CONSTRAINT inbound_file_queue_status_chk
  CHECK (status IN ('pending','claimed','done','skipped','error'));

COMMENT ON COLUMN sync.inbound_file_queue.claimed_at IS
  'When this row was handed to a worker. A claim older than the lease is reclaimable, which is how '
  'a worker killed mid-fetch releases its row. Exclusivity lives here, not in a row lock: a lock '
  'ends at commit and the row would be immediately re-claimable.';

-- ---------------------------------------------------------------------------
-- claim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_claim_inbound_files(p_limit INTEGER DEFAULT 3)
RETURNS TABLE (
  id            BIGINT,
  entity_type   TEXT,
  entity_id     BIGINT,
  source_system TEXT,
  role          TEXT,
  source_url    TEXT,
  target_bucket TEXT,
  attempts      INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sync, public, pg_temp
AS $fn$
DECLARE
  v_max_attempts CONSTANT INTEGER  := 3;
  v_lease        CONSTANT INTERVAL := interval '10 minutes';
BEGIN
  -- p_limit is small on purpose: each claimed row is an HTTP fetch plus a storage upload inside one
  -- edge invocation, and this estate has already paid for an edge function that tried to do too
  -- much in one run (the base64 OOM). Keep it in single digits.
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 10 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 10, got %', p_limit
      USING DETAIL = 'blocker=bad_limit in public.fn_claim_inbound_files';
  END IF;

  RETURN QUERY
  WITH picked AS (
    SELECT q.id
      FROM sync.inbound_file_queue q
     WHERE q.attempts < v_max_attempts
       AND (
             q.status = 'pending'
             -- A claim whose lease expired is reclaimable: that is how a worker killed mid-fetch
             -- gives the row back. Without this a single OOM strands the file permanently.
             OR (q.status = 'claimed' AND q.claimed_at < now() - v_lease)
           )
     ORDER BY q.created_at
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE sync.inbound_file_queue q
     SET status     = 'claimed',
         claimed_at = now(),
         attempts   = q.attempts + 1,
         updated_at = now()
    FROM picked
   WHERE q.id = picked.id
  RETURNING q.id, q.entity_type, q.entity_id, q.source_system,
            q.role, q.source_url, q.target_bucket, q.attempts;
END
$fn$;

COMMENT ON FUNCTION public.fn_claim_inbound_files(INTEGER) IS
  'Atomically hand at most p_limit pending files to ONE worker (FOR UPDATE SKIP LOCKED) and spend '
  'an attempt on each. Spending the attempt at claim time means a worker killed mid-fetch still '
  'consumes budget, so a file that reliably kills a worker cannot retry forever.';

-- ---------------------------------------------------------------------------
-- settle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_settle_inbound_file(
  p_id       BIGINT,
  p_status   TEXT,
  p_photo_id BIGINT DEFAULT NULL,
  p_error    TEXT   DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sync, public, pg_temp
AS $fn$
DECLARE
  v_max_attempts CONSTANT INTEGER := 3;
  v_rows INTEGER;
BEGIN
  IF p_status NOT IN ('done', 'skipped', 'pending', 'error') THEN
    RAISE EXCEPTION 'unknown status %', p_status
      USING DETAIL = 'blocker=bad_status in public.fn_settle_inbound_file';
  END IF;

  -- 🛑 'done' REQUIRES a photo_id. A row marked done with nothing to show for it is the shape that
  -- makes a queue look drained while the images are gone: the work list empties, and the only
  -- evidence left is an absence nobody is counting.
  IF p_status = 'done' AND p_photo_id IS NULL THEN
    RAISE EXCEPTION 'cannot mark a file done without the photo it produced'
      USING DETAIL = 'blocker=done_without_photo in public.fn_settle_inbound_file';
  END IF;

  UPDATE sync.inbound_file_queue
     SET status = CASE
                    -- A reported failure stays retryable until the budget is gone, then sticks.
                    WHEN p_status = 'pending' AND attempts >= v_max_attempts THEN 'error'
                    ELSE p_status
                  END,
         -- Releasing the claim is what makes the row available again immediately, rather than
         -- after the lease expires. A reported failure should retry on the next pass, not in ten
         -- minutes; only an UNREPORTED death should wait for the lease.
         claimed_at   = CASE WHEN p_status = 'pending' THEN NULL ELSE claimed_at END,
         photo_id     = COALESCE(p_photo_id, photo_id),
         last_error   = p_error,
         updated_at   = now(),
         processed_at = CASE WHEN p_status IN ('done','skipped') THEN now() ELSE processed_at END
   WHERE id = p_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END
$fn$;

COMMENT ON FUNCTION public.fn_settle_inbound_file(BIGINT, TEXT, BIGINT, TEXT) IS
  'Close out a claimed file. done REQUIRES the photo id it produced, so a drained queue cannot mean '
  'an empty storage bucket. Reporting pending keeps it retryable until the attempt budget is spent, '
  'after which it sticks at error and stops being offered.';

-- ---------------------------------------------------------------------------
-- health, so "is it draining" is a question with an answer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_inbound_file_queue_health AS
SELECT
  entity_type,
  source_system,
  status,
  count(*)                                        AS rows,
  min(created_at)                                 AS oldest,
  max(updated_at)                                 AS last_touched,
  count(*) FILTER (WHERE attempts >= 3)           AS exhausted
FROM sync.inbound_file_queue
GROUP BY entity_type, source_system, status;

COMMENT ON VIEW public.v_inbound_file_queue_health IS
  'Inbound file queue by status. A growing pending count with an old `oldest` means the drainer is '
  'not running; rows in error mean a file could not be fetched three times. EMPTY IS HEALTHY.';

REVOKE ALL ON FUNCTION public.fn_claim_inbound_files(INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_settle_inbound_file(BIGINT, TEXT, BIGINT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_inbound_file_queue_health FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_claim_inbound_files(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_settle_inbound_file(BIGINT, TEXT, BIGINT, TEXT) TO service_role;
GRANT SELECT ON public.v_inbound_file_queue_health TO service_role;

DO $verify$
DECLARE
  v_qid   BIGINT;
  v_claim RECORD;
  v_n     INTEGER;
  v_ok    BOOLEAN;
  v_raised BOOLEAN;
BEGIN
  -- privileges, off the catalogue
  IF has_function_privilege('authenticated','public.fn_claim_inbound_files(integer)','EXECUTE')
     OR has_function_privilege('anon','public.fn_claim_inbound_files(integer)','EXECUTE') THEN
    RAISE EXCEPTION 'claim is reachable by an app role';
  END IF;
  IF NOT has_function_privilege('service_role','public.fn_claim_inbound_files(integer)','EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot claim; the drainer would fail';
  END IF;

  -- EXERCISE the bodies. PL/pgSQL is not parsed at creation time.
  v_qid := public.fn_enqueue_inbound_file(
    'inspection', 999999998, 'fillout', 'dashboard',
    'https://example.invalid/drain-probe.jpg', 'GT - Visits Images');

  SELECT * INTO v_claim FROM public.fn_claim_inbound_files(3) WHERE id = v_qid;
  IF v_claim.id IS NULL THEN RAISE EXCEPTION 'claim did not return the queued row'; END IF;
  IF v_claim.attempts <> 1 THEN
    RAISE EXCEPTION 'claim did not spend an attempt (got %)', v_claim.attempts;
  END IF;

  -- 🛑 THE ASSERTION THAT ALREADY EARNED ITS KEEP: it failed on the first draft and is the reason
  -- claim moves the row to 'claimed' instead of relying on FOR UPDATE SKIP LOCKED.
  SELECT count(*) INTO v_n FROM public.fn_claim_inbound_files(3) WHERE id = v_qid;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'the same row was claimed twice; two workers would double-download it';
  END IF;

  -- ...and the matching POSITIVE control: a claim whose lease has expired MUST come back, or a
  -- worker killed mid-fetch strands the file forever. Without this, the check above would also
  -- pass on a claim that is simply permanent.
  UPDATE sync.inbound_file_queue
     SET claimed_at = now() - interval '11 minutes' WHERE id = v_qid;
  SELECT count(*) INTO v_n FROM public.fn_claim_inbound_files(3) WHERE id = v_qid;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'an expired lease was not reclaimable; a dead worker would strand the file';
  END IF;

  -- done WITHOUT a photo must be refused. This is the assertion that matters most, so prove it
  -- actually raises rather than assuming it does.
  v_raised := false;
  BEGIN
    PERFORM public.fn_settle_inbound_file(v_qid, 'done', NULL, NULL);
  EXCEPTION WHEN others THEN
    v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'done was accepted with no photo id; a drained queue could mean an empty bucket';
  END IF;

  -- reporting pending with the budget spent must stick at error
  UPDATE sync.inbound_file_queue SET attempts = 3 WHERE id = v_qid;
  v_ok := public.fn_settle_inbound_file(v_qid, 'pending', NULL, 'probe failure');
  IF NOT v_ok THEN RAISE EXCEPTION 'settle reported no row updated'; END IF;
  PERFORM 1 FROM sync.inbound_file_queue WHERE id = v_qid AND status = 'error';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'an exhausted row stayed pending and would be retried forever';
  END IF;

  -- and an exhausted row must stop being offered
  SELECT count(*) INTO v_n FROM public.fn_claim_inbound_files(3) WHERE id = v_qid;
  IF v_n <> 0 THEN RAISE EXCEPTION 'an exhausted row was claimed again'; END IF;

  DELETE FROM sync.inbound_file_queue WHERE entity_id = 999999998;

  RAISE NOTICE 'VERIFY passed: claim is exclusive and spends budget, done needs a photo, exhausted sticks';
END
$verify$;

COMMIT;
