// LIVE Client App (clients.unclogme.app), Trello #177, 2026-11-06: a visit is upcoming only when it is scheduled with a
// date of today or later. A cancelled or skipped visit with a future date is never "Next visit", never under Future
// Visits, and shows under Previous Visits with its chip (Fred's pick). Checked at 1440 and 375 on: the reported record (186-PV,
// job #99900836), a client with a real next visit (control), a fixture on test client 112-YA served to the page only,
// and the Clients list request.
// Sign-in faked (a FAKE token); PostgREST GETs forwarded READ-ONLY with the service key (never printed); every other
// write refused. Nothing is written anywhere.
//   node scripts/client-app/tests/next_visit.mjs [outdir]
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (the control: checks must FAIL)
//   CLIENT_APP=http://localhost:8080/clients runs it on the portal's copy (scripts/client-app/base.mjs): signed in through the
//   portal's form, its STABLE reads (POST /rpc) answered read only. The portal's client page has no job card with Future and
//   Previous visits, so the same rule is checked where the portal shows it (portalChecks below). CHUNK_SUB edits production
//   chunks only.
import fs from 'node:fs'
import { createRequire } from 'node:module'
import { ARGS, ORIGIN, listUrl, PORTAL, COOKIE_SIGN_IN, PORTAL_ACCESS, formSignIn, answerRead, reads } from '../base.mjs'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => { const j = await (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json(); if (!Array.isArray(j)) throw new Error(JSON.stringify(j).slice(0, 300)); return j }
const H = ORIGIN, SB = 'https://wbasvhvvismukaqdnouk.supabase.co', KEY = env.SUPABASE_SERVICE_ROLE_KEY
const out = ARGS[0] || './next_visit_shots'; fs.mkdirSync(out, { recursive: true })

const TODAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York' }).format(new Date())
const plus = (n) => new Date(Date.parse(TODAY + 'T12:00:00Z') + n * 86400000).toISOString().slice(0, 10)
const shown = (d) => { const [y, m, dd] = d.split('-').map(Number); return `${m}/${dd}/${y}` }

// ---- expectations read from the database, never hard-coded ----
const [facts] = await sql(`select
  (select json_build_object('client', j.client_id, 'job', j.id, 'number', j.job_number, 'visit', v.id, 'date', v.visit_date,
     'upcoming', (select count(*) from public.visits u where u.job_id = j.id and u.deleted_at is null and u.visit_status = 'scheduled' and u.visit_date >= '${TODAY}'))
     from public.visits v join public.jobs j on j.id = v.job_id where v.id = 7318 and v.deleted_at is null and v.visit_status = 'cancelled') as reported,
  (select json_build_object('client', c.id, 'code', c.client_code, 'job', j.id, 'number', j.job_number, 'next', min(v.visit_date))
     from public.visits v join public.jobs j on j.id = v.job_id join public.clients c on c.id = v.client_id
    where v.deleted_at is null and v.visit_status = 'scheduled' and v.visit_date >= '${TODAY}' and c.client_code = '009-CN' and j.job_status not in ('archived', 'closed', 'destroyed')
    group by c.id, c.client_code, j.id, j.job_number order by min(v.visit_date) limit 1) as control,
  (select json_build_object('job', j.id, 'number', j.job_number, 'property', j.property_id) from public.jobs j where j.id = 2194) as fixture`)
if (!facts.reported) { console.log('FAIL fixture: visit 7318 must still be cancelled and live (the daily job or a person changed it: pick another)'); process.exit(1) }
if (facts.reported.upcoming !== 0 && Number(facts.reported.upcoming) !== 0) { console.log('FAIL fixture: job 1603 now has a real upcoming visit, the "—" expectation no longer holds'); process.exit(1) }
if (!facts.control) { console.log('FAIL fixture: control client 009-CN has no scheduled visit'); process.exit(1) }

const FIX = facts.fixture
// the portal's checks also need the control's next visit by id, and 112-YA's own soonest scheduled visit outside the fixture job
let controlVisit = null, fixtureRealNext = null
if (PORTAL) {
  const [x] = await sql(`select (select min(id) from public.visits where job_id = ${Number(facts.control.job)} and deleted_at is null and visit_status = 'scheduled' and visit_date = '${facts.control.next}') as cv,
    (select min(visit_date)::text from public.visits where client_id = 381 and deleted_at is null and visit_status = 'scheduled' and visit_date >= '${TODAY}' and job_id is distinct from ${Number(FIX.job)}) as rn`)
  controlVisit = x.cv; fixtureRealNext = x.rn
}
const base = { client_id: 381, property_id: FIX.property, job_id: FIX.job, source: 'visit-calendar', service_type: 'Labor', title: 'Fixture', deleted_at: null, completed_at: null, completed_by: null, invoice_id: null, jobber_url: null, public_id: null, derm_required: false, notes: null }
const ROWS = [
  { ...base, id: 990001, visit_status: 'cancelled', visit_date: plus(10) },
  { ...base, id: 990002, visit_status: 'skipped', visit_date: plus(5) },
  { ...base, id: 990003, visit_status: 'scheduled', visit_date: plus(20) },
  { ...base, id: 990004, visit_status: 'completed', visit_date: TODAY, completed_at: new Date().toISOString() },
  { ...base, id: 990005, visit_status: 'scheduled', visit_date: plus(-3) },
  { ...base, id: 990006, visit_status: 'scheduled', visit_date: plus(40) },
]

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.${Buffer.from('fake-signature-not-real-32bytes-xx').toString('base64url')}`, refresh_token: 'fake', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v) ?? v).slice(0, 500)}`) }
const subHits = new Set()

async function open(w, path, sc = {}) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { errors: [], writes: [], requests: [], statuses: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  if (process.env.CHUNK_SUB) {
    const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||'))
    await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.add(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) })
  }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/realtime/**', (x) => x.abort())
  await p.route(SB + '/functions/v1/**', async (x) => { const r = x.request(); if (r.method() === 'OPTIONS') return x.fulfill({ status: 200, headers: { 'access-control-allow-methods': 'POST, OPTIONS' }, body: 'ok' }); const path = new URL(r.url()).pathname; let b = null; try { b = r.postDataJSON() } catch {} if (!(path === '/functions/v1/emergency-session' || (path === '/functions/v1/save-client-contact' && b?.action === 'refresh'))) st.writes.push('fn ' + path); return x.abort() })
  await p.route(SB + '/rest/v1/**', async (x) => {
    const r = x.request(), m = r.method(), u = new URL(r.url()), n = u.pathname.split('/').pop()
    if (m === 'OPTIONS') return x.fulfill({ status: 204 })
    if (m === 'GET' || m === 'HEAD') {
      st.requests.push(n + '?' + u.searchParams.toString())
      const rh = r.headers(), h = { apikey: KEY }
      for (const k of ['accept', 'accept-profile', 'content-profile', 'prefer', 'range']) if (rh[k]) h[k] = rh[k]
      try {
        const res = await fetch(r.url(), { method: m, headers: h })
        st.statuses.push(res.status)
        if (res.status === 401 || res.status === 403) return x.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
        const text = await res.text()
        if (sc.fixture && m === 'GET' && n === 'visits' && u.searchParams.get('client_id') === 'eq.381') {
          const rows = JSON.parse(text).filter((v) => v.job_id !== FIX.job)
          return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([...rows, ...ROWS]) })
        }
        return x.fulfill({ status: res.status, contentType: res.headers.get('content-type') || 'application/json', headers: { 'content-range': res.headers.get('content-range') || '' }, body: text })
      } catch { return x.abort() }
    }
    if (m === 'POST' && n === 'get_my_access') return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(PORTAL ? PORTAL_ACCESS : { employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: '#334155', photo_path: null }, apps: { client_app: { level: 'edit', mode: 'on' } }, can: {}, access: {} }) })
    if (PORTAL && await answerRead(x)) return
    if (m === 'POST') {
      const res = await fetch(r.url(), { method: 'POST', headers: { apikey: KEY, 'content-type': 'application/json' }, body: '{}' }).catch(() => null)
      void res
    }
    st.writes.push(m + ' ' + n)
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{"message":"stubbed"}' })
  })
  if (!COOKIE_SIGN_IN) await formSignIn(p, session, user)
  await p.goto(path === '/' ? listUrl() : ORIGIN + path)
  return { ctx, p, st, phone }
}

// ---- the portal's client page (seven tabs): the same rule, where the portal shows it ----
// A job's next visit and its "N coming up" are its row on the Jobs tab ([data-job], the archived jobs have neither); every
// visit is on the Visits tab, where ?visit=<id> opens the segment of its kind ("Coming up", "Done", or "All" for any other)
// with the visit's row ([data-visit]), whose state icon reads Cancelled, Skipped or Not done; the header's Next visit is the
// client's soonest coming visit. Dates as the portal writes them (lib/visit-list.ts dayText and shortDay).
const onDay = (d, o) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { timeZone: 'UTC', ...o })
const day = (d) => onDay(d, { month: 'short', day: 'numeric', year: 'numeric' })
const short = (d) => onDay(d, { weekday: 'short', month: 'short', day: 'numeric', ...(d.slice(0, 4) === TODAY.slice(0, 4) ? {} : { year: 'numeric' }) })
async function jobRow(w, client, number) {
  const { ctx, p, st } = await open(w, `/clients/${client}?tab=jobs`)
  const row = p.locator(`[data-job="${number}"]`).first()
  await row.waitFor({ timeout: 30000 }); await p.waitForTimeout(1500)
  const cells = await row.locator('[role=cell]').allInnerTexts()
  await ctx.close()
  return { next: (cells[4] || '').replace(/^\s*Next visit\s*/, '').trim(), coming: Number(((cells[5] || '').match(/(\d+) coming up/) || [])[1] ?? NaN), st }
}
async function visitAt(w, client, id, sc) {
  const { ctx, p, st } = await open(w, `/clients/${client}?tab=visits&visit=${id}`, sc)
  await p.locator(`[data-visit="${id}"]`).first().waitFor({ timeout: 30000 }).catch(() => {}); await p.waitForTimeout(1000)
  const r = await p.evaluate((vid) => {
    const row = document.querySelector(`[data-visit="${vid}"]`)
    const seg = [...document.querySelectorAll('[role=tab][aria-selected=true]')].map((t) => t.innerText.trim()).find((t) => /^(All|Coming up|Done)\b/.test(t)) || null
    const head = [...document.querySelectorAll('*')].find((e) => e.children.length < 6 && /^Next visit\b/.test(e.innerText || '') && (e.innerText || '').length < 60)
    return { found: !!row, seg: seg && seg.replace(/\s*\d+$/, ''), state: row ? [...row.querySelectorAll('[aria-label]')].map((e) => e.getAttribute('aria-label')).join(' | ') : null, header: head ? head.innerText.replace(/\s+/g, ' ') : null, body: document.body.innerText }
  }, id)
  await p.screenshot({ path: `${out}/${w}_portal_visit_${id}.png`, fullPage: false })
  await ctx.close()
  return { ...r, st }
}
async function portalChecks(w, tag) {
  // 186-PV: its job has no next visit, and the cancelled visit is not a coming one
  const j = await jobRow(w, facts.reported.client, facts.reported.number)
  ok(j.next === 'None planned' && j.coming === 0, `${tag} 186-PV #${facts.reported.number}: Jobs tab Next visit reads "None planned", 0 coming up`, j)
  const v = await visitAt(w, facts.reported.client, 7318)
  ok(v.found && v.seg === 'All' && /Cancelled/.test(v.state || ''), `${tag} 186-PV: visit 7318 is not under Coming up, and carries its Cancelled state`, { seg: v.seg, state: v.state })
  ok(![day(facts.reported.date), short(facts.reported.date)].some((s) => new RegExp('Next visit\\s*' + s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(v.body)), `${tag} 186-PV: no "Next visit ${day(facts.reported.date)}" anywhere on the page, the header included`, v.header)
  ok(j.st.errors.length === 0 && v.st.errors.length === 0, `${tag} 186-PV: no page errors`, [...j.st.errors, ...v.st.errors])
  ok(j.st.writes.length === 0 && v.st.writes.length === 0, `${tag} 186-PV: nothing written`, [...j.st.writes, ...v.st.writes])
  // control: a client with a real next visit keeps it
  const c = await jobRow(w, facts.control.client, facts.control.number)
  ok(c.next === day(facts.control.next), `${tag} control ${facts.control.code} #${facts.control.number}: Jobs tab Next visit stays ${day(facts.control.next)}`, c)
  const cv = await visitAt(w, facts.control.client, controlVisit)
  ok(cv.found && cv.seg === 'Coming up', `${tag} control: its next visit is under Coming up`, { seg: cv.seg })
  ok(c.st.errors.length === 0 && cv.st.errors.length === 0, `${tag} control: no page errors`, [...c.st.errors, ...cv.st.errors])
  // the fixture on 112-YA, served to this page only: every status against the rule
  const want = { 990003: ['Coming up', null], 990006: ['Coming up', null], 990004: ['Done', null], 990001: ['All', 'Cancelled'], 990002: ['All', 'Skipped'], 990005: ['All', 'Not done'] }
  let header = null
  for (const [id, [seg, state]] of Object.entries(want)) {
    const f = await visitAt(w, 381, id, { fixture: true })
    header ??= f.header
    ok(f.found && f.seg === seg && (!state || (f.state || '').includes(state)), `${tag} fixture: visit ${id} (${ROWS.find((r) => r.id === Number(id)).visit_status}, ${ROWS.find((r) => r.id === Number(id)).visit_date}) is under ${seg}${state ? ' with ' + state : ''}`, { seg: f.seg, state: f.state })
    ok(f.st.errors.length === 0 && f.st.writes.length === 0, `${tag} fixture ${id}: no page errors, nothing written`, { errors: f.st.errors, writes: f.st.writes })
  }
  const soonest = [plus(20), fixtureRealNext].filter(Boolean).sort()[0]
  ok(header === `Next visit ${short(soonest)}` || (header || '').startsWith(`Next visit ${short(soonest)}`), `${tag} fixture: the header's Next visit is the soonest scheduled one (${short(soonest)}), not the cancelled +10 or skipped +5`, { header })
}

// The smallest element holding the job number AND both visit headings: that one job's card.
async function card(p, number) {
  const find = () => p.evaluate((num) => {
    const hits = [...document.querySelectorAll('div,section,article,li')].filter((e) => e.innerText?.includes('#' + num) && /FUTURE VISITS/i.test(e.innerText) && /PREVIOUS VISITS/i.test(e.innerText))
    hits.sort((a, b) => a.innerText.length - b.innerText.length)
    return hits[0]?.innerText ?? null
  }, number)
  await p.waitForFunction((num) => document.body.innerText.includes('#' + num), number, { timeout: 30000 })
  await p.waitForTimeout(1500)
  return find()
}

const lines = (t) => (t || '').split('\n').map((s) => s.trim()).filter(Boolean)
const section = (t, from, to) => { const l = lines(t), i = l.findIndex((x) => x.toUpperCase().startsWith(from)); if (i < 0) return null; const j = to ? l.findIndex((x, k) => k > i && x.toUpperCase().startsWith(to)) : -1; return l.slice(i + 1, j < 0 ? undefined : j).join(' | ') }
const nextOf = (t) => { const l = lines(t), i = l.findIndex((x) => x === 'Next visit'); return i < 0 ? null : l[i + 1] }
const expandAll = async (p, number) => {
  const row = p.getByText('#' + number, { exact: false }).first()
  await row.waitFor({ timeout: 30000 })
  await row.scrollIntoViewIfNeeded().catch(() => {})
  return card(p, number)
}

for (const w of [1440, 375]) {
  const tag = `[${w}]`
  if (PORTAL) await portalChecks(w, tag)
  else {   // the old app's job cards
  // ---- the reported record: 186-PV, its one job with no real upcoming visit ----
  {
    const { ctx, p, st } = await open(w, `/clients/${facts.reported.client}`)
    const t = await expandAll(p, facts.reported.number)
    ok(nextOf(t) === '—', `${tag} 186-PV #${facts.reported.number}: Next visit reads "—"`, { next: nextOf(t) })
    const fut = section(t, 'FUTURE VISITS', 'PREVIOUS VISITS'), past = section(t, 'PREVIOUS VISITS')
    ok(fut !== null && !fut.includes(shown(facts.reported.date)) && !/cancelled/i.test(fut), `${tag} 186-PV: not under Future visits`, { fut })
    ok(past !== null && past.includes(shown(facts.reported.date)) && /cancelled/i.test(past), `${tag} 186-PV: under Previous Visits with its chip`, { past })
    const body = await p.evaluate(() => document.body.innerText)
    ok(!new RegExp('Next visit\\s*' + shown(facts.reported.date).replace(/\//g, '\\/')).test(body), `${tag} 186-PV: no "Next visit ${shown(facts.reported.date)}" anywhere on the page, the property chip included`)
    ok(st.errors.length === 0, `${tag} 186-PV: no page errors`, st.errors)
    ok(st.writes.length === 0, `${tag} 186-PV: nothing written`, st.writes)
    await p.screenshot({ path: `${out}/${w}_186-PV.png`, fullPage: false })
    await ctx.close()
  }
  // ---- control: a client with a real next visit keeps it ----
  {
    const { ctx, p, st } = await open(w, `/clients/${facts.control.client}`)
    const t = await expandAll(p, facts.control.number)
    ok(nextOf(t) === shown(facts.control.next), `${tag} control ${facts.control.code} #${facts.control.number}: Next visit stays ${shown(facts.control.next)}`, { next: nextOf(t) })
    const fut = section(t, 'FUTURE VISITS', 'PREVIOUS VISITS')
    ok(fut !== null && fut.includes(shown(facts.control.next)), `${tag} control: its next visit is under Future visits`, { fut })
    ok(st.errors.length === 0, `${tag} control: no page errors`, st.errors)
    await ctx.close()
  }
  // ---- fixture on 112-YA, served to this page only: every status against the rule ----
  {
    const { ctx, p, st } = await open(w, '/clients/381', { fixture: true })
    const t = await expandAll(p, FIX.number)
    ok(nextOf(t) === shown(plus(20)), `${tag} fixture: Next visit is the soonest scheduled one (${shown(plus(20))}), not the cancelled +10 or skipped +5`, { next: nextOf(t) })
    const fut = section(t, 'FUTURE VISITS', 'PREVIOUS VISITS'), past = section(t, 'PREVIOUS VISITS')
    ok(fut !== null && fut.includes(shown(plus(20))) && fut.includes(shown(plus(40))), `${tag} fixture: both scheduled future visits are under Future visits`, { fut })
    ok(fut !== null && !fut.includes(shown(plus(10))) && !fut.includes(shown(plus(5))) && !/cancelled|skipped/i.test(fut), `${tag} fixture: cancelled and skipped are not under Future visits`, { fut })
    ok(past !== null && past.includes(shown(plus(10))) && /cancelled/i.test(past), `${tag} fixture: the cancelled one is under Previous Visits with its chip`, { past })
    ok(past !== null && past.includes(shown(plus(5))) && /skipped/i.test(past), `${tag} fixture: the skipped one is under Previous Visits with its chip`, { past })
    ok(past !== null && past.includes(shown(TODAY)) && past.includes(shown(plus(-3))), `${tag} fixture: completed today and a late scheduled visit stay under Previous Visits, as before`, { past })
    await p.screenshot({ path: `${out}/${w}_112-YA_fixture.png`, fullPage: false })
    await ctx.close()
  }
  }   // the old app's job cards
  // ---- the Clients list asks for scheduled visits only ----
  {
    const { ctx, p, st } = await open(w, '/')
    await p.waitForFunction(() => /Next visit/i.test(document.body.innerText), null, { timeout: 30000 }).catch(() => {})
    await p.waitForTimeout(2500)
    const req = st.requests.filter((r) => r.startsWith('visits?') && r.includes('visit_status') && r.includes('gte'))
    ok(req.length >= 1 && req.every((r) => r.includes('visit_status=eq.scheduled')), `${tag} Clients list: its next visit request is visit_status=eq.scheduled`, req)
    ok(st.errors.length === 0, `${tag} Clients list: no page errors`, st.errors)
    await ctx.close()
  }
}
await browser.close()
if (process.env.CHUNK_SUB) console.log('chunk edits applied: ' + [...subHits].join(' ; '))
if (PORTAL) console.log('portal reads answered read only: ' + ([...new Set(reads)].join(', ') || 'none'))
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
