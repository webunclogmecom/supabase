-- ============================================================================
-- 2026-06-08f — Admin Review: edit a visit's manholes (visit_locations contract)
-- ============================================================================
-- Per Fred 2026-06-08: the Admin Review app (where ops classifies photos + does
-- pre/post inspections + enters manhole counts) becomes the surface to EDIT which
-- manhole(s) a visit serviced. This is the human-tagging that resolves multi-manhole
-- attribution (Casa Neos = Bars/Kitchens/Lounge) which Jobber carries no signal for,
-- and it feeds per-manhole DERM (manifest -> visit -> tagged manhole).
--
-- Contract for the app (reads/writes Prod canonical via its prodMirror anon client):
--   * READ  public.visit_manhole_options — for a visit, EVERY manhole its client has +
--           whether this visit is assigned to it (the checklist the editor renders).
--   * WRITE public.set_visit_manholes(p_visit_id, p_location_ids[]) — replace-set the
--           visit's manholes atomically; validates each location belongs to the visit's
--           client (can't tag a foreign manhole). SECURITY DEFINER so the anon role needs
--           only EXECUTE (no broad write grant on visit_locations). The audit_visit_locations
--           trigger captures the change (app_source resolves to 'admin-review').
-- Adding a brand-new manhole/location is out of scope here (separate admin action); this
-- toggles which EXISTING client_locations a visit serviced.
-- ============================================================================

CREATE OR REPLACE VIEW public.visit_manhole_options AS
SELECT
  v.id        AS visit_id,
  cl.id       AS client_location_id,
  cl.name     AS location_name,
  g.gdo_number,
  EXISTS (SELECT 1 FROM public.visit_locations vl
          WHERE vl.visit_id = v.id AND vl.client_location_id = cl.id) AS is_assigned
FROM public.visits v
JOIN public.client_locations cl ON cl.client_id = v.client_id
LEFT JOIN public.gdos g ON g.client_location_id = cl.id AND g.status = 'ACTIVE'
WHERE v.deleted_at IS NULL;

GRANT SELECT ON public.visit_manhole_options TO anon, authenticated, service_role, yannick_readonly;

CREATE OR REPLACE FUNCTION public.set_visit_manholes(p_visit_id bigint, p_location_ids bigint[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_client bigint;
BEGIN
  SELECT client_id INTO v_client FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'set_visit_manholes: visit % not found (or deleted)', p_visit_id;
  END IF;
  -- remove manholes no longer selected
  DELETE FROM public.visit_locations vl
  WHERE vl.visit_id = p_visit_id
    AND NOT (vl.client_location_id = ANY (COALESCE(p_location_ids, ARRAY[]::bigint[])));
  -- add newly selected manholes, but ONLY locations that belong to this visit's client
  INSERT INTO public.visit_locations (visit_id, client_location_id)
  SELECT p_visit_id, cl.id
  FROM public.client_locations cl
  WHERE cl.client_id = v_client
    AND cl.id = ANY (COALESCE(p_location_ids, ARRAY[]::bigint[]))
  ON CONFLICT (visit_id, client_location_id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_visit_manholes(bigint, bigint[]) TO anon, authenticated, service_role;
