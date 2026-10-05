-- Stamp Studio sheet list: Broward folders dumped since 2026-09-02 are hidden
--
-- Fred, voice note 2026-10-05: "since September the 2nd we are working with a different Broward
-- DERM Manifest ... it does not need the stamp on that manifest anymore ... since September 2nd, we
-- don't need any kind of Broward manifest ... We only need to work with the Miami-Dade from now
-- on." Then, on the plan: "You can show any broward already completed, but since Sep 2nd, filter
-- them out."
--
-- Since 2026-09-02 a Broward load is filed on the FDEP 62-705.300(3) per-visit sheet
-- (derm.manifest_visit_sheets), which carries one generator per page and needs no stamp. Those
-- folders still reached the Studio's list through derm.v_stamp_sheets with 0 pages (no shared
-- address sheet, so derm.ticket_page_images returns nothing) and sat there as "Not started".
--
-- THE RULE, applied to the whole folder as the list's outer WHERE:
--   hide a folder when at least one of its live manifests went to a BROWARD disposal facility on
--   or after 2026-09-02 (dump date, else service date), AND none of its live manifests went
--   anywhere else (Miami-Dade, or a facility we cannot place). A mixed folder stays, because its
--   Miami-Dade pickups still need the stamp.
-- County through public.fn_dump_county_bucket (the one county normaliser, 'BROWARD' / 'DADE' /
-- other), which authenticated can EXECUTE. NOT derm.fn_ticket_dump_bucket: service_role/postgres
-- only, so the list would raise 42501 for every staff user and render blank.
-- 🛑 Filtering only the view's `tickets` CTE does not work: address_row_map is UNION-ed back in, so
-- a folder with a card would reappear. That is why the predicate is the outer WHERE.
--
-- Measured before apply (signed in as authenticated, the way the app reads it): 154 -> 151 rows.
-- Hidden: ticket-312840 (09-02), ticket-313151 (09-08), ticket-9-24-26 (09-24), all Broward, all
-- "Not started" with 0 pages. Kept: the 13 Miami-Dade folders dumped after 09-02, and the 23
-- Broward folders dumped before 09-02 (all completed).
-- Only the list changes: the manifests, the FDEP sheets, the DERM Tracker and the city email are
-- untouched. Column list unchanged, so CREATE OR REPLACE keeps the grants; no dependents.
-- The body is the live pg_get_viewdef output with the WHERE appended after its last join.
-- Rule 8: a view, nothing to audit.

begin;

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
    ss.placed_rows > 0 AND ai.ai_placed = ss.placed_rows AS filled_by_ai
   FROM ( WITH tickets AS (
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
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE a.stamp_placed_by = 'stamp-studio-ai'::text) AS ai_placed
           FROM derm.address_row_map a
             LEFT JOIN clients c2 ON c2.id = a.matched_client_id
          WHERE a.dump_folder = ss.dump_folder AND a.stamp_placed_at IS NOT NULL AND (a.matched_client_id IS NOT NULL AND c2.client_code IS NOT NULL OR a.manual_code IS NOT NULL)) ai ON true
  -- 2026-10-05: Broward folders dumped on or after 2026-09-02 are not stamped (see header).
  WHERE NOT (
    EXISTS (SELECT 1 FROM public.derm_manifests m
              JOIN public.disposal_facilities df ON df.id = m.disposal_facility_id
             WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number
               AND m.deleted_at IS NULL
               AND public.fn_dump_county_bucket(df.county) = 'BROWARD'
               AND COALESCE(m.dump_ticket_date, m.service_date) >= DATE '2026-09-02')
    AND NOT EXISTS (SELECT 1 FROM public.derm_manifests m
                      LEFT JOIN public.disposal_facilities df ON df.id = m.disposal_facility_id
                     WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number
                       AND m.deleted_at IS NULL
                       AND public.fn_dump_county_bucket(df.county) IS DISTINCT FROM 'BROWARD')
  );

do $verify$
declare n int;
begin
  select count(*) into n from derm.v_stamp_sheets
   where dump_folder in ('ticket-312840','ticket-313151','ticket-9-24-26');
  if n <> 0 then raise exception 'VERIFY: % of the 3 Broward folders are still listed', n; end if;
  -- controls: a Miami-Dade folder after 09-02 and a Broward folder before it are still listed
  select count(*) into n from derm.v_stamp_sheets where dump_folder = 'ticket-836624';
  if n <> 1 then raise exception 'VERIFY control: ticket-836624 (Miami-Dade, 09-21) is gone'; end if;
  select count(*) into n from derm.v_stamp_sheets s
   where s.dump_date < date '2026-09-02'
     and exists (select 1 from public.derm_manifests m join public.disposal_facilities df on df.id = m.disposal_facility_id
                  where coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                    and m.deleted_at is null and public.fn_dump_county_bucket(df.county) = 'BROWARD');
  if n < 1 then raise exception 'VERIFY control: no Broward folder from before 09-02 is listed'; end if;
  if not has_table_privilege('authenticated', 'derm.v_stamp_sheets', 'SELECT') then
    raise exception 'VERIFY: authenticated lost SELECT on the list'; end if;
end $verify$;

commit;
