-- 2026-09-03_1510_page_image_injectivity_guard.sql
--
-- WHY
-- ---
-- Fred: **"fix it and add the guard so it never happens again."** `2026-09-03_1500` repaired the
-- data on `ticket-834742`. This migration removes the three routes that produce the defect and
-- installs the permanent guard, so it cannot come back on a folder nobody is looking at.
--
-- THE DEFECT, IN ONE LINE
-- -----------------------
-- `derm.ticket_page_images(white#)` GROUPs `derm.address_row_map` BY `page` and takes
-- `mode(image_url)` per page, then appends any manifest image not already shown. So a SECOND `page`
-- carrying an image that another `page` already carries APPENDS a duplicate array entry, and every
-- later ordinal silently re-points at a different scan. `stamp_page`, `address_sheet_scan_reads.page`
-- and `address_sheet_row_reads.page` are all ordinals into that array, and `effective_page` is the
-- page selector in `derm.fn_blackout_targets`, so the end state is a customer-facing redaction built
-- from the wrong page. That is exactly what froze `ticket-833049`.
--
-- THE INVARIANT, AND WHY THE OBVIOUS ONE IS FALSE
-- -----------------------------------------------
-- The estate documentation says "every card on a folder shares one `page`; only `stamp_page`
-- varies". As an operational habit that is right. **As a constraint it is FALSE and unshippable:**
-- 19 of 138 folders carry more than one `page` (98 of 726 rows) and 17 of them are LEGITIMATE
-- multi-page OCR sheets. Enforcing the sentence literally would refuse 96 good rows.
--
-- What separates the 17 good folders from the 2 bad ones is a BIJECTION: n_pages ==
-- n_distinct_images. So the shippable invariant is the injective half of it, and it is scoped to
-- `white_manifest_number` because that, not `dump_folder`, is what `ticket_page_images` groups on:
--
--     within one white_manifest_number, no two distinct `page` values may carry the same
--     non-'pending' `image_url`
--
-- Measured before installing: that predicate refuses **18 rows across exactly 2 manifests** (833049
-- and 834742) out of 726, and **zero** legitimate rows. Replayed across the entire `audit.logs`
-- history it fires on only 5 folder/image pairs ever: 833049, 834742, a hand-SQL move on
-- ticket-310429 that was reverted 38 minutes later, a corrected page on window4-sheet1, and a
-- deleted smoke-test fixture. `2026-09-03_1500` cleared 834742, so **833049 is the only violator
-- left**, and it is frozen by design.
--
-- 🛑 THE GUARD IS NO-WORSE, NOT ABSOLUTE - the same design decision `derm.save_page_geometry`
-- already carries. It skips an UPDATE that leaves `white_manifest_number`, `page` and `image_url`
-- untouched. Without that skip it would FREEZE every write to `ticket-833049`, which is a folder a
-- person still has to work on: band edits, stamp clears and the eventual repair all have to remain
-- possible. With it, only a write that MOVES a card into (or leaves it in) the violating shape is
-- refused - and the repair itself passes, because the guard tests the post-image and the repaired
-- folder is clean.
--
-- THREE ROUTES, NOT ONE. A TRIGGER-ONLY FIX WOULD LEAVE TWO OPEN.
-- ---------------------------------------------------------------
--   1. `derm.trg_autoplace_generated` - `NEW.page := v_img` with no matching `image_url`. The ONLY
--      object in the database that assigns `NEW.page`; it produced a page>1 row twice in production
--      and corrupted it both times (0 of 2 correct).
--   2. `derm.add_sheet_client` - when the caller names a page that has no card yet, it fell back to
--      the folder-wide `min(image_url)` (page 1's image) and inserted it at the caller's page. This
--      is EXECUTE-granted to `authenticated` and is the operator-facing "Add client" path, so it is
--      reachable today by clicking page 2 of a folder whose cards are all on page 1.
--   3. `derm.add_extra_client_card` - takes the client's existing card's `image_url` and writes it at
--      `coalesce(p_page,1)`. Same shape whenever those two pages differ.
--
-- 🛑 WITHOUT FIXING ALL THREE, THE GUARD WOULD BE A REGRESSION, NOT A FIX. Route 1 fires on any
-- generated sheet whose client sits on printed page 2, so the guard alone would make filing that
-- manifest RAISE. Routes 2 and 3 would turn an operator's ordinary "add a client to page 2" into a
-- raw constraint error. Fixing the source is what makes the guard safe to install.
--
-- 🛑 EVERY FUNCTION BODY BELOW WAS COPIED FROM THE LIVE `pg_get_functiondef` AND EDITED IN PLACE,
-- never retyped, with each anchor asserted to match EXACTLY ONCE before substitution
-- (`scratchpad/edit.py`). `CREATE OR REPLACE` takes the whole body, so anything not reproduced is
-- silently deleted - which is how `2026-08-06_1316` broke the resolver for 3.5 hours.
--
-- WHAT MOVES, PRECISELY
--   PART 1  NEW  derm.fn_page_image_url(dump_folder, page)  - the one place that answers
--                "which image does this page carry?", so routes 2 and 3 cannot drift apart.
--   PART 2  derm.trg_autoplace_generated   - one assignment REMOVED, nothing else changed.
--   PART 3  derm.add_sheet_client          - the folder-wide image fallback REPLACED by PART 1.
--   PART 4  derm.add_extra_client_card     - the borrowed image REPLACED by PART 1.
--   PART 5  NEW  derm.fn_guard_page_image_injective() + the DEFERRABLE constraint trigger
--                `trg_zz_page_image_injective` on derm.address_row_map.
--
-- WHY A DEFERRABLE CONSTRAINT TRIGGER RATHER THAN A CHECK: the predicate spans rows, so a CHECK
-- cannot express it. DEFERRED so a multi-statement repair that passes through an intermediate
-- violating state inside one transaction still commits - only the end state has to be clean.
--
-- ⚠ `page` INDEXES THE IMAGE ARRAY, AND THAT IS MEASURED, NOT ASSUMED. All 138 folders have
-- contiguous pages 1..N (0 exceptions), which is what makes PART 1's array-position arm correct.
-- ⚠ And the tempting STRONGER check - "`ticket_page_images[page]` must equal the row's own
-- `image_url`" - is BLIND to this defect: on ticket-833049 both page 1 and page 2 hold address_1
-- and the array holds it twice, so both rows match and the check passes. Injectivity is the
-- predicate that actually separates the two populations.
--
-- ⚠ Rows with a NULL `white_manifest_number` are out of scope by construction: `ticket_page_images`
-- filters `white_manifest_number = p_wm`, and NULL never matches, so such a row cannot reach the
-- array it would corrupt.
--
-- RULE 8 (audit): no table or column added or changed. Two new functions and one trigger. Nothing
-- to opt in or out of; `derm.address_row_map` keeps its existing `audit_address_row_map` trigger.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. The single answer to "which image does this page carry?".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_page_image_url(p_dump_folder text, p_page integer)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
  -- Arm 1: a card already on that page has the answer. 'pending' is a placeholder, not an image,
  -- and is excluded exactly as derm.ticket_page_images excludes it.
  -- Arm 2: no card yet -> the ticket's image list, indexed by the page. Every one of the 138
  -- folders has contiguous pages 1..N (measured 2026-09-03), so `page` IS the array position.
  -- NULL means "this page has no scan on file". Callers MUST refuse rather than borrow another
  -- page's image: borrowing is the whole defect.
  SELECT COALESCE(
    (SELECT min(r.image_url)
       FROM derm.address_row_map r
      WHERE r.dump_folder = p_dump_folder
        AND r.page = p_page
        AND r.image_url <> 'pending'),
    (derm.ticket_page_images(
       (SELECT max(r2.white_manifest_number)
          FROM derm.address_row_map r2
         WHERE r2.dump_folder = p_dump_folder)))[p_page]
  );
$fn$;

COMMENT ON FUNCTION derm.fn_page_image_url(text, integer) IS
  'The image_url that a given page of a sheet carries, or NULL if that page has no scan on file. '
  'Callers must refuse on NULL: inserting a card at page N carrying page M''s image is what makes '
  'derm.ticket_page_images append a duplicate entry (ticket-833049, ticket-834742).';

REVOKE ALL ON FUNCTION derm.fn_page_image_url(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_page_image_url(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION derm.fn_page_image_url(text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- PART 2. ROUTE 1. Copied from the live body; one assignment removed, nothing else touched.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.trg_autoplace_generated()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare geo record; v_slot integer; v_img integer; v_code text;
begin
  if NEW.white_manifest_number is not null
     and NEW.stamp_placed_at is null
     and derm.fn_sheet_is_generated(NEW.white_manifest_number) then
    v_slot := derm.fn_generated_sheet_slot(NEW.matched_manifest_id);
    -- ⚠ NO row_index fallback. row_index is card-creation order and is provably
    -- unrelated to printed order (309898: printed slot 1 is row_index 5).
    -- Guessing here writes a stamp onto another client's row.
    if v_slot is not null then
      select * into geo from derm.fn_generated_row_geometry(v_slot);

      -- 2026-08-06_2110: the LOGICAL page is not the image position when the scans are stored out of
      -- printed order. Writing geo.o_page directly is inverted on ticket-310590. NULL = we do not
      -- know which image this page is, so do not place.
      v_img := derm.fn_sheet_image_position(NEW.dump_folder, geo.o_page);

      select c.client_code into v_code from public.clients c where c.id = NEW.matched_client_id;

      if v_img is not null
         and geo.o_y_pct is not null
         -- row gate, disagreement-only (same semantics as the resolver): if the scanned sheet names
         -- a DIFFERENT client on this row, refuse. No read = no opinion = unchanged behaviour.
         and (v_code is null
              or derm.fn_row_read_confirms(
                   NEW.dump_folder, v_img, ((v_slot - 1) % 5) + 1, v_code) is not false)
      then
        -- 🛑 2026-09-03: the assignment of the image position to `page` was REMOVED here.
        -- `page` is the OCR page and every card on a folder shares ONE value of it; only
        -- `stamp_page` varies. Writing the image position into `page` without a matching
        -- `image_url` made a second `page` carry page 1's image, and derm.ticket_page_images
        -- (which GROUPs BY page and takes mode(image_url)) then APPENDED a duplicate entry.
        -- It fired twice in production and corrupted the image list both times:
        -- ticket-833049 card 972 (2026-08-17), ticket-834742 card 1106 (2026-09-03).
        -- The stamp still lands on the right scan: that is what stamp_page is for.
        NEW.stamp_page      := v_img;
        NEW.stamp_x_pct     := round(geo.o_x_pct, 3);
        NEW.stamp_y_pct     := round(geo.o_y_pct, 3);
        NEW.stamp_placed_at := now();
        NEW.stamp_placed_by := 'stamp-studio-ai';
      end if;
    end if;
  end if;
  return NEW;
end $function$;


-- ---------------------------------------------------------------------------
-- PART 3. ROUTE 2. Copied from the live body; the folder-wide image fallback replaced by PART 1.
-- ---------------------------------------------------------------------------
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


-- ---------------------------------------------------------------------------
-- PART 4. ROUTE 3. Copied from the live body; the borrowed image replaced by PART 1.
-- ---------------------------------------------------------------------------
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


-- ---------------------------------------------------------------------------
-- PART 5. THE GUARD.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_guard_page_image_injective()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
DECLARE v_wm text; v_bad record;
BEGIN
  v_wm := NEW.white_manifest_number;

  -- Out of scope: derm.ticket_page_images filters `white_manifest_number = p_wm`, which NULL can
  -- never satisfy, so a NULL-white# row cannot corrupt any image list.
  IF v_wm IS NULL THEN RETURN NULL; END IF;

  -- 🛑 NO-WORSE, NOT ABSOLUTE. An UPDATE that does not move this row's (white#, page, image_url)
  -- cannot have created or worsened a violation, so it is not this write's business. Without this
  -- skip the guard would freeze every band edit, stamp clear and repair attempt on ticket-833049,
  -- which is a folder a person still has to work on. Same reasoning as derm.save_page_geometry.
  IF TG_OP = 'UPDATE'
     AND NEW.white_manifest_number IS NOT DISTINCT FROM OLD.white_manifest_number
     AND NEW.page                  IS NOT DISTINCT FROM OLD.page
     AND NEW.image_url             IS NOT DISTINCT FROM OLD.image_url
  THEN RETURN NULL; END IF;

  SELECT r.image_url, array_agg(DISTINCT r.page ORDER BY r.page) AS pages
    INTO v_bad
    FROM derm.address_row_map r
   WHERE r.white_manifest_number = v_wm
     AND r.image_url <> 'pending'
   GROUP BY r.image_url
  HAVING count(DISTINCT r.page) > 1
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION
      'white manifest % would have one image carried by more than one page (pages %, image %)',
      v_wm, v_bad.pages, v_bad.image_url
      USING ERRCODE = '23514',
            HINT = 'derm.ticket_page_images GROUPs BY page and takes mode(image_url), so a second '
                   'page holding an image another page already holds APPENDS a duplicate entry to '
                   'the image list and silently re-points every later stamp ordinal at a different '
                   'scan. `page` is the OCR page: on a folder scanned as one sheet every card '
                   'shares it and only `stamp_page` varies. If you meant "place this stamp on '
                   'image N", set stamp_page, not page. If you are adding a card to a real second '
                   'page, give it that page''s own image (derm.fn_page_image_url).';
  END IF;

  RETURN NULL;
END $fn$;

COMMENT ON FUNCTION derm.fn_guard_page_image_injective() IS
  'Constraint trigger: within one white_manifest_number, no two distinct `page` values may carry '
  'the same non-pending image_url. Deferred to commit; skips an UPDATE that moves none of '
  '(white_manifest_number, page, image_url), so a pre-existing violator stays editable.';

DROP TRIGGER IF EXISTS trg_zz_page_image_injective ON derm.address_row_map;
CREATE CONSTRAINT TRIGGER trg_zz_page_image_injective
  AFTER INSERT OR UPDATE ON derm.address_row_map
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION derm.fn_guard_page_image_injective();

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------

-- The guard is INITIALLY DEFERRED, so inside this transaction it would only fire at COMMIT and the
-- probes below could not observe it. Make it immediate for the duration of the checks.
SET CONSTRAINTS ALL IMMEDIATE;

DO $do$
DECLARE
  v_folder text := 'zz-guard-probe';
  v_wm     text := 'ZZGUARDPROBE';
  v_a      text := 'https://example.invalid/zz-guard/a.jpg';
  v_b      text := 'https://example.invalid/zz-guard/b.jpg';
  v_legit  boolean := false;
  v_refused boolean := false;
  v_editable boolean := false;
  v_moved_refused boolean := false;
  v_msg text; v_id bigint; n int; d text;
BEGIN
  -- ---- static checks on the three rewritten bodies -------------------------
  d := pg_get_functiondef('derm.trg_autoplace_generated'::regproc);
  IF d ~ 'NEW\.page\s*:=' THEN
    RAISE EXCEPTION 'VERIFY 1: trg_autoplace_generated still assigns NEW.page';
  END IF;
  IF d !~ 'NEW\.stamp_page\s*:=' THEN
    RAISE EXCEPTION 'VERIFY 1b: control failed - trg_autoplace_generated no longer assigns stamp_page either, so the body was damaged, not edited';
  END IF;

  d := pg_get_functiondef('derm.add_sheet_client'::regproc);
  IF d ~ 'min\(image_url\) INTO v_img' THEN
    RAISE EXCEPTION 'VERIFY 2: add_sheet_client still borrows an image with min(image_url)';
  END IF;
  IF d !~ 'fn_page_image_url' THEN
    RAISE EXCEPTION 'VERIFY 2b: add_sheet_client does not call fn_page_image_url';
  END IF;
  IF d !~ '_require_stamp_key' THEN
    RAISE EXCEPTION 'VERIFY 2c: control failed - add_sheet_client lost its stamp-key gate, so the body was damaged';
  END IF;

  d := pg_get_functiondef('derm.add_extra_client_card'::regproc);
  IF d ~ 'v_next, v_existing\.image_url' THEN
    RAISE EXCEPTION 'VERIFY 3: add_extra_client_card still writes the existing card''s image';
  END IF;
  IF d !~ 'fn_page_image_url' THEN
    RAISE EXCEPTION 'VERIFY 3b: add_extra_client_card does not call fn_page_image_url';
  END IF;
  IF d !~ 'gdo_id is null' THEN
    RAISE EXCEPTION 'VERIFY 3c: control failed - add_extra_client_card lost its unbound-permit refusal, so the body was damaged';
  END IF;

  -- ---- the estate is in the state this guard was measured against ----------
  SELECT count(DISTINCT r.white_manifest_number) INTO n
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.image_url <> 'pending'
     AND EXISTS (SELECT 1 FROM derm.address_row_map r2
                  WHERE r2.white_manifest_number = r.white_manifest_number
                    AND r2.image_url = r.image_url AND r2.image_url <> 'pending'
                    AND r2.page <> r.page);
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 4: % violating white manifest(s), expected exactly 1 (833049)', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map r
   WHERE r.white_manifest_number = '834742' AND r.image_url <> 'pending'
     AND EXISTS (SELECT 1 FROM derm.address_row_map r2
                  WHERE r2.white_manifest_number = '834742'
                    AND r2.image_url = r.image_url AND r2.image_url <> 'pending'
                    AND r2.page <> r.page);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4b: 834742 is violating again (% rows)', n; END IF;

  -- ---- live probes, all rolled back ---------------------------------------
  BEGIN
    -- CONTROL A (must be ACCEPTED): a GENUINE two-page folder, one image per page. This is the
    -- 17-folder legitimate population. If the guard refuses this it is unshippable.
    INSERT INTO derm.address_row_map
      (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
    VALUES (v_folder, v_wm, 1, 1, v_a, 'matched', 'high', 'guard-probe'),
           (v_folder, v_wm, 2, 1, v_b, 'matched', 'high', 'guard-probe');
    v_legit := true;

    -- CONTROL B (must be REFUSED): the exact ticket-834742 shape - a further page carrying an
    -- image an earlier page already carries.
    BEGIN
      INSERT INTO derm.address_row_map
        (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
      VALUES (v_folder, v_wm, 3, 1, v_a, 'matched', 'high', 'guard-probe');
      v_refused := false;
    EXCEPTION WHEN others THEN
      v_msg := SQLERRM;
      v_refused := (SQLERRM LIKE '%more than one page%');
    END;

    -- CONTROL C (must be ACCEPTED): the no-worse skip. ticket-833049 is a KNOWN violator and a
    -- person still has to work it; an edit that moves none of (white#, page, image_url) must pass.
    BEGIN
      UPDATE derm.address_row_map SET confidence = confidence
       WHERE dump_folder = 'ticket-833049';
      v_editable := true;
    EXCEPTION WHEN others THEN
      v_editable := false;
    END;

    -- CONTROL D (must be REFUSED): moving a card's page on that same folder, leaving it violating.
    BEGIN
      UPDATE derm.address_row_map SET page = 3
       WHERE dump_folder = 'ticket-833049' AND id = 964;
      v_moved_refused := false;
    EXCEPTION WHEN others THEN
      v_moved_refused := (SQLERRM LIKE '%more than one page%');
    END;

    RAISE EXCEPTION 'ZZ_GUARD_PROBE_ROLLBACK';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ZZ_GUARD_PROBE_ROLLBACK' THEN RAISE; END IF;
  END;

  IF NOT v_legit THEN
    RAISE EXCEPTION 'VERIFY 5: the guard REFUSED a legitimate two-page folder - it would refuse 17 real folders';
  END IF;
  IF NOT v_refused THEN
    RAISE EXCEPTION 'VERIFY 6: the guard did NOT refuse the duplicate-image shape (got: %) - it is a dead instrument',
      coalesce(v_msg, 'no error at all');
  END IF;
  IF NOT v_editable THEN
    RAISE EXCEPTION 'VERIFY 7: the no-worse skip does not work - ticket-833049 is now frozen against every edit';
  END IF;
  IF NOT v_moved_refused THEN
    RAISE EXCEPTION 'VERIFY 8: a page MOVE on the known violator was allowed - the skip is too wide';
  END IF;

  -- ---- the probe left nothing behind --------------------------------------
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'zz-guard-probe' OR white_manifest_number = 'ZZGUARDPROBE';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 9: % probe row(s) survived the rollback', n; END IF;

  -- ---- the trigger is the shape it claims to be ---------------------------
  SELECT count(*) INTO n FROM pg_trigger
   WHERE tgrelid = 'derm.address_row_map'::regclass
     AND tgname = 'trg_zz_page_image_injective'
     AND tgdeferrable AND tginitdeferred AND tgenabled = 'O';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 10: the constraint trigger is missing, not deferrable, or disabled'; END IF;

  -- ---- grants -------------------------------------------------------------
  IF has_function_privilege('anon', 'derm.fn_page_image_url(text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 11: anon can execute fn_page_image_url';
  END IF;

  RAISE NOTICE 'VERIFY ok: three routes closed, guard refuses the defect shape and accepts a real two-page folder, ticket-833049 stays editable';
END $do$;

SET CONSTRAINTS ALL DEFERRED;

COMMIT;

-- ---------------------------------------------------------------------------
-- ROLLBACK: re-apply the three ORIGINAL bodies (they are in git history, and in
-- scratchpad/orig_*.sql at the time of writing), then
--   DROP TRIGGER trg_zz_page_image_injective ON derm.address_row_map;
--   DROP FUNCTION derm.fn_guard_page_image_injective();
--   DROP FUNCTION derm.fn_page_image_url(text, integer);
-- ---------------------------------------------------------------------------
