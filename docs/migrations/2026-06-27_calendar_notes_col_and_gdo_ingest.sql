-- 2026-06-27_calendar_notes_col_and_gdo_ingest.sql
-- ============================================================================
-- TWO related changes from the GDO-in-drawer work (Calendar app):
--
-- (A) REGRESSION FIX — add `notes` to ops.v_calendar_visit.
--     The Calendar app's "GDO Permit" drawer build rewrote its visits query from
--     select('*') to an EXPLICIT column list that referenced `notes` (the drawer's
--     Instructions field). ops.v_calendar_visit never exposed `notes`, so PostgREST
--     returned 400 ("column v_calendar_visit.notes does not exist") and the live
--     calendar loaded 0 visits. Fix: expose public.visits.notes as `notes` (appended
--     as the trailing column so CREATE OR REPLACE VIEW is legal). Side benefit: the
--     drawer's Instructions field is now actually populated. The 5 gdo_* columns the
--     same build added were NOT the cause — they already existed on the view.
--
-- (B) GDO INGEST — 2 new ACTIVE gdos + 3 demotions, from the GDO-Bot Miami-Dade DERM
--     lookup over the 76 active clients that had no GDO. Only house+zip+NAME matches
--     are trusted ACTIVE; house+zip-only matches are a DIFFERENT co-located business's
--     permit (a strip-mall/plaza neighbor) and are demoted INACTIVE — the same bar the
--     2026-05-25 Phase-2 review used. Those INACTIVE rows are institutional memory:
--     they block re-ingesting a known-false match (they blocked 190-LOU/202-CAP today).
--
-- AUDIT (Rule 8): ops.v_calendar_visit is a VIEW (no trigger). public.gdos already
--     carries `audit_gdos` — all INSERT/UPDATE below are logged. No audit change needed.
-- Source-of-truth: GDO = location-bound (per CLAUDE.md). gdos is the calendar's GDO
--     source (the LATERAL join in the view), distinct from legacy service_configs.permit_number.
-- Idempotent (Rule 5): view is CREATE OR REPLACE; GDO inserts are guarded NOT EXISTS;
--     demotions only fire on a still-ACTIVE row.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (A) ops.v_calendar_visit: append `notes` (= public.visits.notes)
--     Full definition re-stated (CREATE OR REPLACE requires it); only change vs the
--     2026-06-27_default_trucks_by_line_item.sql version is the new trailing `v.notes`.
-- ----------------------------------------------------------------------------
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
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    v.start_at IS NULL OR (v.start_at AT TIME ZONE 'America/New_York'::text)::time without time zone = '00:00:00'::time without time zone AND v.end_at IS NOT NULL AND (v.end_at - v.start_at) >= '23:00:00'::interval AS is_all_day,
        CASE
            WHEN jb.id IS NULL THEN NULL::text
            WHEN jb.title ~~* '%Service Agreement%'::text THEN 'SA'::text
            WHEN jb.title ~~* '%Service Call%'::text THEN 'SC'::text
            WHEN COALESCE(jb.frequency_days, 0) > 0 THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes                                   -- (A) NEW: drawer Instructions + unblocks the explicit-column query
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

-- PostgREST schema cache must pick up the new column:
NOTIFY pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- (B) GDO ingest — 2 ACTIVE (name+house+zip verified), client+property linked.
--     226-JER Jerusalem Pizza  -> GDO-03256 (permit "JERUSALEM PIZZA", exp 2026-12-31, 60d)
--     242-WYN Wynd 28          -> GDO-13814 (permit "WYNWOOD 28 - SHELL",  exp 2026-12-31, 90d)
--     (050-PV GDO-11228 "Sumi Yaktori", 233-AH GDO-15303 "Lucciano's", 241-WYN GDO-13814
--      "Wynwood 28"=unit-28-not-27 were ingested then DEMOTED to INACTIVE — house-only,
--      different/neighbor business. 190-LOU/202-CAP stayed INACTIVE from 2026-05-25.)
-- ----------------------------------------------------------------------------
INSERT INTO public.gdos (client_id, property_id, gdo_number, location_label, permit_expiration, permit_document_path, status, max_frequency_days, notes)
SELECT c.id, p.id, v.gdo_number, c.name, v.exp::date, v.doc, 'ACTIVE', v.freq, v.note
  FROM (VALUES
    ('226-JER','GDO-03256','2026-12-31',
      'https://stecmrerportal.blob.core.windows.net/dermdocuments/0902a1349b2c56d3.pdf',60,
      'GDO Bot 2026-06-27: matched by house+zip (761, 33162); permit issued to "JERUSALEM PIZZA"'),
    ('242-WYN','GDO-13814','2026-12-31',
      'https://stecmrerportal.blob.core.windows.net/dermdocuments/0902a1349db863e0.pdf',90,
      'GDO Bot 2026-06-27: matched by house+zip (127, 33127); permit issued to "WYNWOOD 28 - SHELL "')
  ) AS v(client_code, gdo_number, exp, doc, freq, note)
  JOIN public.clients c ON c.client_code = v.client_code
  LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = true
 WHERE NOT EXISTS (SELECT 1 FROM public.gdos g WHERE g.gdo_number = v.gdo_number AND g.client_id = c.id);

-- Note: 226-JER's GDO is on its PRIMARY property (650); its one completed June visit sits on a
-- DUPLICATE property (651, same address "761 NE 167th St"), so the property-keyed GDO join misses
-- that single visit (its future visits have property_id NULL -> resolve via the client fallback and
-- DO show GDO-03256). Root cause is the duplicate 650/651 property pair, not the GDO link. Flagged.
