-- ============================================================================
-- 2026-09-24_1347_derm_get_visit_report.sql
-- ============================================================================
-- THE ASK
--   Fred, 2026-09-24: "the idea is to make the report at the DERM App too, for whatever visit we
--   want. The FP App is for the clients so it's only for the DERM Required visits." He then chose:
--   the DERM App gets its own report page, and Download Report stays a one-click PDF file.
--
-- WHAT THIS IS
--   The staff data RPC behind the DERM Tracker's own copy of the Service Report
--   (derm.unclogme.app/visits/$visitId/report). For ANY completed, non-deleted visit, DERM-required
--   or not, it returns the JSON the Field Portal report page consumes:
--     work_order (with fog_documents inside it), photos, permits, gdo_reports, inspection_items,
--     recommendations                     <- customer.get_work_order_internal(public_id), verbatim
--     client                              <- to_jsonb(customer.clients row) of the VISIT's client,
--                                            the same object customer.get_client_portal returns
--     derm_required                       <- coalesce(visits.derm_required, true); the page shows
--                                            the "verify at fp.unclogme.app" footer only when true
--   NULL for a missing, deleted or not-completed visit (the page shows "Report not available").
--
-- CALLERS
--   1. The DERM report route, signed in as staff (role authenticated).
--   2. The edge fn derm-visit-report, as service_role: it hands this JSON to the pdf-service
--      (POST /generate/derm-visit-report, 0.7.0), which answers the page's own
--      POST /rest/v1/rpc/get_visit_report (Content-Profile: derm) inside its headless browser. That
--      browser has no session and, by the grants below, could not call this function itself.
--
-- DESIGN NOTES / TRAPS
--   * REUSES customer.get_work_order_internal (2026-09-24_1150), never retypes it: the FP report
--     logic stays in ONE place. This function only picks the visit and adds 'client' and
--     'derm_required'.
--   * 'client' is looked up by the VISIT's client_id, never by slug. The FP page takes the client
--     from the URL slug, which is how /293-alc/visit/qkmi1uMYoE/report shows 293-ALC over a 306-16
--     visit; this payload cannot do that. And 4 clients with completed visits (6 visits, all non-DERM,
--     e.g. Yes Market North Miami) have NO client_code and NO slug, so a slug lookup finds nothing.
--   * visit_num: the twin numbers a visit among ALL the client's completed visits, FP among the
--     DERM-required ones. The report does not render visit_num.
--   * Cost: ~210 ms per call, nearly all of it get_work_order_internal (a window over every completed
--     visit). Called ONCE, in plpgsql steps (a lateral + filter evaluated it twice, ~400 ms).
--   * Staff gate in the body, the house pattern of client.* and public.set_visit_status
--     (auth.uid() + @ayache.com / @unclogme.com). service_role passes (the edge fn). Direct SQL
--     (no request.jwt.claims: migrations, audits) passes; PostgREST always sets claims.
--     Today authenticated == staff by CONFIG (the before-user-created hook limits sign-ups to the two
--     domains, anonymous sign-ins are off); the body check keeps holding if that ever changes.
--   * 🛑 derm has NO default ACL for functions, so a new one gets Postgres' EXECUTE TO PUBLIC, and anon
--     has USAGE on the exposed derm schema. REVOKE BY NAME, then assert it in VERIFY.
--   * Rule 8 (audit): read-only function, no table, nothing to audit.
-- ============================================================================

CREATE OR REPLACE FUNCTION derm.get_visit_report(p_visit_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_public_id     text;
  v_client_id     bigint;
  v_derm_required boolean;
  v_out           jsonb;
BEGIN
  IF nullif(current_setting('request.jwt.claims', true), '') IS NOT NULL
     AND coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'authentication required' USING errcode = '28000';
    END IF;
    IF lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@ayache.com'
       AND lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@unclogme.com' THEN
      RAISE EXCEPTION 'not a staff account' USING errcode = '42501';
    END IF;
  END IF;

  SELECT v.public_id, v.client_id, coalesce(v.derm_required, true)
    INTO v_public_id, v_client_id, v_derm_required
    FROM public.visits v
   WHERE v.id = p_visit_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.client_id IS NOT NULL;
  IF v_public_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_out := customer.get_work_order_internal(v_public_id);
  IF v_out IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_out || jsonb_build_object(
    'client', (SELECT to_jsonb(c) FROM customer.clients c
                WHERE c.id = customer.uuid_from_bigint(v_client_id)
                LIMIT 1),  -- ponytail: LIMIT 1 guards a future duplicate row in customer.clients (0 today)
    'derm_required', v_derm_required);
END
$function$;

COMMENT ON FUNCTION derm.get_visit_report(bigint) IS
  'STAFF-ONLY Service Report data for ANY completed visit (DERM-required or not): '
  'customer.get_work_order_internal(public_id) plus the visit''s customer.clients row as ''client'' '
  'and derm_required. NULL for a missing, deleted or not-completed visit. Callers: DERM Tracker '
  'report route (staff JWT), edge fn derm-visit-report (service_role).';

REVOKE ALL ON FUNCTION derm.get_visit_report(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.get_visit_report(bigint) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------- VERIFY
DO $verify$
DECLARE
  r record; j jsonb; n_derm int := 0; n_nonderm int := 0; n_nocode int := 0; mism int := 0; v_bad bigint;
BEGIN
  -- 1. Grants: anon and PUBLIC cannot execute, staff and the edge fn can.
  IF has_function_privilege('anon', 'derm.get_visit_report(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can execute derm.get_visit_report';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
              WHERE p.oid = 'derm.get_visit_report(bigint)'::regprocedure AND x.grantee = 0) THEN
    RAISE EXCEPTION 'PUBLIC still holds EXECUTE on derm.get_visit_report';
  END IF;
  IF NOT has_function_privilege('authenticated', 'derm.get_visit_report(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.get_visit_report(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated or service_role cannot execute derm.get_visit_report';
  END IF;

  -- 2. Parity on 10 DERM-required + 10 non-DERM recent completed visits + every visit whose client has
  --    no code. The client is compared BY ID (a slug lookup is blind to the no-code clients).
  FOR r IN SELECT * FROM (
             (SELECT v.id, v.public_id, v.client_id, v.derm_required, false AS nocode FROM public.visits v
               WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.client_id IS NOT NULL
                 AND coalesce(v.derm_required, true) ORDER BY v.visit_date DESC, v.id DESC LIMIT 10)
             UNION ALL
             (SELECT v.id, v.public_id, v.client_id, v.derm_required, false FROM public.visits v
               WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.client_id IS NOT NULL
                 AND v.derm_required = false ORDER BY v.visit_date DESC, v.id DESC LIMIT 10)
             UNION ALL
             (SELECT v.id, v.public_id, v.client_id, v.derm_required, true FROM public.visits v
               JOIN public.clients c ON c.id = v.client_id
               WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND c.client_code IS NULL)) s
  LOOP
    IF r.nocode THEN n_nocode := n_nocode + 1;
    ELSIF coalesce(r.derm_required, true) THEN n_derm := n_derm + 1;
    ELSE n_nonderm := n_nonderm + 1; END IF;
    j := derm.get_visit_report(r.id);
    IF j IS NULL
       OR (j - 'client' - 'derm_required') IS DISTINCT FROM customer.get_work_order_internal(r.public_id)
       OR (j -> 'client') IS DISTINCT FROM (SELECT to_jsonb(c) FROM customer.clients c
                                              WHERE c.id = customer.uuid_from_bigint(r.client_id))
       OR (j -> 'client') IS NULL
       OR (j ->> 'derm_required')::boolean IS DISTINCT FROM coalesce(r.derm_required, true) THEN
      mism := mism + 1;
    END IF;
  END LOOP;
  IF n_derm < 10 OR n_nonderm < 10 OR n_nocode < 1 OR mism <> 0 THEN
    RAISE EXCEPTION 'parity: % DERM + % non-DERM + % no-code checked, % differ', n_derm, n_nonderm, n_nocode, mism;
  END IF;

  -- 3. Refusals: a not-completed visit, a deleted visit, a missing id all return NULL.
  SELECT id INTO v_bad FROM public.visits WHERE visit_status <> 'completed' AND deleted_at IS NULL LIMIT 1;
  IF v_bad IS NULL OR derm.get_visit_report(v_bad) IS NOT NULL THEN
    RAISE EXCEPTION 'not-completed visit % was not refused (or none found)', v_bad;
  END IF;
  SELECT id INTO v_bad FROM public.visits WHERE visit_status = 'completed' AND deleted_at IS NOT NULL LIMIT 1;
  IF v_bad IS NOT NULL AND derm.get_visit_report(v_bad) IS NOT NULL THEN
    RAISE EXCEPTION 'deleted visit % was not refused', v_bad;
  END IF;
  IF derm.get_visit_report(-1) IS NOT NULL THEN
    RAISE EXCEPTION 'a missing visit id returned data';
  END IF;

  -- 4. The body gate, under simulated PostgREST claims (transaction-local, cleared after).
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  BEGIN
    PERFORM derm.get_visit_report(8117);
    RAISE EXCEPTION 'gate let an anon request through';
  EXCEPTION WHEN invalid_authorization_specification THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims',
    '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","email":"someone@gmail.com"}', true);
  BEGIN
    PERFORM derm.get_visit_report(8117);
    RAISE EXCEPTION 'gate let a non-staff account through';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims',
    '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","email":"x@unclogme.com.evil.io"}', true);
  BEGIN
    PERFORM derm.get_visit_report(8117);
    RAISE EXCEPTION 'gate let a look-alike domain through';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims',
    '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000001","email":"Ops@UnclogMe.com"}', true);
  IF derm.get_visit_report(8117) IS NULL THEN RAISE EXCEPTION 'staff account got no report for 8117'; END IF;
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  j := derm.get_visit_report(8117);
  PERFORM set_config('request.jwt.claims', '', true);
  IF j IS NULL OR j -> 'client' ->> 'client_code' IS DISTINCT FROM '235-LOU'
     OR (j ->> 'derm_required')::boolean IS DISTINCT FROM false
     OR jsonb_array_length(j -> 'photos') < 1 THEN
    RAISE EXCEPTION 'service_role: 8117 (235-LOU, not DERM-required) came back wrong';
  END IF;
  j := derm.get_visit_report(8088);
  IF j IS NULL OR (j ->> 'derm_required')::boolean IS DISTINCT FROM true
     OR j -> 'client' ->> 'client_code' IS DISTINCT FROM '236-LOU'
     OR jsonb_array_length(j -> 'gdo_reports') < 1 THEN
    RAISE EXCEPTION '8088 (236-LOU, DERM-required, GDO filing) came back wrong';
  END IF;

  RAISE NOTICE 'OK: % DERM + % non-DERM + % no-code visits match get_work_order_internal and the client by id; refusals and gate hold',
    n_derm, n_nonderm, n_nocode;
END
$verify$;
