-- ============================================================================
-- Migration: 2026-06-24_visit_assigned_driver.sql
-- Purpose: Let the Calendar "New Visit" form assign a PLANNED driver alongside the
--          truck. Visits already store vehicle_id (truck) but no driver; the driver
--          shown in ops.v_calendar_visit is the ACTUAL driver derived from
--          visit_assignments (Samsara attribution), which only exists once a visit is
--          driven (completed). This adds a planned/assigned driver set at creation.
-- Model:   public.visits.assigned_driver_id (planned, nullable, FK employees). The
--          view exposes driver_id = COALESCE(actual-from-attribution, assigned), so
--          completed visits keep their real GPS-derived driver and scheduled visits
--          show the assigned one. Separate concepts, both authoritative for their phase.
-- Note:    This softens the older "trucks-only, never a person" rule (Building Apps
--          CLAUDE.md #4) — but person-level driver was already tracked via
--          visit_assignments/v_calendar_visit.driver_id; this just adds the PLANNED side.
-- Audit:   visits is already audited (ADR 010) — new column auto-captured, no trigger edit.
-- 3NF:     assigned_driver_id depends only on the visit PK; FK to employees.
-- Idempotent: ADD COLUMN IF NOT EXISTS; constraint/index via guards; DROP/CREATE fns;
--             CREATE OR REPLACE VIEW (driver_* expressions change, trailing cols added).
-- Back-compat: existing rpc('create_calendar_visit', {11 named args}) still resolves —
--              the new p_driver_id defaults NULL.
-- ============================================================================
BEGIN;

-- 1) planned-driver column ---------------------------------------------------
ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS assigned_driver_id bigint;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'visits_assigned_driver_id_fkey') THEN
    ALTER TABLE public.visits
      ADD CONSTRAINT visits_assigned_driver_id_fkey
      FOREIGN KEY (assigned_driver_id) REFERENCES public.employees(id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS visits_assigned_driver_id_idx ON public.visits (assigned_driver_id);

-- 2) RPC: add p_driver_id (signature changes -> drop+recreate; ops wrapper first) -------
DROP FUNCTION IF EXISTS ops.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint);
DROP FUNCTION IF EXISTS public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint);

CREATE FUNCTION public.create_calendar_visit(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date,
  p_property_id bigint DEFAULT NULL, p_client_location_ids bigint[] DEFAULT NULL,
  p_start_at timestamptz DEFAULT NULL, p_end_at timestamptz DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL, p_vehicle_id bigint DEFAULT NULL,
  p_driver_id bigint DEFAULT NULL
) RETURNS public.visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_primary      bigint;
  v_service_type text;
  v_derm         boolean;
  v_property     bigint;
  v_visit        public.visits;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_primary := p_service_line_item_ids[1];
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = v_primary;
  SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(
    p_property_id,
    (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1)
  );

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes,
                      visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, p_driver_id, p_visit_date, p_start_at, p_end_at,
          p_title, v_service_type, v_primary, COALESCE(v_derm, false), p_notes,
          'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title, '', 1, 0, 0, false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id
    LIMIT 1
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_visit;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint)
  TO anon, authenticated, service_role;

CREATE FUNCTION ops.create_calendar_visit(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date,
  p_property_id bigint DEFAULT NULL, p_client_location_ids bigint[] DEFAULT NULL,
  p_start_at timestamptz DEFAULT NULL, p_end_at timestamptz DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL, p_vehicle_id bigint DEFAULT NULL,
  p_driver_id bigint DEFAULT NULL
) RETURNS public.visits LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.create_calendar_visit(p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
    p_property_id, p_client_location_ids, p_start_at, p_end_at, p_title, p_notes, p_vehicle_id, p_driver_id);
$$;

GRANT EXECUTE ON FUNCTION ops.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint)
  TO anon, authenticated, service_role;

-- 3) view: driver = COALESCE(actual, assigned) + expose assigned_driver_* -----
CREATE OR REPLACE VIEW ops.v_calendar_visit AS
 WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND prev.visit_status = 'completed'::text AND prev.visit_date < v_1.visit_date) AS last_completed_date
           FROM visits v_1
        ), first_assignment AS (
         SELECT DISTINCT ON (va.visit_id) va.visit_id,
            va.employee_id
           FROM visit_assignments va
          ORDER BY va.visit_id, va.employee_id
        ), observed_cadence AS (
         SELECT gaps.client_id,
            gaps.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.days_since_prev::double precision))::integer AS median_gap_days
           FROM ( SELECT visits.client_id,
                    visits.service_type,
                    visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.client_id, visits.service_type ORDER BY visits.visit_date) AS days_since_prev
                   FROM visits
                  WHERE visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text]))) gaps
          WHERE gaps.days_since_prev >= 5 AND gaps.days_since_prev <= 200
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (li.total_price::double precision))::numeric(12,2) AS median_line_price
           FROM visits v_1
             JOIN line_items li ON li.invoice_id = v_1.invoice_id
          WHERE v_1.invoice_id IS NOT NULL AND v_1.visit_status = 'completed'::text AND (v_1.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text])) AND li.total_price > 0::numeric
          GROUP BY v_1.client_id, v_1.service_type
        )
 SELECT v.id,
    v.public_id,
    v.client_id,
    v.property_id,
    v.vehicle_id,
    v.job_id,
    v.visit_date,
    v.visit_status,
    v.service_type,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    c.group_id AS client_group_id,
    COALESCE(prop.zone, primary_prop.zone) AS zone,
    COALESCE(prop.address, primary_prop.address) AS address,
    COALESCE(prop.city, primary_prop.city) AS city,
    COALESCE(prop.state, primary_prop.state) AS state,
    COALESCE(prop.zip, primary_prop.zip) AS zip,
    COALESCE(prop.county, primary_prop.county) AS county,
    COALESCE(prop.access_hours_start, primary_prop.access_hours_start) AS access_hours_start,
    COALESCE(prop.access_hours_end, primary_prop.access_hours_end) AS access_hours_end,
    COALESCE(prop.access_days, primary_prop.access_days) AS access_days,
    COALESCE(prop.latitude, primary_prop.latitude) AS latitude,
    COALESCE(prop.longitude, primary_prop.longitude) AS longitude,
    COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,
    COALESCE(sc.frequency_days, oc.median_gap_days) AS frequency_days,
    sc.equipment_size_gallons,
    sc.first_visit AS sc_first_visit,
    sc.last_visit AS sc_last_visit,
    sc.stop_date AS sc_stop_date,
    sc.material_type,
    g.gdo_number,
    g.permit_expiration AS gdo_expiration,
    g.max_frequency_days AS gdo_max_frequency_days,
    g.permit_document_path AS gdo_document_path,
    g.status AS gdo_status,
    veh.name AS truck_name,
    veh.status AS vehicle_status,
    veh.grease_tank_capacity_gallons,
    veh.fuel_tank_capacity_gallons,
    COALESCE(emp.id, asg.id) AS driver_id,
    COALESCE(emp.full_name, asg.full_name) AS driver_name,
    COALESCE(emp.role, asg.role) AS driver_role,
        CASE
            WHEN v.visit_status = 'completed'::text THEN NULL::text
            WHEN lc.last_completed_date IS NULL THEN NULL::text
            WHEN COALESCE(sc.frequency_days, oc.median_gap_days) IS NULL THEN NULL::text
            WHEN (lc.last_completed_date + COALESCE(sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < CURRENT_DATE THEN 'late'::text
            WHEN (lc.last_completed_date + COALESCE(sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < v.visit_date THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN properties primary_prop ON primary_prop.client_id = v.client_id AND primary_prop.is_primary = true
     LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
     LEFT JOIN LATERAL ( SELECT g0.gdo_number,
            g0.permit_expiration,
            g0.max_frequency_days,
            g0.permit_document_path,
            g0.status
           FROM gdos g0
          WHERE g0.status = 'ACTIVE'::text AND (v.property_id IS NOT NULL AND g0.property_id = v.property_id OR v.property_id IS NULL AND g0.client_id = v.client_id)
          ORDER BY g0.id
         LIMIT 1) g ON true
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN first_assignment fa ON fa.visit_id = v.id
     LEFT JOIN employees emp ON emp.id = fa.employee_id
     LEFT JOIN employees asg ON asg.id = v.assigned_driver_id
     LEFT JOIN last_completed lc ON lc.visit_id = v.id
     LEFT JOIN observed_cadence oc ON oc.client_id = v.client_id AND oc.service_type = v.service_type
     LEFT JOIN observed_price op ON op.client_id = v.client_id AND op.service_type = v.service_type
  WHERE v.deleted_at IS NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
