-- 2026-06-23_ops_calendar_form_exposure.sql
-- The Calendar App reads through the ops schema (schema-per-app pattern: "apps never query
-- public directly"). The redesigned Create Visit form needs service_line_items + client_locations
-- + the create_calendar_visit RPC in ops too (it already has ops.client_service_options). Expose
-- them as ops views + an ops wrapper function. Audit (ADR 010): views/wrapper — no triggers;
-- underlying public tables keep their own audit posture (public.visits is audited).

CREATE OR REPLACE VIEW ops.service_line_items AS SELECT * FROM public.service_line_items;
GRANT SELECT ON ops.service_line_items TO anon, authenticated;

CREATE OR REPLACE VIEW ops.client_locations AS SELECT * FROM public.client_locations;
GRANT SELECT ON ops.client_locations TO anon, authenticated;

-- ops wrapper so the form can call the RPC via its ops-schema client (delegates to the
-- SECURITY DEFINER public function which does the real work + derivations).
CREATE OR REPLACE FUNCTION ops.create_calendar_visit(
  p_client_id            bigint,
  p_job_id               bigint,
  p_service_line_item_ids bigint[],
  p_visit_date           date,
  p_property_id          bigint DEFAULT NULL,
  p_client_location_ids  bigint[] DEFAULT NULL,
  p_start_at             timestamptz DEFAULT NULL,
  p_end_at               timestamptz DEFAULT NULL,
  p_title                text DEFAULT NULL,
  p_notes                text DEFAULT NULL,
  p_vehicle_id           bigint DEFAULT NULL
) RETURNS public.visits
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT public.create_calendar_visit(p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
    p_property_id, p_client_location_ids, p_start_at, p_end_at, p_title, p_notes, p_vehicle_id);
$$;

GRANT EXECUTE ON FUNCTION ops.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
