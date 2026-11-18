-- =============================================================================
-- 2026-11-17_1735_portal_search_assigned_truck_only_rollback.sql
--
-- Undoes 2026-11-17_1735_portal_search_assigned_truck_only.sql: puts back the previous body of ops.portal_search(text),
-- verbatim. Guarded: it refuses unless the live body is exactly the one that migration wrote. VERIFY: the body is byte for
-- byte the one before it (md5 4af9a78cd5a0d894e9328d050e7a32b2) and the grants did not move.
-- After it, Search names the Calendar's guessed truck as a visit's truck again ("Moises with Grecia", the #225 bug).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure)) <> '67954dcf07b46c5bfc114eb93e2c23ca' THEN
    RAISE EXCEPTION 'guard: ops.portal_search(text) is not the 2026-11-17_1735 body (md5 %)', md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure));
  END IF;
END $guard$;

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

  -- Addresses, invoices and quotes, for a person who has the Client App (2026-11-14, the Client App move, decision 7).
  -- Each carries what opens its client's page on the right tab: "sites" with the site's id, or "billing". New keys only:
  -- the four groups above are unchanged. No email, phone or pay.
  IF v_clients THEN
    v_out := v_out || jsonb_build_object(
      'properties', (
        SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.rank, p.code, p.address, p.id), '[]'::jsonb)
          FROM (
            SELECT pr.id, pr.client_id, c.client_code AS code, c.name AS client_name, pr.name, pr.address, pr.city, pr.zip,
                   coalesce(pr.is_billing, false) AS is_billing, 'sites' AS tab,
                   CASE WHEN pr.address ILIKE v_like || '%' THEN 0
                        WHEN pr.address ILIKE '%' || v_like || '%' THEN 1
                        ELSE 2 END AS rank
              FROM public.properties pr
              JOIN public.clients c ON c.id = pr.client_id
             WHERE pr.deleted_at IS NULL
               AND (pr.address ILIKE '%' || v_like || '%' OR pr.name ILIKE '%' || v_like || '%'
                    OR pr.city ILIKE '%' || v_like || '%' OR pr.zip ILIKE v_like || '%')
             ORDER BY rank, c.client_code, pr.address, pr.id
             LIMIT 5
          ) p),
      'invoices', (
        SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.rank, i.issued DESC NULLS LAST, i.id DESC), '[]'::jsonb)
          FROM (
            SELECT inv.id, inv.client_id, c.client_code AS code, c.name AS client_name, inv.invoice_number,
                   inv.invoice_status AS status, (inv.sent_at AT TIME ZONE 'America/New_York')::date AS issued,
                   'billing' AS tab,
                   CASE WHEN lower(inv.invoice_number) = lower(v_q) THEN 0
                        WHEN inv.invoice_number ILIKE v_like || '%' THEN 1
                        ELSE 2 END AS rank
              FROM public.invoices inv
              JOIN public.clients c ON c.id = inv.client_id
             WHERE inv.invoice_number ILIKE '%' || v_like || '%'
             ORDER BY rank, issued DESC NULLS LAST, inv.id DESC
             LIMIT 5
          ) i),
      'quotes', (
        SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.rank, q.archived, q.id DESC), '[]'::jsonb)
          FROM (
            SELECT qt.id, qt.client_id, c.client_code AS code, c.name AS client_name, qt.quote_number, qt.title,
                   qt.quote_status AS status, coalesce(qt.quote_status, '') = 'archived' AS archived, 'billing' AS tab,
                   CASE WHEN lower(qt.quote_number) = lower(v_q) THEN 0
                        WHEN qt.quote_number ILIKE v_like || '%' THEN 1
                        WHEN qt.quote_number ILIKE '%' || v_like || '%' THEN 2
                        ELSE 3 END AS rank
              FROM public.quotes qt
              JOIN public.clients c ON c.id = qt.client_id
             WHERE qt.quote_number ILIKE '%' || v_like || '%' OR qt.title ILIKE '%' || v_like || '%'
             ORDER BY rank, archived, qt.id DESC
             LIMIT 5
          ) q));
  END IF;

  RETURN v_out;
END;
$function$
;

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure)) <> '4af9a78cd5a0d894e9328d050e7a32b2' THEN
    RAISE EXCEPTION 'verify_fail: ops.portal_search(text) is not the previous body';
  END IF;
  IF has_function_privilege('anon', 'ops.portal_search(text)', 'execute')
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.portal_search(text)'::regprocedure)
        IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'verify_fail: the grants on ops.portal_search moved';
  END IF;
END $verify$;

COMMIT;
