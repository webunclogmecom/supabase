-- 2026-08-10_1930_stamp_return_review_preserve_append.sql
--
-- WHAT: narrows the GRAIN GUARD added 75 minutes earlier in
--       2026-08-10_1855_stamp_return_review_sheet_grain.sql. Nothing else changes.
-- WHY:  that guard was too broad and introduced a FALSE NEGATIVE on a safety control.
--
-- AUDIT (rule #8): no schema change, no new object. See the 1855 migration's header.
--
-- ---------------------------------------------------------------------------------------------
-- THE REGRESSION I SHIPPED AT 1855, AND HOW IT WAS FOUND
-- ---------------------------------------------------------------------------------------------
-- The 1855 guard skips the un-complete whenever the incoming url already sits on a live sibling
-- of the same ticket. That correctly kills the burst-filing re-open (one physical photo attached
-- to every client card in one upload). But it ALSO skips a genuinely different case that the
-- original trigger deliberately covered, and whose own comment says so:
--   "covers photos filed on rows appended after generation".
--
-- An APPENDED card is a client added to a ticket whose sheet was ALREADY completed and reviewed.
-- Its AI stamp is a placement nobody has looked at, which is exactly what this control exists to
-- surface. Under the 1855 guard it would arrive silently, because an appended card is normally
-- given the SAME shared sheet photo as its siblings.
--
-- MEASURED, and it is not hypothetical:
--   609 live cards sit on completed sheets. 2 of them were created AFTER their sheet completed
--   (ids 1295 / 214-MYK on ticket 826661, +3h29m; 1296 / 133-MUT on ticket 827172, +4h40m).
--   BOTH carry a url already held by a live sibling, so BOTH would have been suppressed.
--   Positive control on the same join: 607 cards created at or before completion, 120 tickets,
--   so the query can and does return rows on the other side of the partition.
--
-- Trading a 4-occurrence FALSE POSITIVE (a spurious re-open, visible and harmless) for a
-- 2-occurrence FALSE NEGATIVE (an unreviewed stamp on a compliance form, silent) is a bad trade
-- even at those counts, because the two failures are not the same kind.
--
-- ---------------------------------------------------------------------------------------------
-- THE DISCRIMINATOR
-- ---------------------------------------------------------------------------------------------
-- Not a time threshold. The question is simply: was this row part of the set that was reviewed,
-- or has it appeared since?
--   burst filing : the card is created in the same transaction that completes the sheet, so
--                  completed_at is NOT earlier than created_at  -> duplicate photo -> SKIP
--   appended row : the sheet was completed hours or days before the card existed, so
--                  completed_at IS earlier than created_at      -> new placement  -> FIRE
--
-- Verified against the real burst: manifest 1697 (ticket 832194) has created_at
-- 14:55:37.306400 and the sheet's completion INSERT is the same timestamp in the same txid, so
-- completed_at < created_at is false and the skip still applies.
--
-- PROVENANCE: body COPIED from the live definition (which is the 1855 body), not retyped.
-- The ONLY change is the added NOT EXISTS arm inside the GRAIN GUARD.
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
  --
  -- ...UNLESS this row APPEARED AFTER the sheet was reviewed (2026-08-10_1930). An appended
  -- client card carries the same shared photo but its stamp is a placement nobody has looked at,
  -- which is precisely what this control exists to surface. Measured: 2 of 609 cards on
  -- completed sheets were created after completion, and both share a sibling url, so without
  -- this arm they would be silently suppressed.
  IF EXISTS (
    SELECT 1
    FROM public.derm_manifests sib
    WHERE sib.id <> NEW.id
      AND sib.deleted_at IS NULL
      AND sib.derm_address_url = NEW.derm_address_url
      AND COALESCE(sib.white_manifest_number, sib.yellow_ticket_number) = v_key
  ) AND NOT EXISTS (
    SELECT 1
    FROM derm.stamp_sheet_status st
    WHERE st.completed
      AND st.completed_at IS NOT NULL
      AND st.completed_at < NEW.created_at
      AND st.dump_folder IN (
        SELECT DISTINCT r.dump_folder
        FROM derm.address_row_map r
        WHERE r.white_manifest_number = v_key
      )
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
