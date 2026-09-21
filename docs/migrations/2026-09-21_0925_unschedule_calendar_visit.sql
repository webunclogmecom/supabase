-- ============================================================================
-- 2026-09-21_0925 : "Unschedule" a Calendar visit into the To Be Scheduled list
-- ============================================================================
-- Fred, voice note 2026-09-21 (verbatim): "when we click on a task that has already been made, it
-- will open the drawer for that task. Then on the section date and time, we can see a button that
-- says, Unschedule ... you will get a confirmation dialog letting you know that the task is gonna be
-- moved to the to-be-scheduled section. But when we do the same for a visit instead ... at the date
-- and time section, there is no button for unscheduling. So add that button, add that button to the
-- date and time section as the task have."
--
-- A task is unscheduled by nulling task_date. A visit cannot be: public.visits.visit_date is NOT NULL
-- by design (2026-07-30_1156: the Client App mirror never reconciles nullability, and a dateless
-- visit would break its hourly refresh for ten tables). The To Be Scheduled list is ops.visit_requests,
-- a different table with no row in public.visits. So "unschedule a visit" is one RPC that, in ONE
-- transaction, copies the visit into a request and soft-deletes the visit:
--
--   ops.unschedule_calendar_visit(p_visit_id) -> the new request id
--     1. locks the visit (FOR UPDATE) and refuses, with a plain sentence, anything that is not a live
--        scheduled visit on an open job (completed, skipped, cancelled, deleted, archived job). Every
--        refusal is ERRCODE 22023, MESSAGE = the sentence the app shows verbatim (2026-09-14 rule: no
--        technical word in an operator message), DETAIL = 'blocker=<code> in ops.unschedule_calendar_visit'
--        so the app can tell this function's refusals from any other error;
--     2. copies client, job, property, title, notes, truck (the stored vehicle_id), team (visit_team,
--        the assigned driver first) and locations (visit_locations) into ops.visit_requests and its
--        child tables, with unscheduled_from_visit_id (new column) pointing back at the visit;
--     3. services: the visit's own line_items rows when it has any, mapped back to the catalogue by
--        title (that is how create_calendar_visit writes them; every one of the 17 pending Service
--        Call visits maps that way today), keeping quantity, unit price and description. A generated
--        agreement visit has NO line_items rows (737 of the 738 future ones, measured 2026-09-21), so
--        it takes the job's schedulable line items instead (the same code-prefix mapping
--        ops.client_service_options uses), the visit's own service_type first, code 08 (Warranty of
--        Drainage, billing-only) left out. A line item that maps to nothing is a refusal, never a
--        silent drop;
--     4. calls public.delete_calendar_visit: the canonical soft delete, whose deleted_at transition is
--        what fires trg_push_visit_update and removes the visit from Jobber through the existing path.
--        Nothing new touches Jobber.
--
-- WHY THE LIST NOW ACCEPTS SERVICE AGREEMENT WORK. Measured 2026-09-21: 763 pending visits, 746 of them
-- on Service Agreement jobs and 17 on Service Call jobs. A button that only works on 2% of the visits
-- it appears on is not the button Fred asked for. The 2026-07-30 decision ("SC-queue-only") rejected
-- the DERIVED cadence backlog (172 self-healing client-grained rows); a request a human made by
-- unscheduling a real visit is persisted, human-managed work, which is what the list is for. So:
--   * ops.v_visit_requests gains job_kind ('SA' | 'SC', the client_service_options rule) so the panel
--     can say which kind a row is (until now every row was a Service Call and the card had no badge),
--     plus unscheduled_from_visit_id and unscheduled_from_date;
--   * ops.update_visit_request accepts Service Agreement services when the request's JOB is a Service
--     Agreement (the check used to be Service Call only, which would have refused any service edit on
--     such a row); create_visit_request is unchanged, its caller still binds to a Service Call job.
--
-- 🛑 THE ONE REFUSAL THAT IS NOT ABOUT THE VISIT'S STATE: the LAST future visit of an agreement.
-- public.fn_generate_sa_visits anchors on max(visit_date) of the job's future scheduled visits plus
-- frequency_days and drops candidates within 7 days of an existing visit. Remove a mid-chain visit and
-- the anchor stays beyond it: the gap is real until the request is scheduled. Remove the LAST one and
-- the anchor slides back to the previous visit (or the last completed one) plus the frequency, which is
-- where the removed visit was: the nightly run would put a visit back on that date while the request
-- sits in the list, and the dispatcher would have two. The RPC refuses that case and says why. Measured
-- 2026-09-21: 158 such visits (one per agreement), 0 of them inside 60 days; the tails sit at the
-- 6-month horizon. Skip or Move covers the rare case.
--
-- AUDIT (rule 8): no new table. ops.visit_requests keeps its audit trigger, so the INSERT is logged
-- with the caller (app_source + email) and new_row carries unscheduled_from_visit_id; the visit's
-- deleted_at transition is logged by audit_visits as "deleted by <person>", exactly as Delete visit.
-- The request child tables stay opt-out as in 2026-07-30_1156.
--
-- PRIVILEGES: authenticated only, anon and service_role revoked explicitly (this project's default
-- privileges hand out grants nobody wrote), matching the sibling request RPCs. A CREATE OR REPLACE of
-- the view keeps its grants (only DROP discards them); the appended columns are additive.
--
-- Positive control for the Jobber side is NOT in this file: pg_net only queues on commit, so it is
-- exercised live on 112-YA through the app (Building Apps/Visit Calendar/docs/08-changelog.md,
-- 2026-09-21 (c)).
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

SET LOCAL lock_timeout = '3s';

-- ---------------------------------------------------------------------------
-- 1. Where the request came from.
-- ---------------------------------------------------------------------------

ALTER TABLE ops.visit_requests
  ADD COLUMN unscheduled_from_visit_id bigint REFERENCES public.visits(id) ON DELETE SET NULL;

COMMENT ON COLUMN ops.visit_requests.unscheduled_from_visit_id IS
  'Set by ops.unschedule_calendar_visit: the (soft-deleted) public.visits row this request was made from. NULL for a request created from the New Visit dialog. ON DELETE SET NULL for the same reason as converted_visit_id: trg_wipe_upcoming_on_inactive hard-deletes visits.';

-- ---------------------------------------------------------------------------
-- 2. The RPC.
-- ---------------------------------------------------------------------------

CREATE FUNCTION ops.unschedule_calendar_visit(p_visit_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v          public.visits;
  j          public.jobs;
  v_today    date := (now() AT TIME ZONE 'America/New_York')::date;
  v_is_sa    boolean;
  v_ids      bigint[];
  v_team     bigint[];
  v_locs     bigint[];
  v_orphan   text;
  v_id       bigint;
BEGIN
  IF p_visit_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'No visit was given.', DETAIL = 'blocker=no_visit_id in ops.unschedule_calendar_visit';
  END IF;

  SELECT * INTO v FROM visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND OR v.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit is no longer on the calendar. Close the drawer and open it again.', DETAIL = 'blocker=visit_not_found in ops.unschedule_calendar_visit';
  END IF;
  IF v.visit_status = 'completed' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'A completed visit cannot be unscheduled. Mark it incomplete first.', DETAIL = 'blocker=visit_completed in ops.unschedule_calendar_visit';
  ELSIF v.visit_status = 'skipped' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'A skipped visit cannot be unscheduled. Un-skip it first.', DETAIL = 'blocker=visit_skipped in ops.unschedule_calendar_visit';
  ELSIF v.visit_status IS DISTINCT FROM 'scheduled' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('Only a scheduled visit can be unscheduled. This one is %s.', coalesce(v.visit_status, 'without a status')), DETAIL = 'blocker=visit_not_scheduled in ops.unschedule_calendar_visit';
  END IF;
  IF v.client_id IS NULL OR v.job_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit has no client or no job on record, so it cannot go to the To Be Scheduled list. Delete it instead.', DETAIL = 'blocker=no_client_or_job in ops.unschedule_calendar_visit';
  END IF;

  SELECT * INTO j FROM jobs WHERE id = v.job_id;
  IF NOT FOUND OR j.job_status IN ('archived', 'destroyed') THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit''s job is closed in Jobber, so it cannot go to the To Be Scheduled list. Delete the visit instead.', DETAIL = 'blocker=job_closed in ops.unschedule_calendar_visit';
  END IF;
  IF j.client_id IS DISTINCT FROM v.client_id THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit''s job belongs to a different client, so it cannot go to the To Be Scheduled list. Delete the visit instead.', DETAIL = 'blocker=job_other_client in ops.unschedule_calendar_visit';
  END IF;
  v_is_sa := j.title ILIKE 'Service Agreement%';

  -- The last future visit of an agreement: the nightly generator would put it back (header).
  IF v_is_sa AND coalesce(j.frequency_days, 0) > 0 AND v.visit_date >= v_today
     AND NOT EXISTS (SELECT 1 FROM visits o
                      WHERE o.job_id = v.job_id AND o.id <> v.id AND o.deleted_at IS NULL
                        AND o.visit_status = 'scheduled' AND o.visit_date >= v.visit_date) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This is the last scheduled visit of this Service Agreement. If it is unscheduled, the nightly schedule run puts a visit back on this date. Move it to another date, or skip it, instead.', DETAIL = 'blocker=agreement_tail in ops.unschedule_calendar_visit';
  END IF;

  -- Services (header, point 3).
  IF EXISTS (SELECT 1 FROM line_items WHERE visit_id = v.id) THEN
    SELECT string_agg(li.name, ', ' ORDER BY li.id) INTO v_orphan
      FROM line_items li
     WHERE li.visit_id = v.id
       AND NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.active AND (s.title = li.name OR s.code = split_part(li.name, ' - ', 1)));
    IF v_orphan IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = format('This visit carries a service that is not in the service list any more (%s), so it cannot go to the To Be Scheduled list. Edit its services first.', v_orphan), DETAIL = 'blocker=service_unknown in ops.unschedule_calendar_visit';
    END IF;
    SELECT array_agg(x.sid ORDER BY x.first_id) INTO v_ids
      FROM (SELECT m.sid, min(m.li_id) AS first_id
              FROM (SELECT li.id AS li_id,
                           (SELECT s.id FROM service_line_items s
                             WHERE s.active AND (s.title = li.name OR s.code = split_part(li.name, ' - ', 1))
                             ORDER BY (s.title = li.name) DESC, s.id LIMIT 1) AS sid
                      FROM line_items li WHERE li.visit_id = v.id) m
             GROUP BY m.sid) x;
  ELSE
    SELECT array_agg(x.id ORDER BY x.pri, x.code) INTO v_ids
      FROM (SELECT DISTINCT s.id, s.code,
                   CASE WHEN s.service_type IS NOT DISTINCT FROM v.service_type THEN 0 ELSE 1 END AS pri
              FROM line_items li
              JOIN service_line_items s ON s.code = lpad(substring(btrim(li.name) FROM '^([0-9]+)'), 2, '0')
             WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.quantity > 0
               AND s.schedulable AND s.active AND s.code <> '08') x;
    IF v_ids IS NULL AND v.service_line_item_id IS NOT NULL THEN
      v_ids := ARRAY[v.service_line_item_id];
    END IF;
  END IF;
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'This visit has no service on record, so it cannot go to the To Be Scheduled list. Delete it instead.', DETAIL = 'blocker=no_service in ops.unschedule_calendar_visit';
  END IF;

  SELECT array_agg(t.employee_id ORDER BY (t.employee_id = v.assigned_driver_id) DESC, t.employee_id)
    INTO v_team FROM visit_team t WHERE t.visit_id = v.id;
  IF v_team IS NULL AND v.assigned_driver_id IS NOT NULL THEN
    v_team := ARRAY[v.assigned_driver_id];
  END IF;

  SELECT array_agg(l.client_location_id ORDER BY l.client_location_id)
    INTO v_locs FROM visit_locations l WHERE l.visit_id = v.id;

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes, vehicle_id, unscheduled_from_visit_id)
  VALUES (v.client_id, v.job_id, v.property_id, v.title, v.notes, v.vehicle_id, v.id)
  RETURNING id INTO v_id;

  -- Quantity, unit price and description ride along only when the visit had its own line items.
  INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
  SELECT v_id, x.id, x.ord::smallint, li.quantity, li.unit_price, nullif(btrim(li.description), '')
    FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord)
    LEFT JOIN LATERAL (
      SELECT l.quantity, l.unit_price, l.description
        FROM line_items l JOIN service_line_items s ON s.id = x.id
       WHERE l.visit_id = v.id AND (s.title = l.name OR s.code = split_part(l.name, ' - ', 1))
       ORDER BY (s.title = l.name) DESC, l.id LIMIT 1) li ON true;

  IF v_locs IS NOT NULL THEN
    INSERT INTO ops.visit_request_locations (request_id, client_location_id)
    SELECT v_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
  END IF;

  IF v_team IS NOT NULL THEN
    INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
    SELECT v_id, x.id, x.ord::smallint FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
    ON CONFLICT DO NOTHING;
  END IF;

  -- The canonical soft delete: deleted_at = now(), audited as "deleted by <person>", and its
  -- trg_push_visit_update transition is what removes the visit from Jobber.
  PERFORM public.delete_calendar_visit(v.id);

  RETURN v_id;
END $$;

COMMENT ON FUNCTION ops.unschedule_calendar_visit(bigint) IS
  'Visit Calendar "Unschedule": copies a live scheduled visit into ops.visit_requests (To Be Scheduled) and soft-deletes the visit through public.delete_calendar_visit, in one transaction. Refuses completed, skipped, cancelled and deleted visits, closed jobs, a visit whose line item is not in the catalogue, and the last future visit of a Service Agreement (fn_generate_sa_visits would put it back). Every refusal is ERRCODE 22023: MESSAGE is the plain sentence the app shows verbatim, DETAIL is blocker=<code> in ops.unschedule_calendar_visit (never shown, kept in logs).';

REVOKE ALL ON FUNCTION ops.unschedule_calendar_visit(bigint) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION ops.unschedule_calendar_visit(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. update_visit_request: a Service Agreement request may carry Service Agreement services.
--    Same signature, same body otherwise; only the service check and its message change.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ops.update_visit_request(p_request_id bigint, p_patch jsonb)
RETURNS ops.visit_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE r ops.visit_requests; v_ids bigint[]; v_bad int; v_locs bigint[]; v_team bigint[]; v_is_sa boolean;
BEGIN
  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'update_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'update_visit_request: request % is % and can no longer be edited', p_request_id, r.status;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN r; END IF;

  -- Refuse loudly rather than silently ignoring a key the caller believed would apply.
  IF p_patch ?| ARRAY['client_id','job_id','status','converted_visit_id','converted_at','deleted_at','cancel_reason','unscheduled_from_visit_id'] THEN
    RAISE EXCEPTION 'update_visit_request: client_id, job_id and lifecycle fields are not editable; remove and recreate instead';
  END IF;

  -- Scalars. Key presence decides; an absent key leaves the column untouched.
  UPDATE ops.visit_requests SET
    title       = CASE WHEN p_patch ? 'title'       THEN NULLIF(p_patch->>'title','')      ELSE title END,
    notes       = CASE WHEN p_patch ? 'notes'       THEN NULLIF(p_patch->>'notes','')      ELSE notes END,
    property_id = CASE WHEN p_patch ? 'property_id' THEN (p_patch->>'property_id')::bigint ELSE property_id END,
    vehicle_id  = CASE WHEN p_patch ? 'vehicle_id'  THEN (p_patch->>'vehicle_id')::bigint  ELSE vehicle_id END
  WHERE id = p_request_id;

  -- Services: replace on presence. Service Call services (and 27) as in create_visit_request, plus
  -- Service Agreement services when the request's job is a Service Agreement (2026-09-21_0925: an
  -- unscheduled agreement visit lands here with the agreement's services).
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids
      FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids,1) IS NULL THEN
      RAISE EXCEPTION 'update_visit_request: at least one service is required';
    END IF;
    SELECT (title ILIKE 'Service Agreement%') INTO v_is_sa FROM jobs WHERE id = r.job_id;
    SELECT count(*) INTO v_bad FROM unnest(v_ids) x
     WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.id = x AND s.active
                          AND ((s.reason = 'Service Call' AND s.schedulable) OR s.code = '27'
                               OR (coalesce(v_is_sa, false) AND s.reason = 'Service Agreement' AND s.schedulable)));
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'update_visit_request: % service(s) supplied that a % job cannot carry', v_bad,
        CASE WHEN coalesce(v_is_sa, false) THEN 'Service Agreement' ELSE 'Service Call' END;
    END IF;

    DELETE FROM ops.visit_request_services WHERE request_id = p_request_id;
    INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
    SELECT p_request_id, x.id, x.ord::smallint,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'quantity')::numeric,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'unit_price')::numeric,
           nullif(btrim(p_patch -> 'line_item_descriptions' ->> x.id::text), '')
      FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord);
  END IF;

  IF p_patch ? 'client_location_ids' THEN
    SELECT array_agg(x::bigint) INTO v_locs
      FROM jsonb_array_elements_text(p_patch->'client_location_ids') AS x;
    DELETE FROM ops.visit_request_locations WHERE request_id = p_request_id;
    IF v_locs IS NOT NULL AND array_length(v_locs,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_locations (request_id, client_location_id)
      SELECT p_request_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  IF p_patch ? 'team_ids' THEN
    SELECT array_agg(x::bigint) INTO v_team
      FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
    DELETE FROM ops.visit_request_team WHERE request_id = p_request_id;
    IF v_team IS NOT NULL AND array_length(v_team,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
      SELECT p_request_id, x.id, x.ord::smallint
        FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------------
-- 4. The panel view: three APPENDED columns (a view can only ever append).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW ops.v_visit_requests AS
SELECT r.id,
       r.client_id,
       c.client_code,
       c.name AS client_name,
       c.status AS client_status,
       r.job_id,
       j.job_number,
       j.title AS job_title,
       r.title,
       r.notes,
       r.created_at,
       CURRENT_DATE - r.created_at::date AS age_days,
       (SELECT count(*) FROM ops.visit_request_services s WHERE s.request_id = r.id) AS service_count,
       (SELECT string_agg(sli.title, ', ' ORDER BY s.seq_no)
          FROM ops.visit_request_services s
          JOIN public.service_line_items sli ON sli.id = s.service_line_item_id
         WHERE s.request_id = r.id) AS service_summary,
       (SELECT coalesce(bool_or(sli.requires_derm), false)
          FROM ops.visit_request_services s
          JOIN public.service_line_items sli ON sli.id = s.service_line_item_id
         WHERE s.request_id = r.id) AS requires_derm,
       r.vehicle_id,
       veh.name AS truck_name,
       (SELECT coalesce(array_agg(t.employee_id ORDER BY t.seq_no, t.employee_id), '{}'::bigint[])
          FROM ops.visit_request_team t WHERE t.request_id = r.id) AS team_ids,
       (SELECT string_agg(e.full_name, ', ' ORDER BY t.seq_no, t.employee_id)
          FROM ops.visit_request_team t
          JOIN public.employees e ON e.id = t.employee_id
         WHERE t.request_id = r.id) AS team_names,
       CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA' ELSE 'SC' END AS job_kind,
       r.unscheduled_from_visit_id,
       (SELECT uv.visit_date FROM public.visits uv WHERE uv.id = r.unscheduled_from_visit_id) AS unscheduled_from_date
  FROM ops.visit_requests r
  JOIN public.clients c ON c.id = r.client_id
  JOIN public.jobs    j ON j.id = r.job_id
  LEFT JOIN public.vehicles veh ON veh.id = r.vehicle_id
 WHERE r.deleted_at IS NULL AND r.status = 'open';

-- ---------------------------------------------------------------------------
-- VERIFY (same transaction; a failure rolls everything back).
-- ---------------------------------------------------------------------------

DO $v$
DECLARE v_cols text;
BEGIN
  -- the column exists
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'ops' AND table_name = 'visit_requests' AND column_name = 'unscheduled_from_visit_id') THEN
    RAISE EXCEPTION 'VERIFY: unscheduled_from_visit_id missing';
  END IF;
  -- the RPC: authenticated only (measured, not assumed: default privileges hand out EXECUTE)
  IF NOT has_function_privilege('authenticated', 'ops.unschedule_calendar_visit(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: authenticated cannot execute ops.unschedule_calendar_visit';
  END IF;
  IF has_function_privilege('anon', 'ops.unschedule_calendar_visit(bigint)', 'EXECUTE')
     OR has_function_privilege('service_role', 'ops.unschedule_calendar_visit(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: anon or service_role can execute ops.unschedule_calendar_visit';
  END IF;
  -- update_visit_request kept its ACL (CREATE OR REPLACE keeps grants; assert rather than trust)
  IF NOT has_function_privilege('authenticated', 'ops.update_visit_request(bigint, jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'ops.update_visit_request(bigint, jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: ops.update_visit_request ACL moved';
  END IF;
  -- the view: the three columns are APPENDED after team_names, grants intact
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'v_visit_requests';
  IF v_cols NOT LIKE '%,team_names,job_kind,unscheduled_from_visit_id,unscheduled_from_date' THEN
    RAISE EXCEPTION 'VERIFY: v_visit_requests columns are %', v_cols;
  END IF;
  IF NOT has_table_privilege('authenticated', 'ops.v_visit_requests', 'SELECT')
     OR has_table_privilege('anon', 'ops.v_visit_requests', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: v_visit_requests grants moved';
  END IF;
  -- the view still answers (a bad subquery would only show on first read)
  PERFORM 1 FROM ops.v_visit_requests LIMIT 1;
  -- job_kind follows the client_service_options rule on every open row
  IF EXISTS (SELECT 1 FROM ops.v_visit_requests r JOIN public.jobs j ON j.id = r.job_id
              WHERE r.job_kind IS DISTINCT FROM CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA' ELSE 'SC' END) THEN
    RAISE EXCEPTION 'VERIFY: job_kind disagrees with the job title';
  END IF;
  -- the audit trigger is still on ops.visit_requests (rule 8)
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'ops.visit_requests'::regclass AND tgname = 'audit_visit_requests') THEN
    RAISE EXCEPTION 'VERIFY: audit_visit_requests trigger missing';
  END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
