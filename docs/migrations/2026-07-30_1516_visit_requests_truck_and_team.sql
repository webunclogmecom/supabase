-- 2026-07-30_1516_visit_requests_truck_and_team.sql
--
-- FIXES SILENT DATA LOSS, then enables the panel to show and filter by truck/team.
--
-- 🛑 THE BUG. The New Visit modal's "To be scheduled" flow renders TRUCK and TEAM controls (they were
-- deliberately kept visible because ops often know the truck before the day), but
-- `ops.visit_requests` had NOWHERE to put either, and `ops.create_visit_request` did not accept them.
-- Verified in the deployed bundle: the payload is
--   {p_client_id, p_job_id, p_service_line_item_ids, p_property_id, p_client_location_ids,
--    p_title, p_notes, p_line_item_prices, p_line_item_descriptions}
-- with NO p_vehicle_id and NO p_team_ids. So a dispatcher could pick "Moises" and a crew, hit Add,
-- and both selections were **discarded without a word**. Nothing errored, because the app simply
-- never sent them. That is the worst shape of bug: the UI implied the data was captured.
--
-- Fred then asked for the truck and the assigned people to be SHOWN on the queue card and to be
-- FILTERABLE, which is impossible until they are actually stored. Hence this migration.
--
-- WHAT THIS DOES, all additive to the ops-only queue. `public.visits` is STILL not touched, and the
-- 2026-07-30_1156 design holds: a queued item is not a visit until it is scheduled.
--   1. ops.visit_requests gains `vehicle_id` (nullable FK to public.vehicles).
--   2. New leaf table ops.visit_request_team (request_id, employee_id).
--   3. create_visit_request gains p_vehicle_id + p_team_ids and PERSISTS them.
--   4. schedule_visit_request now DEFAULTS to the stored truck/team when the caller passes none,
--      so a drag (which supplies neither) carries the dispatcher's original intent onto the visit
--      instead of dropping it a second time.
--   5. ops.v_visit_requests gains truck/team columns, APPENDED (a view can only ever append).
--
-- ⚠ WHY create_visit_request IS DROPPED AND RECREATED RATHER THAN OVERLOADED. Adding two DEFAULTed
-- parameters creates a SECOND function with a different identity argument list, and PostgREST then
-- has two candidates for the same name and can answer PGRST203 "Could not choose the best candidate
-- function". Dropping first guarantees exactly one. **The GRANT does not survive a DROP**, so it is
-- re-issued below; the pre-drop ACL was measured as {postgres=X/postgres,authenticated=X/postgres}
-- and is restored exactly.
--
-- ⚠ TEAM IS A LINK TABLE, NOT AN ARRAY COLUMN, to match how the visit side already models crew
-- (public.visit_team) and to keep the FK to employees real. Audit: OPT OUT, consistent with the
-- sibling child tables from 2026-07-30_1156 and stated deliberately rather than defaulted (see that
-- migration's header for the reasoning and the limitation it carries).
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;
SET LOCAL lock_timeout = '3s';

-- 1. Truck on the request -----------------------------------------------------

ALTER TABLE ops.visit_requests
  ADD COLUMN vehicle_id bigint REFERENCES public.vehicles(id);

COMMENT ON COLUMN ops.visit_requests.vehicle_id IS
  'Truck the dispatcher intends for this undated Service Call. Carried onto the visit by ops.schedule_visit_request when the caller does not override it. NULL means no preference, NOT "unassigned by mistake".';

-- 2. Team on the request ------------------------------------------------------

CREATE TABLE ops.visit_request_team (
  request_id  bigint NOT NULL REFERENCES ops.visit_requests(id) ON DELETE CASCADE,
  employee_id bigint NOT NULL REFERENCES public.employees(id),
  seq_no      smallint NOT NULL DEFAULT 1,
  PRIMARY KEY (request_id, employee_id)
);
COMMENT ON TABLE ops.visit_request_team IS
  'Intended crew for an undated Service Call. Mirrors public.visit_team on the visit side. seq_no preserves order because create_calendar_visit treats team_ids[1] as the primary/assigned driver.';

ALTER TABLE ops.visit_request_team ENABLE ROW LEVEL SECURITY;
CREATE POLICY visit_request_team_read ON ops.visit_request_team FOR SELECT TO authenticated USING (true);
REVOKE ALL ON ops.visit_request_team FROM PUBLIC, anon;
GRANT SELECT ON ops.visit_request_team TO authenticated, service_role, yannick_readonly;

-- 3. create_visit_request: accept and PERSIST truck + team --------------------
-- DROP first: see the header. Two overloads would risk PGRST203.

DROP FUNCTION IF EXISTS ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb);

CREATE FUNCTION ops.create_visit_request(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[],
  p_property_id bigint DEFAULT NULL, p_client_location_ids bigint[] DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL,
  p_line_item_prices jsonb DEFAULT NULL, p_line_item_descriptions jsonb DEFAULT NULL,
  p_vehicle_id bigint DEFAULT NULL, p_team_ids bigint[] DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id bigint; v_bad int;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids,1) IS NULL THEN
    RAISE EXCEPTION 'create_visit_request: client_id, job_id and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_visit_request: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  SELECT count(*) INTO v_bad FROM unnest(p_service_line_item_ids) x
   WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                      WHERE s.id = x AND s.reason = 'Service Call' AND s.schedulable AND s.active);
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'create_visit_request: % non Service-Call service(s) supplied', v_bad;
  END IF;

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes, vehicle_id)
  VALUES (p_client_id, p_job_id, p_property_id, p_title, p_notes, p_vehicle_id)
  RETURNING id INTO v_id;

  INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
  SELECT v_id, x.id, x.ord::smallint,
         (p_line_item_prices -> x.id::text ->> 'quantity')::numeric,
         (p_line_item_prices -> x.id::text ->> 'unit_price')::numeric,
         nullif(btrim(p_line_item_descriptions ->> x.id::text), '')
    FROM unnest(p_service_line_item_ids) WITH ORDINALITY AS x(id, ord);

  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_locations (request_id, client_location_id)
    SELECT v_id, l FROM unnest(p_client_location_ids) l ON CONFLICT DO NOTHING;
  END IF;

  IF p_team_ids IS NOT NULL AND array_length(p_team_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
    SELECT v_id, x.id, x.ord::smallint
      FROM unnest(p_team_ids) WITH ORDINALITY AS x(id, ord)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END $$;

-- 4. schedule_visit_request: fall back to the STORED truck/team ---------------
-- A drag supplies neither, so without this the dispatcher's original choice would be
-- dropped a SECOND time at the moment it finally becomes a real visit.

CREATE OR REPLACE FUNCTION ops.schedule_visit_request(
  p_request_id bigint, p_visit_date date,
  p_start_at timestamptz DEFAULT NULL, p_end_at timestamptz DEFAULT NULL,
  p_vehicle_id bigint DEFAULT NULL, p_team_ids bigint[] DEFAULT NULL)
RETURNS public.visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r ops.visit_requests; v public.visits;
        v_ids bigint[]; v_locs bigint[]; v_prices jsonb; v_desc jsonb;
        v_vehicle bigint; v_team bigint[];
BEGIN
  IF p_visit_date IS NULL THEN
    RAISE EXCEPTION 'schedule_visit_request: p_visit_date is required';
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'schedule_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'schedule_visit_request: request % is already %', p_request_id, r.status;
  END IF;

  SELECT array_agg(s.service_line_item_id ORDER BY s.seq_no),
         jsonb_object_agg(s.service_line_item_id::text,
           jsonb_strip_nulls(jsonb_build_object('unit_price', s.unit_price, 'quantity', s.quantity)))
             FILTER (WHERE s.unit_price IS NOT NULL OR s.quantity IS NOT NULL),
         jsonb_object_agg(s.service_line_item_id::text, s.description) FILTER (WHERE s.description IS NOT NULL)
    INTO v_ids, v_prices, v_desc
    FROM ops.visit_request_services s WHERE s.request_id = r.id;

  SELECT array_agg(client_location_id) INTO v_locs
    FROM ops.visit_request_locations WHERE request_id = r.id;

  -- Caller wins; otherwise use what the dispatcher chose when the request was created.
  v_vehicle := COALESCE(p_vehicle_id, r.vehicle_id);
  IF p_team_ids IS NOT NULL AND array_length(p_team_ids,1) IS NOT NULL THEN
    v_team := p_team_ids;
  ELSE
    SELECT array_agg(employee_id ORDER BY seq_no, employee_id) INTO v_team
      FROM ops.visit_request_team WHERE request_id = r.id;
  END IF;

  v := public.create_calendar_visit(
         p_client_id             => r.client_id,
         p_job_id                => r.job_id,
         p_service_line_item_ids => v_ids,
         p_visit_date            => p_visit_date,
         p_property_id           => r.property_id,
         p_client_location_ids   => v_locs,
         p_start_at              => p_start_at,
         p_end_at                => p_end_at,
         p_title                 => r.title,
         p_notes                 => r.notes,
         p_vehicle_id            => v_vehicle,
         p_driver_id             => NULL,
         p_line_item_prices      => v_prices,
         p_team_ids              => v_team,
         p_line_item_descriptions=> v_desc);

  UPDATE ops.visit_requests
     SET status = 'scheduled', converted_visit_id = v.id, converted_at = now()
   WHERE id = r.id;

  RETURN v;
END $$;

-- 5. View: APPEND truck + team columns ---------------------------------------
-- ⚠ CREATE OR REPLACE VIEW can ONLY append. The 15 existing columns are restated in the
-- SAME ORDER with the SAME names; the four new ones go strictly at the end.

CREATE OR REPLACE VIEW ops.v_visit_requests AS
SELECT r.id, r.client_id, c.client_code, c.name AS client_name, c.status AS client_status,
       r.job_id, j.job_number, j.title AS job_title,
       r.title, r.notes, r.created_at,
       (CURRENT_DATE - r.created_at::date) AS age_days,
       (SELECT count(*) FROM ops.visit_request_services s WHERE s.request_id = r.id) AS service_count,
       (SELECT string_agg(sli.title, ', ' ORDER BY s.seq_no)
          FROM ops.visit_request_services s
          JOIN public.service_line_items sli ON sli.id = s.service_line_item_id
         WHERE s.request_id = r.id) AS service_summary,
       (SELECT coalesce(bool_or(sli.requires_derm), false)
          FROM ops.visit_request_services s
          JOIN public.service_line_items sli ON sli.id = s.service_line_item_id
         WHERE s.request_id = r.id) AS requires_derm,
       -- ===== APPENDED =====
       r.vehicle_id,
       veh.name AS truck_name,
       (SELECT coalesce(array_agg(t.employee_id ORDER BY t.seq_no, t.employee_id), '{}')
          FROM ops.visit_request_team t WHERE t.request_id = r.id) AS team_ids,
       (SELECT string_agg(e.full_name, ', ' ORDER BY t.seq_no, t.employee_id)
          FROM ops.visit_request_team t
          JOIN public.employees e ON e.id = t.employee_id
         WHERE t.request_id = r.id) AS team_names
  FROM ops.visit_requests r
  JOIN public.clients c ON c.id = r.client_id
  JOIN public.jobs    j ON j.id = r.job_id
  LEFT JOIN public.vehicles veh ON veh.id = r.vehicle_id
 WHERE r.deleted_at IS NULL AND r.status = 'open';

-- 6. Privileges. The DROP in step 3 took the grant with it; restore it exactly.
-- Measured pre-drop ACL: {postgres=X/postgres,authenticated=X/postgres}

REVOKE ALL ON FUNCTION ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[]) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[]) TO authenticated;

REVOKE ALL ON ops.v_visit_requests FROM PUBLIC, anon;
GRANT SELECT ON ops.v_visit_requests TO authenticated, service_role, yannick_readonly;

COMMIT;

NOTIFY pgrst, 'reload schema';
