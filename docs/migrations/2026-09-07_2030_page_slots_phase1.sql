-- ============================================================================================
-- 2026-09-07_2030_page_slots_phase1.sql
--
-- Phase 1 of geometry-first page slots: the printed rows of a page become first-class objects, so
-- a page can be measured BEFORE anyone is stamped on it, and a client is then dropped into a slot
-- instead of being placed at a free-floating y coordinate.
--
-- WHY (Fred, 2026-09-07): "Why can't i set the bands first so they become like slots for the
-- clients so when i stamp them after it will be perfectly aligned?" and then "build phase 1".
-- Spec: docs/superpowers/specs/2026-09-07-geometry-first-page-slots-design.md
--
-- 🛑 WHY THIS IS WORTH DOING, IN ONE MEASUREMENT FROM TODAY. On ticket-833049 page 2, 221-YAS's
-- stamp sat at 44.480 while its own printed boundary is at 44.090. It missed its row by 0.39 of a
-- percent, about three pixels, and landed in Le Specialita's row. Under today's model the band is
-- then built FROM that stamp, so every guard passes: G13, the only check tying a band to its
-- owner, is satisfied by the wrong stamp. Under slots, "slot 3" is a discrete choice and
-- "0.39% into slot 4" is not expressible. The wrong answer stops being reachable instead of being
-- caught later by an audit.
--
-- ============================================================================================
-- 🛑 DELIBERATE DEVIATION FROM THE SPEC, AND THE MEASUREMENT THAT FORCED IT.
--
-- The spec proposed resolving the band in the view:
--       band_y0_pct = COALESCE(manual_y0, slot_y0, derived_y0)
-- Measured before writing a line of it, that is the WRONG shape here. THIRTEEN objects read
-- derm.address_row_map.band_y0_pct DIRECTLY rather than through derm.v_stamp_row_bands:
--   views: v_band_edge_check, v_band_edges_off_rule, v_blackout_blocked_sheets,
--          v_served_blackout_short, v_stamp_row_bands, v_stamp_rows
--   fns:   _page_geometry_violations, audit_pack, clear_stamp_position, fn_blackout_targets,
--          fn_sheet_publishable_detail, save_page_geometry, set_row_band
-- and one of them decides whether a sheet may publish at all. derm.v_blackout_blocked_sheets
-- classifies a band as DERIVED with `arm.band_y0_pct IS NULL` against the raw column, so a card
-- banded only through a view arm would read as "still derived", raise needs_snap_then_extent, and
-- silently block the folder. Chasing that through 13 objects on a regulator-facing redaction path,
-- to reach the same visible outcome, is a bad trade.
--
-- ⇒ ASSIGNMENT WRITES THE BAND FROM THE SLOT, and `slot_index` records the link. Every existing
-- consumer keeps working with no change at all, and this migration becomes PURELY ADDITIVE: one
-- new table, one new nullable column, three new functions, one new view. It changes the behaviour
-- of nothing that exists today. VERIFY 1 proves that rather than claiming it.
--
-- ⚠ The cost of the deviation, stated so it is not discovered later: a band is a SNAPSHOT of its
-- slot at assignment time, not a live reference, so re-measuring a page does not move the bands of
-- clients already assigned to it. That is why save_page_slots REFUSES to rewrite a page that has
-- assigned cards (see below) rather than letting the two drift apart silently.
-- ============================================================================================
--
-- ⚠ ORDERING INSIDE assign_card_to_slot IS LOAD-BEARING: STAMP FIRST, THEN BAND. derm.set_row_band
-- refuses a band on a row with no stamp point, and its comment says why: derm.v_stamp_row_bands is
-- built WHERE stamp_y_pct IS NOT NULL, so a banded-but-unstamped row drops out of it, fails
-- fn_blackout_targets' whole-folder closed-world gate, and freezes EVERY document in the folder.
-- That is ticket-828604. So assignment places the stamp before it writes the band.
--
-- RULE 8: derm.page_slots OPTS IN. It is human-edited and it decides what is blacked out on a
-- regulator-facing document. derm.address_row_map is unchanged apart from one nullable column,
-- and adding a column to an already-audited table is captured automatically.
-- ============================================================================================

BEGIN;

-- Snapshot the entire band resolution BEFORE anything, so "purely additive" is measured.
CREATE TEMP TABLE _bands_before ON COMMIT DROP AS
  SELECT id, dump_folder, effective_page, band_y0_pct, band_y1_pct, band_is_manual
    FROM derm.v_stamp_row_bands;

-- ============================================================================================
-- 1. THE SLOTS
-- ============================================================================================
CREATE TABLE IF NOT EXISTS derm.page_slots (
  dump_folder    text        NOT NULL,
  effective_page integer     NOT NULL,
  slot_index     integer     NOT NULL,
  y0_pct         numeric     NOT NULL,
  y1_pct         numeric     NOT NULL,
  source         text        NOT NULL,
  set_by         text        NOT NULL,
  set_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_folder, effective_page, slot_index),
  CONSTRAINT page_slots_range_chk CHECK (y0_pct >= 0 AND y1_pct <= 100 AND y0_pct < y1_pct),
  CONSTRAINT page_slots_index_chk CHECK (slot_index >= 1)
);

COMMENT ON TABLE derm.page_slots IS
  'The printed rows of one scanned page, as intervals between consecutive printed boundary rules. '
  'One row per PRINTED slot, including slots no client occupies, which is the whole point: an '
  'empty or unowned printed row is representable here and is not representable as a band, because '
  'a band hangs off a client. Written by derm.save_page_slots from derm.v_page_printed_rules, so '
  'the geometry is whatever a person drew or the detector found, never re-derived on read.';
COMMENT ON COLUMN derm.page_slots.source IS
  'The scan whose boundaries produced these slots, e.g. human-v1-2026-09-07. Copied from '
  'derm.v_page_printed_rules so a slot set can always be traced to the measurement behind it.';

DROP TRIGGER IF EXISTS audit_page_slots ON derm.page_slots;
CREATE TRIGGER audit_page_slots
  AFTER INSERT OR UPDATE OR DELETE ON derm.page_slots
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Supabase ALTER DEFAULT PRIVILEGES hands out grants nobody wrote. Revoke explicitly, then grant
-- the intended set. VERIFY 3 reads relacl afterwards rather than trusting these statements.
REVOKE ALL ON derm.page_slots FROM PUBLIC, anon;
GRANT SELECT ON derm.page_slots TO authenticated, service_role;

ALTER TABLE derm.address_row_map ADD COLUMN IF NOT EXISTS slot_index integer;
COMMENT ON COLUMN derm.address_row_map.slot_index IS
  'The derm.page_slots slot this card was assigned to, on its own effective_page. Provenance for '
  'the band, and the join that makes an unclaimed printed slot detectable. The band VALUES live in '
  'band_y0_pct/band_y1_pct as a snapshot taken at assignment: 13 objects read those columns '
  'directly, including the publish gate, so the slot is the link and not the resolution path.';

-- ============================================================================================
-- 2. BOUNDARIES -> SLOTS.  Read-only, so a caller can see what would be written.
-- ============================================================================================
CREATE OR REPLACE FUNCTION derm.fn_page_slots_preview(p_dump_folder text, p_effective_page integer)
RETURNS TABLE (slot_index integer, y0_pct numeric, y1_pct numeric, source text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $fn$
  WITH b AS (
    SELECT pr.rule_pct, pr.source,
           row_number() OVER (ORDER BY pr.rule_pct) AS k
      FROM derm.v_page_printed_rules pr
     WHERE pr.dump_folder = p_dump_folder
       AND pr.effective_page = p_effective_page
       AND pr.kind = 'boundary'
  )
  SELECT a.k::integer, round(a.rule_pct, 3), round(c.rule_pct, 3), a.source
    FROM b a JOIN b c ON c.k = a.k + 1
   ORDER BY a.k;
$fn$;

COMMENT ON FUNCTION derm.fn_page_slots_preview(text, integer) IS
  'What derm.save_page_slots would write for this page: the intervals between consecutive printed '
  'BOUNDARY rules of the page''s active scan. Dividers are excluded on purpose, they sit inside a '
  'slot rather than bounding one.';

REVOKE ALL ON FUNCTION derm.fn_page_slots_preview(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_page_slots_preview(text, integer) TO authenticated, service_role;

-- ============================================================================================
-- 3. WRITE THE SLOTS.  This is the "measure the page before anyone is on it" verb.
-- ============================================================================================
CREATE OR REPLACE FUNCTION derm.save_page_slots(p_dump_folder text, p_effective_page integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $fn$
DECLARE
  v_n        integer;
  v_assigned integer;
BEGIN
  PERFORM derm._require_stamp_key();

  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'dump_folder and effective_page are required';
  END IF;

  -- 🛑 A page whose clients are already assigned must not be silently re-indexed. This is the
  -- address_sheet_clients.rows_printed lesson: recomputing a printed layout under already-placed
  -- work moved stamps onto other clients' rows on five sheets. Re-measuring an assigned page is a
  -- deliberate act and needs its own path, so refuse here rather than guess.
  SELECT count(*) INTO v_assigned
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder
     AND COALESCE(r.stamp_page, r.page) = p_effective_page
     AND r.slot_index IS NOT NULL;
  IF v_assigned > 0 THEN
    RAISE EXCEPTION 'refusing to rewrite slots for % page %: % card(s) are already assigned to a '
                    'slot here. Re-measuring an assigned page would re-index them silently.',
                    p_dump_folder, p_effective_page, v_assigned;
  END IF;

  SELECT count(*) INTO v_n FROM derm.fn_page_slots_preview(p_dump_folder, p_effective_page);
  IF v_n < 1 THEN
    RAISE EXCEPTION 'no slots can be formed for % page %: it needs at least two printed BOUNDARY '
                    'rules on record, and derm.v_page_printed_rules has fewer. Measure the page '
                    'first.', p_dump_folder, p_effective_page;
  END IF;

  DELETE FROM derm.page_slots
   WHERE dump_folder = p_dump_folder AND effective_page = p_effective_page;

  INSERT INTO derm.page_slots
    (dump_folder, effective_page, slot_index, y0_pct, y1_pct, source, set_by)
  SELECT p_dump_folder, p_effective_page, p.slot_index, p.y0_pct, p.y1_pct, p.source,
         derm._actor('stamp-studio')
    FROM derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;

  RETURN v_n;
END
$fn$;

COMMENT ON FUNCTION derm.save_page_slots(text, integer) IS
  'Materialise the printed slots of a page from its active scan''s boundary rules. Works on a page '
  'with NO stamps and no cards, which is the point: measure first, assign later. REFUSES a page '
  'that already has assigned cards, so re-measuring can never silently re-index placed work.';

REVOKE ALL ON FUNCTION derm.save_page_slots(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.save_page_slots(text, integer) TO authenticated, service_role;

-- ============================================================================================
-- 4. DROP A CLIENT INTO A SLOT.  Stamp first, then band: see the header.
-- ============================================================================================
CREATE OR REPLACE FUNCTION derm.assign_card_to_slot(p_row_id bigint, p_slot_index integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $fn$
DECLARE
  v_folder   text;
  v_eff      integer;
  v_x        numeric;
  v_stamp_y  numeric;
  v_y0       numeric;
  v_y1       numeric;
  v_centre   numeric;
  v_moved    boolean := false;
BEGIN
  PERFORM derm._require_stamp_key();

  IF p_row_id IS NULL OR p_slot_index IS NULL THEN
    RAISE EXCEPTION 'row id and slot index are required';
  END IF;

  SELECT r.dump_folder, COALESCE(r.stamp_page, r.page), r.stamp_x_pct, r.stamp_y_pct
    INTO v_folder, v_eff, v_x, v_stamp_y
    FROM derm.address_row_map r WHERE r.id = p_row_id;
  IF v_folder IS NULL THEN
    RAISE EXCEPTION 'address_row_map id % not found', p_row_id;
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
                AND r2.slot_index = p_slot_index AND r2.id <> p_row_id) THEN
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
$fn$;

COMMENT ON FUNCTION derm.assign_card_to_slot(bigint, integer) IS
  'Put one client in one printed slot. Writes the band from the slot, records the link in '
  'slot_index, and places the stamp at the slot centre when it is missing or outside the slot, so '
  'a stamp can never sit in a different printed row from the band it produced. Refuses a slot that '
  'another client already holds. Stamp is written BEFORE the band on purpose: see set_row_band.';

REVOKE ALL ON FUNCTION derm.assign_card_to_slot(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.assign_card_to_slot(bigint, integer) TO authenticated, service_role;

-- ============================================================================================
-- 5. THE DETECTOR THIS BUYS.  A printed slot nobody occupies.
-- ============================================================================================
CREATE OR REPLACE VIEW derm.v_unclaimed_slots AS
  SELECT s.dump_folder,
         s.effective_page,
         s.slot_index,
         s.y0_pct,
         s.y1_pct,
         s.source,
         (SELECT count(*) FROM derm.address_row_map r
           WHERE r.dump_folder = s.dump_folder
             AND COALESCE(r.stamp_page, r.page) = s.effective_page) AS cards_on_page,
         (SELECT count(*) FROM derm.page_slots s2
           WHERE s2.dump_folder = s.dump_folder
             AND s2.effective_page = s.effective_page)               AS slots_on_page
    FROM derm.page_slots s
   WHERE NOT EXISTS (
     SELECT 1 FROM derm.address_row_map r
      WHERE r.dump_folder = s.dump_folder
        AND COALESCE(r.stamp_page, r.page) = s.effective_page
        AND r.slot_index = s.slot_index);

COMMENT ON VIEW derm.v_unclaimed_slots IS
  'Printed slots with no client in them. NOT a defect list: a six-slot pad carrying five clients '
  'has one legitimately empty row. It is a WORKLIST for a person to eyeball, because the dangerous '
  'case looks identical from geometry alone: a slot with a facility PRINTED in it that we hold no '
  'card for. That is what leaked on ticket-310590 p2 on 2026-08-19, and until now nothing in the '
  'database could see it at all.';

REVOKE ALL ON derm.v_unclaimed_slots FROM PUBLIC, anon;
GRANT SELECT ON derm.v_unclaimed_slots TO authenticated, service_role;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n     int;
  v_acl   text;
  v_res   jsonb;
  v_y0    numeric;
  v_y1    numeric;
  v_row   bigint;
  v_before_band numeric;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. PURELY ADDITIVE. Not one row of band resolution moved.
  --    CONTROL: the snapshot must hold the full population, or this compares nothing.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _bands_before;
  IF v_n < 700 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: snapshot holds % rows, expected the full ~714', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT id, dump_folder, effective_page, band_y0_pct, band_y1_pct, band_is_manual FROM _bands_before
     EXCEPT
     SELECT id, dump_folder, effective_page, band_y0_pct, band_y1_pct, band_is_manual FROM derm.v_stamp_row_bands)
    UNION ALL
    (SELECT id, dump_folder, effective_page, band_y0_pct, band_y1_pct, band_is_manual FROM derm.v_stamp_row_bands
     EXCEPT
     SELECT id, dump_folder, effective_page, band_y0_pct, band_y1_pct, band_is_manual FROM _bands_before)) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % band row(s) changed. This migration must be additive.', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. Nothing became publishable and no slot exists yet.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.page_slots;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % slot(s) were written', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE slot_index IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % card(s) were assigned', v_n; END IF;

  ------------------------------------------------------------------------------------------
  -- 3. GRANTS READ OFF relacl, NOT off the GRANT statements above. CREATE TABLE hands out
  --    privileges before any GRANT runs, and a GRANT cannot remove what it did not create.
  ------------------------------------------------------------------------------------------
  IF has_table_privilege('anon', 'derm.page_slots', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: anon can read derm.page_slots';
  END IF;
  IF has_table_privilege('anon', 'derm.v_unclaimed_slots', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: anon can read derm.v_unclaimed_slots';
  END IF;
  IF NOT has_table_privilege('authenticated', 'derm.page_slots', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: authenticated cannot read derm.page_slots';
  END IF;
  IF has_table_privilege('authenticated', 'derm.page_slots', 'INSERT')
     OR has_table_privilege('authenticated', 'derm.page_slots', 'UPDATE')
     OR has_table_privilege('authenticated', 'derm.page_slots', 'DELETE') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: authenticated can WRITE derm.page_slots directly; it must go '
                    'through the RPCs';
  END IF;
  IF has_function_privilege('anon', 'derm.save_page_slots(text,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'derm.assign_card_to_slot(bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: anon can execute a slot write function';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 4. Rule 8: the audit trigger is really attached.
  ------------------------------------------------------------------------------------------
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace
     WHERE n.nspname='derm' AND c.relname='page_slots'
       AND pn.nspname='audit' AND p.proname='log_change' AND NOT t.tgisinternal) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: derm.page_slots carries no audit trigger';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 5. THE WHOLE PATH, EXERCISED ON REAL GEOMETRY, ROLLED BACK. Nothing above proves the
  --    feature WORKS: it proves it changed nothing. ticket-833049 page 1 carries Fred's 7
  --    hand-drawn boundaries, so it is the honest fixture.
  ------------------------------------------------------------------------------------------
  BEGIN
    SELECT count(*) INTO v_n FROM derm.fn_page_slots_preview('ticket-833049', 1);
    IF v_n <> 6 THEN
      RAISE EXCEPTION 'VERIFY 5 SETUP FAILED: preview gives % slots for 833049 p1, expected 6 '
                      '(7 hand-drawn boundaries)', v_n;
    END IF;

    SELECT derm.save_page_slots('ticket-833049', 1) INTO v_n;
    IF v_n <> 6 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: save wrote % slots, expected 6', v_n; END IF;

    -- The unclaimed worklist must now show all six, because nobody is assigned yet.
    SELECT count(*) INTO v_n FROM derm.v_unclaimed_slots WHERE dump_folder='ticket-833049';
    IF v_n <> 6 THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: v_unclaimed_slots shows % of 6 slots', v_n;
    END IF;

    -- Assign the top client (179-CIG, stamp 32.621) to slot 1 and prove the band comes from the
    -- SLOT rather than from wherever the card already was.
    -- 🛑 MAKING THIS DISCRIMINATING TOOK A SECOND ATTEMPT, and the first one is worth recording.
    -- It asserted the card had NO band beforehand. That was true when this was written and false
    -- an hour later: Fred saved both pages, so all ten cards now carry bands, and the control
    -- correctly refused to apply. But simply dropping the control would have been worse, because
    -- Fred's saved bands ARE the slot intervals, so "the band equals the slot" would then have
    -- passed no matter what assign_card_to_slot did. The fixture therefore MOVES the band off its
    -- slot first, and asserts that it was moved, before proving assignment brings it back.
    SELECT r.id INTO v_row
      FROM derm.address_row_map r
     WHERE r.dump_folder='ticket-833049' AND COALESCE(r.stamp_page,r.page)=1
     ORDER BY r.stamp_y_pct LIMIT 1;

    SELECT y0_pct, y1_pct INTO v_y0, v_y1 FROM derm.page_slots
     WHERE dump_folder='ticket-833049' AND effective_page=1 AND slot_index=1;

    UPDATE derm.address_row_map
       SET band_y0_pct = round(v_y0 - 4, 3), band_y1_pct = round(v_y1 - 4, 3)
     WHERE id = v_row;

    SELECT band_y0_pct INTO v_before_band FROM derm.address_row_map WHERE id = v_row;
    IF v_before_band = round(v_y0, 3) THEN
      RAISE EXCEPTION 'VERIFY 5 CONTROL FAILED: the band still equals the slot after being moved '
                      'off it, so the assertion below cannot discriminate';
    END IF;

    v_res := derm.assign_card_to_slot(v_row, 1);

    SELECT band_y0_pct INTO v_before_band FROM derm.address_row_map WHERE id = v_row;
    IF v_before_band IS DISTINCT FROM round(v_y0,3) THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: band top is % but the slot is %', v_before_band, v_y0;
    END IF;
    SELECT band_y1_pct INTO v_before_band FROM derm.address_row_map WHERE id = v_row;
    IF v_before_band IS DISTINCT FROM round(v_y1,3) THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: band bottom is % but the slot is %', v_before_band, v_y1;
    END IF;
    IF (v_res->>'stamp_moved')::boolean THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: the stamp was moved, but 32.621 is already inside slot 1 '
                      '(%..%); a correctly placed human stamp must be left alone', v_y0, v_y1;
    END IF;

    -- That slot has left the worklist, and only that one.
    SELECT count(*) INTO v_n FROM derm.v_unclaimed_slots WHERE dump_folder='ticket-833049';
    IF v_n <> 5 THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: worklist shows % unclaimed, expected 5 after one assignment', v_n;
    END IF;

    -- Re-measuring an ASSIGNED page must be refused.
    BEGIN
      PERFORM derm.save_page_slots('ticket-833049', 1);
      RAISE EXCEPTION 'VERIFY 5 FAILED: re-measuring a page with an assigned card was ALLOWED';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already assigned to a slot%' THEN RAISE; END IF;
    END;

    -- A second client cannot take the same slot.
    BEGIN
      PERFORM derm.assign_card_to_slot(
        (SELECT r.id FROM derm.address_row_map r
          WHERE r.dump_folder='ticket-833049' AND COALESCE(r.stamp_page,r.page)=1 AND r.id <> v_row
          ORDER BY r.stamp_y_pct LIMIT 1), 1);
      RAISE EXCEPTION 'VERIFY 5 FAILED: two clients were allowed into one printed slot';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already taken by another client%' THEN RAISE; END IF;
    END;

    -- An unmeasured page has no slots, so assignment there is refused rather than guessed.
    BEGIN
      PERFORM derm.assign_card_to_slot(v_row, 99);
      RAISE EXCEPTION 'VERIFY 5 FAILED: assignment to a nonexistent slot was allowed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%no slot %' THEN RAISE; END IF;
    END;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  ------------------------------------------------------------------------------------------
  -- 6. THE FIXTURE LEFT NOTHING BEHIND, and band resolution is STILL untouched.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.page_slots;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % fixture slot(s) survived', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE slot_index IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % fixture assignment(s) survived', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT id, band_y0_pct, band_y1_pct FROM _bands_before
     EXCEPT SELECT id, band_y0_pct, band_y1_pct FROM derm.v_stamp_row_bands)
    UNION ALL
    (SELECT id, band_y0_pct, band_y1_pct FROM derm.v_stamp_row_bands
     EXCEPT SELECT id, band_y0_pct, band_y1_pct FROM _bands_before)) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % band row(s) differ after the fixture rolled back', v_n;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: additive (0 of % band rows moved), grants correct, audited, and '
               'the whole measure-then-assign path exercised on real geometry and rolled back.',
               (SELECT count(*) FROM _bands_before);
END
$verify$;

COMMIT;
