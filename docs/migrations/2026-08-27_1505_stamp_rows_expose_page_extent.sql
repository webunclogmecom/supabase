-- 2026-08-27_1505_stamp_rows_expose_page_extent.sql
--
-- WHY
-- ---
-- The editable rectangle needs to show the operator where the PAGE BOUNDARY currently sits, so it
-- can be dragged. `authenticated` holds NO grant on derm.page_block_extents (measured: none at all),
-- so the browser cannot read it, and without it "Set page boundary" would have nothing to render and
-- the operator would be placing the outer limits blind.
--
-- derm.v_stamp_rows already LEFT JOINs page_block_extents, but only to compute guess_y_pct; it never
-- exposes the values. This appends them as page_top_pct / page_bottom_pct.
--
-- ⚠ NULL means the page has NO boundary yet, which is the state that keeps it unpublished. The app
-- must send p_top_pct/p_bottom_pct as NULL in that case rather than inventing a value: adding the
-- boundary is what OPENS the publish gate and is a deliberate act, never a side effect of saving
-- rows. (derm.save_page_geometry takes it as optional for exactly this reason.)
--
-- 🛑 THE BODY WAS COPIED FROM pg_get_viewdef, NOT RETYPED. CREATE OR REPLACE takes the WHOLE body,
-- so anything not reproduced is silently deleted, and the header would still honestly describe the
-- change intended. That is how 2026-08-06_1316 dropped seven behaviours from a resolver and raised
-- for 3.5 hours. The splice was done by script and asserted byte-identical outside the two columns
-- and the one JOIN it adds.
--
-- ⚠ A SECOND JOIN to page_block_extents is added at the OUTER level rather than plumbing the
-- existing inner `ext` alias up through two subquery layers. That keeps the diff to three lines and
-- leaves guess_y_pct's arithmetic untouched. Same table, same key, so the two cannot disagree.
--
-- No app query changes: all six reads of this view are .select('*'), the same route the AI-tag
-- change took on 2026-07-30 and the client_row_* change took this morning.
--
-- RULE 8 (audit trail): a view holds no state; opt-out.

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
    COALESCE(vb.band_is_manual, false) AS client_row_is_measured,
    pbe.top_pct AS page_top_pct,
    pbe.bottom_pct AS page_bottom_pct
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
     LEFT JOIN derm.page_block_extents pbe
            ON pbe.dump_folder = sr.dump_folder
           AND pbe.effective_page = COALESCE(sr.stamp_page, sr.page)
;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_with integer; v_null integer;
BEGIN
  -- 1. The two new columns exist, at the END of the column list.
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_stamp_rows'
     AND column_name IN ('page_top_pct','page_bottom_pct');
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 1 failed: % of 2 new columns present', v_n; END IF;

  -- 2. Nothing else was dropped. The view carried 37 columns before this change.
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_stamp_rows';
  IF v_n <> 39 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: view has % columns, expected 39 (37 + 2)', v_n; END IF;

  -- 3. Grants survived. CREATE OR REPLACE keeps them; a drop-and-recreate would not, and that is the
  --    silent way this change could take the whole app offline.
  IF NOT has_table_privilege('authenticated','derm.v_stamp_rows','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: authenticated lost SELECT on v_stamp_rows';
  END IF;
  IF has_table_privilege('anon','derm.v_stamp_rows','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: anon gained SELECT on v_stamp_rows';
  END IF;

  -- 4. BOTH STATES MUST BE REPRESENTED, or the column is untested. A page with an extent must
  --    report it, and a page without one must report NULL rather than 0.
  SELECT count(*) FILTER (WHERE page_top_pct IS NOT NULL),
         count(*) FILTER (WHERE page_top_pct IS NULL)
    INTO v_with, v_null FROM derm.v_stamp_rows;
  IF v_with = 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: no row reports an extent; the join is broken'; END IF;
  IF v_null = 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: no row reports NULL; unmeasured pages are indistinguishable'; END IF;

  -- 5. The value must match the table for a page measured earlier today, keyed on effective_page
  --    (NOT page: those genuinely differ, and keying on the wrong one is how a stale map is built).
  IF NOT EXISTS (
    SELECT 1 FROM derm.v_stamp_rows v
     WHERE v.dump_folder='ticket-833530'
       AND v.page_top_pct = 27.411 AND v.page_bottom_pct = 60.268) THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: ticket-833530 does not report its known extent 27.411..60.268';
  END IF;

  RAISE NOTICE 'VERIFY ok: page_top_pct/page_bottom_pct exposed, 39 columns, grants intact, both measured and unmeasured pages represented.';
END $do$;

COMMIT;
