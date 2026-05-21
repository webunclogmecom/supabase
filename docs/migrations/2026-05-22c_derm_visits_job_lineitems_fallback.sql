-- 2026-05-22c_derm_visits_job_lineitems_fallback.sql
--
-- Re-add the job-level line_items fallback, NOW that we backfill jobs.lineItems
-- fresh from Jobber via backfill_job_line_items_from_jobber.js. The earlier
-- 2026-05-21d concern (job_id fallback mixing in stale historical invoice
-- items) doesn't apply when the line_items table is curated: job-level rows
-- come from Jobber's job.lineItems (planned items for this job), not from
-- aggregated invoice history.
--
-- For Casa Neos job 132 (the recurring "Service call" case) — the original
-- 5 stale items got their line_items rows previously, but going forward
-- the backfill script keys on job_id and uses delete-then-insert per job,
-- so each pull replaces stale data with current Jobber state.
--
-- New priority:
--   1. {job.title} - {invoice line items}   (most accurate, when invoiced)
--   2. {invoice line items}                  (no job title)
--   3. {job.title} - {job line items}        (NEW — uses backfilled jobs.lineItems)
--   4. {job line items}                       (NEW — fallback without job title)
--   5. {visit.title parsed}                  (specific visit description)
--   6. {job.title}                            (last resort)
--
-- All branches still apply the payment-fee filter from 2026-05-22b.
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
    -- Branch 1: {job.title} - {invoice line items, fee-filtered}
    (SELECT NULLIF(TRIM(j.title), '') || ' - ' ||
            (SELECT string_agg(li.name, ', ' ORDER BY li.id)
               FROM line_items li
               WHERE li.invoice_id = v.invoice_id
                 AND li.name IS NOT NULL
                 AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                          AND li.name ~* '(fee|fees|%)')
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
    -- Branch 2: {invoice line items only}
    (SELECT string_agg(li.name, ', ' ORDER BY li.id)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id
         AND li.name IS NOT NULL
         AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                  AND li.name ~* '(fee|fees|%)')
         AND li.name !~* '^\s*tax\s*$'),
    -- Branch 3 (NEW): {job.title} - {job-level line items, fee-filtered}
    (SELECT NULLIF(TRIM(j.title), '') || ' - ' ||
            (SELECT string_agg(li.name, ', ' ORDER BY li.id)
               FROM line_items li
               WHERE li.job_id = v.job_id
                 AND li.invoice_id IS NULL  -- only job-direct, not invoiced
                 AND li.name IS NOT NULL
                 AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                          AND li.name ~* '(fee|fees|%)')
                 AND li.name !~* '^\s*tax\s*$')
       FROM jobs j
       WHERE j.id = v.job_id
         AND j.title IS NOT NULL AND TRIM(j.title) <> ''
         AND EXISTS (SELECT 1 FROM line_items li
                      WHERE li.job_id = v.job_id
                        AND li.invoice_id IS NULL
                        AND li.name IS NOT NULL
                        AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                                 AND li.name ~* '(fee|fees|%)')
                        AND li.name !~* '^\s*tax\s*$')),
    -- Branch 4 (NEW): {job line items only}
    (SELECT string_agg(li.name, ', ' ORDER BY li.id)
       FROM line_items li
       WHERE li.job_id = v.job_id
         AND li.invoice_id IS NULL
         AND li.name IS NOT NULL
         AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'
                  AND li.name ~* '(fee|fees|%)')
         AND li.name !~* '^\s*tax\s*$'),
    -- Branch 5: {visit.title parsed}
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), ''),
    -- Branch 6: {job.title}
    (SELECT NULLIF(TRIM(j.title), '') FROM jobs j WHERE j.id = v.job_id)
  ) AS line_items,
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
    (SELECT NULLIF(jsonb_agg(
              jsonb_build_object(
                'name', li.name,
                'quantity', li.quantity,
                'unit_price', li.unit_price,
                'total_price', li.total_price
              ) ORDER BY li.id), '[]'::jsonb)
       FROM line_items li
       WHERE li.job_id = v.job_id AND li.invoice_id IS NULL),
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
