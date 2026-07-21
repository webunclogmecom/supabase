-- ============================================================================
-- 2026-07-21a — Generated DERM Address sheets: return-review tripwire +
--               renumber-follow for Studio cards
-- ============================================================================
-- WHY (Fred 2026-07-20/21: "good, looks good, implement it" — opening the
-- production door for the generated-sheet flow, lifecycle doc open item #1):
--
-- 1) REVIEW-ON-RETURN TRIPWIRE. A generated sheet auto-completes in the Stamp
--    Studio at generation time (trg_zy_generated_sheet_complete, placed_by
--    'stamp-studio-ai') — correct, because in phase 1 there is nothing to look
--    at. But when the physical sheet RETURNS from the dump as a photo (the
--    office files it onto the ticket's manifests → derm_address_url NULL→set),
--    the AI stamps become the redaction-band seeds for a real image nobody has
--    verified. This trigger un-completes the sheet's stamp_sheet_status row at
--    that moment, so it reappears in the Studio work queue and the office
--    confirms (or drags) the pre-positioned stamps against the actual photo
--    before the blackout pipeline consumes them. Recommended in
--    docs/reference/generated-derm-address-lifecycle.md ("Open items" #1);
--    Fred's "implement it" green-lit it.
--
-- 2) RENUMBER-FOLLOW. Observed office practice (real returns 1009/1010) is to
--    file the return under the DISPOSAL facility's ticket number — i.e. the
--    ticket is RENUMBERED at filing (edit_manifest grouped update). Provenance
--    survives that (keyed by immutable manifest id), but the Stamp Studio's
--    card join key is derm.address_row_map.white_manifest_number = the ticket
--    key — and NOTHING remapped it on renumber (verified 2026-07-21: no trigger
--    on derm_manifests touches address_row_map keys; edit_manifest doesn't
--    either). In the NEW flow, cards materialize AT GENERATION under the
--    pre-dump number, so a renumber-at-filing would orphan the generated
--    sheet's cards + pages in the Studio (ticket_page_images(new key) finds the
--    photos while the cards sit under the old key). The preview-era sheets
--    never hit this only because their cards were created AFTER the renumber.
--    This trigger makes the card key follow the ticket key, scoped to manifests
--    provenance-linked to a LIVE generated sheet.
--
--    NOTE (known gap, out of scope): renumbering a HANDWRITTEN stamped ticket
--    has the same stale-key effect today. Rare (cards normally exist only
--    after filing under the final number), pre-existing, and deliberately NOT
--    covered here to keep this change scoped to the generated lane. Widen the
--    guard later if it ever bites (drop the provenance EXISTS).
--
-- DESIGN NOTES:
-- - stamp_sheet_status is keyed by dump_folder (a stable FOLDER LABEL, e.g.
--   'ticket-999901' / 'backfill-829201'), NOT the ticket number — so the
--   tripwire resolves folders via the ticket's cards, and the renumber-follow
--   deliberately does NOT touch dump_folder (label, not a join key).
-- - Tripwire fires on the FIRST photo per manifest row (INSERT with photo, or
--   UPDATE with OLD.derm_address_url IS NULL). A photo REPLACEMENT does not
--   re-flip. A later first-photo on a SIBLING row after the office already
--   re-completed WILL re-flip — new image content is a new review; accepted.
--   Extras-only changes (derm_address_extra_urls without a primary) don't fire;
--   the DERM Tracker always writes the primary first.
-- - Both triggers are idempotent no-ops outside the generated lane (provenance
--   EXISTS against derm.address_sheets s WHERE s.deleted_at IS NULL).
-- - completed_by/completed_at are NULLed on the flip so a later completion
--   (human or AI) records fresh attribution.
--
-- 3NF: no new columns; triggers only. AUDIT: derm.* Studio app-state tables
-- remain audit-opt-out (standing decision, ADR 010 exclusion list —
-- stamp_sheet_status is derived app state, source of truth is the human
-- action in the Studio); public.derm_manifests writes that FIRE these
-- triggers are already audited (audit_derm_manifests).
--
-- VERIFICATION: synthetic arena test T1-T4 below (112-YA client 381, ticket
-- 999901, sheet 999901 — hard-deleted after JSON backup per synthetic-row
-- protocol); results appended at the bottom of this file.
-- ============================================================================

-- ─── 1. Renumber-follow ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION derm.trg_generated_cards_follow_renumber()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $$
DECLARE
  v_old_key text := COALESCE(OLD.white_manifest_number, OLD.yellow_ticket_number);
  v_new_key text := COALESCE(NEW.white_manifest_number, NEW.yellow_ticket_number);
BEGIN
  IF v_old_key IS NULL OR v_new_key IS NULL OR v_old_key = v_new_key THEN
    RETURN NULL;
  END IF;

  -- Only the generated lane: this manifest is provenance-linked to a live sheet.
  IF NOT EXISTS (
    SELECT 1
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
    WHERE l.manifest_id = NEW.id
  ) THEN
    RETURN NULL;
  END IF;

  UPDATE derm.address_row_map
     SET white_manifest_number = v_new_key,
         updated_at = now()
   WHERE matched_manifest_id = NEW.id
     AND white_manifest_number = v_old_key;

  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zw_generated_cards_follow_renumber ON public.derm_manifests;
CREATE TRIGGER trg_zw_generated_cards_follow_renumber
  AFTER UPDATE OF white_manifest_number, yellow_ticket_number ON public.derm_manifests
  FOR EACH ROW
  EXECUTE FUNCTION derm.trg_generated_cards_follow_renumber();

-- ─── 2. Review-on-return tripwire ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION derm.trg_generated_sheet_return_review()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $$
DECLARE
  v_key text := COALESCE(NEW.white_manifest_number, NEW.yellow_ticket_number);
BEGIN
  -- first photo on this row only
  IF NEW.derm_address_url IS NULL OR NEW.deleted_at IS NOT NULL THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.derm_address_url IS NOT NULL THEN
    RETURN NULL;
  END IF;
  IF v_key IS NULL THEN
    RETURN NULL;
  END IF;

  -- Only when this ticket belongs to a LIVE generated sheet (linked directly,
  -- or via any live ticket sibling — covers photos filed on rows appended
  -- after generation).
  IF NOT EXISTS (
    SELECT 1
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
    JOIN public.derm_manifests sib ON sib.id = l.manifest_id AND sib.deleted_at IS NULL
    WHERE l.manifest_id = NEW.id
       OR COALESCE(sib.white_manifest_number, sib.yellow_ticket_number) = v_key
  ) THEN
    RETURN NULL;
  END IF;

  -- Un-complete the sheet so the Studio queue resurfaces it for the visual
  -- check of the AI stamps against the real returned photo.
  UPDATE derm.stamp_sheet_status st
     SET completed = false,
         completed_at = NULL,
         completed_by = NULL,
         updated_at = now()
   WHERE st.completed
     AND st.dump_folder IN (
       SELECT DISTINCT r.dump_folder
       FROM derm.address_row_map r
       WHERE r.white_manifest_number = v_key
     );

  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zx_generated_sheet_return_review ON public.derm_manifests;
CREATE TRIGGER trg_zx_generated_sheet_return_review
  AFTER INSERT OR UPDATE OF derm_address_url ON public.derm_manifests
  FOR EACH ROW
  EXECUTE FUNCTION derm.trg_generated_sheet_return_review();

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21, all PASS (synthetic arena, client 381
-- 112-YA, ticket 999901/sheet 999901; scratchpad test_21a.js; backup at
-- ..\backups\2026-07-21_tripwire_test_synthetic_rows.json, then hard-deleted)
-- ============================================================================
-- setup: record_generated_address_sheet(999901) + _materialize_card ->
--        card auto-stamped @25.980% by stamp-studio-ai (trg_ab_autoplace path
--        still intact), status 'ticket-999901' auto-completed.
-- T1 PASS renumber-follow: white 999901->999902 => card.white_manifest_number
--        followed to 999902; dump_folder label unchanged ('ticket-999901').
-- T2 PASS tripwire: derm_address_url NULL->set => status flipped
--        completed=false / completed_by NULL — resolved through the RENUMBERED
--        key (T1+T2 together = the real office sequence: renumber at filing,
--        then attach the photo).
-- T3 PASS no-flap: office re-completed ('office-test'); photo REPLACED
--        (non-NULL -> non-NULL) => no re-flip.
-- T4 PASS negative control: handwritten ticket (no provenance) renumbered +
--        photo attached => stamp_sheet_status untouched (counts identical).
-- teardown: counts restored to exact baseline
--        {blackout:0, manifests:553, cards:552, status:103, live sheets:0};
--        fn_blackout_targets stayed 0 throughout.
