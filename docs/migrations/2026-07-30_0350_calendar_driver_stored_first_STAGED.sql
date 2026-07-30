-- 2026-07-30_0350  calendar driver: STORED first, derived fallback — ⛔ STAGED, DO NOT APPLY
--
-- ⛔⛔ NOT APPLIED. Prepared on Fred's instruction ("prepare the migration without applying it").
--
-- ⛔⛔⛔ GATE 1 IS NOW ANSWERED, AND THE ANSWER RECOMMENDS **AGAINST** APPLYING THIS FILE AS-IS.
-- @Building Apps measured (2026-07-30, live bundle + live function bodies, each claim re-verified
-- here against Prod before recording it):
--   * The drawer CANNOT create the crew-vs-stored divergence this file was designed for. Both edit
--     RPCs CO-WRITE the pair: edit_calendar_visit's team branch runs
--     `assigned_driver_id = NULLIF(p_patch->'team_ids'->>0,'')::bigint` in the same statement that
--     replaces the crew, and create_calendar_visit sets `COALESCE(p_team_ids[1], p_driver_id)`.
--     The deployed Calendar bundle passes `p_driver_id: null` HARDCODED. Only raw `sql` writes can
--     desync the pair.
--   * The app-reachable divergence class is INVERTED from the premise: the drawer writes
--     `visit_team`, but the view's derived driver reads `visit_assignments` (`visit_team` appears
--     ZERO times in the view body — verified). So a team edit on a visit carrying a
--     visit_assignments row updates the STORED driver while the view keeps showing the OLD derived
--     person. Coverage: 940/945 completed and 32/703 scheduled visits carry a va row; divergent
--     today: 0 (rarity — 22 team edits ever — not protection).
--   * 🛑 THE BLANKET FLIP CONTRADICTS A DOCUMENTED RULE. Building Apps CLAUDE.md rule #4
--     (2026-06-24): actual driver of a COMPLETED visit is derived from Samsara GPS attribution,
--     "driver_id = COALESCE(actual, assigned)", derived-first DELIBERATE — GPS truth beats plan,
--     per the trust hierarchy (Samsara = 100%). Applying this file would make any future completed
--     visit where GPS ≠ plan display the PLAN. "0 rows change today" is true of BOTH orders and
--     decides nothing.
--
-- ⇒ IF THE DRAWER'S EDIT SHOULD WIN ANYWHERE, THE DEFENSIBLE SHAPE IS **STATUS-SCOPED**, NOT THIS
--   FILE: stored-first for `scheduled` (a human's plan should beat a stray va row; only 32
--   scheduled visits even have one), derived-first for `completed` (GPS is truth). Also 0 rows
--   change today. The 4-site machinery below (3 COALESCEs + the driver_color CASE) carries over
--   directly into that variant.
--
-- ⇒ REMAINING GATE: FRED, with the rule-#4 conflict in front of him. Do not apply this file, and do
--   not write the status-scoped variant, until he picks. This file is kept because its body is the
--   proven mechanical edit and its test protocol transfers to whichever variant is chosen.
--
-- The `_STAGED` suffix follows docs/migrations/NAMING.md (suffix, never prefix — a prefix breaks date
-- sorting and is exactly how STAGED_2026-06-15c ended up sorting under "S").
--
-- WHAT THIS CHANGES. ops.v_calendar_visit's driver quartet currently prefers the DERIVED driver over
-- the explicitly STORED one:
--     COALESCE(emp.id, asg.id)                    -- emp = derived (fa), asg = v.assigned_driver_id
--     COALESCE(emp.full_name, asg.full_name)
--     COALESCE(emp.role, asg.role)
--     CASE WHEN emp.id IS NOT NULL THEN emp.color_hex ELSE asg.color_hex END
-- So if the derived driver (active crew -> any crew -> whoever inspected the stored truck ±1 day)
-- ever resolves to a DIFFERENT person than assigned_driver_id, every Calendar surface shows the
-- derived one and hides the explicit assignment. This file flips all FOUR sites to stored-first.
-- ⚠ FOUR sites, not three: driver_color is a CASE, not a COALESCE, and missing it would ship a view
-- where the name follows the stored driver while the color follows the derived one.
--
-- MEASURED BLAST RADIUS (2026-07-30, all against Prod):
--   * Rows where reversal changes the display TODAY: 0 of 1,652 live visits. Derived and stored
--     currently never disagree. This is a LATENT-behaviour change, not a visible one.
--     ⚠ Do NOT read that 0 as an invariant (reference_clean_data_is_not_proof_of_an_invariant):
--     nothing enforces the agreement; a crew edit that disagreed would silently win today.
--   * The 728 rows where the view shows a driver and the column is NULL are UNAFFECTED: stored-first
--     COALESCE still falls back to derived when stored is NULL. The fallback is kept on purpose.
--   * Same COALESCE exists NOWHERE else (repo + catalog swept: 1 site).
--   * DB dependents: public.client_services_flat (does not read driver columns — verified).
--   * ⚠ REAL DEPENDENT: pg_cron `dump-driver-truck-refresh` (jobid 12, */5) materialises
--     cv.driver_id × cv.vehicle_id into public.dump_driver_truck, which feeds dump_driver_origin ->
--     the DUMP app's ETA origin. With 0 divergent rows its output is unchanged today; if divergence
--     ever exists, the ETA map would follow the STORED driver after this change. That is the intended
--     semantics (an explicit assignment should win everywhere), but it is a dependency, not nothing.
--
-- PROOF, run before staging (constructed case, single transaction, ROLLED BACK, zero residue —
-- verified zero new audit rows after):
--   * On visit 7318 (crew = Grecia via visit_assignments, stored assigned_driver_id set to Mark
--     inside the txn): LIVE view showed **Grecia** (derived wins, hiding the explicit assignment);
--     a TEMP view with THIS definition showed **Mark**. That is the entire point of the change,
--     demonstrated rather than argued.
--   * Board-wide with the constructed row in place: driver diffs = 1 (only the constructed row),
--     color diffs = 1 (same row — the CASE follows), truck diffs = 0 (truck chain untouched).
--
-- HOW THIS FILE WAS PRODUCED. Live definition fetched via pg_get_viewdef and edited by script with
-- anchors asserted first (each of the four sites matched EXACTLY once; 0 derived-first sites remain
-- after). Every byte except the four documented edits is unchanged from what is running.
-- CREATE OR REPLACE VIEW is legal here: same columns, same names, same order, same types.
--
-- ⚠ ON APPLYING: grants are preserved by CREATE OR REPLACE VIEW, but re-verify the §"Grants, views
-- and functions" post-conditions anyway, and re-run the board-wide diff (expect 0). Then re-check
-- dump_driver_truck's next */5 refresh via net-effect (row count + pairs unchanged).
-- ⚠ ROLLBACK: re-apply the previous definition (git holds it; it is also exactly this file with the
-- four sites swapped back). No data is touched either way — this is a read-path change only.
--
-- RULE 8 (ADR 010): no table or column change; view redefinition only.

CREATE OR REPLACE VIEW ops.v_calendar_visit AS
 WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = 'completed'::text) AND (prev.visit_date < v_1.visit_date))) AS last_completed_date
           FROM visits v_1
        ), prev_live AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date))) AS prev_live_date
           FROM visits v_1
        ), observed_cadence AS (
         SELECT gaps.client_id,
            gaps.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.client_id,
                    visits.service_type,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.client_id, visits.service_type ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((li.total_price)::double precision)))::numeric(12,2) AS median_line_price
           FROM (visits v_1
             JOIN line_items li ON ((li.invoice_id = v_1.invoice_id)))
          WHERE ((v_1.invoice_id IS NOT NULL) AND (v_1.visit_status = 'completed'::text) AND (v_1.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text])) AND (li.total_price > (0)::numeric))
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.job_id
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
    COALESCE(v.duration_minutes, ((EXTRACT(epoch FROM (v.end_at - v.start_at)) / (60)::numeric))::integer) AS duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    (COALESCE(NULLIF(( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id)), (0)::numeric),
        CASE
            WHEN ((v.invoice_id IS NOT NULL) AND (( SELECT count(*) AS count
               FROM visits v2
              WHERE ((v2.invoice_id = v.invoice_id) AND (v2.deleted_at IS NULL))) = 1)) THEN ( SELECT sum(li.total_price) AS sum
               FROM line_items li
              WHERE (li.invoice_id = v.invoice_id))
            ELSE NULL::numeric
        END, ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))), ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id))))::numeric(12,2) AS amount,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    c.group_id AS client_group_id,
    COALESCE(pz.code, ppz.code) AS zone,
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
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULLIF(jb.frequency_days, 0)
            ELSE COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)
        END AS frequency_days,
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
    COALESCE(asg.id, emp.id) AS driver_id,
    COALESCE(asg.full_name, emp.full_name) AS driver_name,
    COALESCE(asg.role, emp.role) AS driver_role,
        CASE
            WHEN (v.visit_status = 'skipped'::text) THEN NULL::text
            WHEN (v.visit_status = 'completed'::text) THEN NULL::text
            WHEN (pl.prev_live_date IS NULL) THEN NULL::text
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) IS NULL) THEN NULL::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < CURRENT_DATE) THEN 'late'::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < v.visit_date) THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    ((v.start_at IS NULL) OR ((((v.start_at AT TIME ZONE 'America/New_York'::text))::time without time zone = '00:00:00'::time without time zone) AND (v.end_at IS NOT NULL) AND ((v.end_at - v.start_at) >= '23:00:00'::interval))) AS is_all_day,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN 'SC'::text
            WHEN (NULLIF(jb.frequency_days, 0) > 0) THEN 'SA'::text
            WHEN ((lower(jb.title) ~~ '%service call%'::text) OR (lower(jb.title) ~~ '%emergency%'::text)) THEN 'SC'::text
            WHEN ((ojc.median_gap_days > 0) OR (lower(jb.title) ~~ '%grease%'::text) OR (lower(jb.title) ~~ '%grey water%'::text) OR (lower(jb.title) ~~ '%service agreement%'::text)) THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes,
    v.sync_state,
    v.skip_reason,
    sagrp.sa_group,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULL::date
            WHEN (pl.prev_live_date IS NULL) THEN NULL::date
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days) IS NULL) THEN NULL::date
            ELSE ((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days))::double precision * '1 day'::interval)))::date
        END AS expected_date,
        CASE
            WHEN (asg.id IS NOT NULL) THEN asg.color_hex
            ELSE emp.color_hex
        END AS driver_color,
    COALESCE(( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_kind IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE (li.visit_id = v.id)), ( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_kind IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))),
        CASE
            WHEN (v.derm_required IS TRUE) THEN 'Pumping'::text
            ELSE NULL::text
        END) AS service_label,
    v.vehicle_id AS assigned_vehicle_id,
        CASE
            WHEN (v.vehicle_id IS NOT NULL) THEN 'assigned'::text
            WHEN (effv.vehicle_id IS NOT NULL) THEN 'default'::text
            ELSE 'none'::text
        END AS vehicle_source
   FROM ((((((((((((((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN properties primary_prop ON (((primary_prop.client_id = v.client_id) AND (primary_prop.is_primary = true))))
     LEFT JOIN zones pz ON ((pz.id = prop.zone_id)))
     LEFT JOIN zones ppz ON ((ppz.id = primary_prop.zone_id)))
     LEFT JOIN service_configs sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_id(v.client_id, v.property_id, v.id) AS gdo_id) r ON (true))
     LEFT JOIN gdos g ON ((g.id = r.gdo_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE (li2.visit_id = v.id)), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li2.job_id = v.job_id) AND (li2.visit_id IS NULL) AND (li2.invoice_id IS NULL)))) AS vehicle_id) effv ON (true))
     LEFT JOIN vehicles veh ON ((veh.id = effv.vehicle_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT min(e.id) AS min
                   FROM (visit_assignments va
                     JOIN employees e ON ((e.id = va.employee_id)))
                  WHERE ((va.visit_id = v.id) AND (e.status = 'ACTIVE'::text))), ( SELECT min(va.employee_id) AS min
                   FROM visit_assignments va
                  WHERE (va.visit_id = v.id)), ( SELECT e.id
                   FROM (inspections i
                     JOIN employees e ON ((e.id = i.employee_id)))
                  WHERE ((i.vehicle_id = v.vehicle_id) AND (i.shift_date >= (v.visit_date - 1)) AND (i.shift_date <= (v.visit_date + 1)))
                  ORDER BY (i.shift_date = v.visit_date) DESC, (e.status = 'ACTIVE'::text) DESC, (abs((i.shift_date - v.visit_date))), e.id
                 LIMIT 1)) AS employee_id) fa ON (true))
     LEFT JOIN employees emp ON ((emp.id = fa.employee_id)))
     LEFT JOIN employees asg ON ((asg.id = v.assigned_driver_id)))
     LEFT JOIN last_completed lc ON ((lc.visit_id = v.id)))
     LEFT JOIN prev_live pl ON ((pl.visit_id = v.id)))
     LEFT JOIN observed_cadence oc ON (((oc.client_id = v.client_id) AND (oc.service_type = v.service_type))))
     LEFT JOIN observed_price op ON (((op.client_id = v.client_id) AND (op.service_type = v.service_type))))
     LEFT JOIN jobs jb ON ((jb.id = v.job_id)))
     LEFT JOIN observed_job_cadence ojc ON ((ojc.job_id = v.job_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.visit_id = v.id) AND (sli.schedulable = true))), ( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.job_id = v.job_id) AND (li3.visit_id IS NULL) AND (li3.invoice_id IS NULL) AND (sli.schedulable = true)))) AS sa_group) sagrp ON (true))
  WHERE (v.deleted_at IS NULL);
