-- 2026-06-03c — customer.permits: show OUR pump frequency (in days) + county compliance.
-- Applied via Mgmt API from the Building Apps session (Fred-authorized).
--
-- Field Portal "GDO Permits & Frequency" redesign (Fred, 2026-06-03). The old view
-- bucketed each GDO's max_frequency_days into Monthly/Quarterly/etc. and showed the
-- PERMIT's required frequency — wrong on two counts: (a) lossy/mislabeled (a 60-day
-- permit rendered "Quarterly"), and (b) it should show what WE actually do, not the
-- county requirement. Now the view also exposes:
--   * our_frequency_days — the property's grease-trap service frequency
--       (service_configs.frequency_days, service_type='GT', matched by property_id;
--        one property-level GT service covers all that property's per-location GDOs).
--   * compliant — boolean: our interval <= the GDO's max_frequency_days (we pump at
--       least as often as the county requires). NULL when either number is unknown.
-- The Field Portal shows our_frequency_days as "Every N days"; when compliant = false
-- (we pump LESS often than required) it shows an amber warning icon + a hover tooltip
-- "County requires {max_frequency_days} days". Columns 1-12 are unchanged (back-compat);
-- our_frequency_days + compliant are appended (CREATE OR REPLACE-safe).
--
-- Related one-off DATA fix this session (separate from this DDL): gdos row id 164 for
-- 009-CN / Casa Neos — a legacy pre-client-locations-split row with all 3 GDO numbers
-- concatenated into gdo_number ("GDO-10877, GDO-15062, GDO-16389"), null freq/location,
-- expired 2025-12-04 — was set status='INACTIVE' (reversible) so the FP shows the 3
-- proper per-location GDOs (ids 63/64/65) instead of 4 rows. It was the ONLY comma-joined
-- gdo_number in the table (not systemic).

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
        ELSE COALESCE((CURRENT_DATE - (SELECT max(v.visit_date) FROM visits v WHERE v.property_id = g.property_id AND v.visit_status = 'completed')) > g.max_frequency_days, true)
    END AS over_gdo_max,
    sc.frequency_days AS our_frequency_days,
    CASE
        WHEN sc.frequency_days IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
        ELSE sc.frequency_days <= g.max_frequency_days
    END AS compliant
FROM gdos g
JOIN clients c ON c.id = g.client_id
LEFT JOIN LATERAL (
    SELECT s.frequency_days FROM service_configs s
    WHERE s.property_id = g.property_id AND s.service_type = 'GT' AND s.frequency_days IS NOT NULL
    ORDER BY s.id LIMIT 1
) sc ON true
WHERE g.status = 'ACTIVE' AND c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]);
