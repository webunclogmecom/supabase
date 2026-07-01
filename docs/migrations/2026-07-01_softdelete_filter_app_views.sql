-- 2026-07-01_softdelete_filter_app_views.sql
-- Health-check finding (DB Integrity dimension): five app-facing views read bare
-- public.visits / public.derm_manifests with NO deleted_at filter, so soft-deleted
-- rows leak into the customer/derm app surfaces. Standing rule = soft-delete only;
-- app views must never surface deleted_at IS NOT NULL rows.
--
-- Confirmed leaking TODAY:
--   * customer.inspection_items — 2 POST-inspection rows resolve to a soft-deleted
--     visit (visits 6547 cancelled/6824 scheduled, both deleted); those 2 rows drop.
--   * customer.permits — over_gdo_max for 1 ACTIVE GDO (property 162) derived its
--     last-completed date from a soft-deleted visit (5-day error; flag unaffected today).
-- Latent (0 rows leaking today, hardened so it can't grow as the 303 soft-deletes accrue):
--   * customer.recommendations, customer.wo_photos — bare JOIN visits.
--   * derm.gdos — manifest_count subquery over derm_manifests, no deleted_at filter.
--
-- Change = add `AND <alias>.deleted_at IS NULL` only. No column list / option change.
-- reloptions were NULL on all five (owner=postgres, default RLS) → CREATE OR REPLACE
-- preserves behavior. search_path pinned to public so unqualified table names bind to
-- public (NOT the customer.clients view / derm.gdos view — avoids self-reference).

SET search_path TO public;

-- 1) customer.inspection_items — filter the visit-resolution subquery in the iv CTE
CREATE OR REPLACE VIEW customer.inspection_items AS
 WITH iv AS (
         SELECT i.id,
            i.is_valve_closed,
            i.has_issue,
            i.issue_note,
            ( SELECT v.id
                   FROM visits v
                  WHERE v.vehicle_id = i.vehicle_id AND v.visit_date = i.shift_date AND v.deleted_at IS NULL
                  ORDER BY (v.visit_status = 'completed'::text) DESC, v.id
                 LIMIT 1) AS visit_id
           FROM inspections i
          WHERE i.inspection_type = 'POST'::text
        )
 SELECT id,
    work_order_id,
    label,
    value,
    is_positive,
    "position"
   FROM ( SELECT md5('insp-valve-'::text || iv.id::text)::uuid AS id,
            ( SELECT v.public_id
                   FROM visits v
                  WHERE v.id = iv.visit_id) AS work_order_id,
            'Valve closed'::text AS label,
            COALESCE(iv.is_valve_closed, false) AS value,
            true AS is_positive,
            0 AS "position"
           FROM iv
          WHERE iv.visit_id IS NOT NULL AND iv.is_valve_closed IS NOT NULL
        UNION ALL
         SELECT md5('insp-issue-'::text || iv.id::text)::uuid AS md5,
            ( SELECT v.public_id
                   FROM visits v
                  WHERE v.id = iv.visit_id) AS work_order_id,
                CASE
                    WHEN iv.has_issue THEN COALESCE(iv.issue_note, 'Issue reported'::text)
                    ELSE 'No issues'::text
                END AS "case",
            NOT COALESCE(iv.has_issue, false),
            true,
            1
           FROM iv
          WHERE iv.visit_id IS NOT NULL AND iv.has_issue IS NOT NULL) sub;

-- 2) customer.permits — filter the over_gdo_max last-completed subquery
CREATE OR REPLACE VIEW customer.permits AS
 SELECT customer.uuid_from_bigint(g.id) AS id,
    customer.uuid_from_bigint(g.client_id) AS client_id,
    g.gdo_number AS permit_number,
    'Grease Trap'::text AS area,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::text
            WHEN g.max_frequency_days <= 35 THEN 'Monthly'::text
            WHEN g.max_frequency_days <= 95 THEN 'Quarterly'::text
            WHEN g.max_frequency_days <= 185 THEN 'Semi-annually'::text
            WHEN g.max_frequency_days <= 380 THEN 'Annually'::text
            ELSE ('Every '::text || g.max_frequency_days) || ' days'::text
        END AS frequency,
    g.permit_document_path AS permit_url,
    (row_number() OVER (PARTITION BY g.client_id ORDER BY g.property_id, g.gdo_number) - 1)::integer AS "position",
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE COALESCE((CURRENT_DATE - (( SELECT max(v.visit_date) AS max
               FROM visits v
              WHERE v.property_id = g.property_id AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL))) > g.max_frequency_days, true)
        END AS over_gdo_max,
    sc.frequency_days AS our_frequency_days,
        CASE
            WHEN sc.frequency_days IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE sc.frequency_days <= g.max_frequency_days
        END AS compliant
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN LATERAL ( SELECT s.frequency_days
           FROM service_configs s
          WHERE s.property_id = g.property_id AND s.service_type = 'GT'::text AND s.frequency_days IS NOT NULL
          ORDER BY s.id
         LIMIT 1) sc ON true
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]));

-- 3) customer.recommendations — filter the bare visits join
CREATE OR REPLACE VIEW customer.recommendations AS
 SELECT customer.uuid_from_bigint(vr.id) AS id,
    v.public_id AS work_order_id,
    vr.label,
    vr.is_needed AS needed,
    vr."position"
   FROM visit_recommendations vr
     JOIN visits v ON v.id = vr.visit_id AND v.deleted_at IS NULL;

-- 4) customer.wo_photos — filter the bare visits join
CREATE OR REPLACE VIEW customer.wo_photos AS
 SELECT customer.uuid_from_bigint(pl.id) AS id,
    v.public_id AS work_order_id,
    pc.service_phase AS variant,
    customer.public_url(ph.storage_path) AS url,
    pl.caption,
    (row_number() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS "position",
    customer.thumbnail_url(ph.storage_path, 400) AS thumbnail_url
   FROM photo_links pl
     JOIN photos ph ON ph.id = pl.photo_id
     JOIN photo_classifications pc ON pc.photo_link_id = pl.id
     JOIN visits v ON v.id = pl.entity_id AND v.deleted_at IS NULL
  WHERE pl.entity_type = 'visit'::text AND (pc.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'extra'::text]));

-- 5) derm.gdos — filter the manifest_count subquery over derm_manifests
CREATE OR REPLACE VIEW derm.gdos AS
 SELECT g.id,
    g.client_id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    g.gdo_number,
    g.location_label,
    g.property_id,
    g.permit_expiration::text AS permit_expiration,
    g.permit_document_path,
    g.status,
    g.notes,
    g.created_at::text AS created_at,
    g.updated_at::text AS updated_at,
    ( SELECT count(*) AS count
           FROM derm_manifests dm
          WHERE dm.gdo_id = g.id AND dm.deleted_at IS NULL) AS manifest_count
   FROM gdos g
     JOIN clients c ON c.id = g.client_id;
