// LIVE Page Builder /property/1164: the two new photo sections, "Lift station" and "Water tank" (form v3, Fred's pick B2,
// 2026-09-30: "how that would be for the building phase too"). A form photo of a lift_station.* question lands in Lift
// station and a water_tank.* one in Water tank, never in Grease trap; a section shows only when the page's count is above
// 0 or it holds a photo (and hides again once neither is true); the saved content, the Site file and the "On the form"
// panel follow; the loader takes a version holding such photos and an old browser draft with only three sections; the
// map's GT pin (also called greaseTrap in the code) is untouched. Real 1164 replies read as Fred's claims, then edited: four off-page photos
// of form 686 are relabelled as the four new slots (never in Prod) and form 686 answers one lift station and one water
// tank. Sign-in faked, every call stubbed (submit_property_page answered by the stub, nothing written), every photo signed
// to a 1x1 fixture image, Maps aborted.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-30-form-v3-photo-slots-design.md, section B2
//   node scripts/page-builder/tests/lift_water_sections.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@...' serves the live chunks with those edits (a control: named checks must FAIL)
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
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.forms)) { console.log('FAIL fixture: 1164 needs a live version :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it holds the link code
const clone = (x) => JSON.parse(JSON.stringify(x))
const BASE = clone({ pb: row.pb, forms: row.forms })
BASE.pb.property.source = clone(BASE.pb.live.source)   // no "Changed in the Client App's property data" notice
BASE.pb.pending = null
for (const x of [...(BASE.pb.pool || []), ...(BASE.pb.referenced || [])]) if (x.kind === 'intake') x.caption = null
// form 686: four photos NOT on the live version become the four new slots (in the replies only)
const F686 = BASE.forms.find((f) => Number(f.intake_id) === 686)
if (!F686) { console.log('FAIL fixture: form 686 of 1164 is gone'); process.exit(1) }
const onLive = new Set((BASE.pb.live.content.photos || []).map((ph) => String(ph.photo_id)))
const RELABEL = { 'access_entry.access_photos': ['lift_station.access_photos', 'Lift station access'], 'access_entry.gate_photos': ['lift_station.photos', 'Lift station'],
  'access_entry.lock_box_photos': ['water_tank.capacity_photos', 'Water tank capacity'], 'grease_trap.capacity_photos': ['water_tank.photos', 'Water tank'] }
const moved = {}
for (const ph of F686.photos) { const to = RELABEL[ph.question_key]; if (to && !onLive.has(String(ph.photo_id)) && !Object.values(moved).includes(to[0])) { moved[String(ph.photo_id)] = to[0]; ph.question_key = to[0] } }
if (Object.keys(moved).length !== 4) { console.log('FAIL fixture: form 686 needs its four off-page photos (access, gate, lock box, capacity)', moved); process.exit(1) }
for (const x of [...(BASE.pb.pool || []), ...(BASE.pb.referenced || [])]) if (moved[String(x.photo_id)]) { x.question_key = moved[String(x.photo_id)]; x.label = Object.values(RELABEL).find((v) => v[0] === x.question_key)[1] }
F686.answers = { ...F686.answers, 'lift_station.count': 1, 'water_tank.count': 1 }
BASE.forms = [F686, ...BASE.forms.filter((f) => f !== F686)]   // the builder starts on the first form
const facts0 = BASE.pb.live.content.facts || {}
if (Number(facts0.lift_stations) > 0 || Number(facts0.water_tanks) > 0) { console.log('FAIL fixture: 1164 live version already counts lift stations or water tanks', facts0); process.exit(1) }
const S = clone(BASE); S.pb.live.content.facts = { ...S.pb.live.content.facts, lift_stations: null, water_tanks: null }   // S: the counts empty on the page
const C = clone(BASE); C.pb.live.content.facts = { ...C.pb.live.content.facts, lift_stations: 1 }        // C: one count on the page
const C2 = clone(BASE); C2.pb.live.content.facts = { ...C2.pb.live.content.facts, lift_stations: 1, water_tanks: 1 }   // C2: both
const LV = clone(BASE); const LV_I = LV.pb.live.content.photos.findIndex((ph) => ph.section === 'access')
if (LV_I < 0) { console.log('FAIL fixture: the live version of 1164 has no access photo'); process.exit(1) }
LV.pb.live.content.photos[LV_I].section = 'lift_station'                                                // LV: a saved version holding one
const ACC_LIVE = BASE.pb.live.content.photos.filter((ph) => ph.section === 'access').length
const SEC = ['Access photos', 'Grease trap', 'Lift station', 'Water tank', 'Job pictures & description']   // the builder's titles
const SEC3 = 'Access photos|Grease trap|Job pictures & description'
const INTO = ['Access photos', 'Grease trap', 'Lift station', 'Water tank', 'Job pictures']               // "Add into" and the Site file
const HINT3 = 'Drag a photo between Access photos, Grease trap and Job pictures, and drag within a section to set the order. Add more from past visits on the right.'
const HINT5 = 'Drag a photo between Access photos, Grease trap, Lift station, Water tank and Job pictures, and drag within a section to set the order. Add more from past visits on the right.'
const HINT_LS = 'The lift station: its access, its control panel and the station itself.'
const HINT_WT = 'The water tank: its capacity plate and the tank itself.'

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const PIXEL = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './lift_water_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = [], calls = [], submits = []
async function open(w, data, draft) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  if (draft) await ctx.addInitScript(([k, d]) => { try { if (!localStorage.getItem(k)) localStorage.setItem(k, d) } catch {} }, [`pp-draft:${user.id}:1164`, draft])
  const p = await ctx.newPage()
  const st = { errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: [], get_page_versions: [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); calls.push(n)
    if (n === 'submit_property_page') { submits.push(JSON.parse(x.request().postData() || '{}')); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: 999999, version: (data.pb.newest_version || 0) + 1 }) }) }
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => { const q = x.request()
    if (q.method() === 'POST' && q.url().includes('/object/sign/')) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedURL: '/object/sign/fixture/one-pixel.png?token=fixture' }) })
    if (q.method() === 'GET') return x.fulfill({ status: 200, contentType: 'image/png', body: PIXEL })
    return x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/functions/v1/**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent.trim() === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
// the builder's photo sections, in page order: title, hint, empty or not, and each card's source (its From line tooltip)
const sections = (p) => p.evaluate((names) => [...document.querySelectorAll('section h2')].filter((h) => names.includes(h.textContent.trim()) && h.closest('section').querySelector('[title="Drag to reorder or move to another category"], .border-dashed'))
  .map((h) => { const s = h.closest('section'); return { title: h.textContent.trim(), hint: (h.nextElementSibling || {}).textContent || null, empty: /Drag photos here/.test(s.textContent),
    cards: [...s.querySelectorAll('[title="Drag to reorder or move to another category"]')].map((c) => { const f = c.parentElement.querySelector('[title^="From: "]'); return f ? f.getAttribute('title').replace(/\. Written by the collector.*$/, '') : null }) } }), SEC)
const stepHint = (p) => p.evaluate(() => { const e = [...document.querySelectorAll('p')].find((x) => x.textContent.startsWith('Drag a photo between')); return e ? e.textContent.trim() : null })
const addInto = (p) => p.evaluate(() => { const l = [...document.querySelectorAll('label')].find((x) => x.textContent.startsWith('Add into')); return l ? [...l.querySelectorAll('option')].map((o) => o.textContent) : null })
const clickText = async (p, re) => { const b = p.locator('button', { hasText: re }).first(); if (await b.count()) { await b.scrollIntoViewIfNeeded().catch(() => {}); await b.click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(700) } }
const titles = (s) => s.map((x) => x.title).join('|')
// the first Remove of the INNERMOST section titled <title> (the photo step is a section too, holding every h2)
const removeIn = async (p, title) => { await p.evaluate((title) => { const h = [...document.querySelectorAll('section h2')].find((x) => x.textContent.trim() === title && x.closest('section').querySelectorAll('section').length === 0); const b = h && [...h.closest('section').querySelectorAll('button')].find((x) => x.textContent.trim() === 'Remove'); if (b) b.click() }, title); await p.waitForTimeout(600) }
const src = (label) => `From: Site survey · ${label}`

{ // 390, scenario S: the counts from the form, then the photos; saved, previewed
  const { ctx, p, st } = await open(390, S)
  const s0 = await sections(p)
  ok(titles(s0) === SEC3, '390: [guard] B1 with no count and no such photo the builder shows the three sections of today', titles(s0))
  ok((await stepHint(p)) === HINT3, '390: [guard] B1 the step hint names the three sections shown', await stepHint(p))
  const gt0 = (s0.find((x) => x.title === 'Grease trap') || { cards: [] }).cards.length
  // the office fills the counts from the form first (a lift station or water tank photo is offered only once the page
  // counts one: PP rule 13, NEEDS); the two sections appear, empty
  await clickText(p, /^Fill empty fields$/)
  const sF = await sections(p)
  ok(titles(sF) === SEC.join('|') && ['Lift station', 'Water tank'].every((t) => (sF.find((x) => x.title === t) || {}).empty), '390: [new] B2 "Fill empty fields" puts the counts on the page: Lift station and Water tank appear, empty', sF.map((x) => [x.title, x.cards.length, x.empty]))
  await clickText(p, /^Add \d+ photos? from this form$/)
  const s1 = await sections(p)
  const ls = s1.find((x) => x.title === 'Lift station'), wt = s1.find((x) => x.title === 'Water tank'), gt = s1.find((x) => x.title === 'Grease trap')
  ok(titles(s1) === SEC.join('|'), '390: [new] B2 after "Add N photos from this form" the five sections are there, in this order: ' + SEC.join(', '), titles(s1))
  ok(!!ls && ls.cards.slice().sort().join('|') === [src('Lift station'), src('Lift station access')].sort().join('|'), '390: [new] B2 Lift station holds the two lift station photos', ls && ls.cards)
  ok(!!wt && wt.cards.slice().sort().join('|') === [src('Water tank'), src('Water tank capacity')].sort().join('|'), '390: [new] B2 Water tank holds the two water tank photos', wt && wt.cards)
  ok(!!gt && gt.cards.length === gt0 + 1 && !gt.cards.some((c) => /Lift station|Water tank/.test(c || '')), '390: [new] B2 Grease trap got only its own new photo, none of the lift station or water tank ones', gt && gt.cards)
  ok(!!ls && ls.hint === HINT_LS && !!wt && wt.hint === HINT_WT, '390: [new] B2 each new section has its hint', { ls: ls && ls.hint, wt: wt && wt.hint })
  ok((await stepHint(p)) === HINT5, '390: [new] B2 the step hint names the five sections shown', await stepHint(p))
  const ai = await addInto(p)
  ok(!!ai && ai.join('|') === INTO.join('|'), '390: [new] B2 "Add into" lists the five sections shown', ai)
  // Remove one lift station photo: the section stays (shown once, it never unmounts under the office's fingers)
  await removeIn(p, 'Lift station')
  const s2 = await sections(p)
  ok(titles(s2).includes('Lift station') && (s2.find((x) => x.title === 'Lift station') || { cards: [] }).cards.length === 1, '390: [new] B2 a removed lift station photo leaves the section shown, with the other photo', s2.map((x) => [x.title, x.cards.length]))
  // the Site file preview draws the new sections between Grease trap and Job pictures
  await p.evaluate(() => window.scrollTo(0, 0))
  await clickText(p, /^View site file$/)
  const pv = await p.evaluate(() => { const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop(); return d ? [...d.querySelectorAll('h2')].map((h) => h.textContent.trim()) : null })
  const idx = INTO.map((t) => (pv || []).indexOf(t))
  ok(!!pv && idx.every((i) => i >= 0) && idx.every((i, k) => k === 0 || i > idx[k - 1]), '390: [new] B8 the Site file preview shows Lift station and Water tank between Grease trap and Job pictures', pv)
  await p.keyboard.press('Escape'); await p.waitForTimeout(500)
  // Submit: the saved content carries the new section values, and the map is exactly the live version's
  await clickText(p, /^Submit for approval$/); await clickText(p, /^Submit( anyway)?$/); await p.waitForTimeout(1500)
  const sub = submits[submits.length - 1]
  const secOf = (id) => ((sub && sub.p_content && sub.p_content.photos) || []).find((ph) => String(ph.photo_id) === String(id))?.section
  const lsIds = Object.entries(moved).filter(([, k]) => k.startsWith('lift_station.')).map(([id]) => id), wtIds = Object.entries(moved).filter(([, k]) => k.startsWith('water_tank.')).map(([id]) => id)
  ok(!!sub && lsIds.filter((id) => secOf(id)).length === 1 && lsIds.filter((id) => secOf(id)).every((id) => secOf(id) === 'lift_station') && wtIds.every((id) => secOf(id) === 'water_tank'), '390: [new] B5 Submit sends section lift_station and water_tank for those photos', sub && { ls: lsIds.map(secOf), wt: wtIds.map(secOf) })
  ok(!!sub && JSON.stringify(sub.p_content.site_map) === JSON.stringify(S.pb.live.content.site_map || null), '390: [guard] B5 the map sent is the live version\'s, untouched (the GT pin is not a photo section)', sub && { sent: sub.p_content.site_map, live: S.pb.live.content.site_map })
  ok(st.errors.length === 0, '390: no page errors', st.errors)
  await ctx.close()
}
{ // 390, scenario C: a count above 0 shows its section, empty, on open
  const { ctx, p, st } = await open(390, C)
  const s = await sections(p), ls = s.find((x) => x.title === 'Lift station')
  ok(titles(s) === 'Access photos|Grease trap|Lift station|Job pictures & description' && !!ls && ls.empty && ls.cards.length === 0, '390: [new] B3 a page counting 1 lift station shows the Lift station section on open, empty ("Drag photos here"), and no Water tank', s.map((x) => [x.title, x.cards.length, x.empty]))
  ok(st.errors.length === 0, '390: B3 no page errors', st.errors)
  await ctx.close()
}
{ // 390, scenario LV: a saved version holding a lift_station photo loads it into Lift station
  const { ctx, p, st } = await open(390, LV)
  const s = await sections(p), ls = s.find((x) => x.title === 'Lift station')
  const acc = (s.find((x) => x.title === 'Access photos') || { cards: [] }).cards.length
  ok(!!ls && ls.cards.length === 1 && acc === ACC_LIVE - 1, '390: [new] B6 a version whose photo is in lift_station opens with that photo in Lift station (not in Access photos)', { sections: s.map((x) => [x.title, x.cards.length]), ACC_LIVE })
  // B2s: Fred's rule, literally: a section shows only while the page counts one or it holds a photo, so with the count at
  // 0 its last photo removed takes the section away (a section that stayed would be a rule he did not pick)
  await removeIn(p, 'Lift station')
  const sR = await sections(p), lsR = sR.find((x) => x.title === 'Lift station')
  ok(!!ls && ls.cards.length === 1 && !lsR && titles(sR) === SEC3, '390: [new] B2s its only photo removed (count 0), the Lift station section is gone: three sections, as today', sR.map((x) => [x.title, x.cards.length, x.empty]))
  ok(st.errors.length === 0, '390: B6 no page errors (the loader knows the five sections)', st.errors)
  await ctx.close()
}
{ // 390: an old browser draft (three sections only) is restored without an error
  const { ctx, p } = await open(390, S)
  await p.locator('#pp-shared-access-notes').click({ timeout: 4000 }).catch(() => {}); await p.keyboard.press('End'); await p.keyboard.type(' x'); await p.waitForTimeout(2500)
  const raw = await p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) return localStorage.getItem(k) } return null })
  await ctx.close()
  // a browser draft holds the page CONTENT (photo sections as access / grease_trap / job) and goes back through the loader
  const old = raw && !/"section":"(lift_station|water_tank)"/.test(raw) ? raw : null
  ok(!!old, '390: [guard] B7 fixture: a browser draft whose photos sit in the three sections of today', !!raw)
  if (old) {
    const { ctx: c3, p: p3, st: st3 } = await open(390, S, old)
    const body = await p3.textContent('body')
    const s = await sections(p3)
    ok(/Restored your draft from/.test(body) && titles(s) === SEC3 && st3.errors.length === 0, '390: [guard] B7 an old draft with three sections restores, draws its sections, and throws nothing', { restored: /Restored your draft from/.test(body), s: titles(s), errors: st3.errors })
    await c3.close()
  }
}
{ // 1440, scenario C2 (both counts on the page): the "On the form" panel beside the photos
  const { ctx, p, st } = await open(1440, C2)
  const rowOf = (label) => p.evaluate((label) => { const pn = document.querySelector('section[aria-label="Photos on the form"]'); if (!pn) return null
    const rowEl = [...pn.children].find((d) => [...d.querySelectorAll('p, span')].some((x) => x.textContent.trim() === label)); return rowEl ? rowEl.textContent.replace(/\s+/g, ' ').trim() : null }, label)
  const r0 = await rowOf('Lift station access'), r1 = await rowOf('Water tank')
  ok(!!r0 && /Add to Lift station$/.test(r0) && !!r1 && /Add to Water tank$/.test(r1), '1440: [new] B9 "On the form": the lift station photo offers "Add to Lift station", the water tank one "Add to Water tank"', { r0, r1 })
  // the chip of THAT row ("Lift station access"), never the first chip of the panel
  await p.evaluate(() => { const pn = document.querySelector('section[aria-label="Photos on the form"]'); const rowEl = pn && [...pn.children].find((d) => [...d.querySelectorAll('p, span')].some((x) => x.textContent.trim() === 'Lift station access')); const b = rowEl && rowEl.querySelector('button'); if (b) b.click() }); await p.waitForTimeout(700)
  const r2 = await rowOf('Lift station access'), s = await sections(p)
  ok(!!r2 && /Already in Lift station/.test(r2) && titles(s).split('|').includes('Lift station') && (s.find((x) => x.title === 'Lift station') || { cards: [] }).cards.length >= 1, '1440: [new] B9 after the chip the row reads "Already in Lift station" and the photo is in the Lift station section', { r2, s: s.map((x) => [x.title, x.cards.length]) })
  ok(st.errors.length === 0, '1440: no page errors', st.errors)
  await p.screenshot({ path: `${out}/b2_1440.png`, fullPage: true }).catch(() => {})
  await ctx.close()
}
ok(!calls.some((n) => !/^get_|^submit_property_page$/.test(n)), 'nothing but reads and the stubbed submit was called', [...new Set(calls)])
await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
