// LIVE Client App (clients.unclogme.app), Clients list, 2026-11-12: every list read gets ALL its rows past the 1,000-row
// cap. The project answers at most 1,000 rows per request (PostgREST max_rows) and drops the rest with no error. The list
// read every completed visit in one `.limit(10000)` request, so at 1,648 rows 47 clients (43 Active) had no "Last visit".
// Audit: Supabase/docs/audits/2026-11-12_postgrest_row_cap_reads.md (row 1).
// Spec: Building Apps/Client App/docs/specs/2026-11-12-clients-list-reads-past-1000-rows.md
//
// At 1440 and 375, on the live site:
//   - every read the list makes, grouped by table and filters (paging dropped), returns as many rows as the database
//     counts for the same filters (a HEAD with Prefer: count=exact);
//   - the reported client (234-PV, last visit before the old cut) shows its last visit, from the database;
//   - a control client (004-BAO, last visit yesterday) still shows its own;
//   - the list's account count equals the database's; no page error; nothing written.
// Sign-in faked (a FAKE token); PostgREST GETs forwarded READ-ONLY with the service key (never printed); every write refused.
//   node scripts/client-app/tests/home_list_row_cap.mjs [outdir]
// Exit 0 = all pass. Run against the pre-fix bundle it must FAIL the completed-visits read and 234-PV (the control).
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => { const j = await (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: 'set transaction read only; ' + q }) })).json(); if (!Array.isArray(j)) throw new Error(JSON.stringify(j).slice(0, 300)); return j }
const H = 'https://clients.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co', KEY = env.SUPABASE_SERVICE_ROLE_KEY
const out = process.argv[2] || './home_list_shots'; fs.mkdirSync(out, { recursive: true })

// ---- expectations read from the database, never hard-coded ----
const [f] = await sql(`with done as (select client_id, visit_date from client.visits where visit_status = 'completed' and deleted_at is null)
select (select count(*) from done) as completed,
  (select json_build_object('code', c.client_code, 'last', max(d.visit_date)) from done d join public.clients c on c.id = d.client_id where c.client_code = '234-PV' group by c.client_code) as reported,
  (select json_build_object('code', c.client_code, 'last', max(d.visit_date)) from done d join public.clients c on c.id = d.client_id where c.client_code = '004-BAO' group by c.client_code) as control,
  (select visit_date from done order by visit_date desc offset 999 limit 1) as old_cut`)
if (!f.reported || !f.control) { console.log('FAIL fixture: 234-PV or 004-BAO has no completed visit'); process.exit(1) }
if (!(f.reported.last < f.old_cut)) console.log(`NOTE: 234-PV's last visit ${f.reported.last} is no longer older than the 1,000th completed visit (${f.old_cut}); its check no longer exercises the cut. Pick a client whose last visit is older.`)
if (Number(f.completed) <= 1000) console.log(`NOTE: only ${f.completed} completed visits, so the cap is not exercised by that read today.`)

// The list renders "Jun 04" (zero-padded day, no year); the other shapes are kept in case the column format changes.
const fmt = (d) => { const [y, m, dd] = d.split('-').map(Number); const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]; const d2 = String(dd).padStart(2, '0'); return [`${m}/${dd}/${y}`, `${mon} ${dd}, ${y}`, `${mon} ${d2}`, `${mon} ${dd}\t`, d] }
const shows = (text, d) => fmt(d).some((s) => text.includes(s))

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.${Buffer.from('fake-signature-not-real-32bytes-xx').toString('base64url')}`, refresh_token: 'fake', token_type: 'bearer', expires_in: 3600, expires_at: exp, user }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v) ?? v).slice(0, 400)}`) }

async function open(w, path) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { errors: [], writes: [], reads: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/realtime/**', (x) => x.abort())
  // emergency-session is the app's own session read (as in next_visit.mjs); any other function call counts as a write.
  await p.route(SB + '/functions/v1/**', (x) => { const path = new URL(x.request().url()).pathname; if (x.request().method() !== 'OPTIONS' && path !== '/functions/v1/emergency-session') st.writes.push('fn ' + path); return x.abort() })
  await p.route(SB + '/rest/v1/**', async (x) => {
    const r = x.request(), m = r.method(), u = new URL(r.url()), n = u.pathname.split('/').pop()
    if (m === 'OPTIONS') return x.fulfill({ status: 204 })
    if (m === 'POST' && n === 'get_my_access') return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: '#334155', photo_path: null }, apps: { client_app: { level: 'edit', mode: 'on' } }, can: {}, access: {} }) })
    if (m !== 'GET' && m !== 'HEAD') { st.writes.push(m + ' ' + n); return x.fulfill({ status: 404, contentType: 'application/json', body: '{"message":"stubbed"}' }) }
    const rh = r.headers(), h = { apikey: KEY }
    for (const k of ['accept', 'accept-profile', 'prefer', 'range']) if (rh[k]) h[k] = rh[k]
    try {
      const res = await fetch(r.url(), { method: m, headers: h })
      const text = await res.text()
      if (res.status === 401 || res.status === 403) return x.fulfill({ status: 200, contentType: 'application/json', body: '[]' }) // saved_views etc.: not part of this check
      let rows = -1; try { const j = JSON.parse(text); if (Array.isArray(j)) rows = j.length } catch {}
      st.reads.push({ url: u, profile: rh['accept-profile'] || 'public', status: res.status, rows })
      return x.fulfill({ status: res.status, contentType: res.headers.get('content-type') || 'application/json', headers: { 'content-range': res.headers.get('content-range') || '' }, body: text })
    } catch { return x.abort() }
  })
  await p.goto(H + path)
  return { ctx, p, st }
}

// The list's reads, grouped by table and filters with the paging dropped; each group must hold the exact total.
const LIST = ['client_services_flat', 'clients', 'properties', 'gdos', 'visits', 'jobs', 'line_items']
async function readsComplete(tag, st) {
  const groups = new Map()
  for (const r of st.reads) {
    const n = r.url.pathname.split('/').pop()
    if (!LIST.includes(n)) continue
    const q = new URLSearchParams(r.url.searchParams)
    for (const k of ['limit', 'offset', 'order', 'select']) q.delete(k)
    const key = `${r.profile}:${n}?${q.toString()}`
    const g = groups.get(key) || { n, profile: r.profile, q, rows: 0, pages: 0, statuses: [] }
    g.rows += Math.max(r.rows, 0); g.pages++; g.statuses.push(r.status); groups.set(key, g)
  }
  for (const n of LIST) ok([...groups.values()].some((g) => g.n === n), `${tag} the list read ${n}`)
  for (const g of groups.values()) {
    const res = await fetch(`${SB}/rest/v1/${g.n}?select=*&${g.q.toString()}`, { method: 'HEAD', headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'accept-profile': g.profile, Prefer: 'count=exact' } })
    const total = Number((res.headers.get('content-range') || '').split('/')[1])
    const filt = [...g.q.keys()].join(',') || 'no filter'
    ok(Number.isFinite(total) && g.rows === total, `${tag} ${g.n} (${filt}): ${g.rows} rows in ${g.pages} request(s), database counts ${total}`, { statuses: g.statuses })
    ok(g.statuses.every((s) => s === 200 || s === 206), `${tag} ${g.n} (${filt}): every request 200 or 206`, g.statuses)
  }
}

for (const w of [1440, 375]) {
  const tag = `[${w}]`
  for (const c of [{ ...f.reported, role: 'reported' }, { ...f.control, role: 'control' }]) {
    const { ctx, p, st } = await open(w, `/?q=${encodeURIComponent(c.code)}&hide=${encodeURIComponent('+lastVisit')}`)
    await p.waitForFunction((code) => document.body.innerText.includes(code), c.code, { timeout: 45000 }).catch(() => {})
    await p.waitForTimeout(4000)
    const t = await p.evaluate(() => document.body.innerText)
    const row = t.split('\n').slice(t.split('\n').findIndex((l) => l.includes(c.code))).slice(0, 30).join(' | ')
    ok(/Last visit/i.test(t), `${tag} ${c.code}: the Last visit column is shown`)
    ok(shows(row, c.last), `${tag} ${c.role} ${c.code}: Last visit shows ${c.last} (the database's)`, { row: row.slice(0, 300) })
    ok(st.errors.length === 0, `${tag} ${c.code}: no page errors`, st.errors)
    ok(st.writes.length === 0, `${tag} ${c.code}: nothing written`, st.writes)
    if (c.role === 'reported') {
      await readsComplete(tag, st)
      const m = t.match(/Showing \d+ of (\d+) accounts/)
      const [{ n }] = await sql(`select count(*)::int as n from client.client_services_flat f join client.clients c on c.id = f.id where coalesce(c.status, '') <> 'INACTIVE'`)
      ok(!!m && Number(m[1]) === n, `${tag} the list's account count equals the database's (${n} not INACTIVE)`, { shown: m?.[1] })
    }
    await p.screenshot({ path: `${out}/${w}_${c.code}.png`, fullPage: false })
    await ctx.close()
  }
}
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
