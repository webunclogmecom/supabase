-- ============================================================================
-- fix_v2_view_status_strings.sql
-- ============================================================================
-- v2 schema uses uppercase status values (ACTIVE, INACTIVE, RECURRING).
-- Two views from v1 still referenced mixed-case 'Active' — zero rows returned.
-- ============================================================================

-- 1. clients_due_service: 'Active' → IN ('ACTIVE','RECURRING')
CREATE OR REPLACE VIEW public.clients_due_service AS
SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p.zone,
    s.service_type,
    s.last_visit,
    s.next_visit,
    s.frequency_days,
    s.next_visit - CURRENT_DATE AS days_until_due,
    CASE
        WHEN s.next_visit < CURRENT_DATE THEN 'OVERDUE'
        WHEN s.next_visit <= (CURRENT_DATE + 14) THEN 'DUE_SOON'
        ELSE 'OK'
    END AS due_status
FROM clients c
  JOIN service_configs s ON s.client_id = c.id
  LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
WHERE c.status IN ('ACTIVE', 'RECURRING')
  AND s.status IS DISTINCT FROM 'Paused'
  AND s.next_visit IS NOT NULL
ORDER BY s.next_visit;

-- 2. driver_inspection_status: 'Active' → 'ACTIVE'
CREATE OR REPLACE VIEW public.driver_inspection_status AS
SELECT e.id,
    e.full_name,
    max(CASE WHEN i.inspection_type = 'PRE' AND i.shift_date = CURRENT_DATE
             THEN i.submitted_at ELSE NULL::timestamp with time zone END) AS pre_submitted_at,
    max(CASE WHEN i.inspection_type = 'POST'
             THEN i.submitted_at ELSE NULL::timestamp with time zone END) AS post_submitted_at,
    count(CASE WHEN i.shift_date = CURRENT_DATE THEN 1 ELSE NULL::integer END) AS inspections_today,
    bool_or(CASE WHEN i.has_issue THEN true ELSE NULL::boolean END) AS has_open_issue
FROM employees e
  LEFT JOIN inspections i ON i.employee_id = e.id
    AND (i.shift_date = CURRENT_DATE
         OR (i.shift_date = (CURRENT_DATE - 1)
             AND i.inspection_type = 'POST'
             AND i.submitted_at >= CURRENT_DATE::timestamp with time zone))
WHERE e.status = 'ACTIVE'
GROUP BY e.id, e.full_name;
