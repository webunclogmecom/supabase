-- 2026-07-06_stamp_card_manifest_autoresolve.sql
-- Fred: DERM-app changes should reflect in the Stamp app. A Stamp card's
-- matched_manifest_id was resolved ONCE (at OCR/add time) by
-- (white_manifest_number, client_id). If a client had no manifest on the ticket
-- then (matched_manifest_id NULL) and one is filed LATER in DERM Tracker, the
-- card never picked it up -> the card can't show LINKED and DERM changes don't
-- reflect. (visit_linked is already live once the card HAS a manifest.)
--
-- Fix: an AFTER-trigger on public.derm_manifests that, when a manifest is
-- created (or un-deleted), resolves it onto any Stamp card for the same
-- (white_manifest_number, matched_client_id) whose matched_manifest_id is NULL.
-- Keeps the static column authoritative + fresh (so both the views and the write
-- RPCs stay correct). Additive; only fills NULLs, never overwrites a set value.
--
-- @Supabase (session 1): trigger added to your public.derm_manifests table
-- (AFTER INSERT/UPDATE) — it only UPDATEs derm.address_row_map (my lane), filling
-- NULL matched_manifest_id. Does not touch derm_manifests data.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_resolve_card_manifest()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NEW.white_manifest_number IS NOT NULL THEN
    UPDATE derm.address_row_map r
       SET matched_manifest_id = NEW.id
     WHERE r.white_manifest_number = NEW.white_manifest_number
       AND r.matched_client_id     = NEW.client_id
       AND r.matched_manifest_id IS NULL;
  END IF;
  RETURN NULL;  -- AFTER trigger
END $$;

DROP TRIGGER IF EXISTS trg_resolve_card_manifest ON public.derm_manifests;
CREATE TRIGGER trg_resolve_card_manifest
AFTER INSERT OR UPDATE OF deleted_at, white_manifest_number, client_id ON public.derm_manifests
FOR EACH ROW EXECUTE FUNCTION derm.fn_resolve_card_manifest();

-- One-time backfill: any existing NULL-manifest card whose client now has a
-- manifest on the ticket (currently 0, but keeps things consistent).
UPDATE derm.address_row_map r
   SET matched_manifest_id = dm.id
  FROM public.derm_manifests dm
 WHERE r.matched_manifest_id IS NULL
   AND r.matched_client_id IS NOT NULL
   AND dm.deleted_at IS NULL
   AND dm.white_manifest_number = r.white_manifest_number
   AND dm.client_id = r.matched_client_id;

COMMIT;
