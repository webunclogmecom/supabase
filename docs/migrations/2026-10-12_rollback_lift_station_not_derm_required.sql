-- ============================================================================
-- ROLLBACK of 2026-10-12_1600_lift_station_not_derm_required.sql (and of 2026-10-12_1605 if it was applied)
-- 🛑 Roll back 2026-10-12_1610 (derm.v_lwt_pickups_without_manifest) FIRST: that view reads the rule view, so this
--    file's DROP of public.v_visit_lift_station_pumping would refuse (RESTRICT) and nothing would change.
-- ============================================================================
-- One transaction, one call. It REFUSES unless the five objects 1600 created are still on 1600's md5s: run days
-- later, after another migration edited one of them, it would otherwise silently undo that edit. If it refuses,
-- rebuild it from the live bodies (the later edit must be merged by hand).
-- Order, chosen so the heavy part never runs while an app-read view is locked:
--   1. the classifier and the catalogue back (function + 2 rows: no view lock)
--   2. re-promotion (~0.4 s UPDATE over the unlocked visits stored FALSE; row locks only). It puts back TRUE on
--      every visit 1600 or its consequences made FALSE that the OLD rule calls TRUE: the backfilled pending visits
--      (found in audit.logs: TRUE -> FALSE, app_source 'sql', at or after the LATEST 04/11 catalogue change) and any
--      lift station visit created after it (the SA generator and the Calendar wrote FALSE). Completed ones among the
--      latter come back as DERM required (Missing Docs), which is what the old rule says and what keeps them in the
--      Field Portal once its lift station arm is gone. Locked rows are never touched.
--   3. the three views back, in lock order (DUMP, picker, Field Portal last): short, lock_timeout 3 s
--   4. 1605's view (optional, reads the rule), the rule view, then the helper (a SQL function body records no
--      dependency, so the helper may only go once the classifier no longer calls it: step 1)
-- If a lock times out, send the whole file again: nothing is kept.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE _rb_acl ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl FROM pg_class
   WHERE oid IN ('customer.work_orders'::regclass, 'public.manifest_pickable_visits'::regclass, 'public.dump_outstanding_visits'::regclass);
CREATE TEMP TABLE _rb_ts ON COMMIT DROP AS
  SELECT max(changed_at) AS ts FROM audit.logs
   WHERE table_schema = 'public' AND table_name = 'service_line_items' AND operation = 'UPDATE'
     AND new_row->>'code' IN ('04','11') AND old_row->>'requires_derm' = 'true' AND new_row->>'requires_derm' = 'false';
DO $pre$
BEGIN
  IF (SELECT ts FROM _rb_ts) IS NULL THEN RAISE EXCEPTION 'rollback: no audit row of the 04/11 catalogue change: 1600 was not applied'; END IF;
  IF to_regclass('public.v_visit_lift_station_pumping') IS NULL THEN RAISE EXCEPTION 'rollback: the lift station view is not there'; END IF;
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '7e889e8f135a808080eea4da88e25cdb' THEN
    RAISE EXCEPTION 'rollback: the classifier is not 1600''s body (changed since): rebuild this rollback from the live bodies'; END IF;
  IF md5(pg_get_viewdef('public.v_visit_lift_station_pumping'::regclass)) <> '646c58880a808ecf00a6d468062d049b' THEN
    RAISE EXCEPTION 'rollback: v_visit_lift_station_pumping is not 1600''s body (changed since): rebuild this rollback'; END IF;
  IF md5(pg_get_viewdef('public.dump_outstanding_visits'::regclass)) <> '9cd9caec1e8fee8e5185b1d89c27fdfe' THEN
    RAISE EXCEPTION 'rollback: dump_outstanding_visits is not 1600''s body (changed since): rebuild this rollback'; END IF;
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> '09c9282e54442afea7c5412741e8476f' THEN
    RAISE EXCEPTION 'rollback: manifest_pickable_visits is not 1600''s body (changed since): rebuild this rollback'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '2cb2720c0a935f36ab37debfb7ac7a25' THEN
    RAISE EXCEPTION 'rollback: customer.work_orders is not 1600''s body (changed since): rebuild this rollback'; END IF;
END $pre$;

-- 1. the classifier (baseline) and the catalogue
CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
    WHEN p_name IS NULL OR btrim(p_name) = '' THEN NULL
    -- (a) taxonomy-formatted "NN - ..." -> authoritative flag by code.
    --     ⚠ A fee/admin line answers NULL, not FALSE: it does not say whether the work
    --     needed a manifest, and FALSE would be read as "definitively not required".
    WHEN substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s') IS NOT NULL THEN
      (SELECT CASE WHEN s.reason IN ('fee', 'other') THEN NULL ELSE s.requires_derm END
         FROM public.service_line_items s
        WHERE s.code = lpad(substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s'), 2, '0'))
    -- (b0) 2026-09-24: a free-text line that is exactly GREY WATER pumping answers what the catalogue
    --      says for grey water pumping (codes 03 and 10; FALSE since 2026-09-24_1220), so the policy
    --      stays in one place. The phrase list is public.fn_line_item_is_free_text_grey_water.
    WHEN public.fn_line_item_is_free_text_grey_water(p_name) THEN
      (SELECT bool_and(s.requires_derm) FROM public.service_line_items s
        WHERE s.service_type = 'Pumping' AND s.location_target = 'Grey Water')
    -- (b) free-text PUMPING: a regulated vessel (grease trap/interceptor, grey water, lift station)
    --     near a pump word (either order), or an explicit pump-out (any word-form).
    WHEN btrim(p_name) ~* '(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)[^,]*pump'
      OR btrim(p_name) ~* 'pump[a-z]*[^,]*(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)'
      OR btrim(p_name) ~* 'pump(ed|ing|s)?\s*[- ]?out'
      THEN true
    -- (c) free-text recognized NON-pumping services / parts / fees
    --     ⚠ Left answering FALSE on purpose: this same branch covers clean/hydrojet/camera/
    --     labour, where FALSE is real evidence. Narrowing it is a separate change.
    WHEN btrim(p_name) ~* '(clean|hydrojet|unclog|camera|dye|assess|inspect|labou?r|\mpart|warrant|fee|tax|gdo|manifest|report|faucet|toilet|pipe|drain|install|repair|replace|locator|leak|smell|pictur|material|supply|\mdig|concret|cover|barrier|discount|credit|tip|commissary|ceiling|sump|plumb|cancel|removal|sample|mop|connection|brass|tapcon|union|p-?trap|reconnect|reinstal|drill|valve|emergency\s*visit|manhole|driver)'
      THEN false
    ELSE NULL
  END
$function$
;

COMMENT ON FUNCTION public.fn_visit_requires_derm(bigint) IS 'DERM required for a visit, from the line items it reaches (visit, invoice or job). Any line classified TRUE -> true; every line classified and none TRUE -> false; otherwise NULL (unknown, treated as still needing a manifest). Fee/admin catalogue lines (reason fee/other: 25, 26, 27) abstain: they are left out of the fold, so a visit reaching only such lines is NULL. Grey water pumping (03, 10) is not DERM required since 2026-09-24.';
COMMENT ON FUNCTION public.fn_line_item_requires_derm(text) IS 'Does this line item NAME indicate DERM was required? TRUE = yes, FALSE = it says no, NULL = it does not say. Fee/admin catalogue lines (reason fee/other, codes 25/26/27) answer NULL by design: a payment fee is not evidence that no manifest was needed, and FALSE would evict the visit from customer.work_orders. See 2026-08-06_1448_fee_lines_are_derm_neutral.sql.';

DO $cat$
DECLARE v_n int;
BEGIN
  UPDATE public.service_line_items SET requires_derm = true WHERE code IN ('04','11') AND requires_derm IS FALSE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN RAISE EXCEPTION 'rollback catalogue: expected 2 rows, updated %', v_n; END IF;
END $cat$;

-- 2. re-promotion (old rule restored above, so fn_visit_requires_derm answers as before 1600)
DO $rp$
DECLARE v_n int; v_ts timestamptz := (SELECT ts FROM _rb_ts);
BEGIN
  UPDATE public.visits v SET derm_required = true
   WHERE v.deleted_at IS NULL AND v.derm_required IS FALSE AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS TRUE
     AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
                  AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id) OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
                  AND (lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('04','11')
                       OR li.name ~* 'l[iy]ft[-[:space:]]*station'))
     AND (v.created_at >= v_ts
          OR EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_schema = 'public' AND a.table_name = 'visits' AND a.operation = 'UPDATE'
                      AND (a.old_row->>'id')::bigint = v.id AND a.old_row->>'derm_required' = 'true' AND a.new_row->>'derm_required' = 'false'
                      AND a.app_source = 'sql' AND a.changed_at >= v_ts));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'rollback: % visits put back to DERM required', v_n;
END $rp$;

-- 3. the three readers back to their previous bodies, in lock order (baseline)
CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
 SELECT p.visit_id,
    p.client_code,
    p.client_name,
    regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) AS address,
        CASE
            WHEN ((p.city IS NOT NULL) AND (regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) ~* ((',\s*'::text || p.city) || '(\s*,|\s*$)'::text))) THEN NULL::text
            ELSE p.city
        END AS city,
    p.visit_date,
    p.completed_at,
    vis.vehicle_id,
    veh.name AS truck,
    gd.gdo_number,
    GREATEST(0, (((now() AT TIME ZONE 'America/New_York'::text))::date - p.visit_date)) AS age_days,
    (GREATEST(0, (((now() AT TIME ZONE 'America/New_York'::text))::date - p.visit_date)) > 14) AS needs_office,
    (h.visit_id IS NOT NULL) AS on_sheet,
    emp.full_name AS marked_by,
    h.handed_at AS marked_at,
    vis.assigned_driver_id,
    p.county,
    fn_dump_county_bucket(p.county) AS county_bucket,
    ((h.visit_id IS NOT NULL) AND (COALESCE(dv.start_at, h.handed_at) < (now() - fn_dump_confirm_window()))) AS confirmed_hidden,
    h.dump_visit_id AS marked_dump_visit_id,
    (COALESCE(dv.start_at, h.handed_at) + fn_dump_confirm_window()) AS confirm_expires_at,
        CASE
            WHEN (h.visit_id IS NULL) THEN NULL::integer
            ELSE GREATEST(0, ((EXTRACT(epoch FROM ((COALESCE(dv.start_at, h.handed_at) + fn_dump_confirm_window()) - now())) / (60)::numeric))::integer)
        END AS confirm_minutes_left
   FROM ((((((manifest_pickable_visits p
     JOIN visits vis ON ((vis.id = p.visit_id)))
     LEFT JOIN vehicles veh ON ((veh.id = vis.vehicle_id)))
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_number(p.client_id, vis.property_id, p.visit_id) AS gdo_number) gd ON (true))
     LEFT JOIN dump_manifest_handout h ON ((h.visit_id = p.visit_id)))
     LEFT JOIN visits dv ON ((dv.id = h.dump_visit_id)))
     LEFT JOIN employees emp ON ((emp.id = h.driver_id)))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM (derm.address_sheet_clients a
             JOIN derm.address_sheets s ON ((s.id = a.sheet_id)))
          WHERE ((a.visit_id = p.visit_id) AND (s.deleted_at IS NULL)))));

CREATE OR REPLACE VIEW public.manifest_pickable_visits WITH (security_invoker = true) AS
 SELECT visit_id,
    visit_date,
    start_at,
    completed_at,
    service_type,
    title,
    client_id,
    client_code,
    client_name,
    address,
    city,
    county,
    fn_dump_county_bucket(county) AS county_bucket
   FROM ( SELECT v.id AS visit_id,
            v.visit_date,
            v.start_at,
            v.completed_at,
            v.service_type,
            v.title,
            c.id AS client_id,
            c.client_code,
            c.name AS client_name,
            COALESCE(p.address, primary_p.address) AS address,
            COALESCE(p.city, primary_p.city) AS city,
            COALESCE(p.county, primary_p.county) AS county
           FROM (((visits v
             JOIN clients c ON ((c.id = v.client_id)))
             LEFT JOIN properties p ON ((p.id = v.property_id)))
             LEFT JOIN properties primary_p ON (((primary_p.client_id = v.client_id) AND (primary_p.is_primary = true))))
          WHERE ((v.visit_status = 'completed'::text) AND ((v.derm_required IS NULL) OR (v.derm_required = true)) AND (v.deleted_at IS NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM (manifest_visits mv
                     JOIN derm_manifests dm ON ((dm.id = mv.manifest_id)))
                  WHERE ((mv.visit_id = v.id) AND (dm.deleted_at IS NULL))))))) _pv
  WHERE (NOT (client_id IN ( SELECT clients.id
           FROM clients
          WHERE fn_is_non_customer(clients.id, ARRAY['dump_site'::text]))));

CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN (v.start_at IS NOT NULL) THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM (visit_assignments va
             JOIN employees e ON ((e.id = va.employee_id)))
          WHERE (va.visit_id = v.id)), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM (visit_team vt
             JOIN employees e2 ON ((e2.id = vt.employee_id)))
          WHERE (vt.visit_id = v.id))) AS driver,
    veh.name AS truck,
    ( SELECT vd.decal_number
           FROM (((manifest_visits mv
             JOIN derm_manifests dm_1 ON (((dm_1.id = mv.manifest_id) AND (dm_1.deleted_at IS NULL))))
             JOIN disposal_facilities df ON ((df.id = dm_1.disposal_facility_id)))
             JOIN vehicle_decals vd ON (((vd.vehicle_id = veh.id) AND (vd.jurisdiction = df.county) AND (vd.status = 'ACTIVE'::text))))
          WHERE (mv.visit_id = v.id)
         LIMIT 1) AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE ((prim.client_id = v.client_id) AND (prim.is_primary = true))
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    (row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date))::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN ((sc.frequency_days IS NULL) OR (sc.frequency_days <= 0)) THEN NULL::integer
                    ELSE (GREATEST((1)::numeric, round((365.0 / (sc.frequency_days)::numeric))))::integer
                END AS "greatest"
           FROM v_client_agreement_services sc
          WHERE ((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))
         LIMIT 1) AS visit_total,
    NULL::text AS notes,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
        CASE
            WHEN (rc.class = 'receipt'::text) THEN dm.derm_manifest_url
            ELSE NULL::text
        END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN (dm.yellow_ticket_number IS NOT NULL) THEN 'broward'::text
            WHEN ((dm.white_manifest_number IS NOT NULL) AND (length(dm.white_manifest_number) >= 5)) THEN 'dade'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE ((prim.client_id = v.client_id) AND (prim.is_primary = true))
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE (df.id = dm.disposal_facility_id)) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ARRAY[]::text[]) AS services,
    ( SELECT df2.county
           FROM disposal_facilities df2
          WHERE (df2.id = dm.disposal_facility_id)) AS disposal_county,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ARRAY[]::text[]) AS service_items,
    COALESCE(( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN (x.nm ~* 'unclog'::text) THEN 'Unclogging'::text
                            WHEN (x.nm ~* 'pump'::text) THEN 'Pumping'::text
                            WHEN (x.nm ~* 'hydrojet'::text) THEN 'Cleaning'::text
                            WHEN (x.nm ~* '^camera inspection'::text) THEN 'Camera Inspection'::text
                            WHEN (x.nm ~* 'dye test'::text) THEN 'Dye Test'::text
                            WHEN (x.nm ~* 'assessment'::text) THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM (( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))) x
                     LEFT JOIN service_line_items sli ON ((sli.code = x.code)))) lbl
          WHERE (lbl.label IS NOT NULL)), ( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN (x.nm ~* 'unclog'::text) THEN 'Unclogging'::text
                            WHEN (x.nm ~* 'pump'::text) THEN 'Pumping'::text
                            WHEN (x.nm ~* 'hydrojet'::text) THEN 'Cleaning'::text
                            WHEN (x.nm ~* '^camera inspection'::text) THEN 'Camera Inspection'::text
                            WHEN (x.nm ~* 'dye test'::text) THEN 'Dye Test'::text
                            WHEN (x.nm ~* 'assessment'::text) THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM (( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))) x
                     LEFT JOIN service_line_items sli ON ((sli.code = x.code)))) lbl
          WHERE (lbl.label IS NOT NULL)), ARRAY[]::text[]) AS service_type,
    COALESCE(v.derm_required, true) AS derm_required
   FROM (((((visits v
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM (derm_manifests dm_inner
             JOIN manifest_visits mv ON ((mv.manifest_id = dm_inner.id)))
          WHERE ((mv.visit_id = v.id) AND (dm_inner.deleted_at IS NULL))
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON (true))
     LEFT JOIN LATERAL ( SELECT f.url
           FROM derm.fn_fog_documents(dm.id, v.client_id, v.id) f(effective_page, url)
          ORDER BY f.effective_page
         LIMIT 1) rd ON (true))
     LEFT JOIN derm.receipt_doc_class rc ON ((rc.url = dm.derm_manifest_url)))
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND ((COALESCE(v.derm_required, true) = true) OR (EXISTS ( SELECT 1
           FROM v_visit_grey_water_pumping gwp
          WHERE (gwp.visit_id = v.id)))) AND (v.deleted_at IS NULL));

COMMENT ON COLUMN customer.work_orders.derm_required IS 'COALESCE(visits.derm_required, true), never NULL. FALSE only on a grey water pumping visit (catalogue Pumping + Grey Water, decided by the visit''s own coded lines first), the one not-required kind the client still sees (Fred, 2026-09-24). Apps hide the DERM paperwork parts on === false with no manifest number, never on !== true.';
COMMENT ON VIEW public.dump_outstanding_visits IS 'Read-only browse list of completed visits that still have no live DERM manifest link, with the address cleaned for copying onto a sheet. Shared projection: dump_manifest_handout_list selects FROM this. Browsing must never record a hand-out, which is why this exists separately.';
COMMENT ON VIEW public.manifest_pickable_visits IS NULL;

-- 4. the new objects
DROP VIEW IF EXISTS derm.v_lwt_lift_station_unlinked;
DROP VIEW public.v_visit_lift_station_pumping;
DROP FUNCTION public.fn_line_item_is_free_text_lift_station(text);

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '4c11514fe282b48e82e4a0e6268556ff' THEN RAISE EXCEPTION 'rollback: classifier not restored'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> 'a78a3815fff23c00d2100b963b159260' THEN RAISE EXCEPTION 'rollback: work_orders not restored'; END IF;
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> 'd5513224f7b2220c8c1ec0c0de1129a9' THEN RAISE EXCEPTION 'rollback: picker not restored'; END IF;
  IF md5(pg_get_viewdef('public.dump_outstanding_visits'::regclass)) <> '5eb6eed9069a38f7557175a279b3c13f' THEN RAISE EXCEPTION 'rollback: dump_outstanding not restored'; END IF;
  IF (SELECT reloptions::text FROM pg_class WHERE oid = 'public.manifest_pickable_visits'::regclass) IS DISTINCT FROM '{security_invoker=true}' THEN
    RAISE EXCEPTION 'rollback: the picker lost security_invoker'; END IF;
  IF EXISTS (SELECT 1 FROM _rb_acl a JOIN pg_class c ON c.oid = a.reloid WHERE c.relacl::text IS DISTINCT FROM a.acl) THEN
    RAISE EXCEPTION 'rollback: a view ACL changed'; END IF;
  IF to_regclass('public.v_visit_lift_station_pumping') IS NOT NULL OR to_regprocedure('public.fn_line_item_is_free_text_lift_station(text)') IS NOT NULL
     OR to_regclass('derm.v_lwt_lift_station_unlinked') IS NOT NULL THEN RAISE EXCEPTION 'rollback: a new object is still there'; END IF;
  IF (SELECT string_agg(code, ',' ORDER BY code) FROM public.service_line_items WHERE requires_derm) IS DISTINCT FROM '01,02,04,09,11' THEN
    RAISE EXCEPTION 'rollback: the catalogue is not back to {01,02,04,09,11}'; END IF;
  IF EXISTS (SELECT 1 FROM public.visits v WHERE v.deleted_at IS NULL AND v.visit_status = 'scheduled'
               AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date AND v.derm_required IS FALSE
               AND v.derm_required_locked IS NOT TRUE AND public.fn_visit_requires_derm(v.id) IS TRUE
               AND EXISTS (SELECT 1 FROM public.line_items li WHERE li.job_id = v.job_id
                            AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('04','11'))) THEN
    RAISE EXCEPTION 'rollback: a pending lift station visit is still FALSE while the old rule says TRUE'; END IF;
END $verify$;
NOTIFY pgrst, 'reload schema';
COMMIT;
