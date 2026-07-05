-- 2026-07-04_derm_audit_pack.sql  (rev 2 — post adversarial review)
-- DERM INSPECTOR AUDIT PACK — DB-ONLY (per Fred: logic lives in the database).
--   derm.audit_pack(manifest_id)             -> jsonb chain-of-custody pack
--   derm.audit_pack_client(client, from, to) -> jsonb client-period dossier
-- Review fixes applied:
--   * record_pk is JSONB -> compare record_pk->>'id' (also matches the existing
--     Prod index logs_table_record_changed_idx). The old ::text comparison
--     silently returned ZERO derm_manifests custody events.
--   * chain_of_custody restructured as UNION ALL with table_schema filters
--     (public/derm namesakes exist) + two additive partial indexes on
--     audit.logs so anon calls stay index-backed as the log grows.
--   * frequency_check excludes the manifest's OWN linked visits (a linked
--     visit dated service_date-1 previously faked 'within-frequency').
--   * custody ordering by real timestamptz, not jsonb text.
--   * client dossier: lag() seeded with the last pre-window visit so a gap
--     spanning the period start is caught; single-location assumption
--     surfaced in the output (GDOs are location-bound per Fred 2026-05-25).
-- Read-only; SECURITY DEFINER solely to read audit.logs; curated fields only
-- (operation, app_source, actor, timestamp — no row bodies, no jwt/headers).
-- Audit Rule 8: N/A (functions + indexes only, no tables).

BEGIN;

-- Index-back the two jsonb-extraction custody branches (audit.logs is append-only).
CREATE INDEX IF NOT EXISTS logs_mv_manifest_idx ON audit.logs
  (((coalesce(new_row, old_row))->>'manifest_id'))
  WHERE table_schema = 'public' AND table_name = 'manifest_visits';
CREATE INDEX IF NOT EXISTS logs_arm_manifest_idx ON audit.logs
  (((coalesce(new_row, old_row))->>'matched_manifest_id'))
  WHERE table_schema = 'derm' AND table_name = 'address_row_map';

CREATE OR REPLACE FUNCTION derm.audit_pack(p_manifest_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = derm, public, audit AS $$
DECLARE
  v_m   public.derm_manifests%ROWTYPE;
  v_out jsonb;
BEGIN
  SELECT * INTO v_m FROM public.derm_manifests WHERE id = p_manifest_id;
  IF v_m.id IS NULL THEN RAISE EXCEPTION 'manifest % not found', p_manifest_id; END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'manifest', jsonb_build_object(
      'id', v_m.id,
      'white_manifest_number', v_m.white_manifest_number,
      'yellow_ticket_number',  v_m.yellow_ticket_number,
      'service_date',          v_m.service_date,
      'dump_ticket_date',      v_m.dump_ticket_date,
      'disposal_facility', (SELECT df.name FROM public.disposal_facilities df
                             WHERE df.id = v_m.disposal_facility_id),
      'deleted', v_m.deleted_at IS NOT NULL),
    'documents', jsonb_strip_nulls(jsonb_build_object(
      'manifest_form_url',  v_m.derm_manifest_url,
      'wwtp_receipt_path',  v_m.wwtp_receipt_document_path,
      'address_sheet_url',  v_m.derm_address_url,
      'address_sheet_extra_urls', to_jsonb(v_m.derm_address_extra_urls),
      'fog_manifest_url',   v_m.fog_manifest_url)),
    'client', (SELECT jsonb_build_object(
        'id', c.id, 'client_code', c.client_code, 'name', c.name, 'status', c.status,
        'address', (SELECT p.address || ', ' || coalesce(p.city,'')
                      FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1))
      FROM public.clients c WHERE c.id = v_m.client_id),
    'gdo', (SELECT jsonb_build_object(
        'gdo_number', g.gdo_number, 'status', g.status,
        'permit_expiration', g.permit_expiration,
        'max_frequency_days', g.max_frequency_days)
      FROM public.gdos g
      WHERE g.id = coalesce(v_m.gdo_id,
              (SELECT g2.id FROM public.gdos g2
                WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'
                ORDER BY g2.id LIMIT 1))),
    'linked_visits', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'visit_id', v.id, 'visit_date', v.visit_date,
        'service_type', v.service_type, 'status', v.visit_status,
        'derm_required', v.derm_required,
        'line_items', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'name', li.name, 'quantity', li.quantity))
          FROM public.line_items li WHERE li.visit_id = v.id), '[]'::jsonb))
        ORDER BY v.visit_date)
      FROM public.manifest_visits mv
      JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
      WHERE mv.manifest_id = v_m.id), '[]'::jsonb),
    'stamped_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'page', r.page, 'row_index', r.row_index,
        'facility_read', r.facility_name_read,
        'stamp_placed', r.stamp_placed_at IS NOT NULL,
        'stamp_x_pct', r.stamp_x_pct, 'stamp_y_pct', r.stamp_y_pct,
        'band_y0_pct', r.band_y0_pct, 'band_y1_pct', r.band_y1_pct,
        'human_verified', r.reviewed_at IS NOT NULL,
        'verified_at', r.reviewed_at)
        ORDER BY r.page, r.row_index)
      FROM derm.address_row_map r
      WHERE r.matched_manifest_id = v_m.id), '[]'::jsonb),
    'sheet_completed', coalesce((SELECT s.completed
      FROM derm.address_row_map r
      JOIN derm.stamp_sheet_status s ON s.dump_folder = r.dump_folder
      WHERE r.matched_manifest_id = v_m.id LIMIT 1), false),
    'frequency_check', (SELECT CASE
        WHEN g.max_frequency_days IS NULL THEN jsonb_build_object('status','no-gdo-max-on-file')
        WHEN prev.visit_date IS NULL       THEN jsonb_build_object('status','no-prior-visit',
                                                 'max_frequency_days', g.max_frequency_days)
        ELSE jsonb_build_object(
          'status', CASE WHEN (v_m.service_date - prev.visit_date) <= g.max_frequency_days
                         THEN 'within-frequency' ELSE 'exceeded' END,
          'days_since_prior_pumping', (v_m.service_date - prev.visit_date),
          'max_frequency_days', g.max_frequency_days,
          'prior_visit_date', prev.visit_date) END
      FROM (SELECT 1) one
      LEFT JOIN public.gdos g ON g.id = coalesce(v_m.gdo_id,
             (SELECT g2.id FROM public.gdos g2
               WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'
               ORDER BY g2.id LIMIT 1))
      LEFT JOIN LATERAL (SELECT v.visit_date FROM public.visits v
        WHERE v.client_id = v_m.client_id AND v.deleted_at IS NULL
          AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
          AND v.visit_date < v_m.service_date
          -- review fix: never treat this manifest's OWN linked visit as "prior"
          AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv2
                           WHERE mv2.manifest_id = v_m.id AND mv2.visit_id = v.id)
        ORDER BY v.visit_date DESC LIMIT 1) prev ON true),
    'chain_of_custody', coalesce((SELECT jsonb_agg(ev ORDER BY at) FROM (
      SELECT l.changed_at AS at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name') AS ev
      FROM audit.logs l
      WHERE l.table_schema = 'public' AND l.table_name = 'derm_manifests'
        AND l.record_pk->>'id' = v_m.id::text
      UNION ALL
      SELECT l.changed_at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name')
      FROM audit.logs l
      WHERE l.table_schema = 'public' AND l.table_name = 'manifest_visits'
        AND (coalesce(l.new_row, l.old_row))->>'manifest_id' = v_m.id::text
      UNION ALL
      SELECT l.changed_at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name')
      FROM audit.logs l
      WHERE l.table_schema = 'derm' AND l.table_name = 'address_row_map'
        AND (coalesce(l.new_row, l.old_row))->>'matched_manifest_id' = v_m.id::text
      ) evs), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $$;
GRANT EXECUTE ON FUNCTION derm.audit_pack(bigint) TO anon, authenticated;

-- Client-period dossier. NOTE (surfaced in output): frequency analysis merges
-- all of a client's locations; GDOs are location-bound (Fred 2026-05-25), so
-- multi-location clients need per-location scoping in a later rev.
CREATE OR REPLACE FUNCTION derm.audit_pack_client(p_client_id bigint, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = derm, public AS $$
DECLARE v_out jsonb;
BEGIN
  SELECT jsonb_build_object(
    'generated_at', now(),
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'assumptions', jsonb_build_array(
      'frequency analysis merges all client locations (GDOs are location-bound; multi-location clients need per-location scoping)'),
    'client', (SELECT jsonb_build_object('id', c.id, 'client_code', c.client_code,
        'name', c.name, 'status', c.status) FROM public.clients c WHERE c.id = p_client_id),
    'gdo', (SELECT jsonb_build_object('gdo_number', g.gdo_number,
        'permit_expiration', g.permit_expiration, 'max_frequency_days', g.max_frequency_days)
      FROM public.gdos g WHERE g.client_id = p_client_id AND g.status = 'ACTIVE'
      ORDER BY g.id LIMIT 1),
    'manifests', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'manifest_id', m.id,
        'white_manifest_number', m.white_manifest_number,
        'service_date', m.service_date,
        'linked_visits', (SELECT count(*) FROM public.manifest_visits mv WHERE mv.manifest_id = m.id),
        'stamped', EXISTS (SELECT 1 FROM derm.address_row_map r
                            WHERE r.matched_manifest_id = m.id AND r.stamp_placed_at IS NOT NULL),
        'human_verified', EXISTS (SELECT 1 FROM derm.address_row_map r
                            WHERE r.matched_manifest_id = m.id AND r.reviewed_at IS NOT NULL))
        ORDER BY m.service_date)
      FROM public.derm_manifests m
      WHERE m.client_id = p_client_id AND m.deleted_at IS NULL
        AND m.service_date BETWEEN p_from AND p_to), '[]'::jsonb),
    'frequency_violations', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'from_visit', prev_date, 'to_visit', visit_date, 'gap_days', gap,
        'max_frequency_days', maxf) ORDER BY visit_date)
      FROM (SELECT vv.visit_date,
                   lag(vv.visit_date) OVER (ORDER BY vv.visit_date) AS prev_date,
                   vv.visit_date - lag(vv.visit_date) OVER (ORDER BY vv.visit_date) AS gap,
                   (SELECT g.max_frequency_days FROM public.gdos g
                     WHERE g.client_id = p_client_id AND g.status = 'ACTIVE'
                     ORDER BY g.id LIMIT 1) AS maxf
            FROM (
              SELECT v.visit_date FROM public.visits v
              WHERE v.client_id = p_client_id AND v.deleted_at IS NULL
                AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
                AND v.visit_date BETWEEN p_from AND p_to
              UNION ALL
              -- review fix: seed lag() with the last pre-window pumping visit so
              -- a violation gap spanning the period start is caught
              (SELECT v.visit_date FROM public.visits v
               WHERE v.client_id = p_client_id AND v.deleted_at IS NULL
                 AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
                 AND v.visit_date < p_from
               ORDER BY v.visit_date DESC LIMIT 1)
            ) vv) gaps
      WHERE gaps.visit_date >= p_from
        AND gaps.maxf IS NOT NULL AND gaps.gap > gaps.maxf), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $$;
GRANT EXECUTE ON FUNCTION derm.audit_pack_client(bigint, date, date) TO anon, authenticated;

COMMIT;
