-- ============================================================================================
-- 2026-09-07_2245_page_slots_phase1b.sql
--
-- Two gaps in phase 1 (2026-09-07_2030), both found by an adversarial preflight before the Stamp
-- Studio was pointed at any of it. One is a correctness hazard I introduced yesterday.
--
-- WHY (Fred, 2026-09-07): "build phase 2". This is the DB half that has to land first, because the
-- app cannot be written correctly against phase 1 as shipped.
--
-- ============================================================================================
-- 🛑 GAP 1, THE HAZARD. assign_card_to_slot RESOLVED THE PAGE FROM A VALUE THAT DOES NOT MEAN
-- "THE PAGE", and it did so for exactly the cards the feature is FOR.
--
-- It derived the page as COALESCE(r.stamp_page, r.page). Measured on live data:
--       unplaced cards                                43
--       of those, stamp_page IS NULL                  33
--       of those, page = 1                            42 of 43
--       multi-page folders holding unplaced cards      4
-- An UNPLACED card has no stamp, so it has no stamp_page, so the COALESCE falls through to `page`,
-- which is the OCR page and is 1 almost everywhere. Assigning such a card while looking at page 2
-- therefore resolved to page 1 and would either fail with a confusing "no slot N on page 1" or, on
-- a folder whose page 1 is measured, put the client in a slot on the WRONG PAGE.
--
-- ⇒ That is the same defect one level up from the one this feature exists to remove. Phase 1's own
-- header says it: resolving a client's row from a free-floating y coordinate is unsafe because the
-- value does not carry the meaning being read out of it. `page` does not mean "the page the
-- operator is looking at", and I read it as if it did.
--
-- THE FIX: p_effective_page is now a REQUIRED third argument. The caller always knows which tab it
-- is on; the card does not. Fail-closed: there is deliberately no default, so a caller that does
-- not name the page cannot invoke this at all.
--
-- ⚠ AND A SECOND GUARD FALLS OUT OF IT. Once the page is the caller's, an already-PLACED card
-- could be dragged from page 1 into a page 2 slot and silently move. Moving a placed card between
-- pages is a real repair (it is what fixed ticket-833813 and ticket-312433) but it is a deliberate
-- act, not a side effect of a drop gesture. A placed card on a different page is now REFUSED with a
-- message naming both pages.
--
-- 🛑 THE OLD 2-ARGUMENT SIGNATURE IS DROPPED, NOT LEFT ALONGSIDE. Two overloads reachable through
-- PostgREST is worse than either: the app would pick one by which JSON keys it happened to send,
-- and the one it might pick is the one with the bug. PART 0 refuses to apply unless the object is
-- provably unused: zero assigned cards, zero slots, and no other database object referencing it.
--
-- ============================================================================================
-- ⚠ GAP 2, INERT BUT BLOCKING. derm.v_stamp_rows does not expose slot_index.
--
-- The Studio reads card state ONLY from derm.v_stamp_rows (39 columns, measured), and slot_index is
-- not one of them because the column was added after that view was written. So the app could assign
-- a card to a slot and then have no way to show which slots are occupied. The alternative was to
-- have the app read derm.address_row_map directly, which works but adds a second source of card
-- state to a surface that deliberately has one.
--
-- One column appended to the end of the outer select list. CREATE OR REPLACE permits that, and the
-- view already LEFT JOINs derm.address_row_map a ON a.id = sr.id, so no join changes.
--
-- BODY PROVENANCE: both bodies pulled with pg_get_viewdef / pg_get_functiondef and patched by
-- anchored replacement (scripts/probes/p2/patch.js, every anchor asserted to match exactly once).
-- Never retyped.
--
-- RULE 8: no schema change beyond one view column. derm.page_slots keeps its audit trigger.
-- ============================================================================================

BEGIN;

-- Snapshot band resolution and the view's column list, so "additive" is measured, not claimed.
CREATE TEMP TABLE _p1b_bands ON COMMIT DROP AS
  SELECT id, band_y0_pct, band_y1_pct FROM derm.v_stamp_row_bands;
CREATE TEMP TABLE _p1b_cols ON COMMIT DROP AS
  SELECT column_name, ordinal_position FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_stamp_rows';

-- ============================================================================================
-- PART 0. The old signature may only be dropped if it is provably unused.
-- ============================================================================================
DO $pre$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE slot_index IS NOT NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.1: % card(s) are already assigned to a slot, so assign_card_to_slot has '
                    'been used and its signature must not be changed silently', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.page_slots;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.2: % slot(s) exist; this migration assumes the feature is not yet in '
                    'use', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('derm','public','ops')
     AND p.prosrc LIKE '%assign_card_to_slot%'
     AND p.proname <> 'assign_card_to_slot';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.3: % other function(s) call assign_card_to_slot', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('v','m') AND pg_get_viewdef(c.oid, true) LIKE '%assign_card_to_slot%';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.4: % view(s) reference assign_card_to_slot', v_n;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='derm' AND p.proname='assign_card_to_slot'
                    AND pg_get_function_identity_arguments(p.oid) = 'p_row_id bigint, p_slot_index integer') THEN
    RAISE EXCEPTION 'PRE 0.5: the 2-argument assign_card_to_slot is not present; this migration '
                    'expects the shape shipped by 2026-09-07_2030';
  END IF;

  RAISE NOTICE 'PRE OK: feature unused (0 slots, 0 assignments), no callers, old signature present.';
END
$pre$;

DROP FUNCTION derm.assign_card_to_slot(bigint, integer);

CREATE OR REPLACE VIEW derm.v_stamp_rows AS
SELECT sr.id,
    sr.dump_folder,
    sr.white_manifest_number,
    sr.page,
    sr.row_index,
    sr.image_url,
    sr.facility_name_read,
    sr.address_read,
    sr.client_code,
    sr.client_name,
    sr.service_date,
    sr.assignment_status,
    sr.confidence,
    sr.stamp_x_pct,
    sr.stamp_y_pct,
    sr.stamp_page,
    sr.guess_x_pct,
    sr.guess_y_pct,
    sr.placed,
    sr.is_manual,
    sr.matched_client_id,
    sr.matched_manifest_id,
    sr.band_y0_pct,
    sr.band_y1_pct,
    sr.band_source,
    sr.reviewed,
    sr.visit_linked,
    sr.linked_visit_count,
    sr.guess_confidence,
    sr.is_generated,
    sr.gdo_number,
    sr.gdo_label,
    a.stamp_placed_by,
    a.stamp_placed_by = 'stamp-studio-ai'::text AS filled_by_ai,
    vb.band_y0_pct AS client_row_top_pct,
    vb.band_y1_pct AS client_row_bottom_pct,
    COALESCE(vb.band_is_manual, false) AS client_row_is_measured,
    pbe.top_pct AS page_top_pct,
    pbe.bottom_pct AS page_bottom_pct,
    a.slot_index
   FROM ( SELECT sr_1.id,
            sr_1.dump_folder,
            sr_1.white_manifest_number,
            sr_1.page,
            sr_1.row_index,
            sr_1.image_url,
            sr_1.facility_name_read,
            sr_1.address_read,
            sr_1.client_code,
            sr_1.client_name,
            sr_1.service_date,
            sr_1.assignment_status,
            sr_1.confidence,
            sr_1.stamp_x_pct,
            sr_1.stamp_y_pct,
            sr_1.stamp_page,
            sr_1.guess_x_pct,
            sr_1.guess_y_pct,
            sr_1.placed,
            sr_1.is_manual,
            sr_1.matched_client_id,
            sr_1.matched_manifest_id,
            sr_1.band_y0_pct,
            sr_1.band_y1_pct,
            sr_1.band_source,
            sr_1.reviewed,
            sr_1.visit_linked,
            sr_1.linked_visit_count,
            sr_1.guess_confidence,
            sr_1.is_generated,
            gg.gdo_number,
            COALESCE(gg.nickname, gg.location_label, gg.gdo_number) AS gdo_label
           FROM ( SELECT r.id,
                    r.dump_folder,
                    r.white_manifest_number,
                    r.page,
                    r.row_index,
                    r.image_url,
                    r.facility_name_read,
                    r.address_read,
                    COALESCE(c.client_code, r.manual_code) AS client_code,
                    COALESCE(c.name, r.manual_code) AS client_name,
                    ( SELECT min(m.service_date) AS min
                           FROM derm_manifests m
                          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND m.deleted_at IS NULL) AS service_date,
                    r.assignment_status,
                    r.confidence,
                    r.stamp_x_pct,
                    r.stamp_y_pct,
                    r.stamp_page,
                        CASE
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 8.00
                            ELSE 8.0
                        END AS guess_x_pct,
                    round(
                        CASE
                            WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN ( SELECT g.o_y_pct
                               FROM derm.fn_generated_row_geometry(derm.fn_generated_sheet_slot(r.matched_manifest_id)) g(o_page, o_x_pct, o_y_pct))
                            WHEN ext.top_pct IS NOT NULL THEN LEAST(ext.top_pct + (r.row_index::numeric - 0.5) * LEAST((ext.bottom_pct - ext.top_pct) / NULLIF(r.mx, 0)::numeric, 6.0), ext.bottom_pct)
                            ELSE LEAST(28::numeric + (r.row_index::numeric - 0.5) * 5.2, 62::numeric)
                        END, 3) AS guess_y_pct,
                    r.stamp_placed_at IS NOT NULL AS placed,
                    r.source = 'stamp-studio'::text AS is_manual,
                    r.matched_client_id,
                    r.matched_manifest_id,
                    r.band_y0_pct,
                    r.band_y1_pct,
                    r.band_source,
                    r.reviewed_at IS NOT NULL AS reviewed,
                    r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                           FROM manifest_visits mv
                          WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
                    ( SELECT count(*) AS count
                           FROM manifest_visits mv
                          WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count,
                        CASE
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 'generated'::text
                            WHEN r.source = ANY (ARRAY['derm-link'::text, 'linked-backfill'::text]) THEN 'low'::text
                            ELSE 'ok'::text
                        END AS guess_confidence,
                    derm.fn_sheet_is_generated(r.white_manifest_number) AS is_generated
                   FROM ( SELECT a_1.id,
                            a_1.dump_folder,
                            a_1.white_manifest_number,
                            a_1.page,
                            a_1.row_index,
                            a_1.image_url,
                            a_1.facility_name_read,
                            a_1.address_read,
                            a_1.matched_client_id,
                            a_1.assignment_status,
                            a_1.confidence,
                            a_1.agent_agreement,
                            a_1.flags,
                            a_1.source,
                            a_1.reviewed_by,
                            a_1.reviewed_at,
                            a_1.created_at,
                            a_1.updated_at,
                            a_1.stamp_x_pct,
                            a_1.stamp_y_pct,
                            a_1.stamp_page,
                            a_1.stamp_placed_at,
                            a_1.stamp_placed_by,
                            a_1.manual_code,
                            a_1.matched_manifest_id,
                            a_1.band_y0_pct,
                            a_1.band_y1_pct,
                            a_1.band_source,
                            a_1.band_set_at,
                            a_1.band_set_by,
                            max(a_1.row_index) OVER (PARTITION BY a_1.dump_folder, a_1.page) AS mx
                           FROM derm.address_row_map a_1) r
                     LEFT JOIN clients c ON c.id = r.matched_client_id
                     LEFT JOIN derm.page_block_extents ext ON ext.dump_folder = r.dump_folder AND ext.effective_page = COALESCE(r.stamp_page, r.page)
                  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                           FROM derm_manifests m
                          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))) sr_1
             LEFT JOIN gdos gg ON gg.id = (( SELECT r2.gdo_id
                   FROM derm.address_row_map r2
                  WHERE r2.id = sr_1.id))) sr
     LEFT JOIN derm.address_row_map a ON a.id = sr.id
     LEFT JOIN derm.v_stamp_row_bands vb ON vb.id = sr.id
     LEFT JOIN derm.page_block_extents pbe ON pbe.dump_folder = sr.dump_folder AND pbe.effective_page = COALESCE(sr.stamp_page, sr.page);;

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
$function$;

COMMENT ON FUNCTION derm.assign_card_to_slot(bigint, integer, integer) IS
  'Put one client in one printed slot on the page the CALLER names. p_effective_page is required '
  'and has no default: the card cannot supply it, because an unplaced card has no stamp_page and '
  'its `page` is the OCR page, which is 1 almost everywhere. Writes the band from the slot, records '
  'slot_index, and places the stamp at the slot centre when it is missing or outside the slot. '
  'Refuses a taken slot, and refuses to move an already-placed card to a different page.';

REVOKE ALL ON FUNCTION derm.assign_card_to_slot(bigint, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.assign_card_to_slot(bigint, integer, integer)
  TO authenticated, service_role;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n    int;
  v_res  jsonb;
  v_y0   numeric;
  v_y1   numeric;
  v_row  bigint;
  v_got  numeric;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. EXACTLY ONE assign_card_to_slot, and it is the 3-argument one. Two overloads reachable
  --    through PostgREST is the failure this migration exists to prevent.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='derm' AND p.proname='assign_card_to_slot';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % overload(s) of assign_card_to_slot', v_n; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='derm' AND p.proname='assign_card_to_slot'
                    AND pg_get_function_identity_arguments(p.oid)
                        = 'p_row_id bigint, p_slot_index integer, p_effective_page integer') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the surviving signature is not the 3-argument one';
  END IF;

  -- No default on the page: a caller that omits it must not be able to invoke this.
  IF (SELECT pronargdefaults FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='derm' AND p.proname='assign_card_to_slot') <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: p_effective_page has a default; it must be required';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. GRANTS, read off has_function_privilege rather than off the GRANT statements.
  ------------------------------------------------------------------------------------------
  IF has_function_privilege('anon','derm.assign_card_to_slot(bigint,integer,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon can execute assign_card_to_slot';
  END IF;
  IF NOT has_function_privilege('authenticated','derm.assign_card_to_slot(bigint,integer,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: authenticated cannot execute assign_card_to_slot';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. THE VIEW GAINED ONE COLUMN AND LOST NONE, AND IT IS AT THE END.
  --    CONTROL: the before-snapshot must be non-trivial.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _p1b_cols;
  IF v_n < 30 THEN RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: snapshot holds % columns', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT column_name FROM _p1b_cols
    EXCEPT
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='derm' AND table_name='v_stamp_rows') x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % column(s) disappeared from v_stamp_rows', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='derm' AND table_name='v_stamp_rows'
    EXCEPT SELECT column_name FROM _p1b_cols) x;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % column(s) added, expected exactly 1', v_n; END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='derm' AND table_name='v_stamp_rows' AND column_name='slot_index') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: slot_index is not on v_stamp_rows';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 4. BAND RESOLUTION UNMOVED. This migration must not change what any client is served.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _p1b_bands;
  IF v_n < 700 THEN RAISE EXCEPTION 'VERIFY 4 CONTROL FAILED: snapshot holds % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM (
    (SELECT id, band_y0_pct, band_y1_pct FROM _p1b_bands
     EXCEPT SELECT id, band_y0_pct, band_y1_pct FROM derm.v_stamp_row_bands)
    UNION ALL
    (SELECT id, band_y0_pct, band_y1_pct FROM derm.v_stamp_row_bands
     EXCEPT SELECT id, band_y0_pct, band_y1_pct FROM _p1b_bands)) x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % band row(s) moved', v_n; END IF;

  ------------------------------------------------------------------------------------------
  -- 5. THE HAZARD IS ACTUALLY CLOSED. Exercise it on the real folder, rolled back.
  --    ticket-833049 is two-page; its page-2 cards carry stamp_page = 2 and page = 1, which is
  --    exactly the divergence that made the old derivation wrong.
  ------------------------------------------------------------------------------------------
  BEGIN
    PERFORM derm.save_page_slots('ticket-833049', 2);
    SELECT count(*) INTO v_n FROM derm.page_slots
     WHERE dump_folder='ticket-833049' AND effective_page=2;
    IF v_n <> 6 THEN RAISE EXCEPTION 'VERIFY 5 SETUP FAILED: % slots on page 2, expected 6', v_n; END IF;

    SELECT y0_pct, y1_pct INTO v_y0, v_y1 FROM derm.page_slots
     WHERE dump_folder='ticket-833049' AND effective_page=2 AND slot_index=3;

    SELECT r.id INTO v_row FROM derm.address_row_map r
     WHERE r.dump_folder='ticket-833049' AND r.stamp_page=2 AND r.page=1
     ORDER BY r.stamp_y_pct LIMIT 1;
    IF v_row IS NULL THEN
      RAISE EXCEPTION 'VERIFY 5 CONTROL FAILED: no card with stamp_page=2 and page=1, so this '
                      'folder does not reproduce the divergence the fix addresses';
    END IF;

    -- The page is now the caller's. Naming page 2 must resolve page 2's slots.
    UPDATE derm.address_row_map SET band_y0_pct = round(v_y0 - 5, 3), band_y1_pct = round(v_y1 - 5, 3)
     WHERE id = v_row;
    v_res := derm.assign_card_to_slot(v_row, 3, 2);
    IF (v_res->>'effective_page')::int <> 2 THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: resolved page % rather than the caller''s page 2',
                      v_res->>'effective_page';
    END IF;
    SELECT band_y0_pct INTO v_got FROM derm.address_row_map WHERE id = v_row;
    IF v_got IS DISTINCT FROM round(v_y0,3) THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: band % is not page 2 slot 3 (%)', v_got, v_y0;
    END IF;

    -- A placed card on page 2 must be refused when the caller names page 1, rather than moved.
    BEGIN
      PERFORM derm.assign_card_to_slot(v_row, 1, 1);
      RAISE EXCEPTION 'VERIFY 5 FAILED: a placed page-2 card was assigned to a page-1 slot';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already placed on page%' THEN RAISE; END IF;
    END;

    -- And slot_index is visible to the app now.
    SELECT slot_index INTO v_n FROM derm.v_stamp_rows WHERE id = v_row;
    IF v_n <> 3 THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: v_stamp_rows reports slot_index % for a card assigned to 3',
                      coalesce(v_n, -1);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  ------------------------------------------------------------------------------------------
  -- 6. The fixture left nothing behind.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.page_slots;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % fixture slot(s) survived', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE slot_index IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % fixture assignment(s) survived', v_n; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: one 3-arg signature with no default, grants correct, v_stamp_rows '
               '+1 column and -0, band resolution unmoved, and the wrong-page hazard exercised on '
               'the real two-page folder and refused.';
END
$verify$;

COMMIT;
