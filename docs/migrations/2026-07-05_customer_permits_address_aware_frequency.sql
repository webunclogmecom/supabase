-- 2026-07-05  customer.permits: address-aware service-frequency + compliance join
-- ============================================================================
-- WHY: Field Portal "GDO Permits & Frequency" showed a blank PUMP FREQUENCY for
-- 035-LG (La Granja Downtown) — it binds to customer.permits.our_frequency_days,
-- which was NULL. The client HAS the frequency (GT service_config.frequency_days=30,
-- gdos.max_frequency_days=30, SA job #99900617.frequency_days=30), but the view
-- joined the GT service_config to the GDO on property_id, and 035-LG has TWO
-- property records at the SAME address (127 SE 2nd Ave): property 79 (primary/
-- service, where the GDO lives) and property 554 (billing, where the GT
-- service_config lives). Strict property_id match missed it -> NULL -> "—".
-- Affects ~7-15 GDOs with the same service-vs-billing property split (035-LG,
-- 041-MB, 042-MT, 077-TCE, 137-BB, 176-SOU, 192-FRK, ...).
--
-- FIX: make the our_frequency_days LATERAL and the over_gdo_max last-visit lookup
-- ADDRESS-AWARE — match the GT service_config / completed visits for the SAME
-- CLIENT whose property shares the GDO property's address, preferring an exact
-- property_id match, then falling back to same-address. Verified safe: 0 clients
-- have multiple GDOs at DIFFERENT addresses, so no cross-location contamination;
-- the join is client-scoped so no cross-client. No data changes; reversible
-- (backup: backups/2026-07-05_customer_permits_view_before.sql).
-- ----------------------------------------------------------------------------
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
                 JOIN properties vp ON vp.id = v.property_id
              WHERE v.client_id = g.client_id
                AND v.visit_status = 'completed'::text
                AND v.deleted_at IS NULL
                AND (v.property_id = g.property_id
                     OR lower(btrim(vp.address)) = lower(btrim(gp.address)))))) > g.max_frequency_days, true)
        END AS over_gdo_max,
    sc.frequency_days AS our_frequency_days,
        CASE
            WHEN sc.frequency_days IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE sc.frequency_days <= g.max_frequency_days
        END AS compliant
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties gp ON gp.id = g.property_id
     LEFT JOIN LATERAL ( SELECT s.frequency_days
           FROM service_configs s
             JOIN properties sp ON sp.id = s.property_id
          WHERE s.client_id = g.client_id
            AND s.service_type = 'GT'::text
            AND s.frequency_days IS NOT NULL
            AND (s.property_id = g.property_id
                 OR lower(btrim(sp.address)) = lower(btrim(gp.address)))
          ORDER BY (s.property_id = g.property_id) DESC, s.id
         LIMIT 1) sc ON true
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]));
