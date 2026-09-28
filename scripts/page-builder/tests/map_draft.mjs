// LIVE Page Builder, property 1164, real data read in SQL as Fred's claims, then edited per scenario. Sign-in faked,
// every RPC stubbed, nothing written. Checks the 2026-09-27 batch M1:
//   A. the map starts from the LIVE VERSION's content (not the property's map), is draft state only (no
//      update_property_site_map call ever), is saved in the browser draft, and is sent in p_content.site_map on Submit;
//      "Remove last arrow" removes one arrow; the draft note is shown; the header says made by / checked by.
//   B. a new page (no version) is filled from the property record only, never from the newest form.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms;`)
const row = r[r.length - 1]
const L = Number(row.pb.property.lat), G = Number(row.pb.property.lng)
const rnd = (x) => Math.round(x * 1e6) / 1e6
const TRUCK = { lat: rnd(L + 0.0002), lng: rnd(G - 0.0001) }
const ARROW = { points: [{ lat: rnd(L + 0.00025), lng: rnd(G - 0.00025) }, { lat: rnd(L + 0.0001), lng: rnd(G - 0.0002) }] }

// A: a live version WITH a map; the property holds a DIFFERENT (stale) map that must not be used
const A = JSON.parse(JSON.stringify({ pb: row.pb, forms: row.forms }))
A.pb.live.content.site_map = { pins: { truck: TRUCK }, arrows: [ARROW] }
A.pb.live.submitted_by_name = 'Maker Person'
A.pb.live.approved_by_name = 'Checker Person'
A.pb.property.site_map = { rev: 5, pins: { gt: { lat: rnd(L - 0.0003), lng: rnd(G) } } }
A.pb.property.site_map_rev = 5
A.pb.pending = null
// B: a new page: no version, the newest form has answers the property record lacks
const B = JSON.parse(JSON.stringify({ pb: row.pb, forms: row.forms }))
B.pb.live = null; B.pb.pending = null; B.pb.newest_version = 0; B.pb.link = null
B.pb.property.source = { ...B.pb.property.source, lock_box_key: 'LB-FROM-PROPERTY', access_notes: null }
if (B.forms[0]) B.forms[0].answers = { ...B.forms[0].answers, 'access_entry.gate': 'yes', 'access_entry.gate_code': '4242-FROM-FORM' }

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './map_draft_shots'; fs.mkdirSync(out, { recursive: true })
const calls = [], submits = []
async function open(w, data, keepStorage) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 }, ...(keepStorage ? { storageState: keepStorage } : {}) })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const replies = { get_page_builder: JSON.stringify(data.pb), get_page_builder_forms: JSON.stringify(data.forms), get_property_activity: '[]' }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); calls.push(n)
    if (n === 'submit_property_page') { submits.push(JSON.parse(x.request().postData() || '{}')); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: 999999, version: (data.pb.newest_version || 0) + 1 }) }) }
    if (replies[n]) return x.fulfill({ status: 200, contentType: 'application/json', body: replies[n] })
    return x.fulfill({ status: 404, body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 })
  await p.waitForTimeout(3000)
  return { ctx, p }
}
const btn = (p, re) => p.locator('button', { hasText: re }).first()
const draftContent = (p) => p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) { try { return JSON.parse(localStorage.getItem(k)).content } catch { return 'bad' } } } return null })

{ // ---------------- A
  const { ctx, p } = await open(1440, A)
  const txt = await p.textContent('body')
  ok(/Pins and arrows are part of this draft\. They show on the site file only after the page is approved\./.test(txt), 'A: the draft note is under the map')
  ok(/made by Maker Person, checked by Checker Person/.test(txt), 'A: the header and footer say made by and checked by', (txt.match(/Live v\d+[^.]{0,80}/g) || []).slice(0, 2))
  ok(!/Use this form's pins: moves the property's pins/.test(txt), 'A: the old "moves the property\'s pins. No Undo." hint is gone')
  ok(!/\u2014/.test(txt), 'A: no long dash anywhere on the page', (txt.match(/.{20}\u2014.{20}/g) || []).slice(0, 3))
  const rla = btn(p, /^Remove last arrow$/)
  ok(await rla.isVisible().catch(() => false), 'A: "Remove last arrow" is offered (the live version has one arrow)')
  await p.screenshot({ path: `${out}/A_1440_open.png`, fullPage: false })
  // Remove the arrow, place the G pin at the map centre
  if (await rla.isVisible().catch(() => false)) { await rla.click(); await p.waitForTimeout(400); ok(!(await btn(p, /^Remove last arrow$/).isVisible().catch(() => false)), 'A: after removing it, the button is gone (no arrow left)') }
  else { await btn(p, /^Clear arrows$/).click().catch(() => {}); await p.waitForTimeout(400) }
  await btn(p, /Place GT Location|Move GT Location/).click().catch(() => {})
  await p.waitForTimeout(300)
  const mapBox = await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => /GT Location/.test(x.textContent)); const w = b && b.closest('.space-y-2'); const g = w && w.querySelector('.gm-style'); if (!g) return null; g.scrollIntoView({ block: 'center' }); const r = g.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height } })
  ok(!!mapBox, 'A: the Google map is drawn')
  if (mapBox) { await p.waitForTimeout(800); await p.mouse.click(mapBox.x + mapBox.width / 2 + 140, mapBox.y + mapBox.height / 2 - 90); await p.waitForTimeout(2500) }
  const d = await draftContent(p)
  ok(d && d.site_map && d.site_map.pins && d.site_map.pins.truck && d.site_map.pins.gt, 'A: the browser draft holds the map (truck from the live version, the new G pin)', d && d.site_map)
  await p.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await p.waitForTimeout(400)
  const sub = btn(p, /^Submit for approval$/)
  ok(await sub.isEnabled().catch(() => false), 'A: Submit for approval is enabled (it no longer waits for a map save)')
  await sub.click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(600)
  await p.locator('button', { hasText: /^Submit$/ }).first().click().catch(() => {})
  await p.waitForTimeout(2500)
  const s = submits[0]
  const sm = s && s.p_content && s.p_content.site_map
  ok(!!s, 'A: submit_property_page was called', s && Object.keys(s))
  ok(sm && sm.pins && sm.pins.truck && sm.pins.truck.lat === TRUCK.lat && sm.pins.truck.lng === TRUCK.lng, 'A: the submitted map carries the LIVE VERSION\'s truck pin (not the property\'s map)', sm)
  ok(sm && sm.pins && sm.pins.gt && Math.abs(sm.pins.gt.lat - L) < 0.002 && Math.abs(sm.pins.gt.lng - G) < 0.002 && !(sm.pins.gt.lat === rnd(L - 0.0003) && sm.pins.gt.lng === rnd(G)), 'A: the submitted G pin is the one placed on the map, near the property', sm && sm.pins && sm.pins.gt)
  ok(sm && (!sm.arrows || sm.arrows.length === 0) && !('rev' in sm), 'A: the removed arrow is gone and the map has no rev', sm)
  ok(s && s.p_expected_map_rev === 5, 'A: p_expected_map_rev is the loaded site_map_rev', s && s.p_expected_map_rev)
  ok(!calls.includes('update_property_site_map'), 'A: update_property_site_map was never called', [...new Set(calls)])
  await p.screenshot({ path: `${out}/A_1440_after_submit.png` })
  await ctx.close()
}
{ // ---------------- B
  const before = submits.length
  const { ctx, p } = await open(1440, B)
  const txt = await p.textContent('body')
  ok(/New page, filled from the property record\. Take the collector's answers with Use this or Fill empty fields\./.test(txt), 'B: the new-page header line')
  const vals = await p.evaluate(() => [...document.querySelectorAll('input, textarea')].map((i) => i.value).filter(Boolean))
  ok(vals.includes('LB-FROM-PROPERTY'), 'B: the lock box code comes from the property record', vals.slice(0, 12))
  ok(!vals.includes('4242-FROM-FORM'), 'B: the gate code from the newest form is NOT pre-filled')
  const notes = p.locator('textarea').last(); await notes.click().catch(() => {}); await p.keyboard.type(' x'); await p.waitForTimeout(2000)
  const d = await draftContent(p)
  ok(d && Array.isArray(d.photos) && d.photos.length === 0, 'B: no form photo is pre-selected (read from the saved draft)', d && d.photos && d.photos.length)
  ok(submits.length === before, 'B: nothing submitted')
  await p.screenshot({ path: `${out}/B_1440_new.png` })
  await ctx.close()
}
{ // ---------------- phone: the map controls fit and Remove last arrow is a tap target
  const { ctx, p } = await open(390, A)
  const box = await btn(p, /^Remove last arrow$/).boundingBox().catch(() => null)
  ok(!!box, 'phone 390: "Remove last arrow" is on the page', box)
  const ov = await p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  ok(!ov, 'phone 390: no sideways scroll')
  await ctx.close()
}
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
