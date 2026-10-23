// LIVE Page Builder, property 1164: up to 9 grease trap pins and 3 truck pins (2026-10-23, Fred: "up to 3 trucks and 9 GT").
// Real data read in SQL as Fred's claims; the live version's map is emptied in the stub. Sign-in faked, every RPC stubbed,
// Submit RECORDED (nothing written). Clicks the real Google map (needs the planner key, like map_draft.mjs).
//   node scripts/page-builder/tests/map_pins.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = r[r.length - 1]
if (row.pb.live) { row.pb.property.source = JSON.parse(JSON.stringify(row.pb.live.source)); row.pb.live.content.site_map = { pins: {}, arrows: [] } }
if (row.pb.pending) row.pb.pending = null
const L = Number(row.pb.property.lat), G = Number(row.pb.property.lng)
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './map_pins_shots'; fs.mkdirSync(out, { recursive: true })
const submits = [], errors = []
async function open(w, forms) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 } })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  p.on('pageerror', (e) => errors.push(String(e)))
  const replies = { get_page_builder: JSON.stringify(row.pb), get_page_builder_forms: JSON.stringify(forms || row.forms), get_property_activity: '[]', get_my_access: '{"ok":true}' }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop()
    if (n === 'submit_property_page') { submits.push(JSON.parse(x.request().postData() || '{}')); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: 999999, version: (row.pb.newest_version || 0) + 1 }) }) }
    if (replies[n]) return x.fulfill({ status: 200, contentType: 'application/json', body: replies[n] })
    return x.fulfill({ status: 404, body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [a, c] of pairs) t = t.split(a).join(c); return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 })
  await p.waitForTimeout(3000)
  return { ctx, p }
}
const btn = (p, re) => p.locator('button', { hasText: re }).first()
const draftPins = async (p) => { await p.waitForTimeout(1500); return p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) { try { const j = JSON.parse(localStorage.getItem(k)); const sm = (j.content && j.content.site_map) || j.site_map; return (sm && sm.pins) || { __shape: { top: Object.keys(j), content: j.content && Object.keys(j.content), sm } } } catch { return null } } } return null }) }
const chips = (p) => p.evaluate(() => [...document.querySelectorAll('button')].map((b) => b.textContent.trim()).filter((t) => /^(GT|T)\d ×$/.test(t)))
const mapBox = (p) => p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => /Place GT Location/.test(x.textContent)); const w = b && b.closest('.space-y-2'); const g = w && w.querySelector('.gm-style'); if (!g) return null; g.scrollIntoView({ block: 'center' }); const r = g.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height } })
async function place(p, kind, n) {
  for (let i = 0; i < n; i++) {
    const b = btn(p, kind === 'gt' ? /Place GT Location|Add GT|GT Location/ : /Truck Parking|Place Truck|Add truck/)
    const mode = await p.evaluate((k) => { const b = [...document.querySelectorAll('button')].find((x) => (k === 'gt' ? /GT Location/ : /Truck Parking/).test(x.textContent)); return b ? { on: /bg-red-500|bg-orange|bg-\[#f/.test(b.className), dis: b.disabled } : null }, kind)
    if (mode && mode.dis) return
    if (mode && !mode.on) await b.click().catch(() => {})
    await p.waitForTimeout(250)
    const m = await mapBox(p)
    if (!m) return
    await p.mouse.click(m.x + 60 + ((i % 5) * (m.width - 120)) / 5, m.y + 50 + (Math.floor(i / 5) + (kind === 'gt' ? 0 : 2)) * 60)
    await p.waitForTimeout(500)
  }
}

{ // A. 9 GT and 3 truck pins, the limits, a remove that renumbers, then Submit
  const { ctx, p } = await open(1440)
  ok(!!(await mapBox(p)), 'A: the Google map is drawn')
  await place(p, 'gt', 10)
  let d = await draftPins(p)
  const gts = Object.keys(d || {}).filter((k) => k.startsWith('gt')).sort()
  ok(gts.join(',') === 'gt,gt2,gt3,gt4,gt5,gt6,gt7,gt8,gt9', 'A: ten clicks place exactly 9 GT pins, keys gt..gt9', Object.keys(d || {}))
  const body = await p.textContent('body')
  ok(/At most 9 grease trap pins\./.test(body), 'A: the limit sentence for GT shows')
  ok(await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => /GT Location/.test(x.textContent)); return !!(b && b.disabled) }), 'A: the GT place button is disabled at 9')
  await place(p, 'truck', 4)
  d = await draftPins(p)
  const trs = Object.keys(d || {}).filter((k) => k.startsWith('truck')).sort()
  ok(trs.join(',') === 'truck,truck2,truck3', 'A: four clicks place exactly 3 truck pins, keys truck..truck3', Object.keys(d || {}))
  ok(/At most 3 truck pins\./.test(await p.textContent('body')), 'A: the limit sentence for trucks shows')
  let c = await chips(p)
  ok(c.length === 12 && c.includes('GT1 ×') && c.includes('GT9 ×') && c.includes('T3 ×'), 'A: one chip per pin (GT1..GT9, T1..T3)', c)
  await p.screenshot({ path: `${out}/A_1440_12pins.png` }).catch(() => {})
  const before = JSON.parse(JSON.stringify(d))
  await btn(p, /^GT2 ×$/).click().catch(() => {}); await p.waitForTimeout(600)
  d = await draftPins(p)
  const gts2 = Object.keys(d || {}).filter((k) => k.startsWith('gt')).sort()
  ok(gts2.join(',') === 'gt,gt2,gt3,gt4,gt5,gt6,gt7,gt8' && d.gt2 && before.gt3 && d.gt2.lat === before.gt3.lat && d.gt8.lat === before.gt9.lat && !d.gt9, 'A: removing GT2 removes that pin only and renumbers the rest (old gt3 is now gt2)', { after: Object.keys(d), gt2: d.gt2, oldgt3: before.gt3 })
  c = await chips(p)
  ok(c.length === 11 && !c.includes('GT9 ×'), 'A: 11 chips left', c)
  ok(!/At most 9 grease trap pins\./.test(await p.textContent('body')), 'A: below the limit the GT sentence goes')
  await btn(p, /^Clear T$/).click().catch(() => {}); await p.waitForTimeout(500)
  d = await draftPins(p)
  ok(!Object.keys(d || {}).some((k) => k.startsWith('truck')) && Object.keys(d || {}).length === 8, 'A: Clear T removes every truck pin and keeps the GT pins', Object.keys(d || {}))
  await place(p, 'truck', 1)
  await p.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await p.waitForTimeout(400)
  await btn(p, /^Submit for approval$/).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(600)
  const go = p.locator('button', { hasText: /^(Submit|Submit anyway|Yes, submit)/ }).last()
  if (await go.isVisible().catch(() => false)) await go.click().catch(() => {})
  await p.waitForTimeout(1500)
  const s = submits[submits.length - 1], sm = s && s.p_content && s.p_content.site_map
  const keys = sm ? Object.keys(sm.pins).sort() : []
  ok(keys.join(',') === 'gt,gt2,gt3,gt4,gt5,gt6,gt7,gt8,truck', 'A: Submit sends gt..gt8 and truck', keys)
  ok(sm && Object.values(sm.pins).every((v) => Math.round(v.lat * 1e6) / 1e6 === v.lat && Math.round(v.lng * 1e6) / 1e6 === v.lng), 'A: every pin rounded to 6 decimals')
  ok(sm && Object.values(sm.pins).every((v) => Math.abs(v.lat - L) < 0.01 && Math.abs(v.lng - G) < 0.01), 'A: the pins are on this property (no far-pin case)')
  await ctx.close()
}

{ // B. "Use this form's pins" maps a form's trap 2 / trap 3 / truck pins (1024: the card's button, below the side by side)
  const forms = JSON.parse(JSON.stringify(row.forms))
  const f = (Array.isArray(forms) ? forms : forms.forms || [])[0]
  const P = (dy, dx) => ({ lat: L + dy, lng: G + dx, accuracy_m: 5 })
  let target = null
  if (f) {
    target = f.answers
    const put = (k, v) => { target[k] = v }
    put('site_map.gt_location', P(0.0001, 0)); put('grease_trap.t2.location', P(0.0002, 0.0001)); put('grease_trap.t3.location', P(0.0003, 0.0002)); put('site_map.truck_parking', P(-0.0002, -0.0001))
  }
  const { ctx, p } = await open(1024, forms)
  const use = btn(p, /^Use this form's pins/)
  ok(await use.isVisible().catch(() => false), "B: \"Use this form's pins\" is offered", f ? Object.keys(f) : forms)
  await use.click().catch(() => {}); await p.waitForTimeout(600)
  const conf = p.locator('button', { hasText: /^(Use pins|Replace|Yes)/ }).first()
  if (await conf.isVisible().catch(() => false)) await conf.click().catch(() => {})
  await p.waitForTimeout(1000)
  const d = await draftPins(p)
  ok(d && ['gt', 'gt2', 'gt3', 'truck'].every((k) => d[k]) && Object.keys(d).length === 4 && Math.abs(d.gt3.lat - (L + 0.0003)) < 1e-6, "B: the form's GT1/GT2/GT3 and truck pins land as gt, gt2, gt3, truck", d)
  await p.screenshot({ path: `${out}/B_1024_formpins.png` }).catch(() => {})
  await ctx.close()
}
ok(errors.filter((e) => !/Google Maps|ResizeObserver/.test(e)).length === 0, 'no page errors', errors.slice(0, 3))
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
