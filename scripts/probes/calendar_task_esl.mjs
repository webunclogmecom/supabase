// Proves public.entity_source_links.entity_type accepts 'calendar_task'.
//
// Calendar Tasks link an ops.calendar_tasks row to its Jobber Task GID, and that link row is the
// ONLY thing deciding create-versus-edit on the push. On 2026-08-06 the same omission for
// 'calendar_day_marker' let jobber-push-task create a REAL Jobber Task, have the link insert
// rejected 23514, swallow it, and return ok:true -- so the next push would have put a SECOND Task
// on the crew's schedule. This probe is the standing guard on that constraint.
//
// Both inserts run inside begin/rollback, so nothing is written. entity_id = -999 cannot collide.
//
// 🛑 POSITIVE CONTROL: an already-allowed value ('visit') must insert cleanly on every run. A
//    target rejection only means something if the control succeeded -- otherwise the instrument is
//    broken and proves nothing (feedback_confident_zero_is_a_broken_instrument).
//
// Run:  node scripts/probes/calendar_task_esl.mjs                  (expects: calendar_task ALLOWED)
//       node scripts/probes/calendar_task_esl.mjs --expect-blocked (expects: rejected 23514)
// Exit: 0 = expectation met, 1 = expectation violated or instrument untrustworthy.
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// Resolve .env from the REPO ROOT, not the cwd. Tasks 2 and 3 import this module, and a relative
// '.env' is read at module load, so a different cwd would break the IMPORT itself, not just a call.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^["']|["']$/g, '').trim()]))

// Parameterized so a caller pointing .env at Sandbox does not silently write to Prod. The literal
// is only a fallback, preserving today's behaviour when SUPABASE_PROJECT_ID is absent.
const PROJECT_REF = env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk'

export async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.SUPABASE_PAT },
    body: JSON.stringify({ query }) })
  // Read TEXT first. A 502 from the gateway returns an HTML error page, and a bare r.json() would
  // throw a raw SyntaxError that reads exactly like a rejected insert -- making a transport blip
  // indistinguishable from the real pre-migration signal, which is the whole point of this probe.
  const t = await r.text()
  let j; try { j = JSON.parse(t) } catch { throw new Error(`non-JSON (HTTP ${r.status}): ${t.slice(0, 200)}`) }
  if (!Array.isArray(j)) throw new Error(`mgmt API error (HTTP ${r.status}): ${t.slice(0, 300)}`)
  return j
}

// process.argv[1] is UNDEFINED under `node -e` / `node --eval`, and pathToFileURL throws on
// undefined -- which would kill the IMPORT for Tasks 2 and 3, not just a direct run. Guard it.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // NOTE on the guard above: it MUST use pathToFileURL. On Windows import.meta.url is
  // `file:///C:/...` (three slashes) while `file://` + a backslash-replaced argv[1] yields
  // `file://C:/...` (two), so the hand-built form NEVER matches and this whole block is silently
  // skipped, exiting 0 with no output. A probe that prints nothing is not a passing probe.
  const expectBlocked = process.argv.includes('--expect-blocked')
  let fails = 0
  const check = (name, ok, detail) => {
    if (!ok) fails++
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`)
  }

  // POSITIVE CONTROL: an already-allowed value must insert cleanly.
  let controlOk = false, controlDetail = ''
  try {
    const control = await sql(`
      begin;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
      values ('visit', -999, 'jobber', 'PROBE-CONTROL');
      select 'control-inserted' as r;
      rollback;`)
    controlOk = JSON.stringify(control).includes('control-inserted')
    controlDetail = JSON.stringify(control).slice(0, 60)
  } catch (e) { controlDetail = e.message.slice(0, 160) }
  check("control: 'visit' (already allowed) inserts", controlOk, controlDetail)

  // The control is the licence to interpret the target. Without it, stop.
  if (!controlOk) {
    console.log('\n🛑 CONTROL FAILED -- the instrument is untrustworthy, so the target result below')
    console.log('   would be meaningless. Not reporting one. Fix access/connectivity and re-run.')
    console.log('--- audit complete --- ' + JSON.stringify(
      { probe: 'calendar_task_esl', control_ok: false, target_ok: null, failures: ++fails }))
    process.exit(1)
  }

  // TARGET: the new value. Distinguish a genuine CHECK rejection from a transport failure --
  // treating "anything threw" as "not allowed" is what lets a gateway blip masquerade as a finding.
  let targetOk = false, targetBlocked = false, targetDetail = ''
  try {
    await sql(`
      begin;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
      values ('calendar_task', -999, 'jobber', 'PROBE-TARGET');
      rollback;`)
    targetOk = true
    targetDetail = 'insert accepted'
  } catch (e) {
    const m = e.message
    // 23514 = check_violation, and it must name THIS constraint.
    if (m.includes('23514') && m.includes('entity_source_links')) {
      targetBlocked = true
      targetDetail = 'rejected 23514 by entity_source_links check'
    } else {
      console.log(`FAIL  target: INSTRUMENT ERROR, not a verdict -- ${m.slice(0, 200)}`)
      console.log('--- audit complete --- ' + JSON.stringify(
        { probe: 'calendar_task_esl', control_ok: true, target_ok: null, failures: ++fails }))
      process.exit(1)
    }
  }

  check(`target: 'calendar_task' ${expectBlocked ? 'REJECTED (--expect-blocked)' : 'allowed'}`,
    expectBlocked ? targetBlocked : targetOk, targetDetail)

  console.log(`\n${fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`}`)
  console.log('--- audit complete --- ' + JSON.stringify(
    { probe: 'calendar_task_esl', control_ok: controlOk, target_ok: targetOk, failures: fails }))
  process.exit(fails === 0 ? 0 : 1)
}
