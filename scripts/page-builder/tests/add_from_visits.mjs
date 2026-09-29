// LIVE Page Builder /property/1164, the "Add from visits" panel (Fred, 2026-09-29, from a screenshot of the collapsed
// "Site survey · 5 photos" group: "make the site survey, to be expanded, by default is collapsed"). The Site survey
// group STARTS EXPANDED; every visit group starts collapsed; each toggle still opens and closes its group and says so
// with aria-expanded. Nothing else in the panel changes (Add into, the order, the counts). Real replies read in SQL as
// Fred's claims; 1164 has no visit photos, so the stub adds three FIXTURE visit photos (two dates) to the pool, never
// in Prod. Sign-in faked, every call stubbed, storage 400, nothing written. Prints titles and counts only.
//   node scripts/page-builder/tests/add_from_visits.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms) || !row.forms.length) { console.log('FAIL fixture: 1164 needs a live version and a submitted form :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it opens with the driver link code
const D = JSON.parse(JSON.stringify({ pb: row.pb, forms: row.forms }))
D.pb.property.source = JSON.parse(JSON.stringify(D.pb.live.source))  // keep the "Changed in the Client App's property data" notice away (as map_draft.mjs)
D.pb.pending = null
// fixture visit photos: two on 2026-09-10, one on 2026-08-20 (ids far above any real photo id; storage answers 400)
const V = (id, date) => ({ kind: 'visit', photo_id: id, visit_id: 990100 + (id % 10), visit_date: date, bucket: 'GT - Visits Images', path: `fixture/${id}.jpg`, label: null, caption: '[TEST] fixture', intake_id: null, question_key: null, content_type: 'image/jpeg', rotation_deg: 0 })
D.pb.pool = [...(D.pb.pool || []).filter((x) => x.kind !== 'visit'), V(990001, '2026-09-10'), V(990002, '2026-09-10'), V(990003, '2026-08-20')]
// the Site survey count the panel must show: pool photos from a form that are not already on the live version
const surveyIds = new Set(D.forms.flatMap((f) => (f.photos || []).map((x) => String(x.photo_id))))
const onPage = new Set((D.pb.live.content.photos || []).map((x) => String(x.photo_id)))
const SURVEY_N = D.pb.pool.filter((x) => x.kind !== 'visit' && surveyIds.has(String(x.photo_id)) && !onPage.has(String(x.photo_id))).length

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './add_from_visits_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [] }
  const replies = { get_page_builder: D.pb, get_page_builder_forms: D.forms, get_property_activity: [], get_page_versions: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n); if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }); return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent.trim() === 'Add from visits'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
// one read of the panel: each group's title, the count its toggle states, the photos actually shown, aria-expanded
const read = (p) => p.evaluate(() => {
  const h = [...document.querySelectorAll('h3')].find((x) => x.textContent.trim() === 'Add from visits')
  const panel = h && h.parentElement
  if (!panel) return null
  const sel = panel.querySelector('select')
  const toggles = [...panel.querySelectorAll('button')].filter((b) => /\d+ photos?/.test(b.textContent))
  const groups = toggles.map((t, i) => {
    let g = t  // the largest ancestor below the panel that holds this toggle and no other
    while (g.parentElement && g.parentElement !== panel && !toggles.some((o) => o !== t && g.parentElement.contains(o))) g = g.parentElement
    const shown = [...g.querySelectorAll('button')].filter((b) => b !== t && b.textContent.trim() === 'Add' && b.getClientRects().length > 0 && getComputedStyle(b).visibility !== 'hidden').length
    // the count from the element that holds ONLY it: the toggle's whole text glues the date to it ("Sep 10, 20262 photos")
    const cnt = [...t.querySelectorAll('*')].map((e) => e.textContent.trim()).find((x) => /^\d+ photos?\b/.test(x))
    return { i, title: (t.querySelector('span') || t).textContent.trim(), count: cnt ? Number(cnt.match(/^\d+/)[0]) : NaN, shown, expanded: t.getAttribute('aria-expanded') }
  })
  return { into: sel ? { value: sel.value, text: sel.options[sel.selectedIndex]?.textContent } : null, groups }
})
const click = async (p, i) => {
  const t = p.locator('xpath=//h3[normalize-space()="Add from visits"]/..//button').filter({ hasText: /\d+ photos?/ }).nth(i)
  await t.evaluate((e) => e.scrollIntoView({ block: 'center' }))
  await t.click({ timeout: 5000 })
  await p.waitForTimeout(400)
}

for (const w of [390, 1440]) {
  const { ctx, p, st } = await open(w)
  const a = await read(p)
  const G = (a && a.groups) || []
  const sv = G.filter((g) => g.title === 'Site survey'), vis = G.filter((g) => g.title !== 'Site survey')
  const S = sv[0]
  // the fixture and the panel as they were (must hold before and after the change)
  ok(SURVEY_N > 0 && sv.length === 1 && S.count === SURVEY_N, `${w}: ONE Site survey group, stating the ${SURVEY_N} form photos not on the page`, sv.map((g) => g.count))
  ok(vis.length === 2 && vis[0].count === 2 && vis[1].count === 1 && G[G.length - 1] === S, `${w}: the two fixture visit groups come first, newest date first (2 then 1 photos), Site survey last`, G.map((g) => [g.title, g.count]))
  ok(a && a.into && a.into.value === 'job' && a.into.text === 'Job pictures', `${w}: "Add into" still starts on Job pictures`, a && a.into)
  // THE CHANGE
  ok(!!S && S.shown === S.count, `${w}: the Site survey group starts EXPANDED (its photos are shown on load)`, S && { count: S.count, shown: S.shown })
  ok(!!S && S.expanded === 'true', `${w}: the Site survey toggle says aria-expanded="true" on load`, S && S.expanded)
  ok(vis.length > 0 && vis.every((g) => g.shown === 0), `${w}: every visit group starts collapsed (no photo shown)`, vis.map((g) => g.shown))
  ok(vis.length > 0 && vis.every((g) => g.expanded === 'false'), `${w}: every visit group toggle says aria-expanded="false" on load`, vis.map((g) => g.expanded))
  await p.locator('xpath=//h3[normalize-space()="Add from visits"]').evaluate((e) => e.parentElement.scrollIntoView({ block: 'start' }))
  await p.screenshot({ path: `${out}/afv_${w}_load.png` })
  // the toggle keeps working both ways, and aria-expanded follows what is shown
  if (S) {
    const s0 = S.shown > 0
    await click(p, S.i); const s1 = (await read(p)).groups[S.i]
    await click(p, S.i); const s2 = (await read(p)).groups[S.i]
    ok((s1.shown > 0) === !s0 && (s2.shown > 0) === s0 && (s0 ? s1.shown === 0 && s2.shown === S.count : s1.shown === S.count && s2.shown === 0), `${w}: clicking the Site survey toggle flips it, and a second click flips it back`, [S.shown, s1.shown, s2.shown])
    ok(s1.expanded === String(s1.shown > 0) && s2.expanded === String(s2.shown > 0), `${w}: the Site survey aria-expanded follows each click`, [s1.expanded, s2.expanded])
  }
  if (vis[0]) {
    await click(p, vis[0].i); const v1 = (await read(p)).groups[vis[0].i]
    await click(p, vis[0].i); const v2 = (await read(p)).groups[vis[0].i]
    ok(v1.shown === vis[0].count && v2.shown === 0, `${w}: a visit group still opens on a click and closes on the next`, [vis[0].shown, v1.shown, v2.shown])
    ok(v1.expanded === 'true' && v2.expanded === 'false', `${w}: the visit group aria-expanded follows each click`, [v1.expanded, v2.expanded])
  }
  if (w < 768) ok(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${w}: no sideways scroll`)
  const writes = [...new Set(st.calls)].filter((n) => !/^get_/.test(n))
  ok(writes.length === 0, `${w}: nothing but reads was called`, [...new Set(st.calls)])
  await ctx.close()
}
await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
