-- 2026-07-20j — generated-sheet stamps must count GDO ROWS, not clients (multi-GDO mis-stamp)
--
-- FOUND BY THE MULTI-GDO GENERATION TEST (Fred: "now test a multi-GDO client the same way").
-- Sheet 1028, ticket 999002, two clients: 043-MIL Mila (2 ACTIVE permits) then 002-41 41 Pizza (1).
--
-- WHAT THE PDF ACTUALLY PRINTED          WHAT THE STUDIO STAMPED
--   slot 1  25.980%  043-MIL  GDO-11024    043-MIL -> slot 1   CORRECT
--   slot 2  34.624%  043-MIL  GDO-14117    002-41  -> slot 2   *** MILA'S ROW ***
--   slot 3  41.585%  002-41   GDO-09852
--
-- ROOT CAUSE: two different counting rules that only agree when every client has <= 1 permit.
--   * The generator prints ONE ROW PER ACTIVE WELL-FORMED PERMIT
--     (app.py _facility_rows_for_client; siblings ordered by manifest id, permits by gdo_number).
--   * The Studio creates ONE CARD PER CLIENT with row_index = max(row_index)+1 in LINK order
--     (derm._materialize_card).
--   So every extra permit on an earlier client shifts every later client's true row down by one,
--   while its card index does not move. With Mila's 2 permits, 41 Pizza's stamp landed exactly one
--   slot high: on Mila's Bar/Lounge line. On a compliance document that is one client's code
--   printed on another client's row.
--
-- THIS WAS INVISIBLE IN THE SINGLE-GDO TEST (sheet 1027) because with one permit per client the two
-- rules coincide. It is the exact failure the multi-GDO test existed to find, and it was unreachable
-- in production only because no generated sheet had ever been produced.
--
-- FIX: for GENERATED sheets, derive the slot from the SHEET's own layout instead of the card's link
-- index. derm.fn_generated_sheet_slot(manifest_id) replays the generator's own rule — walk the
-- ticket's live sibling manifests in id order, add GREATEST(1, active well-formed permit count) for
-- every sibling that prints BEFORE this one, and add 1. Verified to reproduce the printed layout
-- above exactly (MIL -> 1, 41 Pizza -> 3).
--
-- SEMANTICS, stated explicitly: a multi-permit client still gets ONE card, and its stamp marks that
-- client's FIRST printed row. The remaining rows for that client are unstamped by design (the card
-- identifies the client on the sheet; it is not a per-permit marker). If per-permit stamping is ever
-- wanted, that is a card-model change, not a geometry change.
--
-- ⚠ KEEP IN SYNC WITH THE GENERATOR. Three rules must match app.py:
--     1. siblings ordered by derm_manifests.id ascending, soft-deleted excluded
--     2. rows per client = GREATEST(1, count of ACTIVE gdo_number matching '^GDO-[0-9]+$')
--     3. 5 slots per page, overflow to the next page
--   If _facility_rows_for_client or the sibling query changes, change this function in the same PR.
--
-- Handwritten sheets are untouched: they keep row_index semantics through the unchanged
-- fn_generated_row_geometry(slot) mapping and the existing band/extent/empirical cascade.
-- ADR 010: no new tables. Idempotent.

BEGIN;

-- A. the slot a manifest's card belongs on, per the GENERATOR's own layout rule
CREATE OR REPLACE FUNCTION derm.fn_generated_sheet_slot(p_manifest_id bigint)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm','public' AS $$
  WITH me AS (
    SELECT m.id, COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS k
      FROM public.derm_manifests m
     WHERE m.id = p_manifest_id AND m.deleted_at IS NULL
  ), before AS (
    SELECT GREATEST(1, (
             SELECT count(*) FROM public.gdos gd
              WHERE gd.client_id = m.client_id
                AND gd.status = 'ACTIVE'
                AND gd.gdo_number ~ '^GDO-[0-9]+$'
           ))::int AS rows_printed
      FROM public.derm_manifests m
      JOIN me ON COALESCE(m.white_manifest_number, m.yellow_ticket_number) = me.k
     WHERE m.deleted_at IS NULL AND m.id < me.id
  )
  SELECT CASE WHEN EXISTS (SELECT 1 FROM me)
              THEN 1 + COALESCE((SELECT sum(rows_printed) FROM before), 0)::int
         END;
$$;

COMMENT ON FUNCTION derm.fn_generated_sheet_slot(bigint) IS
  'Section B slot for this manifest''s Stamp card on a GENERATED sheet. Replays the generator rule: siblings by manifest id, GREATEST(1, active well-formed permit count) rows each. Must stay in sync with pdf-service _facility_rows_for_client.';

-- B. auto-stamp uses the slot, falling back to row_index only when the card has no manifest
CREATE OR REPLACE FUNCTION derm.trg_autoplace_generated()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE geo record; v_slot integer;
BEGIN
  IF NEW.white_manifest_number IS NOT NULL
     AND NEW.stamp_placed_at IS NULL
     AND derm.fn_sheet_is_generated(NEW.white_manifest_number) THEN
    v_slot := COALESCE(derm.fn_generated_sheet_slot(NEW.matched_manifest_id), NEW.row_index);
    SELECT * INTO geo FROM derm.fn_generated_row_geometry(v_slot);
    NEW.page            := geo.o_page;
    NEW.stamp_page      := geo.o_page;
    NEW.stamp_x_pct     := round(geo.o_x_pct, 3);
    NEW.stamp_y_pct     := round(geo.o_y_pct, 3);
    NEW.stamp_placed_at := now();
    NEW.stamp_placed_by := 'stamp-studio-ai';
  END IF;
  RETURN NEW;
END $$;

-- C. the view's generated guess branch must agree, so a manual clear + Auto-place re-places
--    on the same (correct) row instead of reintroducing the offset.
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
 SELECT r.id,
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
    CASE WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 6.82 ELSE 8.0 END AS guess_x_pct,
    round(
        CASE
            WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number)
              THEN (ARRAY[25.98, 34.62, 41.58, 49.10, 57.25]::numeric[])[
                     ((COALESCE(derm.fn_generated_sheet_slot(r.matched_manifest_id), r.row_index) - 1) % 5) + 1]
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
   FROM ( SELECT a.id, a.dump_folder, a.white_manifest_number, a.page, a.row_index, a.image_url,
            a.facility_name_read, a.address_read, a.matched_client_id, a.assignment_status,
            a.confidence, a.agent_agreement, a.flags, a.source, a.reviewed_by, a.reviewed_at,
            a.created_at, a.updated_at, a.stamp_x_pct, a.stamp_y_pct, a.stamp_page,
            a.stamp_placed_at, a.stamp_placed_by, a.manual_code, a.matched_manifest_id,
            a.band_y0_pct, a.band_y1_pct, a.band_source, a.band_set_at, a.band_set_by,
            max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
           FROM derm.address_row_map a) r
     LEFT JOIN clients c ON c.id = r.matched_client_id
     LEFT JOIN derm.page_block_extents ext ON ext.dump_folder = r.dump_folder AND ext.effective_page = COALESCE(r.stamp_page, r.page)
  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)));

COMMIT;

-- ============================================================================
-- MULTI-GDO GENERATION TEST — full result (2026-07-20, Fred-authorised)
--
-- Sheet 1028, ticket 999002, scratch manifests for 043-MIL Mila (2 ACTIVE permits) and 002-41
-- 41 Pizza (1), MIL first so it printed first. Both with no photo and no card.
--
-- BEFORE THE FIX (the bug this test found, measured off the real PDF):
--   printed  slot 1  25.980%  043-MIL  Mila - Restaurant   GDO-11024
--   printed  slot 2  34.624%  043-MIL  Mila - Bar / Lounge GDO-14117
--   printed  slot 3  41.585%  002-41   41 Pizza and Bakery GDO-09852
--   stamped          043-MIL -> 25.980% (slot 1)  CORRECT
--   stamped          002-41  -> 34.620% (slot 2)  *** sat on Mila's Bar/Lounge row ***
--
-- AFTER THE FIX, verified three ways on the same live sheet:
--   * derm.fn_generated_sheet_slot: MIL -> 1, 41 Pizza -> 3 (matches the printed layout exactly)
--   * clear + derm.auto_place_page: 043-MIL 25.980%, 002-41 41.580% — both on their OWN printed rows
--   * a fresh card INSERT (the trigger path, not auto-place): 002-41 -> 41.580% CORRECT
--
-- REGRESSION, same session: handwritten sheets unchanged (ticket-306915 still guesses from its
-- manual bands, e.g. row 659 -> 35.907% = its band midpoint, guess_confidence 'low'); role matrix
-- OK for anon / authenticated / service_role; fn_blackout_targets still 0.
--
-- TEARDOWN: verified back to baseline (manifests 553, cards 552, address_sheets 0, photos 535/535,
-- no ghost rows, 0 storage objects under derm/sheets/, 0 blackout targets). The generated PDF was
-- deleted from the PUBLIC bucket (it carries two real clients' facility names and addresses under a
-- fake ticket number). Backup: ..ackups6-07-20_multi_gdo_test_scratch_data.json. Review copy
-- at the workspace root: 2026-07-20_multi-GDO_DERM_address_sheet_1028.pdf.
-- Sequence advanced 1027 -> 1028, so the first production sheet is now 1029.
--
-- WHAT IS NOW PROVEN vs STILL UNPROVEN:
--   PROVEN — single-client single-GDO (sheet 1027), and multi-client with a multi-GDO client
--            printing before a single-GDO client (sheet 1028), on ONE page.
--   NOT PROVEN — a ticket whose rows spill past slot 5 onto page 2. fn_generated_row_geometry
--            paginates by (slot-1)/5 and the generator chunks facilities in fives, so they should
--            agree, but nothing has exercised it end to end. Test that before generating a ticket
--            whose combined permit count exceeds 5 (e.g. Casa Neos 3 + Wynd 28 3 on one ticket).
-- ============================================================================
