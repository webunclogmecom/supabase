-- 2026-09-16_1000_calendar_day_markers_per_driver.sql
-- Day markers belong to a DRIVER, not a truck: the Jobber Task must land on one person's schedule.
--
-- WHY (Fred, 2026-09-16, voice): "once we do it, it lets you select which truck is gonna do it. But the
-- task needs to be assigned to a driver instead, for it to be actually the driver to see this task."
-- Plus: markers must be movable, editable and deletable from the Calendar with Jobber following.
-- Design: Building Apps/Visit Calendar/docs/specs/2026-09-16-day-markers-driver-edit-eta-design.md.
--
-- WHAT CHANGES HERE (the app change follows the same hour; the edge fn jobber-push-task is deployed
-- BEFORE the app starts writing employee_id):
--   1. ops.calendar_day_markers.employee_id bigint NULL REFERENCES public.employees(id). NULL = Unassigned,
--      a supported value (like vehicle_id NULL was), never to be backfilled away. vehicle_id STAYS for the
--      five legacy rows; the app stops writing it.
--   2. Uniqueness moves from (marker_date, vehicle_id, marker_type) to (marker_date, employee_id,
--      marker_type) NULLS NOT DISTINCT, Start/End only (Dump stays repeatable). The five legacy rows all
--      carry employee_id NULL on distinct (date, type) pairs, asserted in PRE 2, so the new index builds.
--   3. public.fn_push_marker_to_jobber: the live body (md5 a435bc4e6cdc050482c1ac06daf2dce9) with ONE line added to the
--      UPDATE guard, employee_id, so a driver change reaches Jobber (title + assignee). Spliced by
--      scratchpad mkmig2.js from pg_get_functiondef, per the CREATE OR REPLACE rule (never retyped).
--   4. trg_calendar_day_markers_updated_at BEFORE UPDATE -> public.set_updated_at(). updated_at has
--      DEFAULT now() and no trigger today, so it freezes at insert and an edited marker cannot be told
--      from a fresh one once the app starts issuing UPDATEs (which it never did before this change).
--
-- UNCHANGED, ASSERTED: grants (authenticated=arwd, service_role=r, yannick_readonly=r), the FOR ALL
-- policy calendar_day_markers_rw, trg_push_marker_to_jobber (events), trg_zz_dump_visit_cleanup.
-- AUDIT (ADR 010): the table stays OPTED OUT (dispatch state, 2026-07-28 decision); audit.logs silence
-- on it proves nothing. entity_source_links (the Task link) is unchanged.
-- PROBE: the UPDATE guard is exercised in a rolled-back savepoint against the pg_net queue, BEFORE the
-- replace (old body: an employee_id-only UPDATE enqueues NOTHING, the mutation control) and AFTER it
-- (new body: exactly one request for that marker). net.http_request_queue is transactional (its body is
-- bytea, hence the convert_from), so the
-- rollback removes the row and no push reaches Jobber.
-- REVERSIBLE: backups/2026-09-16_fn_push_marker_to_jobber_before_driver.sql holds the previous body;
-- recreate calendar_day_markers_start_end_uniq, drop the trigger, drop the column.

BEGIN;

-- PRE 1: the objects are the ones this file was written against.
DO $$ BEGIN
  IF md5(pg_get_functiondef('public.fn_push_marker_to_jobber'::regproc)) <> 'a435bc4e6cdc050482c1ac06daf2dce9' THEN
    RAISE EXCEPTION 'fn_push_marker_to_jobber changed since this migration was written; re-splice from the live definition';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_day_markers' AND column_name = 'employee_id') THEN
    RAISE EXCEPTION 'employee_id already exists';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'ops' AND tablename = 'calendar_day_markers' AND indexname = 'calendar_day_markers_start_end_uniq') THEN
    RAISE EXCEPTION 'calendar_day_markers_start_end_uniq is missing';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'ops' AND c.relname = 'calendar_day_markers')
     <> '{postgres=arwdDxtm/postgres,authenticated=arwd/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'calendar_day_markers ACL is not the expected one';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'set_updated_at') THEN
    RAISE EXCEPTION 'public.set_updated_at() is missing';
  END IF;
END $$;

-- PRE 2: the new index can build: no two Start/End rows share (marker_date, marker_type) once the truck
-- leaves the key (all live rows have employee_id NULL, which NULLS NOT DISTINCT treats as one value).
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM (
    SELECT marker_date, marker_type FROM ops.calendar_day_markers
     WHERE marker_type IN ('start','end') GROUP BY 1, 2 HAVING count(*) > 1) d;
  IF n <> 0 THEN
    RAISE EXCEPTION '% (date, type) pairs would collide under the driver key; resolve them first', n;
  END IF;
END $$;

-- snapshot of the rows for VERIFY 4
CREATE TEMP TABLE cdm_before ON COMMIT DROP AS
  SELECT id, marker_date, marker_type, minutes, dump_site, vehicle_id, dump_visit_id, created_at, updated_at
    FROM ops.calendar_day_markers;

-- 1. the driver column
ALTER TABLE ops.calendar_day_markers ADD COLUMN employee_id bigint REFERENCES public.employees(id);
COMMENT ON COLUMN ops.calendar_day_markers.employee_id IS
  'The driver this Day Start / End / Dump marker belongs to (public.employees). The Jobber Task is assigned to this person and the depot legs are computed from their stops. NULL = Unassigned, a supported value. Replaces vehicle_id as the marker key since 2026-09-16; vehicle_id is kept for the rows placed before that.';
CREATE INDEX calendar_day_markers_employee_date_idx ON ops.calendar_day_markers (employee_id, marker_date);

-- 2. uniqueness per (date, driver, type) for Start/End; Dump stays repeatable
DROP INDEX ops.calendar_day_markers_start_end_uniq;
CREATE UNIQUE INDEX calendar_day_markers_start_end_driver_uniq
  ON ops.calendar_day_markers (marker_date, employee_id, marker_type) NULLS NOT DISTINCT
  WHERE marker_type IN ('start','end');

-- PROBE A (mutation control, OLD body): an employee_id-only UPDATE must enqueue NOTHING today.
DO $$
DECLARE v_id bigint; n0 bigint; n1 bigint;
BEGIN
  SELECT min(id) INTO v_id FROM ops.calendar_day_markers;
  IF v_id IS NULL THEN RAISE EXCEPTION 'no marker row to probe with'; END IF;
  SELECT count(*) INTO n0 FROM net.http_request_queue WHERE (convert_from(body, 'utf8')::jsonb->>'marker_id')::bigint = v_id;
  UPDATE ops.calendar_day_markers SET employee_id = 2 WHERE id = v_id;   -- 2 = Fred
  SELECT count(*) INTO n1 FROM net.http_request_queue WHERE (convert_from(body, 'utf8')::jsonb->>'marker_id')::bigint = v_id;
  IF n1 <> n0 THEN
    RAISE EXCEPTION 'control failed: the OLD guard already pushes on employee_id (% -> %)', n0, n1;
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROBE_A_ROLLBACK';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'PROBE_A_ROLLBACK' THEN RAISE; END IF;
  -- the block's own rollback undid the UPDATE and any queue row
END $$;

-- 3. the trigger function: live body + one guard line
CREATE OR REPLACE FUNCTION public.fn_push_marker_to_jobber()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'DELETE' then
    perform public.fn_request_marker_push(old.id, 'delete');
    return old;
  end if;

  -- On UPDATE, only push when something Jobber can SEE changed. Without this guard any future
  -- bookkeeping column (a touched updated_at, a backfill) would fire a Jobber round-trip for nothing.
  if tg_op = 'UPDATE'
     and new.marker_date is not distinct from old.marker_date
     and new.marker_type is not distinct from old.marker_type
     and new.minutes     is not distinct from old.minutes
     and new.vehicle_id  is not distinct from old.vehicle_id
     and new.employee_id is not distinct from old.employee_id
     and new.dump_site   is not distinct from old.dump_site then
    return new;
  end if;

  perform public.fn_request_marker_push(new.id, 'upsert');
  return new;
end;
$function$;

-- 4. updated_at becomes trigger-managed
CREATE TRIGGER trg_calendar_day_markers_updated_at
  BEFORE UPDATE ON ops.calendar_day_markers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- PROBE B (NEW body): an employee_id-only UPDATE enqueues exactly one push for that marker, a
-- bookkeeping-only UPDATE enqueues none, and updated_at moves. All rolled back.
DO $$
DECLARE v_id bigint; n0 bigint; n1 bigint; n2 bigint; t0 timestamptz; t1 timestamptz;
BEGIN
  SELECT min(id) INTO v_id FROM ops.calendar_day_markers;
  SELECT updated_at INTO t0 FROM ops.calendar_day_markers WHERE id = v_id;
  SELECT count(*) INTO n0 FROM net.http_request_queue WHERE (convert_from(body, 'utf8')::jsonb->>'marker_id')::bigint = v_id;
  UPDATE ops.calendar_day_markers SET employee_id = 2 WHERE id = v_id;
  SELECT count(*) INTO n1 FROM net.http_request_queue WHERE (convert_from(body, 'utf8')::jsonb->>'marker_id')::bigint = v_id;
  SELECT updated_at INTO t1 FROM ops.calendar_day_markers WHERE id = v_id;
  IF n1 <> n0 + 1 THEN
    RAISE EXCEPTION 'new guard did not push on employee_id (% -> %)', n0, n1;
  END IF;
  IF t1 IS NOT DISTINCT FROM t0 THEN
    RAISE EXCEPTION 'updated_at did not move on UPDATE';
  END IF;
  UPDATE ops.calendar_day_markers SET dump_visit_id = dump_visit_id WHERE id = v_id;
  SELECT count(*) INTO n2 FROM net.http_request_queue WHERE (convert_from(body, 'utf8')::jsonb->>'marker_id')::bigint = v_id;
  IF n2 <> n1 THEN
    RAISE EXCEPTION 'a bookkeeping-only UPDATE pushed (% -> %)', n1, n2;
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROBE_B_ROLLBACK';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'PROBE_B_ROLLBACK' THEN RAISE; END IF;
END $$;

-- VERIFY 1: shape
DO $$ BEGIN
  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_day_markers') <> 10
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_day_markers' AND column_name = 'employee_id' AND data_type = 'bigint' AND is_nullable = 'YES') THEN
    RAISE EXCEPTION 'employee_id column not as expected';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'ops' AND tablename = 'calendar_day_markers' AND indexname = 'calendar_day_markers_start_end_uniq')
     OR (SELECT indexdef FROM pg_indexes WHERE schemaname = 'ops' AND tablename = 'calendar_day_markers' AND indexname = 'calendar_day_markers_start_end_driver_uniq')
        <> 'CREATE UNIQUE INDEX calendar_day_markers_start_end_driver_uniq ON ops.calendar_day_markers USING btree (marker_date, employee_id, marker_type) NULLS NOT DISTINCT WHERE (marker_type = ANY (ARRAY[''start''::text, ''end''::text]))' THEN
    RAISE EXCEPTION 'unique index swap not as expected';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.calendar_day_markers'::regclass AND contype = 'f' AND confrelid = 'public.employees'::regclass) THEN
    RAISE EXCEPTION 'employee FK missing';
  END IF;
END $$;

-- VERIFY 2: the function carries the new guard line and the old ones
DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.fn_push_marker_to_jobber'::regproc);
  IF position('new.employee_id is not distinct from old.employee_id' IN d) = 0
     OR position('new.vehicle_id  is not distinct from old.vehicle_id' IN d) = 0
     OR position('new.dump_site   is not distinct from old.dump_site' IN d) = 0
     OR md5(d) = 'a435bc4e6cdc050482c1ac06daf2dce9' THEN
    RAISE EXCEPTION 'fn_push_marker_to_jobber body not as expected';
  END IF;
END $$;

-- VERIFY 3: triggers, grants, policy untouched (plus the new updated_at trigger)
DO $$ BEGIN
  IF (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'ops.calendar_day_markers'::regclass AND NOT tgisinternal)
     <> 'trg_calendar_day_markers_updated_at,trg_push_marker_to_jobber,trg_zz_dump_visit_cleanup' THEN
    RAISE EXCEPTION 'trigger set not as expected';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'ops' AND c.relname = 'calendar_day_markers')
     <> '{postgres=arwdDxtm/postgres,authenticated=arwd/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'ACL changed';
  END IF;
  IF NOT has_column_privilege('authenticated', 'ops.calendar_day_markers', 'employee_id', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'ops.calendar_day_markers', 'employee_id', 'INSERT')
     OR has_column_privilege('anon', 'ops.calendar_day_markers', 'employee_id', 'SELECT') THEN
    RAISE EXCEPTION 'column privileges on employee_id not as expected';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'ops' AND tablename = 'calendar_day_markers') <> 1
     OR (SELECT policyname FROM pg_policies WHERE schemaname = 'ops' AND tablename = 'calendar_day_markers') <> 'calendar_day_markers_rw' THEN
    RAISE EXCEPTION 'policy set changed';
  END IF;
END $$;

-- VERIFY 4: the legacy rows are byte-identical on their old columns and carry employee_id NULL
DO $$
DECLARE n_a bigint; n_b bigint; n_null bigint; n_all bigint;
BEGIN
  SELECT count(*) INTO n_a FROM (SELECT * FROM cdm_before EXCEPT ALL SELECT id, marker_date, marker_type, minutes, dump_site, vehicle_id, dump_visit_id, created_at, updated_at FROM ops.calendar_day_markers) d;
  SELECT count(*) INTO n_b FROM (SELECT id, marker_date, marker_type, minutes, dump_site, vehicle_id, dump_visit_id, created_at, updated_at FROM ops.calendar_day_markers EXCEPT ALL SELECT * FROM cdm_before) d;
  SELECT count(*), count(*) FILTER (WHERE employee_id IS NULL) INTO n_all, n_null FROM ops.calendar_day_markers;
  IF n_a <> 0 OR n_b <> 0 OR n_null <> n_all THEN
    RAISE EXCEPTION 'legacy rows changed: before-only %, after-only %, null employee % of %', n_a, n_b, n_null, n_all;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
