-- ============================================================================
-- ops.v_route_today — Today's visit day-sheet with shift classification
-- ----------------------------------------------------------------------------
-- One row per visit scheduled for CURRENT_DATE.
-- Includes property address, client, service_type, assigned vehicle/crew,
-- and shift classification (overnight: David/Goliath/Moises; daytime: Cloggy).
-- Crew is aggregated from visit_assignments as a comma-separated string.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_route_today AS
WITH crew AS (
  SELECT va.visit_id,
         STRING_AGG(e.full_name, ', ' ORDER BY e.full_name) AS crew_names,
         COUNT(*) AS crew_size
  FROM public.visit_assignments va
  JOIN public.employees e ON e.id = va.employee_id
  GROUP BY va.visit_id
)
SELECT
  v.id                       AS visit_id,
  v.visit_date,
  v.start_at,
  v.end_at,
  v.visit_status,
  v.service_type,
  v.title,
  c.id                       AS client_id,
  c.name                     AS client_name,
  c.client_code,
  c.phone                    AS client_phone,
  c.operation_phone,
  p.name                     AS property_name,
  p.street,
  p.city,
  p.state,
  p.postal_code,
  veh.id                     AS vehicle_id,
  veh.name                   AS vehicle_name,
  veh.short_code             AS vehicle_short_code,
  veh.tank_capacity_gallons,
  CASE
    WHEN veh.name IN ('David','Goliath','Moises') THEN 'overnight'
    WHEN veh.name = 'Cloggy'                      THEN 'daytime'
    ELSE                                               'unassigned'
  END                        AS shift,
  crew.crew_names,
  crew.crew_size,
  (SELECT MAX(updated_at) FROM public.visits) AS data_as_of
FROM public.visits v
LEFT JOIN public.clients    c   ON c.id   = v.client_id
LEFT JOIN public.properties p   ON p.id   = v.property_id
LEFT JOIN public.vehicles   veh ON veh.id = v.vehicle_id
LEFT JOIN crew              crew ON crew.visit_id = v.id
WHERE v.visit_date = CURRENT_DATE
ORDER BY shift, v.start_at NULLS LAST, veh.name;

COMMENT ON VIEW ops.v_route_today IS
  'Driver day-sheet: all visits scheduled for CURRENT_DATE with client, property, vehicle, crew, and shift (overnight/daytime/unassigned).';
