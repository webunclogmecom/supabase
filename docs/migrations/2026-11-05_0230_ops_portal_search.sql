-- =============================================================================
-- 2026-11-05_0230_ops_portal_search.sql
--
-- WHAT: ops.portal_search(text), the Ops Portal header's "Search everything": a client code or name from any page gives
--       the client, their next visit (or last, when none is coming) and any waiting request; a name also finds a person.
--
-- WHY: Fred, 2026-11-05, on the header mockup (https://claude.ai/artifact/KW6w5fKBtpXXv1N3FRX98w), asked what comes next:
--      "Both, search first". Record: Building Apps/Ops Portal/docs/08-changelog.md.
--
-- WHAT IT READS: public.clients, ops.v_calendar_visit, ops.v_visit_requests, public.employees. Writes nothing (STABLE).
--
-- ACCESS: SECURITY DEFINER, because a staff person's reach differs by app and the answer must not depend on who can read
--   which view. Each group is present only when its app is open to the person, by the same rule as the portal's
--   tileVisible and ops.portal_waiting: an app is closed when its mode is on and its level is neither view nor edit.
--     clients   Calendar OR Client App open
--     visits    Calendar open
--     requests  Calendar open
--     people    HR App open. Name and access level only: no email, phone or pay.
--   Someone who is not staff gets {}.
--
-- A QUERY IS TEXT, NOT A PATTERN: % _ and \ in it are escaped, so typing % finds a literal percent sign and not every
--   client. Under 2 or over 80 characters returns {}.
--
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- ATOMIC: one transaction. The VERIFY block raises on any failure and rolls the whole thing back.
-- ROLLBACK: 2026-11-05_0230_ops_portal_search_rollback.sql
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ops.portal_search(p_q text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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

REVOKE ALL ON FUNCTION ops.portal_search(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.portal_search(text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $verify$
DECLARE
  v_admin jsonb; v_pct jsonb; v_short jsonb; v_stranger jsonb; v_field jsonb; v_uid uuid; v_n bigint;
BEGIN
  IF has_function_privilege('anon', 'ops.portal_search(text)', 'execute') THEN RAISE EXCEPTION 'verify_fail: anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.portal_search(text)', 'execute') THEN RAISE EXCEPTION 'verify_fail: authenticated cannot execute'; END IF;

  -- An admin finds the test client by its exact code, first (positive control).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_admin := ops.portal_search('112-ya');
  v_pct := ops.portal_search('%%');
  v_short := ops.portal_search('1');
  RESET ROLE;
  IF v_admin->'clients'->0->>'code' IS DISTINCT FROM '112-YA' THEN RAISE EXCEPTION 'verify_fail: first client %', v_admin->'clients'->0; END IF;
  IF NOT (v_admin ? 'visits' AND v_admin ? 'requests' AND v_admin ? 'people') THEN RAISE EXCEPTION 'verify_fail: admin groups %', v_admin; END IF;

  -- A percent sign is text, not a pattern.
  SELECT count(*) INTO v_n FROM public.clients c WHERE position('%%' in c.client_code) > 0 OR position('%%' in c.name) > 0;
  IF jsonb_array_length(v_pct->'clients') <> v_n THEN RAISE EXCEPTION 'verify_fail: %% found % clients, literally %', jsonb_array_length(v_pct->'clients'), v_n; END IF;
  IF v_short <> '{}'::jsonb THEN RAISE EXCEPTION 'verify_fail: one character returned %', v_short; END IF;

  -- Someone who is not staff gets nothing.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000999', 'email', 'nobody@example.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_stranger := ops.portal_search('112-ya');
  RESET ROLE;
  IF v_stranger <> '{}'::jsonb THEN RAISE EXCEPTION 'verify_fail: a stranger sees %', v_stranger; END IF;

  -- An active field person, who by the group defaults opens none of these apps, gets no group.
  SELECT u.id INTO v_uid FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email)
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field' ORDER BY e.id LIMIT 1;
  IF v_uid IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', (SELECT email FROM auth.users WHERE id = v_uid), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    v_field := ops.portal_search('112-ya');
    RESET ROLE;
    IF v_field ? 'clients' OR v_field ? 'people' THEN RAISE EXCEPTION 'verify_fail: field sees %', v_field; END IF;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
END $verify$;

COMMIT;
