-- 2026-07-04_derm_stamp_studio_v2_backbone.sql
-- DERM Stamp Studio v2 — "stamp once, feed everything". Enriches the manual
-- stamping capture so one pass by Yannick powers: FP blackout (client-region),
-- DERM Tracker linkage double-check (visits via manifest_visits), and the DERM
-- 2-week compliance rule. ADDITIVE + reference-only (no snapshot/source-prefixed
-- columns; manifest_visits stays the canonical link table — we only INSERT into it,
-- human-triggered + idempotent).
-- Audit Rule 8: address_row_map is derm-schema app tooling (opt-out, documented).
--   The one compliance write (derm.link_row_visit -> public.manifest_visits) rides
--   manifest_visits' existing audit trigger (opted in 2026-05-18).

BEGIN;

-- 1. BACKBONE: each stamped row -> the per-client manifest it depicts.
--    (white_manifest_number, client_id) is UNIQUE in derm_manifests (verified 458/458),
--    so the backfill is deterministic. From this one FK, a single join yields the
--    client (blackout region), the linked visit(s) (linkage-verify), and the
--    physical-proof signal (2-week rule).
ALTER TABLE derm.address_row_map
  ADD COLUMN IF NOT EXISTS matched_manifest_id bigint REFERENCES public.derm_manifests(id);

UPDATE derm.address_row_map r
   SET matched_manifest_id = dm.id
  FROM public.derm_manifests dm
 WHERE dm.white_manifest_number = r.white_manifest_number
   AND dm.client_id = r.matched_client_id
   AND dm.deleted_at IS NULL
   AND r.matched_client_id IS NOT NULL
   AND r.matched_manifest_id IS DISTINCT FROM dm.id;

-- 2. ROW BAND (for FP per-client redaction): vertical strip [y0,y1] as % of the
--    page image that belongs to this client's row. Point stamp stays untouched.
ALTER TABLE derm.address_row_map
  ADD COLUMN IF NOT EXISTS band_y0_pct  numeric(6,3),
  ADD COLUMN IF NOT EXISTS band_y1_pct  numeric(6,3),
  ADD COLUMN IF NOT EXISTS band_source  text,        -- 'manual' | 'derived'
  ADD COLUMN IF NOT EXISTS band_set_at  timestamptz,
  ADD COLUMN IF NOT EXISTS band_set_by  text;
-- reviewed_at / reviewed_by already exist on the table -> per-row human verify.

-- 3. ENRICHED CARD VIEW (manifest, band, reviewed, live link-state).
-- CREATE OR REPLACE keeps the existing 20 columns in order, then APPENDS the new ones.
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
SELECT r.id, r.dump_folder, r.white_manifest_number, r.page, r.row_index, r.image_url,
       r.facility_name_read, r.address_read,
       COALESCE(c.client_code, r.manual_code) AS client_code,
       COALESCE(c.name, r.manual_code)        AS client_name,
       (SELECT min(m.service_date) FROM public.derm_manifests m
          WHERE m.white_manifest_number = r.white_manifest_number) AS service_date,
       r.assignment_status, r.confidence,
       r.stamp_x_pct, r.stamp_y_pct, r.stamp_page,
       6.0::numeric AS guess_x_pct,
       round((40 + (r.row_index - 0.5)
              * (52.0 / NULLIF(max(r.row_index) OVER (PARTITION BY r.dump_folder, r.page), 0)))::numeric, 3) AS guess_y_pct,
       (r.stamp_placed_at IS NOT NULL) AS placed,
       (r.source = 'stamp-studio')     AS is_manual,
       -- appended v2 columns:
       r.matched_client_id,
       r.matched_manifest_id,
       r.band_y0_pct, r.band_y1_pct, r.band_source,
       (r.reviewed_at IS NOT NULL)     AS reviewed,
       (r.matched_manifest_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
       (SELECT count(*) FROM public.manifest_visits mv WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count
FROM derm.address_row_map r
LEFT JOIN public.clients c ON c.id = r.matched_client_id
WHERE r.white_manifest_number IS NOT NULL
  AND ((r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL) OR r.manual_code IS NOT NULL);

-- 4. CANDIDATE VISITS for a row (the "link a visit" picker): this client's
--    completed visits near the sheet's service date, with current link state.
--    Frontend filters by row_id.
CREATE OR REPLACE VIEW derm.v_stamp_row_candidate_visits AS
SELECT r.id AS row_id,
       v.id AS visit_id,
       v.visit_date,
       v.service_type,
       v.assigned_driver_id,
       (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id) AS driver_name,
       EXISTS (SELECT 1 FROM public.manifest_visits mv
                WHERE mv.manifest_id = r.matched_manifest_id AND mv.visit_id = v.id) AS already_linked
FROM derm.address_row_map r
JOIN public.derm_manifests m ON m.id = r.matched_manifest_id
JOIN public.visits v ON v.client_id = r.matched_client_id
   AND v.deleted_at IS NULL
   AND v.visit_status = 'completed'
   AND v.visit_date BETWEEN m.service_date - INTERVAL '4 days' AND m.service_date + INTERVAL '4 days'
WHERE r.matched_client_id IS NOT NULL;

-- 5. LINKAGE GAPS (the physical-proof complement to the 2-week rule): a client is
--    stamped on a sheet but has NO linked visit for that manifest number.
CREATE OR REPLACE VIEW derm.v_stamp_linkage_gaps AS
SELECT DISTINCT
       r.white_manifest_number,
       r.matched_client_id,
       c.client_code,
       c.name AS client_name,
       r.matched_manifest_id,
       (r.matched_manifest_id IS NULL) AS no_manifest_row
FROM derm.address_row_map r
JOIN public.clients c ON c.id = r.matched_client_id
WHERE r.matched_client_id IS NOT NULL
  AND r.white_manifest_number IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.derm_manifests m
    JOIN public.manifest_visits mv ON mv.manifest_id = m.id
    JOIN public.visits v ON v.id = mv.visit_id
    WHERE m.white_manifest_number = r.white_manifest_number
      AND v.client_id = r.matched_client_id);

-- 6. AUTHORITATIVE multi-client flag (fixes ADR 017 Option 2's unsafe inference).
CREATE OR REPLACE VIEW derm.v_sheet_client_count AS
SELECT white_manifest_number,
       count(DISTINCT COALESCE(matched_client_id::text, manual_code)) AS client_count,
       count(*) FILTER (WHERE matched_client_id IS NOT NULL OR manual_code IS NOT NULL) AS mapped_rows,
       count(*) AS total_rows
FROM derm.address_row_map
WHERE white_manifest_number IS NOT NULL
GROUP BY white_manifest_number;

-- 7. WRITE RPCs.
CREATE OR REPLACE FUNCTION derm.set_row_band(p_row_id bigint, p_y0 numeric, p_y1 numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  IF p_y0 < 0 OR p_y1 > 100 OR p_y0 >= p_y1 THEN
    RAISE EXCEPTION 'invalid band (y0=%, y1=%)', p_y0, p_y1;
  END IF;
  UPDATE derm.address_row_map
     SET band_y0_pct = round(p_y0, 3), band_y1_pct = round(p_y1, 3),
         band_source = 'manual', band_set_at = now(),
         band_set_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $$;

CREATE OR REPLACE FUNCTION derm.set_row_reviewed(p_row_id bigint, p_reviewed boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  UPDATE derm.address_row_map
     SET reviewed_at = CASE WHEN p_reviewed THEN now() END,
         reviewed_by = CASE WHEN p_reviewed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $$;

-- The one cross-domain write: link a visit to this row's manifest. Human-triggered
-- only, idempotent (ON CONFLICT DO NOTHING on the (manifest_id,visit_id) PK), audited
-- via manifest_visits' own trigger. No auto-link, no unlink (unlink stays in DERM Tracker).
CREATE OR REPLACE FUNCTION derm.link_row_visit(p_row_id bigint, p_visit_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_mid bigint; v_cid bigint; v_vcid bigint;
BEGIN
  SELECT matched_manifest_id, matched_client_id INTO v_mid, v_cid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest for this client on this sheet — file it in DERM Tracker first', p_row_id;
  END IF;
  -- safety: the visit must belong to the same client as the row (no cross-client link)
  SELECT client_id INTO v_vcid FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN RAISE EXCEPTION 'visit % not found / deleted', p_visit_id; END IF;
  IF v_cid IS NOT NULL AND v_vcid <> v_cid THEN
    RAISE EXCEPTION 'visit % belongs to a different client than row %', p_visit_id, p_row_id;
  END IF;
  INSERT INTO public.manifest_visits (manifest_id, visit_id)
  VALUES (v_mid, p_visit_id)
  ON CONFLICT DO NOTHING;
END $$;

-- 8. GRANTS.
GRANT SELECT ON derm.v_stamp_rows, derm.v_stamp_row_candidate_visits,
               derm.v_stamp_linkage_gaps, derm.v_sheet_client_count TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.set_row_band(bigint, numeric, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.set_row_reviewed(bigint, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.link_row_visit(bigint, bigint) TO anon, authenticated;

COMMIT;
