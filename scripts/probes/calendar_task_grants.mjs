// Proves ops.calendar_tasks + ops.calendar_task_assignees hold NO write grant, for ANY role.
//
// All writes go through ops.fn_record_calendar_task (SECDEF) called by the save-calendar-task edge
// function only AFTER Jobber has confirmed the change. A write grant on either table would reopen a
// PostgREST path around that, which is what stops our copy claiming something Jobber does not have.
//
// 🛑 ABSENCE IS A FAILURE BY DEFAULT. An earlier version iterated whatever the catalogue returned,
//    so pointing it at tables that do not exist looped over an empty array and exited 0 -- the
//    instrument greenlit a dropped, renamed, or never-migrated table. A probe that cannot fail is
//    worse than no probe, because it is trusted. The expected-state is now declared by the caller.
//
// 🛑 POSITIVE CONTROL: ops.visit_requests is the shape being copied and must read SELECT-only on
//    every run, in BOTH modes. It is unrelated to whether our tables exist yet, and if it ever fails
//    the run proves nothing either way (feedback_confident_zero_is_a_broken_instrument).
//
// Run:  node scripts/probes/calendar_task_grants.mjs                 (expects: both tables, read-only)
//       node scripts/probes/calendar_task_grants.mjs --expect-absent (expects: neither table exists)
// Exit: 0 = expectation met, 1 = expectation violated or instrument untrustworthy.
import { sql } from './calendar_task_esl.mjs'

const CONTROL = 'visit_requests'
const TARGETS = ['calendar_tasks', 'calendar_task_assignees']
const expectAbsent = process.argv.includes('--expect-absent')

const rows = await sql(`
  select c.relname,
         c.relrowsecurity as rls_on,
         c.relacl::text   as acl,
         has_table_privilege('authenticated','ops.'||c.relname,'SELECT') as authn_select,
         has_table_privilege('authenticated','ops.'||c.relname,'INSERT') as authn_insert,
         has_table_privilege('authenticated','ops.'||c.relname,'UPDATE') as authn_update,
         has_table_privilege('authenticated','ops.'||c.relname,'DELETE') as authn_delete,
         has_table_privilege('service_role','ops.'||c.relname,'INSERT')  as svc_insert
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'ops' and c.relname in (${[CONTROL, ...TARGETS].map(t => `'${t}'`).join(', ')})
   order by c.relname`)

const done = (fails) => {
  console.log('--- audit complete --- ' + JSON.stringify(
    { probe: 'calendar_task_grants', mode: expectAbsent ? 'expect-absent' : 'expect-present',
      found: rows.length, failures: fails }))
  process.exit(fails ? 1 : 0)
}

// CONTROL: ops.visit_requests is the shape we are copying. It must show authn SELECT-only.
const control = rows.find(r => r.relname === CONTROL)
if (!control) {
  console.log(`🛑 CONTROL MISSING: ops.${CONTROL} not found -- the instrument is untrustworthy, so`)
  console.log('   the target results below would be meaningless. Not reporting any.')
  done(1)
}
const controlOk = control.authn_select && !control.authn_insert && !control.svc_insert
console.log(`CONTROL ops.${CONTROL} SELECT-only: ${controlOk}  (must be true, in BOTH modes)`)
if (!controlOk) {
  console.log('🛑 CONTROL FAILED -- ops.visit_requests is no longer the read-only template this')
  console.log('   probe compares against. Fix that first; the target results prove nothing until then.')
  done(1)
}

// TARGETS: name by name, never by row count -- a future third row must not be able to stand in for
// a missing one.
let fails = 0
for (const name of TARGETS) {
  const r = rows.find(x => x.relname === name)

  if (expectAbsent) {
    const good = !r
    if (!good) fails++
    console.log(`  ops.${name}: ${r ? 'PRESENT' : 'absent'}  => ${good ? 'OK' : 'WRONG: it exists, but --expect-absent was passed'}`)
    continue
  }

  if (!r) {
    fails++
    console.log(`  ops.${name}: MISSING => WRONG: the table does not exist here. Either the migration`)
    console.log('     never ran against this project, or the table was dropped or renamed. Pass')
    console.log('     --expect-absent if you meant to assert it is gone.')
    continue
  }

  const good = r.rls_on && r.authn_select &&
    !r.authn_insert && !r.authn_update && !r.authn_delete && !r.svc_insert
  if (!good) fails++
  console.log(`  ops.${r.relname}: rls=${r.rls_on} authn(s/i/u/d)=${r.authn_select}/${r.authn_insert}/${r.authn_update}/${r.authn_delete} svc_insert=${r.svc_insert}  => ${good ? 'OK' : 'WRONG'}`)
}

console.log(fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`)
done(fails)
