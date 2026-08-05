-- DERM manual lock, STEP 1 of 3 (EXPAND): an explicit RPC to record a human DERM decision
--
-- Fred: "do an audit about the derm lock, and talk with the Supabase 1 session ... both go ahead to plan
-- on what to do there and execute it, later do another audit." Planned jointly by both Supabase sessions.
--
-- THE PROBLEM. public.fn_lock_manual_derm_required (trigger trg_derm_required_lock, BEFORE UPDATE OF
-- derm_required ON public.visits) infers a HUMAN DECISION from transport metadata:
--     x-app-source = 'derm-tracker'  OR  origin ILIKE '%derm.unclogme.app%'
-- and on a match does NEW.derm_required_locked := true.
--
-- Two things are wrong with that, both measured:
--   1. A HOSTNAME GATES REGULATORY DATA. derm_required is the per-visit "this visit does not need a DERM
--      manifest" opt-out, read by 25 live objects. If DERM Tracker ever changes domain without the header,
--      the lock silently stops being applied and later human decisions are unprotected.
--   2. IT LAUNDERS A PRIVILEGE THE GRANT WITHHOLDS. `authenticated` holds column UPDATE on
--      visits.derm_required but NOT on derm_required_locked. A BEFORE trigger's NEW assignment is not
--      checked against the caller's column grants, so the trigger hands back a capability the grant
--      deliberately withholds: staff may set the value, but may not declare it sticky.
--
-- ⚠ WHAT THIS MIGRATION DOES *NOT* CLAIM. It does not narrow WHO can lock: the same `authenticated`
-- population can call the RPC exactly as they could send the header. It narrows HOW: intent becomes an
-- explicit, named, revocable API call instead of a side effect of any derm-origin write. Do not read this
-- as "escalation fixed" and assume the caller set shrank. (@Supabase's framing, and it is the right one.)
--
-- 🛑 THE TWO-STATEMENT BODY IS NOT A STYLE CHOICE. The first draft of this RPC used ONE statement,
-- `SET derm_required = ..., derm_required_locked = ...`, and it is SILENTLY DEFEATED while the old trigger
-- is still armed: the trigger fires (derm_required is in the SET list), runs AFTER the SET list is applied,
-- and overwrites the lock. Proven independently by BOTH sessions on rolled-back probes, same result:
--     one statement, NULL + unlock      -> locked = TRUE     (the clear never happens)
--     two statements, value then lock   -> locked = false    (intent lands)
--     control, non-derm origin          -> locked = false    (the probe really did exercise the trigger)
-- BEFORE UPDATE **OF derm_required** fires only when that column is named, so statement 2 is untouchable.
-- Order is load-bearing: reversed, the value write re-locks the row.
--
-- NULL MEANS "I HAVE NO OPINION" AND CLEARS THE LOCK. This is the design point that makes the existing
-- defect structurally impossible rather than repaired once. 21 `false -> NULL` and 1 `true -> NULL` writes
-- from derm-tracker are exactly what minted the 10 visits currently pinned at derm_required = NULL with a
-- lock the nightly rederive can never clear (it carries AND derm_required_locked IS NOT TRUE). Freezing
-- "unknown" is not a human decision; it is the value the rederive exists to fill.
--
-- VERIFIED AFTER APPLYING, rolled back, called WITH the derm origin present and the trigger still armed:
--     (visit, true)  -> true,  locked  |  (visit, false) -> false, locked
--     (visit, NULL)  -> NULL,  UNLOCKED   <- the case the one-statement draft got wrong
--     non-derm origin -> identical (the RPC is the authority, not the host)
--     unknown/soft-deleted visit -> 22023
--     grants: anon=false, authenticated=true, service_role=false
-- Nothing committed: 164 locked / 10 locked-NULL before and after.
--
-- SEQUENCE (expand -> migrate -> contract). THIS IS STEP 1 AND IS PURELY ADDITIVE: nothing calls the RPC
-- yet, the trigger is untouched, and both paths work. There is no moment without a guard.
--   2. @Supabase ships DERM Tracker to call this RPC and asserts on the returned row. The old trigger
--      still locks direct writes throughout, so a half-landed app change degrades to today's behaviour.
--   3. ONLY after observing zero direct `PATCH /visits` derm_required writes from derm-tracker, remove
--      the trigger's LOCKING half (keeping its protective half).
-- ⚠ Step 3 must not be reordered, and we are deliberately NOT revoking authenticated's column UPDATE on
-- derm_required: visit-calendar (125 writes) and dump-schedule (91) legitimately touch it. After step 3 a
-- direct PATCH simply becomes a non-sticky write, which is the correct semantics.
--
-- STILL OPEN, deliberately not done here: the 10 NULL-locked visits (needs Fred's sign-off, because
-- unlocking them means 7 visits GAIN a DERM obligation), and making the trigger's silent revert
-- observable before any decision to make it raise.
--
-- ADR 010 rule 8: function only, no table or column change -> no audit-trigger decision.
-- REVERSIBLE: DROP FUNCTION public.set_visit_derm_required_manual(bigint, boolean). Nothing depends on it.

BEGIN;

CREATE OR REPLACE FUNCTION public.set_visit_derm_required_manual(
  p_visit_id bigint,
  p_value    boolean
)
RETURNS TABLE (visit_id bigint, derm_required boolean, derm_required_locked boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE v_alive boolean;
BEGIN
  SELECT true INTO v_alive
    FROM public.visits v WHERE v.id = p_visit_id AND v.deleted_at IS NULL;
  IF v_alive IS NOT TRUE THEN
    RAISE EXCEPTION 'visit % not found or soft-deleted', p_visit_id USING ERRCODE = '22023';
  END IF;

  -- 🛑 TWO STATEMENTS, AND THE ORDER IS LOAD-BEARING. DO NOT MERGE THEM.
  -- trg_derm_required_lock is BEFORE UPDATE **OF derm_required**, so it fires only when that column is
  -- named in the SET list, and it runs AFTER the SET list is applied. A single
  -- `SET derm_required = NULL, derm_required_locked = false` is therefore OVERWRITTEN by the trigger,
  -- which unconditionally does `NEW.derm_required_locked := true` for any derm-origin write.
  -- Measured independently by both sessions on a rolled-back probe against a real alive visit:
  --   one statement (NULL + unlock)  -> locked = TRUE   (the clear is silently defeated)
  --   two statements (value, then lock) -> locked = false (intent lands)
  --   control, non-derm origin        -> locked = false (the probe really did exercise the trigger)
  -- Reversed order re-locks the row, because the value write fires the trigger again.
  UPDATE public.visits SET derm_required = p_value WHERE id = p_visit_id;
  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL) WHERE id = p_visit_id;

  RETURN QUERY
    SELECT v.id, v.derm_required, v.derm_required_locked
      FROM public.visits v WHERE v.id = p_visit_id;
END
$fn$;

COMMENT ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean) IS
'Record a HUMAN decision about whether a visit needs a DERM manifest. p_value NOT NULL sets the value and
marks it sticky; p_value NULL means "I have no opinion" and CLEARS the lock so the nightly rederive owns it
again. Returns the stored row so the caller can assert on it. Replaces inferring human intent from the
request Origin/X-App-Source header. Fred + both Supabase sessions, 2026-08-04.';

-- Supabase ALTER DEFAULT PRIVILEGES auto-grants new public functions to anon AND service_role, so
-- REVOKE FROM PUBLIC alone is not enough (repo memory: reference_supabase_function_default_privileges).
-- Note this is hygiene, not a barrier for service_role: it already holds direct column UPDATE on both
-- columns and does not need the RPC.
REVOKE ALL     ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean) FROM PUBLIC, anon, service_role;
GRANT  EXECUTE ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean) TO authenticated;

COMMIT;
