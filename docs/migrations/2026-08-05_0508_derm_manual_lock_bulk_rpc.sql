-- 2026-08-05_0508_derm_manual_lock_bulk_rpc.sql
--
-- DERM manual-lock remediation, step 1b (EXPAND ONLY - additive, nothing calls it yet).
--
-- WHY THIS EXISTS
-- ---------------
-- 2026-08-05_0457 shipped the SINGLE-visit RPC set_visit_derm_required_manual().
-- @Supabase then walked the live DERM Tracker bundle to closure (18 chunks) and found a
-- SECOND write path we had both missed - a BULK one, and it is the busy one:
--
--     visits LIST   "Mark DERM Required / Not Required"
--         sb.from("visits").update({derm_required:v}).in("id", ids)
--         + when unlinking: sb.from("manifest_visits").delete().in("visit_id", ids)
--
-- Grouping the 265 historical derm_required writes by txid:
--     batch 1 (single)  60 txns /  60 visits
--     batch 2-5          5 txns /  19 visits
--     batch 6-20         4 txns /  48 visits
--     batch 21+          1 txn  / 138 visits
--   => 205 of 265 visits (77%) were written in BULK. Largest single txn: 138 visits.
--   => most recent bulk txns 2026-06-29/30, so this is live behaviour, not a leftover.
--
-- 🛑 A PER-VISIT LOOP OVER THE SINGULAR RPC WOULD BE A REGRESSION, NOT A FIX.
-- Today the bulk mark is ONE transaction: all 138 rows move or none do. A loop makes it
-- 138 transactions, so a mid-way failure leaves a HALF-MARKED COMPLIANCE SET with no
-- record of where it stopped. That is strictly worse than the silent-revert bug being
-- fixed. Hence this array sibling. The singular RPC stays exactly as shipped and the
-- detail-page toggle keeps using it unchanged.
--
-- SEMANTICS - IDENTICAL TO THE SINGULAR SIBLING
-- ---------------------------------------------
--   p_value = true/false  -> set the value AND lock it (human decision, protected)
--   p_value = NULL        -> clear the value AND release the lock (back to auto-derive)
--
-- 🛑 TWO STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE THEM.
-- fn_lock_manual_derm_required is a BEFORE UPDATE OF derm_required trigger, so it fires
-- only when derm_required is named in the SET list, and it runs AFTER the SET list is
-- applied. A single statement setting both columns is therefore silently overwritten by
-- the trigger - measured: (derm_required=NULL, locked=false) in one statement lands as
-- locked=TRUE. Setting the value first and the lock second leaves the second statement
-- untouchable. This is why the trigger needs no change during the migration window.
--
-- ALL-OR-NOTHING
-- --------------
-- Any unknown or soft-deleted id raises 22023 and the WHOLE call fails - nothing half
-- applies. One row is returned per visit so the caller can assert
-- count(returned) = count(sent), which is precisely the assurance today's silent revert
-- denies it.
--
-- p_unlink: WHY THE DELETE IS INSIDE THE FUNCTION (measured, not assumed)
-- ----------------------------------------------------------------------
-- The bulk path also deletes manifest_visits rows when marking not-required-with-unlink.
-- Today that is a SECOND, SEPARATE app statement, so it is already non-atomic with the
-- value write. Folding it in makes value + lock + unlink one transaction.
--
-- The objection to check was privilege laundering: a SECURITY DEFINER function owned by
-- postgres (rolbypassrls = true) bypasses RLS, so it could grant reach the caller does
-- not have. That is the exact bug class this whole remediation removes, so it was
-- measured rather than reasoned about, and it does NOT apply here:
--
--   * authenticated already holds DELETE on public.manifest_visits (table grant), AND
--   * already has an unrestricted DELETE policy on it - anon_delete_manifest_visits_authn,
--     polcmd 'd', USING (true), roles {authenticated}.
--     ⚠ Note the name: the manifest_visits policies are all named anon_* but every one
--     targets {authenticated}. A policy-NAME sweep answering "what can anon do" is
--     wrong here. Read polroles, not the name.
--   * every DELETE is audited WITH old_row - 151 of 151 historical deletes are
--     recoverable from audit.logs.old_row - so this stays reversible.
--   * unlinking does NOT strand a DERM Stamp card: derm.address_row_map has no visit_id
--     at all (cards key on white_manifest_number / matched_client_id / matched_manifest_id)
--     and fn_card_from_link materialises from NEW.manifest_id. No hidden coupling.
--
-- Equivalent check for the UPDATE half, probed as authenticated with the derm origin set:
--     direct UPDATE, scheduled visit      -> 1 row       RPC -> same
--     direct UPDATE, soft-deleted visit   -> 0 rows      RPC -> refused 22023
-- The permissive UPDATE policies on visits OR together, and visits_app_update_authn
-- (deleted_at IS NULL) already swallows visits_authenticated_update_derm_required
-- (visit_status = 'completed'), so that policy is dead as a restriction. The RPC's reach
-- therefore EQUALS the app's existing reach, and is stricter on soft-deleted rows: it
-- raises where a direct write silently affects nothing.
--
-- GUARD: unlink is refused while marking DERM REQUIRED. Deleting the manifest links that
-- evidence a DERM obligation while simultaneously asserting that obligation exists is
-- incoherent; the app only ever unlinks when marking not-required.
--
-- AUDIT (rule 8): no new table. public.visits and public.manifest_visits both already
-- carry audit.log_change triggers, so every write here is captured unchanged.
--
-- ROLLBACK: DROP FUNCTION public.set_visits_derm_required_manual(bigint[],boolean,boolean);
-- Nothing depends on it until the app is switched over in step 2.

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
    RAISE EXCEPTION 'no visit ids supplied'
      USING ERRCODE = '22023';
  END IF;

  IF array_position(p_visit_ids, NULL::bigint) IS NOT NULL THEN
    RAISE EXCEPTION 'visit id array contains NULL'
      USING ERRCODE = '22023';
  END IF;

  -- Sanity bound. The largest real batch ever observed is 138; 1000 is ~7x headroom and
  -- stops a runaway "select all" from marking a compliance column across the table.
  IF array_length(p_visit_ids, 1) > 1000 THEN
    RAISE EXCEPTION 'too many visits in one call (% supplied, limit 1000)',
      array_length(p_visit_ids, 1)
      USING ERRCODE = '22023';
  END IF;

  IF p_unlink AND p_value IS TRUE THEN
    RAISE EXCEPTION 'refusing to unlink DERM manifests while marking DERM required'
      USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_visit_ids) AS x;
  v_sent := array_length(v_ids, 1);

  SELECT count(*) INTO v_alive
    FROM public.visits v
   WHERE v.id = ANY(v_ids)
     AND v.deleted_at IS NULL;

  IF v_alive <> v_sent THEN
    RAISE EXCEPTION 'one or more visits not found or soft-deleted (% of % alive) - nothing was changed',
      v_alive, v_sent
      USING ERRCODE = '22023';
  END IF;

  -- 🛑 TWO STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE. See header.
  UPDATE public.visits SET derm_required        = p_value              WHERE id = ANY(v_ids);
  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL) WHERE id = ANY(v_ids);

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

-- Supabase's ALTER DEFAULT PRIVILEGES hands new public functions to anon/service_role
-- without anyone writing it. Revoke explicitly, then grant only what is needed.
REVOKE ALL ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.set_visits_derm_required_manual(bigint[], boolean, boolean) IS
  'Bulk manual set of visits.derm_required + derm_required_locked, one transaction, all-or-nothing. '
  'NULL clears the value and releases the lock. Optional p_unlink also deletes the visits'' '
  'manifest_visits links (refused while marking required). Returns one row per visit so the caller '
  'can assert count(returned) = count(sent). The two UPDATE statements must stay separate and in '
  'order - see 2026-08-05_0508_derm_manual_lock_bulk_rpc.sql.';
