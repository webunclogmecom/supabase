-- 2026-05-22b_derm_visits_filter_payment_fees.sql
--
-- Per Fred 2026-05-22: line_items display was showing payment processing
-- fees like "ACH Fee (1%)" and "CC Fees (Deduct if paid by Wire/Check or
-- Zelle) 3.53%" appended to the service description. Those aren't services
-- — they're billing surcharges and visually clutter the row.
--
-- Filter rule: hide line_items where name matches BOTH a payment-method
-- keyword (ACH, CC, Credit Card, Transaction) AND a fee/percent marker.
-- Also hide bare "Tax"/"TAX" entries.
--
-- Real service charges keep showing (e.g. "Round Trip Travel Fee",
-- "Vac Truck Travel Fees", "Pump Truck Travel Fee", "Dump Fee",
-- "Discharge dump fee", "Broward Fees", "Overnight fees") — those
-- describe work performed and the customer should see them.
--
-- Discounts also kept ("Service Discount", "Discount servive first 3 GT")
-- — these are informational and ops may want them visible.
--
-- The filter applies to the display string (line_items column).
-- line_items_json keeps EVERY row for billing/audit completeness.
--
-- Audit (Rule 8): view-only change.

BEGIN;

CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text)
      THEN (c.client_code || ' '::text) || c.name
    ELSE c.name
  END AS client_name,
  COALESCE(p.address, ''::text) AS address,
  COALESCE(p.county, ''::text) AS county,
  v.visit_date::text AS visit_date,
  NULL::text AS technician,
  NULL::text AS notes,
  v.created_at::text AS created_at,
  v.client_id,
  v.service_type,
  (EXISTS (
    SELECT 1
    FROM manifest_visits mv
    JOIN derm_manifests dm ON dm.id = mv.manifest_id
    WHERE mv.visit_id = v.id
      AND (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL)
  )) AS has_manifest,
  v.derm_required,
  COALESCE(v.derm_required, true) AS needs_manifest,
  COALESCE(
    -- Branch 1: job title + invoice line items (with fee filter applied)
    (SELECT NULLIF(TRIM(j.title), '') || ' - ' ||
            (SELECT string_agg(li.name, ', ' ORDER BY li.id)
               FROM line_items li
               WHERE li.invoice_id = v.invoice_id
                 AND li.name IS NOT NULL
                 -- exclude payment processing fees (ACH/CC/Transaction + fee/%)
                 AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                          AND li.name ~* '(fee|fees|%)')
                 -- exclude bare tax rows
                 AND li.name !~* '^\s*tax\s*$')
       FROM jobs j
       WHERE j.id = v.job_id
         AND j.title IS NOT NULL AND TRIM(j.title) <> ''
         AND EXISTS (SELECT 1 FROM line_items li
                      WHERE li.invoice_id = v.invoice_id
                        AND li.name IS NOT NULL
                        AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                                 AND li.name ~* '(fee|fees|%)')
                        AND li.name !~* '^\s*tax\s*$')),
    -- Branch 2: invoice line items only (with fee filter)
    (SELECT string_agg(li.name, ', ' ORDER BY li.id)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id
         AND li.name IS NOT NULL
         AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                  AND li.name ~* '(fee|fees|%)')
         AND li.name !~* '^\s*tax\s*$'),
    -- Branch 3: parsed visit title
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), ''),
    -- Branch 4: job title only
    (SELECT NULLIF(TRIM(j.title), '') FROM jobs j WHERE j.id = v.job_id)
  ) AS line_items,
  -- line_items_json keeps EVERY line item including fees, for billing/audit
  COALESCE(
    (SELECT NULLIF(jsonb_agg(
              jsonb_build_object(
                'name', li.name,
                'quantity', li.quantity,
                'unit_price', li.unit_price,
                'total_price', li.total_price
              ) ORDER BY li.id), '[]'::jsonb)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id),
    '[]'::jsonb
  ) AS line_items_json,
  (SELECT g.gdo_number
     FROM gdos g
     WHERE g.client_id = c.id
       AND g.status = 'ACTIVE'
     ORDER BY g.id
     LIMIT 1) AS gdo_number,
  (SELECT j.job_number FROM jobs j WHERE j.id = v.job_id) AS job_number
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM properties p2
  WHERE p2.client_id = c.id
  ORDER BY
    p2.is_primary DESC NULLS LAST,
    (p2.is_billing IS NOT TRUE) DESC,
    p2.id
  LIMIT 1
) p ON true
WHERE v.visit_status = 'completed'::text;

COMMIT;

-- Verification — these visits had fees appended before, should be clean now:
--   SELECT id, line_items FROM derm.visits WHERE id IN (
--     SELECT mv.visit_id FROM manifest_visits mv -- proxy for active visits
--     LIMIT 0
--   ) OR client_id = (SELECT id FROM clients WHERE client_code='068-TCE')
--   AND visit_date >= '2026-05-17'
--   LIMIT 5;
--   Expected: no "ACH Fee", "CC Fees", "3.53%", "Tax" trailing the names.
