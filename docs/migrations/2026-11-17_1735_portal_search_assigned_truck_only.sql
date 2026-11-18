-- =============================================================================
-- 2026-11-17_1735_portal_search_assigned_truck_only.sql
--
-- WHAT: the Ops Portal's Search stops naming the Calendar's GUESSED truck as a visit's truck (Trello #225).
--   ops.portal_search(text): each visit in "visits" carries "truck" only when the visit's own truck is ASSIGNED
--   (ops.v_calendar_visit vehicle_source 'assigned': visits.vehicle_id is set). For a visit whose truck is only the
--   Calendar's guess (vehicle_source 'default': visits.vehicle_id is empty and the view fills in the usual truck) or
--   that has no truck at all ('none'), "truck" is null. "driver" is unchanged: the view's driver_name comes from the
--   visit's own assignment (visit_assignments, an inspection on its ASSIGNED truck, else assigned_driver_id), never
--   from the guessed truck. Nothing else in the answer
--   moves: clients, requests, people, properties, invoices and quotes are untouched, and so is which visit is picked.
--   The portal's search.tsx already joins only what it gets (truck and driver, " with " between them), so with a null
--   truck it shows the driver alone, or nothing; the portal side moves that join into visitCrew() and pins it with a
--   test (same card). ops.portal_search has no other caller.
--
-- WHY: Fred's rule for the driver's own truck (Trello #224, 2026-11-17): never present a guess as the truck. Search
--   broke it the same way the Home did (fixed in 2026-11-17_1615): visit 8597 (320-MGF) read "Moises with Grecia",
--   where Moises was only the Calendar's guess and GPS put the truck David at the site. 1615's header named this
--   sibling and left it for its own card.
--
-- HOW: the body is the LIVE pg_get_functiondef text with two anchored edits (each anchor found exactly once, by a
--   script), md5-guarded 4af9a78cd5a0d894e9328d050e7a32b2 -> 67954dcf07b46c5bfc114eb93e2c23ca:
--   "v.truck_name AS truck" became "CASE WHEN v.vehicle_source = 'assigned' THEN v.truck_name END AS truck", plus a
--   dated comment above the visits block. Diff this body against the rollback file, which holds the previous one
--   verbatim.
--
-- REACH, measured on Prod 2026-11-17 about 5:30 PM ET, wider than the card's 4 visits:
--   Search shows ONE visit per client, for the first 3 clients found (the next scheduled one, else the last completed
--   one). Of the 298 clients with such a visit, 140 show a guessed truck today, 156 an assigned truck, 2 no truck.
--   Of the 140, 3 read "<guessed truck> with <driver>" (5836 777-YA, 6857 284-GA, 8021 322-IRO, all past completed visits) and 137 show
--   the guessed truck ALONE (future scheduled visits with no driver yet, mostly "Moises"). All 140 lose the truck name.
--   The card's 4 visits (8597, 9080, 9213, 9220) are not in any Search answer today: 8597 and 9220 were completed today
--   (Search shows a visit of today only while it is scheduled), 9080 was skipped and 9213 is past and still scheduled.
--   320-MGF's answer is now 8598 (2026-11-21, guessed David, no driver).
--   ⚠ For the 137 future visits Search will show no truck while the Calendar still draws them in the guessed truck's
--   lane. That is the rule as asked; a "usually Moises" wording would need a new field and a portal change.
--
-- ACCESS: unchanged. SECURITY DEFINER with an empty search_path; CREATE OR REPLACE keeps the grants (authenticated and
--   service_role, never anon or PUBLIC; VERIFY pins the ACL).
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- REHEARSED, rolled back on Prod on 2026-11-17 about 5:40 PM ET (draft, NOT applied):
--   this file: VERIFY passes (12 clients searched, 12 visits: the 7 on a guessed truck, 3 of them with a driver, came
--   back with no truck, the 4 on an assigned truck kept it, 320-MGF's 8598 has none), and of every function in ops,
--   public, client, hr, derm and customer only ops.portal_search(text) moved;
--   the same file with the OLD body as a control FAILS that VERIFY (all 7 guessed visits named, 8021 "Moises" with Mark);
--   the new body beside the live one, for 294 client codes (every client with a Search visit and a code; 4 have no
--   code) plus 10 broad terms: 150 answers changed, every one exactly the old answer with the guessed visits' truck set
--   to null (159 trucks nulled, 160 kept, 0 answers different in any other way);
--   this file then the rollback file: the body is back byte for byte (md5 4af9a78c...) with the same grants, and no
--   function differs from before; the rollback file alone against today's body is refused by its guard;
--   scripts/checks/portal_search_assigned_truck.sql fails on today's body and passes after this file.
-- ON APPLY, in the same cycle: claim ops.portal_search in WORKING-NOW.md first (only the session named Supabase works
--   on the portal). Afterwards update Supabase CLAUDE.md (the "THE MY WORK DOOR" portal_home bullet says the flaw is
--   still in portal_search; and the app-source attribution line that lists ops.portal_search), the portal's
--   docs/08-changelog.md (its docs/02-architecture.md Search row and docs/04-backend.md line are drafted beside the
--   search.tsx change), and memory, and run the standing check scripts/checks/portal_search_assigned_truck.sql (it fails before this is
--   applied whenever Search's answer holds a guessed truck).
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-17_1735_portal_search_assigned_truck_only_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure)) <> '4af9a78cd5a0d894e9328d050e7a32b2' THEN
    RAISE EXCEPTION 'guard: ops.portal_search(text) changed since this was written (md5 %)', md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.v_calendar_visit'::regclass AND attname = 'vehicle_source' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'guard: ops.v_calendar_visit has no vehicle_source';
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
    -- 2026-11-17 (Trello #225): "truck" is the visit's ASSIGNED truck only (vehicle_source 'assigned'), never the
    -- Calendar's guess for a visit with no truck ('default'), so Search never reads "<guessed truck> with <driver>"
    -- (visit 8597: "Moises with Grecia", GPS said David). A visit with no assigned truck returns truck null.
    v_out := v_out || jsonb_build_object('visits', (
      SELECT coalesce(jsonb_agg(to_jsonb(y) ORDER BY array_position(v_ids, y.client_id)), '[]'::jsonb)
        FROM (
          SELECT DISTINCT ON (v.client_id)
                 v.id, v.client_id, v.client_code, v.client_name, v.visit_date, v.start_at, v.is_all_day,
                 coalesce(v.service_label, v.service_type) AS service,
                 CASE WHEN v.vehicle_source = 'assigned' THEN v.truck_name END AS truck, v.driver_name AS driver,
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
DECLARE
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_uid uuid; v_email text; v_code text; v_codes text[]; v_got jsonb := '[]'::jsonb;
  v_rows bigint; v_found bigint; v_guess bigint; v_guess_driver bigint; v_assigned bigint; v_none bigint; v_bad jsonb;
BEGIN
  -- Grants did not move: signed-in staff and the server, never anon or PUBLIC.
  IF has_function_privilege('anon', 'ops.portal_search(text)', 'execute')
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.portal_search(text)'::regprocedure)
        IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'verify_fail: the grants on ops.portal_search moved';
  END IF;

  -- Whom to search for: Search's own pick per client (the next scheduled visit, else the last completed one), a few of
  -- each kind: on a guessed truck with a driver (the "<truck> with <driver>" case), on a guessed truck with no driver,
  -- on an assigned truck, on no truck. Plus 320-MGF, the card's client. Codes are searched exactly, so each is the
  -- first client found and its visit is in the answer.
  WITH pick AS (
    SELECT DISTINCT ON (v.client_id) v.client_code, v.vehicle_source, v.driver_name IS NOT NULL AS has_driver
      FROM ops.v_calendar_visit v
     WHERE (v.visit_date >= v_today AND v.visit_status = 'scheduled') OR (v.visit_date < v_today AND v.visit_status = 'completed')
     ORDER BY v.client_id, (v.visit_date >= v_today) DESC, CASE WHEN v.visit_date >= v_today THEN v.visit_date END ASC,
              v.visit_date DESC, v.start_at),
  ranked AS (
    SELECT p.client_code, p.vehicle_source, p.has_driver,
           row_number() OVER (PARTITION BY p.vehicle_source, p.has_driver ORDER BY p.client_code) AS n
      FROM pick p WHERE length(p.client_code) BETWEEN 2 AND 80)
  SELECT array_agg(DISTINCT r.client_code) INTO v_codes
    FROM (SELECT r.client_code FROM ranked r
           WHERE r.n <= CASE WHEN r.vehicle_source = 'default' AND r.has_driver THEN 4
                             WHEN r.vehicle_source = 'default' THEN 3
                             WHEN r.vehicle_source = 'assigned' THEN 2
                             ELSE 1 END
          UNION ALL SELECT '320-MGF') r;

  -- Search, read as the first active admin with a confirmed sign-in.
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL
     AND (u.banned_until IS NULL OR u.banned_until <= now())
   ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no admin with a sign-in to search as'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  FOREACH v_code IN ARRAY v_codes LOOP
    v_got := v_got || coalesce(ops.portal_search(v_code) -> 'visits', '[]'::jsonb);
  END LOOP;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  -- Every visit Search returned: "truck" is the view's truck when vehicle_source = 'assigned' and null otherwise; "driver"
  -- is the view's driver as before. The rule leans on what vehicle_source means: 'assigned' = the visit's own truck,
  -- 'default' = no truck and the Calendar's guess, 'none' = no truck and no guess.
  SELECT count(*), count(v.id),
         count(*) FILTER (WHERE v.vehicle_source = 'default' AND v.truck_name IS NOT NULL),
         count(*) FILTER (WHERE v.vehicle_source = 'default' AND v.truck_name IS NOT NULL AND v.driver_name IS NOT NULL),
         count(*) FILTER (WHERE v.vehicle_source = 'assigned' AND v.truck_name IS NOT NULL),
         count(*) FILTER (WHERE v.vehicle_source = 'none'),
         jsonb_agg(jsonb_build_object('id', g.x->>'id', 'source', v.vehicle_source, 'got_truck', g.x->>'truck', 'view_truck', v.truck_name,
                                      'got_driver', g.x->>'driver', 'view_driver', v.driver_name))
           FILTER (WHERE v.id IS NULL
                      OR (g.x->>'truck') IS DISTINCT FROM CASE WHEN v.vehicle_source = 'assigned' THEN v.truck_name END
                      OR (g.x->>'driver') IS DISTINCT FROM v.driver_name
                      OR v.vehicle_source IS DISTINCT FROM CASE WHEN v.assigned_vehicle_id IS NOT NULL THEN 'assigned'
                                                                WHEN v.vehicle_id IS NOT NULL THEN 'default' ELSE 'none' END)
    INTO v_rows, v_found, v_guess, v_guess_driver, v_assigned, v_none, v_bad
    FROM jsonb_array_elements(v_got) g(x)
    LEFT JOIN ops.v_calendar_visit v ON v.id = (g.x->>'id')::bigint;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'verify_fail: Search names a truck that is not the visit''s assigned truck, or moved a driver: %', v_bad;
  END IF;
  -- The rule was exercised both ways: a guessed truck came back null, and an assigned truck came back named.
  IF v_guess = 0 OR v_assigned = 0 THEN
    RAISE EXCEPTION 'verify_fail: not tested (% visits on a guessed truck, % on an assigned truck in % answers)', v_guess, v_assigned, v_rows;
  END IF;

  -- Last: the installed body is exactly the reviewed one.
  IF md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure)) <> '67954dcf07b46c5bfc114eb93e2c23ca' THEN
    RAISE EXCEPTION 'verify_fail: the installed body is not the reviewed one (md5 %)', md5(pg_get_functiondef('ops.portal_search(text)'::regprocedure));
  END IF;

  PERFORM set_config('verify.summary', jsonb_build_object('searched', cardinality(v_codes), 'visits', v_rows,
    'guessed', v_guess, 'guessed_with_driver', v_guess_driver, 'assigned', v_assigned, 'no_truck', v_none,
    'mgf_320', (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_got) x WHERE x->>'client_code' = '320-MGF'))::text, true);
END $verify$;

COMMIT;
