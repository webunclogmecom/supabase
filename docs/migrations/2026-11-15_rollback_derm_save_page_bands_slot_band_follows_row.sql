-- 2026-11-15_rollback_derm_save_page_bands_slot_band_follows_row.sql
--
-- Puts back derm.save_page_bands exactly as it was before 2026-11-15_1350_derm_save_page_bands_slot_band_follows_row.sql
-- (the live body read 2026-11-15 13:41 ET, byte for byte; md5 3858d1442a0b15b90714c26ef9e4e1d7). After it a band taken from a row stays where it was
-- when the page's lines are saved again, and only its row number is cleared (Fred's drag test on #111111).
-- Rehearsed in the same rolled-back run as the migration (see the migration's REHEARSED block).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure), chr(13), '')) <> '321ff35fb811c44b25571a9f90290439'
    THEN RAISE EXCEPTION 'GUARD: derm.save_page_bands changed since it was read (expected the body of 2026-11-15_1350)'; END IF;
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
$function$
;

DO $v$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure), chr(13), '')) <> '3858d1442a0b15b90714c26ef9e4e1d7'
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands is not the rehearsed body (old)'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands grants moved'; END IF;
  IF NOT (SELECT prosecdef AND pg_get_userbyid(proowner) = 'postgres' AND proconfig = ARRAY['search_path=derm, public']
            FROM pg_proc WHERE oid = 'derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure)
    THEN RAISE EXCEPTION 'VERIFY: derm.save_page_bands owner, SECURITY DEFINER or search_path moved'; END IF;
END $v$;

COMMIT;
