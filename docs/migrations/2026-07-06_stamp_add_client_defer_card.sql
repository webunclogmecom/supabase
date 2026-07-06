-- 2026-07-06_stamp_add_client_defer_card.sql
-- Fred UX bug: "+ Add client" created the card IMMEDIATELY on client-pick (fired a
-- premature "Card added" toast before any visit was linked), then DELETED it on
-- "Done" if you didn't link ("ghost card" create-then-remove). A card should not
-- exist until a visit is actually linked to it (you can't have a card without a
-- linked visit). Especially bad when the client has no linkable visits (e.g.
-- 112-YA: modal shows "nothing to link" yet a card was already created+removed).
--
-- Fix: defer card creation to visit-click. The modal's visit list
-- (derm.v_stamp_unlinked_visits) is already CLIENT-keyed, so "+ Add client" can
-- open the picker WITHOUT a card. Only when the operator clicks a visit do we
-- create the card AND link, atomically, via this new RPC. If there are no visits
-- / the operator hits Done, nothing was created — no card, no toast, no removal.
--
--   derm.add_client_card_and_link(p_dump_folder, p_page, p_client_id, p_visit_id)
--     -> creates (or reuses) the client's card on the sheet AND files/links the
--        visit in one gated, atomic call; returns the card id.
--     - x-stamp-key gated (single gate for the whole op).
--     - Reuses an existing card for (sheet, client) if one already exists (no dup).
--     - Delegates the manifest file/link to derm.file_manifest_and_link (reuses the
--       ticket's manifest or files one inheriting shared docs; points the card;
--       links the visit; audited). Same-client guard enforced there.
--     - The picked visit comes from v_stamp_unlinked_visits (unlinked-only), so no
--       cross-manifest double-link is possible.
--
-- Additive (new function). The old add_sheet_client + link_row_visit path stays
-- (used by the per-card Link toggle); only the "+ Add client" flow changes in the app.

BEGIN;

CREATE OR REPLACE FUNCTION derm.add_client_card_and_link(
  p_dump_folder text, p_page integer, p_client_id bigint, p_visit_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_wm text; v_row bigint; v_vcid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_client_id IS NULL THEN RAISE EXCEPTION 'p_client_id required'; END IF;
  IF p_visit_id IS NULL THEN RAISE EXCEPTION 'p_visit_id required'; END IF;

  -- visit must exist, be live, and belong to this client
  SELECT client_id INTO v_vcid FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN RAISE EXCEPTION 'visit % not found or deleted', p_visit_id; END IF;
  IF v_vcid <> p_client_id THEN
    RAISE EXCEPTION 'visit % belongs to a different client than %', p_visit_id, p_client_id;
  END IF;

  SELECT max(white_manifest_number) INTO v_wm FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_wm IS NULL THEN RAISE EXCEPTION 'unknown sheet %', p_dump_folder; END IF;

  -- reuse the client's existing card on this sheet if present, else create one now
  SELECT id INTO v_row FROM derm.address_row_map
    WHERE dump_folder = p_dump_folder AND matched_client_id = p_client_id
    ORDER BY id LIMIT 1;
  IF v_row IS NULL THEN
    v_row := derm.add_sheet_client(p_dump_folder, COALESCE(p_page, 1), p_client_id, NULL);
  END IF;

  -- file the manifest if needed (inherits shared docs) + link the visit + point the card
  PERFORM derm.file_manifest_and_link(v_row, p_visit_id);
  RETURN v_row;
END $$;
GRANT EXECUTE ON FUNCTION derm.add_client_card_and_link(text, integer, bigint, bigint) TO anon, authenticated;

COMMIT;
