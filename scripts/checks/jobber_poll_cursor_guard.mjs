// node scripts/checks/jobber_poll_cursor_guard.mjs [control-ref]
// Proves the sync-jobber-poll fix of 2026-10-06: a failed cursor read throws (it used to return
// null, which means "pull everything"), the cursor read sits inside the per-entity try, and the
// error path awaits its sync_log insert instead of calling .catch on a builder that has none.
// Runs getCursor extracted from the working tree AND from <control-ref> (default: the commit before
// the fix) against the same stubs; the control must FAIL, or the check proves nothing.
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { stripTypeScriptTypes } from 'node:module'

const PATH = 'supabase/functions/sync-jobber-poll/index.ts'
const control = process.argv[2] || 'df02aba'

function extractGetCursor(src) {
  const m = src.match(/async function getCursor\([\s\S]*?\n\}/)
  if (!m) throw new Error('getCursor not found: update this check')
  const js = stripTypeScriptTypes(m[0])
  return (supabase) => new Function('supabase', `${js}; return getCursor`)(supabase)
}
const stub = (result) => ({ from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => result }) }) }) })

async function behaviour(src) {
  const out = {}
  const run = async (name, result) => {
    try { out[name] = { value: await extractGetCursor(src)(stub(result))('visits') } }
    catch (e) { out[name] = { threw: String(e.message) } }
  }
  await run('error', { data: null, error: { message: 'PGRST002 schema cache' } })
  await run('no_row', { data: null, error: null })
  await run('row', { data: { last_synced_at: '2026-10-06T17:50:00Z' }, error: null })
  return out
}
const pass = (b) => !!b.error.threw && b.no_row.value === null && b.row.value === '2026-10-06T17:50:00Z'

const fixed = readFileSync(PATH, 'utf8')
const old = execSync(`git show ${control}:${PATH}`, { encoding: 'utf8' })
// Is any `.insert(...)` call (balanced parentheses, comments stripped) followed by `.catch(`?
function insertThenCatch(src) {
  const code = src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n')
  for (let i = code.indexOf('.insert('); i !== -1; i = code.indexOf('.insert(', i + 1)) {
    let depth = 0, j = i + '.insert'.length
    for (; j < code.length; j++) { if (code[j] === '(') depth++; else if (code[j] === ')' && --depth === 0) break }
    if (code.startsWith('.catch(', j + 1)) return true
  }
  return false
}
const f = await behaviour(fixed), o = await behaviour(old)
const shape = {
  cursor_inside_try: /try \{ cursor = await getCursor\(entity\.name\); nodes = await pullDelta/.test(fixed),
  no_builder_catch: !insertThenCatch(fixed),
  control_had_builder_catch: insertThenCatch(old),   // proves the detector can see the old defect
}
console.log('fixed  ', JSON.stringify(f))
console.log('control', JSON.stringify(o))
console.log('shape  ', JSON.stringify(shape))
const ok = pass(f) && !pass(o) && shape.cursor_inside_try && shape.no_builder_catch && shape.control_had_builder_catch
console.log(ok ? 'PASS' : 'FAIL')
process.exit(ok ? 0 : 1)
