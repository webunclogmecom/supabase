-- 2026-11-15_1350_derm_save_page_bands_slot_band_follows_row.sql
--
-- THE RULE NOW
-- ------------
-- When a page's lines are saved (derm.save_page_bands: "Save the bands" on the portal's stamping screen AND on the old
-- Stamp host, which call the same function), a card whose band was TAKEN FROM A ROW (band_source = 'slot') is treated like
-- a card with no band: it takes the row its stamp sits in (both bounds and slot_index), so the band follows that row when
-- a line moves, and the client's copy is remade to match by the usual path (a moved band reopens the sheet; Mark completed
-- and the copy sweep do the rest). A band drawn by hand for one client (any other band_source) stays exactly as drawn, as
-- before. A 'slot' card now also counts like a card with no band in both refusals of the save: a stamp outside every new
-- row is refused ("The stamp of ... is outside the new rows"), and two stamps in one row are refused.
--
-- WHY
-- ---
-- Fred's drag test on test ticket #111111 (2026-11-15, 12:16 to 12:17 ET, from the portal: "done, I dragged the card and the
-- line"). He moved the line under the 112-YA row (card 3051) from 32.588 to 34.352. The card's band stayed 23.882..32.588 and
-- its slot_index went 1 -> NULL, because this function banded only a card with no band ("only unbanded stamps are banded; a
-- banded stamp keeps its band and carries a row number only when that band IS the row"). Asked whether a band taken from a
-- row should follow that row when its line moves, the recommended choice read: "A card whose band came from its row (not
-- drawn by hand) moves with that row when a line is saved, and its copy is remade to match. A band someone drew by hand for
-- one client stays as drawn. One database change, rehearsed with a control; old host and portal both get it, since they
-- share the save." He picked:
--     "Follow the row (Recommended)"
-- (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-12-manifests-and-stamping.md, last section.)
--
-- "TAKEN FROM A ROW" IS band_source = 'slot', BY EVIDENCE (read 2026-11-15 13:45 ET)
-- -------------------------------------------------------------------------------------
--   Writers of 'slot': derm.place_stamp_in_row (a stamp dropped into a row: band = the row), this function (a stamp with no
--     band takes its row) and derm.assign_card_to_slot (no app calls it since 2026-10-05).
--   Writers of 'manual': derm.save_page_geometry (the hand rectangle; also the replay inside
--     derm._write_page_extent_from_slots, which writes only a band whose value moved, so a save never turns 'slot' into
--     'manual') and derm.set_row_band (0 app calls). Every other value is a one-time repair or migration of July to September
--     2026 with no live writer: ocr-v2-snap 419, NULL 128 (7 with a band), claude-rulesnap-2026-08-20 56,
--     vision-repair-2026-07-11 36, claude-rulesnap-2026-08-19 28, leak-fix 26, ocr-v1 21, runlen-snap-* 26,
--     claude-tilingfit-2026-08-20 9, vision-* 21, claude-leakfix-2026-08-21 4. None of them carries a slot_index.
--   'slot' today: 63 cards on 16 sheets, all stamped, all on completed sheets; 62 with a row number (the 63rd is card 3051).
--   A correction to the brief: "a second look" (pick J) is not a band source. It lets a person save uneven LINES
--     (page_rule_scans.detail); the cards of that save take their rows as 'slot', like Fred's card on #111111.
--   So: 'slot' follows its row; 'manual' and every older value stay as drawn (unchanged behaviour).
--
-- A STAMP OUTSIDE EVERY NEW ROW: REFUSED, LIKE A CARD WITH NO BAND (the choice, and why)
-- --------------------------------------------------------------------------------------
--   The other choice was today's: keep the old band and clear the row number. Refusing is chosen because:
--   * it never widens a copy: a kept band would be a band that is no row of the page any more;
--   * it costs nothing measured: re-saving every page that holds a 'slot' card with its current lines, 0 of 63 'slot'
--     stamps sit outside every row (and 0 against the saved rows);
--   * the rows tile the Limit, so a stamp outside every row is outside the Limit, and the old body refused that save
--     anyway one step later (G8, "A Limit band cuts through a client row"; the check's S4 on the old body); the save now
--     stops earlier with the sentence that tells the person what to do;
--   * the portal's stamping screen already refuses, before it calls the server, any stamp outside the two Limit bands.
--
-- PRIVACY (the reason a 'slot' card counts as unbanded in the refusals)
-- ---------------------------------------------------------------------
--   A band taken from a row can never grow into a row another card holds: two stamps in one new row are refused, whatever
--   the other card's band (S3 slot + slot, S3b slot + hand-drawn), and a row that would overlap another card's band is
--   refused by the geometry guard the save already runs (G7 no overlap, absolute, over every stamped card of the page,
--   G7b for a withheld card; S5). The old body let two stamps share a printed row when both had bands (S3 and S3b saved
--   there, the second band reaching into the first card's row).
--
-- WHAT (five anchored edits of the LIVE body, md5 3858d1442a0b15b90714c26ef9e4e1d7 read 13:41 ET, each matched once)
-- ----
--   E1 a comment over the card list.
--   E2 _spb_cards.banded gains  and r.band_source is distinct from 'slot'  (the rule; it feeds both refusals and both
--      updates).
--   E3 a comment over the two updates.
--   E4 the banding update skips a card whose band is already its row (no write of band_y0_pct: mentioning it fires
--      derm.fn_dirty_on_card_change, which would reopen a completed sheet for nothing). Before E2 such a card was "banded"
--      and only its row number was written; E4 keeps exactly that.
--   E5 the row-number update reads every card (it dropped "and c.banded"): it now also gives the row number to a 'slot' card
--      that E4 skipped. For a card the banding update just wrote it is a no-op (its row number is already set).
--   Everything else byte for byte: header, SECURITY DEFINER, search_path, the access check and stamp key, record_page_rules,
--   the independent check, the refusal sentences, page_slots, the Limit through _write_page_extent_from_slots. Grants,
--   owner and volatility unchanged (CREATE OR REPLACE): {postgres=X,authenticated=X,service_role=X}.
-- Audit (rule 8): no table changes, no column changes, no rows written by this file: a function body only. The rows the
--   function writes land in derm.address_row_map, derm.page_slots and derm.page_block_extents, all audited, as before.
-- Both hosts: the old Stamp host (stamp.unclogme.app) and the portal (ops.unclogme.app/stamp) call this function, so both
--   get the rule with no app change. The portal's screen refuses two stamps in one strip before calling; the old host
--   relies on this function.
--
-- NO BACKFILL (on purpose)
-- ------------------------
--   Writing a band on a completed sheet reopens it (derm.fn_dirty_on_card_change), so the rule acts at the next band save
--   of a page only. Reach, read only, 2026-11-15 13:46 ET:
--   * against the saved rows (derm.page_slots): ONE card has a 'slot' band that is not the row its stamp sits in, card 3051
--     on #111111 (completed; band 23.882..32.588, its row 23.882..34.352 since Fred's drag);
--   * against the lines a re-save would send (derm.fn_page_slots_preview, the page's current lines): 5 cards on 2 sheets,
--     both completed: card 3051, and the four cards of ticket-934861 page 1, whose rows were saved 2026-09-09 16:36 ET from
--     lines that were recorded again under the same source six minutes later; the current lines sit 0.13 to 0.24 points
--     off the saved rows. They move only if someone saves that page's lines again, which moves its Limit too (26.906 ->
--     26.772) and so reopens the sheet under either body.
--   * re-saving every page holding a 'slot' card with its current lines: 0 stamps outside every row and 0 two-in-one-row
--     refusals, under the old body and the new one alike.
--
-- REHEARSED: see the REHEARSED block at the end of this header.
-- Rollback: 2026-11-15_rollback_derm_save_page_bands_slot_band_follows_row.sql (the old body byte for byte).
-- Standing check: scripts/checks/stamp_slot_band_follows_row.mjs (rolled back; CONTROL=1 puts the old body back and S1
--   must FAIL; APPLY=1 runs this file first, for a rehearsal before it is applied).
-- Locks: CREATE OR REPLACE FUNCTION locks no table and blocks no reader; the transaction holds the DDL and the md5 and
--   grant checks only. The fixtures run in the standing check, rolled back, never in this transaction.
--
-- REHEARSED (BEGIN ... ROLLBACK on Prod, 2026-11-15 13:53 ET, through the standing check: APPLY=1 runs this file's
-- BEGIN..COMMIT body, CONTROL=1 then runs the rollback file's, in the same transaction). Cases on #111111 page 1, as a
-- signed-in Stamp editor with the Studio key, machine reference scans removed inside the transaction:
--                                                              NEW body                 OLD body (control)
--   S1 'slot' band 23.882..32.588, line moved to 33.0          band 23.882..33.0, row 1  band kept, row cleared  <- FAILS
--   S2 hand-drawn band, same lines                             kept as drawn, no row     kept as drawn, no row
--   S3 + a second 'slot' card whose stamp falls in that row    refused two_stamps_one_row saved                  <- FAILS
--   S3b the second card's band drawn by hand                   refused two_stamps_one_row saved                  <- FAILS
--   S4 top Limit moved below the 'slot' card's stamp           refused stamp_outside_rows refused geometry (G8)  <- FAILS
--   S5 the moved row would overlap a hand-drawn band below     refused geometry (G7)     saved                   <- FAILS
--   S6 'slot' band already on its row, sheet completed         row 1 back, band not      the same
--                                                              rewritten, still completed
--   After every case no two stamped cards of the page overlap; the city email of 2017 and 2020 identical.
--   S6 bites: the new body WITHOUT edit E4 (a one-off mutant) FAILS S6 (it rewrites the band and reopens the sheet).
--   Both VERIFY blocks passed in that run (md5 3858d144 -> 321ff35f -> 3858d144, grants unchanged).
--   The standing check on the OLD live body before this file: S1, S3, S3b, S4, S5 FAIL; S2, S6, CITY pass.
-- APPLIED 2026-11-15 13:56:59 ET (first attempt, 0.9 s; the name is earlier than the apply time). md5 read back 321ff35f,
-- grants unchanged. NOTHING ELSE MOVED, measured read-only right before (13:56:37 ET) and right after (13:57:00 ET):
--   derm.v_blackout_blocked_sheets (2 rows), fn_sheet_publishable for all 189 sheets, derm.fn_manifest_row_states_core()
--   180 of 180 rows, derm.v_blackout_completed_unpublished (ticket-836361), fn_blackout_targets(50) (none), and the md5 of
--   every card (1,013), status row (171), copy row (858), page_slots per sheet (21) and extent (226): all identical; city
--   email 2017 already_sent, 2020 awaiting_manual_send, 7 sends. (net.http_request_queue read 1 once, a passing cron
--   request, empty again seconds later.)
-- LIVE PROOF on test ticket #111111 (test client 112-YA), 13:59:17 ET, as Fred (claims of fred@ayache.com, the Studio key,
--   no app label, so audit.logs reads app_source 'sql' with his email), ONE transaction: derm.set_sheet_completed(false),
--   derm.save_page_bands of page 1 with its CURRENT six lines unchanged (23.882 34.352 39.569 47.255 55.412 63.412, the
--   lines Fred saved at 12:17 ET after his own second look; second_look was sent again with them, since at 20 percent
--   they are refused), derm.set_sheet_completed(true):
--   card 3051: band 23.882..32.588 slot_index NULL -> 23.882..34.352 slot_index 1, still 'slot', set by fred@ayache.com;
--   the sheet completed again (fn_sheet_publishable NULL before and after); manifest 2017's copy remade by the sweep 2 s
--   after the completion (derm.redacted_manifest_docs band_y1 32.588 -> 34.352, fingerprint 26e86600 -> 4798a092,
--   blocks_bottom 63.412 unchanged); 2020's copy untouched; city email unchanged (2017 already_sent, 2020
--   awaiting_manual_send, 7 sends). Nothing else moved (the same comparison after it): only card 3051, #111111's
--   page_slots (rewritten with the same bounds), its status row and 2017's copy row differ; the Manifests rows core 180 of
--   180 identical; no extent moved.
--   Checks after: stamp_slot_band_follows_row ALL PASS (CONTROL=1: S1, S3, S3b, S4, S5 FAIL); stamp_partial_copies ALL PASS
--   (it read UNKNOWN since Fred's drag took card 3051's row number); stamp_blocked_list_unlinked_card ALL PASS;
--   stamp_bands_second_look ALL PASS once its premise reads the rows of Fred's drag (34.352), CONTROL=1 fails C2 and G.

BEGIN;
SET LOCAL lock_timeout = '3s';

-- GUARD: the live body this was generated from (md5 in the replace(..., chr(13), '') form, read 2026-11-15 13:41 ET)
DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure), chr(13), '')) <> '3858d1442a0b15b90714c26ef9e4e1d7'
    THEN RAISE EXCEPTION 'GUARD: derm.save_page_bands changed since it was read (read 2026-11-15 13:41 ET)'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION derm.save_page_bands(p_dump_folder text, p_effective_page integer, p_source_url text, p_rules jsonb, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
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
  perform hr.fn_check_app('stamp_studio', 'edit', 'save the bands');   -- 2026-10-20_1700 access phase 4
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
     -- 2026-10-05 (background measuring): only a measurement graded OK is trusted as the reference; an
     -- IRREGULAR or SPARSE one can mislabel lines (934861 p1 measured with no window)
     and s.grade = 'OK'
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
  -- 2026-11-15 (Fred, "Follow the row"): a band TAKEN FROM A ROW (band_source 'slot') counts as NO band here, so it
  -- follows the row its stamp sits in, a stamp outside every new row is refused, and it counts in the two-in-one-row
  -- refusal; a band drawn for one client (any other band_source) stays exactly as drawn
  create temp table if not exists _spb_cards (id bigint, k integer, banded boolean) on commit drop;
  truncate _spb_cards;
  insert into _spb_cards
  select r.id,
         (select p.slot_index from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
           where r.stamp_y_pct >= p.y0_pct and r.stamp_y_pct <= p.y1_pct
           order by p.slot_index desc limit 1),
         (r.band_y0_pct is not null and r.band_y1_pct is not null and r.band_source is distinct from 'slot')
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
  -- (2026-11-15: a 'slot' band counts as unbanded, see above; the row-number statement reads every card)
  update derm.address_row_map r
     set slot_index = c.k,
         band_y0_pct = round(s.y0_pct, 3), band_y1_pct = round(s.y1_pct, 3),
         band_source = 'slot', band_set_at = now(), band_set_by = v_actor
    from _spb_cards c
    join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page and s.slot_index = c.k
   where r.id = c.id and not c.banded
     -- a band already on its row is not written again: mentioning band_y0_pct fires derm.fn_dirty_on_card_change,
     -- which would reopen a completed sheet for nothing. The statement below gives such a card its row number.
     and (r.band_y0_pct is distinct from round(s.y0_pct, 3) or r.band_y1_pct is distinct from round(s.y1_pct, 3));
  update derm.address_row_map r
     set slot_index = case when round(s.y0_pct, 3) = r.band_y0_pct and round(s.y1_pct, 3) = r.band_y1_pct then c.k end
    from _spb_cards c
    left join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page
                               and s.slot_index = c.k
   where r.id = c.id
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
$function$
;

-- VERIFY: cheap only (md5, grants, owner and settings). The behaviour is proved by the standing check, rolled back.
DO $v$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure), chr(13), '')) <> '321ff35fb811c44b25571a9f90290439'
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands is not the rehearsed body (new)'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands grants moved'; END IF;
  IF NOT (SELECT prosecdef AND pg_get_userbyid(proowner) = 'postgres' AND proconfig = ARRAY['search_path=derm, public']
            FROM pg_proc WHERE oid = 'derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure)
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands owner, SECURITY DEFINER or search_path moved'; END IF;
END $v$;

COMMIT;
