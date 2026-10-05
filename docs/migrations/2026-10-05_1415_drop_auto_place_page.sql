-- Drop derm.auto_place_page: the Stamp Studio's Auto-place button is gone
--
-- Fred, voice note 2026-10-05: "remove the Auto Place button and Re-measure Printed Lines ... any
-- kind of functionality they have, remove them as well ... either the AI is gonna do the job, or when
-- the AI cannot do it, we need to do the draw the bands requirement and put the stamp on it."
--
-- The button was the function's ONLY caller, measured before this migration:
--   * the published Stamp Studio bundle (every chunk walked, positive controls 'save_page_bands' and
--     'place_stamp_in_row' present) carries 0 references to auto_place_page;
--   * no function, view, trigger, cron job or edge function calls it (prosrc / view / cron / deployed
--     edge-body sweeps, 2026-10-05, positive control save_page_geometry found);
--   * no other app bundle names it (admin, calendar, clients, derm, dump, fp, hr, hub, planner, reviews);
--   * pg_depend: no dependents, so no CASCADE.
-- The AI path never used it: trg_autoplace_generated (at filing) and derm.fn_place_cards_awaiting_page_map
-- (the finisher's step A) each have their own UPDATE and only share its helpers, which all stay.
-- v_stamp_rows.guess_x_pct / guess_y_pct (read only by this function) stay in the view, now unread.
--
-- RESTORE: the full body as it was live on 2026-10-05 is kept below as a comment. Re-create it and
-- GRANT EXECUTE ... TO authenticated, service_role to undo.
-- Rule 8: a function, nothing to audit.
--
-- ----- body before the drop -----
-- CREATE OR REPLACE FUNCTION derm.auto_place_page(p_dump_folder text, p_page integer)
--  RETURNS TABLE(placed integer, skipped integer)
--  LANGUAGE plpgsql
--  SECURITY DEFINER
--  SET search_path TO 'derm', 'public'
-- AS $function$
-- DECLARE v_sheet text; v_placed integer := 0; v_skipped integer := 0;
-- BEGIN
--   PERFORM derm._require_stamp_key();
--   IF p_dump_folder IS NULL OR p_page IS NULL OR p_page < 1 THEN
--     RAISE EXCEPTION 'auto-place: bad arguments (folder=%, page=%)', p_dump_folder, p_page;
--   END IF;
--   SELECT min(white_manifest_number) INTO v_sheet FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
--   IF v_sheet IS NULL THEN RAISE EXCEPTION 'auto-place: unknown sheet %', p_dump_folder; END IF;
--   -- 🛑 2026-09-13: a GENERATED sheet knows its own layout, so the TAB is not the target image.
--   -- Until this branch existed, every generated-sheet card was stamped at stamp_page = p_page:
--   -- derm.v_stamp_rows.guess_y_pct takes o_y_pct from derm.fn_generated_row_geometry and DISCARDS
--   -- o_page, and the UPDATE below wrote the tab. Measured on ticket-835076 (rolled back): pressing
--   -- Auto-place on the page-1 tab placed the five page-2 clients on image 1 at exactly the five
--   -- page-1 clients' y values. Ten stamps on a scan that prints five.
--   -- This branch is derm.trg_autoplace_generated's own resolution chain, evaluated per card:
--   --   slot -> geometry -> fn_sheet_image_position(o_page) -> fn_row_read_confirms
--   -- and it places the card on THAT image, whatever tab the operator is on. A card whose image
--   -- position is still unknown (the page-N read has not landed) or whose row read names a
--   -- different client is left alone and counted as skipped, never guessed.
--   -- ⚠ A client holding MORE THAN ONE card on the folder is also skipped: fn_generated_sheet_slot
--   -- resolves the client's FIRST printed row, so placing both here would stack the second permit on
--   -- the first one's row (the trap documented for the insert trigger). Those cards are placed by
--   -- derm.assign_card_to_slot or by dragging, never by this button.
--   -- p_page is deliberately NOT a filter here: the cards belong where the paper says, and rostering
--   -- on COALESCE(stamp_page, page) is what listed page-2 cards under the page-1 tab in the first place.
--   -- (The resolution runs in a subquery because an UPDATE's LATERAL may not reference its target.)
--   IF derm.fn_sheet_is_generated(v_sheet) THEN
--     UPDATE derm.address_row_map a
--        SET stamp_x_pct = round(t.o_x_pct, 3),
--            stamp_y_pct = round(t.o_y_pct, 3),
--            stamp_page  = t.img,
--            stamp_placed_at = now(),
--            stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
--       FROM (
--         SELECT r.id, geo.o_x_pct, geo.o_y_pct,
--                derm.fn_sheet_image_position(r.dump_folder, geo.o_page) AS img
--           FROM derm.address_row_map r
--           JOIN public.clients c ON c.id = r.matched_client_id
--           CROSS JOIN LATERAL derm.fn_generated_row_geometry(derm.fn_generated_sheet_slot(r.matched_manifest_id)) geo
--          WHERE r.dump_folder = p_dump_folder
--            AND r.stamp_placed_at IS NULL
--            AND geo.o_y_pct IS NOT NULL
--            AND derm.fn_sheet_image_position(r.dump_folder, geo.o_page) IS NOT NULL
--            AND derm.fn_row_read_confirms(r.dump_folder,
--                                          derm.fn_sheet_image_position(r.dump_folder, geo.o_page),
--                                          ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1,
--                                          c.client_code) IS NOT FALSE
--            AND (SELECT count(*) FROM derm.address_row_map s
--                  WHERE s.dump_folder = r.dump_folder AND s.matched_client_id = r.matched_client_id) = 1
--       ) t
--      WHERE a.id = t.id;
--     GET DIAGNOSTICS v_placed = ROW_COUNT;
--     SELECT count(*) INTO v_skipped FROM derm.address_row_map s
--      WHERE s.dump_folder = p_dump_folder AND s.stamp_placed_at IS NULL;
--     RETURN QUERY SELECT v_placed, v_skipped;
--     RETURN;
--   END IF;
--   -- 🛑 2026-09-03: the roster keys on the EFFECTIVE page, COALESCE(stamp_page, page), not on
--   -- raw `page`. On a folder scanned as one sheet, derm._materialize_card writes page = 1 for every
--   -- card, so `page` is a constant and cannot say which scan a card belongs on: 23 of 138 folders
--   -- (193 cards) are in that state. Rostering on it offered a page-2 card from the PAGE-1 tab and
--   -- re-filed it against page 1's scan. Paired with clear_stamp_position keeping stamp_page, this
--   -- reads the operator's page intent instead.
--   SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
--     FROM derm.v_stamp_rows g
--    WHERE g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page AND NOT g.placed;
--   UPDATE derm.address_row_map a
--      SET stamp_x_pct = round(g.guess_x_pct, 3),
--          stamp_y_pct = round(g.guess_y_pct, 3),
--          stamp_page  = p_page,
--          stamp_placed_at = now(),
--          stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
--     FROM derm.v_stamp_rows g
--    WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page
--      AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
--   GET DIAGNOSTICS v_placed = ROW_COUNT;
--   RETURN QUERY SELECT v_placed, v_skipped;
-- END $function$
-- 
-- ----- end -----

begin;

revoke execute on function derm.auto_place_page(text, integer) from public, anon, authenticated;
drop function derm.auto_place_page(text, integer);

do $verify$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'derm' and p.proname = 'auto_place_page') then
    raise exception 'VERIFY: derm.auto_place_page still exists';
  end if;
end $verify$;

commit;
