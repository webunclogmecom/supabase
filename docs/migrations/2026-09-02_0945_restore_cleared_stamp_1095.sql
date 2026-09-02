-- 2026-09-02_0945_restore_cleared_stamp_1095.sql
--
-- WHAT: restores the stamp on derm.address_row_map id 1095 (148-MOR, ticket-834489 page 1), which
--       was cleared at 2026-09-02 09:27:10 ET. Every value comes from audit.logs old_row, not from
--       anyone's memory.
--
-- WHY:  Fred drew a full set of limit and client bands on that sheet and could not save. The reason
--       is not the drawing: it is that the page has NO PLACED STAMP, so no card can be assigned to a
--       strip, so zero bands derive and the Save button is correctly disabled
--       (`drawDerivation.bands.length === 0`). A strip is bound to a client BY ITS STAMP and by
--       nothing else, which is the safety property of the whole feature, so with the stamp gone
--       there is nothing to bind.
--
-- 🛑 IT WAS ALMOST CERTAINLY ME, AND THE AUDIT TRAIL CANNOT PROVE IT EITHER WAY.
--       audit.logs id 179094 records the clear as app_source='derm-stamp-studio',
--       jwt_claims email fred@ayache.com. My automation dispatches clicks INSIDE Fred's browser
--       session, so anything I do is attributed to him and is indistinguishable from his own work.
--       I was driving that exact page at that exact minute, clicking "Re-measure printed lines" and
--       "Confirm lines manually" by dispatching pointer events at computed coordinates, and the
--       PLACED list on that page carries an X control per card.
--       ⇒ Worth carrying beyond this repair: **browser automation running in a person's own session
--       is unattributable in audit.logs.** Any write it makes will be blamed on them. That is a
--       reason to keep synthetic clicks off pages holding real work, not merely an inconvenience.
--
-- 🛑 AND THE VALUES BEING RESTORED ARE FRED'S OWN FINAL PLACEMENT, not a guess. The trail for this
--       card reads: 21:28 placed at y=36.065, 22:15 no-op, 22:16:15 cleared, 22:16:19 re-placed at
--       y=35.861. So 35.861 is where he deliberately left it after adjusting, eleven hours before
--       the accidental clear.
--
-- ⚠ RESTORING PROVENANCE WITH THE COORDINATES, never separately. stamp_placed_by and
--    stamp_placed_at go back together with x, y and page. Putting the coordinates back while leaving
--    a different actor would relabel a person's work.
--
-- ⚠ stamp_image_url is restored explicitly. derm's witness trigger writes that column on a FRESH
--    placement by resolving the page ordinal, and the ordinal is what this estate has already been
--    bitten by when an image list moves. The recorded witness is the authority, so it is set from
--    old_row and asserted afterwards.
--
-- ⚠ BANDS ARE DELIBERATELY LEFT NULL. old_row shows band_y0_pct and band_y1_pct were both null at
--    the moment of the clear, so restoring anything there would be inventing geometry, not reverting.
--
-- RULE 6 (never hard-delete): not applicable, this is a restore.
-- RULE 8 (audit): derm.address_row_map already carries the audit trigger, which is exactly why this
--    repair is possible at all. This UPDATE is itself audited. No schema change.

BEGIN;

UPDATE derm.address_row_map r
   SET stamp_page      = 1,
       stamp_x_pct     = 12.999,
       stamp_y_pct     = 35.861,
       stamp_placed_at = '2026-09-02T02:16:19.797682+00'::timestamptz,
       stamp_placed_by = 'fred@ayache.com',
       stamp_image_url = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1774/address_1.jpg'
 WHERE r.id = 1095
   AND r.dump_folder = 'ticket-834489'
   -- pinned to the cleared state, so this cannot fire twice or overwrite a newer real placement
   AND r.stamp_placed_at IS NULL
   AND r.stamp_y_pct IS NULL;

DO $$
DECLARE
  v_y numeric; v_x numeric; v_pg int; v_by text; v_url text; v_at timestamptz;
  v_b0 numeric; v_b1 numeric; v_placed int; v_other int;
BEGIN
  SELECT stamp_y_pct, stamp_x_pct, stamp_page, stamp_placed_by, stamp_image_url,
         stamp_placed_at, band_y0_pct, band_y1_pct
    INTO v_y, v_x, v_pg, v_by, v_url, v_at, v_b0, v_b1
    FROM derm.address_row_map WHERE id = 1095;

  -- 1. every value matches audit.logs old_row exactly
  IF v_y <> 35.861 OR v_x <> 12.999 OR v_pg <> 1
     OR v_by IS DISTINCT FROM 'fred@ayache.com'
     OR v_at IS DISTINCT FROM '2026-09-02T02:16:19.797682+00'::timestamptz THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: restored to y=% x=% page=% by=% at=%', v_y, v_x, v_pg, v_by, v_at;
  END IF;

  -- 2. the witness survived the trigger rather than being re-derived from an ordinal
  IF v_url IS DISTINCT FROM 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1774/address_1.jpg' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: stamp_image_url is %, not the recorded witness', v_url;
  END IF;

  -- 3. no geometry was invented
  IF v_b0 IS NOT NULL OR v_b1 IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: bands were written (% .. %), but old_row had none', v_b0, v_b1;
  END IF;

  -- 4. THE POINT OF THE REPAIR: the page now has exactly one placed card, so a strip can bind to it.
  --    Without this the migration could restore a row and still leave Fred unable to save.
  SELECT count(*) INTO v_placed FROM derm.v_stamp_rows
   WHERE dump_folder = 'ticket-834489' AND placed AND stamp_page = 1
     AND stamp_x_pct IS NOT NULL AND stamp_y_pct IS NOT NULL;
  IF v_placed <> 1 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: v_stamp_rows reports % placed cards on page 1, expected 1', v_placed;
  END IF;

  -- 5. CONTROL: card 1096 was never placed and must stay untouched
  SELECT count(*) INTO v_other FROM derm.address_row_map
   WHERE id = 1096 AND stamp_placed_at IS NULL AND stamp_y_pct IS NULL;
  IF v_other <> 1 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: card 1096 was modified';
  END IF;

  RAISE NOTICE 'OK: 1095 restored to Fred''s own 22:16 placement; 1 placed card on page 1; 1096 untouched.';
END $$;

COMMIT;
