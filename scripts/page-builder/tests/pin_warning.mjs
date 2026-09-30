// LIVE Page Builder /property/1164: the "more than about 5 km" pin check is a WARNING, not a refusal (Fred, 2026-09-29, on
// /property/162: "at most it should be a warning that we can continue"; his pick: the same sentence under the map AND in the
// Submit confirm row, whose orange button then reads "Submit anyway"). Real replies read as Fred's claims, then edited per
// scenario; a browser draft is planted to hold far pins (the state Fred was in on 162: intake 742's pins, about 9.2 km off).
// Sign-in faked, every RPC stubbed (submit_property_page answered by the stub), Google Maps ABORTED (the warning needs no map;
// the map fit is checked by map_draft.mjs and restore_version.mjs). Nothing is written. Codes are never printed.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-29-pin-warning-map-fit-design.md
//   node scripts/page-builder/tests/pin_warning.mjs <outdir>
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
if (!row || !row.pb || !row.pb.live) { console.log('FAIL fixture: no 1164 reply with a live version :: ' + ((r && r.message) || '')); process.exit(1) }  // never the raw reply: it holds the link code
row.pb.property.source = JSON.parse(JSON.stringify(row.pb.live.source))  // no "Changed in the Client App's property data" notice: Submit must not wait for it
const clone = (x) => JSON.parse(JSON.stringify(x))
const L = Number(row.pb.property.lat), G = Number(row.pb.property.lng)
if (!Number.isFinite(L) || !Number.isFinite(G)) { console.log('FAIL fixture: 1164 has no lat/lng'); process.exit(1) }
const rnd = (x) => Math.round(x * 1e6) / 1e6
// the spec's distance: haversine on a 6371 km sphere, shown rounded to 0.1 km; a pin counts when it is MORE than 5 km away
const km = (a, b) => { const R = 6371, rad = Math.PI / 180, dl = (b.lat - a.lat) * rad, dg = (b.lng - a.lng) * rad; const h = Math.sin(dl / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dg / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)) }
const HOME = { lat: L, lng: G }
// 162's geometry, moved onto 1164: intake 742's pins sat -0.0565 / -0.0677 degrees from 162's point (9.2 km)
const FAR_GT = { lat: rnd(L - 0.056468), lng: rnd(G - 0.067718) }, FAR_T = { lat: rnd(L - 0.056464), lng: rnd(G - 0.067539) }
const NEAR_T = { lat: rnd(L + 0.0002), lng: rnd(G - 0.0001) }
const ARROW = { points: [{ lat: rnd(L + 0.00025), lng: rnd(G - 0.00025) }, { lat: rnd(L + 0.0001), lng: rnd(G - 0.0002) }] }
const TAIL = " from this property's address. Check the map is on the right property."
const SENT = (pins) => { const far = pins.filter(([, p]) => p && km(HOME, p) > 5); if (!far.length) return null; const d = Math.max(...far.map(([, p]) => km(HOME, p))).toFixed(1); return far.length === 2 ? `The GT Location and Truck Parking pins are about ${d} km${TAIL}` : `The ${far[0][0]} pin is about ${d} km${TAIL}` }
const WANT_BOTH = SENT([['GT Location', FAR_GT], ['Truck Parking', FAR_T]]), WANT_T = SENT([['Truck Parking', FAR_T]]), WANT_GT = SENT([['GT Location', FAR_GT]])
if (!WANT_BOTH || !WANT_T || !WANT_GT || km(HOME, NEAR_T) > 1 || km(HOME, { lat: L - 0.0001, lng: G + 0.0001 }) > 1) { console.log('FAIL fixture: the far pins are not far'); process.exit(1) }
console.log(`fixture: 1164 live v${row.pb.live.version}; far GT ${km(HOME, FAR_GT).toFixed(3)} km, far T ${km(HOME, FAR_T).toFixed(3)} km, near T ${(km(HOME, NEAR_T) * 1000).toFixed(0)} m`)

const base = () => { const d = { pb: clone(row.pb), forms: clone(row.forms) }; d.pb.pending = null; d.pb.live.content.site_map = { pins: { truck: NEAR_T }, arrows: [ARROW] }; return d }
const draftOf = (d, map) => ({ base_version: d.pb.newest_version, source: d.pb.property.source, saved_at: new Date().toISOString(), content: { ...clone(d.pb.live.content), site_map: map } })
const NEAR_GT = { lat: rnd(L - 0.0001), lng: rnd(G + 0.0001) }
const NEAR = base(); NEAR.draft = draftOf(NEAR, { pins: { gt: NEAR_GT, truck: NEAR_T }, arrows: [ARROW] })  // a draft with near pins only: no warning (a draft, so Submit is enabled)
const FAR = base(); FAR.draft = draftOf(FAR, { pins: { gt: FAR_GT, truck: FAR_T }, arrows: [] })
const ONE = base(); ONE.draft = draftOf(ONE, { pins: { gt: FAR_GT, truck: NEAR_T }, arrows: [] })
const NOLL = base(); NOLL.pb.property.lat = null; NOLL.pb.property.lng = null; NOLL.draft = draftOf(NOLL, { pins: { gt: FAR_GT, truck: FAR_T }, arrows: [] })

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const DKEY = `pp-draft:${user.id}:1164`
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './pin_warning_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, data) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript(([u, k, d]) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })); if (d && !localStorage.getItem(k)) localStorage.setItem(k, JSON.stringify(d)) } catch {} }, [user, DKEY, data.draft || null])
  const p = await ctx.newPage()
  const st = { calls: [], submits: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })  // Maps is aborted on purpose
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [], get_page_versions: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    if (n === 'submit_property_page') { let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {} st.submits.push(b); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: 999999, version: (data.pb.newest_version || 0) + 1 }) }) }
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
const t = (s) => (s == null ? null : s.replace(/\s+/g, ' ').trim())
const NOTICE = ['rounded-2xl', 'border', 'border-dp-orange/40', 'bg-dp-orange/10', 'px-4', 'py-3', 'text-sm', 'text-dp-ink']
// the warning under the map and its neighbours; the confirm row once "Submit for approval" was pressed
const state = (p) => p.evaluate(() => {
  const t = (s) => (s == null ? null : s.replace(/\s+/g, ' ').trim())
  const u = document.querySelector('[data-pin-warning]')
  const map = [...document.querySelectorAll('button')].find((b) => /GT Location/.test(b.textContent))
  const pinner = map && map.closest('.space-y-2')
  const prev = u && u.previousElementSibling, next = u && u.nextElementSibling
  const q = [...document.querySelectorAll('p')].find((x) => /^Submit version \d+ for approval\?/.test(t(x.textContent) || ''))
  const cw = document.querySelector('[data-pin-warning-confirm]')
  const row = q && q.parentElement
  const btns = row ? [...row.querySelectorAll('button')].map((b) => ({ t: t(b.textContent), h: Math.round(b.getBoundingClientRect().height) })) : []
  const R = (e) => { const b = e.getBoundingClientRect(); return { x: Math.round(b.x), w: Math.round(b.width), r: Math.round(b.right), y: Math.round(b.y) } }
  return { under: u ? { text: t(u.textContent), role: u.getAttribute('role'), cls: u.className, afterMap: !!(prev && pinner && (prev === pinner || prev.contains(pinner))), beforeNote: !!(next && /^Pins and arrows are part of this draft\./.test(t(next.textContent) || '')), rect: R(u) } : null,
    confirmQ: q ? t(q.textContent) : null, confirmWarn: cw ? { text: t(cw.textContent), inRow: !!(row && row.contains(cw)), beforeQ: !!(q && (cw.compareDocumentPosition(q) & Node.DOCUMENT_POSITION_FOLLOWING)) } : null, btns,
    sideways: document.documentElement.scrollWidth > innerWidth, vw: innerWidth }
})
const btn = (p, re) => p.locator('button', { hasText: re }).first()
const openConfirm = async (p) => { await p.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await btn(p, /^Submit for approval$/).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(600) }
const lastSubmitMap = (st) => { const s = st.submits[st.submits.length - 1]; return s && s.p_content && s.p_content.site_map }
const samePin = (a, b) => !!a && !!b && Math.abs(a.lat - b.lat) < 1e-6 && Math.abs(a.lng - b.lng) < 1e-6

for (const w of [1440, 390]) {
  { // both pins far: the sentence under the map and in the confirm row; Submit anyway goes through
    const { ctx, p, st } = await open(w, FAR)
    let S = await state(p)
    ok(!!S.under && S.under.text === WANT_BOTH, `${w}: under the map, "${WANT_BOTH}"`, S.under && S.under.text)
    ok(!!S.under && S.under.afterMap && S.under.beforeNote, `${w}: the warning sits right under the map, above "Pins and arrows are part of this draft."`, S.under && { afterMap: S.under.afterMap, beforeNote: S.under.beforeNote })
    ok(!!S.under && NOTICE.every((c) => S.under.cls.split(/\s+/).includes(c)) && S.under.role === 'status', `${w}: it wears the property data notice's classes and is role=status`, S.under && { cls: S.under.cls, role: S.under.role })
    ok(!!S.under && S.under.rect.x >= 0 && S.under.rect.r <= S.vw && !S.sideways, `${w}: it fits the width, no sideways scroll`, S.under && { rect: S.under.rect, vw: S.vw, sideways: S.sideways })
    await p.screenshot({ path: `${out}/far_${w}_under.png`, fullPage: false }).catch(() => {})
    await openConfirm(p)
    S = await state(p)
    ok(!!S.confirmWarn && S.confirmWarn.text === WANT_BOTH && S.confirmWarn.inRow && S.confirmWarn.beforeQ, `${w}: the confirm row shows the same sentence above "Submit version N for approval?"`, { warn: S.confirmWarn, q: S.confirmQ })
    ok(S.btns.map((b) => b.t).join() === 'Keep editing,Submit anyway', `${w}: the confirm row's buttons read Keep editing and Submit anyway`, S.btns)
    if (w < 768) ok(S.btns.length === 2 && S.btns.every((b) => b.h >= 44), `${w}: both confirm buttons are 44px or taller on a phone`, S.btns)
    await p.screenshot({ path: `${out}/far_${w}_confirm.png`, fullPage: false }).catch(() => {})
    await btn(p, /^Submit anyway$/).click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(1500)
    const m = lastSubmitMap(st)
    ok(st.submits.length === 1 && !!m && samePin(m.pins && m.pins.gt, FAR_GT) && samePin(m.pins && m.pins.truck, FAR_T), `${w}: Submit anyway sends the version with the far pins (the page does not block it)`, { submits: st.submits.length, map: m })
    ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
    await ctx.close()
  }
  { // the warning follows the pins: Clear G leaves the truck pin named alone; Clear T removes it, and Submit is plain again
    const { ctx, p } = await open(w, FAR)
    await btn(p, /^Clear G$/).click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(500)
    let S = await state(p)
    ok(!!S.under && S.under.text === WANT_T, `${w}: after Clear G, "${WANT_T}"`, S.under && S.under.text)
    await btn(p, /^Clear T$/).click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(500)
    S = await state(p)
    ok(!S.under, `${w}: after Clear T, no warning under the map`, S.under)
    await openConfirm(p)
    S = await state(p)
    ok(!S.confirmWarn && S.btns.map((b) => b.t).join() === 'Keep editing,Submit' && !!S.confirmQ, `${w}: with no far pin the confirm row is today's (Keep editing, Submit, no sentence)`, { warn: S.confirmWarn, btns: S.btns })
    await ctx.close()
  }
}
{ // one far pin: named alone
  const { ctx, p } = await open(1440, ONE)
  const S = await state(p)
  ok(!!S.under && S.under.text === WANT_GT, `1440: only the GT pin far, "${WANT_GT}"`, S.under && S.under.text)
  await ctx.close()
}
{ // guard: the live version's own pins (near), no draft: nothing
  const { ctx, p } = await open(1440, NEAR)
  await openConfirm(p)
  const S = await state(p)
  ok(!S.under && !S.confirmWarn && S.btns.map((b) => b.t).join() === 'Keep editing,Submit', '1440: guard, near pins show no warning and the plain Submit', { under: S.under, warn: S.confirmWarn, btns: S.btns })
  await ctx.close()
}
{ // guard: a property with no lat/lng is never warned about, whatever the pins
  const { ctx, p } = await open(1440, NOLL)
  await openConfirm(p)
  const S = await state(p)
  ok(!S.under && !S.confirmWarn && S.btns.map((b) => b.t).join() === 'Keep editing,Submit', '1440: guard, no lat/lng on the property: no warning, the plain Submit', { under: S.under, warn: S.confirmWarn, btns: S.btns })
  await ctx.close()
}
await browser.close()
if (process.env.CHUNK_SUB) console.log(`CHUNK_SUB edits applied: ${new Set(subHits).size} of ${process.env.CHUNK_SUB.split('@@@').length}`)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
