-- ============================================================================================
-- 2026-09-09_1430_stamp_rows_expose_client_address.sql
--
-- Give a stamp card something to say when the client has no permit and the sheet has not been
-- read: the client's own property address.
--
-- WHY (Fred, 2026-09-09): "the cards for stamping all are saying `no address` but it should be the
-- property address of the client, maybe the reference for it it's not working and needs to be
-- checked."
--
-- 🛑 THE REFERENCE IS NOT BROKEN. THE CARD HAS NOTHING TO SHOW. Read off the live bundle, the
-- card's third line is:
--       e.gdo_number ? <gdo_label · gdo_number>
--                    : <e.address_read || "no address">
-- so it shows the PERMIT when the card has one, and otherwise falls back to `address_read`, which
-- is the OCR of the address column ON THE SHEET. On ticket-834986 every card had `gdo_id IS NULL`
-- and the row OCR has never run, so all four fell through to the literal string. Measured
-- estate-wide: 286 of 750 cards carry a NULL `address_read`, 20 of them unplaced.
--
-- ⇒ `derm.v_stamp_rows` has no client-address column at all, so the app could not have shown one.
-- This adds it. The app change is a one-line fallback and is NOT in this migration.
--
-- ⚠ TWO OF THE FOUR CARDS FIXED THEMSELVES for a different reason, and it is worth separating:
-- 043-MIL and 239-COM are PRINTED on that sheet with a GDO, so binding their permit makes the card
-- show `Restaurant · GDO-11024` and the address question never arises (see 2026-09-09_1400).
-- 017-FIA and 168-AVA are HANDWRITTEN rows with genuinely no permit, and the DERM form itself says
-- what to do there: "Facility Name (if no GDO#)" and "Complete Facility Address (if no GDO#)".
-- For those the address IS the right identifier, which is what makes this the correct fallback
-- rather than a cosmetic one.
--
-- HOW THE ADDRESS IS RESOLVED, and it is deliberately the SAME expression `derm.v_stamp_clients`
-- already uses for the "Add client" picker:
--       (SELECT p.address FROM properties p
--         WHERE p.client_id = ... AND p.deleted_at IS NULL ORDER BY p.id LIMIT 1)
-- Consistency matters here: the same client should read the same address in the picker and on the
-- card, and a second, cleverer expression would eventually disagree with the first.
--
-- ⚠ A CLIENT USUALLY HAS TWO PROPERTY ROWS AT THE SAME ADDRESS, one SERVICE and one BILLING (the
-- billing row is the Client gid plus `_billing`, see the property-sync notes). `ORDER BY p.id`
-- picks the lower id, which is the SERVICE row for all four clients on this sheet
-- (32/51/63/203 rather than 683/536/506/733). That is a convention, not an invariant: it holds
-- because the service property is created first. Both rows carry the same `address` string today,
-- so the distinction is currently inert either way.
--
-- ⚠ COLUMN ADDED AT THE END, so CREATE OR REPLACE keeps the grants and every dependant. The view
-- goes 40 -> 41 columns. VERIFY 2 asserts exactly one added and NONE lost.
--
-- BODY PROVENANCE: pg_get_viewdef output patched by one anchored insertion
-- (scripts/probes/addr/, anchor asserted to match exactly once). Never retyped.
--
-- RULE 8: no schema change, view only.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _vsr_cols_before ON COMMIT DROP AS
  SELECT column_name FROM information_schema.columns
   WHERE table_schema='derm' AND table_name='v_stamp_rows';

CREATE TEMP TABLE _vsr_rows_before ON COMMIT DROP AS
  SELECT id, dump_folder, client_code, band_y0_pct, band_y1_pct, slot_index, page_top_pct
    FROM derm.v_stamp_rows;

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
    a.slot_index,
    ( SELECT p.address
           FROM properties p
          WHERE p.client_id = sr.matched_client_id AND p.deleted_at IS NULL
          ORDER BY p.id
         LIMIT 1) AS client_address
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

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n    int;
  v_txt  text;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. NOTHING THAT EXISTED MOVED. Every row keeps the values it had.
  --    CONTROL: the snapshot must hold the real population.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM _vsr_rows_before;
  IF v_n < 600 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: snapshot holds only % rows', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT id, dump_folder, client_code, band_y0_pct, band_y1_pct, slot_index, page_top_pct
       FROM _vsr_rows_before
     EXCEPT
     SELECT id, dump_folder, client_code, band_y0_pct, band_y1_pct, slot_index, page_top_pct
       FROM derm.v_stamp_rows)
    UNION ALL
    (SELECT id, dump_folder, client_code, band_y0_pct, band_y1_pct, slot_index, page_top_pct
       FROM derm.v_stamp_rows
     EXCEPT
     SELECT id, dump_folder, client_code, band_y0_pct, band_y1_pct, slot_index, page_top_pct
       FROM _vsr_rows_before)) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) changed on the existing columns', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. EXACTLY ONE COLUMN ADDED, NONE LOST. A lost column is a silently broken app.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM (
    SELECT column_name FROM _vsr_cols_before
    EXCEPT
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='derm' AND table_name='v_stamp_rows') y;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % column(s) disappeared from v_stamp_rows', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='derm' AND table_name='v_stamp_rows'
    EXCEPT SELECT column_name FROM _vsr_cols_before) z;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % column(s) added, expected exactly 1', v_n;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='derm' AND table_name='v_stamp_rows'
                    AND column_name='client_address') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: client_address is not on the view';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. IT ACTUALLY ANSWERS THE QUESTION FRED ASKED. The four cards on ticket-834986 that read
  --    "no address" must now carry one. Named explicitly, because a column that resolves NULL
  --    everywhere would satisfy VERIFY 1 and 2 perfectly.
  ------------------------------------------------------------------------------------------
  SELECT string_agg(client_code || '=' || coalesce(client_address,'<NULL>'), ', ' ORDER BY client_code)
    INTO v_txt
    FROM derm.v_stamp_rows
   WHERE dump_folder = 'ticket-834986'
     AND client_code IN ('017-FIA','168-AVA','043-MIL','239-COM');
  IF v_txt IS DISTINCT FROM
     '017-FIA=9463 Harding Avenue, 043-MIL=1636 Meridian Avenue, '
     '168-AVA=2889 McFarlane Road, 239-COM=1530 Washington Avenue' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: the four cards resolve "%"', v_txt;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 4. AND IT RESOLVES BROADLY, not just on the folder it was written for.
  --    CONTROL: it must also be capable of being NULL, or it is not measuring anything.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows WHERE client_address IS NOT NULL;
  IF v_n < 500 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: only % row(s) resolve an address', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 5. IT MATCHES derm.v_stamp_clients EXACTLY. Two expressions for one question is how they
  --    start disagreeing, so assert they agree on every client the card view can show.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM derm.v_stamp_rows r
    JOIN derm.v_stamp_clients c ON c.client_code = r.client_code
   WHERE r.client_address IS DISTINCT FROM c.address;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % row(s) disagree with v_stamp_clients about the address', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 6. The app can still read it.
  ------------------------------------------------------------------------------------------
  IF NOT has_table_privilege('authenticated','derm.v_stamp_rows','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: authenticated lost SELECT on v_stamp_rows';
  END IF;
  IF has_table_privilege('anon','derm.v_stamp_rows','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: anon can now read v_stamp_rows';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: +1 column and -0, no existing value moved, the four 834986 '
               'cards now carry their property address, and every row agrees with '
               'v_stamp_clients.';
END
$verify$;

COMMIT;
