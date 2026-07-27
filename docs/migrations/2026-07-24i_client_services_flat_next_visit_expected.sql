-- 2026-07-24i — client_services_flat.next_visit_expected (canonical, reused)
-- Adds next_visit_expected = the "supposed-to-be" date of the client's next visit,
-- REUSING ops.v_calendar_visit.expected_date directly (prev-live + COALESCE(NULLIF(
-- jobs.frequency_days,0), service_configs.frequency_days); 000-% NULL; no observed
-- cadence) — NOT re-derived (never re-derive the expected-date formula: Calendar
-- tooltip + late chips must agree). = MIN(expected_date) over the client's upcoming
-- scheduled visits (earliest across service types). NULL for clients w/ no upcoming
-- scheduled visit (correct). Replaces the naive/stale gt/cl/wd_next_visit for the
-- Client App list "supposed-to-be" tooltip. Perf: one eval of v_calendar_visit,
-- ~+200ms on the list (~1.1s total). Additive; client wrapper appends the column.
-- Fred-approved via BA 2026-07-24.

begin;
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
            WHEN s.service_type = 'GT'::text THEN s.equipment_size_gallons
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN s.service_type = 'GT'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'GT'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'GT'::text THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN s.service_type = 'GT'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN s.service_type = 'GT'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN s.service_type = 'CL'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'CL'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'CL'::text THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN s.service_type = 'CL'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN s.service_type = 'CL'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN s.service_type = 'WD'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'WD'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'WD'::text THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN s.service_type = 'WD'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN s.service_type = 'WD'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status,
    max(nve.nve) AS next_visit_expected
   FROM clients c
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN service_configs s ON s.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
     LEFT JOIN ( SELECT client_id, min(expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE visit_status = 'scheduled' AND visit_date >= CURRENT_DATE AND expected_date IS NOT NULL
          GROUP BY client_id) nve ON nve.client_id = c.id
  GROUP BY c.id, p.address, p.city, p_z.code;

create or replace view client.client_services_flat as
  select id, name, client_code, address, city, zone, status,
         gt_size_gallons, gt_frequency_days, gt_price_per_visit, gt_last_visit, gt_next_visit, gt_status,
         cl_frequency_days, cl_price_per_visit, cl_last_visit, cl_next_visit, cl_status,
         wd_frequency_days, wd_price_per_visit, wd_last_visit, wd_next_visit, wd_status,
         next_visit_expected
    from public.client_services_flat;
commit;
