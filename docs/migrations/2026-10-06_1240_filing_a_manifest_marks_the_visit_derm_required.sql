-- ============================================================================
-- 2026-10-06 · Filing a manifest on a "DERM not required" visit turns the visit DERM required
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-06, after manifest 111112 (112-YA, visit 8742) did not show in the Field Portal:
--   "we need to make it so if we file a manifest, it should also be shown at the FP App, even if it's DERM not
--   required, or actually even better, if we file a Manifest to a visit that is DERM Not required, turn it to
--   DERM required."
--
-- WHY IT WAS HIDDEN
--   customer.work_orders (the Field Portal) lists a completed visit only while COALESCE(derm_required, true) is
--   true (or it is grey water pumping). That filter is by design (Fred, 2026-08-05) and is NOT widened here.
--   Visit 8742 had been set "DERM not required" (locked) in the DERM Tracker at 11:58 ET; 111112 was linked to it
--   at 12:17. (111112 was then soft-deleted from the DERM Tracker at 12:18:54, so it stays hidden either way.)
--
-- WHAT CHANGES
--   NEW public.fn_manifest_link_marks_derm_required() + trigger trg_zy_link_marks_derm_required, AFTER INSERT OR
--   UPDATE OF manifest_id, visit_id on public.manifest_visits. When the linked visit is live and derm_required IS
--   FALSE and the manifest is not soft-deleted, it calls public.set_visit_derm_required_manual(visit, true): the
--   visit becomes TRUE and LOCKED, exactly what a person pressing "DERM required" in the DERM Tracker produces.
--   - Every writer of manifest_visits is covered (DERM Tracker, Stamp Studio, RPCs, scripts), on purpose: a rule
--     inside one app is not a rule.
--   - Through the manual RPC because fn_lock_manual_derm_required reverts a change to a LOCKED value from any
--     non-DERM origin; the RPC's unlock / set / lock sequence is the sanctioned way past it.
--   - NULL is left alone (it already shows: COALESCE), TRUE is left alone (0 writes, asserted in the probe).
--   - Name sorts after audit_manifest_visits and before trg_zz_card_from_link; the card does not read
--     derm_required (derm._materialize_card read 2026-10-06), so the order only keeps the audit row first.
--   - SECURITY DEFINER (owner postgres): it must reach set_visit_derm_required_manual, which only authenticated
--     and postgres may execute, whatever role inserted the link. It writes one column of the one visit the
--     caller was already allowed to link. EXECUTE revoked from everyone (a trigger function needs none).
--
-- NOT CHANGED
--   - No backfill. 21 older visits (2026-01-04 .. 2026-06-18, before the 2026-07-07 link guards) carry a manifest
--     link while derm_required = false; most derive FALSE and several sit on another client's ticket. Turning
--     them TRUE would put them in their client's Field Portal and in the city email candidates, so that is
--     Fred's call, listed in the report, not done here. 8742 is not touched either: its manifest is deleted.
--   - customer.work_orders, the lock trigger, the manual RPCs, the link guards.
--   - Restoring a soft-deleted manifest does not re-fire this (no link row is inserted). Not needed today.
--
-- PROVEN BEFORE APPLY (rolled-back probe on visit 8113 / manifest 2017 = 111111, the live 112-YA test pair):
--   A false+locked, no header        -> true, locked, Field Portal row + manifest visible
--   B false+unlocked                 -> true, locked, visible
--   C true+unlocked                  -> unchanged, 0 visit writes
--   D NULL                           -> unchanged (already visible)
--   E false+locked, DERM Tracker hdr -> true, locked, visible
--   F false+locked, as authenticated from admin.unclogme.app -> true, locked, visible
--   G link to soft-deleted 2018 on 8742 -> unchanged
--   CONTROL: A without the trigger   -> stays false, not visible
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no new table. The visits UPDATEs are audited by audit_visits (app_source
-- of the linking request) and logged by trg_aa_derm_required_shadow when the old value was locked.
-- ROLLBACK: DROP TRIGGER trg_zy_link_marks_derm_required ON public.manifest_visits;
--           DROP FUNCTION public.fn_manifest_link_marks_derm_required();
-- ============================================================================

BEGIN;

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.set_visit_derm_required_manual(bigint,boolean)'::regprocedure)) <> '961661513c10d2daa4a9db5f52a9a327' THEN
    RAISE EXCEPTION 'set_visit_derm_required_manual changed since this migration was built; re-probe'; END IF;
  IF md5(pg_get_functiondef('public.fn_lock_manual_derm_required()'::regprocedure)) <> 'b8b50b65be89acaee77e1b799e140f48' THEN
    RAISE EXCEPTION 'fn_lock_manual_derm_required changed since this migration was built; re-probe'; END IF;
  IF to_regprocedure('public.fn_manifest_link_marks_derm_required()') IS NOT NULL THEN
    RAISE EXCEPTION 'fn_manifest_link_marks_derm_required already exists'; END IF;
END
$pre$;

CREATE TEMP TABLE _false_linked_before ON COMMIT DROP AS
  SELECT DISTINCT v.id FROM public.visits v JOIN public.manifest_visits mv ON mv.visit_id = v.id
   WHERE v.deleted_at IS NULL AND v.derm_required IS FALSE;

CREATE FUNCTION public.fn_manifest_link_marks_derm_required()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- 2026-10-06 (Fred): "if we file a Manifest to a visit that is DERM Not required, turn it to DERM required."
  -- A manifest on file is proof DERM work happened, and the Field Portal shows a visit only while it is DERM
  -- required (customer.work_orders), so a filed manifest on a "not required" visit was invisible to the client.
  -- Only FALSE moves: NULL already shows (COALESCE(derm_required, true)) and TRUE has nothing to do. A link to a
  -- soft-deleted manifest moves nothing (the Field Portal does not show a deleted manifest either).
  -- Goes through the manual RPC so the lock trigger is honoured from every origin, and the result is LOCKED
  -- true, like a person pressing "DERM required": the filing is a person's decision.
  -- Undo is the DERM Tracker's "Mark DERM Not Required", which also offers to unlink the manifest.
  IF EXISTS (SELECT 1 FROM public.visits v
              WHERE v.id = NEW.visit_id AND v.deleted_at IS NULL AND v.derm_required IS FALSE)
     AND EXISTS (SELECT 1 FROM public.derm_manifests dm
              WHERE dm.id = NEW.manifest_id AND dm.deleted_at IS NULL) THEN
    PERFORM public.set_visit_derm_required_manual(NEW.visit_id, true);
  END IF;
  RETURN NULL;
END
$function$;
REVOKE ALL ON FUNCTION public.fn_manifest_link_marks_derm_required() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.fn_manifest_link_marks_derm_required() IS
  'AFTER INSERT/UPDATE trigger on public.manifest_visits: a manifest linked to a live visit whose derm_required is FALSE turns it TRUE and locked (via set_visit_derm_required_manual). NULL, TRUE and soft-deleted manifests are left alone. Fred, 2026-10-06.';
CREATE TRIGGER trg_zy_link_marks_derm_required
  AFTER INSERT OR UPDATE OF manifest_id, visit_id ON public.manifest_visits
  FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_link_marks_derm_required();

-- ---------- VERIFY
DO $v$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_zy_link_marks_derm_required'
                  AND tgrelid = 'public.manifest_visits'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'VERIFY: trigger missing or disabled'; END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.fn_manifest_link_marks_derm_required()'::regprocedure) THEN
    RAISE EXCEPTION 'VERIFY: function is not SECURITY DEFINER'; END IF;
  IF has_function_privilege('anon', 'public.fn_manifest_link_marks_derm_required()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_manifest_link_marks_derm_required()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: EXECUTE still granted'; END IF;
  -- no backfill: the same visits are still false + linked
  SELECT count(*) INTO n FROM (
    (SELECT id FROM _false_linked_before EXCEPT
     SELECT DISTINCT v.id FROM public.visits v JOIN public.manifest_visits mv ON mv.visit_id = v.id
      WHERE v.deleted_at IS NULL AND v.derm_required IS FALSE)
    UNION ALL
    (SELECT DISTINCT v.id FROM public.visits v JOIN public.manifest_visits mv ON mv.visit_id = v.id
      WHERE v.deleted_at IS NULL AND v.derm_required IS FALSE EXCEPT SELECT id FROM _false_linked_before)) d;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % visits changed state; this file must not backfill', n; END IF;
  RAISE NOTICE 'VERIFY ok: trigger live, % false+linked visits untouched', (SELECT count(*) FROM _false_linked_before);
END
$v$;

COMMIT;
