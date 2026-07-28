-- ============================================================================
-- 2026-07-28m — expose the "filled by AI" flag so Stamp Studio can badge it
-- ============================================================================
-- Fred, 2026-07-28: "put the AI tag on it to know it was completed by AI" —
-- an "AI" badge in the top-right of each row in the Studio manifest list.
--
-- The underlying signal already exists: derm.address_row_map.stamp_placed_by is
-- 'stamp-studio-ai' when a stamp was placed automatically, and 'stamp-studio'
-- when a human placed it. Neither view the app reads exposed it, so the app had
-- nothing to render. This migration adds it, and changes nothing else.
--
-- APPENDED (CREATE OR REPLACE VIEW only permits new columns at the END, so every
-- existing column keeps its name, type and position and no app query breaks):
--   derm.v_stamp_rows   + stamp_placed_by  (text)     who placed THIS card's stamp
--                       + filled_by_ai     (boolean)  convenience for the row badge
--   derm.v_stamp_sheets + ai_placed_rows   (bigint)   how many of the sheet's stamps were AI
--                       + filled_by_ai     (boolean)  TRUE only when EVERY placed stamp is AI
--
-- WHY "every placed stamp" AND NOT "any": the badge claims the sheet was completed
-- by AI. A sheet a human fixed up by hand is NOT AI-completed, and badging it as
-- such would launder a human correction into an automated one. Partially-AI sheets
-- are visible via ai_placed_rows vs placed_rows if a mixed state ever needs its own
-- treatment.
--
-- ⚠ NOTE ON is_generated: it is FALSE on every sheet today, including sheets that
-- ARE ours (830673 = printed #1057, 309898 = #1059, 309944 = #1060). That is the
-- separate provenance bug: the office prints via the pdf-service PREVIEW endpoint,
-- which writes no derm.address_sheets row, so fn_sheet_is_generated cannot know.
-- Do NOT drive the AI badge off is_generated — it would never light up.
--
-- ALSO: marks tickets 309898 and 309944 complete. Their stamps were placed today
-- from the printed sheets (verified against the scans row by row, see the
-- 2026-07-28 fill), so the sheets are finished; only the status row was missing.
--
-- AUDIT (ADR 010): views are read-only. derm.stamp_sheet_status is Stamp-Studio
-- working state, unaudited by design.
-- ============================================================================

begin;

create or replace view derm.v_stamp_rows as
select sr.*,
       a.stamp_placed_by,
       (a.stamp_placed_by = 'stamp-studio-ai') as filled_by_ai
  from (SELECT sr.id,
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
                    WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 6.82
                    ELSE 8.0
                END AS guess_x_pct,
            round(
                CASE
                    WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
                    WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN (ARRAY[25.98, 34.62, 41.58, 49.10, 57.25])[(COALESCE(derm.fn_generated_sheet_slot(r.matched_manifest_id), r.row_index) - 1) % 5 + 1]
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
           FROM ( SELECT a.id,
                    a.dump_folder,
                    a.white_manifest_number,
                    a.page,
                    a.row_index,
                    a.image_url,
                    a.facility_name_read,
                    a.address_read,
                    a.matched_client_id,
                    a.assignment_status,
                    a.confidence,
                    a.agent_agreement,
                    a.flags,
                    a.source,
                    a.reviewed_by,
                    a.reviewed_at,
                    a.created_at,
                    a.updated_at,
                    a.stamp_x_pct,
                    a.stamp_y_pct,
                    a.stamp_page,
                    a.stamp_placed_at,
                    a.stamp_placed_by,
                    a.manual_code,
                    a.matched_manifest_id,
                    a.band_y0_pct,
                    a.band_y1_pct,
                    a.band_source,
                    a.band_set_at,
                    a.band_set_by,
                    max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
                   FROM derm.address_row_map a) r
             LEFT JOIN clients c ON c.id = r.matched_client_id
             LEFT JOIN derm.page_block_extents ext ON ext.dump_folder = r.dump_folder AND ext.effective_page = COALESCE(r.stamp_page, r.page)
          WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM derm_manifests m
                  WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))) sr
     LEFT JOIN gdos gg ON gg.id = (( SELECT r2.gdo_id
           FROM derm.address_row_map r2
          WHERE r2.id = sr.id))) sr
  left join derm.address_row_map a on a.id = sr.id;

create or replace view derm.v_stamp_sheets as
select ss.*,
       ai.ai_placed as ai_placed_rows,
       (ss.placed_rows > 0 and ai.ai_placed = ss.placed_rows) as filled_by_ai
  from (WITH tickets AS (
         SELECT DISTINCT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS wm
           FROM derm_manifests
          WHERE derm_manifests.deleted_at IS NULL AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
        UNION
         SELECT DISTINCT address_row_map.white_manifest_number
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
        ), folder AS (
         SELECT address_row_map.white_manifest_number AS wm,
            min(address_row_map.dump_folder) AS f
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
          GROUP BY address_row_map.white_manifest_number
        ), vis AS (
         SELECT r.white_manifest_number AS wm,
            count(*) AS total,
            count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched,
            count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed
           FROM derm.address_row_map r
             LEFT JOIN clients c ON c.id = r.matched_client_id
          WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM derm_manifests m
                  WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))
          GROUP BY r.white_manifest_number
        )
 SELECT COALESCE(folder.f, 'ticket-'::text || t.wm) AS dump_folder,
    t.wm AS white_manifest_number,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL) AS service_date,
    COALESCE(array_length(spi.imgs, 1), 0)::bigint AS page_count,
    spi.imgs AS page_image_urls,
    COALESCE(vis.total, 0::bigint) AS total_rows,
    COALESCE(vis.matched, 0::bigint) AS matched_rows,
    COALESCE(vis.placed, 0::bigint) AS placed_rows,
    COALESCE(s.completed, false) AS completed,
    s.completed_at,
    COALESCE(( SELECT max(m.dump_ticket_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL), ( SELECT max(m.service_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL)) AS dump_date,
    derm.fn_sheet_is_generated(t.wm) AS is_generated
   FROM tickets t
     LEFT JOIN folder ON folder.wm = t.wm
     LEFT JOIN vis ON vis.wm = t.wm
     LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = COALESCE(folder.f, 'ticket-'::text || t.wm)
     CROSS JOIN LATERAL ( SELECT derm.ticket_page_images(t.wm) AS imgs) spi) ss
  left join lateral (
    select count(*) filter (where a.stamp_placed_by = 'stamp-studio-ai') as ai_placed
      from derm.address_row_map a
     where a.dump_folder = ss.dump_folder and a.stamp_placed_at is not null
  ) ai on true;

-- the two sheets filled today are finished
insert into derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
values ('ticket-309898', true, now(), 'stamp-studio-ai', now()),
       ('ticket-309944', true, now(), 'stamp-studio-ai', now())
on conflict (dump_folder) do update
   set completed = true, completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
       completed_by = excluded.completed_by, updated_at = now();

commit;
