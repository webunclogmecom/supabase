-- DERM Stamp Studio: Draw the bands is REQUIRED before a manual stamp (the database half)
--
-- Fred, voice note 2026-10-05: "before doing the stamp, we need to do the draw the bands ... it's
-- not gonna be like an optional from now on. It's gonna be required. First we need to draw the
-- bands ... the limit one ... for know where the blackout can happen, and then we need the client
-- bands. The client bands are the ones which differentiate between clients." And: "either the AI
-- is gonna do the job, or when the AI cannot do it, we need to do the draw the bands requirement
-- and put the stamp on it." On the plan the same day: snap each click to the printed line ("a
-- person is not perfect"), which is app-side.
--
-- Until now the order was the reverse: stamps first, then Draw the bands, because a band was tied
-- to a client only by that client's placed stamp, and save_page_geometry refuses a page with no
-- stamp (G1/G3). So "bands first" can only mean LINES first: the page's rows are saved from the
-- drawn lines, each stamp is then dropped INTO a row, and the Limit (the blackout area) is written
-- from the rows as soon as a stamp is in one. Three new functions and one widened check do that:
--
-- 1. derm.save_page_bands(folder, page, source_url, rules, meta)  [authenticated]
--    ONE transaction for what used to take two buttons ("Save lines and bands", then "Save printed
--    rows"): records the lines through record_page_rules (human-v1-<ET date>, the server's validator
--    judges them), rebuilds derm.page_slots from them, and puts every stamp already on the page
--    back in the row its point sits in (refused, with the client codes named, when a stamp is
--    outside every row or two share one). Then writes the Limit. A refusal raises, which also undoes
--    the FAILED scan row record_page_rules writes, so a refused save can never hide the page's last
--    good lines (the 2026-10-05 flow critique's "FAILED human-v1 ranks first" trap).
--    Unlike save_page_slots it may redraw a page whose cards are already in rows: it re-assigns
--    them by their stamp, which is the only safe way to re-index.
-- 2. derm.place_stamp_in_row(row, page, x, y)  [authenticated]
--    THE write for a stamp drop, unplaced card or placed stamp alike. The row comes from the drop
--    point and the page's saved rows: no rows -> "Draw the bands on this page first", outside every
--    row -> refused (until now the app placed it anyway with a warning), a row held by another
--    stamped card -> refused with its code. The stamp stays exactly where it was dropped (so the
--    chip is no longer forced to x = 8%), the card gets the row as its band (band_source 'slot'),
--    and the Limit is written. A geometry refusal undoes the whole drop.
-- 3. derm._write_page_extent_from_slots(folder, page)  [service_role only, called by 1 and 2]
--    Limit = first and last saved row edge, replayed with every publishable card's STORED band
--    through save_page_geometry, so G6 (closed set), G7/G7B (overlap, held rows), G8/G11, G9, G13
--    and G14 all still run. No extent-only writer was added, and the extent stays optional in
--    save_page_geometry (the generated-sheet finisher calls it).
-- 4. derm.record_page_rules: a page that has a scan but no card yet is a real page. An unplaced
--    card carries page = 1, so page 2 of a two-page sheet has no card until its first stamp; the
--    bands now come first, so that page must accept them. It must be in the ticket's image list.
-- 5. The operator sentences that named removed controls ("Re-measure printed lines", "Drag",
--    "Shrink this strip") or the old order ("Place the stamps first") are rewritten in the words of
--    the new panel (Limit bands, client bands): fn_geometry_hint, fn_rule_hint, fn_publishable_hint.
--    Plain-language rule (2026-09-14): MESSAGE is the sentence, DETAIL carries blocker=<code>.
--
-- Not changed: assign_card_to_slot / save_page_slots stay (the app stops calling them in the same
-- release; dropping them is a separate cleanup), set_stamp_position (fixed in 2026-10-05_1200),
-- fn_sheet_publishable (its fourth arm already holds a stamp that is not in a row), the AI path.
-- Every changed body is the live pg_get_functiondef output with anchored edits (each asserted to
-- match once). Rule 8: no new table or column; page_slots and address_row_map stay audited.

begin;

CREATE OR REPLACE FUNCTION derm.record_page_rules(p_dump_folder text, p_effective_page integer, p_source text, p_source_url text, p_rules jsonb, p_meta jsonb DEFAULT '{}'::jsonb, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public', 'pg_temp'
AS $function$
DECLARE
  v_grade      text := coalesce(p_meta->>'grade', 'FAILED');
  v_detail     text := p_meta->>'detail';
  -- 🛑 COMPUTE THE ETAG WHEN THE CALLER OMITS IT. A NULL here makes every band on the page read
  -- STALE in v_band_edge_check, because that check compares the etag BEFORE it compares any edge
  -- and NULL is DISTINCT FROM everything. The app does not send one; this is why it must not matter.
  v_etag       text := coalesce(p_meta->>'source_etag', derm._img_etag(p_source_url));
  v_reject     text;
  v_prev       record;
  v_n_rules    integer := 0;
  v_n_bounds   integer := 0;
  v_pitch      numeric;
  v_wrote      boolean := false;
  v_hint       text;
BEGIN
  -- 2026-09-02: 'human-v1-%' admitted alongside 'runlen-v2-%'. The READER was widened by
  -- 2026-09-02_0330 and this WRITER was not, so an operator-marked page raised
  -- "source must match runlen-v2-%" and nothing could ever be recorded. Measured before this
  -- migration: 176 scans exist and every one is runlen-v2, i.e. the widened view had never
  -- admitted a single row and was inert from the hour it shipped.
  IF NOT derm._is_rule_source(p_source) THEN
    RAISE EXCEPTION 'source must match runlen-v2-%%, human-v1-%% or template-v1-%%, got %',
      coalesce(p_source,'<null>') USING ERRCODE = '22023';
  END IF;
  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'dump_folder and effective_page are required' USING ERRCODE = '22023';
  END IF;
  IF v_grade NOT IN ('OK','IRREGULAR','SPARSE','FAILED') THEN
    RAISE EXCEPTION 'grade % is outside the allowed vocabulary', v_grade USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                  WHERE r.dump_folder = p_dump_folder
                    AND coalesce(r.stamp_page, r.page) = p_effective_page)
     -- 2026-10-05: a page with a scan but no card on it yet is a real page. Draw the bands now comes
     -- BEFORE any stamp, and an unplaced card carries page = 1, so page 2 of a two-page sheet has no
     -- card until the first stamp lands on it. The page must be in the ticket's image list.
     AND NOT EXISTS (SELECT 1
                       FROM (SELECT DISTINCT r.white_manifest_number AS wm
                               FROM derm.address_row_map r
                              WHERE r.dump_folder = p_dump_folder
                                AND r.white_manifest_number IS NOT NULL) f
                      WHERE p_effective_page BETWEEN 1
                            AND coalesce(array_length(derm.ticket_page_images(f.wm), 1), 0)) THEN
    RAISE EXCEPTION 'no cards on %/% : refusing to record rules for a page that does not exist',
      p_dump_folder, p_effective_page USING ERRCODE = '22023';
  END IF;

  -- 2026-09-02_1520: THE VALIDATOR RUNS BEFORE THE SUPERSESSION GUARD, and the order is the whole
  -- point of this migration. v_grade starts as the grade the CALLER CLAIMED. The guard below
  -- compares that value, so while validation ran AFTER it the guard could only ever see a caller
  -- that SAID 'FAILED'. The detector never does: it claims OK and lets the server judge. So a
  -- re-measure whose rules the validator rejects sailed past the guard, was written as the newest
  -- scan for the page, and v_page_printed_rules -- which joins rules on the newest scan's OWN
  -- source -- then served ZERO rules. The operator's hand-marked geometry vanished from every
  -- reader while still sitting in page_row_rules.
  -- Measured on ticket-834489 before the fix, replaying that page's real rejected detector
  -- payload: rules served went 7 -> 0, and the RPC reported wrote:false as if it had done nothing.
  IF v_grade <> 'FAILED' THEN
    v_reject := derm.fn_validate_page_rules(p_rules);
    IF v_reject IS NOT NULL THEN
      v_grade  := 'FAILED';
      v_detail := 'rejected by fn_validate_page_rules: ' || v_reject;
      -- the stored detail keeps the validator's exact words, because page_rule_scans.detail
      -- is the forensic record. The OPERATOR gets the plain sentence, returned separately.
      v_hint   := derm.fn_rule_hint(v_reject);
    END IF;
  END IF;
  SELECT s.grade, s.source, s.source_etag, s.scanned_at
    INTO v_prev
    FROM derm.page_rule_scans s
   WHERE s.dump_folder = p_dump_folder AND s.effective_page = p_effective_page
     AND derm._is_rule_source(s.source)
   ORDER BY s.scanned_at DESC
   LIMIT 1;

  -- 2026-09-02: was v_prev.grade = 'OK'. Widened to any non-FAILED grade because rules are
  -- WRITTEN on OK, SPARSE and IRREGULAR alike, and the view joins rules on the NEWEST scan's
  -- own source. So a later FAILED scan does not delete the old rules, it HIDES them: the page
  -- silently serves zero rules and every band on it grades UNSCANNED. Live corpus: 8 SPARSE
  -- and 2 IRREGULAR scans were exposed to that, and 0 pages are shadowed today, so this
  -- changes no existing row and is purely protective.
  IF FOUND AND v_prev.grade <> 'FAILED' AND v_grade = 'FAILED' AND NOT p_force
     AND (v_etag IS NULL OR v_prev.source_etag IS NULL OR v_etag = v_prev.source_etag) THEN
    RETURN jsonb_build_object(
      'wrote', false, 'grade', v_grade, 'rules_written', 0,
      'skipped', 'would_supersede_ok',
      -- 2026-09-02: the article is chosen from the grade rather than hardcoded 'a'. The grade
      -- vocabulary is OK / IRREGULAR / SPARSE / FAILED, so two of the four take 'an' and the
      -- message read "already has a OK scan" on the commonest one.
      'detail', format('this page already has %s %s scan (%s) and the image has not changed; '
                       || 'refusing to replace it with a %s result',
                       CASE WHEN left(v_prev.grade, 1) IN ('A','E','I','O','U')
                            THEN 'an' ELSE 'a' END,
                       v_prev.grade, v_prev.source, v_grade));
  END IF;


  SELECT count(*), count(*) FILTER (WHERE e->>'kind' = 'boundary')
    INTO v_n_rules, v_n_bounds
    FROM jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) e;

  IF v_grade <> 'FAILED' THEN
    WITH b AS (
      SELECT (e->>'pct')::numeric AS pct
        FROM jsonb_array_elements(p_rules) e
       WHERE e->>'kind' = 'boundary'
       ORDER BY 1
    ), g AS (
      SELECT pct - lag(pct) OVER (ORDER BY pct) AS gap FROM b
    )
    SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) INTO v_pitch FROM g WHERE gap IS NOT NULL;
  END IF;

  INSERT INTO derm.page_rule_scans
    (dump_folder, effective_page, source_url, image_w, image_h, skew,
     n_rules, n_boundaries, pitch_pct, grade, detail, source, scanned_at, source_etag, skew_saturated)
  VALUES
    (p_dump_folder, p_effective_page, coalesce(p_source_url,'(unknown)'),
     (p_meta->>'image_w')::int, (p_meta->>'image_h')::int, (p_meta->>'skew')::numeric,
     v_n_rules, v_n_bounds, v_pitch, v_grade, v_detail, p_source, now(), v_etag,
     coalesce((p_meta->>'skew_saturated')::boolean, false))
  ON CONFLICT (dump_folder, effective_page, source) DO UPDATE
    SET source_url = EXCLUDED.source_url, image_w = EXCLUDED.image_w, image_h = EXCLUDED.image_h,
        skew = EXCLUDED.skew, n_rules = EXCLUDED.n_rules, n_boundaries = EXCLUDED.n_boundaries,
        pitch_pct = EXCLUDED.pitch_pct, grade = EXCLUDED.grade, detail = EXCLUDED.detail,
        scanned_at = EXCLUDED.scanned_at, source_etag = EXCLUDED.source_etag,
        skew_saturated = EXCLUDED.skew_saturated;

  IF v_grade <> 'FAILED' THEN
    DELETE FROM derm.page_row_rules
     WHERE dump_folder = p_dump_folder AND effective_page = p_effective_page AND source = p_source;
    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, ink_frac, source, detected_at, run_frac, kind, kind_confirmed)
    SELECT p_dump_folder, p_effective_page,
           (e->>'pct')::numeric, coalesce((e->>'ink')::numeric, 0), p_source, now(),
           (e->>'run')::numeric, e->>'kind', false
      FROM jsonb_array_elements(p_rules) e;
    v_wrote := true;
  END IF;

  RETURN jsonb_build_object(
    'wrote', v_wrote, 'grade', v_grade,
    'rules_written', CASE WHEN v_wrote THEN v_n_rules ELSE 0 END,
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail, 'hint', v_hint,
    'source_etag', v_etag);
END $function$
;

-- ---------------------------------------------------------------------------------------------
-- 1. The page's Limit (the blackout area), written from its saved rows. Not callable by the app:
--    it runs inside place_stamp_in_row and save_page_bands, so nobody has to make a second trip
--    into Draw the bands, and every guard of save_page_geometry still runs.
-- ---------------------------------------------------------------------------------------------
create function derm._write_page_extent_from_slots(p_dump_folder text, p_effective_page integer)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_top     numeric;
  v_bottom  numeric;
  v_bands   jsonb;
  v_no_band integer;
begin
  -- the two Limit bands ARE the first and the last saved row edge
  select min(s.y0_pct), max(s.y1_pct) into v_top, v_bottom
    from derm.page_slots s
   where s.dump_folder = p_dump_folder and s.effective_page = p_effective_page;
  if v_top is null then
    return jsonb_build_object('extent_written', false, 'reason', 'no_rows');
  end if;

  -- the closed set save_page_geometry demands: every PUBLISHABLE card on the page, stored band
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
    -- a stamp that is not in a row yet; the publish gate already reports it (needs_snap_then_extent)
    return jsonb_build_object('extent_written', false, 'reason', 'stamp_without_row');
  end if;

  return derm.save_page_geometry(p_dump_folder, p_effective_page, v_bands, v_top, v_bottom);
end
$function$;
revoke all on function derm._write_page_extent_from_slots(text, integer) from public, anon, authenticated;
grant execute on function derm._write_page_extent_from_slots(text, integer) to service_role;

-- a plain sentence out of a save_page_geometry refusal: drop the "page geometry refused:" prefix
-- and the bracketed [CODE: detail] parts, which go to DETAIL for support
create function derm._geometry_refusal_sentence(p_msg text)
returns text
language sql
immutable
as $function$
  select nullif(btrim(regexp_replace(regexp_replace(coalesce(p_msg, ''), '^page geometry refused:[[:space:]]*', ''),
                                     '[[:space:]]*\[[^]]*\]', '', 'g')), '');
$function$;
revoke all on function derm._geometry_refusal_sentence(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. Drop a stamp into the row under it. The ONE write for a stamp drop in the Studio, for an
--    unplaced card and for a placed stamp moved to another row alike. The ROW comes from the drop
--    point and the page's saved rows, never from the card.
-- ---------------------------------------------------------------------------------------------
create function derm.place_stamp_in_row(p_row_id bigint, p_effective_page integer, p_x_pct numeric, p_y_pct numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_folder    text;
  v_card_page integer;
  v_placed    boolean;
  v_slot      integer;
  v_y0        numeric;
  v_y1        numeric;
  v_other     text;
  v_ext       jsonb;
  v_msg       text;
begin
  perform derm._require_stamp_key();

  if p_row_id is null or p_effective_page is null or p_x_pct is null or p_y_pct is null then
    raise exception 'Something went wrong placing this stamp. Reload the sheet and try again.'
      using detail = format('blocker=bad_arguments row=%s page=%s x=%s y=%s', p_row_id, p_effective_page, p_x_pct, p_y_pct);
  end if;

  select r.dump_folder, coalesce(r.stamp_page, r.page), r.stamp_placed_at is not null
    into v_folder, v_card_page, v_placed
    from derm.address_row_map r where r.id = p_row_id;
  if v_folder is null then
    raise exception 'This card no longer exists. Reload the sheet.'
      using detail = format('blocker=no_card row=%s', p_row_id);
  end if;

  -- moving a placed stamp to ANOTHER page is a deliberate act (it is how transposed folders were
  -- repaired), never a side effect of a drop
  if v_placed and v_card_page is distinct from p_effective_page then
    raise exception 'This stamp is on page %. Remove it there first, then place it on this page.', v_card_page
      using detail = format('blocker=placed_on_other_page row=%s folder=%s', p_row_id, v_folder);
  end if;

  if not exists (select 1 from derm.page_slots s
                  where s.dump_folder = v_folder and s.effective_page = p_effective_page) then
    raise exception 'Draw the bands on this page first. Then drop the stamp in its client''s row.'
      using detail = format('blocker=no_rows folder=%s page=%s', v_folder, p_effective_page);
  end if;

  -- a drop exactly on a line goes to the row below it
  select s.slot_index, s.y0_pct, s.y1_pct into v_slot, v_y0, v_y1
    from derm.page_slots s
   where s.dump_folder = v_folder and s.effective_page = p_effective_page
     and p_y_pct >= s.y0_pct and p_y_pct <= s.y1_pct
   order by s.slot_index desc
   limit 1;
  if v_slot is null then
    raise exception 'Drop the stamp inside a client''s row, between the two Limit bands.'
      using detail = format('blocker=outside_rows folder=%s page=%s y=%s', v_folder, p_effective_page, p_y_pct);
  end if;

  select coalesce(c.client_code, r2.manual_code, 'another client') into v_other
    from derm.address_row_map r2
    left join public.clients c on c.id = r2.matched_client_id
   where r2.dump_folder = v_folder
     and coalesce(r2.stamp_page, r2.page) = p_effective_page
     and r2.slot_index = v_slot
     and r2.stamp_y_pct is not null
     and r2.id <> p_row_id
   limit 1;
  if v_other is not null then
    raise exception 'That row already has %. Remove that stamp first, or drop this one in its own row.', v_other
      using detail = format('blocker=row_taken folder=%s page=%s slot=%s', v_folder, p_effective_page, v_slot);
  end if;

  -- the point exactly where it was dropped; set_stamp_position clears a band the point has left
  perform derm.set_stamp_position(p_row_id, p_effective_page, p_x_pct, p_y_pct);

  update derm.address_row_map
     set slot_index  = v_slot,
         band_y0_pct = round(v_y0, 3),
         band_y1_pct = round(v_y1, 3),
         band_source = 'slot',
         band_set_at = now(),
         band_set_by = derm._actor('stamp-studio')
   where id = p_row_id;

  -- the page's Limit, through every guard of save_page_geometry. A refusal undoes the whole drop.
  begin
    v_ext := derm._write_page_extent_from_slots(v_folder, p_effective_page);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    raise exception '%', coalesce(derm._geometry_refusal_sentence(v_msg), 'This stamp cannot go in that row.')
      using detail = 'blocker=geometry_refused ' || v_msg;
  end;

  return jsonb_build_object(
    'row_id', p_row_id, 'dump_folder', v_folder, 'effective_page', p_effective_page,
    'slot_index', v_slot, 'band_y0_pct', round(v_y0, 3), 'band_y1_pct', round(v_y1, 3),
    'extent', v_ext);
end
$function$;
revoke all on function derm.place_stamp_in_row(bigint, integer, numeric, numeric) from public, anon;
grant execute on function derm.place_stamp_in_row(bigint, integer, numeric, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. Save the bands: the lines (record_page_rules, human-v1) AND the rows (page_slots) in ONE
--    transaction, and every stamp already on the page goes back in the row its point sits in.
--    Replaces the two-button save of Draw the bands (record_page_rules + save_page_geometry, then
--    "Save printed rows" = save_page_slots).
-- ---------------------------------------------------------------------------------------------
create function derm.save_page_bands(p_dump_folder text, p_effective_page integer, p_source_url text,
                                     p_rules jsonb, p_meta jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_src     text := 'human-v1-' || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD');
  v_rec     jsonb;
  v_rows    integer;
  v_bad     text;
  v_cards   integer;
  v_ext     jsonb;
  v_msg     text;
  v_actor   text := derm._actor('stamp-studio');
begin
  perform derm._require_stamp_key();

  if p_dump_folder is null or p_effective_page is null then
    raise exception 'Something went wrong identifying this page. Reload the sheet and try again.'
      using detail = 'blocker=bad_arguments';
  end if;

  -- the lines. The caller's grade claim is ignored: the server judges (fn_validate_page_rules).
  v_rec := derm.record_page_rules(p_dump_folder, p_effective_page, v_src, p_source_url, p_rules,
                                  coalesce(p_meta, '{}'::jsonb) || '{"grade":"OK"}'::jsonb, false);
  if not coalesce((v_rec->>'wrote')::boolean, false) then
    -- raising also undoes the FAILED scan row record_page_rules wrote, so a refused save can never
    -- shadow the page's last good lines in derm.v_page_printed_rules
    raise exception '%', coalesce(nullif(v_rec->>'hint', ''),
                                  'These lines cannot be saved. Draw the two Limit bands and a client band on every printed line between them.')
      using detail = 'blocker=lines_refused ' || coalesce(v_rec->>'detail', v_rec->>'skipped', '');
  end if;

  select count(*) into v_rows from derm.fn_page_slots_preview(p_dump_folder, p_effective_page);
  if v_rows < 1 then
    raise exception 'Draw both Limit bands, the top and the bottom of Section B.'
      using detail = 'blocker=no_rows_formed';
  end if;

  -- every stamp already on this page must land in exactly one new row, alone
  create temp table if not exists _spb_cards (id bigint, code text, k integer) on commit drop;
  truncate _spb_cards;
  insert into _spb_cards
  select r.id, coalesce(c.client_code, r.manual_code, 'a client'),
         (select p.slot_index from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
           where r.stamp_y_pct >= p.y0_pct and r.stamp_y_pct <= p.y1_pct
           order by p.slot_index desc limit 1)
    from derm.address_row_map r
    left join public.clients c on c.id = r.matched_client_id
   where r.dump_folder = p_dump_folder
     and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.stamp_y_pct is not null and r.stamp_placed_at is not null;

  select string_agg(code, ', ' order by code) into v_bad from _spb_cards where k is null;
  if v_bad is not null then
    raise exception 'The stamp of % is outside the new rows. Move it into its row, or remove it, then save the bands again.', v_bad
      using detail = 'blocker=stamp_outside_rows';
  end if;
  select string_agg(codes, '; ') into v_bad
    from (select string_agg(code, ' and ' order by code) as codes from _spb_cards group by k having count(*) > 1) d;
  if v_bad is not null then
    raise exception '% are in the same row. Each client needs its own row: move one stamp, then save the bands again.', v_bad
      using detail = 'blocker=two_stamps_one_row';
  end if;

  delete from derm.page_slots where dump_folder = p_dump_folder and effective_page = p_effective_page;
  insert into derm.page_slots (dump_folder, effective_page, slot_index, y0_pct, y1_pct, source, set_by)
  select p_dump_folder, p_effective_page, p.slot_index, p.y0_pct, p.y1_pct, p.source, v_actor
    from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;

  -- re-band only what moved: a no-op write would re-stale the blackout fingerprint for nothing
  update derm.address_row_map r
     set slot_index = c.k,
         band_y0_pct = round(s.y0_pct, 3), band_y1_pct = round(s.y1_pct, 3),
         band_source = 'slot', band_set_at = now(), band_set_by = v_actor
    from _spb_cards c
    join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page and s.slot_index = c.k
   where r.id = c.id
     and (r.slot_index is distinct from c.k
          or r.band_y0_pct is distinct from round(s.y0_pct, 3)
          or r.band_y1_pct is distinct from round(s.y1_pct, 3));
  select count(*) into v_cards from _spb_cards;

  -- a row number held by a card with no stamp on this page means nothing any more
  update derm.address_row_map r set slot_index = null
   where r.dump_folder = p_dump_folder and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.slot_index is not null and r.stamp_y_pct is null;

  begin
    v_ext := derm._write_page_extent_from_slots(p_dump_folder, p_effective_page);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    raise exception '%', coalesce(derm._geometry_refusal_sentence(v_msg), 'These bands cannot be saved.')
      using detail = 'blocker=geometry_refused ' || v_msg;
  end;

  return jsonb_build_object('rows', v_rows, 'stamps_in_rows', v_cards, 'grade', v_rec->>'grade',
                            'lines', v_rec->'rules_written', 'extent', v_ext);
end
$function$;
revoke all on function derm.save_page_bands(text, integer, text, jsonb, jsonb) from public, anon;
grant execute on function derm.save_page_bands(text, integer, text, jsonb, jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION derm.fn_geometry_hint(p_code text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_code
    WHEN 'G1_NULL_KEY' THEN
      'Something went wrong identifying this page. Reload the sheet and try again.'
    WHEN 'G1_BANDS_SHAPE' THEN
      'There is no stamp on this page yet, so there is nothing to save for it.'
    WHEN 'G1_BAND_NULL' THEN
      'A client on this page is not in a row yet. Drop its stamp in its row, or draw the bands again.'
    WHEN 'G1_DUP_ROW' THEN
      'The same client row was sent twice. Reload the sheet and set the boundaries again.'
    WHEN 'G1_HALF_EXTENT' THEN
      'Both Limit bands are needed, the top and the bottom of Section B. One on its own cannot be saved.'
    WHEN 'G2_EXTENT_RANGE' THEN
      'A Limit band is off the sheet. Both Limit bands must sit inside the page.'
    WHEN 'G2_BAND_RANGE' THEN
      'A row edge is off the sheet. Every edge must sit inside the page.'
    WHEN 'G3_NO_SUCH_PAGE' THEN
      'There is no stamp on this page yet, so there is nothing to save for it.'
    WHEN 'G6_MISSING_ROW' THEN
      'A client on this page was left out. Every client printed on the page needs its own row boundaries.'
    WHEN 'G6_FOREIGN_ROW' THEN
      'A row that does not belong to this page was included. Reload the sheet and try again.'
    WHEN 'G7_OVERLAP' THEN
      'Two clients share the same row. Each client needs its own row, or one client would be shown part of another.'
    WHEN 'G7B_OVERLAPS_WITHHELD' THEN
      'This row covers a row that is on hold: a card on this page has a stamp but was never confirmed, so nothing may be published over its row. Someone needs to finish or remove that card first. A held row is often not drawn on this sheet, so you may not see it.'
    WHEN 'G8_NOT_CONTAINED' THEN
      'A Limit band cuts through a client row. Draw the bands again so every row sits fully between the two Limit bands.'
    WHEN 'G9_NOT_MEASURED' THEN
      'This page has no bands yet. Draw the bands on this page first.'
    WHEN 'G9_OFF_RULE' THEN
      'A band is not on one of the printed lines of the sheet. Draw the bands again with every band on a printed line: a band between the lines can cut a client''s own text in half.'
    WHEN 'G11_ROSTER_NOT_COVERED' THEN
      'The two Limit bands do not cover the whole printed list. Any printed row left outside them would be shown to the client. Put the Limit bands on the top and the bottom line of Section B.'
    WHEN 'G13_STAMP_OUTSIDE_BAND' THEN
      'A client''s stamp is outside its row. The stamp marks that client''s own row, so drop it inside the row.'
    WHEN 'G14_SPANS_EXTRA_SLOTS' THEN
      'A client''s row covers more printed rows than that client owns. If the client really has several permits on this sheet, it needs one card per permit.'
    ELSE
      'Unrecognised geometry check (' || COALESCE(p_code, 'null') || '). This is a bug: the check has no operator message. Tell Fred.'
  END;
$function$
;

CREATE OR REPLACE FUNCTION derm.fn_rule_hint(p_msg text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_msg IS NULL THEN NULL

    WHEN p_msg = 'no rules' OR p_msg LIKE 'rules is not a json array' THEN
      'No bands were drawn on this page.'

    -- the two floors, and the one Fred hits by marking only the top and bottom of Section B
    WHEN p_msg LIKE 'only % rules inside the roster' THEN
      'Not enough lines yet. Draw the two Limit bands (the top and the bottom of Section B) and a client band on every printed line between them.'

    WHEN p_msg LIKE 'only % slot boundaries' THEN
      'Not enough lines yet. Draw a client band on every printed line between the two Limit bands.'

    WHEN p_msg LIKE '% closer than the %pp merge distance' THEN
      'Two of your bands are almost on top of each other, closer than the sheet''s own rows can be. Remove one of them.'

    WHEN p_msg LIKE 'rules are not in strictly ascending order%' THEN
      'Two bands are at the same height. Remove the duplicate and save again.'

    WHEN p_msg LIKE '% is out of range' THEN
      'A band is off the page. Every band must sit inside the scan.'

    WHEN p_msg LIKE '% is missing pct, run or kind' THEN
      'One band could not be measured on the scan. Remove it and draw it again slightly higher or lower.'

    WHEN p_msg LIKE 'rule % has unknown kind %' THEN
      'One band could not be read. Remove it and draw it again.'

    WHEN p_msg LIKE 'chain does not alternate at position %' THEN
      'These bands do not read as the rows of the sheet. Draw a client band on every printed line between the two Limit bands, and nothing in between.'

    -- V4b. I wrote this one for a person this morning and it STILL says "slot boundary" and quotes
    -- a deviation percentage, neither of which names an action. Replaced, not passed through.
    WHEN p_msg LIKE 'every line is labelled a slot boundary, but they are not evenly pitched%' THEN
      'Your bands are not evenly spaced down the page: a printed line is probably missing, or one band sits inside a row instead of on a line. Draw a client band on every printed line between the two Limit bands.'

    WHEN p_msg LIKE 'a chain with no mid-slot dividers needs at least three%' THEN
      'Draw a client band on every printed line between the two Limit bands, so the spacing of the rows can be checked.'

    WHEN p_msg LIKE 'cannot measure the slot pitch%' THEN
      'The row spacing could not be measured from these bands. Check that they run down the page in order.'

    WHEN p_msg LIKE 'cannot split the run values%' THEN
      'These bands could not be told apart on the scan. Draw a client band on every printed line between the two Limit bands.'

    WHEN p_msg LIKE 'run-length split disagrees with the labels%' THEN
      'The bands do not match the printed lines on the scan. Draw each band on a printed line of Section B.'

    ELSE p_msg
  END;
$function$
;

CREATE OR REPLACE FUNCTION derm.fn_publishable_hint(p_code text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_code
    WHEN 'needs_extent' THEN
      'The top and the bottom of Section B have not been saved for this page yet. Open Draw the bands, check that the two Limit bands sit on the top and the bottom line of Section B, and save the bands.'
    WHEN 'needs_snap_then_extent' THEN
      'Some stamps on this page are not in a client row. Drop each stamp in its client''s row. If the page has no rows yet, open Draw the bands: draw the two Limit bands and a client band on every printed line between them, then save the bands.'
    WHEN 'cards_withheld' THEN
      'A stamp on this sheet has a position but was never confirmed, so nothing can be published over that row. Place that stamp again, or remove the card.'
    WHEN 'no_stamp_timestamp' THEN
      'A stamp on this sheet has a position but was never actually placed. Place it again; measuring the page will not fix this.'
    WHEN 'held_by_constraint' THEN
      'This sheet is deliberately frozen because its page layout is known to be wrong. It cannot be published, and this is not something to work around. Tell Fred.'
    WHEN 'frozen_closed_world' THEN
      'One card on this sheet has no stamp at all, which holds back every client on the sheet. Place the missing stamp; clearing the bands will not release it.'
    WHEN 'no_stamps' THEN
      'Nothing has been stamped on this sheet yet, so there is no document to produce. Draw the bands, then drop each client''s stamp in its row.'
    ELSE
      'This sheet cannot be published yet, and the reason has no message of its own. Tell Fred.'
  END;
$function$
;

do $verify$
declare
  v_rules jsonb;
  v_res   jsonb;
  v_n     integer;
  v_err   text;
  v_mgf   bigint;
  v_y0    numeric;
  v_f     text;
  v_out   text := '';
begin
  -- grants: the two app writes for staff, the helper for nobody but the server
  if not has_function_privilege('authenticated', 'derm.save_page_bands(text,integer,text,jsonb,jsonb)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'derm.place_stamp_in_row(bigint,integer,numeric,numeric)', 'EXECUTE') then
    raise exception 'VERIFY grants: staff cannot execute the new writes'; end if;
  if has_function_privilege('anon', 'derm.save_page_bands(text,integer,text,jsonb,jsonb)', 'EXECUTE')
     or has_function_privilege('anon', 'derm.place_stamp_in_row(bigint,integer,numeric,numeric)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm._write_page_extent_from_slots(text,integer)', 'EXECUTE') then
    raise exception 'VERIFY grants: too wide'; end if;
  if position('Draw the bands' in derm.fn_geometry_hint('G9_NOT_MEASURED')) = 0
     or position('Re-measure' in derm.fn_geometry_hint('G9_NOT_MEASURED')) > 0 then
    raise exception 'VERIFY hints: G9_NOT_MEASURED still names the removed button'; end if;

  -- the real page 836624 p1 (7 lines drawn by hand on 2026-09-30, 3 stamps), all rolled back
  select jsonb_agg(jsonb_build_object('pct', rule_pct, 'run', coalesce(run_frac, 0), 'ink', ink_frac, 'kind', 'boundary') order by rule_pct)
    into v_rules
    from derm.v_page_printed_rules where dump_folder = 'ticket-836624' and effective_page = 1 and kind = 'boundary';
  if jsonb_array_length(coalesce(v_rules, '[]')) <> 7 then raise exception 'VERIFY control: 836624 p1 has % lines, expected 7', jsonb_array_length(v_rules); end if;
  select r.id into v_mgf from derm.address_row_map r join public.clients c on c.id = r.matched_client_id
   where r.dump_folder = 'ticket-836624' and coalesce(r.stamp_page, r.page) = 1 and c.client_code = '320-MGF';

  begin
    -- A. place_stamp_in_row on a page with no rows yet is refused in plain words
    begin
      perform derm.place_stamp_in_row(v_mgf, 1, 10, 40);
      raise exception 'VERIFY A: a drop on a page with no rows was accepted';
    exception when others then
      get stacked diagnostics v_err = message_text;
      if v_err not like 'Draw the bands on this page first%' then raise exception 'VERIFY A: wrong refusal: %', v_err; end if;
    end;

    -- B. save the same 7 lines: 6 rows, the 3 stamps back in rows 1-3, the Limit = 27.677..60.327
    v_res := derm.save_page_bands('ticket-836624', 1, 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1973/address_1.jpg', v_rules, '{}');
    if (v_res->>'rows')::int <> 6 or (v_res->>'stamps_in_rows')::int <> 3 then raise exception 'VERIFY B: %', v_res; end if;
    select count(*) into v_n from derm.page_slots where dump_folder = 'ticket-836624' and effective_page = 1;
    if v_n <> 6 then raise exception 'VERIFY B: % page_slots rows', v_n; end if;
    select count(*) into v_n from derm.address_row_map where dump_folder = 'ticket-836624' and coalesce(stamp_page, page) = 1
       and stamp_y_pct is not null and slot_index is not null and band_y0_pct is not null;
    if v_n <> 3 then raise exception 'VERIFY B: % of 3 stamps are in a row', v_n; end if;
    select count(*) into v_n from derm.page_block_extents where dump_folder = 'ticket-836624' and effective_page = 1
       and top_pct = 27.677 and bottom_pct = 60.327;
    if v_n <> 1 then raise exception 'VERIFY B: Limit not 27.677..60.327'; end if;

    -- C. a drop outside every row, and a drop into a row another stamp holds, are refused
    begin
      perform derm.place_stamp_in_row(v_mgf, 1, 10, 15);
      raise exception 'VERIFY C1: a drop above the top Limit band was accepted';
    exception when others then
      get stacked diagnostics v_err = message_text;
      if v_err not like 'Drop the stamp inside a client''s row%' then raise exception 'VERIFY C1: %', v_err; end if;
    end;
    select y0_pct into v_y0 from derm.page_slots where dump_folder = 'ticket-836624' and effective_page = 1 and slot_index = 1;
    begin
      perform derm.place_stamp_in_row(v_mgf, 1, 10, v_y0 + 2);
      raise exception 'VERIFY C2: a drop into a taken row was accepted';
    exception when others then
      get stacked diagnostics v_err = message_text;
      if v_err not like 'That row already has %' then raise exception 'VERIFY C2: %', v_err; end if;
    end;

    -- D. a move to an empty row (row 4): the stamp lands where dropped, the band is row 4
    select y0_pct into v_y0 from derm.page_slots where dump_folder = 'ticket-836624' and effective_page = 1 and slot_index = 4;
    v_res := derm.place_stamp_in_row(v_mgf, 1, 22.5, v_y0 + 1);
    if (v_res->>'slot_index')::int <> 4 then raise exception 'VERIFY D: %', v_res; end if;
    select count(*) into v_n from derm.address_row_map r join derm.page_slots s
        on s.dump_folder = r.dump_folder and s.effective_page = 1 and s.slot_index = 4
     where r.id = v_mgf and r.slot_index = 4 and r.band_y0_pct = s.y0_pct and r.band_y1_pct = s.y1_pct
       and r.stamp_x_pct = 22.5 and r.stamp_y_pct = round(v_y0 + 1, 3) and r.band_source = 'slot';
    if v_n <> 1 then raise exception 'VERIFY D: the moved stamp is not in row 4 where it was dropped'; end if;

    -- E. a refused set of lines raises the plain hint and leaves no FAILED scan behind
    begin
      perform derm.save_page_bands('ticket-836624', 1, 'x', '[{"pct":27.677,"run":0.9,"ink":0.5,"kind":"boundary"},{"pct":60.327,"run":0.9,"ink":0.5,"kind":"boundary"}]', '{}');
      raise exception 'VERIFY E: two lines were accepted';
    exception when others then
      get stacked diagnostics v_err = message_text;
      if v_err like 'VERIFY%' or v_err like '%fn_validate%' then raise exception 'VERIFY E: %', v_err; end if;
    end;
    select count(*) into v_n from derm.page_rule_scans where dump_folder = 'ticket-836624' and effective_page = 1 and grade = 'FAILED' and source like 'human-v1-%' and scanned_at > now() - interval '1 hour';
    if v_n <> 0 then raise exception 'VERIFY E: a FAILED scan row was left behind'; end if;

    raise exception 'rollback-probe';
  exception when raise_exception then
    if sqlerrm <> 'rollback-probe' then raise; end if;
  end;

  -- F. record_page_rules: a page past the image list is still refused (control for the widening)
  begin
    perform derm.record_page_rules('ticket-836624', 9, 'human-v1-2026-10-05', 'x', v_rules, '{"grade":"OK"}', false);
    raise exception 'VERIFY F: page 9 of a 2-page sheet was accepted';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'no cards on %' then raise exception 'VERIFY F: %', v_err; end if;
  end;

  -- nothing the probes wrote survived
  select count(*) into v_n from derm.page_slots where dump_folder = 'ticket-836624';
  if v_n <> 0 then raise exception 'VERIFY: probe page_slots leaked'; end if;
end $verify$;

commit;
