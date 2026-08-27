-- 2026-08-27_1149_stamp_rows_expose_effective_band.sql
--
-- WHY
-- ---
-- Fred, 2026-08-26: "make the chip be like a rectangle that it's the boundaries of the client",
-- with a hand-drawn mockup on 2026-08-27. Step 1 of that is READ-ONLY: draw the rectangle so he can
-- SEE each client's row boundaries. This migration is the data half of step 1 and nothing else.
--
-- 🛑 THE APP CANNOT DRAW THE RECTANGLE FROM WHAT IT CURRENTLY RECEIVES, and the gap is exactly on
-- the cards worth looking at. `derm.v_stamp_rows` already projects `band_y0_pct` / `band_y1_pct`,
-- but those are the RAW `address_row_map` OVERRIDE columns, passed straight through with no
-- COALESCE. Measured 2026-08-27:
--
--   placed cards with NO manual band (raw columns NULL)        22
--   of those, SERVING a live customer document right now        9
--
-- So a rectangle drawn from the raw columns would render NOTHING on 22 cards, nine of which are
-- being redacted TODAY from a stamp-midpoint heuristic. Those nine are precisely the ones a person
-- most needs to see, and they would be the ones silently missing from the picture.
--
-- `derm.v_stamp_row_bands` is the view that resolves manual-over-derived, and the app does not read
-- it. Rather than teach the app a second query, the resolved band is appended here, because every
-- one of the app's six `v_stamp_rows` reads is `.select('*')` and the values therefore arrive with
-- no client change at all. That is the same route the 2026-07-30 AI-tag change took, recorded in
-- the Studio changelog: "the six v_stamp_rows reads are .select('*'), so stamp_placed_by already
-- arrived at runtime and was simply never rendered."
--
-- WHAT IS ADDED, and nothing else changes
-- ---------------------------------------
--   client_row_top_pct       the resolved top edge    (manual override, else the derived estimate)
--   client_row_bottom_pct    the resolved bottom edge
--   client_row_is_measured   TRUE when a person or a snap pass set it; FALSE when it is an estimate
--
-- 🛑 `client_row_is_measured` IS THE POINT OF THIS MIGRATION, NOT A DECORATION. A derived band is a
-- stamp-midpoint heuristic that is NOT on the printed rules, and the estate's 2026-08-19 leak was
-- exactly a derived band being published. The UI must render an estimate visibly differently from a
-- measured boundary, or the picture will make 22 guesses look like 22 measurements.
--
-- ⚠ IT IS AN OR, NOT AN AND. `derm.v_stamp_row_bands.band_is_manual` is
-- `manual_y0 IS NOT NULL OR manual_y1 IS NOT NULL`, and the band itself COALESCEs PER EDGE. So a
-- half-written band would report measured while one edge is still a heuristic. That cannot happen
-- through `derm.set_row_band` (it writes both edges together, and since 2026-08-27_0347 it refuses
-- NULLs), and all 651 banded rows currently carry both edges. It is recorded here because the OR is
-- the thing that would make this column lie.
--
-- ⚠ COALESCE(..., false) so the column is never NULL. A card with no stamp point is absent from
-- `v_stamp_row_bands` entirely, so it has no band at all and the app must draw no rectangle for it
-- -- which is correct, not a missing value. There are THREE such cards today (ticket-830714, still
-- frozen for want of stamps): they carry a raw band from an old snap pass but resolve to nothing,
-- and the app draws neither a chip nor a rectangle for them. VERIFY 4b pins that behaviour.
--
-- 🛑 APPEND-ONLY, DELIBERATELY. The three columns go at the END of the outer SELECT list and the
-- existing 34 keep their names, order and types, so `CREATE OR REPLACE VIEW` succeeds and the
-- grants survive. Renaming or re-typing `band_y0_pct` to mean the resolved value would have been
-- tidier and would have forced a DROP, which discards `authenticated=r/postgres` and breaks the app
-- until someone notices. The raw columns are deliberately left in place.
--
-- ⚠ The body is SPLICED VERBATIM from the live `pg_get_viewdef` with only the three columns and one
-- LEFT JOIN added programmatically. Nothing was retyped: `CREATE OR REPLACE VIEW` takes the whole
-- body, so anything not reproduced would be silently deleted.
--
-- NO WRITE PATH IS CREATED HERE. The rectangle is not editable yet, and `derm.set_row_band` is not
-- called by the app. Editing needs an overlap guard, snapping to detected printed rules, and an
-- explicit save, because a band edit republishes a regulator-facing customer document within about
-- five minutes with no review step. That is step 2 and it is not this.
--
-- RULE 8 (audit trail): N/A. Replaces one view; creates no table and changes no data.

BEGIN;

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
    COALESCE(vb.band_is_manual, false) AS client_row_is_measured
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
;

COMMENT ON VIEW derm.v_stamp_rows IS
  'Stamp Studio row feed. band_y0_pct/band_y1_pct are the RAW address_row_map overrides and are '
  'NULL on cards whose band is still derived. client_row_top_pct / client_row_bottom_pct are the '
  'RESOLVED band from derm.v_stamp_row_bands (manual over derived), and client_row_is_measured says '
  'which of the two it is. Draw the rectangle from the client_row_* columns; render is_measured '
  'false visibly differently, because a derived band is a stamp-midpoint estimate that is not on '
  'the printed rules. See 2026-08-27_1149.';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_m integer;
BEGIN
  -- 1. Nothing was lost. Same row count, and the original 34 columns are still there.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows;
  IF v_n <> 680 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: v_stamp_rows returns % rows, expected 680 (a join fanned out or dropped rows)', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema = 'derm' AND table_name = 'v_stamp_rows';
  IF v_n <> 37 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: % columns, expected 34 + 3', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema = 'derm' AND table_name = 'v_stamp_rows'
     AND column_name IN ('band_y0_pct','band_y1_pct','stamp_x_pct','stamp_y_pct','client_code','filled_by_ai');
  IF v_n <> 6 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: the splice lost an existing column (found % of 6 probes)', v_n;
  END IF;

  -- 2. THE POINT: every card the app draws a chip for now also carries a resolvable rectangle.
  --    A chip is drawn when stamp_x_pct and stamp_y_pct are both present.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows
   WHERE stamp_x_pct IS NOT NULL AND stamp_y_pct IS NOT NULL;
  SELECT count(*) INTO v_m FROM derm.v_stamp_rows
   WHERE stamp_x_pct IS NOT NULL AND stamp_y_pct IS NOT NULL
     AND client_row_top_pct IS NOT NULL AND client_row_bottom_pct IS NOT NULL;
  IF v_m <> v_n THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % of % chip-bearing rows still have no resolvable band', v_n - v_m, v_n;
  END IF;

  -- 3. AND THE ESTIMATES ARE VISIBLE AS ESTIMATES. If this were 0 the new flag would be useless and
  --    the picture would present 22 heuristics as measurements.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows WHERE NOT client_row_is_measured;
  IF v_n < 1 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: no row reports an estimated band; expected the 22 derived ones';
  END IF;

  -- 4. The resolved band really is the RAW override wherever one exists. This is the control that
  --    the COALESCE is the right way round -- an inverted one would still be non-null everywhere.
  -- Scoped to rows that HAVE a stamp point. A band with no stamp point is deliberately absent
  -- from derm.v_stamp_row_bands, so it resolves to nothing -- see VERIFY 4b, which pins that.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows
   WHERE band_y0_pct IS NOT NULL AND stamp_y_pct IS NOT NULL
     AND (client_row_top_pct <> band_y0_pct OR client_row_bottom_pct <> band_y1_pct
          OR NOT client_row_is_measured);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % row(s) with a stored override do not resolve to it', v_n;
  END IF;

  -- 4b. A BAND WITHOUT A STAMP POINT RESOLVES TO NOTHING, AND THAT IS CORRECT. An earlier draft of
  --     VERIFY 4 did not scope to stamp_y_pct and failed on exactly these rows. derm.v_stamp_row_bands
  --     is `... WHERE stamp_y_pct IS NOT NULL`, so such a card has no resolvable band; the app also
  --     draws no chip for it (it filters on stamp_x_pct/stamp_y_pct), so drawing no rectangle is the
  --     consistent outcome, not a missing value. These are ticket-830714's three cards, the folder
  --     still frozen for want of stamps.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows
   WHERE band_y0_pct IS NOT NULL AND stamp_y_pct IS NULL;
  SELECT count(*) INTO v_m FROM derm.v_stamp_rows
   WHERE band_y0_pct IS NOT NULL AND stamp_y_pct IS NULL
     AND client_row_top_pct IS NULL AND client_row_bottom_pct IS NULL
     AND NOT client_row_is_measured;
  IF v_n <> v_m THEN
    RAISE EXCEPTION 'VERIFY 4b failed: % of % stampless banded rows resolved a band they should not have', v_n - v_m, v_n;
  END IF;
  IF v_n <> 3 THEN
    RAISE NOTICE 'note: % stampless banded rows (was 3 at write time); the frozen backlog moved', v_n;
  END IF;

  -- 5. Never NULL, so the app never has to handle a third state.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows WHERE client_row_is_measured IS NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 failed: % NULL flags', v_n; END IF;

  -- 6. Grants survived the replace. A DROP would have taken authenticated=r with it and broken the
  --    app silently.
  IF NOT has_table_privilege('authenticated', 'derm.v_stamp_rows', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: authenticated lost SELECT on v_stamp_rows';
  END IF;

  -- 7. The one function that reads this view still resolves.
  PERFORM 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'derm' AND p.proname = 'auto_place_page';
  IF NOT FOUND THEN RAISE EXCEPTION 'VERIFY 7 failed: derm.auto_place_page vanished'; END IF;

  RAISE NOTICE 'VERIFY ok: 37 columns (34 + 3), 680 rows unchanged, every chip-bearing row now resolves a band, estimates flagged, overrides resolve to themselves, grants intact.';
END $do$;

COMMIT;
