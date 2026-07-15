-- 2026-07-15_customer_permits_pdf_url.sql
-- Make customer.permits.permit_url a FULL public URL to the GDO PDF (was the bare storage
-- path e.g. "gdo/GDO-10877.pdf"). The Field Portal work order links the GDO number to this URL.
-- PDFs live in the PUBLIC storage bucket "gdo-permits" (verified: HTTP 200, application/pdf).
-- NULL/blank permit_document_path => NULL url (FP renders the number as plain text, no dead link).
-- Only the permit_url expression changed; all other columns/logic identical. Reversible (restore
-- docs/../backups/2026-07-15_customer_permits_before.sql). Audit (ADR 010): view only, no table DML.

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
        CASE
            WHEN g.permit_document_path IS NULL OR btrim(g.permit_document_path) = ''::text THEN NULL::text
            ELSE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/gdo-permits/'::text || g.permit_document_path
        END AS permit_url,
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
              WHERE v.client_id = g.client_id AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL AND (v.property_id = g.property_id OR lower(btrim(vp.address)) = lower(btrim(gp.address)))))) > g.max_frequency_days, true)
        END AS over_gdo_max,
    COALESCE(sc.frequency_days, jf.freq) AS our_frequency_days,
        CASE
            WHEN COALESCE(sc.frequency_days, jf.freq) IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE COALESCE(sc.frequency_days, jf.freq) <= g.max_frequency_days
        END AS compliant
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties gp ON gp.id = g.property_id
     LEFT JOIN LATERAL ( SELECT s.frequency_days
           FROM service_configs s
             JOIN properties sp ON sp.id = s.property_id
          WHERE s.client_id = g.client_id AND s.service_type = 'GT'::text AND s.frequency_days IS NOT NULL AND (s.property_id = g.property_id OR lower(btrim(sp.address)) = lower(btrim(gp.address)))
          ORDER BY (s.property_id = g.property_id) DESC, s.id
         LIMIT 1) sc ON true
     LEFT JOIN LATERAL ( SELECT j.frequency_days AS freq
           FROM jobs j
          WHERE j.client_id = g.client_id AND j.frequency_days > 0
          ORDER BY (j.property_id = g.property_id) DESC NULLS LAST, j.id DESC
         LIMIT 1) jf ON true
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]));
