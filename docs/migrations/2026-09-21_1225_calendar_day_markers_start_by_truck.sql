-- ============================================================================
-- 2026-09-21_1225 : the Day Start marker can be placed BY TRUCK, at the ETA before the truck's first visit
-- ============================================================================
-- Fred, voice note 2026-09-21 (verbatim): "I want it to select between trucks ... it's gonna first
-- look up which is the first visit of that truck that day, and it's gonna do a search using the
-- Google API to do an ETA ... between that first visit and the yard ... the start card is gonna show
-- up 30 minutes before that first visit ... it also needs to create the task on Jobber, and it needs
-- to be assigned to the person who is assigned to that visit ... in Jobber, we cannot assign a truck.
-- We need to assign a person." Plan (approved by Fred, all recommendations):
-- Building Apps/Visit Calendar/docs/specs/2026-09-21-start-pill-by-truck-plan.md.
--
-- The app derives the Start (first timed, geo-coded visit of the picked truck that day; yard-to-visit
-- ETA; minute = visit start minus ETA; driver = that visit's driver_id) and INSERTs one row. This
-- migration gives the row a place to name its inputs and changes what "one Start per day" means:
--
--   1. source_visit_id (FK visits, ON DELETE SET NULL: trg_wipe_upcoming_on_inactive hard-deletes
--      visits), eta_minutes, eta_computed_at. A derived minute must name its inputs, or nobody can
--      tell a computed 11:28 from a typed one. All NULL on End, Dump, the three legacy rows, and
--      after a hand edit of the time (the app clears them then; the chip falls back to the live line).
--   2. Uniqueness. Since 2026-09-16 the rule was one Start and one End per (date, driver, type),
--      NULLS NOT DISTINCT. A person who is the first-visit driver of two trucks the same day (a
--      driver switching trucks is a normal day) could not hold both truck-placed Starts, and the
--      app's pill path pre-deleted by driver, which would have silently removed the first truck's
--      Start and its Jobber Task. Now: the driver index covers DRIVER-PLACED rows only
--      (vehicle_id IS NULL: every End, any driver-placed Start), and a new partial unique index
--      holds one Start per (date, truck) for truck-placed rows. Two Starts for one person on two
--      trucks are two Jobber Tasks for that person, which is the truth of such a day.
--   3. fn_push_marker_to_jobber's UPDATE guard is NOT touched: it already lists marker_date,
--      marker_type, minutes, vehicle_id, employee_id and dump_site, and the three new columns are
--      deliberately absent from it (a re-derivation that changes only the ETA is not a Jobber change;
--      a changed minute or driver is, and those are already in the guard).
--
-- Rule 13m of the Calendar manual ("the stored minute is the user's", "vehicle_id is never written")
-- is reversed for the Start pill only by this cycle; End and Dump keep 13m. The app side and the
-- edge-function changes (calculate-driving-time traffic:false, jobber-push-task title with the truck)
-- ship in the same cycle; see the plan.
--
-- AUDIT (rule 8): no new table; ops.calendar_day_markers stays opted OUT (dispatch state, 2026-07-28).
-- PRIVILEGES: unchanged. authenticated already holds SELECT/INSERT/UPDATE/DELETE with the
-- calendar_day_markers_rw FOR ALL policy; new columns ride the table grant. relacl is compared in VERIFY.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

SET LOCAL lock_timeout = '3s';

-- ---------------------------------------------------------------------------
-- 1. The derived Start names its inputs.
-- ---------------------------------------------------------------------------

ALTER TABLE ops.calendar_day_markers
  ADD COLUMN source_visit_id bigint REFERENCES public.visits(id) ON DELETE SET NULL,
  ADD COLUMN eta_minutes integer CHECK (eta_minutes IS NULL OR eta_minutes >= 0),
  ADD COLUMN eta_computed_at timestamptz;

COMMENT ON COLUMN ops.calendar_day_markers.source_visit_id IS
  'Truck-placed Start only: the visit the Start was derived from (the truck''s first timed, geo-coded visit that day). NULL on End, Dump, driver-placed and legacy rows, and after a hand edit of the time. ON DELETE SET NULL because trg_wipe_upcoming_on_inactive hard-deletes visits.';
COMMENT ON COLUMN ops.calendar_day_markers.eta_minutes IS
  'Truck-placed Start only: the free-flow Doral Yard to source visit ETA in minutes that set the stored minute (minute = visit start minus this). NULL after a hand edit of the time, so the chip shows the live 13m line instead of a stale gap.';
COMMENT ON COLUMN ops.calendar_day_markers.eta_computed_at IS
  'When eta_minutes was computed (calculate-driving-time, traffic:false). NULL whenever eta_minutes is NULL.';

-- ---------------------------------------------------------------------------
-- 2. Uniqueness: driver-placed rows keep the driver rule; truck-placed Starts are one per truck per day.
-- ---------------------------------------------------------------------------

DROP INDEX ops.calendar_day_markers_start_end_driver_uniq;

CREATE UNIQUE INDEX calendar_day_markers_start_end_driver_uniq
  ON ops.calendar_day_markers (marker_date, employee_id, marker_type) NULLS NOT DISTINCT
  WHERE marker_type IN ('start', 'end') AND vehicle_id IS NULL;

CREATE UNIQUE INDEX calendar_day_markers_start_truck_uniq
  ON ops.calendar_day_markers (marker_date, vehicle_id)
  WHERE marker_type = 'start' AND vehicle_id IS NOT NULL;

COMMENT ON INDEX ops.calendar_day_markers_start_end_driver_uniq IS
  'One Start and one End per (date, driver, type) for DRIVER-PLACED rows (vehicle_id IS NULL). A truck-placed Start is keyed by the truck instead (calendar_day_markers_start_truck_uniq), so a person who drives two trucks in one day holds two Starts.';
COMMENT ON INDEX ops.calendar_day_markers_start_truck_uniq IS
  'One Start per (date, truck) for truck-placed Starts (vehicle_id set). The three legacy 2026-08 rows (Moises, distinct dates) satisfy it.';

-- ---------------------------------------------------------------------------
-- VERIFY (same transaction; a failure rolls everything back).
-- ---------------------------------------------------------------------------

DO $v$
DECLARE v_acl text; v_def text; v_n int; v_id1 bigint; v_id2 bigint; v_id3 bigint; v_id4 bigint; v_ok boolean;
BEGIN
  -- columns
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema = 'ops' AND table_name = 'calendar_day_markers'
     AND column_name IN ('source_visit_id', 'eta_minutes', 'eta_computed_at');
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY: expected 3 new columns, found %', v_n; END IF;

  -- indexes and their predicates
  SELECT indexdef INTO v_def FROM pg_indexes WHERE schemaname = 'ops' AND indexname = 'calendar_day_markers_start_end_driver_uniq';
  IF v_def IS NULL OR v_def NOT ILIKE '%vehicle_id IS NULL%' OR v_def NOT ILIKE '%NULLS NOT DISTINCT%' THEN
    RAISE EXCEPTION 'VERIFY: driver index wrong: %', v_def;
  END IF;
  SELECT indexdef INTO v_def FROM pg_indexes WHERE schemaname = 'ops' AND indexname = 'calendar_day_markers_start_truck_uniq';
  IF v_def IS NULL OR v_def NOT ILIKE '%vehicle_id IS NOT NULL%' THEN
    RAISE EXCEPTION 'VERIFY: truck index wrong: %', v_def;
  END IF;

  -- the push guard still lists the Jobber-visible columns and none of the new ones
  v_def := pg_get_functiondef('public.fn_push_marker_to_jobber'::regproc);
  IF v_def NOT LIKE '%new.vehicle_id  is not distinct from old.vehicle_id%'
     OR v_def NOT LIKE '%new.employee_id is not distinct from old.employee_id%'
     OR v_def LIKE '%eta_minutes%' OR v_def LIKE '%source_visit_id%' THEN
    RAISE EXCEPTION 'VERIFY: fn_push_marker_to_jobber guard is not the expected one';
  END IF;

  -- grants unchanged (the ACL measured before this migration)
  SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = 'ops.calendar_day_markers'::regclass;
  IF v_acl <> '{postgres=arwdDxtm/postgres,authenticated=arwd/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: relacl moved: %', v_acl;
  END IF;
  IF NOT has_column_privilege('authenticated', 'ops.calendar_day_markers', 'eta_minutes', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY: authenticated cannot insert the new columns';
  END IF;

  -- the table stays audit opt-out
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'ops.calendar_day_markers'::regclass AND tgname LIKE 'audit%') THEN
    RAISE EXCEPTION 'VERIFY: an audit trigger appeared on calendar_day_markers';
  END IF;

  -- the uniqueness semantics, on synthetic rows inside a savepoint that is rolled back (the push
  -- requests they queue through pg_net are rolled back with them)
  BEGIN
    -- two truck-placed Starts, one driver (employee 2), two trucks, same day: allowed
    INSERT INTO ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
      VALUES ('2099-01-01', 'start', 300, 2, 2) RETURNING id INTO v_id1;
    INSERT INTO ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
      VALUES ('2099-01-01', 'start', 330, 3, 2) RETURNING id INTO v_id2;
    -- a driver-placed End for the same driver that day: allowed (vehicle_id NULL, driver index)
    INSERT INTO ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
      VALUES ('2099-01-01', 'end', 900, NULL, 2) RETURNING id INTO v_id3;
    -- a second truck-placed Start on the same truck and day: refused by the truck index
    v_ok := false;
    BEGIN
      INSERT INTO ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
        VALUES ('2099-01-01', 'start', 400, 2, 27) RETURNING id INTO v_id4;
    EXCEPTION WHEN unique_violation THEN
      v_ok := (SQLERRM LIKE '%calendar_day_markers_start_truck_uniq%');
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY: a second Start on the same truck and day was not refused by the truck index'; END IF;
    -- a second driver-placed End for the same driver and day: still refused by the driver index
    v_ok := false;
    BEGIN
      INSERT INTO ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
        VALUES ('2099-01-01', 'end', 930, NULL, 2) RETURNING id INTO v_id4;
    EXCEPTION WHEN unique_violation THEN
      v_ok := (SQLERRM LIKE '%calendar_day_markers_start_end_driver_uniq%');
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY: a second End for the same driver and day was not refused by the driver index'; END IF;
    -- an ETA-only update must not re-arm the push guard: the guard returns before fn_request_marker_push.
    -- (Measured by the guard body above; exercising pg_net inside a savepoint proves nothing, it is rolled back.)
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'savepoint rollback';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN
    NULL;  -- the synthetic rows are gone
  END;
  IF EXISTS (SELECT 1 FROM ops.calendar_day_markers WHERE marker_date = '2099-01-01') THEN
    RAISE EXCEPTION 'VERIFY: synthetic rows survived the savepoint';
  END IF;

  -- the three legacy truck rows still satisfy the truck index (distinct dates)
  SELECT count(*) INTO v_n FROM ops.calendar_day_markers WHERE vehicle_id IS NOT NULL AND marker_type = 'start';
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY: expected the 3 legacy truck Starts, found %', v_n; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
