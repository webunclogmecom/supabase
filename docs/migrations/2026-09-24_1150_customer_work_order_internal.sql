-- ============================================================================
-- 2026-09-24_1150_customer_work_order_internal.sql
-- ============================================================================
-- Fred, on the DERM Tracker's new "Download Report": "it works perfectly if it's a visit that is
-- already FP App, meaning is a DERM required, but I need it also when is not DERM Required, like
-- cases where is a SC visit, like https://derm.unclogme.app/visits/8117".
--
-- The Field Portal report exists only for DERM-required visits BY DESIGN: customer.work_orders
-- filters COALESCE(v.derm_required, true) = true (Fred, 2026-08-05: "we only show derms required
-- jobs to the work orders"). That customer rule is NOT changed here.
--
-- Instead, a STAFF-ONLY twin for the report printer:
--   customer.work_orders_all          = customer.work_orders with that ONE predicate removed
--   customer.get_work_order_internal  = customer.get_work_order reading the twin
-- Both are SERVICE_ROLE ONLY. The edge function derm-visit-report calls the function and hands
-- the result to the pdf-service, which serves it to the Field Portal's own report page inside its
-- headless browser. Customers see nothing new; the report is still FP's page, byte for byte.
--
-- 🛑 COPIED, NEVER RETYPED: both bodies are the live pg_get_viewdef / pg_get_functiondef output
-- (md5-pinned below) with exactly the named edits. If customer.work_orders or get_work_order ever
-- changes, the twins do NOT follow: re-run this build against the new definitions.
-- ⚠ ONE COLUMN DIFFERS BY DESIGN: visit_num. It is a window count evaluated AFTER the WHERE, so
-- the twin numbers a visit among ALL the client's completed visits, the original among the
-- DERM-required ones only (measured: 330 of 796 DERM rows differ in visit_num and in nothing else).
-- derm-visit-report uses the twin ONLY for a visit the Field Portal has no report for, so a DERM
-- visit's downloaded report keeps FP's numbering exactly.
-- Rule 8 (audit): views and a read-only function, no table, nothing to audit.
-- ============================================================================

DO $pin$
BEGIN
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '5dc2f07cadc35bbbfe7e3a32a48c6d39' THEN
    RAISE EXCEPTION 'customer.work_orders changed since this migration was built; rebuild it';
  END IF;
  IF md5(pg_get_functiondef('customer.get_work_order(text)'::regprocedure)) <> '31d124404035b44b5ddb670ad4de0195' THEN
    RAISE EXCEPTION 'customer.get_work_order changed since this migration was built; rebuild it';
  END IF;
END
$pin$;

CREATE VIEW customer.work_orders_all AS
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
           FROM service_configs sc
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
          WHERE (lbl.label IS NOT NULL)), ARRAY[]::text[]) AS service_type
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
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND (v.deleted_at IS NULL));

COMMENT ON VIEW customer.work_orders_all IS
  'STAFF-ONLY twin of customer.work_orders without the derm_required filter, for the DERM Tracker '
  'Download Report of non-DERM visits (2026-09-24). service_role only. Customers must never read it.';

CREATE FUNCTION customer.get_work_order_internal(p_work_order_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'customer', 'pg_temp'
AS $function$
  select jsonb_build_object(
    -- 🛑 fog_documents lives INSIDE work_order, not beside it. Both consumers read it there:
    -- the FOG card does `workOrder.fog_documents` and the print report does the same. Returned as a
    -- sibling key it is invisible to them and the card silently falls back to its "not available
    -- for online viewing" placeholder, which is what happened on the first attempt.
    'work_order', to_jsonb(w) || jsonb_build_object(
      'fog_documents', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'effective_page', fd.effective_page,
               'url',            fd.url) order by fd.effective_page), '[]'::jsonb)
        from public.visits v
        cross join lateral (
          select dm_inner.id
            from public.derm_manifests dm_inner
            join public.manifest_visits mv on mv.manifest_id = dm_inner.id
           where mv.visit_id = v.id and dm_inner.deleted_at is null
           order by dm_inner.service_date desc nulls last
           limit 1) dm
        cross join lateral derm.fn_fog_documents(dm.id, v.client_id, v.id) fd
       where v.public_id = w.id and v.deleted_at is null)),
    'permits', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb)
        from customer.permits p where p.client_id = w.client_id),
    'inspection_items', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.position), '[]'::jsonb)
        from customer.inspection_items i where i.work_order_id = w.id),
    'recommendations', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.position), '[]'::jsonb)
        from customer.recommendations r where r.work_order_id = w.id),
    'photos', (
      select coalesce(jsonb_agg(to_jsonb(ph) order by ph.position), '[]'::jsonb)
        from customer.wo_photos ph where ph.work_order_id = w.id),
    -- Online Report (GDO filing proof), ONE ENTRY PER PERMIT.
    -- Explicit key list: never to_jsonb(g). screenshot_path must never reach the customer; the image
    -- is fetched through get-derm-doc, which authorises on manifest_id + client_code (+ gdo_id).
    -- manifest_id is NULL on a permit with no filing - the app must not offer a document link then.
    'gdo_reports', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'gdo_id',           g.gdo_id,
               'gdo_number',       g.gdo_number,
               'manifest_id',      g.manifest_id,
               'reported',         g.reported,
               'reported_at',      g.reported_at,
               'confirmation',     g.confirmation,
               'status',           g.status,
               'has_report_image', g.has_report_image) order by g.gdo_number), '[]'::jsonb)
        from public.visits v
        join customer.gdo_reports g on g.visit_id = v.id
       where v.public_id = w.id and v.deleted_at is null)
  )
  from customer.work_orders_all w
  where w.id = p_work_order_id;
$function$;

COMMENT ON FUNCTION customer.get_work_order_internal(text) IS
  'STAFF-ONLY twin of customer.get_work_order over customer.work_orders_all (every completed visit, '
  'DERM-required or not). service_role only; called by the edge function derm-visit-report.';

-- 🛑 Supabase default privileges hand new objects in an exposed schema to anon/authenticated.
-- Revoke BY NAME, then assert the ACL below (a GRANT alone cannot remove what CREATE handed out).
REVOKE ALL ON customer.work_orders_all FROM PUBLIC, anon, authenticated;
GRANT SELECT ON customer.work_orders_all TO service_role;
REVOKE ALL ON FUNCTION customer.get_work_order_internal(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION customer.get_work_order_internal(text) TO service_role;

-- ---------------------------------------------------------------------------- VERIFY
DO $verify$
DECLARE
  n_diff int; n_twin int; n_wo int; mism int := 0; checked int := 0; r record; j jsonb;
BEGIN
  -- 1. On every DERM-required row the twin equals the original, both directions.
  SELECT count(*) INTO n_diff FROM (
    SELECT to_jsonb(w) - 'visit_num' FROM customer.work_orders w
    EXCEPT
    SELECT to_jsonb(a) - 'visit_num' FROM customer.work_orders_all a
      JOIN public.visits v ON v.public_id = a.id WHERE COALESCE(v.derm_required, true)) x;
  IF n_diff <> 0 THEN RAISE EXCEPTION 'twin is missing or differs (beyond visit_num) on % DERM rows', n_diff; END IF;
  SELECT count(*) INTO n_diff FROM (
    SELECT to_jsonb(a) - 'visit_num' FROM customer.work_orders_all a
      JOIN public.visits v ON v.public_id = a.id WHERE COALESCE(v.derm_required, true)
    EXCEPT
    SELECT to_jsonb(w) - 'visit_num' FROM customer.work_orders w) x;
  IF n_diff <> 0 THEN RAISE EXCEPTION 'twin has % DERM rows the original does not', n_diff; END IF;
  SELECT count(*) INTO n_wo FROM customer.work_orders;
  SELECT count(*) INTO n_twin FROM customer.work_orders_all;
  IF n_twin <= n_wo THEN RAISE EXCEPTION 'twin has % rows, original %: the predicate was not removed', n_twin, n_wo; END IF;

  -- 2. The internal function answers exactly like the original for DERM work orders.
  FOR r IN SELECT id FROM customer.work_orders ORDER BY visit_date DESC LIMIT 40 LOOP
    checked := checked + 1;
    IF (customer.get_work_order_internal(r.id) #- '{work_order,visit_num}') IS DISTINCT FROM (customer.get_work_order(r.id) #- '{work_order,visit_num}') THEN mism := mism + 1; END IF;
  END LOOP;
  IF checked < 40 OR mism <> 0 THEN RAISE EXCEPTION 'internal differs from get_work_order on % of % DERM work orders', mism, checked; END IF;

  -- 3. Visit 8117 (235-LOU, Labor, not DERM-required): no customer report, a staff one.
  IF customer.get_work_order('7VYAmyti2p') IS NOT NULL THEN RAISE EXCEPTION 'control: 8117 unexpectedly has a customer report'; END IF;
  j := customer.get_work_order_internal('7VYAmyti2p');
  IF j->'work_order'->>'id' IS DISTINCT FROM '7VYAmyti2p' THEN RAISE EXCEPTION '8117 not returned by the internal function'; END IF;
  IF jsonb_array_length(j->'photos') < 1 THEN RAISE EXCEPTION '8117 came back without its photos'; END IF;

  -- 4. Nobody but service_role can read either.
  IF has_table_privilege('anon', 'customer.work_orders_all', 'SELECT')
     OR has_table_privilege('authenticated', 'customer.work_orders_all', 'SELECT')
     OR has_function_privilege('anon', 'customer.get_work_order_internal(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'customer.get_work_order_internal(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon or authenticated can reach the staff-only twin';
  END IF;
  IF NOT has_function_privilege('service_role', 'customer.get_work_order_internal(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot execute the internal function';
  END IF;

  RAISE NOTICE 'OK: customer.work_orders % rows, twin % rows; % DERM work orders identical; 8117 photos %',
    n_wo, n_twin, checked, jsonb_array_length(j->'photos');
END
$verify$;
