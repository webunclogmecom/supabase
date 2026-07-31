-- 2026-07-31_0020  v_stamp_sheets: ai_placed_rows must count the SAME population as placed_rows
--
-- Found by @Building Apps while dry-running sheet 1073 (the live end-to-end sentinel) inside a
-- rolled-back transaction, BEFORE Diego files it. Their measurement, reproduced independently here.
--
-- -- THE DEFECT ---------------------------------------------------------------
-- The two aggregates the Studio's AI badge depends on counted different row populations:
--   placed_rows    from the `vis` CTE, which requires
--                  ((matched_client_id IS NOT NULL AND clients.client_code IS NOT NULL)
--                    OR manual_code IS NOT NULL)
--   ai_placed_rows from a LEFT JOIN LATERAL keyed only on dump_folder + stamp_placed_at IS NOT NULL,
--                  with NO client_code predicate at all
-- So a card whose client has a NULL client_code is excluded from placed_rows but still counted in
-- ai_placed_rows. When every card is AI-placed, ai_placed_rows EXCEEDS placed_rows.
--
-- The Studio badge's first guard is `n > t -> render nothing`. So the sheet stamps perfectly,
-- completes, and shows NO BADGE AT ALL. Sheet 1073 has exactly this shape: slot 3 is client 518
-- (Habib Elghrissi, ACTIVE, created 2026-07-27, client_code NULL), giving placed=4 / ai=5.
-- Without this fix Fred's feature would have looked broken on the very first real filing, in the
-- one way that reads as "the auto-stamp failed" when in fact it worked.
--
-- SCOPE: 163 of 439 clients carry a NULL client_code, so this is a live class, not a one-off.
-- Currently 0 of 113 sheets trip it, because no sheet had ever been all-AI until yesterday.
-- 1073 is simply the first row that would.
--
-- -- THE FIX ------------------------------------------------------------------
-- Give the lateral the SAME visibility predicate the `vis` CTE uses, so such a card is excluded from
-- BOTH counts or neither. Chosen over the tidier "compute ai_placed inside vis" because that
-- restructure broke the view's paren balance on a first attempt and this is a compliance surface
-- with a filing imminent; the minimal edit preserves structure exactly.
-- NOT chosen: giving client 518 a client_code. That would make the test pass while leaving the
-- class open for the other 162, and inventing a client code is a business decision, not a fix.
--
-- CONTROLLED PROOF, one variable, on a REAL sheet (310429, all 7 cards AI-placed, client 307's
-- code NULLed inside the txn), rolled back:
--     before fix:  placed 6, ai 7, filled_by_ai false -> badge renders NOTHING (n > t)
--     after  fix:  placed 6, ai 6, filled_by_ai true  -> badge renders "AI"
-- Regression sweep after the fix: 0 of 113 sheets trip, 0 rows with filled_by_ai NULL, and the
-- three other AI sheets keep their exact counts.
--
-- RULE 8 (ADR 010): read-path view only; no table, column, or grant change.
--
-- NOTE for whoever reads this next: the same duplicated-predicate shape is why the geometry
-- clobber happened (28n/28q). Two places computing "the same" thing is the recurring defect in
-- this lane. If anyone revisits this view, collapsing both counts into the vis CTE is the durable
-- fix and is worth doing when there is no filing pending.

BEGIN;
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 SELECT ss.dump_folder,
    ss.white_manifest_number,
    ss.service_date,
    ss.page_count,
    ss.page_image_urls,
    ss.total_rows,
    ss.matched_rows,
    ss.placed_rows,
    ss.completed,
    ss.completed_at,
    ss.dump_date,
    ss.is_generated,
    ai.ai_placed AS ai_placed_rows,
    ((ss.placed_rows > 0) AND (ai.ai_placed = ss.placed_rows)) AS filled_by_ai
   FROM (( WITH tickets AS (
                 SELECT DISTINCT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS wm
                   FROM derm_manifests
                  WHERE ((derm_manifests.deleted_at IS NULL) AND (COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL))
                UNION
                 SELECT DISTINCT address_row_map.white_manifest_number
                   FROM derm.address_row_map
                  WHERE (address_row_map.white_manifest_number IS NOT NULL)
                ), folder AS (
                 SELECT address_row_map.white_manifest_number AS wm,
                    min(address_row_map.dump_folder) AS f
                   FROM derm.address_row_map
                  WHERE (address_row_map.white_manifest_number IS NOT NULL)
                  GROUP BY address_row_map.white_manifest_number
                ), vis AS (
                 SELECT r.white_manifest_number AS wm,
                    count(*) AS total,
                    count(*) FILTER (WHERE ((r.matched_client_id IS NOT NULL) OR (r.manual_code IS NOT NULL))) AS matched,
                    count(*) FILTER (WHERE (r.stamp_placed_at IS NOT NULL)) AS placed
                   FROM (derm.address_row_map r
                     LEFT JOIN clients c ON ((c.id = r.matched_client_id)))
                  WHERE ((r.white_manifest_number IS NOT NULL) AND (((r.matched_client_id IS NOT NULL) AND (c.client_code IS NOT NULL)) OR (r.manual_code IS NOT NULL)) AND ((r.stamp_placed_at IS NOT NULL) OR (r.manual_code IS NOT NULL) OR ((r.matched_manifest_id IS NOT NULL) AND (EXISTS ( SELECT 1
                           FROM derm_manifests m
                          WHERE ((m.id = r.matched_manifest_id) AND (m.deleted_at IS NULL)))))))
                  GROUP BY r.white_manifest_number
                )
         SELECT COALESCE(folder.f, ('ticket-'::text || t.wm)) AS dump_folder,
            t.wm AS white_manifest_number,
            ( SELECT min(m.service_date) AS min
                   FROM derm_manifests m
                  WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm) AND (m.deleted_at IS NULL))) AS service_date,
            (COALESCE(array_length(spi.imgs, 1), 0))::bigint AS page_count,
            spi.imgs AS page_image_urls,
            COALESCE(vis.total, (0)::bigint) AS total_rows,
            COALESCE(vis.matched, (0)::bigint) AS matched_rows,
            COALESCE(vis.placed, (0)::bigint) AS placed_rows,
            COALESCE(s.completed, false) AS completed,
            s.completed_at,
            COALESCE(( SELECT max(m.dump_ticket_date) AS max
                   FROM derm_manifests m
                  WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm) AND (m.deleted_at IS NULL))), ( SELECT max(m.service_date) AS max
                   FROM derm_manifests m
                  WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm) AND (m.deleted_at IS NULL)))) AS dump_date,
            derm.fn_sheet_is_generated(t.wm) AS is_generated
           FROM ((((tickets t
             LEFT JOIN folder ON ((folder.wm = t.wm)))
             LEFT JOIN vis ON ((vis.wm = t.wm)))
             LEFT JOIN derm.stamp_sheet_status s ON ((s.dump_folder = COALESCE(folder.f, ('ticket-'::text || t.wm)))))
             CROSS JOIN LATERAL ( SELECT derm.ticket_page_images(t.wm) AS imgs) spi)) ss
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE (a.stamp_placed_by = 'stamp-studio-ai'::text)) AS ai_placed
           FROM (derm.address_row_map a
             LEFT JOIN clients c2 ON ((c2.id = a.matched_client_id)))
          WHERE ((a.dump_folder = ss.dump_folder) AND (a.stamp_placed_at IS NOT NULL) AND (((a.matched_client_id IS NOT NULL) AND (c2.client_code IS NOT NULL)) OR (a.manual_code IS NOT NULL)))) ai ON (true));

COMMIT;
