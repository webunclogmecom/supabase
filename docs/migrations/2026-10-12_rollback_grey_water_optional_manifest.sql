-- ROLLBACK of 2026-10-12_2105_grey_water_optional_manifest: the picker loses the grey water arm and the app role
-- loses SELECT on v_visit_grey_water_pumping. Manifests already filed on grey water visits stay filed and those
-- visits stay DERM required (locked); undo those one by one with the DERM Tracker's "Mark DERM Not Required".
BEGIN;

CREATE OR REPLACE VIEW public.manifest_pickable_visits WITH (security_invoker = true) AS
 SELECT visit_id, visit_date, start_at, completed_at, service_type, title, client_id, client_code, client_name,
        address, city, county, public.fn_dump_county_bucket(county) AS county_bucket
   FROM ( SELECT v.id AS visit_id, v.visit_date, v.start_at, v.completed_at, v.service_type, v.title,
                 c.id AS client_id, c.client_code, c.name AS client_name,
                 COALESCE(p.address, primary_p.address) AS address,
                 COALESCE(p.city, primary_p.city) AS city,
                 COALESCE(p.county, primary_p.county) AS county
            FROM public.visits v
            JOIN public.clients c ON c.id = v.client_id
            LEFT JOIN public.properties p ON p.id = v.property_id
            LEFT JOIN public.properties primary_p ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
           WHERE v.visit_status = 'completed'
             AND (v.derm_required IS NULL OR v.derm_required = true
                  OR EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping lsp WHERE lsp.visit_id = v.id))
             AND v.deleted_at IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
                              WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL)) _pv
  WHERE NOT (client_id IN (SELECT clients.id FROM public.clients WHERE public.fn_is_non_customer(clients.id, ARRAY['dump_site'::text])));

COMMENT ON VIEW public.manifest_pickable_visits IS 'Completed, unlinked, live visits that can take a DERM manifest: DERM required or unknown, plus lift station pumping stored FALSE (the manifest is optional, Fred 2026-10-12; filing one turns the visit DERM required). security_invoker. Read by the DERM Tracker /upload matcher and "Adding a visit" picker, derm.v_stamp_unlinked_visits and public.dump_outstanding_visits (which leaves the optional ones out).';

REVOKE SELECT ON public.v_visit_grey_water_pumping FROM authenticated;

DO $a$ BEGIN
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> '09c9282e54442afea7c5412741e8476f' THEN
    RAISE EXCEPTION 'rollback body differs from the 2026-10-12_1600 picker'; END IF;
  IF (SELECT reloptions::text FROM pg_class WHERE oid = 'public.manifest_pickable_visits'::regclass) IS DISTINCT FROM '{security_invoker=true}' THEN
    RAISE EXCEPTION 'picker lost security_invoker'; END IF;
END $a$;

COMMIT;
