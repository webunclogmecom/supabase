-- 2026-08-24_1930_requeue_honesty_fixes.sql
-- ---------------------------------------------------------------------------
-- Five fixes to fn_requeue_derm_portal, all found by an adversarial pass run against
-- the shipped function. TWO ARE MY OWN REGRESSIONS FROM _1910, WHICH I SHIPPED
-- TWENTY MINUTES EARLIER. Recorded plainly, because the whole point of this function
-- is that it must not lie to its caller, and it was lying in three different ways.
--
-- 🛑 (1) HIGH, AND IT IS A REGRESSION I INTRODUCED IN _1910. The "a sibling permit won
--   the DISTINCT ON" branch never checked that the (visit, gdo) pair EXISTS. It asked
--   only whether the MANIFEST was in the queue. So a nonsense gdo_id, a gdo belonging
--   to a DIFFERENT CLIENT, and NULL all returned the most reassuring message in the
--   set -- "no gate is blocking it ... it will come up on a later pass" -- for pairs
--   that will never come up on any pass.
--   Measured: p_gdo_id=999999999, p_gdo_id=NULL, and p_gdo_id=63 (client 369, while
--   visit 6617 is client 298) ALL hit the sibling branch, all with
--   pair_exists_in_fields=false. Positive control: p_gdo_id=230 -> queued_now=true,
--   pair_exists_in_fields=true, so the probe can tell a real pair from a fake one.
--   ⚠ The PRE-_1910 body was CORRECT here: it fell through to the ELSE, which said the
--   pair "does not appear in v_derm_portal_fields". My new branch was evaluated first
--   and swallowed the honest answer. **A branch added in front of a correct fallback
--   has to be at least as specific as the fallback it shadows.**
--
-- 🛑 (2) HIGH. p_gdo_id => NULL silently turns a PER-PERMIT override into a
--   MANIFEST-WIDE one, and reports it with that same benign message. The view's gate-3
--   anchor matches `rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id`, so a
--   requeue row with a NULL gdo_id supplies the anchor to EVERY permit on the manifest.
--   Meanwhile the function's own checks collapse to `s.gdo_id IS NULL`, match nothing,
--   and fall into the sibling branch -- so the operator re-opens the non-retryable gate
--   on a regulator-facing ticket and is told nothing is wrong.
--   Measured: a NULL requeue anchored BOTH gdo 156 and gdo 230 on manifest 1692;
--   a targeted requeue on 230 anchored only 230 (control). 14 manifests carry 2+ permits.
--   FIX: the RPC now REFUSES a NULL permit. The TABLE keeps NULL support, because a
--   deliberate manifest-wide re-open is a legitimate thing to want -- it just must not
--   be reachable by omitting an argument.
--
-- (3) MEDIUM. was_blocked_by_gate3 answered a different question than the gate it is
--   named after: it omitted the decisive `created_at > GREATEST(f.updated_at, marker)`
--   clause, so it returned true whenever such a submission had EVER existed, including
--   when the gate was already open. An operator requeueing a second time was told their
--   override was needed when it was a no-op. Measured over all 59 candidate pairs:
--   1 over-report, 0 under-reports. Now mirrors the view's own predicate.
--   ⚠ An assertion must MIRROR the rule it tests; a paraphrase manufactures false positives.
--
-- (4) MEDIUM. Attribution was `coalesce(p_by, jwt->>'email', session_user)` -- the
--   UNTRUSTED PARAMETER FIRST. Any caller could write an arbitrary requested_by,
--   including somebody else's email, on a table that has no audit trigger and whose
--   whole purpose is telling the next reader who overrode the gate. Now the JWT wins
--   and p_by is only a fallback label for service-role callers that carry no claim.
--
-- (5) LOW. `btrim(p_reason)` strips ASCII SPACE ONLY, so a reason of a single TAB,
--   NEWLINE or NBSP defeated the "reason required" guard entirely. Measured:
--   tab_is_empty=false, nl_is_empty=false, nbsp_is_empty=false, space_is_empty=true
--   (that last one is the control proving btrim works, on spaces).
--   ⚠ Deliberately NOT adding a minimum length. A one-character reason like '.' is a
--   judgement call, not a hole, and a length rule only teaches people to type 'asdfgh'.
--
-- ---------------------------------------------------------------------------
-- NOT FIXED HERE, on purpose, and each recorded so it is a decision rather than an
-- oversight:
--
-- ⚠ ANY AUTHENTICATED USER CAN CALL THIS. SECURITY DEFINER with EXECUTE to
--   `authenticated`, reachable at POST /rest/v1/rpc/. Left as-is because it matches the
--   house pattern -- 47 public SECURITY DEFINER functions already carry authenticated
--   EXECUTE, including file_manifest and set_visit_status, which are at least as
--   consequential. Raising it here alone would be inconsistent, not safer. **It is a
--   design question for Fred, not a slip.** anon cannot reach it, and `authenticated`
--   has no direct INSERT on the table, so the SECURITY DEFINER is load-bearing.
--
-- ⚠ COALESCE('-infinity') CHANGED THE NULL SEMANTICS OF GATE 3 AND I DID NOT INTEND IT.
--   When f.updated_at IS NULL and no requeue matches: the ORIGINAL `s.created_at >
--   f.updated_at` yields NULL, so the gate does NOT block; the shipped
--   `GREATEST(f.updated_at, COALESCE(..., '-infinity'))` yields '-infinity', so it DOES.
--   Kept, because the direction is fail-CLOSED -- it can only suppress a filing, never
--   cause an extra one -- and "we know nothing about this row's freshness" is a poor
--   reason to serve it to a county. 0 of 59 rows exhibit it today, but all three source
--   columns are nullable so it is schema-reachable. Stated because it was an accident
--   that happens to be an improvement, and the next reader should not think it was designed.
--
-- ⚠ queue_depth COUNTS MANIFESTS, NOT FILINGS. v_derm_portal_queue is
--   DISTINCT ON (manifest_id), so v_rpa_derm_health.queue_depth answers "how many
--   manifests can the bot pick up this pass", NOT "how many DERM filings are
--   outstanding". Measured: 59 candidate pairs across 37 manifests, and 13 manifests
--   currently carry 2+ unfiled permits -- so a backlog read off queue_depth is
--   understated by up to 37%. Any alert threshold on it saturates. Unchanged by
--   _1900/_1910 (identical column list); documented so nobody builds a backlog metric on it.
--
-- ⚠ A requeue naming a LOWER-sorting sibling gdo_id can change WHICH permit the manifest
--   serves, because gates are applied before the DISTINCT ON. Confirmed synthetically
--   (manifest 100: old serves 230, new serves 156); negative control confirms gate 1
--   still prevents the swap for an already-filed permit. Combined with gate 4 being
--   gdo-blind and manifest-wide for 20h, filing one sibling defers the other by up to
--   20h. Not reachable today (0 rows are gate-3-blocked). Inherent to DISTINCT ON, not
--   introduced here; the sibling branch now reports it honestly.
--
-- Audit (Rule 8): one function body. No table, column or grant changes.
-- @Building Apps. Claimed in WORKING-NOW.md.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_requeue_derm_portal(
  p_visit_id bigint,
  p_gdo_id   bigint,
  p_reason   text,
  p_by       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_manifest_id bigint;
  v_n_manifests int;
  v_pair_exists boolean;
  v_blocked     boolean;
  v_queued      boolean;
  v_why         text;
  v_reason      text;
  v_jwt_email   text;
BEGIN
  -- (5) strip the whole whitespace class, not just ASCII space. E' ' is NBSP.
  v_reason := btrim(coalesce(p_reason,''), E' \t\r\n ');
  IF v_reason = '' THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: a reason is required - the next person to read this row has to know why somebody overrode the gate'
      USING ERRCODE = '22023';
  END IF;

  -- (2) a NULL permit is a MANIFEST-WIDE override. Refuse it here: it must never be
  -- reachable by omitting an argument. The table still supports NULL for a deliberate
  -- manifest-wide re-open.
  IF p_gdo_id IS NULL THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: p_gdo_id is required. A NULL permit re-opens gate 3 for EVERY permit on the manifest, which is a manifest-wide override and must be asked for explicitly, not reached by leaving an argument out.'
      USING ERRCODE = '22023';
  END IF;

  SELECT count(DISTINCT mv.manifest_id) INTO v_n_manifests
    FROM public.manifest_visits mv
    JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
   WHERE mv.visit_id = p_visit_id;

  IF v_n_manifests = 0 THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: visit % has no live manifest link, so there is nothing for the portal queue to serve', p_visit_id
      USING ERRCODE = 'P0002';
  ELSIF v_n_manifests > 1 THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: visit % is linked to % live manifests, so which one to re-open is ambiguous. Requeue by manifest instead, or unlink the wrong one first.', p_visit_id, v_n_manifests
      USING ERRCODE = '21000';
  END IF;

  SELECT mv.manifest_id INTO v_manifest_id
    FROM public.manifest_visits mv
    JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
   WHERE mv.visit_id = p_visit_id
   ORDER BY mv.manifest_id
   LIMIT 1;

  -- (1) Does this (visit, permit) pair exist AT ALL? Without this the sibling branch
  -- below tells a caller with a nonsense or wrong-client gdo_id that a sibling won and
  -- their row will come up later. It never will.
  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_fields f
                  WHERE f.visit_id = p_visit_id
                    AND NOT f.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_pair_exists;

  -- (3) mirror the view's gate 3 EXACTLY, anchor clause included, or this answers a
  -- different question than the gate it is named after.
  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
       AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
       AND NOT s.retryable AND s.status <> 'SUCCESS'
       AND s.created_at > GREATEST(
             (SELECT f.updated_at FROM public.v_derm_portal_fields f
               WHERE f.visit_id = p_visit_id AND NOT f.gdo_id IS DISTINCT FROM p_gdo_id),
             COALESCE((SELECT max(rq.requeued_at) FROM public.derm_portal_requeue rq
                        WHERE rq.manifest_id = v_manifest_id
                          AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM p_gdo_id)),
                      '-infinity'::timestamptz)))
  INTO v_blocked;

  INSERT INTO public.derm_portal_requeue (manifest_id, gdo_id, reason, requested_by)
  VALUES (v_manifest_id, p_gdo_id, v_reason,
          -- (4) the JWT wins; p_by is only a label for service-role callers with no claim.
          coalesce(current_setting('request.jwt.claims', true)::jsonb->>'email', p_by, session_user));

  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq
                  WHERE qq.visit_id = p_visit_id
                    AND NOT qq.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_queued;

  IF NOT v_queued THEN
    SELECT CASE
      WHEN NOT v_pair_exists
        THEN 'this (visit, permit) pair does not appear in v_derm_portal_fields at all - check the gdo_id belongs to this visit''s client, and that the visit is on or after rpa_launch_cutoff(). The requeue row was still recorded.'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
        THEN 'gate 1: this permit has already filed successfully - nothing to retry'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND s.created_at > now() - interval '20 hours')
        THEN 'gate 2: a 20h cooldown is running after the last attempt - it will serve once that expires'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_leases l
                     JOIN public.manifest_visits lmv ON lmv.visit_id = l.visit_id
                    WHERE lmv.manifest_id = v_manifest_id AND l.leased_at > now() - interval '20 hours')
        THEN 'gate 4: the manifest is under a dispense lease - the bot already holds it'
      WHEN EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq2
                    WHERE qq2.manifest_id = v_manifest_id)
        THEN 'no gate is blocking it: the queue serves ONE permit per manifest per pass and a sibling permit won this one. It will come up on a later pass, and the requeue is recorded.'
      ELSE 'the pair exists and no gate 1/2/3/4 is blocking it, yet it is not served - re-read v_derm_portal_queue directly, this should not happen'
    END INTO v_why;
  END IF;

  RETURN jsonb_build_object(
    'manifest_id', v_manifest_id,
    'visit_id', p_visit_id,
    'gdo_id', p_gdo_id,
    'pair_exists', v_pair_exists,
    'was_blocked_by_gate3', v_blocked,
    'queued_now', v_queued,
    'still_blocked_by', v_why);
END $fn$;

COMMENT ON FUNCTION public.fn_requeue_derm_portal(bigint,bigint,text,text) IS
  'Explicitly re-open the DERM portal queue for ONE (visit, permit) after a fix made OUTSIDE this database. Relaxes ONLY gate 3; gates 1, 2 and 4 still apply and the return names whichever is still holding the row - including "the pair does not exist" and "a sibling won the DISTINCT ON". REFUSES a NULL p_gdo_id, because that would re-open gate 3 for every permit on the manifest and must be asked for explicitly. was_blocked_by_gate3 mirrors the view predicate exactly, anchor included. requested_by prefers the JWT over the caller-supplied label. Self-limiting: a fresh failure closes the gate again.';

COMMIT;

-- VERIFY (run after applying)
--
-- 1. the queue STILL has not widened
--    select count(*) from public.v_derm_portal_queue;   -- expect 1
--
-- 2. REGRESSION TEST for (1): a nonsense permit must NOT be told a sibling won
--    select public.fn_requeue_derm_portal(6617, 999999999, 'regression: nonsense gdo');
--    -- expect pair_exists=false and still_blocked_by starting "this (visit, permit) pair
--    --   does not appear", NOT the sibling message
--
-- 3. REGRESSION TEST for (1), harder: a REAL gdo belonging to a DIFFERENT client
--    select public.fn_requeue_derm_portal(6617, 63, 'regression: wrong-client gdo');
--    -- gdo 63 is client 369; visit 6617 is client 298
--    -- expect pair_exists=false and the same honest message
--
-- 4. (2) a NULL permit must RAISE
--    do $$ begin perform public.fn_requeue_derm_portal(6617, null, 'x');
--      raise exception 'FAILTEST'; exception when others then
--      if sqlerrm like 'FAILTEST%' then raise; end if; raise notice 'ok: %', sqlerrm; end $$;
--
-- 5. (3) was_blocked_by_gate3 must now agree with the VIEW, not over-report.
--    On 2026-08-24 the pair (6617,230) has gate 3 already open (a requeue cleared it),
--    so the honest answer is FALSE where the old body said true:
--    select public.fn_requeue_derm_portal(6617, 230, 'regression: gate3 mirror');
--    -- expect was_blocked_by_gate3 = false, queued_now = true
--
-- 6. (5) whitespace-only reasons must RAISE
--    do $$ begin perform public.fn_requeue_derm_portal(6617, 230, E'\t');
--      raise exception 'FAILTEST'; exception when others then
--      if sqlerrm like 'FAILTEST%' then raise; end if; raise notice 'ok: %', sqlerrm; end $$;
--
-- 7. (4) attribution prefers the JWT. Under a service-role call there is no email claim,
--    so it falls back to p_by; that is the intended degradation, not a bypass.
--    select requested_by from public.derm_portal_requeue order by id desc limit 1;
