-- 2026-09-16_1300_calendar_tasks_unscheduled.sql
-- A Calendar Task may have NO DATE: it sits in the Calendar's "to be scheduled" tray and is mirrored in
-- Jobber as an UNSCHEDULED Task (startAt null).
--
-- WHY (Fred, 2026-09-16, recorded): "Sometimes they do not have a person or do not have a date. If it
-- does not have a date (a date, not a time) it needs to be placed on the to-be-scheduled." Design:
-- Building Apps/Visit Calendar/docs/specs/2026-09-16-calendar-tasks-create-two-way-design.md.
-- PROVEN AGAINST LIVE JOBBER FIRST (scripts/probes/calendar_task_unscheduled_contract.js, 2026-09-16):
-- taskCreate without startAt is accepted and reads back startAt null / allDay false; taskEdit with
-- startAt/endAt schedules it; taskEdit with startAt null / endAt null unschedules it; deleted, verified
-- gone. So the DB state below is a 1:1 mirror, not an invention.
--
-- WHAT CHANGES:
--   1. ops.calendar_tasks.task_date DROP NOT NULL. NULL = unscheduled.
--   2. calendar_tasks_allday_chk becomes: (task_date IS NULL AND minutes IS NULL AND NOT all_day)
--      OR (task_date IS NOT NULL AND all_day = (minutes IS NULL)). The all-day duration check stays
--      (an unscheduled task is not all-day; it keeps a normal duration, default 30).
--   3. partial index calendar_tasks_unscheduled_idx ON (id) WHERE task_date IS NULL (the tray query).
--   4. ops.fn_record_calendar_task: the LIVE body (md5 1849dc1759dbbeea8033fd6672dbead6) with the 'task_date is required'
--      raise replaced by "no date => no time", and all_day derived as (date present AND no time).
--      Spliced by scratchpad mkmig3.js from pg_get_functiondef, per the CREATE OR REPLACE rule.
--
-- UNCHANGED, ASSERTED: grants (authenticated=r, service_role=r, yannick_readonly=r; nobody writes the
-- table except the two SECDEF recorders), the audit trigger (opted IN), trg_calendar_tasks_updated_at,
-- every other CHECK and FK, the 35 existing rows.
-- CONTROL: PRE 2 runs the OLD body with a dateless payload inside a savepoint and requires the
-- 'task_date is required' refusal; PROBE runs the NEW body through unscheduled -> scheduled ->
-- unscheduled -> the forbidden "no date with a time" and rolls everything back (audit rows and the
-- probe link row included).
-- REVERSIBLE: backups/2026-09-16_fn_record_calendar_task_before_unscheduled.sql holds the previous
-- body; re-add the NOT NULL after deleting any dateless rows; restore the old CHECK.

BEGIN;

-- PRE 1: the objects are the ones this file was written against.
DO $$ BEGIN
  IF md5(pg_get_functiondef('ops.fn_record_calendar_task'::regproc)) <> '1849dc1759dbbeea8033fd6672dbead6' THEN
    RAISE EXCEPTION 'ops.fn_record_calendar_task changed since this migration was written; re-splice from the live definition';
  END IF;
  IF (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_tasks' AND column_name = 'task_date') <> 'NO' THEN
    RAISE EXCEPTION 'task_date is already nullable';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'ops.calendar_tasks'::regclass AND conname = 'calendar_tasks_allday_chk')
     <> 'CHECK ((all_day = (minutes IS NULL)))' THEN
    RAISE EXCEPTION 'calendar_tasks_allday_chk is not the expected definition';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'ops' AND c.relname = 'calendar_tasks')
     <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'calendar_tasks ACL is not the expected one';
  END IF;
END $$;

-- PRE 2 (positive control): the OLD body refuses a dateless task. Rolled back by the block's own savepoint.
DO $$
DECLARE v_id bigint;
BEGIN
  v_id := ops.fn_record_calendar_task(
    jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'title', 'PROBE unscheduled (rolled back)', 'minutes', null),
    'migration-probe@unclogme.com');
  RAISE EXCEPTION 'control failed: the OLD recorder accepted a task with no date (id %)', v_id;
EXCEPTION WHEN SQLSTATE '22023' THEN
  IF position('task_date is required' IN SQLERRM) = 0 THEN
    RAISE EXCEPTION 'control failed: 22023 raised for another reason: %', SQLERRM;
  END IF;
  -- expected: the old body refuses
END $$;

CREATE TEMP TABLE ct_before ON COMMIT DROP AS SELECT * FROM ops.calendar_tasks;

-- 1. no date = unscheduled
ALTER TABLE ops.calendar_tasks ALTER COLUMN task_date DROP NOT NULL;
COMMENT ON COLUMN ops.calendar_tasks.task_date IS 'ET operating date of the task. NULL = UNSCHEDULED (the Calendar "to be scheduled" tray, Jobber startAt null): then minutes is NULL and all_day is false. Since 2026-09-16.';

-- 2. the shape rule
ALTER TABLE ops.calendar_tasks DROP CONSTRAINT calendar_tasks_allday_chk;
ALTER TABLE ops.calendar_tasks ADD CONSTRAINT calendar_tasks_allday_chk
  CHECK ((task_date IS NULL AND minutes IS NULL AND NOT all_day) OR (task_date IS NOT NULL AND all_day = (minutes IS NULL)));

-- 3. the tray index
CREATE INDEX calendar_tasks_unscheduled_idx ON ops.calendar_tasks (id) WHERE task_date IS NULL;

-- 4. the recorder: live body + the unscheduled rule
CREATE OR REPLACE FUNCTION ops.fn_record_calendar_task(p jsonb, p_actor_email text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
DECLARE
  v_gid              text;
  v_task_id          bigint;
  v_cur              ops.calendar_tasks%ROWTYPE;
  v_found            boolean := false;
  v_title            text;
  v_instructions     text;
  v_task_date        date;
  v_minutes          smallint;
  v_duration         smallint;
  v_all_day          boolean;
  v_client_id        bigint;
  v_property_id      bigint;
  v_visit_id         bigint;
  v_is_complete      boolean;
  v_completed_at     timestamptz;
  v_completed_source text;
  v_arr              jsonb;
  v_new_ids          bigint[];
  -- ops.calendar_tasks.duration_minutes DEFAULT, in ONE place. It is needed twice (a fresh insert,
  -- and a row LEAVING all-day) and VERIFY asserts it still equals the column default read out of
  -- pg_attrdef, so this cannot drift from 2026-08-26_1810 in silence.
  c_default_duration constant smallint := 30;
  -- space, TAB, LF, CR, NBSP. Escape-free (see PART 2) so nothing between here and the server can
  -- mangle it.
  c_ws               constant text := concat(' ', chr(9), chr(10), chr(13), chr(160));
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'p must be a JSON object, got %', coalesce(jsonb_typeof(p), 'null')
      USING ERRCODE = '22023';
  END IF;

  PERFORM ops.fn_calendar_task_set_actor(p_actor_email);

  -- The SAME whitespace class the actor label uses (PART 2), and for a stronger reason: this is
  -- the IDEMPOTENCY KEY. A bare btrim() strips ASCII SPACE only, so a jobber_gid of a single TAB
  -- would sail through the "required" guard below and mint a task keyed on a tab -- a key nothing
  -- upstream can ever match again, which is a duplicate task on the crew's schedule the next time
  -- the edge function retries. The two copies of this class are kept honest by the equivalence
  -- LOOP in VERIFY, which drives every character of the class through BOTH copies -- the actor
  -- label and this idempotency key -- and fails on any character either one stops stripping. It
  -- carries its own control, a character that must NOT be stripped, so it also catches both copies
  -- regressing together, which a source-text comparison of the two would miss.
  v_gid := nullif(btrim(coalesce(p->>'jobber_gid', ''), c_ws), '');
  IF v_gid IS NULL THEN
    RAISE EXCEPTION 'jobber_gid is required: this function records what Jobber has ALREADY '
                    'confirmed, so a task with no Jobber id is a task that does not exist yet'
      USING ERRCODE = '22023';
  END IF;

  -- Serialise concurrent calls carrying the same GID. Idempotency is the whole point and
  -- ON CONFLICT is not a lock: without this, two simultaneous retries both miss the link, both
  -- insert a task, and the second dies on idx_esl_source_id with a 23505 after doing work.
  PERFORM pg_advisory_xact_lock(hashtextextended('ops.calendar_task:' || v_gid, 0));

  SELECT l.entity_id INTO v_task_id
    FROM public.entity_source_links l
   WHERE l.entity_type = 'calendar_task'
     AND l.source_system = 'jobber'
     AND l.source_id = v_gid;

  IF v_task_id IS NOT NULL THEN
    -- 3.c: the link row is not an FK and cascades nothing, so it can outlive its task.
    SELECT * INTO v_cur FROM ops.calendar_tasks t WHERE t.id = v_task_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'entity_source_links says Jobber task % is calendar task %, but '
                      'ops.calendar_tasks has no row %. The link row has outlived its task; '
                      'refusing to report a dead id as a successful save.',
                      v_gid, v_task_id, v_task_id
        USING ERRCODE = '23503';
    END IF;
    v_found := true;
  END IF;

  -- ==========================================================================================
  -- OPTIONAL OPTIMISTIC-CONCURRENCY GUARD  (2026-08-26)
  -- ==========================================================================================
  -- The advisory lock above serialises two RECORDER calls. It does NOT close a read-modify-write
  -- that spans a whole SAGA: save-calendar-task reads the row in its own transaction, then makes
  -- three HTTP round trips (token, mutation, read-back), and only then calls this function. A poll
  -- adopting a completion can therefore land on a stale snapshot and clobber a reopen the office
  -- just made -- producing exactly the discrepancy the feature exists to prevent, manufactured by
  -- the safety net.
  --
  -- So a caller may state what it believes the current value to be. Key ABSENT = no check, which
  -- is why this needs no signature change and leaves every existing caller untouched.
  --
  -- 🛑 ERRCODE ZZ002 IS DELIBERATELY DISTINCT from 22023 (bad input) and 23514 (a CHECK). A benign
  --    race must be tellable from a malformed request: the poll retries in five minutes, while the
  --    saga surfaces "someone changed this while you were saving". Same reason it is not P0001,
  --    which is what a bare RAISE produces. ZZ001 is already taken by the VERIFY sentinel in
  --    2026-08-26_1820, so this continues that user-defined class rather than inventing another.
  --
  -- ⚠ WHAT THIS DOES **NOT** CLOSE, stated so nobody believes otherwise: it compares OUR stored
  --   value, so it catches a concurrent write that CHANGED our row. It cannot see a concurrent
  --   change on the JOBBER side. If the office's action leaves our stored value exactly where the
  --   poll expected it, the guard passes and the poll still writes. The poll narrows that residue
  --   separately by re-reading the single task's isComplete from Jobber immediately before it
  --   calls this function. Two narrow windows instead of one wide one; not zero.
  IF p ? 'expected_is_complete' THEN
    IF (p->>'expected_is_complete') IS NULL THEN
      RAISE EXCEPTION 'expected_is_complete may not be null: omit the key to skip the check, or '
                      'send the boolean you believe is stored.' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p->'expected_is_complete') <> 'boolean' THEN
      RAISE EXCEPTION 'expected_is_complete must be a JSON boolean, got %',
                      jsonb_typeof(p->'expected_is_complete') USING ERRCODE = '22023';
    END IF;
    IF v_cur.is_complete IS DISTINCT FROM (p->>'expected_is_complete')::boolean THEN
      RAISE EXCEPTION 'calendar task % (jobber %) is is_complete=%, not the expected %; somebody '
                      'else changed it while this caller was working. Nothing was written.',
                      v_task_id, v_gid, v_cur.is_complete, (p->>'expected_is_complete')::boolean
        USING ERRCODE = 'ZZ002';
    END IF;
  END IF;

  -- ---- explicit nulls on the NOT NULL columns ----------------------------------------------
  -- Patch semantics say an explicit null CLEARS, but these three columns cannot be cleared, and
  -- letting the payload through produces a raw 23502 from the INSERT with no hint about which key
  -- caused it. `title` and `task_date` already raise 22023 below; these did not.
  IF (p ? 'is_complete') AND (p->>'is_complete') IS NULL THEN
    RAISE EXCEPTION 'is_complete may not be null (the column is NOT NULL). Send true or false, or '
                    'omit the key to leave it as it is.' USING ERRCODE = '22023';
  END IF;
  IF (p ? 'duration_minutes') AND (p->>'duration_minutes') IS NULL THEN
    RAISE EXCEPTION 'duration_minutes may not be null (the column is NOT NULL). Send a number, or '
                    'omit the key -- on an all-day task it is derived anyway.'
      USING ERRCODE = '22023';
  END IF;

  -- ---- resolve every column: key present = set, key absent = leave alone -------------------
  -- On the INSERT path v_cur is all-NULL, so coalesce supplies the table defaults for the two
  -- NOT NULL columns that have one.
  v_title        := CASE WHEN p ? 'title'            THEN btrim(coalesce(p->>'title',''),c_ws) ELSE v_cur.title     END;
  v_instructions := CASE WHEN p ? 'instructions'     THEN p->>'instructions'                ELSE v_cur.instructions END;
  v_task_date    := CASE WHEN p ? 'task_date'        THEN (p->>'task_date')::date           ELSE v_cur.task_date    END;
  v_minutes      := CASE WHEN p ? 'minutes'          THEN (p->>'minutes')::smallint         ELSE v_cur.minutes      END;
  v_client_id    := CASE WHEN p ? 'client_id'        THEN (p->>'client_id')::bigint         ELSE v_cur.client_id    END;
  v_property_id  := CASE WHEN p ? 'property_id'      THEN (p->>'property_id')::bigint       ELSE v_cur.property_id  END;
  v_visit_id     := CASE WHEN p ? 'visit_id'         THEN (p->>'visit_id')::bigint          ELSE v_cur.visit_id     END;
  v_is_complete  := CASE WHEN p ? 'is_complete'      THEN (p->>'is_complete')::boolean
                                                     ELSE coalesce(v_cur.is_complete, false) END;

  IF v_title IS NULL OR v_title = '' THEN
    RAISE EXCEPTION 'title is required and may not be blank (Jobber requires it too)'
      USING ERRCODE = '22023';
  END IF;
  -- 2026-09-16 (2026-09-16_1300): task_date NULL is a supported state, UNSCHEDULED: the Calendar's
  -- "to be scheduled" tray and Jobber's own unscheduled Task (startAt null). A dateless task has no
  -- time and is NOT all-day; all_day is derived only when a date exists.
  IF v_task_date IS NULL AND v_minutes IS NOT NULL THEN
    RAISE EXCEPTION 'a task with no date cannot have a time: send task_date as well, or send minutes '
                    'null to keep it unscheduled'
      USING ERRCODE = '22023';
  END IF;

  -- ---- 3.d, BOTH DIRECTIONS ----------------------------------------------------------------
  v_all_day := (v_task_date IS NOT NULL AND v_minutes IS NULL);
  IF (p ? 'all_day') THEN
    IF (p->>'all_day') IS NULL THEN
      RAISE EXCEPTION 'all_day may not be null: it is DERIVED from minutes. Omit it, or send the '
                      'value that matches.' USING ERRCODE = '22023';
    END IF;
    IF (p->>'all_day')::boolean IS DISTINCT FROM v_all_day THEN
      RAISE EXCEPTION 'all_day=% contradicts minutes=%: all_day is DERIVED (all-day means no start '
                      'time), so send one or the other, not two that disagree',
                      p->>'all_day', coalesce(v_minutes::text, 'null')
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- duration_minutes is resolved HERE, after all_day is known, because on an all-day row it is a
  -- DERIVED value and not a stored intent -- and a derived value must not survive the state it was
  -- derived from. The first version of this file forced 1440 on the way IN and left it on the way
  -- OUT, so an all-day task rescheduled to 9:00 AM by a payload of {minutes: 540} came out
  -- false/1440/540: a nine-o'clock task asserting a twenty-four hour duration, passing every CHECK
  -- (calendar_tasks_allday_duration_chk only constrains all-day rows, and 1440 is inside
  -- BETWEEN 1 AND 1440). That is the same "a UI default leaking, not an intent" this section was
  -- written against, with 1440 substituted for the 30. Measured before and after; the probe asserts
  -- the transition in both directions so it cannot come back.
  IF p ? 'duration_minutes' THEN
    v_duration := (p->>'duration_minutes')::smallint;         -- an explicit value always wins
  ELSIF v_all_day THEN
    v_duration := 1440;                                       -- entering or staying all-day
  ELSIF coalesce(v_cur.all_day, false) THEN
    -- LEAVING all-day with no duration stated. The 1440 sitting in the column was written by this
    -- function, not chosen by anyone, so there is no intent to carry forward: fall back to exactly
    -- what a brand-new timed task gets. Note this means entering all-day DISCARDS a timed duration
    -- (45 minutes -> all-day -> timed comes back as 30, not 45). Remembering it would need a column
    -- to hold what we overwrote, which is rule 1, and 1440-forever is the worse of the two.
    v_duration := c_default_duration;
  ELSE
    v_duration := coalesce(v_cur.duration_minutes, c_default_duration);   -- timed -> timed
  END IF;
  IF v_all_day THEN
    v_duration := 1440;   -- last word: a duration sent alongside all_day is still a leaking default
  END IF;

  -- ---- completion triple -------------------------------------------------------------------
  -- Keep it coherent here rather than letting the caller trip calendar_tasks_completion_chk with
  -- an opaque 23514.
  IF v_is_complete THEN
    v_completed_at := CASE WHEN p ? 'completed_at' THEN (p->>'completed_at')::timestamptz
                                                   ELSE v_cur.completed_at END;
    v_completed_at := coalesce(v_completed_at, now());
    v_completed_source := CASE WHEN p ? 'completed_source'
                               THEN nullif(btrim(coalesce(p->>'completed_source',''), c_ws), '')
                               ELSE v_cur.completed_source END;
    IF v_completed_source IS NULL THEN
      RAISE EXCEPTION 'is_complete=true needs completed_source (calendar|jobber): completion works '
                      'from both sides and the trail has to say which one did it'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    v_completed_at     := NULL;
    v_completed_source := NULL;
  END IF;

  -- ---- write -------------------------------------------------------------------------------
  IF v_found THEN
    UPDATE ops.calendar_tasks t
       SET title = v_title, instructions = v_instructions, task_date = v_task_date,
           minutes = v_minutes, duration_minutes = v_duration, all_day = v_all_day,
           client_id = v_client_id, property_id = v_property_id, visit_id = v_visit_id,
           is_complete = v_is_complete, completed_at = v_completed_at,
           completed_source = v_completed_source
     WHERE t.id = v_task_id;
    -- 3.c again: belt and braces, in case the row vanished between the SELECT and here.
    IF NOT FOUND THEN
      RAISE EXCEPTION 'calendar task % vanished mid-update (the link row for Jobber task % is now '
                      'an orphan); refusing to report a dead id as a successful save',
                      v_task_id, v_gid
        USING ERRCODE = '23503';
    END IF;
  ELSE
    -- A stated expectation cannot be met by a row that does not exist yet. Refusing is the point:
    -- silently inserting would turn the guard into a no-op exactly when the caller was most sure.
    IF p ? 'expected_is_complete' THEN
      RAISE EXCEPTION 'expected_is_complete was stated but jobber task % is not linked to any '
                      'calendar task, so there is no current value to compare. Nothing was written.',
                      v_gid
        USING ERRCODE = 'ZZ002';
    END IF;
    INSERT INTO ops.calendar_tasks
      (title, instructions, task_date, minutes, duration_minutes, all_day,
       client_id, property_id, visit_id, is_complete, completed_at, completed_source)
    VALUES
      (v_title, v_instructions, v_task_date, v_minutes, v_duration, v_all_day,
       v_client_id, v_property_id, v_visit_id, v_is_complete, v_completed_at, v_completed_source)
    RETURNING id INTO v_task_id;

    INSERT INTO public.entity_source_links
      (entity_type, entity_id, source_system, source_id, match_method)
    VALUES ('calendar_task', v_task_id, 'jobber', v_gid, 'direct_id');
  END IF;

  -- ---- 3.b: assignees, diffed ---------------------------------------------------------------
  IF p ? 'assignee_ids' THEN
    v_arr := coalesce(nullif(p->'assignee_ids', 'null'::jsonb), '[]'::jsonb);
    IF jsonb_typeof(v_arr) <> 'array' THEN
      RAISE EXCEPTION 'assignee_ids must be a JSON array of employee ids (or null/omitted), got %',
                      jsonb_typeof(v_arr)
        USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_arr) AS e(value)
                WHERE jsonb_typeof(e.value) <> 'number') THEN
      RAISE EXCEPTION 'assignee_ids may contain only numeric employee ids: a JSON null would '
                      'survive array_agg and make the NOT-IN diff below evaluate to NULL, which '
                      'silently KEEPS the rows it was asked to delete'
        USING ERRCODE = '22023';
    END IF;

    SELECT coalesce(array_agg(DISTINCT (e.value)::text::bigint), '{}'::bigint[])
      INTO v_new_ids
      FROM jsonb_array_elements(v_arr) AS e(value);

    DELETE FROM ops.calendar_task_assignees a
     WHERE a.task_id = v_task_id
       AND NOT (a.employee_id = ANY (v_new_ids));

    INSERT INTO ops.calendar_task_assignees (task_id, employee_id)
    SELECT v_task_id, u.employee_id
      FROM unnest(v_new_ids) AS u(employee_id)
     WHERE NOT EXISTS (SELECT 1 FROM ops.calendar_task_assignees a
                        WHERE a.task_id = v_task_id AND a.employee_id = u.employee_id);
  END IF;

  RETURN v_task_id;
END;
$function$;

-- PROBE (NEW body), all rolled back: unscheduled -> scheduled -> unscheduled -> the forbidden shape.
DO $$
DECLARE v_id bigint; r ops.calendar_tasks%ROWTYPE; v_links int;
BEGIN
  v_id := ops.fn_record_calendar_task(
    jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'title', 'PROBE unscheduled (rolled back)', 'minutes', null, 'assignee_ids', '[]'::jsonb),
    'migration-probe@unclogme.com');
  SELECT * INTO r FROM ops.calendar_tasks WHERE id = v_id;
  IF r.task_date IS NOT NULL OR r.minutes IS NOT NULL OR r.all_day OR r.duration_minutes <> 30 THEN
    RAISE EXCEPTION 'probe 1: unscheduled row not as expected: date %, minutes %, all_day %, duration %', r.task_date, r.minutes, r.all_day, r.duration_minutes;
  END IF;
  SELECT count(*) INTO v_links FROM public.entity_source_links WHERE entity_type = 'calendar_task' AND entity_id = v_id AND source_id = 'PROBE-UNSCHEDULED-2026-09-16';
  IF v_links <> 1 THEN RAISE EXCEPTION 'probe 1: link row missing'; END IF;

  PERFORM ops.fn_record_calendar_task(
    jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'task_date', '2026-09-20', 'minutes', 600, 'duration_minutes', 45),
    'migration-probe@unclogme.com');
  SELECT * INTO r FROM ops.calendar_tasks WHERE id = v_id;
  IF r.task_date <> DATE '2026-09-20' OR r.minutes <> 600 OR r.all_day OR r.duration_minutes <> 45 THEN
    RAISE EXCEPTION 'probe 2: scheduled row not as expected';
  END IF;

  PERFORM ops.fn_record_calendar_task(
    jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'task_date', null, 'minutes', null),
    'migration-probe@unclogme.com');
  SELECT * INTO r FROM ops.calendar_tasks WHERE id = v_id;
  IF r.task_date IS NOT NULL OR r.minutes IS NOT NULL OR r.all_day THEN
    RAISE EXCEPTION 'probe 3: unscheduling again failed: date %, minutes %, all_day %', r.task_date, r.minutes, r.all_day;
  END IF;

  PERFORM ops.fn_record_calendar_task(
    jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'task_date', '2026-09-20', 'minutes', null),
    'migration-probe@unclogme.com');
  SELECT * INTO r FROM ops.calendar_tasks WHERE id = v_id;
  IF NOT r.all_day OR r.duration_minutes <> 1440 THEN
    RAISE EXCEPTION 'probe 4: a date with no time must still be all-day/1440';
  END IF;

  BEGIN
    PERFORM ops.fn_record_calendar_task(
      jsonb_build_object('jobber_gid', 'PROBE-UNSCHEDULED-2026-09-16', 'task_date', null, 'minutes', 600),
      'migration-probe@unclogme.com');
    RAISE EXCEPTION 'probe 5: a time without a date was ACCEPTED';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF position('no date cannot have a time' IN SQLERRM) = 0 THEN RAISE; END IF;
  END;

  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROBE_ROLLBACK';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'PROBE_ROLLBACK' THEN RAISE; END IF;
END $$;

-- VERIFY
DO $$
DECLARE d text; n_a bigint; n_b bigint;
BEGIN
  IF (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_tasks' AND column_name = 'task_date') <> 'YES' THEN
    RAISE EXCEPTION 'task_date still NOT NULL';
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'ops.calendar_tasks'::regclass AND conname = 'calendar_tasks_allday_chk')
     <> 'CHECK ((((task_date IS NULL) AND (minutes IS NULL) AND (NOT all_day)) OR ((task_date IS NOT NULL) AND (all_day = (minutes IS NULL)))))' THEN
    RAISE EXCEPTION 'calendar_tasks_allday_chk not as expected: %', (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'ops.calendar_tasks'::regclass AND conname = 'calendar_tasks_allday_chk');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'ops' AND tablename = 'calendar_tasks' AND indexname = 'calendar_tasks_unscheduled_idx') THEN
    RAISE EXCEPTION 'calendar_tasks_unscheduled_idx missing';
  END IF;
  d := pg_get_functiondef('ops.fn_record_calendar_task'::regproc);
  IF md5(d) = '1849dc1759dbbeea8033fd6672dbead6' OR position('no date cannot have a time' IN d) = 0 OR position('task_date is required' IN d) > 0 THEN
    RAISE EXCEPTION 'recorder body not as expected';
  END IF;
  IF (SELECT c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'ops' AND c.relname = 'calendar_tasks')
     <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' THEN
    RAISE EXCEPTION 'ACL changed';
  END IF;
  IF (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'ops.calendar_tasks'::regclass AND NOT tgisinternal)
     <> 'audit_calendar_tasks,trg_calendar_tasks_updated_at' THEN
    RAISE EXCEPTION 'trigger set changed';
  END IF;
  SELECT count(*) INTO n_a FROM (SELECT * FROM ct_before EXCEPT ALL SELECT * FROM ops.calendar_tasks) x;
  SELECT count(*) INTO n_b FROM (SELECT * FROM ops.calendar_tasks EXCEPT ALL SELECT * FROM ct_before) x;
  IF n_a <> 0 OR n_b <> 0 THEN RAISE EXCEPTION 'existing rows changed: % / %', n_a, n_b; END IF;
  IF EXISTS (SELECT 1 FROM public.entity_source_links WHERE source_id = 'PROBE-UNSCHEDULED-2026-09-16') THEN
    RAISE EXCEPTION 'probe link row survived the rollback';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
