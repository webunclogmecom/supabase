// node scripts/checks/job_drift_date_clear.mjs [control-ref]
// Runs the REAL sync-jobber-job-drift (working tree AND the body before the fix) offline against one set of
// Jobber replies, and asserts what the run would write. Trello #177, 2026-11-06: a job whose last visit went
// and whose webhook was lost kept its old dates, because a date was copied only when Jobber had one.
// The danger of the fix: "no date" is what a MISSING answer looks like, and this file once nearly archived 25
// live jobs that way. So a clear must happen on a real `null` and on nothing else.
// The control must FAIL exactly the real-answer cases, or this check proves nothing.
// Talks to nothing: fetch, the database and timers are stubs. Never contacts Jobber or Prod.
import fs from 'node:fs'
import vm from 'node:vm'
import { execSync } from 'node:child_process'
import { edgeVmSource } from './edge_vm_source.mjs'

const PATH = 'supabase/functions/sync-jobber-job-drift/index.ts'
const control = process.argv[2] || 'aab4ac09'
const IMPORT = /^import \{ createClient \} from "jsr:@supabase\/supabase-js@2";\r?\n/m

const DATED = { start_at: '2026-11-11T05:00:00+00:00', end_at: '2026-11-12T04:59:59+00:00' }
const row = (id, over = {}) => ({ id, title: 'T', job_status: 'active', frequency_days: 0, updated_at: '2026-11-06T00:00:00Z', ...DATED, ...over })
const gid = (id) => `gid-${id}`
const node = (id, over = {}) => ({ id: gid(id), title: 'T', jobStatus: 'active', startAt: DATED.start_at, endAt: DATED.end_at, customFields: [], lineItems: { nodes: [] }, ...over })
const json = (body) => ({ ctype: 'application/json', body })
const nodes = (...n) => json({ data: { jobs: { nodes: n } } })

// Runs one whole invocation. reply(): what Jobber answers. Returns every job write and the logged stats.
async function run(ts, rows, reply) {
  const writes = []
  let logged = null
  const from = (table) => {
    const q = {
      _f: {},
      select() { return q },
      not() { q._f.live = true; return q },
      in(col) { if (col === 'job_status') q._f.terminal = true; return q },
      gte() { return q },
      eq() { return q },
      is() { return q },
      single() { return q },
      update(patch) { return { eq: async (_c, id) => { writes.push({ id, patch }); return { error: null } } } },
      insert: async (r) => { logged = r; return { error: null } },
      then(res) {
        if (table === 'webhook_tokens') return res({ data: { access_token: 'x' }, error: null })
        if (table === 'jobs') return res({ data: q._f.live ? rows : [], error: null })
        if (table === 'entity_source_links') return res({ data: rows.map((r) => ({ entity_id: r.id, source_id: gid(r.id) })), error: null })
        if (table === 'line_items') return res({ data: [], error: null })
        return res({ data: [], error: null })
      },
    }
    return q
  }
  let handler
  const ctx = {
    console: { log() {}, error() {} },
    Deno: { env: { get: () => 'x' }, serve: (h) => { handler = h } },
    createClient: () => ({ from, rpc: async () => ({ error: null }) }),
    isSecretKeyCaller: () => true,
    setTimeout: (f) => setImmediate(f),
    Response: class { constructor(b) { this.b = b } },
    fetch: async () => {
      const { ctype, body } = reply()
      return { status: 200, headers: { get: () => ctype }, json: async () => body }
    },
    atob, Map, Date, Number, String, JSON, Math, Array, Object, Promise, Error, RegExp,
  }
  // The one import vm cannot run, swapped for the stub above; the shared helper import is also stubbed.
  const src = ts.replace(IMPORT, '').replace(/^import \{ isSecretKeyCaller \} from .*\r?\n/m, '')
  vm.runInNewContext(edgeVmSource(src), ctx)
  await handler({ method: 'POST', headers: { get: () => '' } })
  return { writes, stats: logged?.details ?? {}, status: logged?.status }
}

const clears = (w) => w.filter((x) => 'start_at' in x.patch || 'end_at' in x.patch)
const cleared = (w, id) => w.some((x) => x.id === id && x.patch.start_at === null && x.patch.end_at === null)

// name, whether the pre-fix body must FAIL it, the rows, Jobber's reply, the assertion
const CASES = [
  ['A real null clears both dates (the 2194 shape)', true,
    [row(1)], () => nodes(node(1, { startAt: null, endAt: null })),
    (r) => cleared(r.writes, 1) && r.stats.updated === 1 && r.status === 'success'],
  ['A real null on one date clears only that date', true,
    [row(2)], () => nodes(node(2, { endAt: null })),
    (r) => r.writes.length === 1 && r.writes[0].patch.end_at === null && !('start_at' in r.writes[0].patch)],
  ['Three clears in one batch still go through', true,
    [row(3), row(4), row(5)], () => nodes(node(3, { startAt: null, endAt: null }), node(4, { startAt: null, endAt: null }), node(5, { startAt: null, endAt: null })),
    (r) => cleared(r.writes, 3) && cleared(r.writes, 4) && cleared(r.writes, 5) && r.stats.date_clears_refused === 0],

  ['A missing key is no answer: nothing is cleared', false,
    [row(10)], () => { const n = node(10); delete n.startAt; delete n.endAt; return nodes(n) },
    (r) => clears(r.writes).length === 0 && r.stats.checked === 1],
  ['An empty string is no answer: nothing is written', false,
    [row(11)], () => nodes(node(11, { startAt: '', endAt: '' })),
    (r) => clears(r.writes).length === 0],
  ['null next to an errors entry (a hidden field): the batch fails, nothing is cleared', false,
    [row(12)], () => json({ data: { jobs: { nodes: [node(12, { startAt: null, endAt: null })] } }, errors: [{ message: 'was hidden due to permissions' }] }),
    (r) => r.writes.length === 0 && r.stats.errors >= 1 && r.stats.checked === 0],
  ['No data key: the batch fails, nothing is written', false,
    [row(13)], () => json({ extensions: { cost: {} } }),
    (r) => r.writes.length === 0 && r.stats.errors >= 1 && r.stats.checked === 0],
  ['data: {} (the old mass-archive shape): the batch fails, nothing is written', false,
    [row(14)], () => json({ data: {} }),
    (r) => r.writes.length === 0 && r.stats.errors >= 1 && r.stats.checked === 0],
  ['An HTML waiting room at 200: nothing is written', false,
    [row(15)], () => ({ ctype: 'text/html', body: {} }),
    (r) => r.writes.length === 0 && r.stats.errors >= 1 && r.stats.checked === 0],

  ['Four in one batch is not a lost webhook: no clear, the run says so', false,
    [row(20), row(21), row(22), row(23)], () => nodes(...[20, 21, 22, 23].map((i) => node(i, { startAt: null, endAt: null }))),
    (r) => clears(r.writes).length === 0],
  ['A refused batch still copies a real date on another job', false,
    [row(30), row(31), row(32), row(33), row(34)],
    () => nodes(...[30, 31, 32, 33].map((i) => node(i, { startAt: null, endAt: null })), node(34, { startAt: '2026-12-01T05:00:00+00:00' })),
    (r) => clears(r.writes).length === 1 && r.writes[0].id === 34 && r.writes[0].patch.start_at === '2026-12-01T05:00:00+00:00'],

  ['Jobber null and ours null: no write (runs must stay quiet)', false,
    [row(40, { start_at: null, end_at: null })], () => nodes(node(40, { startAt: null, endAt: null })),
    (r) => r.writes.length === 0 && r.stats.updated === 0],
  ['Same instant written differently: no write', false,
    [row(41)], () => nodes(node(41, { startAt: '2026-11-11T05:00:00Z', endAt: '2026-11-12T04:59:59Z' })),
    (r) => r.writes.length === 0],
  ['A new date is copied as before', false,
    [row(42)], () => nodes(node(42, { startAt: '2026-12-01T05:00:00+00:00' })),
    (r) => r.writes.length === 1 && r.writes[0].patch.start_at === '2026-12-01T05:00:00+00:00' && !('end_at' in r.writes[0].patch)],
  ['A date arriving on an empty job is copied as before', false,
    [row(43, { start_at: null, end_at: null })], () => nodes(node(43)),
    (r) => r.writes.length === 1 && r.writes[0].patch.start_at === DATED.start_at],
  ['A job Jobber did not return is archived, its dates untouched', false,
    [row(44)], () => nodes(),
    (r) => r.writes.length === 1 && r.writes[0].patch.job_status === 'archived' && clears(r.writes).length === 0],
]

const fixed = fs.readFileSync(PATH, 'utf8')
const old = execSync(`git show ${control}:${PATH}`, { encoding: 'utf8' })
if (fixed === old) { console.log('FAIL control is the working tree: pick the ref before the fix'); process.exit(1) }

let bad = 0
for (const [name, controlFails, rows, reply, ok] of CASES) {
  const f = await run(fixed, rows, reply), o = await run(old, rows, reply)
  const fPass = ok(f), oPass = ok(o)
  const line = (fPass ? 'PASS' : 'FAIL') + ' ' + name + (controlFails === oPass ? `  [control ${oPass ? 'passed' : 'failed'}, expected the opposite]` : '')
  if (!fPass || controlFails === oPass) { bad++; console.log(line, JSON.stringify(f)) } else console.log(line)
}
const mustFail = CASES.filter((c) => c[1]).length
console.log(`\n${CASES.length} cases, the pre-fix body (${control}) had to fail exactly ${mustFail}. ${bad ? bad + ' WRONG' : 'All right.'}`)

// A refused batch must reach a person: the run reads partial, with the count and the words in its row.
const refused = CASES.find((c) => c[0].startsWith('Four in one batch'))
const rr = await run(fixed, refused[2], refused[3])
const said = rr.status === 'partial' && rr.stats.date_clears_refused === 4 && /no date/.test(rr.stats.error_samples?.[0] ?? '')
console.log(`${said ? 'PASS' : 'FAIL'} a refused batch logs partial, date_clears_refused 4 and a sentence`)
if (!said) bad++

// The guards themselves: put each weakness back, and the named cases must start failing.
const MUTANTS = [
  ['`!answer` instead of `=== null`', 'if (answer === null) return ours == null ? undefined : null;', 'if (!answer) return ours == null ? undefined : null;',
    ['A missing key is no answer', 'An empty string is no answer']],
  ['no per-batch limit', 'const clearsAllowed = dateClears <= MAX_DATE_CLEARS_PER_BATCH;', 'const clearsAllowed = true;',
    ['Four in one batch', 'A refused batch still copies']],
  ['a clear even when ours is already empty', 'if (answer === null) return ours == null ? undefined : null;', 'if (answer === null) return null;',
    ['Jobber null and ours null']],
]
for (const [what, from, to, names] of MUTANTS) {
  if (!fixed.includes(from)) { console.log(`FAIL mutant anchor missing: ${what}`); bad++; continue }
  const mutated = fixed.replace(from, to)
  for (const prefix of names) {
    const c = CASES.find((x) => x[0].startsWith(prefix))
    const r = await run(mutated, c[2], c[3])
    const caught = !c[4](r)
    console.log(`${caught ? 'PASS' : 'FAIL'} mutant "${what}" is caught by: ${prefix}`)
    if (!caught) bad++
  }
}
process.exit(bad ? 1 : 0)
