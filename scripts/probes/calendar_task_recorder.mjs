// Proves ops.fn_record_calendar_task / ops.fn_delete_calendar_task actually WORK -- by running them.
//
// These two are the ONLY writers of ops.calendar_tasks + ops.calendar_task_assignees: 2026-08-26_1810
// left no role holding a write grant on either table, not even service_role, so there is no
// PostgREST path around them. The save-calendar-task edge function calls them only AFTER Jobber has
// confirmed a change, which is what makes "our copy never claims something Jobber does not have"
// structural. Everything below is the standing guard on that door.
//
// WHY EXERCISE RATHER THAN READ: PL/pgSQL is NOT parsed at CREATE time. `CREATE OR REPLACE FUNCTION`
//    succeeding says nothing about whether the body runs -- a 42803 sails straight through and fires
//    on the first real call, which on 2026-08-06 meant a resolver RAISING for every ticket for three
//    and a half hours. So this probe CALLS both functions, on real rows, and reads the result back.
//
// EVERYTHING RUNS INSIDE begin; ... rollback;  Nothing is committed. Sentinels are scoped by a
//    probe-only jobber_gid, never by a frozen row count: public.entity_source_links takes live
//    Jobber sync writes (27,868 -> 27,871 within an hour on 2026-08-26), so any assertion pinned to
//    a total would go red for reasons that have nothing to do with this code. The SAME applies to
//    ops.calendar_tasks the day Task 4 writes the first real row, which is why section 6 asserts
//    sentinels and merely PRINTS the totals.
//
// POSITIVE CONTROLS -- a negative assertion needs a twin that MUST fire, or the instrument is
//    untested (feedback_confident_zero_is_a_broken_instrument):
//      * grants        -- ops.set_visit_status is authenticated-EXECUTABLE and must read TRUE, or
//                         has_function_privilege cannot see a grant that IS there and every "anon
//                         cannot" below is worthless.
//      * assignee diff -- "an unchanged set emits ZERO audit rows" only means something because the
//                         very next step changes the set and emits EXACTLY TWO.
//      * actor         -- "the email is in audit.logs" only means something because the same script
//                         shows a NULL-actor call in a FRESH transaction recording NO email.
//      * 3.c orphan    -- "a link row with no task RAISES" only means something because the same
//                         call against the healthy link succeeded moments earlier.
//      * delete        -- "0 rows afterwards" only means something because the rows are counted and
//                         asserted present immediately before.
//      * service_role  -- "service_role can drive the whole cycle" only means something because
//                         the same section shows `authenticated` refused 42501 by the same call.
//      * all-day       -- "leaving all-day resets the duration" is paired with two controls that
//                         must NOT reset: an explicit duration on the way out, and a plain
//                         timed-to-timed edit.
//
// SECTION 5 RUNS AS service_role, not as postgres. Everything else here goes through the
//    Management API as the table owner, which holds rolbypassrls and can do things the real caller
//    cannot -- so a behavioural claim measured only as postgres is a claim about the wrong role.
//
// A MANAGEMENT API QUERY RUNS AS postgres, the table OWNER, which bypasses grants AND holds
//    rolbypassrls. So "it inserted fine" measures NOTHING about permissions. Every grant assertion
//    here goes through has_function_privilege / has_table_privilege, which do not depend on who is
//    asking.
//
// Run:  node scripts/probes/calendar_task_recorder.mjs                 (expects: both functions live)
//       node scripts/probes/calendar_task_recorder.mjs --expect-absent (expects: neither exists)
// Exit: 0 = expectation met, 1 = expectation violated or the instrument is untrustworthy.
import { pathToFileURL } from 'node:url'
import { sql } from './calendar_task_esl.mjs'

const REC   = 'ops.fn_record_calendar_task(jsonb, text)'
const DEL   = 'ops.fn_delete_calendar_task(bigint, text)'
const ACT   = 'ops.fn_calendar_task_set_actor(text)'
const GID   = 'PROBE-RECORDER-2026-08-26'
const ACTOR = 'probe.recorder@unclogme.invalid'

// Every script below ends `select k, v from _r order by k; rollback;` and the Management API hands
// back that select's rows. Collapse them to a plain object.
const kv = (rows) => Object.fromEntries((rows || []).map(r => [r.k, r.v]))

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // The guard MUST use pathToFileURL. On Windows import.meta.url is `file:///C:/...` (three
  // slashes) while a hand-built `file://` + argv[1] yields two, so the hand-rolled form never
  // matches and the whole block is skipped -- exiting 0 with no output. A probe that prints
  // nothing is not a passing probe. `process.argv[1] &&` guards `node -e`, where it is undefined
  // and pathToFileURL throws, which would kill the IMPORT for anything reusing this module.
  const expectAbsent = process.argv.includes('--expect-absent')
  let fails = 0
  const check = (name, ok, detail) => {
    if (!ok) fails++
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`)
  }
  const done = (extra) => {
    console.log(`\n${fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`}`)
    console.log('--- audit complete --- ' + JSON.stringify(Object.assign(
      { probe: 'calendar_task_recorder',
        mode: expectAbsent ? 'expect-absent' : 'expect-present',
        failures: fails }, extra || {})))
    process.exit(fails === 0 ? 0 : 1)
  }
  const instrumentError = (where, e) => {
    console.log(`FAIL  ${where}: INSTRUMENT ERROR, not a verdict -- ${String(e.message).slice(0, 300)}`)
    fails++
    done({ aborted_at: where })
  }

  // ===========================================================================================
  // 0. EXISTENCE. Absence is a FAILURE unless the caller declared it. An earlier probe in this
  //    family iterated whatever the catalogue returned, so pointing it at objects that do not
  //    exist looped over an empty array and exited 0 -- greenlighting a dropped or never-migrated
  //    object. The expected state is declared on the command line, never inferred.
  // ===========================================================================================
  let present
  try {
    present = kv(await sql(`
      select p.proname as k, 'yes' as v
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'ops'
         and p.proname in ('fn_record_calendar_task','fn_delete_calendar_task','fn_calendar_task_set_actor')`))
  } catch (e) { instrumentError('existence', e) }

  const wanted = ['fn_record_calendar_task', 'fn_delete_calendar_task', 'fn_calendar_task_set_actor']
  if (expectAbsent) {
    for (const n of wanted) {
      check(`--expect-absent: ops.${n} is gone`, !present[n], present[n] ? 'it EXISTS' : 'absent')
    }
    done({ found: Object.keys(present).length })
  }
  for (const n of wanted) {
    check(`ops.${n} exists`, !!present[n],
      present[n] ? 'present' : 'MISSING -- the migration never ran here, or the object was dropped/renamed. Pass --expect-absent if that is what you meant.')
  }
  if (fails) {
    console.log('\nThe functions are not all here, so exercising them would prove nothing. Stopping.')
    done({ found: Object.keys(present).length })
  }

  // ===========================================================================================
  // 1. THE GRANT MODEL. service_role and nobody else. Read-only, no transaction needed.
  // ===========================================================================================
  let g
  try {
    g = kv(await sql(`
      select 'CONTROL_authn_can_exec_a_known_grant' as k,
             has_function_privilege('authenticated', p.oid, 'EXECUTE')::text as v
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'ops' and p.proname = 'set_visit_status'
      union all select 'rec_service_role',  has_function_privilege('service_role',  '${REC}', 'EXECUTE')::text
      union all select 'rec_authenticated', has_function_privilege('authenticated', '${REC}', 'EXECUTE')::text
      union all select 'rec_anon',          has_function_privilege('anon',          '${REC}', 'EXECUTE')::text
      union all select 'del_service_role',  has_function_privilege('service_role',  '${DEL}', 'EXECUTE')::text
      union all select 'del_authenticated', has_function_privilege('authenticated', '${DEL}', 'EXECUTE')::text
      union all select 'del_anon',          has_function_privilege('anon',          '${DEL}', 'EXECUTE')::text
      union all select 'actor_service_role', has_function_privilege('service_role', '${ACT}', 'EXECUTE')::text
      union all select 'actor_authenticated',has_function_privilege('authenticated','${ACT}', 'EXECUTE')::text
      union all select 'rec_secdef_postgres',
             (p.prosecdef and pg_get_userbyid(p.proowner) = 'postgres'
              and p.proconfig @> array['search_path=ops, public, pg_temp'])::text
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'ops' and p.proname = 'fn_record_calendar_task'
      union all select 'tbl_svc_insert_tasks',     has_table_privilege('service_role',  'ops.calendar_tasks','INSERT')::text
      union all select 'tbl_authn_insert_tasks',   has_table_privilege('authenticated', 'ops.calendar_tasks','INSERT')::text
      union all select 'tbl_svc_insert_assignees', has_table_privilege('service_role',  'ops.calendar_task_assignees','INSERT')::text
      union all select 'tbl_authn_insert_assignees',has_table_privilege('authenticated','ops.calendar_task_assignees','INSERT')::text
      union all select 'tbl_authn_select_tasks',   has_table_privilege('authenticated', 'ops.calendar_tasks','SELECT')::text`))
  } catch (e) { instrumentError('grants', e) }

  // The control is the licence to read every negative below. Without it, stop.
  const controlOk = g.CONTROL_authn_can_exec_a_known_grant === 'true'
  check('CONTROL: has_function_privilege sees a grant that IS there (ops.set_visit_status/authenticated)',
    controlOk, `= ${g.CONTROL_authn_can_exec_a_known_grant}`)
  if (!controlOk) {
    console.log('\nCONTROL FAILED -- the instrument cannot see a grant it should. Every "cannot')
    console.log('   EXECUTE" below would be meaningless, so none is reported. Fix that first.')
    done({ control_ok: false })
  }

  check('service_role can EXECUTE the recorder and the deleter',
    g.rec_service_role === 'true' && g.del_service_role === 'true',
    `rec=${g.rec_service_role} del=${g.del_service_role}`)
  check('anon + authenticated can EXECUTE NEITHER',
    g.rec_anon === 'false' && g.rec_authenticated === 'false' &&
    g.del_anon === 'false' && g.del_authenticated === 'false',
    `rec anon/authn=${g.rec_anon}/${g.rec_authenticated} del anon/authn=${g.del_anon}/${g.del_authenticated}`)
  check('the actor helper is callable by NOBODY but its owner',
    g.actor_service_role === 'false' && g.actor_authenticated === 'false',
    `svc=${g.actor_service_role} authn=${g.actor_authenticated}`)
  check('recorder is SECDEF, postgres-owned, search_path-pinned', g.rec_secdef_postgres === 'true')
  // The tables are the point of the whole design: adding a SECDEF writer must not hand anyone a
  // direct write. calendar_task_grants.mjs owns this assertion; it is repeated here because this
  // is the migration that could have widened it.
  check('the TABLE grants did NOT widen: still no write for anyone, SELECT intact',
    g.tbl_svc_insert_tasks === 'false' && g.tbl_authn_insert_tasks === 'false' &&
    g.tbl_svc_insert_assignees === 'false' && g.tbl_authn_insert_assignees === 'false' &&
    g.tbl_authn_select_tasks === 'true',
    `tasks svc/authn insert=${g.tbl_svc_insert_tasks}/${g.tbl_authn_insert_tasks}, authn select=${g.tbl_authn_select_tasks}`)

  // ===========================================================================================
  // 2. THE LIFECYCLE. One transaction, rolled back: insert -> idempotent retry -> update ->
  //    assignee diff -> actor -> all-day -> delete.
  // ===========================================================================================
  let L
  try {
    L = kv(await sql(`
begin;
create temp table _r(k text, v text);
do $probe$
declare
  v_e1 bigint; v_e2 bigint; v_e3 bigint;
  v_id1 bigint; v_id2 bigint;
  v_mark bigint; v_n integer; v_txt text; v_dur smallint; v_bit boolean;
begin
  select e.id into v_e1 from public.employees e where e.status = 'ACTIVE' order by e.id offset 0 limit 1;
  select e.id into v_e2 from public.employees e where e.status = 'ACTIVE' order by e.id offset 1 limit 1;
  select e.id into v_e3 from public.employees e where e.status = 'ACTIVE' order by e.id offset 2 limit 1;
  if v_e3 is null then
    raise exception 'CONTROL FAILED: need 3 ACTIVE employees to exercise the assignee diff';
  end if;
  insert into _r values ('employees', v_e1 || ',' || v_e2 || ',' || v_e3);

  -- ---- 2a. first call INSERTs ------------------------------------------------------------
  v_id1 := ops.fn_record_calendar_task(jsonb_build_object(
             'jobber_gid', '${GID}', 'title', 'probe task', 'task_date', current_date,
             'minutes', 540, 'duration_minutes', 45,
             'assignee_ids', jsonb_build_array(v_e1, v_e2)), '${ACTOR}');
  insert into _r values ('a_id', coalesce(v_id1::text, '<null>'));
  insert into _r values ('a_tasks',  (select count(*) from ops.calendar_tasks where id = v_id1)::text);
  insert into _r values ('a_links',  (select count(*) from public.entity_source_links
                                       where entity_type = 'calendar_task' and source_id = '${GID}')::text);
  insert into _r values ('a_assignees', (select string_agg(employee_id::text, ',' order by employee_id)
                                           from ops.calendar_task_assignees where task_id = v_id1));
  insert into _r values ('a_shape', (select all_day::text || '/' || duration_minutes::text || '/' ||
                                            coalesce(minutes::text,'null')
                                       from ops.calendar_tasks where id = v_id1));

  -- ---- 2b. IDEMPOTENCY: same GID, second call, and it must UPDATE not insert ---------------
  v_id2 := ops.fn_record_calendar_task(jsonb_build_object(
             'jobber_gid', '${GID}', 'title', 'probe task EDITED'), '${ACTOR}');
  insert into _r values ('b_id', coalesce(v_id2::text, '<null>'));
  insert into _r values ('b_same_id', (v_id2 is not distinct from v_id1)::text);
  insert into _r values ('b_task_count', (select count(*) from ops.calendar_tasks)::text);
  insert into _r values ('b_link_count', (select count(*) from public.entity_source_links
                                           where entity_type = 'calendar_task')::text);
  insert into _r values ('b_title', (select title from ops.calendar_tasks where id = v_id1));
  -- patch semantics: keys not sent must not be wiped
  insert into _r values ('b_untouched', (select coalesce(minutes::text,'null') || '/' || duration_minutes::text
                                           from ops.calendar_tasks where id = v_id1));
  insert into _r values ('b_assignees', (select string_agg(employee_id::text, ',' order by employee_id)
                                           from ops.calendar_task_assignees where task_id = v_id1));

  -- ---- 2c. ASSIGNEE DIFF, unchanged set: expect ZERO audit rows ---------------------------
  select max(id) into v_mark from audit.logs;
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'assignee_ids', jsonb_build_array(v_e2, v_e1)), '${ACTOR}');
  select count(*) into v_n from audit.logs l
   where l.id > v_mark and l.table_name = 'calendar_task_assignees'
     and l.record_pk->>'task_id' = v_id1::text;
  insert into _r values ('c_unchanged_audit_rows', v_n::text);
  insert into _r values ('c_assignees', (select string_agg(employee_id::text, ',' order by employee_id)
                                           from ops.calendar_task_assignees where task_id = v_id1));

  -- ---- 2d. ASSIGNEE DIFF, real change: this is 2c's positive control -----------------------
  select max(id) into v_mark from audit.logs;
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'assignee_ids', jsonb_build_array(v_e2, v_e3)), '${ACTOR}');
  select coalesce(string_agg(l.operation || ':' || (l.record_pk->>'employee_id'), ',' order by l.id), '<none>')
    into v_txt
    from audit.logs l
   where l.id > v_mark and l.table_name = 'calendar_task_assignees'
     and l.record_pk->>'task_id' = v_id1::text;
  insert into _r values ('d_changed_audit_rows', v_txt);
  insert into _r values ('d_expected', 'DELETE:' || v_e1 || ',INSERT:' || v_e3);
  insert into _r values ('d_assignees', (select string_agg(employee_id::text, ',' order by employee_id)
                                           from ops.calendar_task_assignees where task_id = v_id1));

  -- ---- 2e. 3.a the ACTOR reached audit.logs ------------------------------------------------
  select l.jwt_claims->>'email' into v_txt
    from audit.logs l
   where l.table_schema = 'ops' and l.table_name = 'calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id1)
   order by l.id desc limit 1;
  insert into _r values ('e_actor_email', coalesce(v_txt, '<null>'));
  select count(*) into v_n from audit.logs l
   where l.table_schema = 'ops' and l.table_name = 'calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id1);
  insert into _r values ('e_audit_rows_for_task', v_n::text);   -- control: the trigger fires at all
  select l.changed_by into v_txt from audit.logs l
   where l.table_schema = 'ops' and l.table_name = 'calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id1)
   order by l.id desc limit 1;
  insert into _r values ('e_changed_by', coalesce(v_txt::text, '<null>'));  -- documented to be NULL

  -- ---- 2f. 3.d all-day forces 1440, and the CHECK bites on the bypass path -----------------
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'minutes', null), '${ACTOR}');
  select all_day, duration_minutes into v_bit, v_dur from ops.calendar_tasks where id = v_id1;
  insert into _r values ('f_allday_shape', v_bit::text || '/' || v_dur::text);
  begin
    update ops.calendar_tasks set duration_minutes = 30 where id = v_id1;
    insert into _r values ('f_check_bites', 'NO -- a direct write set an all-day task to 30 minutes');
  exception when check_violation then
    insert into _r values ('f_check_bites', 'yes');
  end;
  -- 3.d IN THE OTHER DIRECTION. This is the transition that shipped wrong: the first version
  -- forced 1440 on the way in and never took it back, so an all-day task rescheduled with a
  -- minutes-only payload -- the natural drag handler shape -- came out false/1440/540, a 9 AM task
  -- claiming twenty-four hours, legal under every CHECK.
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'minutes', 540), '${ACTOR}');
  select all_day, duration_minutes into v_bit, v_dur from ops.calendar_tasks where id = v_id1;
  insert into _r values ('f_leaving_shape', v_bit::text || '/' || v_dur::text);
  -- an explicit duration on the way out still wins over the reset
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'minutes', null), '${ACTOR}');
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'minutes', 600, 'duration_minutes', 90), '${ACTOR}');
  select all_day, duration_minutes into v_bit, v_dur from ops.calendar_tasks where id = v_id1;
  insert into _r values ('f_leaving_explicit', v_bit::text || '/' || v_dur::text);
  -- a timed task that is merely EDITED keeps its own duration (the reset must not fire here)
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}', 'minutes', 630), '${ACTOR}');
  select duration_minutes into v_dur from ops.calendar_tasks where id = v_id1;
  insert into _r values ('f_timed_to_timed', v_dur::text);
  -- finding 6: an explicit null on a NOT NULL column must be a readable 22023, not a raw 23502
  begin
    perform ops.fn_record_calendar_task(jsonb_build_object(
              'jobber_gid', '${GID}', 'is_complete', null), '${ACTOR}');
    insert into _r values ('f_null_notnull', 'ACCEPTED');
  exception when others then
    insert into _r values ('f_null_notnull', 'refused ' || sqlstate);
  end;
  -- finding 5: the idempotency key gets the same whitespace class as the actor label
  begin
    perform ops.fn_record_calendar_task(jsonb_build_object(
              'jobber_gid', chr(9), 'title', 'tab gid', 'task_date', current_date), '${ACTOR}');
    insert into _r values ('f_tab_gid', 'ACCEPTED -- a task keyed on a TAB');
  exception when others then
    insert into _r values ('f_tab_gid', 'refused ' || sqlstate);
  end;

  -- and a contradicting all_day is refused rather than silently overridden
  begin
    perform ops.fn_record_calendar_task(jsonb_build_object(
              'jobber_gid', '${GID}', 'minutes', 600, 'all_day', true), '${ACTOR}');
    insert into _r values ('f_contradiction', 'ACCEPTED -- all_day=true with a start time');
  exception when others then
    insert into _r values ('f_contradiction', 'refused ' || sqlstate);
  end;

  -- ---- 2g. DELETE removes the task, the link and the assignees ----------------------------
  insert into _r values ('g_before', (select count(*) from ops.calendar_tasks where id = v_id1)::text
                                  || '/' || (select count(*) from public.entity_source_links
                                              where entity_type = 'calendar_task' and entity_id = v_id1)::text
                                  || '/' || (select count(*) from ops.calendar_task_assignees
                                              where task_id = v_id1)::text);
  insert into _r values ('g_returned', ops.fn_delete_calendar_task(v_id1, '${ACTOR}')::text);
  insert into _r values ('g_after',  (select count(*) from ops.calendar_tasks where id = v_id1)::text
                                  || '/' || (select count(*) from public.entity_source_links
                                              where entity_type = 'calendar_task' and entity_id = v_id1)::text
                                  || '/' || (select count(*) from ops.calendar_task_assignees
                                              where task_id = v_id1)::text);
  insert into _r values ('g_retry', ops.fn_delete_calendar_task(v_id1, '${ACTOR}')::text);
end
$probe$;
select k, v from _r order by k;
rollback;`))
  } catch (e) { instrumentError('lifecycle', e) }

  check('2a  first call INSERTs and returns an id', /^[0-9]+$/.test(L.a_id || ''), `id=${L.a_id}`)
  check('2a  it wrote exactly one task, one link row and both assignees',
    L.a_tasks === '1' && L.a_links === '1' && L.a_assignees === (L.employees || '').split(',').slice(0, 2).join(','),
    `tasks=${L.a_tasks} links=${L.a_links} assignees=${L.a_assignees}`)
  check('2a  a timed task keeps its own duration (all_day/duration/minutes)',
    L.a_shape === 'false/45/540', `= ${L.a_shape}`)

  check('2b  IDEMPOTENCY: the same jobber_gid returns the SAME id', L.b_same_id === 'true',
    `first=${L.a_id} second=${L.b_id}`)
  check('2b  and creates no second task and no second link row',
    L.b_task_count === '1' && L.b_link_count === '1',
    `tasks=${L.b_task_count} links=${L.b_link_count}`)
  check('2b  the UPDATE branch really changed a field', L.b_title === 'probe task EDITED',
    `title=${L.b_title}`)
  check('2b  patch semantics: keys the caller omitted were left alone',
    L.b_untouched === '540/45' && L.b_assignees === L.a_assignees,
    `minutes/duration=${L.b_untouched} assignees=${L.b_assignees}`)

  check('2c  3.b an UNCHANGED assignee set emits ZERO audit rows',
    L.c_unchanged_audit_rows === '0', `${L.c_unchanged_audit_rows} row(s)`)
  check('2c  and the membership is untouched', L.c_assignees === L.a_assignees, `= ${L.c_assignees}`)
  check('2d  CONTROL for 2c: a REAL change emits exactly one DELETE and one INSERT',
    L.d_changed_audit_rows === L.d_expected, `got ${L.d_changed_audit_rows} want ${L.d_expected}`)
  check('2d  and the membership is the new set',
    L.d_assignees === (L.employees || '').split(',').slice(1, 3).join(','), `= ${L.d_assignees}`)

  check('2e  3.a the actor email is on the audit row this function wrote',
    L.e_actor_email === ACTOR, `jwt_claims->>email = ${L.e_actor_email}`)
  check('2e  CONTROL: the audit trigger fired at all for this task',
    Number(L.e_audit_rows_for_task) > 0, `${L.e_audit_rows_for_task} row(s)`)
  check('2e  changed_by is still NULL, as documented (it reads the singular request.jwt.claim.sub)',
    L.e_changed_by === '<null>', `= ${L.e_changed_by}`)

  check('2f  3.d making a task all-day forces duration_minutes to 1440',
    L.f_allday_shape === 'true/1440', `all_day/duration = ${L.f_allday_shape}`)
  check('2f  CONTROL: calendar_tasks_allday_duration_chk bites a direct write',
    L.f_check_bites === 'yes', L.f_check_bites)
  check('2f  3.d LEAVING all-day with only a time drops the derived 1440 back to the default',
    L.f_leaving_shape === 'false/30', `all_day/duration = ${L.f_leaving_shape} (want false/30)`)
  check('2f  CONTROL for the line above: an explicit duration on the way out still wins',
    L.f_leaving_explicit === 'false/90', `= ${L.f_leaving_explicit}`)
  check('2f  CONTROL: a timed->timed edit keeps its own duration (the reset does not overfire)',
    L.f_timed_to_timed === '90', `= ${L.f_timed_to_timed}`)
  check('2f  an explicit null on a NOT NULL column is a readable 22023, not a raw 23502',
    L.f_null_notnull === 'refused 22023', `= ${L.f_null_notnull}`)
  check('2f  a TAB-only jobber_gid is refused: the idempotency key uses the same whitespace class '
      + 'as the actor label',
    L.f_tab_gid === 'refused 22023', `= ${L.f_tab_gid}`)
  check('2f  an all_day that contradicts minutes is refused with 22023 specifically',
    L.f_contradiction === 'refused 22023', L.f_contradiction)

  check('2g  CONTROL: task, link and assignees all present before the delete',
    L.g_before === '1/1/2', `task/link/assignees = ${L.g_before}`)
  check('2g  fn_delete_calendar_task removes the task, its link row and its assignees',
    L.g_returned === 'true' && L.g_after === '0/0/0',
    `returned=${L.g_returned} after=${L.g_after}`)
  check('2g  a retried delete is a no-op returning false, not an error', L.g_retry === 'false',
    `= ${L.g_retry}`)

  // ===========================================================================================
  // 3. 3.c -- A LINK ROW THAT OUTLIVED ITS TASK MUST RAISE, NOT RETURN A DEAD ID.
  //    entity_source_links is polymorphic, has no FK and cascades nothing, so this state is
  //    reachable. The control is that the identical call succeeds while the task is still there.
  // ===========================================================================================
  let O
  try {
    O = kv(await sql(`
begin;
create temp table _r(k text, v text);
do $probe$
declare v_id bigint; v_again bigint;
begin
  v_id := ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-orphan', 'title', 'orphan probe', 'task_date', current_date),
          '${ACTOR}');
  -- CONTROL: the very same call, while the link is HEALTHY, must succeed.
  v_again := ops.fn_record_calendar_task(jsonb_build_object(
               'jobber_gid', '${GID}-orphan', 'title', 'orphan probe 2'), '${ACTOR}');
  insert into _r values ('control_healthy_update', (v_again is not distinct from v_id)::text);

  -- Now orphan it: remove ONLY the task, as postgres, leaving the link row behind.
  delete from ops.calendar_tasks where id = v_id;
  insert into _r values ('orphan_made',
    ((select count(*) from public.entity_source_links
       where entity_type = 'calendar_task' and source_id = '${GID}-orphan') = 1
     and not exists (select 1 from ops.calendar_tasks where id = v_id))::text);

  begin
    v_again := ops.fn_record_calendar_task(jsonb_build_object(
                 'jobber_gid', '${GID}-orphan', 'title', 'should not get here'), '${ACTOR}');
    insert into _r values ('orphan_result', 'RETURNED ' || coalesce(v_again::text,'null')
                                          || ' -- a dead id reported as success');
  exception when others then
    insert into _r values ('orphan_result', 'raised ' || sqlstate);
    insert into _r values ('orphan_message', left(sqlerrm, 160));
  end;
end
$probe$;
select k, v from _r order by k;
rollback;`))
  } catch (e) { instrumentError('orphan', e) }

  check('3c  CONTROL: the same call succeeds while the link is healthy',
    O.control_healthy_update === 'true', `same id = ${O.control_healthy_update}`)
  check('3c  CONTROL: the orphan state was actually created', O.orphan_made === 'true')
  check('3c  a link row whose task is gone RAISES 23503 instead of returning a dead id',
    O.orphan_result === 'raised 23503', `${O.orphan_result} :: ${O.orphan_message || ''}`)

  // ===========================================================================================
  // 4. 3.a's NEGATIVE CONTROL, plus the measured SCOPE of the label.
  //    Without step 4a, "the email is in audit.logs" could be true of every row regardless of what
  //    this function does. 4c pins the transaction-scoping recorded in the migration header: the
  //    setting is transaction-local, NOT function-local, so a later NULL-actor call in the SAME
  //    transaction inherits the name. PostgREST cannot reach that (one RPC per request), but if
  //    the behaviour ever changes, the header stops being true and this is what says so.
  // ===========================================================================================
  let A
  try {
    A = kv(await sql(`
begin;
create temp table _r(k text, v text);
do $probe$
declare v_id bigint; v_txt text;
begin
  -- 4a. NULL actor first, in a transaction where nothing has set anything.
  v_id := ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-actor', 'title', 'no actor', 'task_date', current_date), null);
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('a_null_actor', coalesce(v_txt, '<null>'));

  -- 4b. named actor
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-actor', 'title', 'named actor'), '${ACTOR}');
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('b_named_actor', coalesce(v_txt, '<null>'));

  -- 4e. a SECOND non-null actor REPLACES the first. The COMMENT on the helper used to say both
  -- calls take the FIRST actor, which is only true when the second is NULL.
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-actor', 'title', 'second actor'), 'second.${ACTOR}');
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('e_second_named_actor', coalesce(v_txt, '<null>'));

  -- 4c. NULL actor again, SAME transaction: documented to inherit, because set_config(..., true)
  -- is transaction-local and survives the function's return.
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-actor', 'title', 'null actor again'), null);
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('c_null_after_named', coalesce(v_txt, '<null>'));

end
$probe$;
select k, v from _r order by k;
rollback;`))
  } catch (e) { instrumentError('actor', e) }

  // 4d has to be its OWN transaction. Inside the block above the label is already set, and by 4c
  // that survives -- so a whitespace actor there would "inherit" ACTOR and the check would pass for
  // the wrong reason. That is the same inheritance 4c documents, used here as a trap to avoid.
  let W
  try {
    W = kv(await sql(`
begin;
create temp table _r(k text, v text);
do $probe$
declare v_id bigint; v_txt text;
begin
  v_id := ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', '${GID}-ws', 'title', 'ws', 'task_date', current_date),
          chr(9) || chr(160) || ' ');
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('d_whitespace_actor', coalesce(v_txt, '<null>'));
end
$probe$;
select k, v from _r order by k;
rollback;`))
  } catch (e) { instrumentError('whitespace-actor', e) }

  check('4a  CONTROL: with a NULL actor the audit row carries NO email',
    A.a_null_actor === '<null>', `= ${A.a_null_actor}`)
  check('4b  with an actor, that exact email is on the audit row', A.b_named_actor === ACTOR,
    `= ${A.b_named_actor}`)
  check('4e  a second NON-NULL actor REPLACES the first (the helper COMMENT says last-wins)',
    A.e_second_named_actor === 'second.' + ACTOR, `= ${A.e_second_named_actor}`)
  check('4c  the label is TRANSACTION-local, so a later NULL-actor call in the same transaction '
      + 'inherits the last named one (measured, matches the migration header)',
    A.c_null_after_named === 'second.' + ACTOR, `= ${A.c_null_after_named}`)
  check('4d  a whitespace-only actor (TAB + NBSP + space) is treated as no actor, in a FRESH '
      + 'transaction so 4c cannot make it pass for the wrong reason',
    W.d_whitespace_actor === '<null>', `= ${W.d_whitespace_actor}`)

  // ===========================================================================================
  // 5. RUN IT AS service_role -- THE ROLE THAT WILL ACTUALLY CALL IT.
  //    Everything above goes through the Management API, i.e. as postgres: table OWNER, holder of
  //    rolbypassrls. has_function_privilege is role-independent so the grant assertions stand, but
  //    every BEHAVIOURAL claim above was measured as the owner, and the owner can do things
  //    service_role cannot. The shape that would fail silently: a SECDEF function calling a
  //    SECURITY INVOKER helper granted to NOBODY. That works because the nested EXECUTE check
  //    resolves against the definer -- but nothing in this repo proved it, so a regression there
  //    would 42501 in production with every suite green.
  //    NEGATIVE CONTROL FIRST: as `authenticated` the same call must be refused 42501. Without it,
  //    a SET LOCAL ROLE that silently did nothing would leave this whole section running as
  //    postgres and passing for the wrong reason.
  // ===========================================================================================
  let R
  try {
    R = kv(await sql(`
begin;
create temp table _r(k text, v text);
do $probe$
declare v_id bigint; v_e1 bigint; v_who text; v_neg text; v_txt text; v_shape text; v_del boolean;
  v_asg text;
begin
  select e.id into v_e1 from public.employees e where e.status='ACTIVE' order by e.id limit 1;

  begin
    set local role authenticated;
    perform ops.fn_record_calendar_task(jsonb_build_object('jobber_gid','${GID}-role-neg',
              'title','must not get in','task_date',current_date), '${ACTOR}');
    v_neg := 'ACCEPTED';
  exception
    when insufficient_privilege then v_neg := 'refused 42501';
    when others                 then v_neg := 'other ' || sqlstate;
  end;
  reset role;
  insert into _r values ('neg_authenticated', v_neg);

  set local role service_role;
  select current_user into v_who;
  v_id := ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid','${GID}-role','title','as service_role','task_date',current_date,
            'minutes',480,'duration_minutes',60,'assignee_ids',jsonb_build_array(v_e1)), '${ACTOR}');
  perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid','${GID}-role','title','as service_role, edited'), '${ACTOR}');
  -- service_role holds SELECT, so it can read its own work back
  select t.all_day::text || '/' || t.duration_minutes::text || '/' || t.title
    into v_shape from ops.calendar_tasks t where t.id = v_id;
  select count(*)::text into v_asg from ops.calendar_task_assignees where task_id = v_id;
  v_del := ops.fn_delete_calendar_task(v_id, '${ACTOR}');
  reset role;
  -- Nothing above writes to _r, because service_role CANNOT: the temp table is owned by postgres
  -- and the first draft of this section died on "permission denied for table _r". Keep the
  -- recording on this side of the reset. That error is also incidental proof the switch is real --
  -- a SET LOCAL ROLE that did nothing would have written the row happily.

  insert into _r values ('current_user', v_who);
  insert into _r values ('assignees', coalesce(v_asg, '<null>'));
  insert into _r values ('id', coalesce(v_id::text, '<null>'));
  insert into _r values ('shape', coalesce(v_shape, '<null>'));
  insert into _r values ('deleted', v_del::text);
  insert into _r values ('gone',
    ((select count(*) from ops.calendar_tasks where id = v_id) = 0
     and (select count(*) from public.entity_source_links
           where entity_type='calendar_task' and source_id='${GID}-role') = 0)::text);
  -- audit is read back as postgres: service_role has no grant in the audit schema
  select l.jwt_claims->>'email' into v_txt from audit.logs l
   where l.table_schema='ops' and l.table_name='calendar_tasks'
     and l.record_pk = jsonb_build_object('id', v_id) order by l.id desc limit 1;
  insert into _r values ('actor_email', coalesce(v_txt, '<null>'));
  insert into _r values ('db_role_informational', (select l.db_role from audit.logs l
     where l.table_schema='ops' and l.table_name='calendar_tasks'
       and l.record_pk = jsonb_build_object('id', v_id) order by l.id limit 1));
end
$probe$;
select k, v from _r order by k;
rollback;`))
  } catch (e) { instrumentError('service_role', e) }

  check('5   NEGATIVE CONTROL: as `authenticated` the recorder is refused 42501',
    R.neg_authenticated === 'refused 42501', `= ${R.neg_authenticated}`)
  check('5   the role switch really took effect (current_user inside the section)',
    R.current_user === 'service_role', `current_user = ${R.current_user}`)
  check('5   as service_role: record, edit and read back all work through the SECDEF door',
    /^[0-9]+$/.test(R.id || '') && R.shape === 'false/60/as service_role, edited' && R.assignees === '1',
    `id=${R.id} shape=${R.shape} assignees=${R.assignees}`)
  check('5   as service_role: the nested call to the granted-to-nobody actor helper still labels '
      + 'the audit row (this is the silent-42501 shape)',
    R.actor_email === ACTOR, `= ${R.actor_email}`)
  check('5   as service_role: the delete removes the task and its link row',
    R.deleted === 'true' && R.gone === 'true', `deleted=${R.deleted} gone=${R.gone}`)
  console.log(`      (informational: audit.logs.db_role = ${R.db_role_informational} -- audit.log_change is `
    + 'itself SECDEF, so this reports ITS owner and cannot discriminate the caller)')

  // ===========================================================================================
  // 6. NOTHING LEAKED.
  //    SENTINEL-SCOPED, NOT WHOLE-TABLE. Today both tables are empty, so a total of 0 happens to
  //    be true -- and would become a permanent false alarm the day Task 4 writes the first real
  //    task. What this probe can actually claim is that IT committed nothing, and the only honest
  //    measure of that is its own sentinels. The totals are printed, never asserted, for the same
  //    reason entity_source_links has always been printed here: it takes live Jobber sync writes.
  // ===========================================================================================
  let C
  try {
    C = kv(await sql(`
      select 'sentinel_links' as k, count(*)::text as v from public.entity_source_links
             where source_id like '${GID}%'
      union all select 'sentinel_tasks', count(*)::text from ops.calendar_tasks
             where title in ('probe task','probe task EDITED','orphan probe','orphan probe 2',
                             'no actor','named actor','second actor','null actor again','ws',
                             'as service_role','as service_role, edited','tab gid')
      union all select 'total_tasks', count(*)::text from ops.calendar_tasks
      union all select 'total_assignees', count(*)::text from ops.calendar_task_assignees
      union all select 'total_calendar_task_links', count(*)::text from public.entity_source_links
             where entity_type = 'calendar_task'`))
  } catch (e) { instrumentError('cleanliness', e) }

  check('6   this probe committed NOTHING: 0 sentinel link rows, 0 sentinel tasks',
    C.sentinel_links === '0' && C.sentinel_tasks === '0',
    `sentinel links=${C.sentinel_links} sentinel tasks=${C.sentinel_tasks}`)
  console.log(`      (informational, NEVER asserted: total tasks=${C.total_tasks} assignees=`
    + `${C.total_assignees} calendar_task links=${C.total_calendar_task_links})`)

  done({ control_ok: true, sentinel_links: C.sentinel_links, total_tasks: C.total_tasks })
}
