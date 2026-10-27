-- ============================================================================
-- 2026-10-27_rollback_stamp_skip_sheet_with_no_scan
-- Undoes 2026-10-27_1640_stamp_skip_sheet_with_no_scan: the view and fn_stamp_open_sheets go back to their bodies of 2026-10-27 16:30 ET,
-- the two new functions and the four skip columns are dropped (the skips stay in audit.logs).
-- The Studio build that reads the new columns must be reverted FIRST, or its home table fails to load.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION derm.set_sheet_skipped(text, boolean, text, text);
CREATE OR REPLACE FUNCTION derm.fn_stamp_open_sheets()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'manifest', s.white_manifest_number,
           'service_date', s.service_date,
           'dump_date', s.dump_date,
           'placed', s.placed_rows,
           'total', s.total_rows,
           'pages', s.page_count,
           'status', case when s.placed_rows > 0 then 'In progress' else 'Not started' end,
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date),
           -- 2026-10-17: what the sheet waits for, from the Studio's own answer (derm.fn_stamp_sheet_wait_reason)
           'reason', derm.fn_stamp_sheet_wait_reason(s.dump_folder))
         order by coalesce(s.dump_date, s.service_date) nulls last, s.white_manifest_number), '[]'::jsonb)
    from derm.v_stamp_sheets s
    -- 2026-10-12: the clients the sheet names (its live manifests and its cards) and how many of them are test or
    -- fixture clients (public.fn_is_non_customer, the shared registry). A manifest with no client, or a card known only
    -- by its manual code, counts as a real client, so this can never hide a real sheet.
    cross join lateral (
      select count(*) as named,
             count(*) filter (where public.fn_is_non_customer(c.client_id, array['test', 'fixture'])) as test
        from (select m.client_id from public.derm_manifests m
               where coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                 and m.deleted_at is null
              union all
              select r.matched_client_id from derm.address_row_map r
               where r.white_manifest_number = s.white_manifest_number
                 and (r.matched_client_id is not null or r.manual_code is not null)) c) k
   where not s.completed
     -- a sheet whose clients are ALL test or fixture clients is not posted: the real post tags Diego and Serena
     and not (k.named > 0 and k.test = k.named);
$function$;
DROP VIEW derm.v_page_reference_backlog;
DROP VIEW derm.v_stamp_sheets;
CREATE VIEW derm.v_stamp_sheets AS
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
  WHERE NOT ((EXISTS ( SELECT 1
           FROM derm_manifests m
             JOIN disposal_facilities df ON df.id = m.disposal_facility_id
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL AND fn_dump_county_bucket(df.county) = 'BROWARD'::text AND COALESCE(m.dump_ticket_date, m.service_date) >= '2026-09-02'::date)) AND NOT (EXISTS ( SELECT 1
           FROM derm_manifests m
             LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL AND fn_dump_county_bucket(df.county) IS DISTINCT FROM 'BROWARD'::text))) AND NOT ((EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number AND m.deleted_at IS NULL)));
GRANT SELECT ON derm.v_stamp_sheets TO authenticated, db_backup_reader;
COMMENT ON VIEW derm.v_stamp_sheets IS 'Stamp Studio sheet list (one row per ticket). 2026-10-06: a ticket whose manifests are all soft-deleted (at least one, none live) is left out; a ticket with no manifest under its number still shows. Read by derm.fn_stamp_open_sheets (the 10 AM reminder).';
CREATE VIEW derm.v_page_reference_backlog AS
 WITH open_pages AS (
         SELECT s.dump_folder,
            s.white_manifest_number,
            p.page::integer AS page,
            p.url AS image_url
           FROM derm.v_stamp_sheets s
             CROSS JOIN LATERAL unnest(s.page_image_urls) WITH ORDINALITY p(url, page)
          WHERE NOT s.completed AND p.url IS NOT NULL
        ), cur AS (
         SELECT o.dump_folder,
            o.white_manifest_number,
            o.page,
            o.image_url,
            derm._img_etag(o.image_url) AS source_etag,
            e.top_pct,
            e.bottom_pct
           FROM open_pages o
             LEFT JOIN derm.page_block_extents e ON e.dump_folder = o.dump_folder AND e.effective_page = o.page
        )
 SELECT c.dump_folder,
    c.white_manifest_number,
    c.page,
    c.image_url,
    c.source_etag,
    c.top_pct,
    c.bottom_pct,
        CASE
            WHEN a.dump_folder IS NULL OR a.image_url IS DISTINCT FROM c.image_url OR a.source_etag IS DISTINCT FROM c.source_etag THEN 0
            ELSE a.attempts
        END AS attempts_on_this_image,
    a.last_outcome,
    a.last_reason,
    a.last_attempt_at
   FROM cur c
     LEFT JOIN derm.page_reference_attempts a ON a.dump_folder = c.dump_folder AND a.page = c.page
  WHERE NOT (EXISTS ( SELECT 1
           FROM derm.page_rule_scans sc
          WHERE sc.dump_folder = c.dump_folder AND sc.effective_page = c.page AND (sc.source ~~ 'runlen-v2-%'::text OR sc.source ~~ 'template-v1-%'::text) AND (sc.source_etag IS NOT NULL AND sc.source_etag = c.source_etag OR sc.source_etag IS NULL AND sc.source_url = c.image_url)));
GRANT SELECT ON derm.v_page_reference_backlog TO service_role, db_backup_reader;
COMMENT ON VIEW derm.v_page_reference_backlog IS 'Pages of Stamp sheets not completed whose current scan has no machine measurement yet. 2026-10-05.';
DROP FUNCTION derm.fn_sheet_missing_scan(text);
ALTER TABLE derm.stamp_sheet_status
  DROP CONSTRAINT stamp_sheet_status_skip_whole_check,
  DROP CONSTRAINT stamp_sheet_status_skip_reason_check,
  DROP COLUMN skip_note, DROP COLUMN skip_reason, DROP COLUMN skipped_by, DROP COLUMN skipped_at;
DO $v$ BEGIN
  IF md5(pg_get_viewdef('derm.v_stamp_sheets'::regclass, true)) IS DISTINCT FROM 'bf040c4294a85d691fef58b26fc7a678' THEN RAISE EXCEPTION 'view not restored'; END IF;
  IF md5(pg_get_functiondef('derm.fn_stamp_open_sheets()'::regprocedure)) IS DISTINCT FROM '6169f30369a09d8bb95b10c3353849b1' THEN RAISE EXCEPTION 'open list not restored'; END IF;
END $v$;
COMMIT;
