-- 2026-07-30_1156_visit_requests_to_be_scheduled.sql
--
-- "TO BE SCHEDULED": Service Call work accepted but not yet dated.
--
-- THE ASK (Yannick, relayed by Fred, verbatim): "on the new visits button, be able to make the visit
-- 'To be scheduled' ... when clicking on that, the created visit is gonna be showing up on the
-- to-be-scheduled section ... the idea is that is a SC visit, not a SA visit, so this visit is not
-- gonna have a Date or Time."
--
-- ⚠ A DATELESS ITEM IS NOT A VISIT, AND THAT IS THE WHOLE DESIGN. It is a row in three new LEAF
-- tables in `ops` that no existing view, trigger, cron, edge function, external script or app can
-- see. Scheduling it calls the UNMODIFIED public.create_calendar_visit, so the visits pipeline
-- receives exactly one new event: an ordinary Calendar visit insert, byte-identical in shape to what
-- the New Visit modal produces today.
--
--   public.visits.visit_date stays NOT NULL.
--   visits_visit_status_chk keeps its four values (scheduled|completed|cancelled|skipped).
--   ops.v_calendar_visit is NOT re-emitted.
--   No existing trigger, cron, edge function, view or grant is touched.
--
-- 🛑 WHY NOT THE OBVIOUS "make visit_date nullable + add an 'unscheduled' status". It was designed,
-- costed and REJECTED on a measurement. The **Client App Mirror** project `mjxjhwxktedrrnochwli`
-- holds `public.visits.visit_date` as NOT NULL (nullability was copied from Prod at --setup;
-- refresh_client_mirror.js emits `${c.notnull ? ' NOT NULL' : ''}`), and its `healDrift()` only ever
-- runs ALTER TABLE ... ADD COLUMN IF NOT EXISTS. **It never reconciles nullability on an existing
-- column, so DROP NOT NULL in Prod does not propagate.** The first dateless visit would 23502 the
-- hourly upsert ('23 * * * *'), and because the per-table loop has NO try/catch and `visits` is 9th
-- of 19 tables, the run aborts there and the TEN tables after it (jobs, invoices, line_items,
-- employees, vehicles, visit_team, visit_assignments, visit_locations, entity_source_links,
-- service_line_items) stop refreshing every hour until a human notices. A silent cross-project
-- outage, from a one-word schema change. Positive control on the same query: start_at, end_at,
-- visit_status, client_id and deleted_at ARE nullable in the mirror, so the instrument reads real
-- values rather than defaulting everything to NOT NULL.
--
-- ⚠ ALSO REJECTED, and worth recording so nobody re-proposes them:
--   * A SENTINEL date (e.g. 1900-01-01) on a real visit. It is a lie that every date-scoped query,
--     every month stat and every Jobber push would have to be taught to ignore. 0 sentinel rows
--     exist today; keep it that way.
--   * Re-emitting ops.v_calendar_visit to null-guard late_status/expected_date. Measured
--     unnecessary: `prev_live_date` is `(SELECT max(prev.visit_date) ... WHERE prev.visit_date <
--     v_1.visit_date)`, which is NULL when v_1.visit_date is NULL, and BOTH CASEs already have an
--     explicit `WHEN pl.prev_live_date IS NULL THEN NULL` branch. Hand-re-typing a 13,025-character,
--     209-line view over 29 joins to fix nothing is how the Calendar gets broken.
--
-- AUDIT (rule 8, explicit opt-in/opt-out as required):
--   * ops.visit_requests            -> OPT IN. It records a commitment to a client; who created and
--                                      who cancelled one is business-relevant.
--   * ops.visit_request_services    -> OPT OUT, and stated deliberately rather than defaulted: they
--   * ops.visit_request_locations      are append-only children written only inside
--                                      ops.create_visit_request in the same transaction as the
--                                      audited parent INSERT, and they CASCADE with it. ⚠ Note the
--                                      real limitation: the parent's old_row/new_row does NOT
--                                      contain the child rows, so an audit reader sees that a
--                                      request existed but not which services it carried. Accepted
--                                      because a request is never edited, only created, scheduled or
--                                      cancelled. **If editing is ever added, opt these in.**
--   audit.log_change is schema-generic and audit.logs carries table_schema, so it works outside
--   `public` (verified: the four derm.* tables have carried it since 2026-07-01).
--
-- ⚠ anon HOLDS USAGE ON THE `ops` SCHEMA (measured: has_schema_privilege('anon','ops','USAGE') =
-- true), and Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote. REVOKE FROM PUBLIC
-- IS NOT ENOUGH here: anon and service_role are revoked explicitly on both tables and functions.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;
SET LOCAL lock_timeout = '3s';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE ops.visit_requests (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id          bigint      NOT NULL REFERENCES public.clients(id),
  job_id             bigint      NOT NULL REFERENCES public.jobs(id),
  property_id        bigint               REFERENCES public.properties(id),
  title              text,
  notes              text,
  status             text        NOT NULL DEFAULT 'open',
  converted_visit_id bigint               REFERENCES public.visits(id) ON DELETE SET NULL,
  converted_at       timestamptz,
  cancel_reason      text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CONSTRAINT visit_requests_status_chk CHECK (status IN ('open','scheduled','cancelled')),
  -- `status` is NOT NULL and the right side is a NOT NULL test, so this CHECK can never evaluate to
  -- NULL. ⚠ public.visits.visit_status is NULLABLE with 0 nulls today, which is exactly how a
  -- NULL-permissive CHECK hole gets opened (a CHECK that is NULL passes). Do not repeat it here.
  CONSTRAINT visit_requests_converted_iff_scheduled
    CHECK ((status = 'scheduled') = (converted_at IS NOT NULL))
);

COMMENT ON TABLE ops.visit_requests IS
  'Service Call work accepted but not yet dated. NOT a visit: no row exists in public.visits until ops.schedule_visit_request() converts it. Feeds the Visit Calendar TO BE SCHEDULED panel.';
COMMENT ON COLUMN ops.visit_requests.converted_visit_id IS
  'ON DELETE SET NULL, and the sibling invariant keys on converted_at NOT on this column, because public.trg_wipe_upcoming_on_inactive HARD-DELETEs from public.visits when a client goes INACTIVE/PAUSED (DELETE ... WHERE client_id=NEW.id AND visit_status=''scheduled'' AND visit_date >= CURRENT_DATE). A plain FK, or an invariant naming this column, would raise 23503/23514 inside that trigger and BLOCK the wipe.';

CREATE TABLE ops.visit_request_services (
  request_id           bigint   NOT NULL REFERENCES ops.visit_requests(id) ON DELETE CASCADE,
  service_line_item_id bigint   NOT NULL REFERENCES public.service_line_items(id),
  seq_no               smallint NOT NULL,   -- create_calendar_visit treats ids[1] as the primary service
  quantity             numeric,
  unit_price           numeric,
  description          text,
  PRIMARY KEY (request_id, service_line_item_id)
);
CREATE UNIQUE INDEX visit_request_services_seq_uk ON ops.visit_request_services (request_id, seq_no);

CREATE TABLE ops.visit_request_locations (
  request_id         bigint NOT NULL REFERENCES ops.visit_requests(id) ON DELETE CASCADE,
  client_location_id bigint NOT NULL REFERENCES public.client_locations(id) ON DELETE CASCADE,
  PRIMARY KEY (request_id, client_location_id)
);

CREATE INDEX idx_visit_requests_open ON ops.visit_requests (created_at)
  WHERE status = 'open' AND deleted_at IS NULL;
CREATE INDEX idx_visit_requests_client ON ops.visit_requests (client_id);

CREATE TRIGGER trg_visit_requests_updated_at
  BEFORE UPDATE ON ops.visit_requests FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER audit_visit_requests
  AFTER INSERT OR UPDATE OR DELETE ON ops.visit_requests FOR EACH ROW EXECUTE FUNCTION audit.log_change();

ALTER TABLE ops.visit_requests          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.visit_request_services  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.visit_request_locations ENABLE ROW LEVEL SECURITY;
CREATE POLICY visit_requests_read          ON ops.visit_requests          FOR SELECT TO authenticated USING (true);
CREATE POLICY visit_request_services_read  ON ops.visit_request_services  FOR SELECT TO authenticated USING (true);
CREATE POLICY visit_request_locations_read ON ops.visit_request_locations FOR SELECT TO authenticated USING (true);

REVOKE ALL ON ops.visit_requests, ops.visit_request_services, ops.visit_request_locations FROM PUBLIC, anon;
GRANT SELECT ON ops.visit_requests, ops.visit_request_services, ops.visit_request_locations
  TO authenticated, service_role, yannick_readonly;

-- ---------------------------------------------------------------------------
-- Read view for the panel.
-- ⚠ `c.name AS client_name`. public.clients has NO client_name column; the shipped
-- ops.v_calendar_push_health does exactly this. The c.client_name spelling returns 42703.
-- ---------------------------------------------------------------------------

CREATE VIEW ops.v_visit_requests AS
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
         WHERE s.request_id = r.id) AS requires_derm
  FROM ops.visit_requests r
  JOIN public.clients c ON c.id = r.client_id
  JOIN public.jobs    j ON j.id = r.job_id
 WHERE r.deleted_at IS NULL AND r.status = 'open';

REVOKE ALL ON ops.v_visit_requests FROM PUBLIC, anon;
GRANT SELECT ON ops.v_visit_requests TO authenticated, service_role, yannick_readonly;

-- ---------------------------------------------------------------------------
-- RPC 1: create. Writes ONLY to ops.
-- ---------------------------------------------------------------------------

CREATE FUNCTION ops.create_visit_request(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[],
  p_property_id bigint DEFAULT NULL, p_client_location_ids bigint[] DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL,
  p_line_item_prices jsonb DEFAULT NULL, p_line_item_descriptions jsonb DEFAULT NULL)
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

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes)
  VALUES (p_client_id, p_job_id, p_property_id, p_title, p_notes) RETURNING id INTO v_id;

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

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- RPC 2: schedule. The ONLY path that touches public.visits, and it does so exclusively
-- through the UNMODIFIED public.create_calendar_visit.
-- ---------------------------------------------------------------------------

CREATE FUNCTION ops.schedule_visit_request(
  p_request_id bigint, p_visit_date date,
  p_start_at timestamptz DEFAULT NULL, p_end_at timestamptz DEFAULT NULL,
  p_vehicle_id bigint DEFAULT NULL, p_team_ids bigint[] DEFAULT NULL)
RETURNS public.visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r ops.visit_requests; v public.visits;
        v_ids bigint[]; v_locs bigint[]; v_prices jsonb; v_desc jsonb;
BEGIN
  IF p_visit_date IS NULL THEN
    RAISE EXCEPTION 'schedule_visit_request: p_visit_date is required';
  END IF;

  -- FOR UPDATE serialises a double-drop: two rapid drags of the same card cannot both convert.
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

  -- ⚠ CONTRACT. public.create_calendar_visit is UNCHANGED, and its 15-arg signature IS the contract
  -- of this function. p_line_item_prices is keyed '<service_line_item_id>' -> {unit_price, quantity}
  -- and p_line_item_descriptions '<service_line_item_id>' -> text. If that signature ever changes,
  -- this reassembly must change with it, and the scheduling smoke test must be re-run.
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
         p_vehicle_id            => p_vehicle_id,
         p_driver_id             => NULL,
         p_line_item_prices      => v_prices,
         p_team_ids              => p_team_ids,
         p_line_item_descriptions=> v_desc);

  UPDATE ops.visit_requests
     SET status = 'scheduled', converted_visit_id = v.id, converted_at = now()
   WHERE id = r.id;

  RETURN v;
END $$;

-- ---------------------------------------------------------------------------
-- RPC 3: cancel. SOFT ONLY. Never hard-delete business data (rule 6).
-- ---------------------------------------------------------------------------

CREATE FUNCTION ops.cancel_visit_request(p_request_id bigint, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE ops.visit_requests
     SET status = 'cancelled', cancel_reason = p_reason, deleted_at = coalesce(deleted_at, now())
   WHERE id = p_request_id AND status = 'open' AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_visit_request: request % is not open', p_request_id;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Privileges. REVOKE FROM PUBLIC is NOT enough on this project (default privileges
-- auto-grant anon/service_role) - revoke both explicitly, matching create_calendar_visit's
-- measured ACL of authenticated=X/postgres.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION ops.schedule_visit_request(bigint,date,timestamptz,timestamptz,bigint,bigint[])        FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION ops.cancel_visit_request(bigint,text)                                                  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION ops.schedule_visit_request(bigint,date,timestamptz,timestamptz,bigint,bigint[])        TO authenticated;
GRANT EXECUTE ON FUNCTION ops.cancel_visit_request(bigint,text)                                                  TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
