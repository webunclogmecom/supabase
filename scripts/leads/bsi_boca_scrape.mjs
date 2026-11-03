// Read-only scrape of BSI Online FOG properties in Boca Raton (Trello f3Q3Q55i, "scrape BSI Online restaurant data").
//
//   node --env-file=.env scripts/leads/bsi_boca_scrape.mjs [--out <file>] [--delay-ms 1500] [--max <n>] [--search-only]
//
// Env: BSI_USERNAME, BSI_PASSWORD (our hauler login, UNCLOGME LLC; Fred: "use the main account"). Never printed.
// Output: the raw API answers, by default in the workspace backups/ folder (client data, outside this public repo):
//   ../backups/<ET date>_bsi_boca_raw.json   { fetched_at, account, terms, properties: { <bsi id>: { found_by,
//   search_item, detail } }, done }. Re-running resumes: properties already holding a detail are not fetched again.
//
// BSI Online (app.bsionlinetracking.com) is a single-page app over a JSON API. This script only GETs, one request at a
// time with a pause between them (about 440 requests, 11 minutes at the default 1.5 s): the search by "Boca Raton" and by
// each Boca ZIP code, then GET /testing-company/fog/properties/{id} for the interceptors (type, size, next and last pump
// date, last report id). It stops at the first refusal (401, 403, 429) or non-JSON answer rather than retrying into a
// ban. Control: Grove Kosher Market (BSI 957372, our 022-GRO) must come back with 2 interceptors, or the run exits 2.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const API = 'https://app.bsionlinetracking.com/api'
const TERMS = ['Boca Raton', '33427', '33428', '33429', '33431', '33432', '33433', '33434', '33481', '33486', '33487',
  '33488', '33496', '33497', '33498', '33499']
const CONTROL_ID = '957372'

const arg = (name, dflt) => { const i = process.argv.indexOf(name); return i < 0 ? dflt : process.argv[i + 1] }
const DELAY = Number(arg('--delay-ms', 1500))
const MAX = Number(arg('--max', Infinity))
const SEARCH_ONLY = process.argv.includes('--search-only')
const etDate = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York' }).format(new Date())
const OUT = path.resolve(arg('--out', path.join(REPO, '..', 'backups', `${etDate}_bsi_boca_raw.json`)))

if (!process.env.BSI_USERNAME || !process.env.BSI_PASSWORD) {
  console.error('Missing BSI_USERNAME / BSI_PASSWORD in Supabase/.env (Fred adds them; this script never prints them).')
  process.exit(1)
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let auth = { token: null, cookie: '' }

async function call(method, p, body) {
  for (let attempt = 1; ; attempt++) {
    const r = await fetch(API + p, {
      method,
      headers: {
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(auth.token ? { Authorization: `Bearer ${auth.token}` } : {}),
        ...(auth.cookie ? { Cookie: auth.cookie } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    })
    const ctype = r.headers.get('content-type') ?? ''
    if ([401, 403, 429].includes(r.status)) throw new Error(`BSI refused ${method} ${p}: HTTP ${r.status}. Stopping.`)
    if (r.status >= 500 && attempt < 3) { await sleep(5000 * attempt); continue }
    if (!ctype.includes('json')) throw new Error(`BSI answered ${method} ${p} with ${ctype || 'no content type'} at HTTP ${r.status}. Stopping.`)
    const json = await r.json()
    if (!r.ok) throw new Error(`BSI ${method} ${p}: HTTP ${r.status} ${JSON.stringify(json).slice(0, 200)}`)
    return { json, res: r }
  }
}

function save(state) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true })
  fs.writeFileSync(OUT + '.tmp', JSON.stringify(state))
  fs.renameSync(OUT + '.tmp', OUT)
}

// 1. Sign in (the token is kept in memory only)
const login = await call('POST', '/login', { username: process.env.BSI_USERNAME, password: process.env.BSI_PASSWORD, locale: 'en' })
auth.token = login.json.token
auth.cookie = (login.res.headers.getSetCookie?.() ?? []).map((c) => c.split(';')[0]).join('; ')
if (!auth.token) throw new Error('BSI login answered without a token')
const { json: profile } = await call('GET', '/testing-company/profile/')
if (profile.hauling_company_name !== 'UNCLOGME LLC') throw new Error(`Signed in as "${profile.hauling_company_name}", expected UNCLOGME LLC`)

const state = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf8')) : { properties: {} }
Object.assign(state, {
  source: 'bsi_online', fetched_at: new Date().toISOString(), done: false,
  account: { testing_company_id: profile.id, hauling_company_id: profile.hauling_company_id },
  terms: state.terms ?? {},
})

// 2. Find every property: "Boca Raton" plus each Boca ZIP (the search also matches other words, so keep the union)
for (const term of TERMS) {
  let page = 1, seen = 0, total = Infinity
  while (seen < total && page <= 40) {
    await sleep(DELAY)
    const q = new URLSearchParams({ search: term, page, per_page: 50, sort_column: 'label', sort_direction: 'asc' })
    const { json } = await call('GET', `/testing-company/fog/search?${q}`)
    total = Number(json.total)
    for (const it of json.items ?? []) {
      const p = (state.properties[it.id] ??= { found_by: [] })
      p.search_item = it
      if (!p.found_by.includes(term)) p.found_by.push(term)
    }
    seen += (json.items ?? []).length
    if (!(json.items ?? []).length) break
    page++
  }
  state.terms[term] = total
  console.log(`search "${term}": ${total} (${Object.keys(state.properties).length} distinct so far)`)
  save(state)
}
if (!state.properties[CONTROL_ID]) { console.error(`CONTROL FAILED: Grove Kosher (${CONTROL_ID}) not found`); process.exit(2) }

// 3. Interceptors, one property at a time
if (!SEARCH_ONLY) {
  const ids = Object.keys(state.properties).sort((a, b) => (a === CONTROL_ID ? -1 : b === CONTROL_ID ? 1 : a - b))
  let fetched = 0
  for (const id of ids) {
    if (state.properties[id].detail) continue
    if (fetched >= MAX) break
    await sleep(DELAY)
    state.properties[id].detail = (await call('GET', `/testing-company/fog/properties/${id}`)).json
    if (++fetched % 25 === 0) { save(state); console.log(`details: ${fetched}`) }
  }
  const control = state.properties[CONTROL_ID].detail
  if (!control || (control.interceptors ?? []).length !== 2) { save(state); console.error('CONTROL FAILED: Grove Kosher detail without 2 interceptors'); process.exit(2) }
  state.done = ids.every((id) => state.properties[id].detail)
}
save(state)

// 4. Summary
const props = Object.values(state.properties)
const withDetail = props.filter((p) => p.detail)
const ics = withDetail.flatMap((p) => (p.detail.interceptors ?? []).filter((i) => i.active === 'y'))
const today = new Date(etDate)
const overdue = ics.filter((i) => i.next_pump_date && new Date(i.next_pump_date) < today)
const tally = (xs, f) => xs.reduce((m, x) => ((m[f(x)] = (m[f(x)] ?? 0) + 1), m), {})
console.log(JSON.stringify({
  out: OUT, done: state.done, properties: props.length, with_detail: withDetail.length,
  by_organization: tally(withDetail, (p) => p.detail.organization_name ?? '(none)'),
  by_city: tally(props, (p) => (p.search_item?.physical_address?.city ?? '').trim().toLowerCase() || '(none)'),
  active_interceptors: ics.length, overdue_interceptors: overdue.length, never_pumped_on_record: ics.filter((i) => !i.last_pump_date).length,
}, null, 2))
