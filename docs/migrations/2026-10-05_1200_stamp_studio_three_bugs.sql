-- DERM Stamp Studio: three bugs, fixed before Draw the bands becomes required
--
-- Fred, 2026-10-05, after reading the plan: "Fix the bugs first." The three were found while
-- checking the plan to make Draw the bands required before any manual stamp (voice note the same
-- day). Each one would have made the required flow fail or leak.
--
-- 1. DRAW THE BANDS OPENED EMPTY ON PAGES THAT ALREADY HAVE LINES.
--    derm.v_page_printed_rules (the one definition of "the printed lines of a page") calls
--    derm._is_rule_source, an IMMUTABLE SQL predicate that no app role could EXECUTE. The view is
--    owner-rights, but a function's EXECUTE is checked against the CALLER, so every staff read
--    raised 42501 and the app showed nothing: on ticket-836624 p1 (7 lines saved 2026-09-30) the
--    panel said "No lines drawn yet", and the line overlay on the scan was blank estate-wide.
--    _rule_source_rank, its sibling in the same view, was already executable by everyone.
--    Fix: GRANT EXECUTE to authenticated and service_role. It is a pure predicate over its one
--    argument and reads no table, so the grant exposes nothing.
-- 2. REMOVING A STAMP DID NOT FREE ITS ROW.
--    derm.clear_stamp_position cleared the point and the band but not slot_index, and
--    derm.assign_card_to_slot treats a row as taken when ANY other card holds that slot_index,
--    stamped or not. So after Remove, no other card could go in that row, and save_page_slots
--    refused to redraw the page for a card that was not even on it.
--    Fix: clear slot_index with the stamp; a row is taken only by a STAMPED card.
-- 3. DRAGGING A PLACED STAMP COULD TAKE IT OUT OF ITS ROW, AND THE SHEET STILL COMPLETED.
--    derm.set_stamp_position moved the point and left band_y0/y1 and slot_index untouched, and
--    derm.fn_sheet_publishable has no stamp-inside-band arm, so a stamp could sit in one client's
--    row while its band revealed another, with completion allowed.
--    Fix: when the new point is outside the stored band, or on another page, the band and the row
--    assignment are cleared in the same write. The publish gate then reports the page
--    (needs_snap_then_extent) until the stamp is dropped into a row again. A move INSIDE the band
--    changes nothing but the point.
--
-- All three bodies are the live pg_get_functiondef output with anchored edits (each anchor asserted
-- to match exactly once); nothing else in them moved. Callers of set_stamp_position checked first:
-- see the migration's VERIFY and Supabase/CLAUDE.md "STAMP STUDIO: DRAW THE BANDS IS REQUIRED".
-- Rule 8: no new table, no new column; derm.address_row_map stays audited.

begin;

grant execute on function derm._is_rule_source(text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION derm.clear_stamp_position(p_row_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     -- 🛑 2026-09-03: the null-out of stamp_page was REMOVED from this SET. Clearing the point
     -- must not also destroy WHICH SCAN the operator had chosen: on a folder where every card
     -- shares page = 1, stamp_page is the only thing that says so, and discarding it dropped the
     -- card onto the page-1 tab where auto-place re-filed it against the wrong scan. Every
     -- publishing predicate keys on stamp_y_pct (verified across all four arms of
     -- v_blackout_blocked_sheets and the closed-world gate in fn_blackout_targets), and that is
     -- still nulled here, so a retained stamp_page cannot make a card look placed or block a sheet.
     SET stamp_x_pct = NULL, stamp_y_pct = NULL,
         stamp_placed_at = NULL, stamp_placed_by = NULL,
         -- clearing the point must clear the rectangle: a band with no stamp is invisible to
         -- derm.v_stamp_row_bands and fails the folder's closed-world gate
         band_y0_pct = NULL, band_y1_pct = NULL,
         band_source = NULL, band_set_at = NULL, band_set_by = NULL,
         -- 2026-10-05: a cleared card no longer holds its row. Before this, slot_index survived the
         -- clear, so assign_card_to_slot kept reporting that row as taken and save_page_slots refused
         -- to redraw the page for a card that was not even on it.
         slot_index = NULL
   WHERE id = p_row_id;
END $function$
;

CREATE OR REPLACE FUNCTION derm.assign_card_to_slot(p_row_id bigint, p_slot_index integer, p_effective_page integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_folder   text;
  v_eff      integer;
  v_x        numeric;
  v_stamp_y  numeric;
  v_y0       numeric;
  v_y1       numeric;
  v_centre   numeric;
  v_moved    boolean := false;
  v_card_page integer;
  v_placed   boolean;
BEGIN
  PERFORM derm._require_stamp_key();

  IF p_row_id IS NULL OR p_slot_index IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'row id, slot index and effective page are required';
  END IF;

  -- 🛑 THE PAGE COMES FROM THE CALLER, NOT FROM THE CARD. The first version of this function
  -- derived it as COALESCE(stamp_page, page). Measured on live data that is wrong for exactly the
  -- cards this feature is FOR: 33 of 43 unplaced cards carry stamp_page NULL and 42 of 43 carry
  -- page = 1, so assigning an unplaced card while looking at page 2 of a multi-page folder
  -- silently resolved to page 1. Four folders are in that state today. Resolving a page from a
  -- value that does not mean "the page" is the same class of defect as resolving a row from a
  -- free-floating y coordinate, which is what this whole feature exists to eliminate.
  SELECT r.dump_folder, COALESCE(r.stamp_page, r.page), r.stamp_x_pct, r.stamp_y_pct
    INTO v_folder, v_card_page, v_x, v_stamp_y
    FROM derm.address_row_map r WHERE r.id = p_row_id;
  IF v_folder IS NULL THEN
    RAISE EXCEPTION 'address_row_map id % not found', p_row_id;
  END IF;
  v_eff := p_effective_page;

  -- An already-PLACED card sitting on another page is not moved by a slot assignment. Moving a
  -- placed card between pages is a real repair (it is what fixed two transposed folders) but it is
  -- a deliberate act, not something a drop-into-slot gesture should do as a side effect.
  SELECT (stamp_placed_at IS NOT NULL) INTO v_placed
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_placed AND v_card_page IS DISTINCT FROM p_effective_page THEN
    RAISE EXCEPTION 'card % is already placed on page %, not page %. Clear its stamp first if it '
                    'really belongs on the other page.', p_row_id, v_card_page, p_effective_page;
  END IF;

  SELECT s.y0_pct, s.y1_pct INTO v_y0, v_y1
    FROM derm.page_slots s
   WHERE s.dump_folder = v_folder AND s.effective_page = v_eff AND s.slot_index = p_slot_index;
  IF v_y0 IS NULL THEN
    RAISE EXCEPTION 'no slot % on % page %. Measure the page with derm.save_page_slots first.',
                    p_slot_index, v_folder, v_eff;
  END IF;

  -- 🛑 Two cards must not share a printed slot: that is precisely the one-slot-shift defect this
  -- whole change exists to make unreachable.
  IF EXISTS (SELECT 1 FROM derm.address_row_map r2
              WHERE r2.dump_folder = v_folder
                AND COALESCE(r2.stamp_page, r2.page) = v_eff
                AND r2.slot_index = p_slot_index AND r2.id <> p_row_id
                -- 2026-10-05: only a STAMPED card holds a row (a cleared one is not on the page)
                AND r2.stamp_y_pct IS NOT NULL) THEN
    RAISE EXCEPTION 'slot % on % page % is already taken by another client',
                    p_slot_index, v_folder, v_eff;
  END IF;

  -- STAMP FIRST. A band on a stampless row drops the row out of derm.v_stamp_row_bands and
  -- freezes every document in the folder through the closed-world gate. Only move a stamp that is
  -- missing or outside its own slot; a stamp already inside it is left exactly where the human
  -- put it.
  v_centre := round((v_y0 + v_y1) / 2, 3);
  IF v_stamp_y IS NULL OR v_stamp_y < v_y0 OR v_stamp_y > v_y1 THEN
    PERFORM derm.set_stamp_position(p_row_id, v_eff, COALESCE(v_x, 8), v_centre);
    v_moved := true;
  END IF;

  UPDATE derm.address_row_map
     SET slot_index  = p_slot_index,
         band_y0_pct = round(v_y0, 3),
         band_y1_pct = round(v_y1, 3),
         band_source = 'slot',
         band_set_at = now(),
         band_set_by = derm._actor('stamp-studio')
   WHERE id = p_row_id;

  RETURN jsonb_build_object(
    'row_id', p_row_id, 'dump_folder', v_folder, 'effective_page', v_eff,
    'slot_index', p_slot_index, 'band_y0_pct', round(v_y0,3), 'band_y1_pct', round(v_y1,3),
    'stamp_moved', v_moved, 'stamp_y_pct', COALESCE(CASE WHEN v_moved THEN v_centre END, v_stamp_y));
END
$function$
;

CREATE OR REPLACE FUNCTION derm.set_stamp_position(p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_out boolean;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_row_id IS NULL OR p_page IS NULL OR p_x_pct IS NULL OR p_y_pct IS NULL THEN
    RAISE EXCEPTION 'stamp arguments must not be null (row=%, page=%, x=%, y=%)', p_row_id, p_page, p_x_pct, p_y_pct;
  END IF;
  IF p_page < 1 THEN RAISE EXCEPTION 'stamp page must be >= 1 (got %)', p_page; END IF;
  IF p_x_pct < 0 OR p_x_pct > 100 OR p_y_pct < 0 OR p_y_pct > 100 THEN
    RAISE EXCEPTION 'stamp percent out of range (x=%, y=%)', p_x_pct, p_y_pct;
  END IF;
  -- 2026-10-05: THE BAND FOLLOWS THE STAMP. A stamp moved out of its saved band, or onto another
  -- page, no longer says which printed row that band belongs to. Before this the old band stayed
  -- behind: the stamp sat in one client's row, the band revealed another, and the sheet still
  -- completed (fn_sheet_publishable has no stamp-inside-band arm). Now the band and the row
  -- assignment are cleared, so the publish gate (needs_snap_then_extent) holds the sheet until the
  -- stamp is dropped into a row again. A move INSIDE the band keeps everything as it was.
  SELECT r.band_y0_pct IS NOT NULL
         AND (COALESCE(r.stamp_page, r.page) IS DISTINCT FROM p_page
              OR round(p_y_pct, 3) < r.band_y0_pct OR round(p_y_pct, 3) > r.band_y1_pct)
    INTO v_out
    FROM derm.address_row_map r WHERE r.id = p_row_id;

  UPDATE derm.address_row_map
     SET stamp_x_pct = round(p_x_pct, 3),
         stamp_y_pct = round(p_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = derm._actor('stamp-studio'),
         band_y0_pct = CASE WHEN v_out THEN NULL ELSE band_y0_pct END,
         band_y1_pct = CASE WHEN v_out THEN NULL ELSE band_y1_pct END,
         band_source = CASE WHEN v_out THEN NULL ELSE band_source END,
         band_set_at = CASE WHEN v_out THEN NULL ELSE band_set_at END,
         band_set_by = CASE WHEN v_out THEN NULL ELSE band_set_by END,
         slot_index  = CASE WHEN v_out THEN NULL ELSE slot_index END
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
END $function$
;

do $verify$
declare v_id bigint; v_pg int; v_y0 numeric; v_y1 numeric; v_ok boolean; v_n int;
begin
  -- 1. the grant, and only to the two roles
  if not has_function_privilege('authenticated', 'derm._is_rule_source(text)', 'EXECUTE') then
    raise exception 'VERIFY 1: authenticated still cannot execute _is_rule_source'; end if;
  if has_function_privilege('anon', 'derm._is_rule_source(text)', 'EXECUTE') then
    raise exception 'VERIFY 1: anon can execute _is_rule_source'; end if;

  -- 3. a move OUTSIDE the band clears band + row; a move INSIDE keeps them (rolled back sub-block)
  select r.id, coalesce(r.stamp_page, r.page), r.band_y0_pct, r.band_y1_pct
    into v_id, v_pg, v_y0, v_y1
    from derm.address_row_map r
   where r.stamp_y_pct is not null and r.band_y0_pct is not null and r.band_y1_pct - r.band_y0_pct > 1
   order by r.id limit 1;
  if v_id is null then raise exception 'VERIFY 3: no banded card to probe (control)'; end if;
  begin
    perform derm.set_stamp_position(v_id, v_pg, 10, round((v_y0 + v_y1) / 2, 3));
    select band_y0_pct = v_y0 and band_y1_pct = v_y1 into v_ok from derm.address_row_map where id = v_id;
    if not coalesce(v_ok, false) then raise exception 'VERIFY 3a: a move inside the band changed the band'; end if;
    perform derm.set_stamp_position(v_id, v_pg, 10, least(v_y1 + 2, 99));
    select band_y0_pct is null and band_y1_pct is null and slot_index is null and band_source is null
      into v_ok from derm.address_row_map where id = v_id;
    if not coalesce(v_ok, false) then raise exception 'VERIFY 3b: a move outside the band kept the band'; end if;
    raise exception 'rollback-probe';
  exception when raise_exception then
    if sqlerrm <> 'rollback-probe' then raise; end if;
  end;

  -- 2. clearing frees the row (on a card that holds one, if any exists)
  select r.id into v_id from derm.address_row_map r
   where r.slot_index is not null and r.stamp_y_pct is not null order by r.id limit 1;
  if v_id is not null then
    begin
      perform derm.clear_stamp_position(v_id);
      select slot_index is null into v_ok from derm.address_row_map where id = v_id;
      if not coalesce(v_ok, false) then raise exception 'VERIFY 2: clear kept slot_index'; end if;
      raise exception 'rollback-probe';
    exception when raise_exception then
      if sqlerrm <> 'rollback-probe' then raise; end if;
    end;
  end if;

  -- nothing the probes touched survived
  select count(*) into v_n from derm.address_row_map where id = v_id and slot_index is null and stamp_y_pct is null;
  if v_id is not null and v_n > 0 then raise exception 'VERIFY: probe write leaked'; end if;
end $verify$;

commit;
