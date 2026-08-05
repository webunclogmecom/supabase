-- 2026-08-05_0535_derm_manual_lock_rpc_authoritative_fix.sql
--
-- DERM manual-lock remediation, step 1c: FIX A DEFECT IN THE TWO RPCs SHIPPED TONIGHT.
-- Replaces the bodies of both. Signatures, return shapes and grants are UNCHANGED, so
-- nothing app-side has to move.
--
--   public.set_visit_derm_required_manual (bigint, boolean)             2026-08-05_0457 / 6a20213
--   public.set_visits_derm_required_manual(bigint[], boolean, boolean)  2026-08-05_0508 / 2d06402
--
-- THE DEFECT
-- ----------
-- Both were authoritative ONLY when called from the DERM origin, which is precisely the
-- dependency they were built to remove. Measured as `authenticated` on real locked+false
-- visits 1240 / 1242, rolled back:
--
--   A  singular(true)  origin=calendar, locked+false -> value=FALSE locked=true  [wanted true]
--   B  bulk(true)      origin=calendar, locked+false -> value=FALSE locked=true  [wanted true]
--   C  singular(NULL)  origin=calendar, locked+false -> value=FALSE locked=false [HALF-APPLIED]
--   CONTROL  singular(true) origin=derm.unclogme.app -> value=TRUE  locked=true  [correct]
--
-- Root cause: the value statement still fires trg_derm_required_lock. On an ALREADY-LOCKED
-- row from a NON-derm origin the ELSIF leg reverts the write:
--
--     ELSIF OLD.derm_required_locked IS TRUE
--           AND NEW.derm_required IS DISTINCT FROM OLD.derm_required THEN
--       NEW.derm_required := OLD.derm_required;   -- the RPC's write, silently discarded
--
-- The original two-statement design fixed the LOCK half (statement 2 is not
-- `UPDATE OF derm_required`, so the trigger cannot touch it) and stopped there. The
-- verification for 0457 did cover "non-derm origin" but only from an UNLOCKED baseline, so
-- this path never ran. 164 rows are locked in Prod right now, so the untested baseline is
-- the COMMON one. Case C is the worst shape: it half-applies, leaving value and lock
-- inconsistent with the request.
--
-- 🛑 GENERAL LESSON, WORTH MORE THAN THE FIX: a guard whose predicate is `OLD.<col> IS TRUE`
-- must be tested from BOTH baselines. Testing only the unlocked one exercises the branch
-- that cannot fire. Same shape as the "0 rows is an untested instrument, not an all-clear"
-- rule in CLAUDE.md.
--
-- THE FIX - THREE STATEMENTS, ORDER IS LOAD-BEARING, NO TRIGGER CHANGE
-- -------------------------------------------------------------------
--   1. clear the lock   (not UPDATE OF derm_required -> trigger does NOT fire)
--   2. write the value  (trigger fires, but its ELSIF cannot revert: OLD lock is now false)
--   3. set the lock     (not UPDATE OF derm_required -> trigger does NOT fire; final authority)
--
-- Correct under BOTH origins:
--   * non-derm: step 2's ELSIF guard `OLD.derm_required_locked IS TRUE` is now FALSE, so the
--     value lands. Step 3 sets the intended lock.
--   * derm: step 2's arm branch sets locked := true. Step 3 overwrites it with the intended
--     value, so NULL still releases the lock.
--
-- ACCEPTED COST: a previously-locked row now gains an unlock/relock pair in audit.logs.
-- Kept deliberately rather than suppressed - the standing complaint about this mechanism is
-- that it is unobservable, so extra truthful rows are the right trade. Step 1 is scoped with
-- `AND derm_required_locked IS TRUE` so already-unlocked rows generate no extra row at all.
--
-- STILL TRUE, UNCHANGED FROM THE TWO PRIOR MIGRATIONS
-- ---------------------------------------------------
--   * p_value true/false sets and locks; p_value NULL clears the value AND releases the lock.
--   * bulk is all-or-nothing: any unknown/soft-deleted id raises 22023 and nothing applies.
--   * one row returned per visit so the caller can assert count(returned) = count(sent).
--   * p_unlink refused while marking DERM required; audited, reversible, no Stamp-card orphan.
--   * SECDEF + pinned search_path; EXECUTE to `authenticated` only.
--   * These RPCs do NOT narrow WHO can lock - the same staff population could always set the
--     header. They make the intent explicit, named and revocable instead of a side effect.
--
-- AUDIT (rule 8): no new table, no trigger change. public.visits and public.manifest_visits
-- keep their existing audit.log_change triggers; every write here is captured.
--
-- ROLLBACK: re-apply 2026-08-05_0457 and 2026-08-05_0508 to restore the prior bodies.

-- ============================================================ singular
CREATE OR REPLACE FUNCTION public.set_visit_derm_required_manual(
  p_visit_id bigint,
  p_value    boolean
)
RETURNS TABLE (
  visit_id             bigint,
  derm_required        boolean,
  derm_required_locked boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
  v_alive boolean;
BEGIN
  SELECT true INTO v_alive
    FROM public.visits v
   WHERE v.id = p_visit_id AND v.deleted_at IS NULL;

  IF v_alive IS NOT TRUE THEN
    RAISE EXCEPTION 'visit % not found or soft-deleted', p_visit_id
      USING ERRCODE = '22023';
  END IF;

  -- 🛑 THREE STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE OR REORDER. See header.
  UPDATE public.visits SET derm_required_locked = false
   WHERE id = p_visit_id AND derm_required_locked IS TRUE;

  UPDATE public.visits SET derm_required = p_value
   WHERE id = p_visit_id;

  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL)
   WHERE id = p_visit_id;

  RETURN QUERY
  SELECT v.id, v.derm_required, v.derm_required_locked
    FROM public.visits v
   WHERE v.id = p_visit_id;
END
$fn$;

REVOKE ALL ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean)
  TO authenticated;

-- ============================================================ bulk
CREATE OR REPLACE FUNCTION public.set_visits_derm_required_manual(
  p_visit_ids bigint[],
  p_value     boolean,
  p_unlink    boolean DEFAULT false
)
RETURNS TABLE (
  visit_id             bigint,
  derm_required        boolean,
  derm_required_locked boolean,
  unlinked             integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
#variable_conflict use_column
DECLARE
  v_ids      bigint[];
  v_sent     integer;
  v_alive    integer;
  v_unlinked jsonb := '{}'::jsonb;
BEGIN
  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no visit ids supplied' USING ERRCODE = '22023';
  END IF;

  IF array_position(p_visit_ids, NULL::bigint) IS NOT NULL THEN
    RAISE EXCEPTION 'visit id array contains NULL' USING ERRCODE = '22023';
  END IF;

  IF array_length(p_visit_ids, 1) > 1000 THEN
    RAISE EXCEPTION 'too many visits in one call (% supplied, limit 1000)',
      array_length(p_visit_ids, 1) USING ERRCODE = '22023';
  END IF;

  IF p_unlink AND p_value IS TRUE THEN
    RAISE EXCEPTION 'refusing to unlink DERM manifests while marking DERM required'
      USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_visit_ids) AS x;
  v_sent := array_length(v_ids, 1);

  SELECT count(*) INTO v_alive
    FROM public.visits v
   WHERE v.id = ANY(v_ids) AND v.deleted_at IS NULL;

  IF v_alive <> v_sent THEN
    RAISE EXCEPTION 'one or more visits not found or soft-deleted (% of % alive) - nothing was changed',
      v_alive, v_sent USING ERRCODE = '22023';
  END IF;

  -- 🛑 THREE STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE OR REORDER. See header.
  UPDATE public.visits SET derm_required_locked = false
   WHERE id = ANY(v_ids) AND derm_required_locked IS TRUE;

  UPDATE public.visits SET derm_required = p_value
   WHERE id = ANY(v_ids);

  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL)
   WHERE id = ANY(v_ids);

  IF p_unlink THEN
    WITH d AS (
      DELETE FROM public.manifest_visits mv
       WHERE mv.visit_id = ANY(v_ids)
      RETURNING mv.visit_id
    )
    SELECT coalesce(jsonb_object_agg(s.visit_id::text, s.n), '{}'::jsonb)
      INTO v_unlinked
      FROM (SELECT d.visit_id, count(*) AS n FROM d GROUP BY d.visit_id) s;
  END IF;

  RETURN QUERY
  SELECT v.id,
         v.derm_required,
         v.derm_required_locked,
         coalesce((v_unlinked ->> v.id::text)::integer, 0)
    FROM public.visits v
   WHERE v.id = ANY(v_ids)
   ORDER BY v.id;
END
$fn$;

REVOKE ALL ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.set_visit_derm_required_manual(bigint, boolean) IS
  'Manual set of visits.derm_required + derm_required_locked. NULL clears the value and releases '
  'the lock. Authoritative regardless of request origin. The THREE UPDATE statements must stay '
  'separate and in order - see 2026-08-05_0535_derm_manual_lock_rpc_authoritative_fix.sql.';

COMMENT ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean) IS
  'Bulk manual set of visits.derm_required + derm_required_locked, one transaction, all-or-nothing. '
  'NULL clears the value and releases the lock. Optional p_unlink also deletes the visits'' '
  'manifest_visits links (refused while marking required). Returns one row per visit so the caller '
  'can assert count(returned) = count(sent). Authoritative regardless of request origin. The THREE '
  'UPDATE statements must stay separate and in order - see '
  '2026-08-05_0535_derm_manual_lock_rpc_authoritative_fix.sql.';
