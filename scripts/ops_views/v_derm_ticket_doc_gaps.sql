-- ============================================================================
-- ops.v_derm_ticket_doc_gaps — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_ticket_doc_gaps AS
WITH per_row AS (
         SELECT COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS ticket,
            dm.id,
            array_remove(ARRAY[dm.derm_address_url], NULL::text) || COALESCE(dm.derm_address_extra_urls, '{}'::text[]) AS urls
           FROM derm_manifests dm
          WHERE dm.deleted_at IS NULL AND COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) IS NOT NULL
        ), per_tkt AS (
         SELECT per_row.ticket,
            count(DISTINCT per_row.id) AS n_rows,
            count(DISTINCT u.u) AS n_sheets
           FROM per_row
             LEFT JOIN LATERAL unnest(per_row.urls) u(u) ON true
          GROUP BY per_row.ticket
        ), crossc AS (
         SELECT COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS ticket,
            count(*) AS n_cross
           FROM manifest_visits mv
             JOIN derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
             JOIN visits v ON v.id = mv.visit_id
          WHERE dm.client_id IS DISTINCT FROM v.client_id
          GROUP BY (COALESCE(dm.white_manifest_number, dm.yellow_ticket_number))
        )
 SELECT t.ticket,
    t.n_rows,
    t.n_sheets,
    round(t.n_rows::numeric / GREATEST(t.n_sheets, 1::bigint)::numeric, 1) AS rows_per_sheet,
    t.n_rows > (5 * GREATEST(t.n_sheets, 1::bigint)) AS pages_suspect,
    COALESCE(c.n_cross, 0::bigint) AS crossclient_links
   FROM per_tkt t
     LEFT JOIN crossc c USING (ticket)
  WHERE t.n_rows > (5 * GREATEST(t.n_sheets, 1::bigint)) OR COALESCE(c.n_cross, 0::bigint) > 0
  ORDER BY (round(t.n_rows::numeric / GREATEST(t.n_sheets, 1::bigint)::numeric, 1)) DESC, (COALESCE(c.n_cross, 0::bigint)) DESC;
