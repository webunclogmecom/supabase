-- Migration: 2026-06-29g_visit_sync_state
-- Author: Claude (Opus 4.8) for Fred
-- Audit: visits.sync_state is operational metadata; trigger-managed. visits already audited.
--
-- WHY (Calendar<->Jobber "no success unless Jobber confirms", per feedback_calendar_jobber_acid_writes):
-- The adversarial design audit REJECTED the synchronous saga (13 blocking issues: anon IDOR, double-push
-- from a GUC mismatch, verify-races-induce-drift, non-atomic compensation, 24-visit timeout). Pivoted to
-- this verify-and-compensate-LITE design that reuses the existing async push + drift watchdog:
--   1. visits.sync_state (pending|confirmed|failed), default confirmed.
--   2. BEFORE INSERT/UPDATE trigger trg_mark_visit_sync_pending sets pending whenever a Jobber-push-relevant
--      field changes (mirrors trg_push_visit_update WHEN cols) on a pushable source (visit-calendar/supabase_cron).
--   3. jobber-push-visit edge fn (DEPLOYED) flips it to confirmed on a clean push / settled no-op
--      (beyond-horizon DB-only / no-link delete), or failed on no-job-match / create error / throw.
--      A sync_state-only UPDATE never re-fires the push trigger (WHEN watches visit_date/start_at/title/..., not sync_state).
--   4. ops.v_calendar_visit exposes sync_state so the Calendar renders pending ("syncing") and only claims
--      success on confirmed. (Watchdog cadence sped up separately as the backstop.)
-- SMOKE-TESTED: write -> RETURNING sync_state=pending; ~2s later confirmed; a real move reflected in Jobber;
--   an unpushable (no-job) visit -> failed. Push confirms in ~2s.

ALTER TABLE public.visits ADD COLUMN IF NOT EXISTS sync_state text NOT NULL DEFAULT $q$confirmed$q$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname=$q$visits_sync_state_chk$q$) THEN
  ALTER TABLE public.visits ADD CONSTRAINT visits_sync_state_chk CHECK (sync_state IN ($q$pending$q$,$q$confirmed$q$,$q$failed$q$)); END IF; END $$;

CREATE OR REPLACE FUNCTION public.fn_mark_visit_sync_pending()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.source IN ($q$visit-calendar$q$,$q$supabase_cron$q$) THEN
    IF TG_OP = $q$INSERT$q$ THEN NEW.sync_state := $q$pending$q$;
    ELSIF (OLD.visit_date IS DISTINCT FROM NEW.visit_date OR OLD.start_at IS DISTINCT FROM NEW.start_at
        OR OLD.end_at IS DISTINCT FROM NEW.end_at OR OLD.title IS DISTINCT FROM NEW.title
        OR OLD.notes IS DISTINCT FROM NEW.notes OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at
        OR OLD.visit_status IS DISTINCT FROM NEW.visit_status OR OLD.team_rev IS DISTINCT FROM NEW.team_rev
        OR OLD.line_items_rev IS DISTINCT FROM NEW.line_items_rev) THEN NEW.sync_state := $q$pending$q$;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS trg_mark_visit_sync_pending ON public.visits;
CREATE TRIGGER trg_mark_visit_sync_pending BEFORE INSERT OR UPDATE ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.fn_mark_visit_sync_pending();

-- ops.v_calendar_visit re-created with v.sync_state appended (also see jobber-push-visit/index.ts edit):
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
    v.notes,
    v.sync_state
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
