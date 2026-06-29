-- Migration: 2026-06-29d_calendar_view_service_kind_frequency_based
-- Author: Claude (Opus 4.8) for Fred
-- Audit: N/A (view). Read-only derivation; no data mutation.
--
-- WHY (Fred-confirmed rule): SA = on a recurring agreement, SC = one-off/emergency.
--   The signal is FREQUENCY, not job title or line-item codes. service_kind is a
--   VIEW-COMPUTED column (NOT stored on public.visits -> nothing to backfill, no
--   writer to fix; visit-gen/handleVisit never set it). This SUPERSEDES the
--   line-item-code tiebreaker from 2026-06-29_calendar_view_servicekind_frequency.sql.
--
-- RULE: service_kind = CASE WHEN COALESCE(NULLIF(jb.frequency_days,0), sc.frequency_days,
--         oc.median_gap_days) > 0 THEN SA ELSE SC END  -- i.e. the SAME frequency the
--       view displays as frequency_days. Title regex + code tiebreaker REMOVED.
--
-- WHY the view frequency (job -> service_config -> observed median), NOT jobs.frequency_days
-- alone: the ~562 mislabeled visits have jobs.frequency_days = 0/null (the JOBS-poll sync
-- gap -- it never fetches the Frequency customField; see reference_jobs_sync_gaps) yet are
-- genuinely recurring (sc/median cadence > 0). Using jobs.frequency_days alone flips 0 of
-- them (and regresses 26 SA->SC); using the displayed frequency flips the 559 correctly.
-- ROOT CAUSE remains the jobs.frequency_days sync gap -- a separate, larger fix; this view
-- rule is the pragmatic correction Fred asked for.
--
-- IMPACT (verified, all visits): SA 733->1289, SC 692->137, nulls 1->0. Completed:
--   SA 54->606, SC 682->131. 559 SC->SA (recurring), 133 true one-offs stay SC, 4 SA->SC
--   (line-item-SA but zero recurrence signal). 63 columns unchanged, 0 dependent views.
--
-- The Visit Calendar app already derives SA/SC from frequency_days client-side (interim);
-- now the backend service_kind matches, so that workaround is redundant (harmless).
-- NOT changed here: ops.v_calendar_visit_detail.service_kind (a separate title-based
-- service_agreement/service_call field feeding the drawer; lacks the sc/median join;
-- effectively superseded by the app client-side derivation).

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
    effv.vehicle_id,
    v.job_id,
    v.visit_date,
    v.visit_status,
    v.service_type,
    v.start_at,
    v.end_at,
    v.completed_at,
    COALESCE(v.duration_minutes, (EXTRACT(epoch FROM v.end_at - v.start_at) / 60::numeric)::integer) AS duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    COALESCE(( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE li.visit_id = v.id), ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL))::numeric(12,2) AS amount,
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
    COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) AS frequency_days,
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
            WHEN COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) IS NULL THEN NULL::text
            WHEN (lc.last_completed_date + COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < CURRENT_DATE THEN 'late'::text
            WHEN (lc.last_completed_date + COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < v.visit_date THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    v.start_at IS NULL OR (v.start_at AT TIME ZONE 'America/New_York'::text)::time without time zone = '00:00:00'::time without time zone AND v.end_at IS NOT NULL AND (v.end_at - v.start_at) >= '23:00:00'::interval AS is_all_day,
        CASE
            WHEN COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) > 0 THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes
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
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.visit_id = v.id), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL)) AS vehicle_id) effv ON true
     LEFT JOIN vehicles veh ON veh.id = effv.vehicle_id
     LEFT JOIN first_assignment fa ON fa.visit_id = v.id
     LEFT JOIN employees emp ON emp.id = fa.employee_id
     LEFT JOIN employees asg ON asg.id = v.assigned_driver_id
     LEFT JOIN last_completed lc ON lc.visit_id = v.id
     LEFT JOIN observed_cadence oc ON oc.client_id = v.client_id AND oc.service_type = v.service_type
     LEFT JOIN observed_price op ON op.client_id = v.client_id AND op.service_type = v.service_type
     LEFT JOIN jobs jb ON jb.id = v.job_id
  WHERE v.deleted_at IS NULL;
