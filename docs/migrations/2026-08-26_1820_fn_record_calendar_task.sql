-- 2026-08-26_1820_fn_record_calendar_task.sql
--
-- WHAT: ops.fn_record_calendar_task / ops.fn_delete_calendar_task -- the ONLY writers of
--       ops.calendar_tasks and ops.calendar_task_assignees. SECURITY DEFINER, owned by postgres,
--       EXECUTE granted to service_role ALONE. Plus one CHECK on ops.calendar_tasks (PART 1).
--       (Filename stamp continues the 2026-08-26_1800/_1810 sequence; actually applied ~18:2x ET.)
--
-- WHY THIS IS THE SINGLE DOOR. 2026-08-26_1810 left NO role holding a write grant on either table,
--       not even service_role. So there is no PostgREST path to them at all, and every write has to
--       arrive through these functions, which the save-calendar-task edge function calls only AFTER
--       Jobber has confirmed the change. That is what makes "our copy never claims something Jobber
--       does not have" structural rather than a convention. Adding a SECDEF function is exactly the
--       privilege-laundering shape CLAUDE.md warns about ("a SECDEF function BYPASSES RLS"), and it
--       is deliberate here: the laundering IS the design, and it is bounded by the EXECUTE grant
--       being service_role-only. The VERIFY block re-reads the TABLE grants afterwards to prove
--       this migration did not widen them.
--
-- IDEMPOTENCY IS THE POINT. The edge function may retry after a network failure that actually
--       succeeded upstream, so a second call carrying the same jobber_gid must UPDATE, never mint a
--       second task. Resolution is by entity_source_links (entity_type='calendar_task',
--       source_system='jobber', source_id=<GID>) -- rule 1, there is no jobber_task_id column. An
--       xact advisory lock on the GID serialises two genuinely concurrent calls, because an upsert
--       is not a lock and idx_esl_source_id would otherwise turn a double-submit into a 23505.
--
-- PATCH SEMANTICS, UNIFORMLY: a key present in `p` is written, a key absent is left alone. That is
--       stated for assignees in the plan (`p ? 'assignee_ids'`) and is applied to every column for
--       consistency, so the poll can mirror a Jobber-side completion with
--       {jobber_gid, is_complete, completed_at, completed_source} without restating title and date.
--       An explicit JSON null CLEARS (p->>'k' is SQL NULL), which is how a task is made all-day.
--
-- ============================================================================================
-- 3.a -- CARRYING THE ACTOR, AND WHAT audit.log_change ACTUALLY READS
-- ============================================================================================
-- Read off the LIVE body with pg_get_functiondef before writing a line of this, because
-- CLAUDE.md records that the obvious column is a dead end. There are THREE identity sinks and they
-- are not equivalent:
--
--   audit.logs.changed_by  <- current_setting('request.jwt.claim.sub')   SINGULAR 'claim'.
--                             PostgREST never sets that key. NULL on all 54,756 rows, forever.
--                             Setting it is pointless AND it is a uuid column, so an email
--                             cannot go there at all.
--   audit.logs.jwt_claims  <- current_setting('request.jwt.claims')      PLURAL, a jsonb object.
--                             THIS is the one that works: CLAUDE.md's own recommended query is
--                             `jwt_claims->>'email'`, populated on 4,578 rows.
--   request_context.actor_name <- request.headers ->> 'x-actor-name'.
--                             Reachable only by overwriting the whole request.headers object,
--                             which would also blank `origin` and silently repaint app_source.
--                             Not touched.
--
-- => We set the PLURAL key, MERGED into whatever PostgREST already put there rather than replacing
--    it, so the service-role JWT's own claims survive alongside the email.
--
-- SCOPE OF THE LABEL -- MEASURED, NOT REASONED. set_config(..., is_local => true) is
--    TRANSACTION-local, not function-local: it survives the function's RETURN and ends at
--    COMMIT/ROLLBACK, which for the edge function is the end of the PostgREST request. Measured
--    2026-08-26 in a rolled-back probe: after ops.fn_record_calendar_task returned,
--    request.jwt.claims still read {"email": "..."}.
--
--    A FIRST DRAFT OF THIS HEADER ASSERTED THE OPPOSITE, and the wrong version is recorded here
--    because it was plausible enough to build a design rule on. The argument was: a function
--    carrying proconfig (any `SET` clause, or SECURITY DEFINER) is entered through
--    fmgr_security_definer, which does NewGUCNestLevel() on entry and
--    AtEOXact_GUC(true, save_nestlevel) on exit, so an inner set_config would be discarded on
--    return -- and therefore putting it in a helper with `SET search_path` would silently do
--    nothing. Measured with three throwaway pg_temp helpers writing the same GUC (no proconfig /
--    SET clause / SECDEF + SET clause): THE VALUE SURVIVED IN ALL THREE. A LOCAL setting is kept
--    to the end of the transaction; the nest-level restore covers the parameters the SET clause
--    itself named, not everything touched inside it.
--
--    => The helper's lack of a SET clause is NOT load-bearing and this file does not pretend it
--       is. What IS load-bearing is that the helper pg_catalog-qualifies every real function it
--       calls, because with no pinned search_path it runs on the CALLER's.
--    => THE CONSEQUENCE WORTH KNOWING: the label persists for the rest of the transaction. Two
--       calls in ONE transaction, the first naming a person and the second passing NULL, both land
--       under the person's name -- verified, not theorised. PostgREST runs one RPC per request per
--       transaction, so neither the edge function nor the poll can reach it; it is still a real
--       property of the mechanism rather than something to find out later.
--    => A NULL actor deliberately CHANGES NOTHING rather than stripping the 'email' key. Erasing a
--       genuine identity in order to record an anonymous one is the worse trade of the two.
--
--    The audit trigger is a plain AFTER ROW trigger, so it fires at the end of the inner
--    statement, well inside the window either way. None of this is trusted from reading it: the
--    VERIFY below and scripts/probes/calendar_task_recorder.mjs both read the email back out of a
--    real audit.logs row, and the probe asserts the inheritance behaviour above as measured fact.
--
-- ops.fn_calendar_task_set_actor is granted to NOBODY (REVOKE ALL FROM PUBLIC and no GRANT). The
--   two SECDEF functions run as its owner, postgres, so they can call it; service_role cannot, so
--   it is not a way to stamp somebody else's name on an unrelated write.
--
-- p_actor_email is a REQUIRED argument on BOTH functions, with no DEFAULT, so a caller cannot
--   forget it and quietly go back to an anonymous audit trail. NULL is legal and means "no human"
--   (the Jobber poll mirroring a completion is a machine actor) -- but it has to be passed.
--
-- DEVIATION FROM THE PLAN, stated plainly: the plan wrote fn_delete_calendar_task(p_task_id
--   bigint). It is shipped as (p_task_id bigint, p_actor_email text). A delete is a write, 3.a says
--   "before any write", and it matters MORE here than anywhere else: public.entity_source_links has
--   ZERO triggers (CLAUDE.md rule 6), so the link-row delete leaves no record of any kind. The
--   calendar_tasks audit row is the only trace the delete happened, and an unnamed actor on it is
--   the decorative audit trail 3.a exists to prevent.
--
-- ============================================================================================
-- 3.b -- ASSIGNEES ARE DIFFED, NOT REPLACED
-- ============================================================================================
-- A blanket DELETE + re-INSERT emits a DELETE and an INSERT audit row per assignee on EVERY save,
-- including saves that do not touch assignees at all, which buries the cross-user signal the
-- trigger was opted in for. So: delete only employee_id NOT IN (<new set>), insert only what is
-- missing. An unchanged set writes nothing and emits nothing.
-- A JSON null INSIDE the array is rejected rather than filtered: a NULL surviving array_agg makes
--   `employee_id = ANY(v_new_ids)` evaluate to NULL, so `NOT (...)` is NULL, so the row is NOT
--   deleted -- the diff would silently keep exactly the rows it was asked to remove.
--
-- ============================================================================================
-- 3.c -- A LINK ROW THAT OUTLIVED ITS TASK RAISES
-- ============================================================================================
-- entity_source_links is polymorphic, has no FK to anything, and cascades nothing. If a link row
-- ever survives its task, the UPDATE branch matches zero rows and the function would return a dead
-- id as a success -- and the edge function would report a save that did not happen. Guarded twice:
-- the SELECT ... FOR UPDATE raises if the task is gone, and the UPDATE re-checks IF NOT FOUND in
-- case it disappears in between.
--
-- ============================================================================================
-- 3.d -- WHAT duration_minutes MEANS ON AN ALL-DAY TASK  (PART 1 below)
-- ============================================================================================
-- THE PROBLEM: 2026-08-26_1810 ships `duration_minutes smallint NOT NULL DEFAULT 30`, so an all-day
-- row comes out `all_day=true, minutes=NULL, duration_minutes=30` -- asserting half an hour on a
-- row that claims to be all day. Two readers of the same row get two different answers.
--
-- THE RULE: an all-day task has duration_minutes = 1440. All-day means "occupies the day", and
-- 1440 is the only value that says so. The 30 is a UI default leaking, not an intent, so
-- fn_record_calendar_task NORMALISES it rather than raising: an edge function sending its form
-- default alongside all_day should not fail a perfectly ordinary create.
-- `all_day` itself is DERIVED from `minutes` (NULL <=> all-day, which is what
-- calendar_tasks_allday_chk already requires) and is never accepted as an independent field -- but
-- an explicit `all_day` in the payload that CONTRADICTS the minutes RAISES, because that is a real
-- disagreement about intent and silently picking one side is how a caller's meaning gets discarded.
-- Pinned for the bypass path by calendar_tasks_allday_duration_chk. There IS no PostgREST bypass
-- today, but `app_source='sql'` is routinely the largest writer in audit.logs (314 rows in 12 hours
-- on 2026-08-19), and that is the same argument that put a CHECK on properties.access_schedule.
-- Safe to add VALIDATED: both tables hold 0 rows.
--
-- THE OTHER HALF, AND IT IS A DELIBERATE NON-CHANGE: there is no CHECK on
-- minutes + duration_minutes <= 1440, so a timed task may run past midnight. The review flagged
-- `minutes=1430, duration_minutes=1440` (ending at minute 2870) as accepted, and it stays accepted.
-- Crossing midnight is normal in this business, not a defect: commercial routes run ~8 PM to ~6 AM
-- and 76% of properties.access_schedule entries are overnight (1,006 of 1,331). Jobber is handed
-- startAt/endAt, which crosses midnight without complaint. A cap would refuse a real overnight task
-- in order to tidy an arithmetic that is not wrong, and a CHECK cannot tell a 23:50 + 24h typo from
-- a legitimate 23:00 + 2h. The blast radius is already bounded to one day by the existing column
-- CHECK duration_minutes BETWEEN 1 AND 1440. This is the "structure tells you what a thing does,
-- never what it is for" rule: the arithmetic is odd, the business is odder, and refusing it is a
-- product decision nobody has taken.
-- A MULTI-DAY all-day task is not representable either way (it would need duration > 1440, which
--   the column CHECK forbids). Out of scope, noted so nobody reads 1440 as a cap that was chosen.
--
-- AUDIT (rule 8): no new table. Both target tables already carry audit.log_change triggers from
--       2026-08-26_1810. public.entity_source_links is deliberately NOT audited and is not changed
--       here -- see the note on the delete function above.
--
-- Design: Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-design.md
-- Probe:  scripts/probes/calendar_task_recorder.mjs  (exercises everything below; run after any edit)

BEGIN;

-- =============================================================================================
-- PART 1 -- 3.d: an all-day task lasts all day.
-- =============================================================================================
-- Guarded so the whole file stays re-runnable (rule 5): the header carries the reasoning, and a
-- reasoning correction should not require hand-picking which statements to replay.
DO $addchk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'ops.calendar_tasks'::regclass
                    AND conname  = 'calendar_tasks_allday_duration_chk') THEN
    ALTER TABLE ops.calendar_tasks
      ADD CONSTRAINT calendar_tasks_allday_duration_chk
      CHECK (NOT all_day OR duration_minutes = 1440);
  END IF;
END
$addchk$;

COMMENT ON CONSTRAINT calendar_tasks_allday_duration_chk ON ops.calendar_tasks IS
  'An all-day task occupies the day: duration_minutes = 1440. Without this an all-day row reads '
  'all_day=true, minutes=NULL, duration_minutes=30, asserting half an hour while claiming all day. '
  'ops.fn_record_calendar_task normalises it; this pins the app_source=''sql'' bypass path. '
  'A TIMED task is deliberately allowed to run past midnight (overnight routes are normal here).';

-- =============================================================================================
-- PART 2 -- the actor helper. No proconfig, no SECDEF, granted to nobody. See 3.a above.
-- =============================================================================================
CREATE OR REPLACE FUNCTION ops.fn_calendar_task_set_actor(p_actor_email text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_actor  text;
  v_claims jsonb;
BEGIN
  -- btrim() on its own strips ASCII SPACE only, so a tab/newline/NBSP-only string would sail
  -- through as a "present" actor and stamp whitespace onto the audit trail.
  -- COALESCE and NULLIF are parser CONSTRUCTS, not functions: pg_catalog.coalesce() does not
  -- exist and search_path cannot shadow them, so they are correctly unqualified here. Everything
  -- that IS a real function stays pg_catalog-qualified, because this body runs on the CALLER's
  -- search_path (no SET clause -- see the header).
  v_actor := nullif(
               pg_catalog.btrim(coalesce(p_actor_email, ''),
                                -- escape-free on purpose: a backslash class in this file has to
                                -- survive a shell heredoc, a JSON body and the Management API
                                -- before Postgres ever sees it, and it did NOT the first time.
                                pg_catalog.concat(' ', pg_catalog.chr(9), pg_catalog.chr(10),
                                                  pg_catalog.chr(13), pg_catalog.chr(160))),
                             '');   -- space, TAB, LF, CR, NBSP
  IF v_actor IS NULL THEN
    RETURN;   -- machine actor (e.g. the Jobber poll). Leave whatever PostgREST set.
  END IF;

  -- Read what is already there so a real JWT's claims survive alongside the email. A malformed or
  -- non-object value must not abort the caller's write, so the cast is guarded.
  BEGIN
    v_claims := nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_claims := NULL;
  END;
  IF pg_catalog.jsonb_typeof(v_claims) IS DISTINCT FROM 'object' THEN
    v_claims := '{}'::jsonb;
  END IF;

  -- set_config OUTSIDE the exception block above: a PL/pgSQL BEGIN..EXCEPTION is a subtransaction,
  -- and a GUC set inside one that rolls back is reverted with it.
  PERFORM pg_catalog.set_config('request.jwt.claims',
            (v_claims || pg_catalog.jsonb_build_object('email', v_actor))::text, true);
END;
$fn$;

REVOKE ALL ON FUNCTION ops.fn_calendar_task_set_actor(text)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION ops.fn_calendar_task_set_actor(text) IS
  'Sets request.jwt.claims->>email transaction-locally so audit.log_change names the person. '
  'audit.logs.changed_by reads the SINGULAR request.jwt.claim.sub, which PostgREST never sets and '
  'which is a uuid column anyway -- jwt_claims->>''email'' is the readable identity. '
  'The setting is TRANSACTION-local (measured): it survives this function AND its caller and ends '
  'with the request, so two calls in one transaction both take the first non-null actor. A NULL '
  'actor changes nothing rather than clearing the key. Every real function it calls is '
  'pg_catalog-qualified because it has no pinned search_path. '
  'Granted to nobody; callable only by its owner via the two SECDEF calendar-task functions.';

-- =============================================================================================
-- PART 3 -- the recorder. THE only writer.
-- =============================================================================================
CREATE OR REPLACE FUNCTION ops.fn_record_calendar_task(p jsonb, p_actor_email text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ops, public, pg_temp
AS $fn$
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
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'p must be a JSON object, got %', coalesce(jsonb_typeof(p), 'null')
      USING ERRCODE = '22023';
  END IF;

  PERFORM ops.fn_calendar_task_set_actor(p_actor_email);

  v_gid := nullif(btrim(coalesce(p->>'jobber_gid', '')), '');
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

  -- ---- resolve every column: key present = set, key absent = leave alone -------------------
  -- On the INSERT path v_cur is all-NULL, so coalesce supplies the table defaults for the two
  -- NOT NULL columns that have one.
  v_title        := CASE WHEN p ? 'title'            THEN btrim(coalesce(p->>'title', ''))  ELSE v_cur.title        END;
  v_instructions := CASE WHEN p ? 'instructions'     THEN p->>'instructions'                ELSE v_cur.instructions END;
  v_task_date    := CASE WHEN p ? 'task_date'        THEN (p->>'task_date')::date           ELSE v_cur.task_date    END;
  v_minutes      := CASE WHEN p ? 'minutes'          THEN (p->>'minutes')::smallint         ELSE v_cur.minutes      END;
  v_client_id    := CASE WHEN p ? 'client_id'        THEN (p->>'client_id')::bigint         ELSE v_cur.client_id    END;
  v_property_id  := CASE WHEN p ? 'property_id'      THEN (p->>'property_id')::bigint       ELSE v_cur.property_id  END;
  v_visit_id     := CASE WHEN p ? 'visit_id'         THEN (p->>'visit_id')::bigint          ELSE v_cur.visit_id     END;
  v_duration     := CASE WHEN p ? 'duration_minutes' THEN (p->>'duration_minutes')::smallint
                                                     ELSE coalesce(v_cur.duration_minutes, 30) END;
  v_is_complete  := CASE WHEN p ? 'is_complete'      THEN (p->>'is_complete')::boolean
                                                     ELSE coalesce(v_cur.is_complete, false) END;

  IF v_title IS NULL OR v_title = '' THEN
    RAISE EXCEPTION 'title is required and may not be blank (Jobber requires it too)'
      USING ERRCODE = '22023';
  END IF;
  IF v_task_date IS NULL THEN
    RAISE EXCEPTION 'task_date is required' USING ERRCODE = '22023';
  END IF;

  -- ---- 3.d ---------------------------------------------------------------------------------
  v_all_day := (v_minutes IS NULL);
  IF (p ? 'all_day') AND (p->>'all_day') IS NOT NULL
     AND (p->>'all_day')::boolean IS DISTINCT FROM v_all_day THEN
    RAISE EXCEPTION 'all_day=% contradicts minutes=%: all_day is DERIVED (all-day means no start '
                    'time), so send one or the other, not two that disagree',
                    p->>'all_day', coalesce(v_minutes::text, 'null')
      USING ERRCODE = '22023';
  END IF;
  IF v_all_day THEN
    v_duration := 1440;
  END IF;

  -- ---- completion triple -------------------------------------------------------------------
  -- Keep it coherent here rather than letting the caller trip calendar_tasks_completion_chk with
  -- an opaque 23514.
  IF v_is_complete THEN
    v_completed_at := CASE WHEN p ? 'completed_at' THEN (p->>'completed_at')::timestamptz
                                                   ELSE v_cur.completed_at END;
    v_completed_at := coalesce(v_completed_at, now());
    v_completed_source := CASE WHEN p ? 'completed_source'
                               THEN nullif(btrim(coalesce(p->>'completed_source', '')), '')
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
$fn$;

REVOKE ALL ON FUNCTION ops.fn_record_calendar_task(jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_record_calendar_task(jsonb, text) TO service_role;

COMMENT ON FUNCTION ops.fn_record_calendar_task(jsonb, text) IS
  'THE only writer of ops.calendar_tasks / ops.calendar_task_assignees. Called by the '
  'save-calendar-task edge function AFTER Jobber confirms. Resolves by jobber_gid through '
  'entity_source_links, so a retry UPDATEs instead of minting a duplicate. Patch semantics: a key '
  'present in p is written, a key absent is left alone, an explicit null clears. all_day is derived '
  'from minutes; an all-day task has duration_minutes=1440. Assignees are DIFFED on key presence. '
  'p_actor_email is required (NULL = machine actor) and lands in audit.logs.jwt_claims->>''email''.';

-- =============================================================================================
-- PART 4 -- the delete
-- =============================================================================================
CREATE OR REPLACE FUNCTION ops.fn_delete_calendar_task(p_task_id bigint, p_actor_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ops, public, pg_temp
AS $fn$
DECLARE
  v_rows integer;
BEGIN
  IF p_task_id IS NULL THEN
    RAISE EXCEPTION 'p_task_id is required' USING ERRCODE = '22023';
  END IF;

  PERFORM ops.fn_calendar_task_set_actor(p_actor_email);

  -- Link first, task second. public.entity_source_links carries NO triggers, so this delete leaves
  -- no trace anywhere; the ops.calendar_tasks audit row (with old_row and the actor email) is the
  -- only record that any of it happened. Assignees go by ON DELETE CASCADE, which still fires their
  -- own audit trigger.
  DELETE FROM public.entity_source_links l
   WHERE l.entity_type = 'calendar_task' AND l.entity_id = p_task_id;

  DELETE FROM ops.calendar_tasks t WHERE t.id = p_task_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- false, not an exception: the edge function may retry a delete that already succeeded upstream,
  -- and "it is already gone" is the outcome it asked for. It DOES report whether a task row was
  -- removed, so a caller can tell a real delete from a no-op.
  RETURN v_rows > 0;
END;
$fn$;

REVOKE ALL ON FUNCTION ops.fn_delete_calendar_task(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION ops.fn_delete_calendar_task(bigint, text) TO service_role;

COMMENT ON FUNCTION ops.fn_delete_calendar_task(bigint, text) IS
  'Removes a calendar task and its entity_source_links row (assignees cascade). Returns whether a '
  'task row was actually deleted, so a retried delete is a no-op rather than an error. '
  'p_actor_email is required and is the ONLY record of who did it: entity_source_links is unaudited.';

-- =============================================================================================
-- VERIFY -- exercise the bodies, then undo. PL/pgSQL is NOT parsed at creation time, so
-- "CREATE OR REPLACE succeeded" says nothing about whether either function runs: a 42803 sails
-- straight through and fires on the first real call. Deep coverage lives in
-- scripts/probes/calendar_task_recorder.mjs; this is the gate on the migration itself.
-- =============================================================================================
DO $verify$
DECLARE
  v_ctl_oid oid;
  v_rec_oid oid;
  v_del_oid oid;
  v_act_oid oid;
  v_id      bigint;
  v_id2     bigint;
  v_emp     bigint;
  v_n       integer;
  v_txt     text;
  v_dur     smallint;
  v_bit     boolean;
BEGIN
  -- ---- grants, by oid so no signature string can go stale ---------------------------------
  SELECT p.oid INTO v_rec_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'ops' AND p.proname = 'fn_record_calendar_task';
  SELECT p.oid INTO v_del_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'ops' AND p.proname = 'fn_delete_calendar_task';
  SELECT p.oid INTO v_act_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'ops' AND p.proname = 'fn_calendar_task_set_actor';
  -- CONTROL: ops.set_visit_status is authenticated-EXECUTABLE. If has_function_privilege stops
  -- seeing a grant that IS there, every negative assertion below is worthless.
  SELECT p.oid INTO v_ctl_oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'ops' AND p.proname = 'set_visit_status' LIMIT 1;

  IF v_rec_oid IS NULL OR v_del_oid IS NULL OR v_act_oid IS NULL THEN
    RAISE EXCEPTION 'a function this migration just created is not in pg_proc';
  END IF;
  IF v_ctl_oid IS NULL OR NOT has_function_privilege('authenticated', v_ctl_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'CONTROL FAILED: has_function_privilege cannot see a known authenticated grant';
  END IF;

  IF NOT has_function_privilege('service_role', v_rec_oid, 'EXECUTE')
  OR NOT has_function_privilege('service_role', v_del_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot EXECUTE the recorder/deleter -- the edge fn is locked out';
  END IF;
  IF has_function_privilege('anon',          v_rec_oid, 'EXECUTE')
  OR has_function_privilege('authenticated', v_rec_oid, 'EXECUTE')
  OR has_function_privilege('anon',          v_del_oid, 'EXECUTE')
  OR has_function_privilege('authenticated', v_del_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon or authenticated can EXECUTE a calendar-task writer';
  END IF;
  IF has_function_privilege('service_role',  v_act_oid, 'EXECUTE')
  OR has_function_privilege('authenticated', v_act_oid, 'EXECUTE')
  OR has_function_privilege('anon',          v_act_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'the actor helper is callable by a non-owner: identity could be stamped onto '
                    'an unrelated write';
  END IF;
  -- Pin the helper as a plain SECURITY INVOKER function. This is NOT what makes the GUC survive
  -- (measured: a LOCAL set_config survives a SET clause and SECDEF alike) -- it is here because
  -- SECDEF is the shape somebody would later feel free to GRANT, and a grantable identity-setter
  -- lets any caller stamp a name onto an unrelated write.
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_act_oid AND p.prosecdef) THEN
    RAISE EXCEPTION 'ops.fn_calendar_task_set_actor became SECURITY DEFINER';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_rec_oid AND p.prosecdef
                   AND p.proconfig @> ARRAY['search_path=ops, public, pg_temp']
                   AND pg_get_userbyid(p.proowner) = 'postgres') THEN
    RAISE EXCEPTION 'ops.fn_record_calendar_task is not SECDEF / postgres-owned / search_path-pinned';
  END IF;

  -- ---- exercise, inside a subtransaction we then throw away --------------------------------
  SELECT e.id INTO v_emp FROM public.employees e WHERE e.status = 'ACTIVE' ORDER BY e.id LIMIT 1;
  IF v_emp IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: no ACTIVE employee, cannot exercise the assignee diff';
  END IF;

  BEGIN
    v_id := ops.fn_record_calendar_task(jsonb_build_object(
              'jobber_gid', 'PROBE-VERIFY-1820', 'title', 'verify', 'task_date', current_date,
              'minutes', 540, 'assignee_ids', jsonb_build_array(v_emp)),
            'verify@probe.invalid');
    IF v_id IS NULL THEN RAISE EXCEPTION 'recorder returned NULL on insert'; END IF;

    -- idempotency: same GID, second call
    v_id2 := ops.fn_record_calendar_task(jsonb_build_object(
               'jobber_gid', 'PROBE-VERIFY-1820', 'title', 'verify edited'),
             'verify@probe.invalid');
    IF v_id2 IS DISTINCT FROM v_id THEN
      RAISE EXCEPTION 'idempotency broken: second call on the same GID returned % not %', v_id2, v_id;
    END IF;
    SELECT count(*) INTO v_n FROM ops.calendar_tasks;
    IF v_n <> 1 THEN RAISE EXCEPTION 'second call created a second task (% rows)', v_n; END IF;
    SELECT count(*) INTO v_n FROM public.entity_source_links
     WHERE entity_type = 'calendar_task' AND source_id = 'PROBE-VERIFY-1820';
    IF v_n <> 1 THEN RAISE EXCEPTION 'second call created a second link row (% rows)', v_n; END IF;
    SELECT t.title INTO v_txt FROM ops.calendar_tasks t WHERE t.id = v_id;
    IF v_txt <> 'verify edited' THEN RAISE EXCEPTION 'the UPDATE branch changed nothing'; END IF;

    -- omitting assignee_ids must leave assignees alone
    SELECT count(*) INTO v_n FROM ops.calendar_task_assignees WHERE task_id = v_id;
    IF v_n <> 1 THEN RAISE EXCEPTION 'assignees moved on a save that never mentioned them (%)', v_n; END IF;

    -- 3.a: the actor really reached audit.logs
    SELECT l.jwt_claims->>'email' INTO v_txt
      FROM audit.logs l
     WHERE l.table_schema = 'ops' AND l.table_name = 'calendar_tasks'
       AND l.record_pk = jsonb_build_object('id', v_id)
     ORDER BY l.id DESC LIMIT 1;
    IF v_txt IS DISTINCT FROM 'verify@probe.invalid' THEN
      RAISE EXCEPTION '3.a FAILED: audit.logs.jwt_claims->>email is % not the actor',
                      coalesce(v_txt, '<null>');
    END IF;

    -- 3.d: making it all-day forces 1440
    PERFORM ops.fn_record_calendar_task(jsonb_build_object(
              'jobber_gid', 'PROBE-VERIFY-1820', 'minutes', NULL), 'verify@probe.invalid');
    SELECT t.duration_minutes, t.all_day INTO v_dur, v_bit FROM ops.calendar_tasks t WHERE t.id = v_id;
    IF NOT v_bit OR v_dur <> 1440 THEN
      RAISE EXCEPTION '3.d FAILED: all_day=% duration=%', v_bit, v_dur;
    END IF;

    -- the CHECK must BITE on the bypass path (postgres writing the table directly)
    BEGIN
      UPDATE ops.calendar_tasks SET duration_minutes = 30 WHERE id = v_id;
      RAISE EXCEPTION 'calendar_tasks_allday_duration_chk did not fire on an all-day row set to 30';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- delete removes both
    IF NOT ops.fn_delete_calendar_task(v_id, 'verify@probe.invalid') THEN
      RAISE EXCEPTION 'fn_delete_calendar_task returned false on a live task';
    END IF;
    SELECT count(*) INTO v_n FROM ops.calendar_tasks WHERE id = v_id;
    IF v_n <> 0 THEN RAISE EXCEPTION 'task survived the delete'; END IF;
    SELECT count(*) INTO v_n FROM public.entity_source_links
     WHERE entity_type = 'calendar_task' AND entity_id = v_id;
    IF v_n <> 0 THEN RAISE EXCEPTION 'link row survived the delete'; END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'verify: discard the exercise';
  EXCEPTION WHEN sqlstate 'ZZ001' THEN
    NULL;   -- everything the exercise wrote is rolled back with this subtransaction
  END;

  -- prove the undo actually undid it
  SELECT count(*) INTO v_n FROM ops.calendar_tasks;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY LEAKED: ops.calendar_tasks holds % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.entity_source_links WHERE entity_type = 'calendar_task';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY LEAKED: % calendar_task link rows', v_n; END IF;

  -- the TABLE grants must not have widened. A SECDEF function is not a reason for anyone to gain
  -- direct write access, and this is the assertion that proves this migration did not do it.
  IF has_table_privilege('service_role',  'ops.calendar_tasks', 'INSERT')
  OR has_table_privilege('authenticated', 'ops.calendar_tasks', 'INSERT')
  OR has_table_privilege('service_role',  'ops.calendar_task_assignees', 'INSERT')
  OR has_table_privilege('authenticated', 'ops.calendar_task_assignees', 'INSERT') THEN
    RAISE EXCEPTION 'TABLE grants widened: something can now write around the function';
  END IF;

  RAISE NOTICE 'VERIFY OK: recorder + deleter exercised and rolled back, actor lands in audit.logs, '
               'all-day forces 1440, grants are service_role-only, table grants unchanged';
END
$verify$;

COMMIT;
