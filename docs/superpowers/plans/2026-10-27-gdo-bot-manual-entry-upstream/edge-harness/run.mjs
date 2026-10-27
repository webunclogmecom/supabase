// Drives recordManualEntry of old / plan / mine with a stubbed Supabase client and a stubbed Slack.
const ENV = { RPA_BOT_KEYS: 'k1', SUPABASE_URL: 'http://x', SUPABASE_SERVICE_ROLE_KEY: 's', SLACK_BOT_TOKEN: 't' }
const handlers = {}
for (const name of ['old', 'plan', 'mine']) {
  globalThis.Deno = { env: { get: (k) => ENV[k] }, serve: (h) => { handlers[name] = h } }
  await import(`./${name}.mjs?${name}`)
}
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString('base64')
const RUN = 'd079deb3-002b-4394-add1-3ddc2b59987d'
const ROW = { id: 2030, visit_id: 8889, gdo_id: 69, screenshot_path: `8889/manual-bot-${RUN}.jpg` }
// B2 shape, exactly what the plan's build_result_payload would emit for T1
const body = (over = {}, meOver = {}) => ({
  visit_id: null, manifest_id: null, run_id: RUN, status: 'SUCCESS', retryable: false,
  attempted_at: '2026-10-27T16:24:48Z', dry_run: false,
  manual_entry: { created_by: 'yan', why: 'entered by hand on the dashboard; no upstream visit', gdo_number: '14965',
    ticket_number: '487956', service_date: '2025-03-25', dump_date: '2025-03-28', ...meOver },
  screenshot: JPEG, portal_confirmation: 'Submitted - DERM email confirmed', ...over })

function makeSb(sc) {
  const calls = []
  let subReads = 0
  const sb = {
    from(table) {
      const q = { table, filters: [] }
      const b = {
        select() { return b }, eq(c, v) { q.filters.push(`${c}=${v}`); return b }, limit() { return b },
        then(res, rej) {
          calls.push(`read ${table}`)
          let out
          if (table === 'derm_portal_submissions') out = subReads++ === 0 ? sc.dedupe : sc.reread
          else if (table === 'v_derm_portal_fields') out = { data: [{ visit_id: 8889, gdo_id: 69, gdo_number: 'GDO-14965', ticket_number: '487956', manifest_id: 2090 }], error: null }
          else if (table === 'manifest_visits') out = { data: [{ visit_id: 8889 }], error: null }
          return Promise.resolve(out).then(res, rej)
        },
      }
      return b
    },
    storage: { from: () => ({
      upload: async (p) => { calls.push(`upload ${p}`); return { error: null } },
      remove: async (ps) => { calls.push(`REMOVE ${ps.join(',')}`); return { error: null } } }) },
    rpc: async (fn) => { calls.push(`rpc ${fn}`); return sc.rpc },
  }
  return { sb, calls }
}
const none = { data: [], error: null }
const scenarios = {
  'S1 race: same run recorded first, our RPC 23505': { dedupe: none, reread: { data: [ROW], error: null }, rpc: { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint "derm_portal_submissions_visit_attempt_uniq"' } } },
  'S2 other run already filed this permit (23505)': { dedupe: none, reread: none, rpc: { data: null, error: { code: '23505', message: 'visit 8889 already has a filing on record for that GDO permit' } } },
  'S3 race, and the re-read itself fails': { dedupe: none, reread: { data: null, error: { message: 'fetch failed' } }, rpc: { data: null, error: { code: '23505', message: 'dup' } } },
  'S4 RPC committed, only its answer was lost (no code)': { dedupe: none, reread: { data: [ROW], error: null }, rpc: { data: null, error: { message: 'TypeError: fetch failed' } } },
  'S5 transient RPC error, no row': { dedupe: none, reread: none, rpc: { data: null, error: { message: 'TypeError: fetch failed' } } },
  'S6 22023 refusal': { dedupe: none, reread: none, rpc: { data: null, error: { code: '22023', message: 'visit 8889 does not exist, is deleted, or is not completed' } } },
  'S7 happy path': { dedupe: none, reread: none, rpc: { data: { id: 9999 }, error: null } },
  'A3 replay of the stored run (dedupe hit)': { dedupe: { data: [ROW], error: null }, reread: none, rpc: { data: null, error: null } },
}
async function call(name, sc, b) {
  const { sb, calls } = makeSb(sc)
  globalThis.__sb = sb
  const slack = []
  globalThis.fetch = async (url, init) => { slack.push(url); return { json: async () => ({ ok: true }), status: 200 } }
  const res = await handlers[name](new Request('http://x/', { method: 'POST', headers: { 'x-rpa-key': 'k1', 'content-type': 'application/json' }, body: JSON.stringify(b) }))
  const out = await res.json()
  return { status: res.status, out, calls, slack: slack.length }
}
const quiet = console.error; console.error = () => {}; console.info = () => {}
for (const [label, sc] of Object.entries(scenarios)) {
  console.log('\n## ' + label)
  for (const name of ['old', 'plan', 'mine']) {
    const r = await call(name, sc, body())
    console.log(`  ${name.padEnd(4)} HTTP ${r.status} slack=${r.slack} ${JSON.stringify(r.out)}\n       calls: ${r.calls.join(' | ')}`)
  }
}
console.log('\n## controls on mine')
const c1 = await call('mine', scenarios['A3 replay of the stored run (dedupe hit)'], body({}, { client_name: 'x' }))
console.log('  extra manual_entry.client_name:', c1.status, JSON.stringify(c1.out), 'calls:', c1.calls.length, 'slack:', c1.slack)
const c2 = await call('mine', { dedupe: none, reread: none, rpc: {} }, body({ run_id: 'fresh-' + Date.now(), dry_run: true }))
console.log('  fresh run + dry_run:true:', c2.status, JSON.stringify(c2.out), 'calls:', c2.calls.join(' | '), 'slack:', c2.slack)
const c3 = await call('mine', scenarios['A3 replay of the stored run (dedupe hit)'], body({ gdo_id: 69 }))
console.log('  gdo_id on a manual body:', c3.status, JSON.stringify(c3.out))
const c4 = await call('mine', scenarios['A3 replay of the stored run (dedupe hit)'], body({ client_name: 'x' }))
console.log('  top-level client_name:', c4.status, JSON.stringify(c4.out))
console.error = quiet
