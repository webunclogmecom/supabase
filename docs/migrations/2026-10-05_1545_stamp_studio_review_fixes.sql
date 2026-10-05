-- Stamp Studio: fixes from the adversarial review of today's Draw-the-bands release
--
-- A 21-agent review of 2026-10-05_1310 (read-only probes, every claim re-run by a refuter) confirmed
-- 17 of 18 findings. The database ones are fixed here; the app ones went to Lovable the same hour.
-- Measured scenarios (all rolled back) and their outcome AFTER this migration:
--
-- 1. LEAK, a half-row shift: drawing the faint mid-row lines instead of the lines between clients
--    passed every check (the validator skips its phase test for an all-boundary chain, and human
--    lines were only ever graded against themselves). On 836624 p1 it would have served 320-MGF the
--    lower half of 009-CN's row. NOW: when the scan has a machine measurement (runlen-v2 or
--    template-v1, not FAILED, same image), save_page_bands refuses a row that crosses a measured
--    line between two clients ("A row you drew crosses a printed line between two clients ...").
--    The same check refuses one line 1pp off (829216 p2). Tolerance 0.5pp, not G9's 0.35: a correct
--    hand line on 836057 p1 sits 0.365 from the template line. The machine's first and last line
--    are exempt (a footer bar can be counted as a row line: 836624 p1 64.956). Sweep: the current
--    lines of all 22 hand-drawn pages re-save without a refusal.
--    NOTE: a page with NO machine measurement (every new handwritten page, now that the in-app
--    re-measure is gone) has no independent check. Recorded for Fred.
-- 2. LEAK, a redraw narrowing the blackout: re-saving window5-sheet3 p2 shrank its Limit from
--    65.6 to 60.5 and re-banded two reviewed overflow bands, so 114-CI's handwritten address below
--    the footer and JCC's city line would have reached other clients. NOW: the Limit is NEVER
--    narrower than the page's current one (least/greatest), and a stamp that already has a band
--    KEEPS it on a redraw; only stamps without a band take their row.
-- 3. A Limit change on a completed sheet republished without anyone re-completing: page_block_extents
--    has no dirty trigger. NOW _write_page_extent_from_slots re-opens the sheet when the Limit moves.
-- 4. Old writers the Studio no longer calls (record_page_rules, save_page_slots,
--    assign_card_to_slot, set_row_band, save_page_geometry) were still callable by any staff
--    session, around every new check; record_page_rules(p_force) could hide a page's lines. NOW
--    revoked from authenticated (SECURITY DEFINER callers run as owner: unaffected).
-- 5. Rows carried no scan identity: after a replaced scan a drop used the old rows. NOW
--    place_stamp_in_row refuses when the rows' scan etag differs from the page image's.
-- 6. place_stamp_in_row's "row taken" missed stamps without a row number (older pages): now any
--    other stamp whose point is inside the row; and a nudge inside a stamp's own band keeps the band.
-- 7. Plain-language gaps: a redraw refused on a page with a good earlier scan got a generic sentence
--    (record_page_rules' would_supersede_ok now returns the validator's hint and reason); a page past
--    the image list raised a raw technical message (now "This page is no longer on the sheet.");
--    refusals name a multi-permit card by its permit nickname ("009-CN Kitchen and 009-CN Lounge").
-- Not changed: the refuted finding (stale rows after a same-day re-record, no harm shown).
-- New helper derm._card_label(row_id). The bodies of today's own functions are rewritten in full
-- from the live ones; record_page_rules is an anchored replace of its live body.
-- Rule 8: no new table or column.

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
      -- 2026-10-05: the validator's reason travels with the refusal, so a redraw on a page with a
      -- good earlier scan gets the specific sentence, not a generic one (save_page_bands shows it)
      'hint', v_hint, 'reject', v_detail,
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
-- A label for a card in an operator sentence: the client code, plus the permit nickname when the
-- client has one card per permit ("009-CN Bar"), so two cards of one client are told apart.
-- ---------------------------------------------------------------------------------------------
create function derm._card_label(p_row_id bigint)
returns text
language sql
stable
security definer
set search_path to 'derm', 'public'
as $function$
  select coalesce(c.client_code, r.manual_code, 'a client')
         || coalesce(' ' || nullif(btrim(coalesce(g.nickname, g.location_label)), ''), '')
    from derm.address_row_map r
    left join public.clients c on c.id = r.matched_client_id
    left join public.gdos g on g.id = r.gdo_id
   where r.id = p_row_id;
$function$;
revoke all on function derm._card_label(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1. The Limit from the saved rows. NEVER NARROWER than the Limit the page already has: a
--    narrower box shows whatever sits outside it (a client's address written below the footer
--    line) to every client on the page. Widening is the safe direction. A change of the Limit
--    re-opens a completed sheet, so nothing republishes without a person pressing Mark completed.
-- ---------------------------------------------------------------------------------------------
create or replace function derm._write_page_extent_from_slots(p_dump_folder text, p_effective_page integer)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
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
  v_top    := least(v_top, coalesce(v_old_top, v_top));
  v_bottom := greatest(v_bottom, coalesce(v_old_bot, v_bottom));

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
$function$;

-- ---------------------------------------------------------------------------------------------
-- 2. Drop a stamp into the row under it.
--    Changed today after review: a row is taken by any OTHER stamp whose point is inside it (not
--    only by a row number, which older stamps do not carry); a stamp moved inside its own saved
--    band keeps that band (a reviewed band is never replaced by a nudge); and the rows must belong
--    to the scan that is on the page now.
-- ---------------------------------------------------------------------------------------------
create or replace function derm.place_stamp_in_row(p_row_id bigint, p_effective_page integer, p_x_pct numeric, p_y_pct numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_folder    text;
  v_wm        text;
  v_card_page integer;
  v_placed    boolean;
  v_b0        numeric;
  v_b1        numeric;
  v_slot      integer;
  v_y0        numeric;
  v_y1        numeric;
  v_other     bigint;
  v_rows_etag text;
  v_img_etag  text;
  v_ext       jsonb;
  v_msg       text;
begin
  perform derm._require_stamp_key();

  if p_row_id is null or p_effective_page is null or p_x_pct is null or p_y_pct is null then
    raise exception 'Something went wrong placing this stamp. Reload the sheet and try again.'
      using detail = format('blocker=bad_arguments row=%s page=%s x=%s y=%s', p_row_id, p_effective_page, p_x_pct, p_y_pct);
  end if;

  select r.dump_folder, r.white_manifest_number, coalesce(r.stamp_page, r.page), r.stamp_placed_at is not null,
         r.band_y0_pct, r.band_y1_pct
    into v_folder, v_wm, v_card_page, v_placed, v_b0, v_b1
    from derm.address_row_map r where r.id = p_row_id;
  if v_folder is null then
    raise exception 'This card no longer exists. Reload the sheet.'
      using detail = format('blocker=no_card row=%s', p_row_id);
  end if;

  if v_placed and v_card_page is distinct from p_effective_page then
    raise exception 'This stamp is on page %. Remove it there first, then place it on this page.', v_card_page
      using detail = format('blocker=placed_on_other_page row=%s folder=%s', p_row_id, v_folder);
  end if;

  -- a nudge inside the stamp's own saved band: move the point, keep the band (reviewed bands stay)
  if v_placed and v_b0 is not null and v_b1 is not null and p_y_pct >= v_b0 and p_y_pct <= v_b1 then
    perform derm.set_stamp_position(p_row_id, p_effective_page, p_x_pct, p_y_pct);
    return jsonb_build_object('row_id', p_row_id, 'dump_folder', v_folder, 'effective_page', p_effective_page,
                              'kept_band', true, 'band_y0_pct', v_b0, 'band_y1_pct', v_b1);
  end if;

  if not exists (select 1 from derm.page_slots s
                  where s.dump_folder = v_folder and s.effective_page = p_effective_page) then
    raise exception 'Draw the bands on this page first. Then drop the stamp in its client''s row.'
      using detail = format('blocker=no_rows folder=%s page=%s', v_folder, p_effective_page);
  end if;

  -- the rows must describe the scan that is on the page now (a replaced scan moves every line)
  select sc.source_etag into v_rows_etag
    from derm.page_slots s
    join derm.page_rule_scans sc on sc.dump_folder = s.dump_folder and sc.effective_page = s.effective_page
                                and sc.source = s.source
   where s.dump_folder = v_folder and s.effective_page = p_effective_page
   limit 1;
  if v_wm is not null then
    v_img_etag := derm._img_etag((derm.ticket_page_images(v_wm))[p_effective_page]);
  end if;
  if v_rows_etag is not null and v_img_etag is not null and v_rows_etag <> v_img_etag then
    raise exception 'The scan of this page changed after the bands were drawn. Open Draw the bands and save the bands again.'
      using detail = format('blocker=rows_stale folder=%s page=%s', v_folder, p_effective_page);
  end if;

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

  -- taken = another placed stamp whose point is inside this row, whatever row number it carries
  select r2.id into v_other
    from derm.address_row_map r2
   where r2.dump_folder = v_folder
     and coalesce(r2.stamp_page, r2.page) = p_effective_page
     and r2.stamp_y_pct is not null
     and r2.id <> p_row_id
     and (r2.slot_index = v_slot or (r2.stamp_y_pct > v_y0 and r2.stamp_y_pct < v_y1))
   limit 1;
  if v_other is not null then
    raise exception 'That row already has %. Remove that stamp first, or drop this one in its own row.', derm._card_label(v_other)
      using detail = format('blocker=row_taken folder=%s page=%s slot=%s', v_folder, p_effective_page, v_slot);
  end if;

  perform derm.set_stamp_position(p_row_id, p_effective_page, p_x_pct, p_y_pct);

  update derm.address_row_map
     set slot_index  = v_slot,
         band_y0_pct = round(v_y0, 3),
         band_y1_pct = round(v_y1, 3),
         band_source = 'slot',
         band_set_at = now(),
         band_set_by = derm._actor('stamp-studio')
   where id = p_row_id;

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

-- ---------------------------------------------------------------------------------------------
-- 3. Save the bands.
--    Changed today after review:
--    * a stamp that already has a band KEEPS it (a reviewed band, a client's handwriting running
--      past the printed line, is never replaced by a redraw); only stamps without a band take
--      their row, and only they must sit alone inside one;
--    * when the scan on the page has a machine measurement (runlen-v2 or template-v1, not FAILED,
--      same image), the drawn rows are checked against it: no row may cross a printed line
--      between two clients. That is the independent check: until now human lines were only ever
--      graded against themselves;
--    * a page that is not in the sheet's image list, and a redraw refused on a page with a good
--      earlier scan, get plain sentences.
-- ---------------------------------------------------------------------------------------------
create or replace function derm.save_page_bands(p_dump_folder text, p_effective_page integer, p_source_url text,
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
  v_wm      text;
  v_npages  integer;
  v_etag    text;
  v_ref     text;
  -- 0.5pp, not the 0.35 of G9: measured 2026-10-05, a correct hand line on 836057 p1 sits 0.365pp from the
  -- template line (0.322 from the detector line). The cases this check exists for are 1pp and more off.
  v_tol     constant numeric := 0.5;
  v_top     numeric;
  v_bot     numeric;
begin
  perform derm._require_stamp_key();

  if p_dump_folder is null or p_effective_page is null then
    raise exception 'Something went wrong identifying this page. Reload the sheet and try again.'
      using detail = 'blocker=bad_arguments';
  end if;

  select r.white_manifest_number into v_wm from derm.address_row_map r
   where r.dump_folder = p_dump_folder and r.white_manifest_number is not null limit 1;
  if v_wm is not null then
    v_npages := coalesce(array_length(derm.ticket_page_images(v_wm), 1), 0);
    if p_effective_page < 1 or p_effective_page > v_npages then
      raise exception 'This page is no longer on the sheet. Reload the sheet.'
        using detail = format('blocker=no_such_page folder=%s page=%s pages=%s', p_dump_folder, p_effective_page, v_npages);
    end if;
  end if;

  v_rec := derm.record_page_rules(p_dump_folder, p_effective_page, v_src, p_source_url, p_rules,
                                  coalesce(p_meta, '{}'::jsonb) || '{"grade":"OK"}'::jsonb, false);
  if not coalesce((v_rec->>'wrote')::boolean, false) then
    raise exception '%', coalesce(nullif(v_rec->>'hint', ''),
                                  'These lines cannot be saved. Draw the two Limit bands and a client band on every printed line between them.')
      using detail = 'blocker=lines_refused ' || coalesce(v_rec->>'reject', v_rec->>'detail', v_rec->>'skipped', '');
  end if;

  select count(*), min(p.y0_pct), max(p.y1_pct) into v_rows, v_top, v_bot
    from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;
  if v_rows < 1 then
    raise exception 'Draw both Limit bands, the top and the bottom of Section B.'
      using detail = 'blocker=no_rows_formed';
  end if;

  -- the independent check: the machine measurement of THIS scan, when there is one
  v_etag := derm._img_etag(p_source_url);
  select s.source into v_ref
    from derm.page_rule_scans s
   where s.dump_folder = p_dump_folder and s.effective_page = p_effective_page
     and (s.source like 'runlen-v2-%' or s.source like 'template-v1-%')
     and s.grade <> 'FAILED'
     and ((s.source_etag is not null and s.source_etag = v_etag)
          or (s.source_etag is null and s.source_url = p_source_url))
   order by s.scanned_at desc
   limit 1;
  if v_ref is not null then
    if exists (select 1
                 from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
                 join derm.page_row_rules x on x.dump_folder = p_dump_folder and x.effective_page = p_effective_page
                                           and x.source = v_ref and x.kind = 'boundary'
                where x.rule_pct > p.y0_pct + v_tol and x.rule_pct < p.y1_pct - v_tol
                  -- the machine's first and last line are the edges of the list (or the form's
                  -- header/footer bar): a Limit drawn a little past them only reaches into the form
                  -- itself, never into another client's row (836057 p1, 0.4pp below the last line)
                  and x.rule_pct > (select min(y.rule_pct) from derm.page_row_rules y where y.dump_folder = p_dump_folder
                                      and y.effective_page = p_effective_page and y.source = v_ref and y.kind = 'boundary')
                  and x.rule_pct < (select max(y.rule_pct) from derm.page_row_rules y where y.dump_folder = p_dump_folder
                                      and y.effective_page = p_effective_page and y.source = v_ref and y.kind = 'boundary')) then
      raise exception 'A row you drew crosses a printed line between two clients. Put each band on a printed line: on the line between two clients, not inside a row.'
        using detail = format('blocker=row_crosses_printed_line folder=%s page=%s reference=%s', p_dump_folder, p_effective_page, v_ref);
    end if;
    -- NO Limit-coverage check against the reference: a machine scan can count the form's footer bar
    -- as a row line (measured on 836624 p1: 64.956), which would refuse a correct drawing. A Limit
    -- that leaves a printed row out is covered instead by the never-narrow rule in
    -- _write_page_extent_from_slots on every page that already has a blackout area.
  end if;

  -- stamps WITHOUT a band take the row their point sits in; they must sit alone inside one
  create temp table if not exists _spb_cards (id bigint, k integer, banded boolean) on commit drop;
  truncate _spb_cards;
  insert into _spb_cards
  select r.id,
         (select p.slot_index from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
           where r.stamp_y_pct >= p.y0_pct and r.stamp_y_pct <= p.y1_pct
           order by p.slot_index desc limit 1),
         (r.band_y0_pct is not null and r.band_y1_pct is not null)
    from derm.address_row_map r
   where r.dump_folder = p_dump_folder
     and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.stamp_y_pct is not null and r.stamp_placed_at is not null;

  select string_agg(derm._card_label(id), ', ' order by id) into v_bad from _spb_cards where not banded and k is null;
  if v_bad is not null then
    raise exception 'The stamp of % is outside the new rows. Move it into its row, or remove it, then save the bands again.', v_bad
      using detail = 'blocker=stamp_outside_rows';
  end if;
  select string_agg(labels, '; ') into v_bad
    from (select string_agg(derm._card_label(c.id), ' and ' order by c.id) as labels
            from _spb_cards c
           where c.k is not null
             and (not c.banded or exists (select 1 from _spb_cards o where o.k = c.k and not o.banded))
           group by c.k having count(*) > 1 and bool_or(not c.banded)) d;
  if v_bad is not null then
    raise exception '% are in the same row. Each client needs its own row: move one stamp, then save the bands again.', v_bad
      using detail = 'blocker=two_stamps_one_row';
  end if;

  delete from derm.page_slots where dump_folder = p_dump_folder and effective_page = p_effective_page;
  insert into derm.page_slots (dump_folder, effective_page, slot_index, y0_pct, y1_pct, source, set_by)
  select p_dump_folder, p_effective_page, p.slot_index, p.y0_pct, p.y1_pct, p.source, v_actor
    from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;

  -- only unbanded stamps are banded; a banded stamp keeps its band and carries a row number only
  -- when that band IS the row
  update derm.address_row_map r
     set slot_index = c.k,
         band_y0_pct = round(s.y0_pct, 3), band_y1_pct = round(s.y1_pct, 3),
         band_source = 'slot', band_set_at = now(), band_set_by = v_actor
    from _spb_cards c
    join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page and s.slot_index = c.k
   where r.id = c.id and not c.banded;
  update derm.address_row_map r
     set slot_index = case when round(s.y0_pct, 3) = r.band_y0_pct and round(s.y1_pct, 3) = r.band_y1_pct then c.k end
    from _spb_cards c
    left join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page
                               and s.slot_index = c.k
   where r.id = c.id and c.banded
     and r.slot_index is distinct from (case when round(s.y0_pct, 3) = r.band_y0_pct and round(s.y1_pct, 3) = r.band_y1_pct
                                             then c.k end);
  select count(*) into v_cards from _spb_cards;

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
                            'lines', v_rec->'rules_written', 'checked_against', v_ref, 'extent', v_ext);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 4. The writers the Studio no longer calls are taken away from staff sessions. An old tab could
--    still call them and write lines or bands around every new check. SECURITY DEFINER callers
--    (save_page_bands, the generated-sheet finisher) run as owner and are unaffected.
-- ---------------------------------------------------------------------------------------------
revoke execute on function derm.record_page_rules(text, integer, text, text, jsonb, jsonb, boolean) from authenticated;
revoke execute on function derm.save_page_slots(text, integer) from authenticated;
revoke execute on function derm.assign_card_to_slot(bigint, integer, integer) from authenticated;
revoke execute on function derm.set_row_band(bigint, numeric, numeric) from authenticated;
revoke execute on function derm.save_page_geometry(text, integer, jsonb, numeric, numeric) from authenticated;

do $verify$
declare v_err text; v_rules jsonb; v_ref text;
begin
  if has_function_privilege('authenticated', 'derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.save_page_geometry(text,integer,jsonb,numeric,numeric)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.save_page_slots(text,integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.assign_card_to_slot(bigint,integer,integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'derm.set_row_band(bigint,numeric,numeric)', 'EXECUTE') then
    raise exception 'VERIFY: an old writer is still executable by staff'; end if;
  if not has_function_privilege('authenticated', 'derm.save_page_bands(text,integer,text,jsonb,jsonb)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'derm.place_stamp_in_row(bigint,integer,numeric,numeric)', 'EXECUTE') then
    raise exception 'VERIFY: the new writes lost their grant'; end if;
  -- the half-row shift on 836624 p1 is refused
  select s.source into v_ref from derm.page_rule_scans s where s.dump_folder = 'ticket-836624' and s.effective_page = 1
     and s.source like 'runlen-v2-%' and s.grade <> 'FAILED' order by s.scanned_at desc limit 1;
  select jsonb_agg(jsonb_build_object('pct', rule_pct, 'run', coalesce(run_frac, 0.35), 'ink', ink_frac, 'kind', 'boundary') order by rule_pct)
    into v_rules
    from derm.page_row_rules where dump_folder = 'ticket-836624' and effective_page = 1 and source = v_ref and kind = 'divider';
  begin
    perform derm.save_page_bands('ticket-836624', 1, (derm.ticket_page_images('836624'))[1], v_rules, '{}');
    raise exception 'VERIFY: the half-row shift was accepted';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'A row you drew crosses a printed line%' then raise exception 'VERIFY half-row: %', v_err; end if;
  end;
end $verify$;

commit;
