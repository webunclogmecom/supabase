-- ROLLBACK of 2026-11-14_0203_ops_portal_search_addresses_invoices_quotes.sql (B4 of the Client App move).
--
-- Puts ops.portal_search(text) back to its 2026-11-05_0230 body (verbatim, md5 3ddd56fed24618c59d16ff16c8f4ed4d with carriage returns
-- removed; its grants are kept by CREATE OR REPLACE). Guarded: refuses unless the live body is the one this migration
-- applied. The live portal never read the three new groups, so it does not change; a portal build that shows them shows
-- none until the migration is applied again.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('ops.portal_search(text)'::regprocedure), chr(13), '')) <> '4af9a78cd5a0d894e9328d050e7a32b2' then
    raise exception 'ops.portal_search(text) is not the body of 2026-11-14_0203_ops_portal_search_addresses_invoices_quotes; do not undo blindly';
  end if;
end
$pin$;

CREATE OR REPLACE FUNCTION ops.portal_search(p_q text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_q text := btrim(coalesce(p_q, ''));
  v_like text;
  v_closed text[];
  v_calendar boolean;
  v_clients boolean;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_found jsonb := '[]'::jsonb;
  v_ids bigint[] := '{}';
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL OR length(v_q) < 2 OR length(v_q) > 80 THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  v_calendar := NOT 'visit_calendar' = ANY (v_closed);
  v_clients := NOT 'client_app' = ANY (v_closed);
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  IF v_calendar OR v_clients THEN
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.rank, x.inactive, x.code), '[]'::jsonb),
           coalesce(array_agg(x.id ORDER BY x.rank, x.inactive, x.code), '{}'::bigint[])
      INTO v_found, v_ids
      FROM (
        SELECT c.id, c.client_code AS code, c.name, c.status,
               CASE WHEN lower(c.client_code) = lower(v_q) THEN 0
                    WHEN c.client_code ILIKE v_like || '%' THEN 1
                    WHEN c.name ILIKE v_like || '%' THEN 2
                    ELSE 3 END AS rank,
               c.status = 'INACTIVE' AS inactive
          FROM public.clients c
         WHERE c.client_code ILIKE '%' || v_like || '%' OR c.name ILIKE '%' || v_like || '%'
         ORDER BY rank, inactive, c.client_code
         LIMIT 6
      ) x;
    v_out := v_out || jsonb_build_object('clients', v_found);
  END IF;

  IF v_calendar AND cardinality(v_ids) > 0 THEN
    -- The next visit of the first 3 clients found, or the last one when none is coming.
    v_out := v_out || jsonb_build_object('visits', (
      SELECT coalesce(jsonb_agg(to_jsonb(y) ORDER BY array_position(v_ids, y.client_id)), '[]'::jsonb)
        FROM (
          SELECT DISTINCT ON (v.client_id)
                 v.id, v.client_id, v.client_code, v.client_name, v.visit_date, v.start_at, v.is_all_day,
                 coalesce(v.service_label, v.service_type) AS service, v.truck_name AS truck, v.driver_name AS driver,
                 CASE WHEN v.visit_date >= v_today THEN 'next' ELSE 'last' END AS kind
            FROM ops.v_calendar_visit v
           WHERE v.client_id = ANY (v_ids[1:3])
             AND ((v.visit_date >= v_today AND v.visit_status = 'scheduled')
               OR (v.visit_date < v_today AND v.visit_status = 'completed'))
           ORDER BY v.client_id,
                    (v.visit_date >= v_today) DESC,
                    CASE WHEN v.visit_date >= v_today THEN v.visit_date END ASC,
                    v.visit_date DESC,
                    v.start_at
        ) y));
    v_out := v_out || jsonb_build_object('requests', (
      SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY array_position(v_ids, z.client_id), z.age_days DESC), '[]'::jsonb)
        FROM (
          SELECT r.id, r.client_id, r.client_code, r.client_name, r.service_summary AS service, r.age_days, r.call_required
            FROM ops.v_visit_requests r
           WHERE r.client_id = ANY (v_ids)
           ORDER BY r.age_days DESC
           LIMIT 4
        ) z));
  END IF;

  IF NOT 'hr' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('people', (
      SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.full_name), '[]'::jsonb)
        FROM (
          SELECT e.id, e.full_name, e.access_level, e.color_hex
            FROM public.employees e
           WHERE e.status = 'ACTIVE' AND e.full_name ILIKE '%' || v_like || '%'
           ORDER BY e.full_name
           LIMIT 4
        ) p));
  END IF;

  RETURN v_out;
END;
$function$;

notify pgrst, 'reload schema';

do $verify$
begin
  if md5(replace(pg_get_functiondef('ops.portal_search(text)'::regprocedure), chr(13), '')) <> '3ddd56fed24618c59d16ff16c8f4ed4d' then
    raise exception 'verify_fail: ops.portal_search(text) is not the 2026-11-05_0230 body';
  end if;
  if has_function_privilege('anon', 'ops.portal_search(text)', 'execute') or not has_function_privilege('authenticated', 'ops.portal_search(text)', 'execute') then
    raise exception 'verify_fail: the grants of ops.portal_search(text) are not what they were';
  end if;
  raise notice 'verify ok: ops.portal_search(text) is the 2026-11-05_0230 body again';
end $verify$;

COMMIT;
