-- ============================================================================
-- 2026-06-25 — Editable line-item prices on Calendar visits
-- ----------------------------------------------------------------------------
-- The New Visit form selected services by ID only and create_calendar_visit
-- hardcoded unit_price/total_price = 0, so visit line items had no price and
-- (separately) were never pushed to Jobber. Per Fred: Service-Call line items
-- get an EDITABLE price on the form (default blank), with an optional catalog
-- default per service. (Service-Agreement line items keep their per-client
-- prices on the Jobber SA job — unaffected here.)
--
-- This migration:
--   1. Adds public.service_line_items.unit_price (nullable catalog default;
--      NULL = no default, office enters the price per visit).
--   2. Recreates create_calendar_visit (public + ops wrapper) with a new
--      optional p_line_item_prices jsonb param: a map of
--      service_line_item_id(text) -> { "unit_price": <num>, "quantity": <num> }.
--      Per line item the price resolves as
--        COALESCE(form price, catalog service_line_items.unit_price, 0)
--      and quantity as COALESCE(form qty, 1); total = price * qty.
--      Adding a param changes the signature, so the 12-arg versions are dropped
--      and recreated atomically (grants restored) to avoid an ambiguous overload.
-- ============================================================================

ALTER TABLE public.service_line_items ADD COLUMN IF NOT EXISTS unit_price numeric;
COMMENT ON COLUMN public.service_line_items.unit_price IS
  'Optional catalog default unit price for this service. NULL = no default (office sets price per visit on the Calendar form). Used by create_calendar_visit when the form does not pass a per-line price.';

DROP FUNCTION IF EXISTS ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint);
DROP FUNCTION IF EXISTS public.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint);

CREATE FUNCTION public.create_calendar_visit(
  p_client_id bigint,
  p_job_id bigint,
  p_service_line_item_ids bigint[],
  p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint,
  p_client_location_ids bigint[] DEFAULT NULL::bigint[],
  p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_title text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text,
  p_vehicle_id bigint DEFAULT NULL::bigint,
  p_driver_id bigint DEFAULT NULL::bigint,
  p_line_item_prices jsonb DEFAULT NULL::jsonb
)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary      bigint;
  v_service_type text;
  v_derm         boolean;
  v_property     bigint;
  v_visit        public.visits;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_primary := p_service_line_item_ids[1];
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = v_primary;
  SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(
    p_property_id,
    (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1)
  );

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes,
                      visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, p_driver_id, p_visit_date, p_start_at, p_end_at,
          p_title, v_service_type, v_primary, COALESCE(v_derm, false), p_notes,
          'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  -- Line items: price = COALESCE(form-supplied, catalog default, 0); qty = COALESCE(form-supplied, 1).
  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT
    v_visit.id,
    s.title,
    '',
    COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
      * COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1),
    false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id
    LIMIT 1
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_visit;
END;
$function$;

CREATE FUNCTION ops.create_calendar_visit(
  p_client_id bigint,
  p_job_id bigint,
  p_service_line_item_ids bigint[],
  p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint,
  p_client_location_ids bigint[] DEFAULT NULL::bigint[],
  p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_title text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text,
  p_vehicle_id bigint DEFAULT NULL::bigint,
  p_driver_id bigint DEFAULT NULL::bigint,
  p_line_item_prices jsonb DEFAULT NULL::jsonb
)
 RETURNS visits
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.create_calendar_visit(p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
    p_property_id, p_client_location_ids, p_start_at, p_end_at, p_title, p_notes, p_vehicle_id, p_driver_id,
    p_line_item_prices);
$function$;

GRANT EXECUTE ON FUNCTION public.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb) TO anon, authenticated, service_role;
