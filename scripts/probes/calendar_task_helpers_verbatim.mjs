// Proves save-calendar-task's copied Jobber helpers still match jobber-push-task, and that the ONE
// deliberate fork is still forked.
//
// save-calendar-task lifts getJobberToken / gql / errsOf from jobber-push-task rather than retyping
// them, because retyping is how 2026-08-06_1316 silently dropped six clauses from a live function.
// Two of those helpers carry logic whose loss is SILENT: gql()'s HTML waiting-room check (Jobber
// sheds load with text/html at HTTP 200, which a naive helper reads as success with data:undefined)
// and errsOf() reading BOTH GraphQL error channels (a schema error has data:null and an EMPTY
// userErrors, so a userErrors-only reader calls it success).
//
// 🛑 etToUtcISO IS DELIBERATELY DIFFERENT AND MUST STAY DIFFERENT. jobber-push-task's version probes
//    the zone offset at 12:00 UTC -- 07:00/08:00 ET, AFTER the 02:00 transition -- and applies that
//    offset to minute 0, which is before it. On a spring-forward date minutes 0-119 land on the
//    PREVIOUS DAY (2026-03-08 min 0 -> 2026-03-07 23:00 ET). save-calendar-task carries a corrected
//    copy. This probe asserts the fork is intact in BOTH directions, so that "restoring consistency"
//    with the original cannot pass unnoticed.
//    ⚠ jobber-push-task and jobber-push-visit STILL CARRY THE BUG. Both are live. Fixing them was
//      out of scope for the task that forked this copy; it is a real open item, not an oversight.
//
// 🛑 WHY THIS FILE EXISTS AT ALL: save-calendar-task's header used to claim these helpers were
//    "sha256-checked at build time". THERE IS NO BUILD STEP. `supabase functions deploy` bundles and
//    uploads and nothing else runs; npm test is a stub; there are no active git hooks and no CI job
//    that touches edge functions. The comment asserted a check that had never been committed, which
//    is worse than no check: a reader trusts it and skips verifying. This probe is that check, and
//    it is a probe someone RUNS, not a build step.
//
// 🛑 POSITIVE CONTROLS, because a comparator that matches everything would pass silently:
//    (a) each extracted block must be non-trivial -- two empty strings compare equal;
//    (b) a one-character mutation of a matched helper must NOT compare equal;
//    (c) the buggy 12:00-UTC probe must be FOUND in the original, or "absent from the new copy"
//        is measuring a string that does not exist anywhere.
//
// SCOPE, so nobody over-reads a pass: this compares FUNCTION BODIES ONLY -- from the `function
// NAME(` line to its closing brace. The explanatory comments ABOVE each helper are NOT compared,
// so an edit to a comment will not fail this probe. That is deliberate (comments are not logic and
// the two files organise them differently), but it does mean a pass says the CODE matches, not that
// the surrounding prose does.
//
// Run:  node scripts/probes/calendar_task_helpers_verbatim.mjs
// Exit: 0 = helpers verbatim and the fork intact, 1 = drift, or the instrument is untrustworthy.
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const SRC = join(ROOT, 'supabase', 'functions', 'jobber-push-task', 'index.ts')
const NEW = join(ROOT, 'supabase', 'functions', 'save-calendar-task', 'index.ts')

// Helpers copied verbatim. etToUtcISO is deliberately NOT in this list -- see FORKED below.
export const VERBATIM = ['getJobberToken', 'gql', 'errsOf']
export const FORKED = 'etToUtcISO'
const BUGGY_PROBE = 'T12:00:00Z'          // the 12:00-UTC offset probe, the DST bug's signature

// Extract by NAME, never by line number: a hard-coded range silently compares the wrong text the
// first time either file shifts by a line, and that failure looks exactly like a passing check.
// Ends at the first line that is exactly '}' -- the file's own formatting convention.
export function extract(text, name) {
  const lines = text.split('\n').map(l => l.replace(/\r$/, ''))   // LF/CRLF-insensitive
  const i = lines.findIndex(l => new RegExp('^(async )?function ' + name + '\\(').test(l))
  if (i < 0) return null
  for (let j = i; j < lines.length; j++) if (lines[j] === '}') return lines.slice(i, j + 1).join('\n')
  return null
}

const sha = s => createHash('sha256').update(s, 'utf8').digest('hex').slice(0, 16)

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // pathToFileURL, not a hand-built 'file://' + path: on Windows import.meta.url has three slashes
  // and the hand-built form has two, so the block would be skipped and the probe would exit 0
  // having printed nothing. A probe that prints nothing is not a passing probe.
  let fails = 0
  const check = (name, ok, detail) => {
    if (!ok) fails++
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`)
  }

  let src, nw
  try {
    src = readFileSync(SRC, 'utf8')
    nw = readFileSync(NEW, 'utf8')
  } catch (e) {
    console.log(`FAIL  INSTRUMENT ERROR, not a verdict -- ${e.message.slice(0, 200)}`)
    console.log('--- audit complete --- ' + JSON.stringify(
      { probe: 'calendar_task_helpers_verbatim', control_ok: false, failures: 1 }))
    process.exit(1)
  }

  // ---- CONTROL (c): the bug's signature must EXIST in the original --------------------------
  const controlBuggy = src.includes(BUGGY_PROBE)
  check(`control: the ${BUGGY_PROBE} probe is present in jobber-push-task`, controlBuggy,
    controlBuggy ? 'the string being searched for is real' : 'NOTHING to detect -- absence proves nothing')

  if (!controlBuggy) {
    console.log('\n🛑 CONTROL FAILED -- either jobber-push-task was fixed (good: re-scope this probe)')
    console.log('   or the search string is stale. Either way the fork assertions below are')
    console.log('   meaningless. Not reporting them.')
    console.log('--- audit complete --- ' + JSON.stringify(
      { probe: 'calendar_task_helpers_verbatim', control_ok: false, failures: ++fails }))
    process.exit(1)
  }

  // ---- the three helpers that MUST be byte-identical ----------------------------------------
  for (const name of VERBATIM) {
    const a = extract(src, name)
    const b = extract(nw, name)
    if (a === null || b === null) {
      check(`${name}: extractable from both files`, false,
        `${a === null ? 'MISSING in jobber-push-task' : ''}${b === null ? ' MISSING in save-calendar-task' : ''}`.trim())
      continue
    }
    // CONTROL (a): two empty strings compare equal. Require real content.
    if (a.length < 100) {
      check(`${name}: extracted block is non-trivial`, false, `only ${a.length} bytes -- extractor is broken`)
      continue
    }
    check(`${name} is byte-identical`, a === b, `sha256=${sha(a)} bytes=${a.length} lines=${a.split('\n').length}`)

    // CONTROL (b): the comparator must reject a one-character change.
    const mutated = a.replace(/[a-z]/, c => c.toUpperCase())
    check(`  control: a 1-char mutation of ${name} does NOT compare equal`, mutated !== a && mutated !== b)
  }

  // ---- the ONE deliberate fork, asserted in BOTH directions ---------------------------------
  const fa = extract(src, FORKED)
  const fb = extract(nw, FORKED)
  check(`${FORKED}: present in both files`, fa !== null && fb !== null)
  if (fa && fb) {
    check(`${FORKED} DIFFERS (the deliberate fork is intact)`, fa !== fb,
      fa === fb ? 'the buggy original has been restored -- see the header of save-calendar-task' : `orig=${sha(fa)} new=${sha(fb)}`)
  }
  check(`the ${BUGGY_PROBE} probe is ABSENT from save-calendar-task`, !nw.includes(BUGGY_PROBE),
    nw.includes(BUGGY_PROBE) ? 'the DST bug is back' : 'DST fix intact')

  // The fork must stay self-explaining, or someone "restores consistency" with the original.
  check('the fork is announced in save-calendar-task', nw.includes('DELIBERATELY NOT IDENTICAL'))
  check('the still-buggy siblings are named', nw.includes('STILL CARRY THE BUG'))

  console.log(`\n${fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`}`)
  console.log('--- audit complete --- ' + JSON.stringify(
    { probe: 'calendar_task_helpers_verbatim', control_ok: true, verbatim: VERBATIM, forked: FORKED, failures: fails }))
  process.exit(fails === 0 ? 0 : 1)
}
