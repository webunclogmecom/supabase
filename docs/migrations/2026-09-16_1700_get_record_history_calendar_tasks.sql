-- 2026-09-16_1700_get_record_history_calendar_tasks.sql
-- The Calendar's task drawer gets the same Activity tab a visit has: public.get_record_history learns
-- ops.calendar_tasks (with its assignee child rows), audit.render_value learns to print a start time
-- and a duration in plain words, and audit.entity_render_config gets the ten rows that name the
-- task columns.
--
-- WHY (Fred, 2026-09-16, voice, on the task drawer redesign in the visit style): "Details and Activity
-- is also needed there." Claim: WORKING-NOW.md, 2026-09-16 16:3x ET, @Building Apps. Feature context:
-- docs/reference/calendar-tasks.md. The app calls supabase.rpc("get_record_history", { p_table:
-- "calendar_tasks", p_record_id: String(task.id), p_since: null, p_hide_system: false, p_limit: 50,
-- p_cursor: null }). The value is 'calendar_tasks', not 'ops.calendar_tasks': audit.logs stores
-- table_name without the schema (every task row sampled reads table_schema='ops',
-- table_name='calendar_tasks', record_pk={"id":<n>}), and ops.calendar_tasks is the only relation of
-- that name in the database (asserted in PRE 1, since `l.table_name = p_table` carries no schema).
--
-- WHAT CHANGES:
--   1. audit.render_value: the LIVE body (md5 ed46ed7e11bc3552613df2eff87e9233) plus two ADDITIVE arms
--      before the untouched ELSE:
--        'minutes'  : minutes past ET midnight -> '7:30 AM ET' (12-hour ET, suffix included, so the app
--                     must not append ET again).
--        'duration' : a length in minutes -> '45 min' | '1 hr' | '1 hr 30 min' | 'All day' (>= 1440).
--                     'All day' means the all-day state by RECORDER CONVENTION, not by a CHECK: the
--                     recorder forces duration_minutes := 1440 exactly when the task is all-day (a
--                     dateless task keeps its timed duration), but calendar_tasks_allday_duration_chk
--                     only forces 1440 WHEN all_day is true, and calendar_tasks_duration_minutes_check
--                     allows 1..1440 on a timed task, so nothing stops a timed task carrying 1440 from
--                     reading 'Duration: All day' beside a Start time. Measured 2026-09-16: no timed
--                     task has ever carried 1440 (0 live rows, 0 audit rows; 0 all-day and 0 dateless
--                     tasks exist), so the convention holds today. If the app's picker ever offers a
--                     24 hr duration on a timed task, guard it here or in the CHECK first.
--      No existing config row uses either type (live set: bool, date, datetime, fk, money, text,
--      asserted in PRE 1), so no existing Activity line changes. Ships BEFORE the config rows: an
--      unknown render_type falls to ELSE and 'Start time' would print '450' in the interval.
--   2. public.get_record_history: the LIVE body (md5 cad70179a20bcab21b561a35b1555384) with five
--      anchored splices, produced by scratchpad mkmig4.js from pg_get_functiondef (never retyped, each
--      anchor asserted to occur exactly once):
--        A. allow-list: 'calendar_tasks' admitted. The PARENT only: p_table = 'calendar_task_assignees'
--           keeps raising (control C3 in the PROBE).
--        B. child fold: a third OR arm in the src WHERE, guarded by p_table = 'calendar_tasks', folds
--           ops.calendar_task_assignees rows whose COALESCE(new_row, old_row)->>'task_id' is the task.
--           The child pk is (task_id, employee_id), so record_pk->>'id' is NULL on those rows and the
--           first arm can never match them; COALESCE(new_row, old_row) is what lets a DELETE row
--           (new_row NULL) fold by its old task_id. For p_table = 'visits' the arm is FALSE on every row.
--        C. delete-reinsert churn filter: 'calendar_task_assignees' added to the IN list. DEFENSIVE:
--           ops.fn_record_calendar_task DIFFS the assignee set (its section 3.b deletes only the rows
--           not in the new set and inserts only the missing ones; measured today: 1 DELETE and 28
--           INSERTs on calendar_task_assignees through /rpc/fn_record_calendar_task), so a same-txid
--           DELETE+INSERT of the same (task_id, employee_id) cannot occur today and this predicate is a
--           no-op until someone rewrites the RPC as delete-all-reinsert. The `- 'created_at'` in the
--           comparison is harmless: calendar_task_assignees has exactly task_id and employee_id.
--        D. the 'jobber' actor-label arm: two arms inserted BEFORE the existing INSERT arm, both
--           guarded by s.table_name so a visits, visit_team or visit_locations row can never enter them:
--             calendar_task_assignees row            -> 'Changed in Jobber' (an assignee the poll adds
--                                                        or removes is a change to the task, never a
--                                                        creation, so it must not fall into the INSERT arm)
--             calendar_tasks UPDATE flipping is_complete -> 'Completed in Jobber' / 'Reopened in Jobber'
--                                                        (completion lives in is_complete, not
--                                                        visit_status, so the visits completion arm
--                                                        cannot see it; old/new is_complete are the
--                                                        strings 'false'/'true', audit ids 200083,
--                                                        200051, 199961, 172497)
--           Both new arms carry the same ' by ' || left(actor_name_ctx, 120) suffix as the INSERT and
--           ELSE arms around them, so if the poll is ever given an x-actor-name the person is named in
--           every arm alike instead of silently vanishing from these two (PROBE rows m and n prove it
--           with a synthetic 'Poll Robot'). Everything else from the poll falls through unchanged: a
--           discovery INSERT reads 'Created in Jobber', a title/notes/date/client/property adoption
--           reads 'Changed in Jobber'. The poll sends NO x-actor-name today, so actor_name_ctx is NULL
--           and the suffix collapses to '' in every arm.
--        E. comment only: the headless-writer note now names save-calendar-task beside
--           save-calendar-visit. No behavioural change.
--      VERIFY 1 pins the POST-change md5 of both bodies, get_record_history
--      945668a62e9e499ac064136fc073605f and render_value 4615c1c1820dec241aeb1037c4b1b213, computed the
--      way pg_get_functiondef emits them (catalog header, prosrc, closing tag, newline; the same method
--      reproduces cad70179... and ed46ed7e... from the live bodies), so a stray edit anywhere in either
--      body, not only at the five anchors, fails closed.
--      NOT edited, stated so nobody adds one: the human-app arm. Once save-calendar-task sends
--      X-App-Source: visit-calendar + x-actor-name: <email> (edge fn change, deployed separately) it
--      yields 'Edited in Visit Calendar by <employees.full_name>' for create, edit, complete AND
--      delete. The email is ALREADY in jwt_claims (ops.fn_calendar_task_set_actor does
--      set_config('request.jwt.claims', claims || {email}, true); measured today: 3 INSERT, 5 UPDATE,
--      3 DELETE task rows carry jwt_claims->>'email' under role service_role) and x-actor-name is the
--      second leg of the same value, matching save-calendar-visit. actor_type already returns 'human'
--      for visit-calendar and 'system' for jobber. The changes block is keyed on c.table_name =
--      s.table_name, so the new config rows apply with no edit.
--      Historical task rows written BEFORE the headers ship keep app_source='sql' and read 'System'
--      (the ELSE); with p_hide_system=true they are hidden. Measured 2026-09-16: 167 such rows across
--      71 tasks, and 68 of those are the ENTIRE live table (the 2026-08-27 poll backfill of 35 real
--      Jobber tasks, plus 36 first seen on 2026-09-16, among them the real discoveries 247 to 251 and
--      the two test tasks 245/246; only 216, 245 and 246 were ever deleted). So every existing task's
--      'created' line, and every edit and completion before the edge functions ship, reads 'System'
--      with no actor, permanently. Do NOT add a path/email heuristic arm to relabel them: 'sql' is
--      also what a Management API or psql write produces, the poll and the saga share the same
--      /rpc/fn_record_calendar_task path, and relabelling the trail by guesswork is the failure the
--      2026-07-28 app_source incident was about. The Activity is accurate from the first row that
--      carries a header.
--   3. audit.entity_render_config: ten rows, PK (table_name, column_name), ON CONFLICT DO NOTHING (the
--      md5 pin above makes this file single-shot anyway; VERIFY reads every one of the ten back and
--      refuses a pre-existing row that differs, so DO NOTHING cannot keep a wrong label silently):
--        calendar_tasks: title/Title/text 10, instructions/Notes/text 20, task_date/Date/date 30,
--        minutes/Start time/minutes 40, duration_minutes/Duration/duration 50,
--        client_id/Client/fk clients.name 60, property_id/Property/fk properties.name 70,
--        visit_id/Visit/fk visits.title 80, is_complete/Completed/bool 90;
--        calendar_task_assignees: employee_id/Assigned to/fk employees.full_name 10.
--      The fk lookups run against public.<fk_table> (render_value formats 'public.%I'), and the FK
--      constraints on ops.calendar_tasks point at public.clients / public.properties / public.visits,
--      on ops.calendar_task_assignees at public.employees; all four label columns exist (asserted in
--      PRE 1).
--      Deliberately NOT configured: all_day (derived: task_date IS NOT NULL AND minutes IS NULL, and
--      its 'No' is ambiguous because a dateless task is all_day=false too; Date + Start time + Duration
--      already say everything, and all_day never changes without minutes or task_date changing, so the
--      UPDATE-visibility gate cannot hide an edit), completed_at (the poll writes an ESTIMATE when it
--      cannot find Jobber's timestamp and nothing marks it as a guess; the entry's own changed_at is
--      the time; it never changes without is_complete changing), completed_source ('calendar'/'jobber'
--      is a technical word and the actor label already says where), created_at/updated_at/id
--      (updated_at is stripped by log_change; created_at never changes).
--      One consequence for the app: a timed-to-all-day edit shows two lines, 'Start time: 7:30 AM ET
--      to <empty>' and 'Duration: 1 hr to All day'; render the empty side with a plain word ('none' or
--      'no time'), never a dash-only value. render_value returns NULL for SQL NULL, JSON null and ''.
--
-- UNCHANGED, ASSERTED: both signatures (no NOTIFY pgrst needed); the ACL on public.get_record_history
-- and on the ops.get_record_history wrapper (authenticated, postgres, service_role EXECUTE, 6 rows in
-- information_schema.routine_privileges); the wrapper's body byte for byte (it delegates); the 32
-- existing entity_render_config rows; the ELSE of render_value and every existing render_type's output
-- on a fixed probe row; p_hide_system semantics ('visit-calendar' and 'jobber' are always shown, only
-- NULL / 'sql' / 'other:%' are hidden); the Activity of visits 6568, client 235 and manifest 1937,
-- compared row for row before and after INSIDE this transaction, pinned by a cursor at now() so a row
-- landing from the other session cannot move the comparison.
-- CONTROL (all in the PROBE, in a rolled-back savepoint):
--   real rows: task 245 (created, assignee added, updated with Title/Notes/Date/Start time/Duration,
--   assignee removed + a different one added in the SAME txid which must NOT fold as churn, unscheduled
--   with Date and Start time going empty, deleted, assignee removed) and task 246 (Completed No -> Yes).
--   synthetic audit rows on a task id that cannot exist (-1): every new 'jobber' arm ('Created in
--   Jobber', 'Changed in Jobber' on an assignee row, 'Completed in Jobber', 'Reopened in Jobber'), the
--   ' by ' suffix on both new arms (an assignee row and a completion carrying x-actor-name 'Poll Robot'
--   read 'Changed in Jobber by Poll Robot' / 'Completed in Jobber by Poll Robot'), the
--   human arm with x-actor-name ('Edited in Visit Calendar by Fred', actor_type human), the churn fold
--   on an identical same-txid DELETE+INSERT pair, and two GUARD controls: a visits UPDATE and a
--   visit_team INSERT carrying app_source='jobber' and an is_complete key must NOT take the new arms.
--   negatives: 'zones' still refused, 'calendar_task_assignees' as p_table refused (C3), the OLD
--   function refused 'calendar_tasks' (PRE 2), and the OLD render_value printed '450' for 'minutes'.
-- REVERSIBLE: backups/2026-09-16_get_record_history_and_render_value_before_calendar_tasks.sql holds
-- both previous bodies (captured with pg_get_functiondef); delete the ten config rows.
-- SHIPS WITH (deployed AFTER this file applies; the label arms are inert until a row carries the new
-- app_source): save-calendar-task builds a per-request write client carrying x-app-source:
-- visit-calendar + x-actor-name: <the caller's email> for its 3 RPC call sites (delete, complete,
-- create/edit); poll-calendar-tasks builds a separate rpcDb client carrying x-app-source: jobber and
-- NO x-actor-name for its 2 RPC call sites (adoption, discovery). Module-level clients stay
-- header-less so the audited webhook_tokens refresh keeps its label. Exact old/new lines and the
-- deploy commands: scratchpad td/edge_fn_edits.md (this session), summarised in
-- docs/reference/calendar-tasks.md when released.
-- DRY RUN (2026-09-16, 18:3x to 18:5x ET, against Prod): this whole file with COMMIT replaced by
-- ROLLBACK ran clean, every PRE, PROBE (23 report lines) and VERIFY assertion passing; the external
-- C1 fingerprint (scratchpad td/control_history_fingerprint.sql, 30 visits + 5 clients + 5 manifests,
-- both p_hide_system values, frozen at a fixed cursor) reproduced all six (entries, md5) pairs inside
-- the same rolled-back transaction; and eight single-splice mutations (allow-list, fold, churn, jobber
-- arms, the table_name guard on the completion arm, each render arm, a config label) were each caught
-- by a different named assertion. Nothing persisted: both md5s, 32 config rows and 0 probe rows
-- re-read afterwards.
-- REVIEW EDITS AFTER THAT DRY RUN (2026-09-16, 19:0x ET, from the second-reader review): the ' by '
-- suffix on the two new jobber arms plus PROBE rows m and n that exercise it (the report is now 25
-- lines), the two post-change md5 pins in VERIFY 1 (computed locally by the method above; a wrong
-- value fails closed and prints the actual md5), and three comment corrections (the historical 'sql'
-- rows, the 'All day' convention, the PRE 3 cursor). RE-RUN THE DRY RUN BEFORE APPLYING.
-- PARALLEL SESSIONS: claim public.get_record_history, audit.render_value, audit.entity_render_config
-- and the two edge functions in WORKING-NOW.md before applying; commit with an explicit pathspec.

BEGIN;

-- PRE 1: the objects are the ones this file was written against.
DO $$
DECLARE v_grants text; v_cols text;
BEGIN
  IF md5(pg_get_functiondef('public.get_record_history'::regproc)) <> 'cad70179a20bcab21b561a35b1555384' THEN
    RAISE EXCEPTION 'public.get_record_history changed since this migration was written; re-splice from the live definition';
  END IF;
  IF md5(pg_get_functiondef('audit.render_value'::regproc)) <> 'ed46ed7e11bc3552613df2eff87e9233' THEN
    RAISE EXCEPTION 'audit.render_value changed since this migration was written; re-splice from the live definition';
  END IF;
  IF md5(pg_get_functiondef('ops.get_record_history'::regproc)) <> '99779411cd2264e7976b0775539aa7b9' THEN
    RAISE EXCEPTION 'ops.get_record_history wrapper is not the expected one';
  END IF;
  -- the config table: PK (table_name, column_name) is its only constraint, 32 rows, none for tasks yet
  IF (SELECT string_agg(conname || ':' || pg_get_constraintdef(oid), ',' ORDER BY conname)
        FROM pg_constraint WHERE conrelid = 'audit.entity_render_config'::regclass)
     <> 'entity_render_config_pkey:PRIMARY KEY (table_name, column_name)' THEN
    RAISE EXCEPTION 'audit.entity_render_config constraints are not the expected single PK';
  END IF;
  IF (SELECT count(*) FROM audit.entity_render_config) <> 32 THEN
    RAISE EXCEPTION 'audit.entity_render_config has % rows, expected 32', (SELECT count(*) FROM audit.entity_render_config);
  END IF;
  IF EXISTS (SELECT 1 FROM audit.entity_render_config WHERE table_name IN ('calendar_tasks','calendar_task_assignees')) THEN
    RAISE EXCEPTION 'audit.entity_render_config already holds calendar task rows';
  END IF;
  IF (SELECT string_agg(DISTINCT render_type, ',' ORDER BY render_type) FROM audit.entity_render_config)
     <> 'bool,date,datetime,fk,money,text' THEN
    RAISE EXCEPTION 'unexpected render_type set: %', (SELECT string_agg(DISTINCT render_type, ',' ORDER BY render_type) FROM audit.entity_render_config);
  END IF;
  -- grants on both copies: 6 rows, EXECUTE only
  SELECT string_agg(routine_schema || '.' || grantee || ':' || privilege_type, ',' ORDER BY routine_schema, grantee)
    INTO v_grants FROM information_schema.routine_privileges WHERE routine_name = 'get_record_history';
  IF v_grants <> 'ops.authenticated:EXECUTE,ops.postgres:EXECUTE,ops.service_role:EXECUTE,public.authenticated:EXECUTE,public.postgres:EXECUTE,public.service_role:EXECUTE' THEN
    RAISE EXCEPTION 'get_record_history grants are not the expected six: %', v_grants;
  END IF;
  -- the fk label columns render_value will look up (it formats public.%I)
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public'
         AND (table_name, column_name) IN (('clients','name'),('properties','name'),('visits','title'),('employees','full_name'))) <> 4 THEN
    RAISE EXCEPTION 'one of clients.name / properties.name / visits.title / employees.full_name is missing';
  END IF;
  -- l.table_name = p_table carries no schema: there must be exactly one relation of each name, in ops
  IF (SELECT string_agg(n.nspname || '.' || c.relname, ',' ORDER BY c.relname)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE c.relname IN ('calendar_tasks','calendar_task_assignees') AND c.relkind IN ('r','p','v','m'))
     <> 'ops.calendar_task_assignees,ops.calendar_tasks' THEN
    RAISE EXCEPTION 'calendar_tasks / calendar_task_assignees are not the two ops relations expected';
  END IF;
  -- both are audited, so the Activity has rows to read
  IF (SELECT count(*) FROM pg_trigger t
       WHERE t.tgrelid IN ('ops.calendar_tasks'::regclass, 'ops.calendar_task_assignees'::regclass)
         AND t.tgfoid = 'audit.log_change'::regproc AND NOT t.tgisinternal) <> 2 THEN
    RAISE EXCEPTION 'audit trigger missing on ops.calendar_tasks or ops.calendar_task_assignees';
  END IF;
  -- the child pk is (task_id, employee_id) and nothing else: the fold keys on task_id, the churn
  -- comparison subtracts a created_at that does not exist
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'calendar_task_assignees';
  IF v_cols <> 'task_id,employee_id' THEN
    RAISE EXCEPTION 'ops.calendar_task_assignees columns are %, expected task_id,employee_id', v_cols;
  END IF;
  -- every configured task column exists
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'ops' AND table_name = 'calendar_tasks'
         AND column_name IN ('title','instructions','task_date','minutes','duration_minutes','client_id','property_id','visit_id','is_complete')) <> 9 THEN
    RAISE EXCEPTION 'a configured ops.calendar_tasks column is missing';
  END IF;
END $$;

-- PRE 2 (positive controls on the OLD state): the old allow-list refuses calendar_tasks and zones, and
-- the old render_value prints the raw number for the two new types. Each must FAIL here so the
-- PROBE's success below is a change and not a vacuous pass.
DO $$
DECLARE n int; v text;
BEGIN
  BEGIN
    SELECT count(*) INTO n FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL);
    RAISE EXCEPTION 'control failed: the OLD get_record_history accepted calendar_tasks (% rows)', n;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF position('is not allowed' IN SQLERRM) = 0 THEN RAISE; END IF;
  END;
  BEGIN
    SELECT count(*) INTO n FROM public.get_record_history('zones', '1', NULL, false, 50, NULL);
    RAISE EXCEPTION 'control failed: the OLD get_record_history accepted zones';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF position('is not allowed' IN SQLERRM) = 0 THEN RAISE; END IF;
  END;
  v := audit.render_value('450'::jsonb, 'minutes', NULL, NULL);
  IF v IS DISTINCT FROM '450' THEN RAISE EXCEPTION 'control failed: OLD render_value(minutes) gave %, expected the raw 450', v; END IF;
  v := audit.render_value('1440'::jsonb, 'duration', NULL, NULL);
  IF v IS DISTINCT FROM '1440' THEN RAISE EXCEPTION 'control failed: OLD render_value(duration) gave %, expected the raw 1440', v; END IF;
END $$;

-- PRE 3: snapshots for the UNCHANGED assertions, all ON COMMIT DROP.
-- The cursor is now() (transaction-stable): a row the other session lands while this runs almost
-- always carries a later changed_at (now() is the WRITER's transaction start) and is outside the
-- window on both sides of the comparison; a long-open transaction from the other session that commits
-- mid-run would fall inside the window and fail VERIFY 6 closed, in which case re-run.
CREATE TEMP TABLE grh_probe_cursor ON COMMIT DROP AS
  SELECT jsonb_build_object('changed_at', now(), 'id', 9223372036854775807::bigint) AS c;

CREATE TEMP TABLE grh_before ON COMMIT DROP AS
  SELECT s.t, s.id, hs.hide, h.entry_id, h.changed_at, h.txid, h.actor_label, h.actor_type, h.app_source, h.operation, h.changes
  FROM (VALUES ('visits','6568'), ('clients','235'), ('derm_manifests','1937')) AS s(t, id)
  CROSS JOIN (VALUES (true), (false)) AS hs(hide)
  CROSS JOIN LATERAL public.get_record_history(s.t, s.id, NULL, hs.hide, 200, (SELECT c FROM grh_probe_cursor)) h;

CREATE TEMP TABLE erc_before ON COMMIT DROP AS SELECT * FROM audit.entity_render_config;

CREATE TEMP TABLE rv_before ON COMMIT DROP AS
  SELECT k, audit.render_value(v, t, ft, fc) AS out
  FROM (VALUES
    ('date',     '"2026-09-16"'::jsonb,           'date',     NULL, NULL),
    ('datetime', '"2026-09-16T20:01:04Z"'::jsonb, 'datetime', NULL, NULL),
    ('money',    '1234.5'::jsonb,                 'money',    NULL, NULL),
    ('bool',     'true'::jsonb,                   'bool',     NULL, NULL),
    ('fk',       '2'::jsonb,                      'fk',       'employees', 'full_name'),
    ('text',     '"abc"'::jsonb,                  'text',     NULL, NULL),
    ('null',     'null'::jsonb,                   'date',     NULL, NULL),
    ('empty',    '""'::jsonb,                     'text',     NULL, NULL)
  ) AS p(k, v, t, ft, fc);

DO $$ BEGIN
  -- the snapshots must have something in them, or the comparisons below pass on nothing
  IF (SELECT count(*) FROM grh_before WHERE t = 'visits' AND NOT hide) = 0 THEN
    RAISE EXCEPTION 'control failed: visit 6568 has no Activity rows before the change';
  END IF;
  IF (SELECT count(*) FROM grh_before WHERE t = 'clients' AND NOT hide) = 0
     OR (SELECT count(*) FROM grh_before WHERE t = 'derm_manifests' AND NOT hide) = 0 THEN
    RAISE EXCEPTION 'control failed: client 235 or manifest 1937 has no Activity rows before the change';
  END IF;
  IF (SELECT count(*) FROM rv_before WHERE out IS NOT NULL) <> 6 OR (SELECT count(*) FROM rv_before WHERE out IS NULL) <> 2 THEN
    RAISE EXCEPTION 'control failed: render_value baseline is not 6 rendered + 2 NULL';
  END IF;
  IF (SELECT out FROM rv_before WHERE k = 'fk') <> 'Fred' THEN
    RAISE EXCEPTION 'control failed: render_value fk baseline resolved employee 2 to %, expected Fred', (SELECT out FROM rv_before WHERE k = 'fk');
  END IF;
END $$;

-- 1. audit.render_value: the LIVE body (md5 ed46ed7e11bc3552613df2eff87e9233) with two additive arms,
--    'minutes' and 'duration', spliced before the untouched ELSE. Shipped BEFORE the config rows below,
--    because an unknown render_type falls to ELSE and 'Start time' would read '450' in the interval.
CREATE OR REPLACE FUNCTION audit.render_value(p_val jsonb, p_type text, p_fk_table text, p_fk_label_col text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v text; r text;
BEGIN
  IF p_val IS NULL OR p_val = 'null'::jsonb THEN RETURN NULL; END IF;
  v := p_val #>> '{}';
  IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
  CASE p_type
    WHEN 'date'     THEN RETURN pg_catalog.to_char(v::date, 'FMMon DD, YYYY');
    WHEN 'datetime' THEN RETURN pg_catalog.to_char((v::timestamptz) AT TIME ZONE 'America/New_York', 'FMMon DD, YYYY, FMHH12:MI AM') || ' ET';
    WHEN 'money'    THEN RETURN '$' || pg_catalog.to_char(v::numeric, 'FM999G999G990D00');
    WHEN 'bool'     THEN RETURN CASE WHEN v::boolean THEN 'Yes' ELSE 'No' END;
    WHEN 'fk'       THEN
      BEGIN
        EXECUTE pg_catalog.format('SELECT %I::text FROM public.%I WHERE id = $1', p_fk_label_col, p_fk_table)
          INTO r USING v::bigint;
      EXCEPTION WHEN OTHERS THEN r := NULL;
      END;
      RETURN COALESCE(r, v);
    -- minutes past ET midnight (ops.calendar_tasks.minutes, smallint). 450 -> '7:30 AM ET'.
    WHEN 'minutes'  THEN RETURN pg_catalog.to_char(('00:00'::time + pg_catalog.make_interval(mins => v::int)), 'FMHH12:MI AM') || ' ET';
    -- a length in minutes (ops.calendar_tasks.duration_minutes). The recorder forces 1440 exactly when
    -- the task is all-day, so 1440 reads as the state it encodes rather than as '24 hr'.
    WHEN 'duration' THEN RETURN CASE WHEN v::int >= 1440 THEN 'All day'
                                     WHEN v::int < 60   THEN v || ' min'
                                     WHEN v::int % 60 = 0 THEN (v::int / 60) || ' hr'
                                     ELSE (v::int / 60) || ' hr ' || (v::int % 60) || ' min' END;
    ELSE RETURN v;
  END CASE;
END;
$function$;

-- 2. public.get_record_history: the LIVE body (md5 cad70179a20bcab21b561a35b1555384) with the five
--    anchored splices listed in the header (A allow-list, B child fold, C churn filter, D jobber arm,
--    E comment). Every other byte is what was running.
CREATE OR REPLACE FUNCTION public.get_record_history(p_table text, p_record_id text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hide_system boolean DEFAULT true, p_limit integer DEFAULT 50, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(entry_id bigint, changed_at timestamp with time zone, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF p_table NOT IN ('visits','clients','derm_manifests','calendar_tasks') THEN
    RAISE EXCEPTION 'get_record_history: table % is not allowed', p_table;
  END IF;
  IF p_record_id IS NULL OR p_record_id = '' THEN
    RAISE EXCEPTION 'get_record_history: p_record_id is required';
  END IF;

  RETURN QUERY
  WITH src AS (
    SELECT l.id, l.table_name, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source,
           (l.jwt_claims->>'email')        AS actor_email,
           -- actor_effective: browser writes carry the email in jwt_claims; headless writers
           -- (save-calendar-visit, save-calendar-task) carry it in request_context.actor_name via the x-actor-name
           -- header. Prefer the JWT, fall back to the header. Kept as a SEPARATE column so the
           -- 'jobber' branch's use of actor_name_ctx (a person NAME, not an email) is untouched.
           COALESCE(NULLIF(l.jwt_claims->>'email',''),
                    NULLIF(l.request_context->>'actor_name','')) AS actor_effective,
           (l.request_context->>'actor_name') AS actor_name_ctx
    FROM audit.logs l
    WHERE (
            (l.table_name = p_table AND l.record_pk->>'id' = p_record_id)
            -- same-visit child-table changes (already-audited M:N tables)
            OR ( p_table = 'visits'
                 AND l.table_name IN ('visit_team','visit_locations')
                 AND COALESCE(l.new_row, l.old_row)->>'visit_id' = p_record_id )
            -- same-task child-table changes: ops.calendar_task_assignees, pk = (task_id, employee_id),
            -- so record_pk->>'id' is NULL on those rows and the first arm can never match them.
            OR ( p_table = 'calendar_tasks'
                 AND l.table_name = 'calendar_task_assignees'
                 AND COALESCE(l.new_row, l.old_row)->>'task_id' = p_record_id )
          )
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      -- p_hide_system suppresses ONLY raw 'sql'/'other'/null noise. Everything with a
      -- meaningful app_source (human apps + every Jobber/cron/backfill source) is ALWAYS
      -- shown (aligns with the documented intent + auto-includes new X-App-Source names).
      AND (NOT p_hide_system
           OR NOT ( l.app_source IS NULL
                    OR l.app_source = 'sql'
                    OR l.app_source LIKE 'other:%' ))
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = l.table_name
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
      -- drop delete-all-reinsert churn on the child M:N tables (no-op within a txid)
      AND NOT (
            l.table_name IN ('visit_team','visit_locations','calendar_task_assignees')
            AND l.operation IN ('INSERT','DELETE')
            AND EXISTS (
              SELECT 1 FROM audit.logs l2
              WHERE l2.table_name = l.table_name
                AND l2.txid = l.txid
                AND l2.operation IN ('INSERT','DELETE')
                AND l2.operation <> l.operation
                AND (COALESCE(l2.new_row, l2.old_row) - 'created_at')
                  = (COALESCE(l.new_row,  l.old_row)  - 'created_at')
            )
          )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
      -- Human edits in one of our apps
      WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
        THEN 'Edited in ' || pg_catalog.initcap(pg_catalog.replace(s.app_source, '-', ' '))
          || COALESCE(
               ' by ' || (SELECT e.full_name FROM public.employees e
                          WHERE pg_catalog.lower(e.email) = pg_catalog.lower(s.actor_effective)
                            AND COALESCE(e.email,'') <> ''
                          ORDER BY e.id LIMIT 1),
               CASE WHEN COALESCE(s.actor_effective,'') <> ''
                         AND s.actor_effective <> 'unclogme@unclogme.com'
                    THEN ' by ' || s.actor_effective ELSE '' END
             )
      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN
        CASE
          -- Calendar Tasks (ops.calendar_tasks), mirrored by poll-calendar-tasks with X-App-Source: jobber.
          -- An assignee child row the poll adds or removes is a CHANGE to the task, never a creation, so
          -- it must not fall into the INSERT arm below. Completion lives in is_complete, not visit_status,
          -- so the visits completion arm below cannot see it.
          WHEN s.table_name = 'calendar_task_assignees'
            THEN 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN s.table_name = 'calendar_tasks' AND s.operation = 'UPDATE'
               AND (s.old_row->>'is_complete') IS DISTINCT FROM (s.new_row->>'is_complete')
            THEN (CASE WHEN (s.new_row->>'is_complete') = 'true' THEN 'Completed in Jobber'
                       ELSE 'Reopened in Jobber' END) || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN s.operation = 'INSERT'
            THEN 'Created in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN (s.old_row->>'visit_status') IS DISTINCT FROM (s.new_row->>'visit_status')
               AND (s.new_row->>'visit_status') = 'completed'
            THEN 'Completed in Jobber' || COALESCE(' by ' || pg_catalog.btrim(pg_catalog.left(s.new_row->>'completed_by', 120)), '')
          ELSE 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
        END
      -- Automated nightly reconcile / drift-heal that pulls our DB into line with Jobber
      WHEN s.app_source LIKE '%reconcile%' OR s.app_source LIKE '%drift%'
           OR s.app_source LIKE 'jobber-daily%' OR s.app_source = 'jobber-reconcile'
        THEN 'System · Synced to match Jobber'
      -- Automated recurring / service-agreement visit generation
      WHEN s.app_source = 'service-agreement-cron' OR s.app_source LIKE 'sa-%'
           OR s.app_source LIKE '%recurring%'
        THEN 'System · Recurring-visit generator'
      -- Automated data corrections / backfills / repairs
      WHEN s.app_source LIKE '%backfill%' OR s.app_source LIKE '%correction%'
           OR s.app_source LIKE '%-fix' OR s.app_source LIKE '%-repair'
        THEN 'System · Data correction'
      -- Other scheduled/system jobs
      WHEN s.app_source LIKE '%-cron' OR s.app_source LIKE 'system:%'
        THEN 'System · Scheduled job'
      -- DUMP Schedule: the truck-QR driver tool. The DRIVER is the actor, but he has no auth
      -- identity (no login by design), so the actor is read off the visit's own assigned driver
      -- rather than actor_email. Reads as "Anthony · DUMP app created this visit".
      WHEN s.app_source = 'dump-schedule' THEN
        COALESCE(
          (SELECT e.full_name FROM public.employees e
            WHERE e.id = NULLIF(s.new_row->>'assigned_driver_id', '')::bigint
            LIMIT 1) || ' · DUMP app',
          'DUMP app')
      -- Generic backend script (Management API / psql / uncategorized)
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review','dump-schedule')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
      WHEN s.table_name <> p_table
        THEN CASE s.operation WHEN 'INSERT' THEN 'added' WHEN 'DELETE' THEN 'removed' ELSE 'updated' END
      WHEN s.operation = 'INSERT' THEN 'created'
      WHEN s.operation = 'DELETE' THEN 'deleted'
      WHEN (s.old_row->>'deleted_at') IS NULL AND (s.new_row->>'deleted_at') IS NOT NULL THEN 'deleted'
      ELSE 'updated'
    END AS operation,
    COALESCE((
      SELECT pg_catalog.jsonb_agg(
               pg_catalog.jsonb_build_object(
                 'field', c.column_name,
                 'label', c.label,
                 'old',   audit.render_value(s.old_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col),
                 'new',   audit.render_value(s.new_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col)
               ) ORDER BY c.sort_order, c.column_name)
      FROM audit.entity_render_config c
      WHERE c.table_name = s.table_name
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$;

-- 3. the render config rows (PK (table_name, column_name), asserted in PRE 1). Labels are the words
--    the drawer already uses; the two new render types are the arms added in step 1. VERIFY reads all
--    ten back, so a row that already existed with different values fails loudly instead of being kept.
INSERT INTO audit.entity_render_config (table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order) VALUES
  ('calendar_tasks',          'title',            'Title',       'text',     NULL,         NULL,        10),
  ('calendar_tasks',          'instructions',     'Notes',       'text',     NULL,         NULL,        20),
  ('calendar_tasks',          'task_date',        'Date',        'date',     NULL,         NULL,        30),
  ('calendar_tasks',          'minutes',          'Start time',  'minutes',  NULL,         NULL,        40),
  ('calendar_tasks',          'duration_minutes', 'Duration',    'duration', NULL,         NULL,        50),
  ('calendar_tasks',          'client_id',        'Client',      'fk',       'clients',    'name',      60),
  ('calendar_tasks',          'property_id',      'Property',    'fk',       'properties', 'name',      70),
  ('calendar_tasks',          'visit_id',         'Visit',       'fk',       'visits',     'title',     80),
  ('calendar_tasks',          'is_complete',      'Completed',   'bool',     NULL,         NULL,        90),
  ('calendar_task_assignees', 'employee_id',      'Assigned to', 'fk',       'employees',  'full_name', 10)
ON CONFLICT (table_name, column_name) DO NOTHING;

-- PROBE (new bodies). Part A reads the REAL audit rows of tasks 245 and 246 (both created, edited and
-- deleted on 2026-09-16; their rows are frozen because the tasks no longer exist). Part B inserts
-- synthetic audit rows on task id -1 (no such task can exist) to exercise every new label arm, the
-- churn fold and the two guards, and rolls them back. PL/pgSQL is not parsed at CREATE time, so this
-- is the first time either new body runs. The report table survives the rollback (filled from a
-- variable after the savepoint) so a dry run can print what was seen.
CREATE TEMP TABLE grh_probe_report (step text, detail text) ON COMMIT DROP;

DO $$
DECLARE
  rep text[] := '{}';
  n int; v text; j jsonb; lbl text; typ text; op text;
  t0 timestamptz := now();
  id_a bigint; id_b bigint; id_c bigint; id_d bigint; id_e bigint; id_f bigint; id_g bigint; id_g2 bigint;
  id_h bigint; id_i1 bigint; id_i2 bigint; id_j bigint; id_k bigint; id_l bigint; id_m bigint; id_n bigint;
  base_old jsonb; base_new jsonb;
BEGIN
  BEGIN
    -- ---------------- A. real rows: task 245 (8 entries) ----------------------------------------
    SELECT count(*), string_agg(entry_id::text || ':' || operation, ',' ORDER BY entry_id)
      INTO n, v FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL);
    IF n <> 8 OR v <> '200021:created,200022:added,200023:updated,200024:removed,200025:added,200040:updated,200041:deleted,200042:removed' THEN
      RAISE EXCEPTION 'probe A1: task 245 gave % rows: %', n, v;
    END IF;
    rep := rep || ('A1 task 245: ' || n::text || ' entries, ' || v);
    -- the removed+added pair (200024/200025) is the SAME txid with DIFFERENT employees: it must NOT fold as churn
    IF (SELECT count(*) FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL) WHERE entry_id IN (200024, 200025)) <> 2 THEN
      RAISE EXCEPTION 'probe A1b: a different-employee same-txid assignee pair was folded as churn';
    END IF;
    IF EXISTS (SELECT 1 FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL)
                WHERE actor_label <> 'System' OR actor_type <> 'system' OR app_source <> 'sql') THEN
      RAISE EXCEPTION 'probe A1c: a historical sql-sourced task row did not read System/system/sql';
    END IF;
    -- 200023: five configured columns changed, rendered in sort order
    SELECT changes INTO j FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL) WHERE entry_id = 200023;
    IF j <> '[{"field":"title","label":"Title","old":"SMOKE two-way task (auto-delete)","new":"SMOKE two-way task RENAMED IN JOBBER (auto-delete)"},
              {"field":"instructions","label":"Notes","old":"Poll adoption test. Safe to delete.","new":"Edited on the Jobber side."},
              {"field":"task_date","label":"Date","old":"Sep 19, 2026","new":"Sep 20, 2026"},
              {"field":"minutes","label":"Start time","old":"9:00 AM ET","new":"10:00 AM ET"},
              {"field":"duration_minutes","label":"Duration","old":"45 min","new":"1 hr"}]'::jsonb THEN
      RAISE EXCEPTION 'probe A2: entry 200023 changes not as expected: %', j;
    END IF;
    rep := rep || ('A2 entry 200023 changes: ' || j::text);
    -- 200022: the assignee child row, rendered through the employees lookup
    SELECT changes INTO j FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL) WHERE entry_id = 200022;
    IF j <> '[{"field":"employee_id","label":"Assigned to","old":null,"new":"Fred"}]'::jsonb THEN
      RAISE EXCEPTION 'probe A3: entry 200022 changes not as expected: %', j;
    END IF;
    rep := rep || ('A3 entry 200022 changes: ' || j::text);
    -- 200040: unscheduled, Date and Start time go empty (NULL from render_value, the app words it)
    SELECT changes INTO j FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL) WHERE entry_id = 200040;
    IF j <> '[{"field":"task_date","label":"Date","old":"Sep 20, 2026","new":null},
              {"field":"minutes","label":"Start time","old":"10:00 AM ET","new":null}]'::jsonb THEN
      RAISE EXCEPTION 'probe A4: entry 200040 changes not as expected: %', j;
    END IF;
    rep := rep || ('A4 entry 200040 changes: ' || j::text);
    -- 200041: the DELETE lists every configured column with its last value
    SELECT changes INTO j FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL) WHERE entry_id = 200041;
    IF jsonb_array_length(j) <> 9
       OR (SELECT count(*) FROM jsonb_array_elements(j) e WHERE e->'new' <> 'null'::jsonb) <> 0
       OR (SELECT e->>'old' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'duration_minutes') <> '1 hr'
       OR (SELECT e->>'old' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'is_complete') <> 'No' THEN
      RAISE EXCEPTION 'probe A5: entry 200041 (deleted) changes not as expected: %', j;
    END IF;
    rep := rep || ('A5 entry 200041 (deleted): ' || jsonb_array_length(j)::text || ' columns, Duration ' || (SELECT e->>'old' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'duration_minutes'));
    -- hide_system: every 245 row is 'sql', so the app's other mode shows none of them
    SELECT count(*) INTO n FROM public.get_record_history('calendar_tasks', '245', NULL, true, 50, NULL);
    IF n <> 0 THEN RAISE EXCEPTION 'probe A6: p_hide_system=true showed % sql rows for task 245', n; END IF;
    rep := rep || 'A6 task 245 with p_hide_system=true: 0 entries'::text;
    -- task 246: 7 entries, and the completion flip renders Completed No -> Yes alone
    SELECT count(*), string_agg(entry_id::text || ':' || operation, ',' ORDER BY entry_id)
      INTO n, v FROM public.get_record_history('calendar_tasks', '246', NULL, false, 50, NULL);
    IF n <> 7 OR v <> '200047:created,200048:added,200049:updated,200050:updated,200051:updated,200052:deleted,200053:removed' THEN
      RAISE EXCEPTION 'probe A7: task 246 gave % rows: %', n, v;
    END IF;
    SELECT changes INTO j FROM public.get_record_history('calendar_tasks', '246', NULL, false, 50, NULL) WHERE entry_id = 200051;
    IF j <> '[{"field":"is_complete","label":"Completed","old":"No","new":"Yes"}]'::jsonb THEN
      RAISE EXCEPTION 'probe A8: entry 200051 changes not as expected: %', j;
    END IF;
    rep := rep || ('A7 task 246: ' || n::text || ' entries, ' || v) || ('A8 entry 200051 changes: ' || j::text);
    -- the p_limit / p_cursor contract is untouched: 3 newest, then the next page from the cursor
    SELECT count(*), string_agg(entry_id::text, ',' ORDER BY entry_id DESC) INTO n, v
      FROM public.get_record_history('calendar_tasks', '246', NULL, false, 3, NULL);
    IF n <> 3 OR v <> '200053,200052,200051' THEN RAISE EXCEPTION 'probe A9: p_limit 3 gave % rows: %', n, v; END IF;
    SELECT count(*), string_agg(entry_id::text, ',' ORDER BY entry_id DESC) INTO n, v
      FROM public.get_record_history('calendar_tasks', '246', NULL, false, 50,
             (SELECT jsonb_build_object('changed_at', changed_at, 'id', entry_id)
                FROM public.get_record_history('calendar_tasks', '246', NULL, false, 3, NULL) ORDER BY entry_id LIMIT 1));
    IF n <> 4 OR v <> '200050,200049,200048,200047' THEN RAISE EXCEPTION 'probe A9b: the page after the cursor gave % rows: %', n, v; END IF;
    rep := rep || 'A9 p_limit 3 + cursor page: 200053,200052,200051 then 200050,200049,200048,200047'::text;

    -- ---------------- negatives (C3): only the PARENT table was admitted -------------------------
    BEGIN
      SELECT count(*) INTO n FROM public.get_record_history('calendar_task_assignees', '245', NULL, false, 50, NULL);
      RAISE EXCEPTION 'probe N1: calendar_task_assignees was ACCEPTED as p_table (% rows)', n;
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      IF position('is not allowed' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;
    BEGIN
      SELECT count(*) INTO n FROM public.get_record_history('zones', '1', NULL, false, 50, NULL);
      RAISE EXCEPTION 'probe N2: zones was ACCEPTED as p_table';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      IF position('is not allowed' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;
    BEGIN
      SELECT count(*) INTO n FROM public.get_record_history('calendar_tasks', '', NULL, false, 50, NULL);
      RAISE EXCEPTION 'probe N3: an empty p_record_id was accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
      IF position('p_record_id is required' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;
    rep := rep || 'N1-N3 calendar_task_assignees, zones and an empty id are still refused'::text;

    -- ---------------- B. synthetic rows on task -1: every new arm, the fold, the guards ------------
    base_new := jsonb_build_object('id', -1, 'title', 'PROBE task', 'instructions', NULL, 'task_date', '2026-09-20',
                                   'minutes', 450, 'duration_minutes', 90, 'all_day', false, 'client_id', NULL,
                                   'property_id', NULL, 'visit_id', NULL, 'is_complete', false, 'completed_at', NULL,
                                   'completed_source', NULL, 'created_at', t0);
    -- a. discovery INSERT from the poll
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'INSERT', NULL, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '1 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900001)
    RETURNING id INTO id_a;
    -- b. an assignee the poll adds, same txid as the discovery
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_task_assignees', '{"task_id":-1,"employee_id":2}', 'INSERT', NULL, '{"task_id":-1,"employee_id":2}', 'postgres', '{"role":"service_role"}',
            t0 + interval '2 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900001)
    RETURNING id INTO id_b;
    -- c. completion adopted from Jobber
    base_old := base_new;
    base_new := base_old || jsonb_build_object('is_complete', true, 'completed_at', t0, 'completed_source', 'jobber');
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '3 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900002)
    RETURNING id INTO id_c;
    -- d. reopened from Jobber
    base_old := base_new;
    base_new := base_old || jsonb_build_object('is_complete', false, 'completed_at', NULL, 'completed_source', NULL);
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '4 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900003)
    RETURNING id INTO id_d;
    -- e. a title adoption
    base_old := base_new;
    base_new := base_old || jsonb_build_object('title', 'PROBE task renamed');
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '5 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900004)
    RETURNING id INTO id_e;
    -- f. timed -> all-day (minutes NULL, duration forced to 1440, all_day true)
    base_old := base_new;
    base_new := base_old || jsonb_build_object('minutes', NULL, 'duration_minutes', 1440, 'all_day', true);
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '6 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900005)
    RETURNING id INTO id_f;
    -- g. an edit from the Calendar saga: email in jwt_claims (fn_calendar_task_set_actor) AND the header
    base_old := base_new;
    base_new := base_old || jsonb_build_object('instructions', 'PROBE notes');
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role","email":"fred@ayache.com"}',
            t0 + interval '7 millisecond', 'visit-calendar',
            '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"visit-calendar","actor_name":"fred@ayache.com"}', 900006)
    RETURNING id INTO id_g;
    -- g2. the header alone (no email in jwt_claims): the second leg must still name the person
    base_old := base_new;
    base_new := base_old || jsonb_build_object('title', 'PROBE task renamed twice');
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_old, base_new, 'postgres', '{"role":"service_role"}',
            t0 + interval '8 millisecond', 'visit-calendar',
            '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"visit-calendar","actor_name":"fred@ayache.com"}', 900007)
    RETURNING id INTO id_g2;
    -- h. an assignee removed from the Calendar (a DELETE row: new_row NULL, folds by old task_id)
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_task_assignees', '{"task_id":-1,"employee_id":2}', 'DELETE', '{"task_id":-1,"employee_id":2}', NULL, 'postgres', '{"role":"service_role","email":"fred@ayache.com"}',
            t0 + interval '9 millisecond', 'visit-calendar',
            '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"visit-calendar","actor_name":"fred@ayache.com"}', 900008)
    RETURNING id INTO id_h;
    -- i. delete-all-reinsert churn: the SAME (task_id, employee_id) deleted and re-inserted in ONE txid
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_task_assignees', '{"task_id":-1,"employee_id":1}', 'DELETE', '{"task_id":-1,"employee_id":1}', NULL, 'postgres', '{"role":"service_role"}',
            t0 + interval '10 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900009)
    RETURNING id INTO id_i1;
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_task_assignees', '{"task_id":-1,"employee_id":1}', 'INSERT', NULL, '{"task_id":-1,"employee_id":1}', 'postgres', '{"role":"service_role"}',
            t0 + interval '11 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber"}', 900009)
    RETURNING id INTO id_i2;
    -- j. a raw sql delete: shown with p_hide_system=false, hidden with true
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'DELETE', base_new, NULL, 'postgres', NULL,
            t0 + interval '12 millisecond', 'sql', NULL, 900010)
    RETURNING id INTO id_j;
    -- k. GUARD: a visits UPDATE from Jobber carrying an is_complete key must not read as a task completion
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('public', 'visits', '{"id":-1}', 'UPDATE',
            '{"id":-1,"notes":"PROBE a","is_complete":"false","visit_status":"scheduled"}',
            '{"id":-1,"notes":"PROBE b","is_complete":"true","visit_status":"scheduled"}',
            'postgres', '{"role":"service_role"}', t0 + interval '13 millisecond', 'jobber', '{"path":"/rpc/adopt_visit_schedule_from_jobber","method":"POST","app_source_hint":"jobber"}', 900011)
    RETURNING id INTO id_k;
    -- l. GUARD: a visit_team INSERT from Jobber keeps the existing 'Created in Jobber' label
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('public', 'visit_team', '{"visit_id":-1,"employee_id":2}', 'INSERT', NULL, '{"visit_id":-1,"employee_id":2}',
            'postgres', '{"role":"service_role"}', t0 + interval '14 millisecond', 'jobber', '{"path":"/rpc/adopt_visit_schedule_from_jobber","method":"POST","app_source_hint":"jobber"}', 900012)
    RETURNING id INTO id_l;
    -- m. the ' by ' suffix on the assignee arm: an assignee the poll adds WITH an x-actor-name (the poll
    --    sends none today; this proves the suffix is wired, not that it fires)
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_task_assignees', '{"task_id":-1,"employee_id":2}', 'INSERT', NULL, '{"task_id":-1,"employee_id":2}', 'postgres', '{"role":"service_role"}',
            t0 + interval '15 millisecond', 'jobber', '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber","actor_name":"Poll Robot"}', 900013)
    RETURNING id INTO id_m;
    -- n. the ' by ' suffix on the completion arm: a completion adopted WITH an x-actor-name
    INSERT INTO audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    VALUES ('ops', 'calendar_tasks', '{"id":-1}', 'UPDATE', base_new,
            base_new || jsonb_build_object('is_complete', true, 'completed_at', t0, 'completed_source', 'jobber'),
            'postgres', '{"role":"service_role"}', t0 + interval '16 millisecond', 'jobber',
            '{"path":"/rpc/fn_record_calendar_task","method":"POST","app_source_hint":"jobber","actor_name":"Poll Robot"}', 900014)
    RETURNING id INTO id_n;

    -- B1: the task's Activity shows a, b, c, d, e, f, g, g2, h, j, m, n (the churn pair i folds away) = 12
    SELECT count(*) INTO n FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL);
    IF n <> 12 THEN RAISE EXCEPTION 'probe B1: synthetic task gave % entries, expected 12', n; END IF;
    IF EXISTS (SELECT 1 FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id IN (id_i1, id_i2)) THEN
      RAISE EXCEPTION 'probe B1b: the identical same-txid DELETE+INSERT assignee pair was NOT folded';
    END IF;
    IF (SELECT count(*) FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id IN (id_a,id_b,id_c,id_d,id_e,id_f,id_g,id_g2,id_h,id_j,id_m,id_n)) <> 12 THEN
      RAISE EXCEPTION 'probe B1c: a synthetic row is missing from the Activity';
    END IF;
    rep := rep || 'B1 synthetic task: 12 entries, churn pair folded, every other row present'::text;
    -- B2: hide_system keeps jobber and visit-calendar, drops sql
    SELECT count(*) INTO n FROM public.get_record_history('calendar_tasks', '-1', NULL, true, 50, NULL);
    IF n <> 11 OR EXISTS (SELECT 1 FROM public.get_record_history('calendar_tasks', '-1', NULL, true, 50, NULL) WHERE entry_id = id_j) THEN
      RAISE EXCEPTION 'probe B2: p_hide_system=true gave % entries (expected 11, without the sql row)', n;
    END IF;
    rep := rep || 'B2 p_hide_system=true: 11 entries, the sql row hidden, jobber and visit-calendar kept'::text;
    -- B3: the labels, one per arm
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_a;
    IF lbl <> 'Created in Jobber' OR typ <> 'system' OR op <> 'created' OR jsonb_array_length(j) <> 9
       OR (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'minutes') <> '7:30 AM ET'
       OR (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'duration_minutes') <> '1 hr 30 min'
       OR (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'task_date') <> 'Sep 20, 2026'
       OR (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'is_complete') <> 'No' THEN
      RAISE EXCEPTION 'probe B3a: discovery INSERT read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3a discovery: ' || lbl || ' / ' || typ || ' / ' || op || ' / Start time ' || (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'minutes') || ', Duration ' || (SELECT e->>'new' FROM jsonb_array_elements(j) e WHERE e->>'field' = 'duration_minutes'));
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_b;
    IF lbl <> 'Changed in Jobber' OR typ <> 'system' OR op <> 'added' OR j <> '[{"field":"employee_id","label":"Assigned to","old":null,"new":"Fred"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3b: assignee INSERT from the poll read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3b assignee added by the poll: ' || lbl || ' / ' || op || ' / ' || j::text);
    SELECT actor_label, operation, changes INTO lbl, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_c;
    IF lbl <> 'Completed in Jobber' OR op <> 'updated' OR j <> '[{"field":"is_complete","label":"Completed","old":"No","new":"Yes"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3c: completion from the poll read % / % with %', lbl, op, j;
    END IF;
    rep := rep || ('B3c completion adopted: ' || lbl || ' / ' || op || ' / ' || j::text);
    SELECT actor_label, operation, changes INTO lbl, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_d;
    IF lbl <> 'Reopened in Jobber' OR op <> 'updated' OR j <> '[{"field":"is_complete","label":"Completed","old":"Yes","new":"No"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3d: reopen from the poll read % / % with %', lbl, op, j;
    END IF;
    rep := rep || ('B3d reopened: ' || lbl || ' / ' || op || ' / ' || j::text);
    SELECT actor_label, operation, changes INTO lbl, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_e;
    IF lbl <> 'Changed in Jobber' OR op <> 'updated' OR j <> '[{"field":"title","label":"Title","old":"PROBE task","new":"PROBE task renamed"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3e: title adoption read % / % with %', lbl, op, j;
    END IF;
    rep := rep || ('B3e title adopted: ' || lbl || ' / ' || op || ' / ' || j::text);
    SELECT actor_label, operation, changes INTO lbl, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_f;
    IF lbl <> 'Changed in Jobber' OR op <> 'updated'
       OR j <> '[{"field":"minutes","label":"Start time","old":"7:30 AM ET","new":null},{"field":"duration_minutes","label":"Duration","old":"1 hr 30 min","new":"All day"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3f: timed-to-all-day read % / % with %', lbl, op, j;
    END IF;
    rep := rep || ('B3f timed to all-day: ' || lbl || ' / ' || j::text);
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_g;
    IF lbl <> 'Edited in Visit Calendar by Fred' OR typ <> 'human' OR op <> 'updated'
       OR j <> '[{"field":"instructions","label":"Notes","old":null,"new":"PROBE notes"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3g: Calendar edit (jwt email + header) read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3g Calendar edit, jwt email + header: ' || lbl || ' / ' || typ || ' / ' || j::text);
    SELECT actor_label, actor_type INTO lbl, typ FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_g2;
    IF lbl <> 'Edited in Visit Calendar by Fred' OR typ <> 'human' THEN
      RAISE EXCEPTION 'probe B3g2: Calendar edit (header only) read % / %', lbl, typ;
    END IF;
    rep := rep || ('B3g2 Calendar edit, header only: ' || lbl || ' / ' || typ);
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_h;
    IF lbl <> 'Edited in Visit Calendar by Fred' OR typ <> 'human' OR op <> 'removed'
       OR j <> '[{"field":"employee_id","label":"Assigned to","old":"Fred","new":null}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3h: assignee removed from the Calendar read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3h assignee removed from the Calendar: ' || lbl || ' / ' || op || ' / ' || j::text);
    SELECT actor_label, actor_type, operation INTO lbl, typ, op FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_j;
    IF lbl <> 'System' OR typ <> 'system' OR op <> 'deleted' THEN
      RAISE EXCEPTION 'probe B3j: raw sql delete read % / % / %', lbl, typ, op;
    END IF;
    rep := rep || ('B3j raw sql delete: ' || lbl || ' / ' || typ || ' / ' || op);
    -- B3m / B3n: the two new arms carry the ' by ' suffix like their neighbours (inert today: the poll
    -- sends no x-actor-name, so rows b, c and d above read the bare label)
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_m;
    IF lbl <> 'Changed in Jobber by Poll Robot' OR typ <> 'system' OR op <> 'added'
       OR j <> '[{"field":"employee_id","label":"Assigned to","old":null,"new":"Fred"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3m: assignee INSERT from the poll WITH x-actor-name read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3m assignee added by the poll with x-actor-name: ' || lbl || ' / ' || op);
    SELECT actor_label, actor_type, operation, changes INTO lbl, typ, op, j FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id = id_n;
    IF lbl <> 'Completed in Jobber by Poll Robot' OR typ <> 'system' OR op <> 'updated'
       OR j <> '[{"field":"is_complete","label":"Completed","old":"No","new":"Yes"}]'::jsonb THEN
      RAISE EXCEPTION 'probe B3n: completion from the poll WITH x-actor-name read % / % / % with %', lbl, typ, op, j;
    END IF;
    rep := rep || ('B3n completion adopted with x-actor-name: ' || lbl || ' / ' || op);
    -- B4: GUARDS. The visits row must take the OLD paths: the UPDATE reads 'Changed in Jobber' (not a
    -- task completion), the visit_team INSERT reads 'Created in Jobber' (not the assignee arm).
    SELECT count(*) INTO n FROM public.get_record_history('visits', '-1', NULL, false, 50, NULL);
    IF n <> 2 THEN RAISE EXCEPTION 'probe B4: synthetic visit gave % entries, expected 2', n; END IF;
    SELECT actor_label, operation INTO lbl, op FROM public.get_record_history('visits', '-1', NULL, false, 50, NULL) WHERE entry_id = id_k;
    IF lbl <> 'Changed in Jobber' OR op <> 'updated' THEN
      RAISE EXCEPTION 'probe B4k: a visits UPDATE with an is_complete key read % / % (the task arm leaked)', lbl, op;
    END IF;
    SELECT actor_label, operation INTO lbl, op FROM public.get_record_history('visits', '-1', NULL, false, 50, NULL) WHERE entry_id = id_l;
    IF lbl <> 'Created in Jobber' OR op <> 'added' THEN
      RAISE EXCEPTION 'probe B4l: a visit_team INSERT read % / % (the assignee arm leaked)', lbl, op;
    END IF;
    -- and the task's own Activity never picked up the visits rows
    IF EXISTS (SELECT 1 FROM public.get_record_history('calendar_tasks', '-1', NULL, false, 50, NULL) WHERE entry_id IN (id_k, id_l)) THEN
      RAISE EXCEPTION 'probe B4x: a visits or visit_team row appeared in the task Activity';
    END IF;
    rep := rep || 'B4 guards: visits UPDATE = Changed in Jobber, visit_team INSERT = Created in Jobber, neither in the task Activity'::text;
    -- B5: the mutation control for the label arms: the same rows read through the OLD label logic
    -- cannot be run (the old body is gone), so the guard rows above ARE the control: two rows that
    -- differ from the task rows only by table_name read the old labels. Recorded, not asserted twice.

    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROBE_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'PROBE_ROLLBACK' THEN RAISE; END IF;
  END;
  -- the synthetic rows are gone with the savepoint; the report is not
  INSERT INTO grh_probe_report SELECT lpad(o::text, 2, '0'), r FROM unnest(rep) WITH ORDINALITY AS u(r, o);
END $$;

-- VERIFY
CREATE TEMP TABLE grh_after ON COMMIT DROP AS
  SELECT s.t, s.id, hs.hide, h.entry_id, h.changed_at, h.txid, h.actor_label, h.actor_type, h.app_source, h.operation, h.changes
  FROM (VALUES ('visits','6568'), ('clients','235'), ('derm_manifests','1937')) AS s(t, id)
  CROSS JOIN (VALUES (true), (false)) AS hs(hide)
  CROSS JOIN LATERAL public.get_record_history(s.t, s.id, NULL, hs.hide, 200, (SELECT c FROM grh_probe_cursor)) h;

DO $$
DECLARE d text; v_grants text; n_a bigint; n_b bigint; v text;
BEGIN
  -- 1. the bodies moved, and only where intended
  d := pg_get_functiondef('public.get_record_history'::regproc);
  IF md5(d) = 'cad70179a20bcab21b561a35b1555384'
     OR position($a$IF p_table NOT IN ('visits','clients','derm_manifests','calendar_tasks') THEN$a$ IN d) = 0
     OR position($a$AND COALESCE(l.new_row, l.old_row)->>'task_id' = p_record_id )$a$ IN d) = 0
     OR position($a$l.table_name IN ('visit_team','visit_locations','calendar_task_assignees')$a$ IN d) = 0
     OR position($a$ELSE 'Reopened in Jobber' END) ||$a$ IN d) = 0
     OR position($a$WHEN s.table_name = 'calendar_task_assignees'$a$ IN d) = 0 THEN
    RAISE EXCEPTION 'public.get_record_history body not as expected';
  END IF;
  -- and the WHOLE body is the intended one, not only the five anchors
  IF md5(d) <> '945668a62e9e499ac064136fc073605f' THEN
    RAISE EXCEPTION 'public.get_record_history post-change md5 is %, expected 945668a62e9e499ac064136fc073605f', md5(d);
  END IF;
  d := pg_get_functiondef('audit.render_value'::regproc);
  IF md5(d) = 'ed46ed7e11bc3552613df2eff87e9233'
     OR position($a$WHEN 'minutes'  THEN RETURN$a$ IN d) = 0
     OR position($a$WHEN 'duration' THEN RETURN CASE WHEN v::int >= 1440 THEN 'All day'$a$ IN d) = 0
     OR position($a$    ELSE RETURN v;$a$ IN d) = 0 THEN
    RAISE EXCEPTION 'audit.render_value body not as expected';
  END IF;
  IF md5(d) <> '4615c1c1820dec241aeb1037c4b1b213' THEN
    RAISE EXCEPTION 'audit.render_value post-change md5 is %, expected 4615c1c1820dec241aeb1037c4b1b213', md5(d);
  END IF;
  -- 2. the wrapper is byte-identical and still delegates to the widened function
  IF md5(pg_get_functiondef('ops.get_record_history'::regproc)) <> '99779411cd2264e7976b0775539aa7b9' THEN
    RAISE EXCEPTION 'ops.get_record_history wrapper changed';
  END IF;
  IF (SELECT count(*) FROM ops.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL)) <> 8
     OR (SELECT count(*) FROM ops.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL))
        <> (SELECT count(*) FROM public.get_record_history('calendar_tasks', '245', NULL, false, 50, NULL)) THEN
    RAISE EXCEPTION 'ops.get_record_history does not serve calendar_tasks like the public function';
  END IF;
  -- 3. grants: the same six rows (CREATE OR REPLACE keeps the ACL; this proves it rather than assumes it)
  SELECT string_agg(routine_schema || '.' || grantee || ':' || privilege_type, ',' ORDER BY routine_schema, grantee)
    INTO v_grants FROM information_schema.routine_privileges WHERE routine_name = 'get_record_history';
  IF v_grants <> 'ops.authenticated:EXECUTE,ops.postgres:EXECUTE,ops.service_role:EXECUTE,public.authenticated:EXECUTE,public.postgres:EXECUTE,public.service_role:EXECUTE' THEN
    RAISE EXCEPTION 'get_record_history grants changed: %', v_grants;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.get_record_history(text,text,timestamptz,boolean,integer,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.get_record_history(text,text,timestamptz,boolean,integer,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.get_record_history(text,text,timestamptz,boolean,integer,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'get_record_history EXECUTE is not authenticated-yes / anon-no';
  END IF;
  -- 4. config: 32 -> 42, the 32 untouched, the 10 exactly as intended
  IF (SELECT count(*) FROM audit.entity_render_config) <> 42 THEN
    RAISE EXCEPTION 'audit.entity_render_config has % rows, expected 42', (SELECT count(*) FROM audit.entity_render_config);
  END IF;
  SELECT count(*) INTO n_a FROM (SELECT * FROM erc_before EXCEPT ALL SELECT * FROM audit.entity_render_config) x;
  SELECT count(*) INTO n_b FROM (SELECT * FROM audit.entity_render_config WHERE table_name NOT IN ('calendar_tasks','calendar_task_assignees') EXCEPT ALL SELECT * FROM erc_before) x;
  IF n_a <> 0 OR n_b <> 0 THEN RAISE EXCEPTION 'existing entity_render_config rows changed: % / %', n_a, n_b; END IF;
  SELECT count(*) INTO n_a FROM (
    SELECT table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order
      FROM audit.entity_render_config WHERE table_name IN ('calendar_tasks','calendar_task_assignees')
    EXCEPT ALL
    SELECT * FROM (VALUES
      ('calendar_tasks','title','Title','text',NULL::text,NULL::text,10),
      ('calendar_tasks','instructions','Notes','text',NULL,NULL,20),
      ('calendar_tasks','task_date','Date','date',NULL,NULL,30),
      ('calendar_tasks','minutes','Start time','minutes',NULL,NULL,40),
      ('calendar_tasks','duration_minutes','Duration','duration',NULL,NULL,50),
      ('calendar_tasks','client_id','Client','fk','clients','name',60),
      ('calendar_tasks','property_id','Property','fk','properties','name',70),
      ('calendar_tasks','visit_id','Visit','fk','visits','title',80),
      ('calendar_tasks','is_complete','Completed','bool',NULL,NULL,90),
      ('calendar_task_assignees','employee_id','Assigned to','fk','employees','full_name',10)
    ) AS w(table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order)) x;
  IF n_a <> 0 OR (SELECT count(*) FROM audit.entity_render_config WHERE table_name IN ('calendar_tasks','calendar_task_assignees')) <> 10 THEN
    RAISE EXCEPTION 'the ten task config rows do not read exactly as intended (% unexpected)', n_a;
  END IF;
  -- 5. render_value: every existing type gives what it gave before; the two new types render; NULL stays NULL
  IF EXISTS (
    SELECT 1 FROM rv_before b
    JOIN (VALUES
      ('date',     '"2026-09-16"'::jsonb,           'date',     NULL, NULL),
      ('datetime', '"2026-09-16T20:01:04Z"'::jsonb, 'datetime', NULL, NULL),
      ('money',    '1234.5'::jsonb,                 'money',    NULL, NULL),
      ('bool',     'true'::jsonb,                   'bool',     NULL, NULL),
      ('fk',       '2'::jsonb,                      'fk',       'employees', 'full_name'),
      ('text',     '"abc"'::jsonb,                  'text',     NULL, NULL),
      ('null',     'null'::jsonb,                   'date',     NULL, NULL),
      ('empty',    '""'::jsonb,                     'text',     NULL, NULL)
    ) AS p(k, v, t, ft, fc) ON p.k = b.k
    WHERE audit.render_value(p.v, p.t, p.ft, p.fc) IS DISTINCT FROM b.out) THEN
    RAISE EXCEPTION 'an existing render_type renders differently after the change';
  END IF;
  IF (SELECT out FROM rv_before WHERE k = 'date') <> 'Sep 16, 2026'
     OR (SELECT out FROM rv_before WHERE k = 'datetime') <> 'Sep 16, 2026, 4:01 PM ET'
     OR (SELECT out FROM rv_before WHERE k = 'money') <> '$1,234.50'
     OR (SELECT out FROM rv_before WHERE k = 'bool') <> 'Yes'
     OR (SELECT out FROM rv_before WHERE k = 'text') <> 'abc' THEN
    RAISE EXCEPTION 'the render_value baseline itself is not the documented output';
  END IF;
  SELECT string_agg(audit.render_value(to_jsonb(m), 'minutes', NULL, NULL), ' | ' ORDER BY o) INTO v
    FROM unnest(ARRAY[450, 0, 1439, 540, 780]) WITH ORDINALITY AS u(m, o);
  IF v <> '7:30 AM ET | 12:00 AM ET | 11:59 PM ET | 9:00 AM ET | 1:00 PM ET' THEN
    RAISE EXCEPTION 'render_value(minutes) gave: %', v;
  END IF;
  SELECT string_agg(audit.render_value(to_jsonb(m), 'duration', NULL, NULL), ' | ' ORDER BY o) INTO v
    FROM unnest(ARRAY[45, 60, 90, 1440, 30, 120, 1, 1500]) WITH ORDINALITY AS u(m, o);
  IF v <> '45 min | 1 hr | 1 hr 30 min | All day | 30 min | 2 hr | 1 min | All day' THEN
    RAISE EXCEPTION 'render_value(duration) gave: %', v;
  END IF;
  IF audit.render_value('null'::jsonb, 'minutes', NULL, NULL) IS NOT NULL
     OR audit.render_value(NULL, 'duration', NULL, NULL) IS NOT NULL
     OR audit.render_value('""'::jsonb, 'minutes', NULL, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'render_value must return NULL for null / SQL NULL / empty on the new types';
  END IF;
  -- 6. the Activity of a visit, a client and a manifest is row-for-row what it was (VISITS CONTROL)
  SELECT count(*) INTO n_a FROM (SELECT * FROM grh_before EXCEPT ALL SELECT * FROM grh_after) x;
  SELECT count(*) INTO n_b FROM (SELECT * FROM grh_after EXCEPT ALL SELECT * FROM grh_before) x;
  IF n_a <> 0 OR n_b <> 0 THEN RAISE EXCEPTION 'visits/clients/manifests Activity changed: % rows before-only, % rows after-only', n_a, n_b; END IF;
  IF (SELECT count(*) FROM grh_before WHERE t = 'visits' AND NOT hide) <> (SELECT count(*) FROM grh_after WHERE t = 'visits' AND NOT hide)
     OR (SELECT entry_id FROM grh_before WHERE t = 'visits' AND NOT hide ORDER BY changed_at DESC, entry_id DESC LIMIT 1)
        <> (SELECT entry_id FROM grh_after WHERE t = 'visits' AND NOT hide ORDER BY changed_at DESC, entry_id DESC LIMIT 1) THEN
    RAISE EXCEPTION 'visit 6568: row count or first entry_id differs before/after';
  END IF;
  IF (SELECT string_agg(t || ':' || hide::text || ':' || n::text, ',' ORDER BY t, hide) FROM (SELECT t, hide, count(*) n FROM grh_before GROUP BY 1, 2) b)
     <> (SELECT string_agg(t || ':' || hide::text || ':' || n::text, ',' ORDER BY t, hide) FROM (SELECT t, hide, count(*) n FROM grh_after GROUP BY 1, 2) a) THEN
    RAISE EXCEPTION 'per-table Activity counts differ before/after';
  END IF;
  -- 7. the synthetic probe rows are gone (negative ids never exist for real)
  IF EXISTS (SELECT 1 FROM audit.logs
              WHERE changed_at >= (SELECT (c->>'changed_at')::timestamptz FROM grh_probe_cursor)
                AND (record_pk->>'id' = '-1' OR record_pk->>'task_id' = '-1' OR record_pk->>'visit_id' = '-1')) THEN
    RAISE EXCEPTION 'probe rows survived the rollback';
  END IF;
  -- 8. the probe actually ran: its report carries every step
  IF (SELECT count(*) FROM grh_probe_report) <> 25 THEN
    RAISE EXCEPTION 'the probe report has % lines, expected 25; the probe did not run to the end', (SELECT count(*) FROM grh_probe_report);
  END IF;
END $$;

-- No NOTIFY pgrst: both signatures are unchanged and PostgREST caches signatures, not bodies.

COMMIT;
