-- 2026-08-10_1855_stamp_return_review_sheet_grain.sql
--
-- WHAT: adds ONE guard to derm.trg_generated_sheet_return_review(). Nothing else changes.
-- WHY:  the trigger models a PER SHEET event but fires PER ROW, so a shared sheet photo
--       re-opened a sheet the resolver had just completed.
--
-- AUDIT (rule #8): no new table, no schema change. derm.stamp_sheet_status keeps its existing
-- audit trigger, and this migration deliberately makes it QUIETER (fewer spurious un-completes),
-- which is the point. No opt-in/opt-out decision is required.
--
-- ---------------------------------------------------------------------------------------------
-- THE DEFECT, measured
-- ---------------------------------------------------------------------------------------------
-- derm.trg_generated_sheet_return_review fires AFTER INSERT OR UPDATE OF derm_address_url on
-- public.derm_manifests and un-completes the sheet, so the office visually re-checks AI stamps
-- against the real returned photo. That control is CORRECT and is kept.
--
-- Its dedup ("first photo on this row only") is PER MANIFEST ROW. But one dump ticket has one
-- manifest row PER CLIENT (DERM Tracker rule #10) and they all share ONE physical address sheet,
-- so the DERM Tracker attaches the SAME derm_address_url to every sibling card in one upload
-- burst. The trigger therefore fires once per card for a single physical photo. Whichever fire
-- happens to land after derm.fn_resolve_generated_sheet_for_ticket has completed the sheet
-- un-completes it, 0.15 to 0.20 s after it was completed.
--
-- Measured in audit.logs (derm.stamp_sheet_status):
--   ticket-832194  completed=true 14:55:37.306400  ->  false 14:55:37.504658   (0.198 s, 7 cards)
--   ticket-311045  completed=true 18:31:56.271752  ->  false 18:31:56.425844   (0.154 s, 2 cards)
--
-- Hit 4 times: 831710 (08-03), 831938 (08-05), 832194 (08-07), 311045 (08-07). 831710 and 831938
-- were repaired by hand on 2026-08-06 17:17:58; the other two landed the next day and missed it.
-- Recency was the only discriminator. All four were fully AI-placed generated sheets.
--
-- ---------------------------------------------------------------------------------------------
-- THE FIX
-- ---------------------------------------------------------------------------------------------
-- Skip the un-complete when this exact URL ALREADY sits on a live sibling of the same ticket.
-- Such an arrival is the same physical photo being attached to another client's card, and the
-- sheet has already been through its return-review transition for that image.
--
-- This PRESERVES the original premise ("new image content is a new review"): a genuinely
-- DIFFERENT url on a sibling still un-completes. Measured, 5 of 102 multi-card tickets carry 2
-- distinct address urls, so that path is real and is intentionally left firing.
--
-- Still fires, deliberately:
--   * the first photo of a ticket arriving while the sheet is completed (the real review event)
--   * a genuinely different image arriving on any card
--   * INSERT of a brand new card carrying a url no live sibling has
--
-- ---------------------------------------------------------------------------------------------
-- REJECTED ALTERNATIVES (do not "simplify" this into one of them)
-- ---------------------------------------------------------------------------------------------
--   * Deriving completed from placed_rows = total_rows in derm.v_stamp_sheets. That deletes the
--     control entirely and contradicts the 2026-07-11 finding that a completed sheet can have
--     0 of 5 real clients stamped.
--   * Moving the photo write onto the INSERT. trg_zx sorts BEFORE trg_zy_resolve_generated_sheet
--     alphabetically, so the un-complete would run before the completion and the symptom would
--     vanish while the control silently stopped working. The firing order is load-bearing.
--   * Dropping the trigger. It has caught a real mis-stamp class twice (831710, 310590).
--
-- ---------------------------------------------------------------------------------------------
-- PROVENANCE: the body below was COPIED from the live pg_get_functiondef output, not retyped
-- (CLAUDE.md "CREATE OR REPLACE: COPY THE WHOLE BODY"). The ONLY difference from the live body is
-- the inserted block marked "GRAIN GUARD". Verified by diffing the live definition against this
-- file: 1 hunk, 16 added lines, 0 removed, 0 modified.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derm.trg_generated_sheet_return_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
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

  -- GRAIN GUARD (2026-08-10): the dedup above is PER ROW, but this is a PER SHEET event.
  -- One physical sheet photo is attached to every sibling card of the ticket in one burst, so
  -- the same url arrives once per client and the arrival that lands after the resolver has
  -- completed the sheet would re-open it. If this exact url is already on a live sibling of the
  -- same ticket, the sheet has already had its return-review for this image.
  -- A genuinely different url on a sibling still falls through and un-completes, on purpose.
  IF EXISTS (
    SELECT 1
    FROM public.derm_manifests sib
    WHERE sib.id <> NEW.id
      AND sib.deleted_at IS NULL
      AND sib.derm_address_url = NEW.derm_address_url
      AND COALESCE(sib.white_manifest_number, sib.yellow_ticket_number) = v_key
  ) THEN
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
END $function$;
