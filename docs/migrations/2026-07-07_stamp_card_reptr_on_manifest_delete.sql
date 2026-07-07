-- 2026-07-07_stamp_card_reptr_on_manifest_delete.sql
-- Fred: #820072 / 043-MIL was added via "+ Add client", then re-filed in the DERM
-- App and linked there (visible in DERM), but never shows as a card in Stamp even
-- after refresh. Root cause: 043-MIL had TWO manifests on 820072 — m1321 (SOFT-
-- DELETED 07-07 15:24) and m1322 (live, holds the visit). The Stamp card (id 330)
-- still pointed at matched_manifest_id = 1321 (the deleted one). The live views
-- (v_stamp_rows / v_stamp_sheets) only show a card whose matched_manifest_id is a
-- LIVE manifest, and the popover/candidate views read matched_manifest_id too — so
-- the card was invisible + unlinkable although its real manifest (1322) exists.
--
-- Why it happened: a card's matched_manifest_id went STALE when its manifest was
-- deleted-and-re-filed. The two resolve triggers only fill a NULL pointer:
--   - trg_resolve_card_manifest (on derm_manifests create/undelete) re-pointed only
--     matched_manifest_id IS NULL.
--   - trg_zz_card_from_link (on manifest_visits link) same.
-- Neither re-points a card that's aimed at a NOW-DELETED manifest, and nothing
-- re-pointed the card when its manifest was soft-deleted. So the pointer dangled.
--
-- FIX (structural, prevents recurrence fleet-wide):
--   1. NEW trigger trg_ad_card_reptr_on_delete on public.derm_manifests: when a
--      manifest is SOFT-DELETED (deleted_at NULL->set), re-point every card that
--      pointed at it to the live sibling for (white#, client), else NULL. Handles
--      the delete-after-refile ordering (this incident).
--   2. Harden derm.fn_resolve_card_manifest (create/undelete path): re-point cards
--      whose matched_manifest_id IS NULL *or points at a non-live manifest* — handles
--      the refile-after-delete ordering + any dangling pointer.
--   3. One-time backfill: re-point every card pointing at a deleted manifest to its
--      live sibling (today: exactly card 330 -> m1322; 0 with no sibling).
-- Both triggers write only derm.address_row_map (Stamp lane); SECURITY DEFINER;
-- no recursion (they don't write derm_manifests). Audit N/A (row-map is my lane).
-- @Supabase (1): trg on shared public.derm_manifests, additive, re-points Stamp
-- cards only — does not touch derm_manifests/manifest_visits data.

BEGIN;

-- 1) harden the create/undelete resolver: re-point NULL *or non-live* pointers
CREATE OR REPLACE FUNCTION derm.fn_resolve_card_manifest()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NEW.white_manifest_number IS NOT NULL THEN
    UPDATE derm.address_row_map r
       SET matched_manifest_id = NEW.id
     WHERE r.white_manifest_number = NEW.white_manifest_number
       AND r.matched_client_id     = NEW.client_id
       AND ( r.matched_manifest_id IS NULL
          OR NOT EXISTS (SELECT 1 FROM public.derm_manifests m
                          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL) );
  END IF;
  RETURN NULL;
END $$;

-- 2) re-point cards off a manifest that just got soft-deleted
CREATE OR REPLACE FUNCTION derm.fn_card_reptr_on_manifest_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  UPDATE derm.address_row_map r
     SET matched_manifest_id = (
           SELECT m.id FROM public.derm_manifests m
            WHERE m.white_manifest_number = NEW.white_manifest_number
              AND m.client_id = NEW.client_id
              AND m.deleted_at IS NULL
            ORDER BY m.id LIMIT 1)        -- live sibling for (ticket, client), else NULL
   WHERE r.matched_manifest_id = NEW.id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_ad_card_reptr_on_delete ON public.derm_manifests;
CREATE TRIGGER trg_ad_card_reptr_on_delete
AFTER UPDATE OF deleted_at ON public.derm_manifests
FOR EACH ROW
WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
EXECUTE FUNCTION derm.fn_card_reptr_on_manifest_delete();

-- 3) one-time backfill: any card pointing at a deleted manifest -> live sibling (else NULL)
UPDATE derm.address_row_map r
   SET matched_manifest_id = (
         SELECT m.id FROM public.derm_manifests m
          WHERE m.white_manifest_number = r.white_manifest_number
            AND m.client_id = r.matched_client_id
            AND m.deleted_at IS NULL
          ORDER BY m.id LIMIT 1)
 WHERE r.matched_manifest_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.derm_manifests m
                    WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL);

COMMIT;
