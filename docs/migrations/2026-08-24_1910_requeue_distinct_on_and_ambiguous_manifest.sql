-- 2026-08-24_1910_requeue_distinct_on_and_ambiguous_manifest.sql
-- ---------------------------------------------------------------------------
-- Two holes in fn_requeue_derm_portal, found by attacking my own function twenty
-- minutes after shipping it (2026-08-24_1900). Neither can bite today; both are
-- unguarded, and "it happens to be clean right now" is not an invariant.
--
-- HOLE 1 — still_blocked_by CAN LIE, and lying is the one thing this function must
-- never do, because its whole reason for returning a post-condition is that a silent
-- no-op makes an operator believe they acted.
--   v_derm_portal_queue is DISTINCT ON (manifest_id), so only ONE permit per manifest
--   is served per pass (ordered gdo_id, then abs(visit_date - dump_ticket_date), then
--   visit_id). A (visit, permit) can therefore be absent from the queue with NO gate
--   blocking it at all — a sibling simply won this pass. The old CASE had no branch for
--   that and fell through to "not gate 1/2/3/4 — the row may be before
--   rpa_launch_cutoff()...", which is wrong and sends the reader hunting the wrong thing.
--   MEASURED 2026-08-24: exactly one manifest has more than one candidate permit —
--   1692 (043-MIL), gdo 156 and 230 — and it is the very row this feature was built for.
--   It does not misreport today only because 156 is held by gate 1, so 230 wins cleanly.
--
-- HOLE 2 — the manifest lookup was `... WHERE mv.visit_id = p_visit_id LIMIT 1` with NO
--   ORDER BY. If a visit ever carries two live manifest links, that picks an ARBITRARY
--   one and the requeue lands on a manifest nobody chose, silently.
--   MEASURED 2026-08-24: 0 visits have more than one live manifest link. That is a
--   property of today's data, not a constraint, so it is now loud instead of arbitrary:
--   the function RAISES and tells the operator to disambiguate rather than guessing.
--
-- Both fixes are to the function only. The view, the table, and gate 3 are untouched.
--
-- Audit (Rule 8): one function body. No table, column or grant changes.
--
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
  v_blocked     boolean;
  v_queued      boolean;
  v_why         text;
BEGIN
  IF coalesce(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: a reason is required - the next person to read this row has to know why somebody overrode the gate'
      USING ERRCODE = '22023';
  END IF;

  -- HOLE 2: be deterministic, and be LOUD when the answer is ambiguous rather than
  -- picking one at random.
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

  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
       AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
       AND NOT s.retryable AND s.status <> 'SUCCESS')
  INTO v_blocked;

  INSERT INTO public.derm_portal_requeue (manifest_id, gdo_id, reason, requested_by)
  VALUES (v_manifest_id, p_gdo_id, btrim(p_reason),
          coalesce(p_by, current_setting('request.jwt.claims', true)::jsonb->>'email', session_user));

  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq
                  WHERE qq.visit_id = p_visit_id
                    AND NOT qq.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_queued;

  IF NOT v_queued THEN
    SELECT CASE
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
      -- HOLE 1: no gate is holding it; a SIBLING permit won the DISTINCT ON. Say so,
      -- because this is not a problem and the operator should not go looking for one.
      WHEN EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq2
                    WHERE qq2.manifest_id = v_manifest_id)
        THEN 'no gate is blocking it: the queue serves ONE permit per manifest per pass and a sibling permit won this one. It will come up on a later pass, and the requeue is recorded.'
      ELSE 'not gate 1/2/3/4 and no sibling is queued - the row may be before rpa_launch_cutoff(), or this (visit, gdo) pair does not appear in v_derm_portal_fields at all'
    END INTO v_why;
  END IF;

  RETURN jsonb_build_object(
    'manifest_id', v_manifest_id,
    'visit_id', p_visit_id,
    'gdo_id', p_gdo_id,
    'was_blocked_by_gate3', v_blocked,
    'queued_now', v_queued,
    'still_blocked_by', v_why);
END $fn$;

COMMENT ON FUNCTION public.fn_requeue_derm_portal(bigint,bigint,text,text) IS
  'Explicitly re-open the DERM portal queue for one (visit, permit) after a fix made OUTSIDE this database - a county portal credential, a permit registration. Relaxes ONLY gate 3; gates 1, 2 and 4 still apply and the return value names whichever is still holding the row - including the case where NO gate is blocking it and a sibling permit simply won the DISTINCT ON (manifest_id). RAISES rather than guessing if a visit carries more than one live manifest link. Self-limiting: a fresh failure closes the gate again. Requires a reason.';

COMMIT;

-- VERIFY (run after applying)
--
-- 1. the queue STILL has not widened — the function changed, the view did not
--    select count(*) from public.v_derm_portal_queue;   -- expect 1
--
-- 2. gate 1 is still correctly reported (unchanged behaviour)
--    select public.fn_requeue_derm_portal(6617, 156, 'regression check');
--    -- expect queued_now=false, still_blocked_by naming gate 1
--
-- 3. POSITIVE CONTROL for the new DISTINCT-ON branch. It needs a manifest with two
--    candidate permits where the queried one is NOT gate-blocked. Today only manifest
--    1692 has two, and gdo 156 is held by gate 1, so the branch is unreachable on live
--    data and CANNOT be proven from production alone. That is a real limitation of this
--    verification, stated rather than papered over:
--    select manifest_id, count(*) from public.v_derm_portal_fields
--     where visit_date >= rpa_launch_cutoff() group by 1 having count(*) > 1;
--    -- 2026-08-24: exactly one row, manifest 1692 (gdo 156, 230)
--    ⚠ Re-check this branch the first time a manifest carries two UNFILED permits.
--
-- 4. MUTATION TEST the ambiguity guard. It cannot be exercised on live data either
--    (0 visits have >1 live manifest), so assert the guard EXISTS in the body rather
--    than claiming it was proven:
--    select pg_get_functiondef('public.fn_requeue_derm_portal(bigint,bigint,text,text)'::regprocedure)
--           ~ 'is linked to % live manifests' as guard_present;   -- expect true
