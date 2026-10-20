-- Rollback of 2026-10-20_1700_hr_access_watch_derm_and_stamp: puts back the 22 bodies and hr.check_app_action exactly as read on 2026-10-20, drops the four
-- public.derm_* write functions (the DERM Tracker build that calls them must be reverted FIRST, or its saves fail),
-- and sets derm_tracker and stamp_studio back to off. hr.access_refusals rows are kept (the record).
BEGIN;
SET LOCAL lock_timeout = '3s';
UPDATE hr.access_apps SET mode = 'off' WHERE app IN ('derm_tracker', 'stamp_studio');
CREATE OR REPLACE FUNCTION derm.add_client_card_and_link(p_dump_folder text, p_page integer, p_client_id bigint, p_visit_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_wm text; v_row bigint; v_vcid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_client_id IS NULL THEN RAISE EXCEPTION 'p_client_id required'; END IF;
  IF p_visit_id IS NULL THEN RAISE EXCEPTION 'p_visit_id required'; END IF;

  -- visit must exist, be live, and belong to this client
  SELECT client_id INTO v_vcid FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN RAISE EXCEPTION 'visit % not found or deleted', p_visit_id; END IF;
  IF v_vcid <> p_client_id THEN
    RAISE EXCEPTION 'visit % belongs to a different client than %', p_visit_id, p_client_id;
  END IF;

  SELECT max(white_manifest_number) INTO v_wm FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_wm IS NULL THEN RAISE EXCEPTION 'unknown sheet %', p_dump_folder; END IF;

  -- reuse the client's existing card on this sheet if present, else create one now
  SELECT id INTO v_row FROM derm.address_row_map
    WHERE dump_folder = p_dump_folder AND matched_client_id = p_client_id
    ORDER BY id LIMIT 1;
  IF v_row IS NULL THEN
    v_row := derm.add_sheet_client(p_dump_folder, COALESCE(p_page, 1), p_client_id, NULL);
  END IF;

  -- file the manifest if needed (inherits shared docs) + link the visit + point the card
  PERFORM derm.file_manifest_and_link(v_row, p_visit_id);
  RETURN v_row;
END $function$;

CREATE OR REPLACE FUNCTION derm.add_extra_client_card(p_dump_folder text, p_client_id bigint, p_page integer DEFAULT 1)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_wm text; v_existing derm.address_row_map%rowtype;
  v_next int; v_new_id bigint; v_gdo bigint; v_img text;
begin
  perform derm._require_stamp_key();
  if p_client_id is null then raise exception 'p_client_id required'; end if;

  select max(white_manifest_number) into v_wm
    from derm.address_row_map where dump_folder = p_dump_folder;
  if v_wm is null then raise exception 'unknown sheet %', p_dump_folder; end if;

  select * into v_existing from derm.address_row_map
   where dump_folder = p_dump_folder and matched_client_id = p_client_id
   order by id limit 1;
  if not found then
    raise exception 'client % is not on sheet % yet — use add_client_card_and_link first',
      p_client_id, p_dump_folder;
  end if;

  -- 🛑 The permit-selection below decides what is UNCLAIMED by looking for cards that already
  -- carry a gdo_id. If any of this client's existing cards on this sheet has a NULL gdo_id we
  -- cannot know which permit it represents, and the "next unclaimed" answer is a guess that
  -- silently hands out the FIRST permit again. Measured 2026-08-27: that is the state of all four
  -- multi-permit cards in the estate (242-WYN@ticket-833395, 043-MIL@ticket-832194,
  -- 009-CN@ticket-312433, 009-CN@ticket-830714), so this was fail-OPEN on 100% of the rows it
  -- would ever be used on. Refuse instead: bind the existing card first.
  if exists (select 1 from derm.address_row_map r0
              where r0.dump_folder = p_dump_folder
                and r0.matched_client_id = p_client_id
                and r0.gdo_id is null) then
    raise exception 'client % on sheet % has a card with no gdo_id; bind it to its permit before '
                    'adding another, or the next card would duplicate the first permit',
      p_client_id, p_dump_folder;
  end if;

  -- the client's next ACTIVE permit not already claimed by a card on this sheet
  select g.id into v_gdo
    from public.gdos g
   where g.client_id = p_client_id
     and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
     and not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = p_dump_folder and r2.gdo_id = g.id)
   order by g.gdo_number
   limit 1;

  select coalesce(max(row_index), 0) + 1 into v_next
    from derm.address_row_map
   where dump_folder = p_dump_folder and page = coalesce(p_page, 1);

  -- 🛑 2026-09-03: was `v_existing.image_url`, i.e. whatever image the client's FIRST card on
  -- this sheet carries, written at coalesce(p_page,1). When those two pages differ that is the
  -- ticket-834742 defect shape. Resolve the image THAT page carries instead.
  v_img := derm.fn_page_image_url(p_dump_folder, coalesce(p_page, 1));
  if v_img is null then
    raise exception 'page % of sheet % has no scan on file, so a card cannot be added to it',
      coalesce(p_page, 1), p_dump_folder;
  end if;

  insert into derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     matched_client_id, matched_manifest_id, gdo_id, assignment_status, confidence, source, flags)
  values
    (p_dump_folder, v_wm, coalesce(p_page, 1), v_next, v_img,
     p_client_id, v_existing.matched_manifest_id, v_gdo, 'matched', 'high',
     'extra-stamp', '{"extra_stamp":true}'::jsonb)
  returning id into v_new_id;

  return v_new_id;
end $function$;

CREATE OR REPLACE FUNCTION derm.add_sheet_client(p_dump_folder text, p_page integer, p_client_id bigint DEFAULT NULL::bigint, p_custom_code text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_wm text; v_img text; v_next int; v_fac text; v_addr text; v_id bigint; v_mid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_client_id IS NULL AND (p_custom_code IS NULL OR btrim(p_custom_code) = '') THEN
    RAISE EXCEPTION 'provide p_client_id or a non-empty p_custom_code';
  END IF;
  SELECT max(white_manifest_number) INTO v_wm FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_wm IS NULL THEN RAISE EXCEPTION 'unknown sheet %', p_dump_folder; END IF;
  -- 🛑 2026-09-03: the old fallback here was `min(image_url) OVER THE WHOLE FOLDER`, i.e.
  -- page 1's image, inserted at the caller's p_page. That is the ticket-834742 defect shape and
  -- it is reachable by an operator: adding a client on page 2 of a folder whose cards are all
  -- on page 1 wrote (page 2, address_1) and duplicated the image list. Resolve the image THAT
  -- page carries, and refuse rather than borrow another page's.
  v_img := derm.fn_page_image_url(p_dump_folder, p_page);
  IF v_img IS NULL THEN
    RAISE EXCEPTION 'page % of sheet % has no scan on file, so a card cannot be added to it',
      p_page, p_dump_folder;
  END IF;
  SELECT coalesce(max(row_index), 0) + 1 INTO v_next FROM derm.address_row_map WHERE dump_folder = p_dump_folder AND page = p_page;
  IF p_client_id IS NOT NULL THEN
    SELECT c.name, (SELECT p.address FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1)
      INTO v_fac, v_addr FROM public.clients c WHERE c.id = p_client_id;
    IF v_fac IS NULL THEN RAISE EXCEPTION 'unknown client id %', p_client_id; END IF;
    -- resolve this client's manifest for the sheet's TICKET (white or yellow keyed), if filed
    SELECT dm.id INTO v_mid FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.client_id = p_client_id
       AND dm.deleted_at IS NULL
     LIMIT 1;
  ELSE
    v_fac := btrim(p_custom_code);
  END IF;
  INSERT INTO derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     facility_name_read, address_read, matched_client_id, matched_manifest_id, manual_code,
     assignment_status, confidence, source, flags, created_at, updated_at)
  VALUES
    (p_dump_folder, v_wm, p_page, v_next, v_img,
     v_fac, v_addr, p_client_id, v_mid, CASE WHEN p_client_id IS NULL THEN btrim(p_custom_code) END,
     'matched', 'high', 'stamp-studio', '{"manual_add":true}'::jsonb, now(), now())
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

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
END $function$;

CREATE OR REPLACE FUNCTION derm.get_visit_report(p_visit_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_public_id     text;
  v_client_id     bigint;
  v_derm_required boolean;
  v_out           jsonb;
BEGIN
  IF nullif(current_setting('request.jwt.claims', true), '') IS NOT NULL
     AND coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'authentication required' USING errcode = '28000';
    END IF;
    IF lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@ayache.com'
       AND lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@unclogme.com' THEN
      RAISE EXCEPTION 'not a staff account' USING errcode = '42501';
    END IF;
  END IF;

  SELECT v.public_id, v.client_id, coalesce(v.derm_required, true)
    INTO v_public_id, v_client_id, v_derm_required
    FROM public.visits v
   WHERE v.id = p_visit_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.client_id IS NOT NULL;
  IF v_public_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_out := customer.get_work_order_internal(v_public_id);
  IF v_out IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_out || jsonb_build_object(
    'client', (SELECT to_jsonb(c) FROM customer.clients c
                WHERE c.id = customer.uuid_from_bigint(v_client_id)
                LIMIT 1),  -- ponytail: LIMIT 1 guards a future duplicate row in customer.clients (0 today)
    'derm_required', v_derm_required);
END
$function$;

CREATE OR REPLACE FUNCTION derm.link_row_visit(p_row_id bigint, p_visit_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_mid bigint; v_cid bigint; v_vcid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  SELECT matched_manifest_id, matched_client_id INTO v_mid, v_cid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest for this client on this sheet — file it in DERM Tracker first', p_row_id;
  END IF;
  -- FIX: a row with no matched client must never link a visit (previously the
  -- cross-client guard was silently skipped when v_cid IS NULL).
  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'row % has no matched client — cannot link a visit', p_row_id;
  END IF;
  SELECT client_id INTO v_vcid FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN RAISE EXCEPTION 'visit % not found / deleted', p_visit_id; END IF;
  IF v_vcid <> v_cid THEN
    RAISE EXCEPTION 'visit % belongs to a different client than row %', p_visit_id, p_row_id;
  END IF;
  INSERT INTO public.manifest_visits (manifest_id, visit_id)
  VALUES (v_mid, p_visit_id)
  ON CONFLICT DO NOTHING;
END $function$;

CREATE OR REPLACE FUNCTION derm.place_stamp_in_row(p_row_id bigint, p_effective_page integer, p_x_pct numeric, p_y_pct numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
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

CREATE OR REPLACE FUNCTION derm.remove_sheet_client(p_row_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  DELETE FROM derm.address_row_map WHERE id = p_row_id AND source = 'stamp-studio';
  IF NOT FOUND THEN RAISE EXCEPTION 'row % is not a manually-added card (cannot remove)', p_row_id; END IF;
END $function$;

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
$function$;

CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  -- 🛑 COMPLETION IS A STATEMENT ABOUT THE GEOMETRY. A sheet that cannot be blacked out must not
  -- be markable complete (Fred, 2026-09-03: "if it's marked as complete then after 5 min it needs a
  -- blackout. period, if not then it can't be marked as complete").
  IF p_completed THEN
    v_block := derm.fn_sheet_publishable(p_dump_folder);
    IF v_block IS NOT NULL THEN
      -- 2026-09-14 (Fred): what an operator reads must be plain language with no technical words.
      -- The blocker CODE and the folder go to DETAIL, which the app never shows; the MESSAGE is the
      -- same page-aware sentence the header banner already shows, so the two never disagree.
      RAISE EXCEPTION 'This sheet cannot be marked complete yet. %',
        COALESCE(derm.fn_sheet_publishable_detail(p_dump_folder)->>'message', derm.fn_publishable_hint(v_block))
        USING DETAIL = 'blocker=' || v_block || ' folder=' || p_dump_folder;
    END IF;
  END IF;
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, p_completed,
          CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END,
          now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    completed    = EXCLUDED.completed,
    completed_at = CASE WHEN EXCLUDED.completed THEN now() ELSE NULL END,
    completed_by = CASE WHEN EXCLUDED.completed THEN EXCLUDED.completed_by ELSE NULL END,
    updated_at   = now();
END $function$;

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
END $function$;

CREATE OR REPLACE FUNCTION derm.unlink_row_visit(p_row_id bigint, p_visit_id bigint, OUT was_last boolean, OUT remaining integer)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_mid bigint;
BEGIN
  PERFORM derm._require_stamp_key();                       -- same gate as link
  SELECT matched_manifest_id INTO v_mid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest — nothing to unlink', p_row_id;
  END IF;
  DELETE FROM public.manifest_visits                       -- hard delete, idempotent
   WHERE manifest_id = v_mid AND visit_id = p_visit_id;
  SELECT count(*) INTO remaining
    FROM public.manifest_visits WHERE manifest_id = v_mid;
  was_last := (remaining = 0);
END $function$;

CREATE OR REPLACE FUNCTION public.detach_manifest_document(p_manifest_id bigint, p_kind text, p_url text, p_reason text)
 RETURNS TABLE(out_ticket_number text, out_kind text, out_url text, out_rows_touched integer, out_remaining text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm', 'pg_temp'
AS $function$
declare
  v_kind   text := lower(btrim(p_kind));
  v_url    text := btrim(p_url);
  v_ticket text;
  v_before text[];
  v_after  text[];
  v_rows   integer := 0;
  v_actor  text;
begin
  if p_manifest_id is null then
    raise exception 'A manifest is required.' using errcode = '22023';
  end if;
  if v_kind not in ('address','manifest') then
    raise exception 'kind must be address or manifest, got %.', coalesce(quote_literal(p_kind),'NULL')
      using errcode = '22023';
  end if;
  if coalesce(v_url,'') = '' then
    raise exception 'The document to detach must be named by its URL.' using errcode = '22023';
  end if;
  if coalesce(p_reason,'') !~ '[[:alnum:]]' then
    raise exception 'A reason is required, and it must say something.' using errcode = '22023';
  end if;

  -- Resolve the TICKET, not the row. edit_manifest replicates the document arrays across
  -- every live row of a ticket, so a per-row detach would leave the ticket internally
  -- inconsistent and the next save would put the URL straight back from a sibling.
  select coalesce(dm.white_manifest_number, dm.yellow_ticket_number)
    into v_ticket
    from public.derm_manifests dm
   where dm.id = p_manifest_id and dm.deleted_at is null;

  if v_ticket is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- (*) Lock BEFORE reading the before-set, in a deterministic order. Two operators on one
  -- ticket would otherwise both pass their checks and the later write would silently undo
  -- the earlier. Same reasoning as the edit_manifest containment guard.
  perform 1
     from public.derm_manifests dm
    where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
      and dm.deleted_at is null
    order by dm.id
      for update;

  -- The ticket's whole document set for this kind. FILTER (WHERE ...) rather than
  -- array_remove(arr, NULL): nothing equals NULL, so array_remove does NOT remove NULLs
  -- and every downstream comparison would come back NULL and fail open.
  select coalesce(array_agg(distinct u) filter (where u is not null and u <> ''), array[]::text[])
    into v_before
    from public.derm_manifests dm
    cross join lateral unnest(
      case when v_kind = 'address'
           then array[dm.derm_address_url]  || coalesce(dm.derm_address_extra_urls,  array[]::text[])
           else array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[])
      end) as u
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
     and dm.deleted_at is null;

  -- (*) Refuse a document the ticket does not hold. A stale modal must not report a
  -- successful removal of something that was already gone -- that is how an operator comes
  -- to believe they acted. Same reasoning as fn_requeue_derm_portal returning its
  -- post-condition rather than "ok".
  if not (v_url = any (v_before)) then
    raise exception 'Ticket % does not carry that % document, so there is nothing to detach. It holds % document(s).',
      v_ticket, v_kind, coalesce(array_length(v_before,1),0)
      using errcode = '22023';
  end if;

  -- Re-pack every live row of the ticket: first survivor becomes the primary, the rest the
  -- extras. Writing the primary and the extras TOGETHER is what stops the two halves of one
  -- list disagreeing -- derm.v_stamp_row_bands already shows what per-edge writes cost.
  if v_kind = 'address' then
    with rows_to_fix as (
      select dm.id,
             (select coalesce(array_agg(u order by ord), array[]::text[])
                from unnest(array[dm.derm_address_url] || coalesce(dm.derm_address_extra_urls, array[]::text[]))
                       with ordinality as t(u, ord)
               where u is not null and u <> '' and u <> v_url) as keep
        from public.derm_manifests dm
       where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
         and dm.deleted_at is null
    )
    update public.derm_manifests d
       set derm_address_url        = r.keep[1],
           derm_address_extra_urls = case when coalesce(array_length(r.keep,1),0) > 1
                                          then r.keep[2:] else array[]::text[] end
      from rows_to_fix r
     where d.id = r.id;
  else
    with rows_to_fix as (
      select dm.id,
             (select coalesce(array_agg(u order by ord), array[]::text[])
                from unnest(array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[]))
                       with ordinality as t(u, ord)
               where u is not null and u <> '' and u <> v_url) as keep
        from public.derm_manifests dm
       where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
         and dm.deleted_at is null
    )
    update public.derm_manifests d
       set derm_manifest_url        = r.keep[1],
           derm_manifest_extra_urls = case when coalesce(array_length(r.keep,1),0) > 1
                                           then r.keep[2:] else array[]::text[] end
      from rows_to_fix r
     where d.id = r.id;
  end if;
  get diagnostics v_rows = row_count;

  select coalesce(array_agg(distinct u) filter (where u is not null and u <> ''), array[]::text[])
    into v_after
    from public.derm_manifests dm
    cross join lateral unnest(
      case when v_kind = 'address'
           then array[dm.derm_address_url]  || coalesce(dm.derm_address_extra_urls,  array[]::text[])
           else array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[])
      end) as u
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
     and dm.deleted_at is null;

  -- Post-conditions, asserted rather than assumed. Removing ONE document must never be
  -- able to take a second with it: that equal-size-swap shape is exactly the loss the
  -- edit_manifest containment guard exists to refuse, and this function must not become a
  -- way around it.
  if v_url = any (v_after) then
    raise exception 'Detach did not take: ticket % still carries that % document.', v_ticket, v_kind
      using errcode = '23514';
  end if;
  if not (v_after <@ v_before) then
    raise exception 'Detach altered the ticket in an unexpected way and has been rolled back.'
      using errcode = '23514';
  end if;
  if coalesce(array_length(v_before,1),0) - coalesce(array_length(v_after,1),0) <> 1 then
    raise exception 'Detach removed % documents, expected exactly 1. Rolled back.',
      coalesce(array_length(v_before,1),0) - coalesce(array_length(v_after,1),0)
      using errcode = '23514';
  end if;

  -- derm._actor reads request.jwt.claims (PLURAL). The singular key PostgREST never sets
  -- is why audit.logs.changed_by has been NULL for its entire life.
  v_actor := derm._actor('sql');

  insert into derm.manifest_document_detachments
    (ticket_number, manifest_id, kind, url, rows_touched, remaining, reason, detached_by)
  values
    (v_ticket, p_manifest_id, v_kind, v_url, v_rows,
     coalesce(array_length(v_after,1),0), btrim(p_reason), v_actor);

  return query select v_ticket, v_kind, v_url, v_rows, v_after;
end;
$function$;

CREATE OR REPLACE FUNCTION public.edit_manifest(p_old_number text, p_old_jurisdiction text, p_new_number text, p_new_jurisdiction text, p_dump_date date, p_disposal_facility_id bigint, p_derm_manifest_url text DEFAULT NULL::text, p_derm_address_url text DEFAULT NULL::text, p_derm_manifest_urls text[] DEFAULT NULL::text[], p_derm_address_urls text[] DEFAULT NULL::text[])
 RETURNS SETOF derm_manifests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old_dade boolean := position('dade' in lower(coalesce(p_old_jurisdiction, ''))) > 0;
  v_new_dade boolean := position('dade' in lower(coalesce(p_new_jurisdiction, ''))) > 0;
  -- Normalize provided arrays: drop NULL/blank entries, preserve order (element 1 = primary).
  v_man_arr  text[] := CASE WHEN p_derm_manifest_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_manifest_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
  v_addr_arr text[] := CASE WHEN p_derm_address_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_address_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
  -- === 2026-09-08_0330: the no-shrink guard ===============================
  v_man_before  text[];
  v_man_after   text[];
  v_addr_before text[];
  v_addr_after  text[];
  v_lost        text[];
BEGIN
  IF coalesce(p_old_number, '') = '' OR coalesce(p_new_number, '') = '' THEN
    RAISE EXCEPTION 'edit_manifest: manifest number is required' USING ERRCODE = '22023';
  END IF;

  -- ===================== NO-SHRINK GUARD (2026-09-08_0330) ================
  -- 1. LOCK the exact rows the UPDATE will touch, BEFORE reading them. Without
  --    this, two concurrent saves both pass their guards and the later wins.
  PERFORM 1
    FROM public.derm_manifests dm
   WHERE dm.deleted_at IS NULL
     AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
        OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
     FOR UPDATE;

  -- 2. The BEFORE set: every distinct non-null url the ticket holds, across
  --    primary AND extras, across every live row. NULL-free by construction.
  SELECT coalesce(array_agg(DISTINCT s.u) FILTER (WHERE s.u IS NOT NULL), ARRAY[]::text[]),
         coalesce(array_agg(DISTINCT t.u) FILTER (WHERE t.u IS NOT NULL), ARRAY[]::text[])
    INTO v_man_before, v_addr_before
    FROM public.derm_manifests dm
    LEFT JOIN LATERAL (SELECT dm.derm_manifest_url AS u
                       UNION ALL SELECT unnest(coalesce(dm.derm_manifest_extra_urls, ARRAY[]::text[]))) s ON true
    LEFT JOIN LATERAL (SELECT dm.derm_address_url AS u
                       UNION ALL SELECT unnest(coalesce(dm.derm_address_extra_urls, ARRAY[]::text[]))) t ON true
   WHERE dm.deleted_at IS NULL
     AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
        OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) );

  -- 3. The AFTER set, per slot, matching exactly what the UPDATE below will do.
  --    Array path  -> the array replaces primary+extras on every row.
  --    Scalar path -> the scalar becomes every row's primary; extras untouched.
  --    Neither     -> nothing moves.
  IF p_derm_manifest_urls IS NOT NULL THEN
    v_man_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM unnest(v_man_arr) u), ARRAY[]::text[]);
  ELSIF p_derm_manifest_url IS NOT NULL THEN
    v_man_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM (
                       SELECT p_derm_manifest_url AS u
                       UNION ALL
                       SELECT unnest(coalesce(dm.derm_manifest_extra_urls, ARRAY[]::text[]))
                         FROM public.derm_manifests dm
                        WHERE dm.deleted_at IS NULL
                          AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
                             OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )) z), ARRAY[]::text[]);
  ELSE
    v_man_after := v_man_before;
  END IF;

  IF p_derm_address_urls IS NOT NULL THEN
    v_addr_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM unnest(v_addr_arr) u), ARRAY[]::text[]);
  ELSIF p_derm_address_url IS NOT NULL THEN
    v_addr_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM (
                       SELECT p_derm_address_url AS u
                       UNION ALL
                       SELECT unnest(coalesce(dm.derm_address_extra_urls, ARRAY[]::text[]))
                         FROM public.derm_manifests dm
                        WHERE dm.deleted_at IS NULL
                          AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
                             OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )) z), ARRAY[]::text[]);
  ELSE
    v_addr_after := v_addr_before;
  END IF;

  -- 4. CONTAINMENT, not cardinality. An equal-size swap must be refused.
  IF NOT (v_addr_before <@ v_addr_after) THEN
    SELECT array_agg(u) INTO v_lost FROM unnest(v_addr_before) u WHERE NOT (u = ANY(v_addr_after));
    RAISE EXCEPTION 'This save would drop % address sheet(s) this ticket already has. Saving can only add or replace a sheet, never take one off. To remove a sheet, use Remove on that sheet.', cardinality(v_lost)
      USING ERRCODE = '23514', DETAIL = array_to_string(v_lost, ' | ');
  END IF;

  IF NOT (v_man_before <@ v_man_after) THEN
    SELECT array_agg(u) INTO v_lost FROM unnest(v_man_before) u WHERE NOT (u = ANY(v_man_after));
    RAISE EXCEPTION 'This save would drop % disposal receipt page(s) this ticket already has. Saving can only add or replace a page, never take one off. To remove a page, use Remove on that page.', cardinality(v_lost)
      USING ERRCODE = '23514', DETAIL = array_to_string(v_lost, ' | ');
  END IF;
  -- ===================== end guard ========================================

  -- Update every live row in the OLD (number, jurisdiction) group, in one atomic statement.
  RETURN QUERY
  UPDATE public.derm_manifests dm SET
    white_manifest_number = CASE WHEN v_new_dade THEN p_new_number ELSE NULL END,
    yellow_ticket_number  = CASE WHEN v_new_dade THEN NULL ELSE p_new_number END,
    -- ⚠ COALESCE, not a bare assignment: this UPDATE spans the whole ticket group (up to 19 rows), so an
    -- empty form field here would wipe the dump date / facility across every manifest on the ticket.
    -- NULL means "leave as is", exactly like the URL slots below. Do NOT "simplify" these back.
    dump_ticket_date      = COALESCE(p_dump_date, dm.dump_ticket_date),
    disposal_facility_id  = COALESCE(p_disposal_facility_id, dm.disposal_facility_id),
    -- MANIFEST slot: authoritative array wins; else legacy single-url COALESCE, extras untouched.
    derm_manifest_url = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[1]
        ELSE COALESCE(p_derm_manifest_url, dm.derm_manifest_url) END,
    derm_manifest_extra_urls = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[2:cardinality(v_man_arr)]
        ELSE dm.derm_manifest_extra_urls END,
    -- ADDRESS slot
    derm_address_url = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[1]
        ELSE COALESCE(p_derm_address_url, dm.derm_address_url) END,
    derm_address_extra_urls = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[2:cardinality(v_addr_arr)]
        ELSE dm.derm_address_extra_urls END
  WHERE dm.deleted_at IS NULL
    AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
       OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
  RETURNING dm.*;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'edit_manifest: no live manifest found for % #%', p_old_jurisdiction, p_old_number
      USING ERRCODE = 'P0002';
  END IF;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'edit_manifest: a manifest numbered % is already filed for one of these clients', p_new_number
      USING ERRCODE = '23505';
END;
$function$;

CREATE OR REPLACE FUNCTION public.file_manifest(p_client_id bigint, p_jurisdiction text, p_number text, p_disposal_facility_id bigint, p_dump_date date, p_visit_ids bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  -- A manifest is only uploaded AFTER it returns from the city, so both of these are on the sheet
  -- in front of whoever is filing it. A blank here means the form was submitted incomplete, not
  -- that the value is unknowable. Raise something Diego can read rather than letting the CHECK
  -- constraint surface a raw 23514.
  IF p_dump_date IS NULL OR p_disposal_facility_id IS NULL THEN
    RAISE EXCEPTION 'Dump date and disposal facility are both required to file a manifest (they are printed on the sheet). Got dump date %, facility %.',
      coalesce(p_dump_date::text, 'blank'), coalesce(p_disposal_facility_id::text, 'blank')
      USING ERRCODE = '22023';
  END IF;

  -- 🛑 DECISION 1, Fred 2026-09-07: an unrecognised jurisdiction must RAISE, not write NULL.
  -- The CASE below writes p_number into the white column only for the exact literal 'Miami-Dade'
  -- and into the yellow column only for the exact literal 'Broward'. Anything else, including
  -- 'miami-dade' and ' Miami-Dade', fell through BOTH arms and produced a manifest with NO ticket
  -- number in either column and NO error. Measured live in a rolled-back probe: 7 of 9 tested
  -- values did exactly that. This guard MIRRORS the CASE below rather than paraphrasing it, so the
  -- two cannot drift; if you change the CASE, change this.
  IF p_jurisdiction IS DISTINCT FROM 'Miami-Dade' AND p_jurisdiction IS DISTINCT FROM 'Broward' THEN
    RAISE EXCEPTION 'Jurisdiction must be exactly ''Miami-Dade'' or ''Broward'' (case and spacing matter). Got %.',
      coalesce(quote_literal(p_jurisdiction), 'NULL')
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.derm_manifests
    (white_manifest_number, yellow_ticket_number, dump_ticket_date, service_date,
     disposal_facility_id, client_id)
  VALUES
    (CASE WHEN p_jurisdiction = 'Miami-Dade' THEN p_number ELSE NULL END,
     CASE WHEN p_jurisdiction = 'Broward'    THEN p_number ELSE NULL END,
     p_dump_date, p_dump_date, p_disposal_facility_id, p_client_id)
  RETURNING id INTO v_id;

  IF p_visit_ids IS NOT NULL AND array_length(p_visit_ids, 1) > 0 THEN
    INSERT INTO public.manifest_visits (manifest_id, visit_id)
    SELECT DISTINCT v_id, vid FROM unnest(p_visit_ids) AS vid
    ON CONFLICT (manifest_id, visit_id) DO NOTHING;
  END IF;

  RETURN v_id;
END; $function$;

CREATE OR REPLACE FUNCTION public.file_manifest_on_shared_ticket(p_white_manifest_number text, p_client_id bigint, p_visit_id bigint, OUT manifest_id bigint, OUT created boolean, OUT linked boolean)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm'
AS $function$
DECLARE
  v_wm text := btrim(p_white_manifest_number);   -- the TICKET number (white, or yellow for Broward-only)
  v_vcid bigint; v_vdate date; v_vcode text; v_ccode text; v_rows int;
  v_yellow_key boolean;
  v_fac bigint; v_dump date;
  sib public.derm_manifests%ROWTYPE;
BEGIN
  IF coalesce(v_wm, '') = '' THEN
    RAISE EXCEPTION 'p_white_manifest_number required';
  END IF;
  IF p_client_id IS NULL OR p_visit_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id and p_visit_id required';
  END IF;

  SELECT v.client_id, v.visit_date INTO v_vcid, v_vdate
    FROM public.visits v WHERE v.id = p_visit_id AND v.deleted_at IS NULL;
  IF v_vcid IS NULL THEN
    RAISE EXCEPTION 'visit % not found or deleted', p_visit_id;
  END IF;
  IF v_vcid <> p_client_id THEN
    SELECT client_code INTO v_vcode FROM public.clients WHERE id = v_vcid;
    SELECT client_code INTO v_ccode FROM public.clients WHERE id = p_client_id;
    RAISE EXCEPTION 'visit % belongs to % — call this RPC with that client, not %',
      p_visit_id, coalesce(v_vcode, v_vcid::text), coalesce(v_ccode, p_client_id::text);
  END IF;

  -- find-or-create the (ticket, client) row (ticket key = COALESCE(white#, yellow#))
  SELECT dm.id INTO manifest_id FROM public.derm_manifests dm
   WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.client_id = p_client_id
     AND dm.deleted_at IS NULL
   ORDER BY dm.id LIMIT 1;
  created := manifest_id IS NULL;

  IF created THEN
    -- DOCUMENT source: unchanged. Best-documented sibling wins (the old hard
    -- "derm_manifest_url IS NOT NULL" filter inherited NOTHING from an address-doc-only sibling).
    SELECT * INTO sib FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
     ORDER BY (dm.derm_manifest_url IS NOT NULL) DESC,
              (dm.derm_address_url IS NOT NULL) DESC, dm.id
     LIMIT 1;
    IF sib.id IS NULL THEN
      RAISE EXCEPTION 'no manifest exists on ticket % to share docs from — file the first manifest through the normal flow', v_wm;
    END IF;

    -- DUMP-FIELD source: resolved INDEPENDENTLY of the document source. The best-documented
    -- sibling is not necessarily a sibling that HAS these fields, and copying its NULLs is what
    -- put a NULL facility on 6 of 6 rows filed through this RPC on 2026-07-07. Take them from any
    -- sibling on the ticket that carries them (lowest id wins, deterministic).
    SELECT dm.disposal_facility_id INTO v_fac FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
       AND dm.disposal_facility_id IS NOT NULL
     ORDER BY dm.id LIMIT 1;

    SELECT dm.dump_ticket_date INTO v_dump FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
       AND dm.dump_ticket_date IS NOT NULL
     ORDER BY dm.id LIMIT 1;

    IF v_fac IS NULL OR v_dump IS NULL THEN
      RAISE EXCEPTION 'ticket % has no sibling carrying a dump date and disposal facility (dump date %, facility %) — fix the existing manifest on this ticket first',
        v_wm, coalesce(v_dump::text, 'missing'), coalesce(v_fac::text, 'missing')
        USING ERRCODE = '22023';
    END IF;

    -- yellow-keyed ticket (live yellow-only siblings, no white-keyed manifest, no split-key sibling)
    -- -> file with yellow_ticket_number, NOT white_manifest_number
    SELECT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NULL AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE white_manifest_number = v_wm AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NOT NULL
                      AND white_manifest_number <> v_wm AND deleted_at IS NULL)
      INTO v_yellow_key;

    INSERT INTO public.derm_manifests
      (white_manifest_number, yellow_ticket_number, client_id, service_date,
       derm_manifest_url, derm_manifest_extra_urls,
       derm_address_url, derm_address_extra_urls,
       wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES
      (CASE WHEN v_yellow_key THEN NULL ELSE v_wm END,
       CASE WHEN v_yellow_key THEN v_wm ELSE NULL END,
       p_client_id, v_vdate,
       sib.derm_manifest_url, coalesce(sib.derm_manifest_extra_urls, '{}'::text[]),
       sib.derm_address_url,  coalesce(sib.derm_address_extra_urls,  '{}'::text[]),
       sib.wwtp_receipt_document_path, v_fac, v_dump)
    RETURNING id INTO manifest_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (manifest_id, p_visit_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  linked := v_rows > 0;
END $function$;

CREATE OR REPLACE FUNCTION public.fn_correct_gdo_report(p_visit_id bigint, p_portal_confirmation text, p_failure_reason text)
 RETURNS TABLE(visit_id bigint, status text, portal_confirmation text, failure_reason text, screenshot_path text, attempted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'a run id is now required: call fn_correct_gdo_report(visit_id, run_id, portal_confirmation, failure_reason). The 3-argument form corrected whichever submission was most recent for the visit, which is the wrong permit whenever a visit has more than one GDO.'
    USING ERRCODE = '22023';
END
$function$;

CREATE OR REPLACE FUNCTION public.fn_correct_gdo_report(p_visit_id bigint, p_run_id text, p_portal_confirmation text, p_failure_reason text)
 RETURNS TABLE(visit_id bigint, run_id text, gdo_id bigint, status text, portal_confirmation text, failure_reason text, screenshot_path text, attempted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id bigint;
  v_n  integer;
BEGIN
  IF p_visit_id IS NULL THEN
    RAISE EXCEPTION 'visit id is required' USING ERRCODE = '22023';
  END IF;
  IF p_run_id IS NULL OR btrim(p_run_id) = '' THEN
    RAISE EXCEPTION 'run id is required: a visit can hold reports for several GDO permits, and without it the correction cannot say which one'
      USING ERRCODE = '22023';
  END IF;

  -- Exactly ONE live row. run_id is unique, so this cannot pick a neighbour the way the old
  -- ORDER BY attempted_at DESC LIMIT 1 could.
  SELECT s.id INTO v_id
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'no live GDO report for visit % run % - nothing to correct', p_visit_id, p_run_id
      USING ERRCODE = '22023';
  END IF;

  -- Trim to NULL so an emptied box does not store ''. On a SUCCESS row this makes the existing
  -- success_confirmed CHECK fire (23514) rather than silently clearing the field that holds the
  -- visit out of the queue. That rejection is CORRECT and is the point.
  UPDATE public.derm_portal_submissions s
     SET portal_confirmation = NULLIF(btrim(coalesce(p_portal_confirmation, '')), ''),
         failure_reason      = NULLIF(btrim(coalesce(p_failure_reason, '')), '')
   WHERE s.id = v_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'expected to correct exactly 1 row, touched %', v_n USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT s.visit_id, s.run_id, s.gdo_id, s.status, s.portal_confirmation, s.failure_reason,
         s.screenshot_path, s.attempted_at
    FROM public.derm_portal_submissions s
   WHERE s.id = v_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.fn_set_gdo_evidence_ext(p_visit_id bigint, p_run_id text, p_ext text)
 RETURNS TABLE(visit_id bigint, run_id text, screenshot_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_old text;
  v_new text;
BEGIN
  IF p_ext NOT IN ('jpg', 'png') THEN
    RAISE EXCEPTION 'extension must be jpg or png, got %', p_ext USING ERRCODE = '22023';
  END IF;

  -- Must be a LIVE row. Dry-run rows are test artefacts against a separate QA queue and the app
  -- never renders them (derm.visit_gdo_report filters them out).
  SELECT s.screenshot_path INTO v_old
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no live GDO report for visit % run %', p_visit_id, p_run_id
      USING ERRCODE = '22023';
  END IF;

  v_new := format('%s/%s.%s', p_visit_id, p_run_id, p_ext);

  UPDATE public.derm_portal_submissions s
     SET screenshot_path = v_new
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  RETURN QUERY SELECT p_visit_id, p_run_id, v_new;
END
$function$;

CREATE OR REPLACE FUNCTION hr.check_app_action(p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_app text; v_level text;
begin
  select a.app, a.lvl into v_app, v_level
    from (values ('send_visit_photos_email', 'admin_review', 'edit'),
                 ('rotate_photo',            'admin_review', 'edit'),
                 ('visit_client_note_photos','admin_review', 'view')) a(action, app, lvl)
   where a.action = p_action;
  if v_app is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  perform hr.fn_check_app(v_app, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.record_manifest_visit_sheet(p_manifest_id bigint, p_visit_id bigint, p_photo_bucket text, p_photo_path text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm', 'pg_temp'
AS $function$
declare
  v_client  bigint;
  v_bucket  text;
  v_sheet   bigint;
begin
  if p_manifest_id is null or p_visit_id is null then
    raise exception 'A manifest and a visit are both required to record an address sheet.'
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_photo_bucket), '') = '' or coalesce(btrim(p_photo_path), '') = '' then
    raise exception 'The uploaded sheet needs both a storage bucket and a path. Got bucket %, path %.',
      coalesce(quote_literal(p_photo_bucket), 'NULL'), coalesce(quote_literal(p_photo_path), 'NULL')
      using errcode = '22023';
  end if;

  select m.client_id into v_client
    from public.derm_manifests m
   where m.id = p_manifest_id and m.deleted_at is null;

  if v_client is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- The visit must be ON this manifest. See refusal 2 in the header.
  if not exists (select 1 from public.manifest_visits mv
                  where mv.manifest_id = p_manifest_id and mv.visit_id = p_visit_id) then
    raise exception 'Visit % is not linked to manifest %, so a sheet cannot be attached to it. Link the visit first.',
      p_visit_id, p_manifest_id
      using errcode = '22023';
  end if;

  v_bucket := derm.fn_manifest_dump_bucket(p_manifest_id);
  if v_bucket <> 'BROWARD' then
    raise exception 'Manifest % was dumped at a % site. One address sheet per visit is the Broward FDEP form only; a Miami-Dade sheet covers several clients at once.',
      p_manifest_id, v_bucket
      using errcode = '22023';
  end if;

  -- Allocate a number only the first time. See the header: the paper is already printed.
  select s.sheet_no into v_sheet
    from derm.manifest_visit_sheets s
   where s.manifest_id = p_manifest_id and s.visit_id = p_visit_id;

  -- ===================== ADOPTION (2026-09-07_2240) =======================
  -- If the office GENERATED a sheet for this visit, the driver is holding paper
  -- with that number on it. Adopt it. Minting here instead would put a second,
  -- different number in the register for the same physical sheet, and nothing
  -- in the schema could see the divergence: the unique index on sheet_no is
  -- per-row within this table and cannot reach the generation register.
  if v_sheet is null then
    select g.sheet_no into v_sheet
      from derm.generated_visit_sheets g
     where g.visit_id = p_visit_id and g.deleted_at is null;
  end if;
  -- ========================================================================

  -- Still null means genuinely un-generated: a sheet filled on a blank pad the
  -- office never printed. That is how every Broward manifest in history was
  -- filed, so it stays supported rather than refused.
  if v_sheet is null then
    v_sheet := nextval('public.derm_broward_address_seq');
  end if;

  insert into derm.manifest_visit_sheets
    (manifest_id, visit_id, client_id, sheet_no, photo_bucket, photo_path, uploaded_at, deleted_at)
  values
    (p_manifest_id, p_visit_id, v_client, v_sheet, btrim(p_photo_bucket), btrim(p_photo_path), now(), null)
  on conflict (manifest_id, visit_id) do update
    set photo_bucket = excluded.photo_bucket,
        photo_path   = excluded.photo_path,
        uploaded_at  = excluded.uploaded_at,
        deleted_at   = null;
        -- sheet_no deliberately NOT updated: the number is on paper the driver carried.

  return v_sheet;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_visit_derm_required_manual(p_visit_id bigint, p_value boolean)
 RETURNS TABLE(visit_id bigint, derm_required boolean, derm_required_locked boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_alive boolean;
BEGIN
  SELECT true INTO v_alive
    FROM public.visits v
   WHERE v.id = p_visit_id AND v.deleted_at IS NULL;

  IF v_alive IS NOT TRUE THEN
    RAISE EXCEPTION 'visit % not found or soft-deleted', p_visit_id
      USING ERRCODE = '22023';
  END IF;

  -- 🛑 THREE STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE OR REORDER. See header.
  UPDATE public.visits SET derm_required_locked = false
   WHERE id = p_visit_id AND derm_required_locked IS TRUE;

  UPDATE public.visits SET derm_required = p_value
   WHERE id = p_visit_id;

  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL)
   WHERE id = p_visit_id;

  RETURN QUERY
  SELECT v.id, v.derm_required, v.derm_required_locked
    FROM public.visits v
   WHERE v.id = p_visit_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.set_visits_derm_required_manual(p_visit_ids bigint[], p_value boolean, p_unlink boolean DEFAULT false)
 RETURNS TABLE(visit_id bigint, derm_required boolean, derm_required_locked boolean, unlinked integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids      bigint[];
  v_sent     integer;
  v_alive    integer;
  v_unlinked jsonb := '{}'::jsonb;
BEGIN
  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no visit ids supplied' USING ERRCODE = '22023';
  END IF;

  IF array_position(p_visit_ids, NULL::bigint) IS NOT NULL THEN
    RAISE EXCEPTION 'visit id array contains NULL' USING ERRCODE = '22023';
  END IF;

  IF array_length(p_visit_ids, 1) > 1000 THEN
    RAISE EXCEPTION 'too many visits in one call (% supplied, limit 1000)',
      array_length(p_visit_ids, 1) USING ERRCODE = '22023';
  END IF;

  IF p_unlink AND p_value IS TRUE THEN
    RAISE EXCEPTION 'refusing to unlink DERM manifests while marking DERM required'
      USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_visit_ids) AS x;
  v_sent := array_length(v_ids, 1);

  SELECT count(*) INTO v_alive
    FROM public.visits v
   WHERE v.id = ANY(v_ids) AND v.deleted_at IS NULL;

  IF v_alive <> v_sent THEN
    RAISE EXCEPTION 'one or more visits not found or soft-deleted (% of % alive) - nothing was changed',
      v_alive, v_sent USING ERRCODE = '22023';
  END IF;

  -- 🛑 THREE STATEMENTS, ORDER IS LOAD-BEARING. DO NOT MERGE OR REORDER. See header.
  UPDATE public.visits SET derm_required_locked = false
   WHERE id = ANY(v_ids) AND derm_required_locked IS TRUE;

  UPDATE public.visits SET derm_required = p_value
   WHERE id = ANY(v_ids);

  UPDATE public.visits SET derm_required_locked = (p_value IS NOT NULL)
   WHERE id = ANY(v_ids);

  IF p_unlink THEN
    WITH d AS (
      DELETE FROM public.manifest_visits mv
       WHERE mv.visit_id = ANY(v_ids)
      RETURNING mv.visit_id
    )
    SELECT coalesce(jsonb_object_agg(s.visit_id::text, s.n), '{}'::jsonb)
      INTO v_unlinked
      FROM (SELECT d.visit_id, count(*) AS n FROM d GROUP BY d.visit_id) s;
  END IF;

  RETURN QUERY
  SELECT v.id,
         v.derm_required,
         v.derm_required_locked,
         coalesce((v_unlinked ->> v.id::text)::integer, 0)
    FROM public.visits v
   WHERE v.id = ANY(v_ids)
   ORDER BY v.id;
END
$function$;

DROP FUNCTION public.derm_link_visits(bigint, bigint[]);
DROP FUNCTION public.derm_unlink_visit(bigint, bigint);
DROP FUNCTION public.derm_delete_manifests(bigint[]);
DROP FUNCTION public.derm_set_manifest_photos(bigint, text, text, text[], text[]);
DO $v$ BEGIN
  if md5(pg_get_functiondef('derm.add_client_card_and_link(text,integer,bigint,bigint)'::regprocedure)) <> '153db542760e6885ce9cd1218a0d3c0d' then raise exception 'derm.add_client_card_and_link(text,integer,bigint,bigint) not restored'; end if;
  if md5(pg_get_functiondef('derm.add_extra_client_card(text,bigint,integer)'::regprocedure)) <> '16b2013460efc00780fc3a6cc1348a98' then raise exception 'derm.add_extra_client_card(text,bigint,integer) not restored'; end if;
  if md5(pg_get_functiondef('derm.add_sheet_client(text,integer,bigint,text)'::regprocedure)) <> '22fc8458c070e818fd0712769014d012' then raise exception 'derm.add_sheet_client(text,integer,bigint,text) not restored'; end if;
  if md5(pg_get_functiondef('derm.clear_stamp_position(bigint)'::regprocedure)) <> 'b8081309ae1c676e88ca2c60f5d06e96' then raise exception 'derm.clear_stamp_position(bigint) not restored'; end if;
  if md5(pg_get_functiondef('derm.get_visit_report(bigint)'::regprocedure)) <> '56a8cdfe591816215bf3a0a9635d9209' then raise exception 'derm.get_visit_report(bigint) not restored'; end if;
  if md5(pg_get_functiondef('derm.link_row_visit(bigint,bigint)'::regprocedure)) <> 'ca12ca402fe75e17938186586f0f047e' then raise exception 'derm.link_row_visit(bigint,bigint) not restored'; end if;
  if md5(pg_get_functiondef('derm.place_stamp_in_row(bigint,integer,numeric,numeric)'::regprocedure)) <> 'b91b752ddb7bb22658174930ffb42bde' then raise exception 'derm.place_stamp_in_row(bigint,integer,numeric,numeric) not restored'; end if;
  if md5(pg_get_functiondef('derm.remove_sheet_client(bigint)'::regprocedure)) <> 'fbc63d862a86b09ff9f3646b064ec739' then raise exception 'derm.remove_sheet_client(bigint) not restored'; end if;
  if md5(pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure)) <> 'ee3f2c465fc00192dad91e72bd508801' then raise exception 'derm.save_page_bands(text,integer,text,jsonb,jsonb) not restored'; end if;
  if md5(pg_get_functiondef('derm.set_sheet_completed(text,boolean)'::regprocedure)) <> '03fccec22dd4317288afcf87b66d9b9b' then raise exception 'derm.set_sheet_completed(text,boolean) not restored'; end if;
  if md5(pg_get_functiondef('derm.set_stamp_position(bigint,integer,numeric,numeric)'::regprocedure)) <> '077074f71fa4b7ad4fb6c1c316bc11f9' then raise exception 'derm.set_stamp_position(bigint,integer,numeric,numeric) not restored'; end if;
  if md5(pg_get_functiondef('derm.unlink_row_visit(bigint,bigint)'::regprocedure)) <> '8a152fe6e6409d9e174dd48f7cfb2278' then raise exception 'derm.unlink_row_visit(bigint,bigint) not restored'; end if;
  if md5(pg_get_functiondef('public.detach_manifest_document(bigint,text,text,text)'::regprocedure)) <> 'a1b651cca24ee1c64b15fe30255fa44e' then raise exception 'detach_manifest_document(bigint,text,text,text) not restored'; end if;
  if md5(pg_get_functiondef('public.edit_manifest(text,text,text,text,date,bigint,text,text,text[],text[])'::regprocedure)) <> '8953d2a7effc1b641acb80ba39c10be4' then raise exception 'edit_manifest(text,text,text,text,date,bigint,text,text,text[],text[]) not restored'; end if;
  if md5(pg_get_functiondef('public.file_manifest(bigint,text,text,bigint,date,bigint[])'::regprocedure)) <> '58a3f57468a71fb220559ec5d0f2b938' then raise exception 'file_manifest(bigint,text,text,bigint,date,bigint[]) not restored'; end if;
  if md5(pg_get_functiondef('public.file_manifest_on_shared_ticket(text,bigint,bigint)'::regprocedure)) <> '3217e3cf85dfc7c8761a2a1af93f1c75' then raise exception 'file_manifest_on_shared_ticket(text,bigint,bigint) not restored'; end if;
  if md5(pg_get_functiondef('public.fn_correct_gdo_report(bigint,text,text)'::regprocedure)) <> 'ef698f1b2297f30167cc66d6416f48ff' then raise exception 'fn_correct_gdo_report(bigint,text,text) not restored'; end if;
  if md5(pg_get_functiondef('public.fn_correct_gdo_report(bigint,text,text,text)'::regprocedure)) <> '7d863992f85c563ae2dcb49b62b56437' then raise exception 'fn_correct_gdo_report(bigint,text,text,text) not restored'; end if;
  if md5(pg_get_functiondef('public.fn_set_gdo_evidence_ext(bigint,text,text)'::regprocedure)) <> 'c615e4efee7bcff8f79a113d83f330d6' then raise exception 'fn_set_gdo_evidence_ext(bigint,text,text) not restored'; end if;
  if md5(pg_get_functiondef('hr.check_app_action(text)'::regprocedure)) <> '0d662d9cee93ce2b5f4160b82c2be5ec' then raise exception 'hr.check_app_action(text) not restored'; end if;
  if md5(pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure)) <> 'f5c8334073fcb0bdc5ef698e139e5a77' then raise exception 'record_manifest_visit_sheet(bigint,bigint,text,text) not restored'; end if;
  if md5(pg_get_functiondef('public.set_visit_derm_required_manual(bigint,boolean)'::regprocedure)) <> '961661513c10d2daa4a9db5f52a9a327' then raise exception 'set_visit_derm_required_manual(bigint,boolean) not restored'; end if;
  if md5(pg_get_functiondef('public.set_visits_derm_required_manual(bigint[],boolean,boolean)'::regprocedure)) <> '5d160fb7c0265195bc046255a0c52959' then raise exception 'set_visits_derm_required_manual(bigint[],boolean,boolean) not restored'; end if;
END $v$;
COMMIT;
