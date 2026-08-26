// Proves the calendar-task poll's standing invariants: the conflict guard raises ZZ002 on a stale
// expectation and writes nothing, the cron wrapper is postgres-only and scheduled off the */5 tick,
// and the poll's own observability row exists.
//
// WHY EACH ONE IS HERE:
//
// * THE GUARD (ZZ002). save-calendar-task is not one transaction: it reads the task row, then makes
//   three HTTP round trips, then calls the recorder. poll-calendar-tasks reads Jobber in a batch and
//   then writes. Nothing else stops the poll adopting a completion on a stale snapshot and clobbering
//   a reopen the office just made -- the exact discrepancy the whole feature exists to prevent,
//   manufactured by its own safety net. `expected_is_complete` is what closes that, and it is
//   OPTIONAL, which means a regression here is SILENT: drop the key and every call still succeeds.
//   ⚠ It compares OUR stored value, so it catches a concurrent write that CHANGED our row. It cannot
//     see a change on the JOBBER side; the poll narrows that separately by re-reading the single
//     task before adopting. Two narrow windows, not zero.
//
// * THE ERRCODE. ZZ002 must stay DISTINCT from 22023 (bad input) and 23514 (a CHECK). If it ever
//   collides, the poll retries a genuinely broken payload for ever and the saga reports a benign
//   race to the user as their mistake.
//
// * THE SCHEDULE. Four cron jobs already sit on `*/5`, and one of them (jobber-poll-sync) calls the
//   SAME Jobber API. `2-57/5` keeps the cadence and lands off that tick. A schedule silently reset to
//   `*/5` doubles concurrent Jobber consumers at every five-minute boundary.
//
// * THE GRANTS. ALTER DEFAULT PRIVILEGES on schema public grants EXECUTE on new functions to anon,
//   authenticated AND service_role before any GRANT statement runs, so `REVOKE ... FROM PUBLIC` is
//   not enough. That is why fn_request_health_escalation carries an `authenticated` grant its own
//   migration never wrote.
//
// 🛑 EVERY WRITE RUNS INSIDE begin/rollback. This probe never leaves a row behind, and it asserts
//    that at the end rather than assuming it.
//
// 🛑 POSITIVE CONTROLS, because a check that cannot fail is worse than none:
//    (a) a MATCHING expectation must still write -- otherwise "it refused" proves nothing;
//    (b) an ABSENT key must still write -- otherwise the guard has broken every existing caller;
//    (c) has_function_privilege must be able to SEE a grant that exists.
//
// Run:  node scripts/probes/calendar_task_poll.mjs
// Exit: 0 = all invariants hold, 1 = a violation, or the instrument is untrustworthy.
import { sql } from './calendar_task_esl.mjs'
import { pathToFileURL } from 'node:url'

export const CONFLICT_SQLSTATE = 'ZZ002'
export const CRON_JOB = 'calendar-task-poll'
export const CRON_SCHEDULE = '2-57/5 * * * *'
export const WRAPPER = 'public.fn_request_calendar_task_poll()'
export const SYNC_SOURCE = 'calendar-task-poll'

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // pathToFileURL, not a hand-built 'file://' + path: on Windows import.meta.url has three slashes
  // and the hand-built form has two, so this block would silently never run and the probe would
  // exit 0 having printed nothing.
  let fails = 0
  const check = (name, ok, detail) => {
    if (!ok) fails++
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`)
  }

  // ---- THE GUARD, exercised end to end inside one rolled-back transaction ------------------
  // Everything is collected into a temp table and selected at the end, so one round trip carries
  // the whole exercise and the ROLLBACK can never be skipped by an early return.
  let rows
  try {
    rows = await sql(`
      begin;
      create temp table probe_out(n int, name text, got text, want text, pass boolean) on commit drop;
      do $p$
      declare
        v_id bigint; v_code text; v_row ops.calendar_tasks%ROWTYPE;
        v_gid text := 'Z2lkOi8vSm9iYmVyL1Rhc2svUFJPQkVfUE9MTA==';
      begin
        v_id := ops.fn_record_calendar_task(jsonb_build_object(
          'jobber_gid', v_gid, 'title', 'poll probe', 'task_date', '2027-03-01',
          'minutes', 540), null);

        -- (a) CONTROL: a MATCHING expectation must WRITE. This is what makes every refusal below
        -- meaningful; without it "the guard refused" is indistinguishable from "nothing works".
        perform ops.fn_record_calendar_task(jsonb_build_object(
          'jobber_gid', v_gid, 'expected_is_complete', false, 'is_complete', true,
          'completed_at', '2027-03-01T12:00:00Z', 'completed_source', 'jobber'), null);
        select * into v_row from ops.calendar_tasks where id = v_id;
        insert into probe_out values (1, 'control: a matching expectation ADOPTS',
          format('c=%s src=%s', v_row.is_complete, v_row.completed_source), 'c=t src=jobber',
          v_row.is_complete and v_row.completed_source = 'jobber');

        -- TARGET: a STALE expectation must raise ZZ002 and write NOTHING. The row is now complete;
        -- a caller still believing it is open is the poll on a stale snapshot.
        begin
          perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', v_gid, 'expected_is_complete', false, 'title', 'CLOBBERED'), null);
          v_code := 'NO ERROR';
        exception when others then get stacked diagnostics v_code = returned_sqlstate; end;
        select * into v_row from ops.calendar_tasks where id = v_id;
        insert into probe_out values (2, 'stale expectation -> ZZ002',
          v_code, 'ZZ002', v_code = 'ZZ002');
        insert into probe_out values (3, 'and the write did NOT land',
          v_row.title, 'poll probe', v_row.title = 'poll probe');

        -- the code must not collide with the meanings it has to be distinguishable from
        insert into probe_out values (4, 'ZZ002 is distinct from 22023/23514/P0001',
          v_code, 'not-in-set', v_code not in ('22023','23514','P0001'));

        -- (b) CONTROL: an ABSENT key must still write, or the guard broke every existing caller.
        perform ops.fn_record_calendar_task(jsonb_build_object(
          'jobber_gid', v_gid, 'title', 'patched'), null);
        select * into v_row from ops.calendar_tasks where id = v_id;
        insert into probe_out values (5, 'control: an ABSENT key skips the check',
          v_row.title, 'patched', v_row.title = 'patched');

        -- un-completion, which the poll mirrors in the other direction
        perform ops.fn_record_calendar_task(jsonb_build_object(
          'jobber_gid', v_gid, 'expected_is_complete', true, 'is_complete', false), null);
        select * into v_row from ops.calendar_tasks where id = v_id;
        insert into probe_out values (6, 'un-completion clears the completion triple',
          format('c=%s at=%s src=%s', v_row.is_complete, v_row.completed_at, v_row.completed_source),
          'c=f at= src=',
          (not v_row.is_complete) and v_row.completed_at is null and v_row.completed_source is null);

        -- a null / non-boolean expectation is BAD INPUT, never a conflict
        begin
          perform ops.fn_record_calendar_task(jsonb_build_object(
            'jobber_gid', v_gid, 'expected_is_complete', null), null);
          v_code := 'NO ERROR';
        exception when others then get stacked diagnostics v_code = returned_sqlstate; end;
        insert into probe_out values (7, 'null expectation -> 22023, not a conflict',
          v_code, '22023', v_code = '22023');

        -- (c) CONTROL: the exception catcher really reports SQLSTATEs. Without this, every
        -- "-> ZZ002" above could be reading a variable nothing ever set.
        begin
          raise exception 'deliberate' using errcode = 'ZZ002';
        exception when others then get stacked diagnostics v_code = returned_sqlstate; end;
        insert into probe_out values (8, 'control: the catcher reports a SQLSTATE',
          v_code, 'ZZ002', v_code = 'ZZ002');
      end $p$;
      select n, name, got, want, pass from probe_out order by n;
      rollback;`)
  } catch (e) {
    console.log(`FAIL  INSTRUMENT ERROR, not a verdict -- ${e.message.slice(0, 220)}`)
    console.log('--- audit complete --- ' + JSON.stringify(
      { probe: 'calendar_task_poll', control_ok: false, failures: 1 }))
    process.exit(1)
  }

  for (const r of rows) check(r.name, r.pass === true, `got=${r.got}`)

  // ---- the cron wrapper + schedule + grants -------------------------------------------------
  const [w] = await sql(`
    select
      (select count(*) from cron.job where jobname = '${CRON_JOB}') as job_count,
      (select schedule from cron.job where jobname = '${CRON_JOB}') as schedule,
      (select active from cron.job where jobname = '${CRON_JOB}') as active,
      (select username from cron.job where jobname = '${CRON_JOB}') as runs_as,
      (select count(*) from cron.job where schedule = '*/5 * * * *') as jobs_on_every5,
      has_function_privilege('authenticated', '${WRAPPER}', 'EXECUTE') as authn_exec,
      has_function_privilege('anon', '${WRAPPER}', 'EXECUTE') as anon_exec,
      has_function_privilege('service_role', '${WRAPPER}', 'EXECUTE') as svc_exec,
      has_function_privilege('service_role', 'ops.fn_record_calendar_task(jsonb,text)', 'EXECUTE') as svc_recorder,
      (select pg_get_userbyid(proowner) from pg_proc where oid = '${WRAPPER}'::regprocedure) as owner,
      (select count(*) from public.sync_log where sync_source = '${SYNC_SOURCE}') as poll_runs,
      (select count(*) from ops.calendar_tasks) as tasks_now,
      (select count(*) from public.entity_source_links where entity_type = 'calendar_task') as links_now`)

  // CONTROL (c): the privilege reader must be able to SEE a grant that exists, or every negative
  // assertion below is worthless.
  check('control: has_function_privilege sees a known grant',
    w.svc_recorder === true, 'service_role EXECUTE on the recorder')
  if (w.svc_recorder !== true) {
    console.log('\n🛑 CONTROL FAILED -- the privilege reader is untrustworthy, so the grant')
    console.log('   assertions below would prove nothing. Not reporting them.')
    console.log('--- audit complete --- ' + JSON.stringify(
      { probe: 'calendar_task_poll', control_ok: false, failures: ++fails }))
    process.exit(1)
  }

  check(`cron job '${CRON_JOB}' exists and is active`, w.job_count === 1 && w.active === true,
    `count=${w.job_count} active=${w.active} runs_as=${w.runs_as}`)
  check(`schedule is ${CRON_SCHEDULE} (staggered off the ${w.jobs_on_every5} jobs on */5)`,
    w.schedule === CRON_SCHEDULE, `got ${w.schedule}`)
  check('the wrapper is postgres-only',
    w.authn_exec === false && w.anon_exec === false && w.svc_exec === false,
    `authenticated=${w.authn_exec} anon=${w.anon_exec} service_role=${w.svc_exec}`)
  check('the wrapper is owned by postgres (SECURITY DEFINER runs as the owner)',
    w.owner === 'postgres', `owner=${w.owner}`)
  check('the poll has written its own sync_log row', Number(w.poll_runs) > 0,
    `${w.poll_runs} run(s) recorded under sync_source='${SYNC_SOURCE}'`)

  // ---- and the probe left nothing behind ----------------------------------------------------
  // ⚠ An earlier version of this line compared w.tasks_now to itself, which is true for every
  // possible input -- a check that cannot fail, in a file whose whole subject is checks that can.
  // Assert on THIS PROBE'S OWN SENTINEL instead: it is the only thing the run could have left, and
  // unlike a table count it does not go stale the moment real tasks exist.
  const [leftovers] = await sql(`
    select count(*) as n from public.entity_source_links
     where entity_type = 'calendar_task'
       and source_id = 'Z2lkOi8vSm9iYmVyL1Rhc2svUFJPQkVfUE9MTA=='`)
  check('this probe wrote nothing (its sentinel left no link row)',
    Number(leftovers.n) === 0,
    `sentinel rows=${leftovers.n}; calendar_tasks=${w.tasks_now} links=${w.links_now}`)

  console.log(`\n${fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`}`)
  console.log('--- audit complete --- ' + JSON.stringify(
    { probe: 'calendar_task_poll', control_ok: true, cron: w.schedule, failures: fails }))
  process.exit(fails === 0 ? 0 : 1)
}
