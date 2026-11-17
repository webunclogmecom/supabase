-- =============================================================================
-- 2026-11-16_1915_portal_home_by_role.sql
--
-- WHAT: what the Ops Portal's new Home by role reads (Trello #210 IGscwHn7):
--   1. ops.portal_waiting() gains four counts: late_today and requests_open (Visit Calendar), reviews_pending (Admin
--      Review), manifests_need_someone (DERM Tracker). The bell and the Home's "Needs you" list read this one answer.
--   2. NEW ops.portal_home(): today (visits, done, left, late, skipped), today's trucks with their crew, the next 7 days,
--      and for the Admin group only a "business" part (invoices sent this month and the same days last month, past due
--      with the top three clients, gallons pumped with the trucks that were measured). No money for anyone else.
--   3. NEW ops.portal_my_work(): the signed-in person's OWN day (their visits by the Calendar's crew rule, the truck of
--      those visits with its last tank readings, the forms assigned to them, visits finished in the last 7 days).
--   4. public.fn_request_gate(): one door, exactly POST /rpc/portal_my_work with content-profile ops, so a person with no
--      app open (the Field group) can read their own day.
--
-- WHY: Fred, 2026-11-16: "creating a dashboard, for the home, so we stop seeing that, i guess we would need like
--      different home views depending on the role of the staff member". His answer to round 1
--      (mockups/2026-11-16-home-dashboard.html, local): "Go with recommended but HO1, it doesn't needs to see the like
--      revenue and stuff like that, for the "Day value"". So HF1 (driver), HO1 with no money (office), HA1 (admin = the
--      office's Home plus the Business band), FB no, and the 13 defaults, among them "bell" (Needs you is the bell's own
--      answer, four counts added) and "fieldread" (the driver's Home reads only their own work). Row in
--      docs/decisions-to-build.md.
--
-- HOW: 1 and 4 are the LIVE pg_get_functiondef bodies with ONE anchored edit each, made by a script (the anchor must
--   occur exactly once), md5-guarded below: portal_waiting 658ee63214dbbf326a1874122d750a99 -> 14253eb27f0899428a86e4f72b8d6d02, fn_request_gate a54d74e1398124e3f62b2419fd54b084 -> 579b255909b5a6c323bd424e0f377861.
--   Nothing else in either body moved. manifests_need_someone reads derm.fn_manifest_row_states_core(), the one core the
--   Manifests list reads through derm.manifest_row_states(), with the list's own "Needs someone" rule (a test row never;
--   any place amber or red). Invoices count by sent_at (our copy's created_at is the day the copy was made), voided and
--   destroyed left out. The Field day starts at 6 AM ET: a night truck works one visit date from about 9 PM to 5 AM.
--
-- ACCESS: all three SECURITY DEFINER, empty search_path, counts and the caller's own rows only.
--   portal_waiting: unchanged grants. portal_home: each part behind the bell's own rule (an app switched on at None is
--   closed), business behind group = admin as well. portal_my_work: the caller from hr.fn_access_caller() (a confirmed
--   sign-in, one active employee); returns no amount, note, lock box or gate code; forms through
--   client.fn_intake_assigned_to_me. EXECUTE: authenticated and service_role only (REVOKE ALL from PUBLIC and anon).
--   The gate door opens nothing else: another function, another schema header, or a GET is still refused (VERIFY).
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- REHEARSED: rolled back three ways first: this file (VERIFY passes), and two controls that must FAIL, the old
--   portal_waiting body (no new keys) and the old gate body (the door refused).
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-16_1915_portal_home_by_role_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '658ee63214dbbf326a1874122d750a99' THEN
    RAISE EXCEPTION 'guard: ops.portal_waiting() changed since this was written (md5 %)', md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure));
  END IF;
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> 'a54d74e1398124e3f62b2419fd54b084' THEN
    RAISE EXCEPTION 'guard: public.fn_request_gate() changed since this was written (md5 %)', md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure));
  END IF;
  IF to_regprocedure('ops.portal_home()') IS NOT NULL OR to_regprocedure('ops.portal_my_work()') IS NOT NULL THEN
    RAISE EXCEPTION 'guard: ops.portal_home() or ops.portal_my_work() already exists';
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION ops.portal_waiting()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_out jsonb := '{}'::jsonb;
  v_admin jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'call_first', (SELECT count(*) FROM ops.visit_requests r
                      WHERE r.deleted_at IS NULL AND r.status = 'open' AND r.call_required),
      'time_on_site', jsonb_array_length(coalesce(
        public.fn_time_on_site_gaps(((now() AT TIME ZONE 'America/New_York')::date - 1))->'visits', '[]'::jsonb)));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_admin := public.fn_admin_review_pending();
    v_out := v_out || jsonb_build_object(
      'photos_unsorted', coalesce((v_admin->'photos'->>'count')::int, 0),
      'city_emails', jsonb_array_length(coalesce(v_admin->'city', '[]'::jsonb)));
  END IF;

  IF NOT 'stamp_studio' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('stamp_sheets', jsonb_array_length(coalesce(derm.fn_stamp_open_sheets(), '[]'::jsonb)));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('unopened_emails', jsonb_array_length(coalesce(public.fn_unopened_emails(now())->'emails', '[]'::jsonb)));
  END IF;

  -- 2026-11-09_1230: Site file versions waiting for approval, only for someone who can approve them (Picture Planner open,
  -- and "Approve site files" by the one approver rule, public.fn_page_approver_ids()). The same versions the
  -- #apps-notifications post announces (public.fn_slack_event_claim, version_waiting): neither approved nor rejected, on a
  -- real client (test clients left out the same way), on a property not removed, and above the property's live version,
  -- because a version below the live one can no longer be decided (Picture Planner rules 20 and 27).
  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    v_out := v_out || jsonb_build_object('site_files', (
      SELECT count(*)
        FROM public.property_pages pg
        JOIN public.properties p ON p.id = pg.property_id
       WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL AND p.deleted_at IS NULL
         AND pg.version > coalesce((SELECT max(l.version) FROM public.property_pages l
                                     WHERE l.property_id = pg.property_id AND l.approved_at IS NOT NULL), 0)
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)));
  END IF;

  -- 2026-11-16 (Trello #210, Fred's default "bell"): the Ops Portal's Home lists "Needs you" from this same answer, so the
  -- bell and the Home can never disagree. Four counts added, each behind the app that holds its list:
  --   late_today, requests_open (Visit Calendar): today's visits past their job's due date (late_status 'late', the
  --     Calendar's red mark; ops.portal_home's "late" is the same predicate), and every open visit request (call_first
  --     stays: the Home shows it as the detail of this line);
  --   reviews_pending (Admin Review): the review queue's rule (completed, in scope, dated today or before, pending);
  --   manifests_need_someone (DERM Tracker): the Manifests list's "Needs someone" rows, read from the one core
  --     (derm.fn_manifest_row_states_core): a test row never counts, a row counts when any place is amber or red.
  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'late_today', (SELECT count(*) FROM ops.v_calendar_visit v
                      WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
                        AND v.visit_status <> 'cancelled' AND v.late_status = 'late'),
      'requests_open', (SELECT count(*) FROM ops.visit_requests r WHERE r.deleted_at IS NULL AND r.status = 'open'));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('reviews_pending', (
      SELECT count(*) FROM public.visits_with_review w
       WHERE w.visit_status = 'completed' AND w.in_review_scope
         AND w.visit_date <= (now() AT TIME ZONE 'America/New_York')::date AND w.review_status = 'pending'));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('manifests_need_someone', (
      SELECT count(*) FROM jsonb_each(derm.fn_manifest_row_states_core()) e
       WHERE NOT coalesce((e.value->>'test')::boolean, false)
         AND EXISTS (SELECT 1 FROM unnest(ARRAY['papers', 'stamps', 'copies', 'city', 'visit', 'email']) p(place)
                      WHERE e.value->p.place->>'s' IN ('warn', 'bad'))));
  END IF;

  RETURN v_out;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.fn_request_gate()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 2026-10-21_0145: PostgREST pre-request gate (pgrst.db_pre_request). Access phase 6.
-- SECURITY INVOKER on purpose: current_user must be the request role (anon / authenticated / service_role);
-- inside a SECURITY DEFINER body current_user is the owner and the gate would pass everyone (caught by VERIFY).
declare v_path text; v_all_on boolean;
begin
  perform set_config('response.headers', '[{"x-access-gate": "pass"}]', true);
  if current_user is distinct from 'authenticated' then return; end if;
  v_path := coalesce(current_setting('request.path', true), '');
  if v_path in ('/rpc/get_my_access') then return; end if;
  v_all_on := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal', '') in ('all-on', 'refuse-me');
  if (nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal' = 'refuse-me' then v_all_on := null; end if;  -- 2026-10-21_0215 live negative probe
  if v_all_on is not null and hr.fn_any_app_open(v_all_on) then return; end if;
  -- 2026-10-27_2130 (Trello AIwCYcmn): the Forms door. A "See submitted forms" person with no top-level View reaches
  -- exactly two client functions that return jsonb, never a view path (embedding would bring properties rows).
  -- The schema header is the one PostgREST uses for the method (GET/HEAD Accept-Profile, else Content-Profile), with no
  -- fallback, so a same-named function in another exposed schema can never be reached through this door.
  -- 2026-11-04_1930: and get_intake_link, which itself refuses any form not assigned to the caller.
  if v_all_on is not null and v_path in ('/rpc/get_intake', '/rpc/list_intake_forms', '/rpc/get_intake_link')
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>
           case when coalesce(current_setting('request.method', true), '') in ('GET', 'HEAD') then 'accept-profile' else 'content-profile' end, '') = 'client'
     and hr.fn_pp_forms_open() then
    return;
  end if;
  -- 2026-11-05_0310: the Photo door. A person with no app open may set their own photo from the Ops Portal's Profile page.
  -- This one function, in schema hr, by POST only, and hr.set_employee_photo itself refuses anyone else's photo.
  if v_all_on is not null and v_path = '/rpc/set_employee_photo'
     and coalesce(current_setting('request.method', true), '') = 'POST'
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'content-profile', '') = 'hr' then
    return;
  end if;
  -- 2026-11-16 (Trello #210): the My work door. A person with no app open (the Field group) reads their OWN day on the
  -- Ops Portal's Home. This one function, in schema ops, by POST only; ops.portal_my_work returns only the caller's own
  -- visits, truck, forms and count, and is not a view path (nothing can be embedded through it).
  if v_all_on is not null and v_path = '/rpc/portal_my_work'
     and coalesce(current_setting('request.method', true), '') = 'POST'
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'content-profile', '') = 'ops' then
    return;
  end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$
;

CREATE OR REPLACE FUNCTION ops.portal_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-16 (Trello #210, Fred's picks HO1 and HA1): what the Ops Portal's Home shows beside "Needs you", which is
-- ops.portal_waiting(), the bell's own answer. Counts and totals only, by the bell's access rule (v_closed):
--   today, trucks, week: for a person who can open the Visit Calendar. No money (Fred: "it doesn't needs to see the
--                        like revenue and stuff like that, for the Day value").
--   business:            the Admin group only, each part by the app that holds it (invoices and past due: Client App;
--                        pumped gallons: Admin Review). Invoices count by the date Jobber SENT them (our copy's
--                        created_at is the day the copy was made), voided and destroyed ones left out.
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_now timestamp := now() AT TIME ZONE 'America/New_York';
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_month date := date_trunc('month', now() AT TIME ZONE 'America/New_York')::date;
  v_prev date := (date_trunc('month', now() AT TIME ZONE 'America/New_York') - interval '1 month')::date;
  v_prev_end date := ((now() AT TIME ZONE 'America/New_York') - interval '1 month')::date;  -- the same day of last month
  v_out jsonb;
  v_biz jsonb := '{}'::jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;
  v_out := jsonb_build_object('date', v_today, 'month_start', v_month, 'prev_start', v_prev, 'prev_end', v_prev_end);

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    -- Today and its trucks, from one read of the day. "late" is the same predicate as portal_waiting's late_today.
    WITH d AS MATERIALIZED (
      SELECT v.vehicle_id, v.truck_name, v.truck_color, v.visit_status, v.late_status, v.start_at, v.driver_name, v.driver_color
        FROM ops.v_calendar_visit v
       WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled'
    )
    SELECT v_out || jsonb_build_object(
      'today', (SELECT jsonb_build_object(
          'visits', count(*),
          'done', count(*) FILTER (WHERE d.visit_status = 'completed'),
          'skipped', count(*) FILTER (WHERE d.visit_status = 'skipped'),
          'left', count(*) FILTER (WHERE d.visit_status = 'scheduled'),
          'late', count(*) FILTER (WHERE d.late_status = 'late'))
          FROM d),
      'trucks', coalesce((SELECT jsonb_agg(t.j ORDER BY t.name) FROM (
          SELECT coalesce(d.truck_name, 'No truck') AS name,
                 jsonb_build_object(
                   'name', coalesce(d.truck_name, 'No truck'),
                   'color', d.truck_color,
                   'visits', count(*),
                   'done', count(*) FILTER (WHERE d.visit_status = 'completed'),
                   'left', count(*) FILTER (WHERE d.visit_status = 'scheduled'),
                   'first_at', min(d.start_at) FILTER (WHERE d.visit_status = 'scheduled'),
                   'crew', coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_object('name', c.driver_name, 'color', c.driver_color))
                                       FROM d c WHERE c.vehicle_id IS NOT DISTINCT FROM d.vehicle_id AND c.driver_name IS NOT NULL), '[]'::jsonb)) AS j
            FROM d GROUP BY d.vehicle_id, d.truck_name, d.truck_color) t), '[]'::jsonb))
      INTO v_out;

    v_out := v_out || jsonb_build_object('week', (
      SELECT jsonb_agg(jsonb_build_object('date', s.day, 'visits', coalesce(c.n, 0)) ORDER BY s.day)
        FROM (SELECT v_today + i AS day FROM generate_series(0, 6) i) s
        LEFT JOIN (SELECT v.visit_date, count(*) AS n FROM ops.v_calendar_visit v
                    WHERE v.visit_date BETWEEN v_today AND v_today + 6 AND v.visit_status <> 'cancelled'
                    GROUP BY 1) c ON c.visit_date = s.day));
  END IF;

  IF v_access->>'group' = 'admin' THEN
    IF NOT 'client_app' = ANY (v_closed) THEN
      v_biz := v_biz || jsonb_build_object(
        'invoices', (SELECT jsonb_build_object(
            'count', count(*) FILTER (WHERE x.day >= v_month),
            'total', coalesce(sum(x.total) FILTER (WHERE x.day >= v_month), 0),
            'prev_count', count(*) FILTER (WHERE x.day BETWEEN v_prev AND v_prev_end),
            'prev_total', coalesce(sum(x.total) FILTER (WHERE x.day BETWEEN v_prev AND v_prev_end), 0))
            FROM (SELECT i.total, (i.sent_at AT TIME ZONE 'America/New_York')::date AS day
                    FROM client.invoices i
                   WHERE i.sent_at >= (v_prev::timestamp AT TIME ZONE 'America/New_York')
                     AND coalesce(i.invoice_status, '') NOT IN ('voided', 'destroyed')) x),
        'past_due', (SELECT jsonb_build_object(
            'amount', coalesce(sum(p.past_due_amount), 0),
            'clients', count(*),
            'top', coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.client_id, 'code', t.client_code, 'amount', t.past_due_amount)
                                              ORDER BY t.past_due_amount DESC)
                               FROM (SELECT q.client_id, q.client_code, q.past_due_amount FROM ops.v_client_past_due q
                                      WHERE q.past_due_amount > 0 ORDER BY q.past_due_amount DESC LIMIT 3) t), '[]'::jsonb))
            FROM ops.v_client_past_due p WHERE p.past_due_amount > 0));
    END IF;
    IF NOT 'admin_review' = ANY (v_closed) THEN
      -- Gallons measured by the tank sensors, and which trucks were measured at all this month (only Moises has sensors
      -- today, so the card must say which trucks its number covers).
      WITH g AS MATERIALIZED (
        SELECT t.vehicle_id, t.visit_date, t.sludge_collected_gallons
          FROM public.v_visit_tank_service t
         WHERE t.visit_date >= v_prev AND t.visit_date <= v_today
      )
      SELECT v_biz || jsonb_build_object('pumped', jsonb_build_object(
          'gallons', round(coalesce((SELECT sum(g.sludge_collected_gallons) FROM g WHERE g.visit_date >= v_month), 0)),
          'prev_gallons', round(coalesce((SELECT sum(g.sludge_collected_gallons) FROM g WHERE g.visit_date BETWEEN v_prev AND v_prev_end), 0)),
          'trucks', coalesce((SELECT jsonb_agg(jsonb_build_object('name', coalesce(vh.name, 'No truck'), 'visits', x.visits, 'measured', x.measured)
                                               ORDER BY x.measured DESC, vh.name)
                                FROM (SELECT g.vehicle_id, count(*) AS visits, count(g.sludge_collected_gallons) AS measured
                                        FROM g WHERE g.visit_date >= v_month GROUP BY 1) x
                                LEFT JOIN public.vehicles vh ON vh.id = x.vehicle_id), '[]'::jsonb)))
        INTO v_biz;
    END IF;
    v_out := v_out || jsonb_build_object('business', v_biz);
  END IF;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION ops.portal_my_work()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-16 (Trello #210, Fred's pick HF1, default "fieldread"): the signed-in person's OWN day for the Ops Portal's
-- Home: their visits (the Calendar's crew rule: the visit's driver or a member of its team), the truck of those visits
-- with its last tank readings, the forms assigned to them (client.fn_intake_assigned_to_me, the one rule), and how many
-- visits they finished in the last 7 days. Never another person's work, never money, never notes or access codes.
-- The Field group opens no app, so public.fn_request_gate lets exactly this function through for them (the My work door).
-- A night truck works one visit date from about 9 PM to 5 AM, so until 6 AM ET the day is still the evening's date.
DECLARE
  v_emp bigint := hr.fn_access_caller();
  v_day date := ((now() AT TIME ZONE 'America/New_York') - interval '6 hours')::date;
  v_out jsonb;
  v_vehicle bigint;
BEGIN
  IF v_emp IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  WITH mine AS MATERIALIZED (
    SELECT v.*
      FROM ops.v_calendar_visit v
     WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
       AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp))
  )
  SELECT jsonb_build_object(
      'date', v_day,
      'stops', coalesce(jsonb_agg(jsonb_build_object(
          'id', m.id, 'at', m.start_at, 'all_day', coalesce(m.is_all_day, false), 'status', m.visit_status,
          'late', coalesce(m.late_status = 'late', false), 'code', m.client_code, 'client', m.client_name,
          'address', m.address, 'city', m.city, 'zone', m.zone, 'lat', m.latitude, 'lng', m.longitude,
          'work', m.service_label, 'manholes', m.manholes, 'trap', m.equipment_size_gallons, 'derm', m.derm_required,
          'open_from', m.access_hours_start, 'open_to', m.access_hours_end, 'truck', m.truck_name,
          'site_file', (SELECT l.public_id FROM public.property_page_links l
                         WHERE l.property_id = m.property_id
                           AND EXISTS (SELECT 1 FROM public.property_pages p WHERE p.property_id = m.property_id AND p.approved_at IS NOT NULL)))
        ORDER BY m.start_at NULLS LAST, m.id), '[]'::jsonb)),
    (SELECT m2.vehicle_id FROM mine m2 WHERE m2.vehicle_id IS NOT NULL ORDER BY m2.start_at NULLS LAST, m2.id LIMIT 1)
    INTO v_out, v_vehicle
    FROM mine m;

  v_out := v_out || jsonb_build_object(
    'truck', CASE WHEN v_vehicle IS NULL THEN NULL ELSE jsonb_build_object(
      'name', (SELECT vh.name FROM public.vehicles vh WHERE vh.id = v_vehicle),
      'tanks', coalesce((SELECT jsonb_agg(jsonb_build_object('contents', t.contents, 'percent', round(t.fill_percent::numeric),
                                                             'gallons', round(t.gallons::numeric), 'at', t.recorded_at) ORDER BY t.contents)
                           FROM (SELECT DISTINCT ON (l.contents) l.contents, l.fill_percent, l.gallons, l.recorded_at
                                   FROM public.v_tank_levels l WHERE l.vehicle_id = v_vehicle
                                  ORDER BY l.contents, l.recorded_at DESC) t), '[]'::jsonb)) END,
    'forms', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'code', c.client_code, 'client', c.name, 'expires_at', i.expires_at)
                                        ORDER BY i.requested_at)
                         FROM public.property_intakes i
                         JOIN public.properties p ON p.id = i.property_id
                         JOIN public.clients c ON c.id = p.client_id
                        WHERE i.submitted_at IS NULL AND i.cancelled_at IS NULL AND (i.expires_at IS NULL OR i.expires_at > now())
                          AND client.fn_intake_assigned_to_me(i.id)), '[]'::jsonb),
    'done_7d', (SELECT count(*) FROM ops.v_calendar_visit v
                 WHERE v.visit_status = 'completed' AND v.visit_date BETWEEN v_day - 6 AND v_day
                   AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp))));

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION ops.portal_home() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION ops.portal_my_work() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.portal_home() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.portal_my_work() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $verify$
DECLARE
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_day date := ((now() AT TIME ZONE 'America/New_York') - interval '6 hours')::date;
  v_month date := date_trunc('month', now() AT TIME ZONE 'America/New_York')::date;
  v_fred jsonb; v_fred_home jsonb; v_diego jsonb; v_diego_home jsonb; v_field jsonb; v_field_home jsonb; v_mine jsonb;
  v_rows jsonb; v_uid uuid; v_emp bigint; v_n numeric; v_t0 timestamptz; v_ms jsonb := '{}'::jsonb; v_refused text;
BEGIN
  -- Grants: the two new reads are for signed-in staff and the server, never anon or PUBLIC.
  IF has_function_privilege('anon', 'ops.portal_home()', 'execute') OR has_function_privilege('anon', 'ops.portal_my_work()', 'execute')
     OR has_function_privilege('anon', 'ops.portal_waiting()', 'execute') THEN
    RAISE EXCEPTION 'verify_fail: anon can execute a portal read';
  END IF;
  IF NOT (has_function_privilege('authenticated', 'ops.portal_home()', 'execute') AND has_function_privilege('authenticated', 'ops.portal_my_work()', 'execute')
          AND has_function_privilege('service_role', 'ops.portal_home()', 'execute') AND has_function_privilege('service_role', 'ops.portal_my_work()', 'execute')) THEN
    RAISE EXCEPTION 'verify_fail: authenticated or service_role cannot execute a new read';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid IN ('ops.portal_home()'::regprocedure, 'ops.portal_my_work()'::regprocedure) AND a.grantee = 0) THEN
    RAISE EXCEPTION 'verify_fail: PUBLIC can execute a new read';
  END IF;

  -- Fred (admin): the bell's answer has the four new counts, each worked out a second way, and the Home agrees with it.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_t0 := clock_timestamp(); v_fred := ops.portal_waiting(); v_ms := v_ms || jsonb_build_object('waiting_ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
  v_t0 := clock_timestamp(); v_fred_home := ops.portal_home(); v_ms := v_ms || jsonb_build_object('home_ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
  v_rows := derm.manifest_row_states();   -- what the Manifests page itself reads, behind its own gate
  RESET ROLE;
  IF NOT (v_fred ?& ARRAY['late_today', 'requests_open', 'reviews_pending', 'manifests_need_someone', 'call_first', 'time_on_site',
                          'photos_unsorted', 'city_emails', 'stamp_sheets', 'unopened_emails']) THEN
    RAISE EXCEPTION 'verify_fail: admin keys %', (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_fred) k);
  END IF;
  SELECT count(*) INTO v_n FROM ops.v_calendar_visit v WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled' AND v.late_status = 'late';
  IF (v_fred->>'late_today')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: late_today % vs %', v_fred->>'late_today', v_n; END IF;
  IF (v_fred_home->'today'->>'late')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: the Home says % late, the bell %', v_fred_home->'today'->>'late', v_n; END IF;
  SELECT count(*) INTO v_n FROM ops.visit_requests r WHERE r.deleted_at IS NULL AND r.status = 'open';
  IF (v_fred->>'requests_open')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: requests_open % vs %', v_fred->>'requests_open', v_n; END IF;
  IF (v_fred->>'call_first')::numeric > v_n THEN RAISE EXCEPTION 'verify_fail: more call-first requests than open requests'; END IF;
  SELECT count(*) INTO v_n FROM public.visits_with_review w
   WHERE w.visit_status = 'completed' AND w.in_review_scope AND w.visit_date <= v_today AND w.review_status = 'pending';
  IF (v_fred->>'reviews_pending')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: reviews_pending % vs %', v_fred->>'reviews_pending', v_n; END IF;
  SELECT count(*) INTO v_n FROM jsonb_each(v_rows) e
   WHERE NOT coalesce((e.value->>'test')::boolean, false)
     AND (e.value->'papers'->>'s' IN ('warn', 'bad') OR e.value->'stamps'->>'s' IN ('warn', 'bad') OR e.value->'copies'->>'s' IN ('warn', 'bad')
          OR e.value->'city'->>'s' IN ('warn', 'bad') OR e.value->'visit'->>'s' IN ('warn', 'bad') OR e.value->'email'->>'s' IN ('warn', 'bad'));
  IF (v_fred->>'manifests_need_someone')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: manifests_need_someone % vs %', v_fred->>'manifests_need_someone', v_n; END IF;

  -- The Home: today, trucks that add up to today, a week of 7 days starting today, and the Business band for an admin.
  IF NOT (v_fred_home ?& ARRAY['date', 'today', 'trucks', 'week', 'business']) THEN
    RAISE EXCEPTION 'verify_fail: admin home keys %', (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_fred_home) k);
  END IF;
  SELECT count(*) INTO v_n FROM ops.v_calendar_visit v WHERE v.visit_date = v_today AND v.visit_status <> 'cancelled';
  IF (v_fred_home->'today'->>'visits')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: today % vs %', v_fred_home->'today', v_n; END IF;
  IF (SELECT coalesce(sum((t->>'visits')::int), 0) FROM jsonb_array_elements(v_fred_home->'trucks') t) <> v_n THEN RAISE EXCEPTION 'verify_fail: trucks do not add up to today'; END IF;
  IF jsonb_array_length(v_fred_home->'week') <> 7 OR (v_fred_home->'week'->0->>'date')::date <> v_today
     OR (v_fred_home->'week'->0->>'visits')::numeric <> v_n THEN
    RAISE EXCEPTION 'verify_fail: week %', v_fred_home->'week';
  END IF;
  IF NOT (v_fred_home->'business' ?& ARRAY['invoices', 'past_due', 'pumped']) THEN RAISE EXCEPTION 'verify_fail: admin business %', v_fred_home->'business'; END IF;
  SELECT coalesce(sum(i.total), 0) INTO v_n FROM client.invoices i
   WHERE (i.sent_at AT TIME ZONE 'America/New_York')::date >= v_month AND coalesce(i.invoice_status, '') NOT IN ('voided', 'destroyed');
  IF (v_fred_home->'business'->'invoices'->>'total')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: invoices % vs %', v_fred_home->'business'->'invoices', v_n; END IF;
  SELECT coalesce(sum(p.past_due_amount), 0) INTO v_n FROM ops.v_client_past_due p WHERE p.past_due_amount > 0;
  IF (v_fred_home->'business'->'past_due'->>'amount')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: past due % vs %', v_fred_home->'business'->'past_due', v_n; END IF;
  SELECT round(coalesce(sum(t.sludge_collected_gallons), 0)) INTO v_n FROM public.v_visit_tank_service t WHERE t.visit_date >= v_month AND t.visit_date <= v_today;
  IF (v_fred_home->'business'->'pumped'->>'gallons')::numeric IS DISTINCT FROM v_n THEN RAISE EXCEPTION 'verify_fail: gallons % vs %', v_fred_home->'business'->'pumped', v_n; END IF;

  -- Diego (office): the same counts and Today, and NO money (Fred: "it doesn't needs to see the like revenue").
  SELECT u.id INTO v_uid FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email) WHERE e.id = 28;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_diego := ops.portal_waiting();
  v_diego_home := ops.portal_home();
  RESET ROLE;
  IF NOT (v_diego ?& ARRAY['late_today', 'requests_open', 'reviews_pending', 'manifests_need_someone']) THEN RAISE EXCEPTION 'verify_fail: office keys %', v_diego; END IF;
  IF NOT v_diego_home ? 'today' OR v_diego_home ? 'business' THEN RAISE EXCEPTION 'verify_fail: office home keys %', (SELECT array_agg(k) FROM jsonb_object_keys(v_diego_home) k); END IF;

  -- A Field person with no app open AND a working sign-in (hr.fn_access_caller's own test): their own day only, nothing
  -- else, and the gate lets exactly this one read through.
  SELECT u.id, e.id INTO v_uid, v_emp
    FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email)
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field'
     AND u.email_confirmed_at IS NOT NULL AND (u.banned_until IS NULL OR u.banned_until <= now())
     AND NOT EXISTS (SELECT 1 FROM hr.fn_effective_access(e.id) f WHERE f.parent IS NULL AND f.level IN ('view', 'edit'))
   ORDER BY (SELECT count(*) FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
               AND (v.driver_id = e.id OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = e.id))) DESC, e.id
   LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no field person with no app open to test with'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', (SELECT email FROM auth.users WHERE id = v_uid), 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_t0 := clock_timestamp(); v_mine := ops.portal_my_work(); v_ms := v_ms || jsonb_build_object('my_work_ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000));
  v_field := ops.portal_waiting();
  v_field_home := ops.portal_home();
  RESET ROLE;
  SELECT count(*) INTO v_n FROM ops.v_calendar_visit v WHERE v.visit_date = v_day AND v.visit_status <> 'cancelled'
     AND (v.driver_id = v_emp OR EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v.id AND t.employee_id = v_emp));
  IF NOT (v_mine ?& ARRAY['date', 'stops', 'forms', 'done_7d']) OR jsonb_array_length(v_mine->'stops') IS DISTINCT FROM v_n::int THEN
    RAISE EXCEPTION 'verify_fail: my work % (expected % stops)', v_mine, v_n;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_mine) k WHERE k NOT IN ('date', 'stops', 'truck', 'forms', 'done_7d'))
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_mine->'stops') s, jsonb_object_keys(s) k
                 WHERE k NOT IN ('id', 'at', 'all_day', 'status', 'late', 'code', 'client', 'address', 'city', 'zone', 'lat', 'lng',
                                 'work', 'manholes', 'trap', 'derm', 'open_from', 'open_to', 'truck', 'site_file')) THEN
    RAISE EXCEPTION 'verify_fail: my work carries a field it should not (money, notes, codes)';
  END IF;
  IF v_field ?| ARRAY['late_today', 'requests_open', 'reviews_pending', 'manifests_need_someone'] THEN RAISE EXCEPTION 'verify_fail: field person gets office counts %', v_field; END IF;
  IF v_field_home ?| ARRAY['today', 'trucks', 'week', 'business'] THEN RAISE EXCEPTION 'verify_fail: field person gets the office Home %', v_field_home; END IF;

  PERFORM set_config('request.headers', json_build_object('content-profile', 'ops')::text, true);
  PERFORM set_config('request.method', 'POST', true);
  PERFORM set_config('request.path', '/rpc/portal_my_work', true);
  SET LOCAL ROLE authenticated;
  PERFORM public.fn_request_gate();   -- the door: must pass
  BEGIN
    PERFORM set_config('request.path', '/rpc/portal_home', true);
    PERFORM public.fn_request_gate();
    v_refused := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN v_refused := 'refused'; END;
  IF v_refused <> 'refused' THEN RAISE EXCEPTION 'verify_fail: the door let another ops function through'; END IF;
  BEGIN
    PERFORM set_config('request.path', '/rpc/portal_my_work', true);
    PERFORM set_config('request.headers', json_build_object('content-profile', 'public')::text, true);
    PERFORM public.fn_request_gate();
    v_refused := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN v_refused := 'refused'; END;
  IF v_refused <> 'refused' THEN RAISE EXCEPTION 'verify_fail: the door let another schema through'; END IF;
  BEGIN
    PERFORM set_config('request.headers', json_build_object('content-profile', 'ops')::text, true);
    PERFORM set_config('request.method', 'GET', true);
    PERFORM public.fn_request_gate();
    v_refused := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN v_refused := 'refused'; END;
  IF v_refused <> 'refused' THEN RAISE EXCEPTION 'verify_fail: the door let a GET through'; END IF;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('request.path', '', true);
  PERFORM set_config('request.method', '', true);
  PERFORM set_config('verify.summary', (v_ms || jsonb_build_object(
    'fred_waiting', v_fred, 'fred_today', v_fred_home->'today', 'fred_business', v_fred_home->'business',
    'diego_home_keys', (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_diego_home) k),
    'field_emp', v_emp, 'field_stops', jsonb_array_length(v_mine->'stops'), 'field_forms', jsonb_array_length(v_mine->'forms'),
    'field_truck', v_mine->'truck'->>'name', 'field_done_7d', v_mine->'done_7d'))::text, true);
END $verify$;

COMMIT;
