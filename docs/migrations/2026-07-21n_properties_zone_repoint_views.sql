-- ============================================================================
-- 2026-07-21n - Collapse properties.zone -> zones.code (step 1: repoint views)
-- ============================================================================
-- FINDING (DB-wide sweep 2026-07-21, verified): public.properties.zone is a
-- byte-for-byte copy of zones.code reachable via the zone_id FK (247/247 exact,
-- 566/566 co-null, 0 mismatches). Redundant snapshot of a join-available value
-- (violates Rule 3). Fred green-lit the collapse (via the Building Apps session).
--
-- PLAN (staged, column drop LAST so nothing breaks mid-flight):
--   1. THIS migration: repoint the 11 views I own from properties.zone to
--      zones.code (LEFT JOIN public.zones on zone_id, expose z.code AS zone).
--   2. Building Apps session: rewrite ops.v_calendar_visit the same way + verify
--      the Visit Calendar app zone chip/sidebar do not regress (their lane).
--   3. 2026-07-21o (follow-up): once pg_depend shows ZERO views reference
--      properties.zone, DROP COLUMN public.properties.zone.
--
-- SAFETY: every rewrite below was gated by an inline data-equivalence check
-- (old view EXCEPT new + new EXCEPT old = 0 rows) AND by CREATE OR REPLACE VIEW
-- column-name enforcement, so each is provably output-identical to before. The
-- only change is HOW zone is sourced (z.code via zone_id instead of the copy).
-- Behaviour-neutral; no app change expected (apps read the same zone column).
-- ============================================================================

-- ops.properties
create or replace view ops.properties as
SELECT p.id, p.client_id, p.name, p.address, p.city, p.state, p.zip, p.country, p.is_billing, p.created_at, p.updated_at, z.code AS zone, p.latitude, p.longitude, p.geofence_radius_meters, p.geofence_type, p.access_hours_start, p.access_hours_end, p.access_days, p.is_primary, p.notes, p.county, p.grease_trap_manhole_count, p.access_notes, p.default_disposal_facility_id FROM public.properties p LEFT JOIN public.zones z ON z.id = p.zone_id;

-- ops.v_ar_aging
create or replace view ops.v_ar_aging as
 SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email AS primary_email,
    cc.phone AS primary_phone,
    i.id AS invoice_id,
    i.invoice_number,
    i.due_date,
    i.total,
    i.outstanding_amount AS balance_due,
    i.invoice_status,
    (CURRENT_DATE - i.due_date) AS days_overdue,
        CASE
            WHEN (i.outstanding_amount <= (0)::numeric) THEN 'paid'::text
            WHEN (i.due_date >= CURRENT_DATE) THEN 'current'::text
            WHEN (((CURRENT_DATE - i.due_date) >= 1) AND ((CURRENT_DATE - i.due_date) <= 30)) THEN '1-30_days'::text
            WHEN (((CURRENT_DATE - i.due_date) >= 31) AND ((CURRENT_DATE - i.due_date) <= 60)) THEN '31-60_days'::text
            WHEN (((CURRENT_DATE - i.due_date) >= 61) AND ((CURRENT_DATE - i.due_date) <= 90)) THEN '61-90_days'::text
            ELSE '90+_days'::text
        END AS aging_bucket
   FROM (((invoices i
     JOIN clients c ON ((c.id = i.client_id)))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE (i.outstanding_amount > (0)::numeric)
  ORDER BY p_z.code, (CURRENT_DATE - i.due_date) DESC NULLS LAST;

-- ops.v_derm_compliance
create or replace view ops.v_derm_compliance as
 WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE (((v.derm_required IS NULL) OR (v.derm_required = true)) AND (v.visit_status = 'completed'::text) AND (v.deleted_at IS NULL) AND (v.visit_date >= (CURRENT_DATE - '120 days'::interval)) AND (NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE ((dm.client_id = v.client_id) AND (dm.service_date = v.visit_date))))))
          GROUP BY v.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, (0)::bigint) AS missing_manifest_count,
        CASE
            WHEN (COALESCE(uv.missing_manifests, (0)::bigint) > 0) THEN true
            ELSE false
        END AS has_missing_manifests,
    (CURRENT_DATE - lm.last_manifest_date) AS days_since_last_manifest,
        CASE
            WHEN (lm.last_manifest_date IS NULL) THEN 'no_service_record'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 'overdue'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM (((((clients c
     JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = 'GT'::text))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN last_manifest lm ON ((lm.client_id = c.id)))
     LEFT JOIN unmatched_visits uv ON ((uv.client_id = c.id)))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 1
            WHEN (lm.last_manifest_date IS NULL) THEN 2
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 3
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 4
            ELSE 5
        END, COALESCE(uv.missing_manifests, (0)::bigint) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;

-- ops.v_gdo_expiry
create or replace view ops.v_gdo_expiry as
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    'GT'::text AS service_type,
    g.gdo_number AS permit_number,
    g.permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    (g.permit_expiration - CURRENT_DATE) AS days_until_expiry,
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 'no_permit'::text
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 'expired'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 'expiring_30d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 'expiring_60d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 'expiring_90d'::text
            ELSE 'valid'::text
        END AS permit_status
   FROM ((((gdos g
     JOIN clients c ON ((c.id = g.client_id)))
     LEFT JOIN properties p ON ((p.id = g.property_id)))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = 'GT'::text))))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE ((g.status = 'ACTIVE'::text) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])))
  ORDER BY
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 2
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 1
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 3
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 4
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 5
            ELSE 6
        END, (g.permit_expiration - CURRENT_DATE);

-- ops.v_revenue_summary
create or replace view ops.v_revenue_summary as
 SELECT (date_trunc('month'::text, (v.visit_date)::timestamp with time zone))::date AS month,
    v.service_type,
    p_z.code AS zone,
    veh.name AS truck,
    count(DISTINCT v.id) AS visit_count,
    count(DISTINCT v.client_id) AS client_count,
    sum(i.total) AS gross_revenue,
    sum(i.outstanding_amount) AS outstanding_ar,
    sum((i.total - i.outstanding_amount)) AS collected_revenue,
    round(((100.0 * sum((i.total - i.outstanding_amount))) / NULLIF(sum(i.total), (0)::numeric)), 1) AS collection_rate_pct
   FROM (((v_visits_live v
     JOIN invoices i ON ((i.id = v.invoice_id)))
     LEFT JOIN properties p ON ((p.id = v.property_id)))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE ((v.visit_status = 'completed'::text) AND (v.visit_date >= (CURRENT_DATE - '1 year'::interval)))
  GROUP BY (date_trunc('month'::text, (v.visit_date)::timestamp with time zone)), v.service_type, p_z.code, veh.name
  ORDER BY ((date_trunc('month'::text, (v.visit_date)::timestamp with time zone))::date) DESC, (sum(i.total)) DESC;

-- ops.v_route_today
create or replace view ops.v_route_today as
 SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    (v.visit_status = 'completed'::text) AS is_complete,
    v.is_gps_confirmed,
    c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    COALESCE(vp_z.code, pp_z.code) AS zone,
    COALESCE(vp.address, pp.address) AS address,
    COALESCE(vp.city, pp.city) AS city,
    COALESCE(vp.county, pp.county) AS county,
    COALESCE(vp.latitude, pp.latitude) AS latitude,
    COALESCE(vp.longitude, pp.longitude) AS longitude,
    COALESCE(vp.access_hours_start, pp.access_hours_start) AS access_hours_start,
    COALESCE(vp.access_hours_end, pp.access_hours_end) AS access_hours_end,
    cc.name AS contact_name,
    cc.phone AS contact_phone,
    sc.equipment_size_gallons,
    COALESCE(( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.property_id = v.property_id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1), ( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1)) AS permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM ((((((((v_visits_live v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties vp ON ((vp.id = v.property_id)))
     LEFT JOIN properties pp ON (((pp.client_id = c.id) AND (pp.is_primary = true))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = v.service_type))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN visit_assignments va ON ((va.visit_id = v.id)))
     LEFT JOIN employees e ON ((e.id = va.employee_id)))
   LEFT JOIN public.zones vp_z ON (vp_z.id = vp.zone_id) LEFT JOIN public.zones pp_z ON (pp_z.id = pp.zone_id) WHERE ((v.visit_date = CURRENT_DATE) AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text])))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp_z.code, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_hours_start, vp.access_hours_end, pp_z.code, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_hours_start, pp.access_hours_end, cc.name, cc.phone, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, COALESCE(vp_z.code, pp_z.code), c.name;

-- ops.v_service_due
create or replace view ops.v_service_due as
 WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM v_visits_live visits
          WHERE (visits.visit_status = 'completed'::text)
          GROUP BY visits.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    p.access_hours_start,
    p.access_hours_end,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.service_type,
    sc.frequency_days,
    sc.equipment_size_gallons,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    ((COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text))::interval))::date AS scheduled_next_visit,
    (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) AS days_since_service,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 'never_serviced'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 'overdue'::text
            WHEN (((COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days) - CURRENT_DATE) <= 14) THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM ((((clients c
     JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = ANY (ARRAY['GT'::text, 'CL'::text])))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN actual_last_visit alv ON ((alv.client_id = c.id)))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE ((c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND ((COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) OR ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 1
            ELSE 2
        END, p_z.code,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 1
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 2
            ELSE 3
        END, (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

-- public.client_services_flat
create or replace view public.client_services_flat as
 SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    c.status,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN s.equipment_size_gallons
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'GT'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN (s.service_type = 'CL'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'CL'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'CL'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'CL'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'CL'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN (s.service_type = 'WD'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'WD'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'WD'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'WD'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'WD'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status
   FROM ((clients c
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN service_configs s ON ((s.client_id = c.id)))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) GROUP BY c.id, p.address, p.city, p_z.code;

-- public.clients_due_service
create or replace view public.clients_due_service as
 SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    s.service_type,
    s.last_visit,
    ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date AS next_visit,
    s.frequency_days,
    (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date - CURRENT_DATE) AS days_until_due,
        CASE
            WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
            WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
            WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
            ELSE 'OK'::text
        END AS due_status
   FROM ((clients c
     JOIN service_configs s ON ((s.client_id = c.id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE ((c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND ((s.stop_date IS NULL) OR (s.stop_date > CURRENT_DATE)) AND (s.last_visit IS NOT NULL) AND (s.frequency_days IS NOT NULL))
  ORDER BY (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date);

-- public.visits_recent
create or replace view public.visits_recent as
 SELECT v.id,
    v.visit_date,
    v.service_type,
    c.name AS client_name,
    p.address,
    p_z.code AS zone,
    v.visit_status,
    v.is_gps_confirmed,
    v.actual_arrival_at,
    v.actual_departure_at,
    veh.name AS vehicle_name,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS assigned_to
   FROM (((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN visit_assignments va ON ((va.visit_id = v.id)))
     LEFT JOIN employees e ON ((e.id = va.employee_id)))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE (v.visit_date >= (CURRENT_DATE - 30))
  GROUP BY v.id, v.visit_date, v.service_type, c.name, p.address, p_z.code, v.visit_status, v.is_gps_confirmed, v.actual_arrival_at, v.actual_departure_at, veh.name
  ORDER BY v.visit_date DESC, v.start_at DESC;

-- public.visits_with_status
create or replace view public.visits_with_status as
 SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    (v.visit_status = 'completed'::text) AS is_complete,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    c.name AS client_name,
    p_z.code AS zone,
    veh.name AS vehicle_name,
    sc.frequency_days,
        CASE
            WHEN (v.visit_status = 'skipped'::text) THEN 'skipped'::text
            WHEN (v.visit_status = 'completed'::text) THEN 'completed'::text
            WHEN ((v.visit_date < CURRENT_DATE) AND (v.visit_status <> 'completed'::text)) THEN 'late'::text
            WHEN (v.visit_date = CURRENT_DATE) THEN 'today'::text
            ELSE 'upcoming'::text
        END AS computed_late_status
   FROM ((((visits v
     LEFT JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN service_configs sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
   LEFT JOIN public.zones p_z ON (p_z.id = p.zone_id) WHERE (v.deleted_at IS NULL);

