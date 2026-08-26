-- 2026-08-26_1850_calendar_task_expected_guard.sql
--
-- WHAT: adds an OPTIONAL `expected_is_complete` key to ops.fn_record_calendar_task's `p` payload,
--       raising SQLSTATE ZZ002 when the stored value is not what the caller expected.
--       (Filename stamp continues the 2026-08-26_1800/_1810/_1820 sequence; applied ~18:5x ET.)
--
-- WHY: poll-calendar-tasks (Task 5) mirrors Jobber's isComplete back into ops.calendar_tasks. The
--       recorder's pg_advisory_xact_lock serialises two RECORDER calls, which is all its own header
--       claims -- but it does nothing about a read-modify-write spanning a whole SAGA.
--       save-calendar-task reads the row in its own transaction, then makes THREE HTTP round trips
--       (OAuth token, the Jobber mutation, the read-back verify), and only then calls the recorder
--       in a new transaction. The poll can land on a stale snapshot in between:
--
--         1. the poll's Jobber read returns isComplete:true for task X (completed in the mobile app)
--         2. meanwhile the office REOPENS X in the Calendar; the saga pushes completed:false,
--            verifies it, and writes is_complete=false
--         3. the poll's RPC then runs on its stale snapshot and writes is_complete=true
--
--       Our copy says complete, Jobber says open. That is precisely the discrepancy this feature
--       exists to prevent, manufactured by the safety net that was added to prevent it.
--
-- WHY A KEY IN `p` AND NOT A NEW ARGUMENT: absence of the key means no check, so every existing
--       caller is unaffected, there is no signature change, and no PostgREST schema-cache churn.
--       ops.fn_record_calendar_task stays (jsonb, text) with pronargdefaults=0.
--
-- 🛑 WHY A DISTINCT SQLSTATE: a benign race must be tellable from a malformed request. 22023 is
--       already "bad input" (48 uses across this migrations tree) and 23514 is a CHECK violation;
--       either would make the poll retry a genuinely broken payload forever, or make the saga
--       report a lost update as user error. P0001 is what a bare RAISE emits, so it is not distinct
--       either. ZZ001 is taken by the VERIFY sentinel in 2026-08-26_1820, so ZZ002 continues that
--       user-defined class. save-calendar-task's mapRpcError maps ZZ002 -> HTTP 409.
--
-- ⚠ WHAT THIS DOES NOT CLOSE. The guard compares OUR STORED VALUE, so it catches a concurrent
--       write that CHANGED our row. It cannot see a concurrent change on the JOBBER side: if the
--       office's action leaves our stored value exactly where the poll expected it, the guard
--       passes and the poll still writes. The poll narrows that residue separately, by re-reading
--       the single task's isComplete from Jobber immediately before calling this function. Two
--       narrow windows instead of one wide one -- not zero, and said out loud rather than implied.
--
-- HOW THIS FILE WAS BUILT: the body below is `pg_get_functiondef` of the LIVE function with the
--       guard spliced in at two anchors, NOT retyped. Retyping is how 2026-08-06_1316 silently
--       dropped six clauses from a live function, and this body is 242 lines of hard-won
--       constraint handling. The VERIFY block at the bottom re-exercises the behaviour that was
--       already there, not just the new guard, precisely because a CREATE OR REPLACE of a large
--       body is the moment that kind of loss happens.
--
-- Design/brief: the Task 5 build brief, section 5 (THE RACE).

BEGIN;

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
  IF v_task_date IS NULL THEN
    RAISE EXCEPTION 'task_date is required' USING ERRCODE = '22023';
  END IF;

  -- ---- 3.d, BOTH DIRECTIONS ----------------------------------------------------------------
  v_all_day := (v_minutes IS NULL);
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

COMMENT ON FUNCTION ops.fn_record_calendar_task(jsonb, text) IS
  'THE only writer of ops.calendar_tasks / ops.calendar_task_assignees. Called by the '
  'save-calendar-task edge function AFTER Jobber confirms, and by poll-calendar-tasks when it '
  'mirrors a Jobber-side completion. Resolves by jobber_gid through entity_source_links, so a retry '
  'UPDATEs instead of minting a duplicate. Patch semantics: a key present in p is written, a key '
  'absent is left alone, an explicit null clears. all_day is derived from minutes; an all-day task '
  'has duration_minutes=1440. Assignees are DIFFED on key presence. p_actor_email is required '
  '(NULL = machine actor) and lands in audit.logs.jwt_claims->>''email''. OPTIONAL '
  'expected_is_complete: when present, the stored is_complete must equal it or the call raises '
  'ZZ002 and writes nothing (optimistic concurrency against the Calendar saga).';

-- =============================================================================================
-- VERIFY -- exercise the NEW guard AND re-exercise the behaviour that was already there, because
-- a CREATE OR REPLACE of a 242-line body is exactly when a clause goes missing unnoticed.
-- PL/pgSQL is not parsed at creation time, so "CREATE OR REPLACE succeeded" proves nothing.
-- Everything below runs on a task created inside this transaction and is rolled back with it.
-- =============================================================================================
DO $verify$
DECLARE
  v_id   bigint;
  v_code text;
  v_row  ops.calendar_tasks%ROWTYPE;
  v_gid  text := 'Z2lkOi8vSm9iYmVyL1Rhc2svR1VBUkRfVkVSSUZZ';
  v_gid2 text := 'Z2lkOi8vSm9iYmVyL1Rhc2svR1VBUkRfTk9ORQ==';
  v_fail int := 0;
BEGIN
  BEGIN   -- implicit SAVEPOINT: every write below is discarded, the function replace is not
  -- ---- CONTROL 1: the function still WORKS at all (a create + an ordinary patch) -------------
  v_id := ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid', v_gid, 'title', 'Guard verify', 'task_date', '2027-01-15',
    'minutes', 540, 'duration_minutes', 45), 'verify@ayache.com');
  SELECT * INTO v_row FROM ops.calendar_tasks WHERE id = v_id;
  IF v_row.title <> 'Guard verify' OR v_row.minutes <> 540 OR v_row.duration_minutes <> 45
     OR v_row.all_day OR v_row.is_complete THEN
    RAISE EXCEPTION 'CONTROL 1 FAILED: the create path is broken: %', to_jsonb(v_row);
  END IF;

  -- ---- CONTROL 2: absence of the key must still mean NO CHECK (existing callers) -------------
  PERFORM ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid', v_gid, 'title', 'Guard verify 2'), 'verify@ayache.com');
  SELECT * INTO v_row FROM ops.calendar_tasks WHERE id = v_id;
  IF v_row.title <> 'Guard verify 2' THEN
    RAISE EXCEPTION 'CONTROL 2 FAILED: an unguarded patch no longer applies';
  END IF;
  -- and the patch left everything else alone (the property the poll's payload depends on)
  IF v_row.minutes <> 540 OR v_row.duration_minutes <> 45 OR v_row.task_date <> '2027-01-15' THEN
    RAISE EXCEPTION 'CONTROL 2b FAILED: patch semantics regressed: %', to_jsonb(v_row);
  END IF;

  -- ---- TARGET 1: a MATCHING expectation passes and writes -----------------------------------
  PERFORM ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid', v_gid, 'expected_is_complete', false,
    'is_complete', true, 'completed_at', '2027-01-14T12:00:00Z', 'completed_source', 'jobber'),
    NULL);
  SELECT * INTO v_row FROM ops.calendar_tasks WHERE id = v_id;
  IF NOT v_row.is_complete OR v_row.completed_source <> 'jobber' THEN
    RAISE EXCEPTION 'TARGET 1 FAILED: a matching expectation did not write: %', to_jsonb(v_row);
  END IF;
  IF v_row.completed_at <> '2027-01-14T12:00:00Z'::timestamptz THEN
    RAISE EXCEPTION 'TARGET 1b FAILED: completed_at was not the value supplied: %', v_row.completed_at;
  END IF;

  -- ---- TARGET 2: a STALE expectation raises ZZ002 and writes NOTHING -------------------------
  -- The row is now is_complete=true. A caller still believing false is exactly the poll landing on
  -- a stale snapshot after the office reopened the task.
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
      'jobber_gid', v_gid, 'expected_is_complete', false, 'title', 'MUST NOT BE WRITTEN'), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> 'ZZ002' THEN
    RAISE EXCEPTION 'TARGET 2 FAILED: stale expectation raised %, want ZZ002', v_code;
  END IF;
  SELECT * INTO v_row FROM ops.calendar_tasks WHERE id = v_id;
  IF v_row.title = 'MUST NOT BE WRITTEN' THEN
    RAISE EXCEPTION 'TARGET 2b FAILED: the guard raised but the write LANDED ANYWAY';
  END IF;

  -- ---- TARGET 3: the code is DISTINCT from the codes it must not collide with ----------------
  IF v_code IN ('22023', '23514', 'P0001') THEN
    RAISE EXCEPTION 'TARGET 3 FAILED: ZZ002 collides with an existing meaning';
  END IF;

  -- ---- TARGET 4: a null / non-boolean expectation is BAD INPUT (22023), not a conflict -------
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
      'jobber_gid', v_gid, 'expected_is_complete', NULL), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> '22023' THEN
    RAISE EXCEPTION 'TARGET 4 FAILED: null expectation raised %, want 22023', v_code;
  END IF;
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
      'jobber_gid', v_gid, 'expected_is_complete', 'yes'), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> '22023' THEN
    RAISE EXCEPTION 'TARGET 4b FAILED: a string expectation raised %, want 22023', v_code;
  END IF;

  -- ---- TARGET 5: stating an expectation for a task that does not exist is ZZ002, not an INSERT
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
      'jobber_gid', v_gid2, 'expected_is_complete', false,
      'title', 'ghost', 'task_date', '2027-01-15', 'minutes', 60), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> 'ZZ002' THEN
    RAISE EXCEPTION 'TARGET 5 FAILED: expectation on a non-existent task raised %, want ZZ002', v_code;
  END IF;
  IF EXISTS (SELECT 1 FROM public.entity_source_links
              WHERE entity_type='calendar_task' AND source_id = v_gid2) THEN
    RAISE EXCEPTION 'TARGET 5b FAILED: it inserted anyway';
  END IF;

  -- ---- TARGET 6: mirroring an UN-completion (true -> false) still works, with the guard -------
  PERFORM ops.fn_record_calendar_task(jsonb_build_object(
    'jobber_gid', v_gid, 'expected_is_complete', true, 'is_complete', false), NULL);
  SELECT * INTO v_row FROM ops.calendar_tasks WHERE id = v_id;
  IF v_row.is_complete OR v_row.completed_at IS NOT NULL OR v_row.completed_source IS NOT NULL THEN
    RAISE EXCEPTION 'TARGET 6 FAILED: un-completion did not clear the triple: %', to_jsonb(v_row);
  END IF;

  -- ---- CONTROL 3: the pre-existing 22023/23503 behaviour is still intact ---------------------
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object('title','x','task_date','2027-01-15'), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> '22023' THEN
    RAISE EXCEPTION 'CONTROL 3 FAILED: missing jobber_gid raised %, want 22023', v_code;
  END IF;
  BEGIN
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
      'jobber_gid', v_gid, 'all_day', NULL), NULL);
    v_code := 'NO ERROR';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> '22023' THEN
    RAISE EXCEPTION 'CONTROL 3b FAILED: all_day null raised %, want 22023', v_code;
  END IF;

  -- ---- CONTROL 4: the catcher itself works (a probe that cannot fail proves nothing) ---------
  BEGIN
    RAISE EXCEPTION 'deliberate' USING ERRCODE = 'ZZ002';
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE; END;
  IF v_code <> 'ZZ002' THEN
    RAISE EXCEPTION 'CONTROL 4 FAILED: GET STACKED DIAGNOSTICS is not reporting SQLSTATEs';
  END IF;

  -- ---- CONTROL 5: the grant surface did not widen ---------------------------------------------
  IF has_function_privilege('authenticated','ops.fn_record_calendar_task(jsonb,text)','EXECUTE')
  OR has_function_privilege('anon','ops.fn_record_calendar_task(jsonb,text)','EXECUTE') THEN
    RAISE EXCEPTION 'CONTROL 5 FAILED: CREATE OR REPLACE widened EXECUTE beyond service_role';
  END IF;
  IF NOT has_function_privilege('service_role','ops.fn_record_calendar_task(jsonb,text)','EXECUTE') THEN
    RAISE EXCEPTION 'CONTROL 5b FAILED: service_role lost EXECUTE';
  END IF;
  IF has_table_privilege('service_role','ops.calendar_tasks','INSERT') THEN
    RAISE EXCEPTION 'CONTROL 5c FAILED: a write grant appeared on ops.calendar_tasks';
  END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'verify: discard the exercise';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;   -- expected. Any OTHER error propagates and fails the apply.
  END;

  RAISE NOTICE 'VERIFY OK: guard fires on a stale expectation (ZZ002), passes on a match, is '
               'ignored when absent, refuses null/non-boolean as 22023, refuses an expectation on '
               'a missing task, mirrors un-completions, and the pre-existing behaviour + grants '
               'are intact.';
END
$verify$;

COMMIT;
