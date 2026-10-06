-- 2026-10-05_2250_stamp_limit_is_what_is_drawn.sql
--
-- WHY
-- ---
-- Fred, 2026-10-05, on ticket-830714 (sheet 416), which he redrew himself: "i see some blue dotted lines which are
-- not correctly placed, they take too much space, when they should only go up to the B section, which are the limit
-- bands, making the blackout be wrong ... the idea of doing it manually is for it to have a correct blackout, so the
-- idea is that the blackout only happens inside the limit bands excluding the client one is looking at the FP App."
--
-- His Draw the bands save (21:53 ET) made rows 27.870 .. 60.523, but the stored Limit stayed 14.796 .. 65.051 (set
-- 2026-09-02 from a SPARSE scan that read the Section A box as the roster top), because
-- derm._write_page_extent_from_slots took least/greatest with the stored Limit: the "the Limit never narrows" rule
-- added the same afternoon (2026-10-05_1545). The three regenerated documents therefore blacked out all of Section A
-- (company, decal, plate, capacity) and the footer down to "Total Waste Unloaded".
--
-- THE RULE NOW (Fred): the Limit is EXACTLY the two Limit bands the person drew, i.e. the first and last row edges.
-- The blackout covers only what is inside them, minus the viewing client's own band. Narrowing is no longer refused:
-- a person who sees a client's writing run below the last printed line draws the bottom Limit band below it.
-- Still guarded by save_page_geometry: G8 (every band inside the Limit, so a kept band that runs past a newly drawn
-- Limit refuses the save with a plain sentence), G11 (the Limit spans the printed lines, which after a save are the
-- drawn ones), and the sheet re-opens whenever the Limit moves.
--
-- WHAT THIS DOES
--   PART 1 derm._write_page_extent_from_slots: the live body copied, only the two least/greatest lines removed
--          (diffed against pg_get_functiondef before writing).
--   PART 2 the two drawn pages whose Limit is not their drawn Limit get it now, and are completed again so their
--          documents regenerate: ticket-830714 p1 (14.796/65.051 -> 27.870/60.523) and ticket-934861 p1
--          (26.604/59.959 -> 26.906/59.758). The other 9 drawn pages already match exactly.
--   Pages nobody has drawn are NOT touched: their Limits come from older measurements; 165 of 190 sit within 2
--   points of the measured printed lines, and the rest need a person (some machine lines are wrong, and
--   window5-sheet3 p2 is deliberately wide over a client's overflowing writing). They become exact when drawn.
-- Dry run (rolled back) before apply: both Limits exact, both sheets publishable and completed, all their documents
-- queued, 0 on v_band_edges_off_rule.
--
-- RULE 8: no new table. page_block_extents, address_row_map, stamp_sheet_status are audited.

BEGIN;

-- PART 1
CREATE OR REPLACE FUNCTION derm._write_page_extent_from_slots(p_dump_folder text, p_effective_page integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_top     numeric;
  v_bottom  numeric;
  v_old_top numeric;
  v_old_bot numeric;
  v_bands   jsonb;
  v_no_band integer;
  v_res     jsonb;
begin
  select min(s.y0_pct), max(s.y1_pct) into v_top, v_bottom
    from derm.page_slots s
   where s.dump_folder = p_dump_folder and s.effective_page = p_effective_page;
  if v_top is null then
    return jsonb_build_object('extent_written', false, 'reason', 'no_rows');
  end if;

  select e.top_pct, e.bottom_pct into v_old_top, v_old_bot
    from derm.page_block_extents e
   where e.dump_folder = p_dump_folder and e.effective_page = p_effective_page;
  -- 2026-10-05 22:45 ET (Fred): the Limit is EXACTLY what the person drew, the first and last row edges.
  -- The "never narrows" rule (least/greatest with the stored Limit, 2026-10-05_1545) is removed: it kept a
  -- wrong, wider Limit after a redraw and blacked out Section A on ticket-830714.

  select jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', r.band_y0_pct, 'y1', r.band_y1_pct) order by r.id),
         count(*) filter (where r.band_y0_pct is null or r.band_y1_pct is null)
    into v_bands, v_no_band
    from derm.address_row_map r
   where r.dump_folder = p_dump_folder
     and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.stamp_y_pct is not null and r.stamp_placed_at is not null;
  if v_bands is null then
    return jsonb_build_object('extent_written', false, 'reason', 'no_stamps');
  end if;
  if v_no_band > 0 then
    return jsonb_build_object('extent_written', false, 'reason', 'stamp_without_row');
  end if;

  v_res := derm.save_page_geometry(p_dump_folder, p_effective_page, v_bands, v_top, v_bottom);

  if v_old_top is distinct from round(v_top, 3) or v_old_bot is distinct from round(v_bottom, 3) then
    update derm.stamp_sheet_status s
       set completed = false, completed_at = null, completed_by = null, updated_at = now()
     where s.dump_folder = p_dump_folder and s.completed;
  end if;
  return v_res;
end
$function$
;

-- PART 2
SELECT derm._write_page_extent_from_slots('ticket-830714', 1);
SELECT derm._write_page_extent_from_slots('ticket-934861', 1);
SELECT derm.set_sheet_completed('ticket-830714', true);
SELECT derm.set_sheet_completed('ticket-934861', true);

DO $verify$
DECLARE v_n integer;
BEGIN
  IF pg_get_functiondef('derm._write_page_extent_from_slots'::regproc) LIKE '%least(v_top%' THEN
    RAISE EXCEPTION 'VERIFY 1: the never-narrow lines are still in the function';
  END IF;

  -- every drawn page's Limit is exactly its drawn rows
  SELECT count(*) INTO v_n
    FROM (SELECT dump_folder, effective_page, min(y0_pct) t, max(y1_pct) b FROM derm.page_slots GROUP BY 1, 2) s
    JOIN derm.page_block_extents e USING (dump_folder, effective_page)
   WHERE e.top_pct <> s.t OR e.bottom_pct <> s.b;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % drawn page(s) with a Limit that is not the drawn one', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE dump_folder IN ('ticket-830714', 'ticket-934861') AND completed;
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 3: % of 2 sheets completed', v_n; END IF;

  SELECT count(DISTINCT t.manifest_id) INTO v_n FROM derm.fn_blackout_targets(500) t
   WHERE t.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder IN ('ticket-830714', 'ticket-934861'));
  IF v_n < 3 THEN RAISE EXCEPTION 'VERIFY 4: only % manifest(s) queued to regenerate', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: the Limit is the drawn one on every drawn page; 830714 and 934861 regenerate';
END
$verify$;

COMMIT;
