-- ============================================================================
-- ops.v_derm_row_completeness_gaps — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_row_completeness_gaps AS
WITH tkt AS (
         SELECT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS ticket,
            bool_or(derm_manifests.derm_manifest_url IS NOT NULL OR derm_manifests.derm_address_url IS NOT NULL OR COALESCE(array_length(derm_manifests.derm_manifest_extra_urls, 1), 0) > 0 OR COALESCE(array_length(derm_manifests.derm_address_extra_urls, 1), 0) > 0) AS ticket_has_pdf
           FROM derm_manifests
          WHERE derm_manifests.deleted_at IS NULL AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
          GROUP BY (COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number))
        )
 SELECT mh.id,
    c.client_code,
    COALESCE(mh.white_manifest_number, mh.yellow_ticket_number) AS ticket,
    mh.jurisdiction,
    mh.health_state,
    mh.severity,
    mh.white_manifest_number IS NULL AND mh.yellow_ticket_number IS NULL AS missing_number,
    NOT mh.has_manifest_pdf AS missing_manifest_pdf,
    NOT mh.has_address_pdf AS missing_address_pdf,
    NOT mh.has_dump_date AS missing_dump_date,
    (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = mh.id)) AS visit_linked,
    COALESCE(t.ticket_has_pdf, false) AS ticket_shows_documented,
    mh.notes IS NOT NULL AS accepted_gap_note,
    mh.notes
   FROM derm.manifest_health mh
     LEFT JOIN clients c ON c.id = mh.client_id
     LEFT JOIN tkt t ON t.ticket = COALESCE(mh.white_manifest_number, mh.yellow_ticket_number)
  WHERE mh.health_state <> 'fully_complete'::text;
