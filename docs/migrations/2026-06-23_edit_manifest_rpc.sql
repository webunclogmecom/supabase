-- ============================================================================
-- 2026-06-23_edit_manifest_rpc.sql
-- DERM Tracker — atomic edit_manifest() RPC (hardening of the live grouped edit)
-- ============================================================================
-- Spec: Building Apps/DERM Tracker/docs/edit-manifest-design.md (approved 2026-06-17).
--
-- The DERM Tracker manifest-Edit modal edits a filed manifest's SHARED fields
-- (#, dump date, county, facility, photo URLs) across ALL derm_manifests rows
-- that share the current (number, jurisdiction) — one physical dump ticket is
-- stored as one row per client (rule #10; 66 shared white-number groups exist).
-- The frontend does this today via a direct grouped anon UPDATE (atomic per
-- statement). This RPC makes the multi-step COUNTY FLIP (white<->yellow remap)
-- and the number-change dup pre-check bulletproof in ONE transaction.
--
-- Design decisions (verified against live schema 2026-06-23):
--   * jurisdiction is NOT a column — it's derived from which number column is
--     set. We map p_*_jurisdiction -> column: contains 'dade' (e.g. 'Miami-Dade'
--     or 'dade') => white_manifest_number; otherwise (Broward/Palm Beach) =>
--     yellow_ticket_number. Accepts BOTH the County-dropdown labels
--     ('Miami-Dade'/'Broward', as file_manifest uses) and the view's lowercase
--     jurisdiction codes ('dade'/'broward', as derm.manifests exposes).
--   * The modal's "Dump date" maps to derm_manifests.dump_ticket_date (per the
--     derm.manifests view: dump_date = dump_ticket_date). We update ONLY
--     dump_ticket_date and deliberately DO NOT touch service_date, to avoid
--     clobbering a distinct service date on AT-sourced manifests.
--   * Photo URLs are COALESCE'd — kept when the caller passes NULL.
--   * disposal_facility_id is set from the caller (frontend re-matches the
--     facility to the new county and passes the new id).
--   * County flip nulls the now-unused number column.
--   * (client_id, number) collision -> partial-unique-index 23505 -> re-raised
--     with SQLSTATE 23505 + a clean message (frontend already maps 23505 to
--     "already filed for {client}").
--   * Returns SETOF derm_manifests (the updated group rows, post-update values).
--
-- Audit: NO new table. Inherits audit via the existing audit_derm_manifests
--   AFTER UPDATE trigger (ADR 010) — every group row's change is logged, with
--   app_source resolved from the PostgREST request context (ADR 016), exactly
--   like the direct UPDATE path. No opt-in needed.
-- Security: SECURITY DEFINER (bypasses RLS like file_manifest) + anon EXECUTE.
--   Partial unique indexes + the audit trigger still apply inside the function.
-- Idempotent migration (CREATE OR REPLACE). Mirrors public.file_manifest().
-- ============================================================================

CREATE OR REPLACE FUNCTION public.edit_manifest(
  p_old_number text, p_old_jurisdiction text,         -- group key (current identity)
  p_new_number text, p_new_jurisdiction text,         -- new identity
  p_dump_date date, p_disposal_facility_id bigint,
  p_derm_manifest_url text DEFAULT NULL,
  p_derm_address_url  text DEFAULT NULL
) RETURNS SETOF public.derm_manifests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_old_dade boolean := position('dade' in lower(coalesce(p_old_jurisdiction, ''))) > 0;
  v_new_dade boolean := position('dade' in lower(coalesce(p_new_jurisdiction, ''))) > 0;
BEGIN
  IF coalesce(p_old_number, '') = '' OR coalesce(p_new_number, '') = '' THEN
    RAISE EXCEPTION 'edit_manifest: manifest number is required' USING ERRCODE = '22023';
  END IF;

  -- Update every live row in the OLD (number, jurisdiction) group, in one
  -- atomic statement. RETURNING reflects the post-update (new) values.
  RETURN QUERY
  UPDATE public.derm_manifests dm SET
    white_manifest_number = CASE WHEN v_new_dade THEN p_new_number ELSE NULL END,
    yellow_ticket_number  = CASE WHEN v_new_dade THEN NULL ELSE p_new_number END,
    dump_ticket_date      = p_dump_date,
    disposal_facility_id  = p_disposal_facility_id,
    derm_manifest_url     = COALESCE(p_derm_manifest_url, dm.derm_manifest_url),
    derm_address_url      = COALESCE(p_derm_address_url, dm.derm_address_url)
  WHERE dm.deleted_at IS NULL
    AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
       OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
  RETURNING dm.*;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'edit_manifest: no live manifest found for % #%', p_old_jurisdiction, p_old_number
      USING ERRCODE = 'P0002';
  END IF;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'edit_manifest: a manifest numbered % is already filed for one of these clients', p_new_number
      USING ERRCODE = '23505';
END;
$function$;

REVOKE ALL     ON FUNCTION public.edit_manifest(text,text,text,text,date,bigint,text,text) FROM public;
GRANT  EXECUTE ON FUNCTION public.edit_manifest(text,text,text,text,date,bigint,text,text) TO anon, authenticated, service_role;
