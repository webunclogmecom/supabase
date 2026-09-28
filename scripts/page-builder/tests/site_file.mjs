// LIVE Picture Planner: the SITE FILE (Fred, 2026-09-28; picks L2, D3, C2, F2 and the preview size switch).
// Public page /driver#code=<FAKE>: functions/v1/driver-page is answered from a reply captured in a rolled-back transaction
// (the file SITE_FILE_REPLY names, built by the plan's sf_fixture.mjs; it holds the test client's codes, so it lives in
// the session scratchpad and is never committed), never a real code, so no open is logged; google.maps is a local
// fake (no tiles, no key), storage answers a 1x1 PNG, the Lovable tracker is aborted. Page Builder /property/1164: sign-in
// faked, get_page_builder / forms / activity / versions read in SQL as Fred (STABLE, no writes), every call stubbed,
// nothing written. The link preview is the served /driver HTML, fetched with no code. Codes are masked in the output. Spec: Building Apps/Picture Planner/docs/specs/2026-09-28-site-file-design.md
//   SITE_FILE_REPLY=<reply1164.json> node site_file.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const REPLY_FILE = process.env.SITE_FILE_REPLY
if (!REPLY_FILE || !fs.existsSync(REPLY_FILE)) { console.log('FAIL fixture: set SITE_FILE_REPLY to the reply file sf_fixture.mjs wrote (never commit it: it holds the test client codes)'); process.exit(1) }
const REPLY = JSON.parse(fs.readFileSync(REPLY_FILE, 'utf8'))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_property_activity(1164) as act, client.get_page_versions(1164) as versions;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.act)) { console.log('FAIL fixture: get_page_builder(1164) has no live version :: ' + JSON.stringify(r).slice(0, 200)); process.exit(1) }
const PINS = REPLY.content?.site_map?.pins || {}
if (!REPLY.ok || !PINS.gt || !PINS.truck || REPLY.content.include_map === false || !(REPLY.content.contacts || []).some((c) => c.phone)) { console.log('FAIL fixture: the reply needs both pins, the map on and a contact with a phone'); process.exit(1) }
// every value that looks like a code, in both fixtures, is masked wherever this script prints
const SECRETS = new Set()
const collect = (v, k = '') => { if (v && typeof v === 'object') { for (const [kk, vv] of Object.entries(v)) collect(vv, kk) } else if (v != null && /code|key_tag|public_id|lock_box|token/i.test(k) && String(v).trim().length >= 3) SECRETS.add(String(v)) }
collect(REPLY); collect(row.pb)
const mask = (s) => [...SECRETS].reduce((t, x) => t.split(x).join('<code>'), String(s))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(JSON.stringify(v)).slice(0, 400)}`) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const near = (a, b, t = 1) => a != null && b != null && Math.abs(a - b) <= t
// the spec, written independently of the build
const TITLE_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Display", "Segoe UI", Roboto, sans-serif'
const TEXT_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", Roboto, sans-serif'
const BLUE = 'rgb(26, 115, 232)', WHITE = 'rgb(255, 255, 255)'
const dirURL = (pt) => `https://www.google.com/maps/dir/?api=1&destination=${pt.lat},${pt.lng}`
const addrOf = (pr) => { const has = (v) => v != null && String(v).trim() !== ''; const a = has(pr.address) ? String(pr.address) : ''; if (!has(pr.city)) return a; const c = String(pr.city).trim(); return a.toLowerCase().includes(c.toLowerCase()) ? a : a ? `${a}, ${c}` : c }
const ADDR_URL = `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(addrOf(REPLY.property))}`
const FULL = REPLY
const GT = clone(REPLY); delete GT.content.site_map.pins.truck
const NOMAP = clone(REPLY); NOMAP.content.include_map = false; NOMAP.content.site_map = { pins: {}, arrows: [] }
const TRUCK_NOMAP = clone(REPLY); TRUCK_NOMAP.content.include_map = false
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co', FN = SB + '/functions/v1/'
const FAKE = 'abcdefghijklmnopqrstuv'
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64')
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source' }
// a fake google.maps: the page's loader resolves at once when window.google.maps exists; the map box keeps its own size
const FAKE_MAPS = () => { const noop = () => {}; function Map(el) { const d = document.createElement('div'); d.className = 'gm-style'; d.style.cssText = 'position:absolute;inset:0;background:#5b7a4a'; el.appendChild(d); this.z = 19 } Map.prototype = { getZoom() { return this.z }, setZoom(z) { this.z = z }, fitBounds: noop }; function LatLngBounds() {} LatLngBounds.prototype.extend = function () { return this }; window.google = { maps: { Map, Marker: function () {}, Polyline: function () {}, Point: function (x, y) { this.x = x; this.y = y }, LatLngBounds, SymbolPath: { CIRCLE: 0, FORWARD_CLOSED_ARROW: 1 }, event: { addListenerOnce: noop } } } }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './site_file_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
const chunkSub = async (p) => { if (!process.env.CHUNK_SUB) return; const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }

// ---------- the public page ----------
async function pub(w, reply, mode = 'ok') {
  const phone = w < 768, touch = w < 1024
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : touch ? 1180 : 900 }, deviceScaleFactor: touch ? 2 : 1, isMobile: phone, hasTouch: touch })
  await ctx.addInitScript(FAKE_MAPS)
  const p = await ctx.newPage()
  const st = { stub: 0, bad: [], errors: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route('**/~flock.js*', (x) => x.abort())
  await p.route('**/~api/analytics**', (x) => x.abort())
  await p.route('https://maps.googleapis.com/**', (x) => { st.bad.push('maps'); return x.abort() })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 200, contentType: 'image/png', body: PNG }))
  await p.route(FN + '**', (x) => {
    const q = x.request()
    if (q.method() === 'OPTIONS') return x.fulfill({ status: 204, headers: cors })
    let b = {}; try { b = JSON.parse(q.postData() || '{}') } catch {}
    if (q.url() === FN + 'driver-page' && q.method() === 'POST' && b.code === FAKE) { st.stub++; return mode === '500' ? x.fulfill({ status: 500, headers: { ...cors, 'content-type': 'application/json' }, body: '{"ok":false}' }) : x.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(reply) }) }
    st.bad.push(q.method() + ' ' + q.url().replace(FN, 'functions/v1/')); return x.abort()
  })
  await chunkSub(p)
  await p.goto(H + '/driver' + (mode === 'nocode' ? '' : '#code=' + FAKE))
  await p.waitForFunction(() => !!document.querySelector('h1') || /not valid|Could not open/.test(document.body.textContent), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(1500)
  return { ctx, p, st }
}
const measure = (p) => p.evaluate(() => {
  const q = (s) => document.querySelector(s)
  const rect = (e) => { if (!e) return null; const b = e.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) } }
  const cs = (e) => (e ? getComputedStyle(e) : {})
  const header = q('header'), col = header && header.parentElement, label = header ? header.children[0] : q('[class*="tracking-[0.14em]"]')
  const dirs = [...document.querySelectorAll('a[href*="google.com/maps/dir"]')], d = dirs[0]
  const map = q('[data-sf-map]'), mapDiv = map && [...map.children].find((e) => e !== d && !e.contains(d))
  let top = false
  if (d) { const b = d.getBoundingClientRect(); const hit = document.elementFromPoint(b.x + b.width / 2, b.y + b.height / 2); top = !!hit && (hit === d || d.contains(hit)) }
  const foot = col ? [...col.children].filter((e) => e.tagName === 'P').pop() : null
  const code = q('dd .font-mono'), dd = q('dd'), h1 = q('h1')
  return {
    title: document.title, label: label ? label.textContent.trim() : null, labelW: cs(label).fontWeight, labelF: cs(label).fontFamily, footer: foot ? foot.textContent.trim() : null,
    dirCount: dirs.length,
    dir: d ? { href: d.getAttribute('href'), name: d.getAttribute('aria-label'), tip: d.getAttribute('title'), text: d.textContent.trim(), svg: !!d.querySelector('svg[aria-hidden="true"]'), bg: cs(d).backgroundColor, color: cs(d).color, weight: cs(d).fontWeight, family: cs(d).fontFamily, size: cs(d).fontSize, r: rect(d), onMap: !!(map && map.contains(d)), inGm: !!d.closest('.gm-style'), top, afterHeader: !!header && !!header.nextElementSibling && header.nextElementSibling.contains(d) && !map } : null,
    map: rect(map), mapH: mapDiv ? Math.round(mapDiv.getBoundingClientRect().height) : null,
    left: rect(q('[data-sf-left]')), cards: rect(q('[data-sf-cards]')), col: rect(col), header: rect(header),
    h1: h1 ? { w: cs(h1).fontWeight, f: cs(h1).fontFamily, size: cs(h1).fontSize } : null,
    h2: [...document.querySelectorAll('section h2')].map((h) => ({ t: h.textContent.trim(), w: cs(h).fontWeight, f: cs(h).fontFamily })),
    code: code ? { w: cs(code).fontWeight, size: cs(code).fontSize } : null, ddW: dd ? cs(dd).fontWeight : null,
    calls: [...document.querySelectorAll('a[href^="tel:"]')].map((a) => { const li = a.closest('li'), who = li && li.querySelector('.font-semibold'), b = a.getBoundingClientRect(), rest = li ? li.textContent.replace(who ? who.textContent : '', '') : ''; return { tel: a.getAttribute('href').startsWith('tel:'), name: a.getAttribute('aria-label'), text: a.textContent.trim(), w: Math.round(b.width), h: Math.round(b.height), bg: cs(a).backgroundColor, color: cs(a).color, radius: parseFloat(cs(a).borderTopLeftRadius), svg: !!a.querySelector('svg[aria-hidden="true"]'), who: who ? who.textContent.trim() : null, digits: /\d{3}/.test(rest) } }),
    retry: (() => { const b = [...document.querySelectorAll('button')].find((x) => x.textContent.trim() === 'Retry'); return b ? cs(b).fontWeight : null })(),
    sideways: document.documentElement.scrollWidth > innerWidth,
  }
})
async function drawn(ctx, p, sel) {
  const cdp = await ctx.newCDPSession(p); await cdp.send('DOM.enable'); await cdp.send('CSS.enable')
  const { root } = await cdp.send('DOM.getDocument', { depth: -1 }); const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector: sel })
  if (!nodeId) return null
  return (await cdp.send('CSS.getPlatformFontsForNode', { nodeId }).catch(() => ({ fonts: [] }))).fonts.map((f) => f.postScriptName || f.familyName).join(', ')
}
const TITLE = 'Site file · Picture Planner · UnclogMe', LABEL = 'UnclogMe · Site file'

// A. The full reply (both pins, map on) at 390 / 820 / 1280
for (const w of [390, 820, 1280]) {
  const { ctx, p, st } = await pub(w, FULL)
  const m = await measure(p)
  ok(m.label === LABEL, `${w}: the header label reads UnclogMe · Site file`, m.label)
  ok(m.footer === 'UnclogMe · Site file.', `${w}: the footer reads UnclogMe · Site file.`, m.footer)
  ok(m.title === TITLE, `${w}: the tab title is ${TITLE}`, m.title)
  ok(m.dirCount === 1 && m.dir && m.dir.href === dirURL(PINS.truck) && m.dir.name === 'Directions to the truck spot' && m.dir.tip === m.dir.name && m.dir.text === 'Directions' && m.dir.svg, `${w}: ONE Directions button, to the truck spot, named for it, with the icon`, m.dir && { n: m.dirCount, truck: m.dir.href === dirURL(PINS.truck), name: m.dir.name, text: m.dir.text, svg: m.dir.svg })
  ok(m.dir && m.dir.bg === BLUE && m.dir.color === WHITE, `${w}: Directions is Google blue #1A73E8 with white`, m.dir && [m.dir.bg, m.dir.color])
  ok(m.dir && m.map && m.dir.onMap && !m.dir.inGm && near(m.dir.r.x - m.map.x, 12) && near(m.dir.r.y - m.map.y, 12) && m.dir.top, `${w}: D3, the pill sits on the map's top left corner (12px in), above the map, outside the Maps box`, m.dir && m.map && { dx: m.dir.r.x - m.map.x, dy: m.dir.r.y - m.map.y, onMap: m.dir.onMap, top: m.dir.top })
  const [ph, pz] = w >= 900 ? [44, '14px'] : [48, '16px']
  ok(m.dir && near(m.dir.r.h, ph) && m.dir.size === pz, `${w}: the pill is ${ph}px tall with ${pz} text`, m.dir && [m.dir.r.h, m.dir.size])
  ok(near(m.mapH, w >= 1024 ? 480 : w >= 640 ? 380 : 300), `${w}: the map is ${w >= 1024 ? 480 : w >= 640 ? 380 : 300}px tall`, m.mapH)
  if (w >= 1024) {
    ok(m.left && m.cards && near(m.left.w, 460) && near(m.left.x + 460 + 20, m.cards.x) && near(m.left.y, m.cards.y) && near(m.col.w, 1100) && m.header.w >= m.left.w + m.cards.w, `${w}: L2, map and Directions on the left (460px), the cards on the right, header across both, page 1100px`, { left: m.left, cards: m.cards, col: m.col && m.col.w })
    await p.evaluate(() => window.scrollTo(0, 1200)); await p.waitForTimeout(300)
    const top = await p.evaluate(() => { const e = document.querySelector('[data-sf-left]'); return e ? Math.round(e.getBoundingClientRect().top) : null })
    ok(near(top, 16, 2), `${w}: the left side stays in view while the cards scroll (sticky, 16px from the top)`, top)
    await p.evaluate(() => window.scrollTo(0, 0)); await p.waitForTimeout(200)
  } else {
    ok(m.left && m.cards && m.left.y + m.left.h <= m.cards.y && near(m.col.w, Math.min(w, 680)), `${w}: one column, the map above the cards, page ${Math.min(w, 680)}px`, { left: m.left, cards: m.cards, col: m.col && m.col.w })
  }
  const c = m.calls[0]
  ok(m.calls.length >= 1 && m.calls.every((x) => x.tel && x.w === 44 && x.h === 44 && x.radius >= 22 && x.bg === BLUE && x.color === WHITE && x.svg && x.text === ''), `${w}: C2, Call is a round 44px filled blue icon button, tel: link, no text`, c)
  ok(m.calls.length >= 1 && m.calls.every((x) => x.who && x.name === 'Call ' + x.who), `${w}: its name is "Call <name>" and the name stays as text`, m.calls.map((x) => [x.name, x.who]))
  ok(m.calls.every((x) => !x.digits), `${w}: no phone number added as text`)
  ok(m.h1 && m.h1.w === '600' && m.h1.f === TITLE_FONT, `${w}: F2, the h1 is weight 600 in the system title stack`, m.h1)
  ok(m.h2.length >= 4 && m.h2.every((h) => h.w === '600' && h.f === TITLE_FONT), `${w}: F2, every card title is weight 600 in the system title stack`, m.h2.map((h) => [h.t, h.w]))
  ok(m.dir && m.dir.weight === '600' && m.dir.family === TEXT_FONT, `${w}: F2, the Directions button is weight 600 in the system text stack`, m.dir && [m.dir.weight, m.dir.family])
  ok(m.labelW === '700' && m.labelF === TEXT_FONT, `${w}: the header label keeps weight 700, system text stack`, [m.labelW, m.labelF])
  const codeWant = w >= 900 ? { w: '600', size: '18px' } : { w: '700', size: '26px' }
  ok(m.code && m.code.w === codeWant.w && m.code.size === codeWant.size && m.ddW === '400', `${w}: guard, codes and body text unchanged (code ${codeWant.size} ${codeWant.w}, text 400)`, [m.code, m.ddW])
  if (w !== 820) { const f = await drawn(ctx, p, 'h1'); ok(!!f && /semibold/i.test(f) && !/black|heavy/i.test(f), `${w}: the h1 is DRAWN in a Semibold face (not Black or Bold)`, f) }
  ok(!m.sideways, `${w}: no sideways scroll`)
  ok(st.stub >= 1 && st.bad.length === 0 && st.errors.length === 0, `${w}: guard, only the stubbed fake-code call, no page error`, [st.stub, st.bad, st.errors])
  await p.screenshot({ path: `${out}/A_full_${w}.png`, fullPage: true })
  await ctx.close()
}

// B. Grease trap pin only: the button goes to the trap, still on the map
{
  const { ctx, p } = await pub(390, GT)
  const m = await measure(p)
  ok(m.dirCount === 1 && m.dir && m.dir.href === dirURL(PINS.gt) && m.dir.name === 'Directions to the grease trap' && m.dir.onMap, 'trap only (390): ONE button, to the grease trap, on the map', m.dir && { n: m.dirCount, gt: m.dir.href === dirURL(PINS.gt), name: m.dir.name, onMap: m.dir.onMap })
  await ctx.close()
}
// C. No map and no pins: the address, in D1's place (full width on a phone, fits its words from 768px), one column
for (const w of [390, 820, 1280]) {
  const { ctx, p } = await pub(w, NOMAP)
  const m = await measure(p)
  ok(m.dirCount === 1 && m.dir && m.dir.href === ADDR_URL && m.dir.name === 'Directions to the address' && m.dir.text === 'Directions', `no map (${w}): ONE button, to the address`, m.dir && { n: m.dirCount, address: m.dir.href === ADDR_URL, name: m.dir.name })
  ok(m.dir && !m.map && m.dir.afterHeader && m.dir.bg === BLUE, `no map (${w}): it takes D1's place, right under the header`, m.dir && { map: !!m.map, afterHeader: m.dir.afterHeader })
  const want = w < 768 ? (m.col ? m.col.w - 24 : -1) : null
  ok(m.dir && (w < 768 ? near(m.dir.r.w, want) && near(m.dir.r.h, 52) : m.dir.r.w < 250 && near(m.dir.r.h, w >= 900 ? 44 : 48)), `no map (${w}): ${w < 768 ? 'full width, 52px' : 'fits its words'}`, m.dir && m.dir.r)
  ok(!m.left && m.col && near(m.col.w, Math.min(w, 680)), `no map (${w}): one column (L2 needs the map), page ${Math.min(w, 680)}px`, { left: m.left, col: m.col && m.col.w })
  ok(!m.sideways, `no map (${w}): no sideways scroll`)
  if (w === 1280) await p.screenshot({ path: `${out}/C_nomap_1280.png`, fullPage: true })
  await ctx.close()
}
// D. Map switched off but a truck spot pinned: still the truck spot, in D1's place
{
  const { ctx, p } = await pub(390, TRUCK_NOMAP)
  const m = await measure(p)
  ok(m.dirCount === 1 && m.dir && m.dir.href === dirURL(PINS.truck) && m.dir.name === 'Directions to the truck spot' && !m.dir.onMap && m.dir.afterHeader, 'map off, truck pinned (390): ONE button, to the truck spot, under the header', m.dir && { truck: m.dir.href === dirURL(PINS.truck), onMap: m.dir.onMap, afterHeader: m.dir.afterHeader })
  await ctx.close()
}
// E. The route's own cards: invalid link (no code, no call made) and the error card
{
  const { ctx, p, st } = await pub(390, FULL, 'nocode')
  const m = await measure(p)
  ok(m.label === LABEL && m.title === TITLE && st.stub === 0, 'invalid link (390): the card label and the tab title say Site file, no call made', [m.label, m.title, st.stub])
  await ctx.close()
}
{
  const { ctx, p } = await pub(390, FULL, '500')
  await p.waitForFunction(() => /Could not open/.test(document.body.textContent), null, { timeout: 15000 }).catch(() => {})
  const m = await measure(p)
  ok(m.label === LABEL && m.retry === '600', 'error (390): the card label says Site file, Retry is weight 600', [m.label, m.retry])
  await ctx.close()
}
// the link preview: the HTML the server sends for /driver (no code: a fragment never reaches the server), read as text
{
  const html = await (await fetch(H + '/driver')).text()
  const metas = [...html.matchAll(/<meta\s[^>]*>/g)].map((x) => Object.fromEntries([...x[0].matchAll(/([a-z:-]+)="([^"]*)"/g)].map((a) => [a[1], a[2]])))
  const meta = (k) => metas.filter((x) => x.property === k || x.name === k).map((x) => x.content)
  const lp = { title: (html.match(/<title>([^<]*)<\/title>/) || [])[1] || null, og: meta('og:title'), tw: meta('twitter:title') }
  ok(lp.title === TITLE && lp.og.join() === TITLE && lp.tw.join() === TITLE && !/Lovable App/.test(html), 'link preview: the served /driver title, og:title and twitter:title are the Site file title (no "Lovable App")', lp)
}

// ---------- the Page Builder ----------
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const PB_PENDING = clone(row.pb)
PB_PENDING.pending = { ...clone(row.pb.live), page_id: 999998, version: (row.pb.newest_version || row.pb.live.version) + 1, approved_at: null, approved_by_name: null, submitted_at: new Date().toISOString(), submitted_by_name: 'Visual Check' }
PB_PENDING.newest_version = PB_PENDING.pending.version
async function builder(w, pb = row.pb) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], bad: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) }) // Maps is aborted on purpose
  const replies = { get_page_builder: pb, get_page_builder_forms: row.forms, get_property_activity: row.act, get_page_versions: row.versions || [] }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n); return replies[n] !== undefined ? x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) }) : x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(FN + '**', (x) => { st.bad.push(x.request().url().replace(FN, 'functions/v1/')); return x.abort() }) // never a real code
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  await chunkSub(p)
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3000)
  return { ctx, p, st }
}
const openPreview = async (p) => { await p.locator('button', { hasText: /^View site file$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1200) }
const preview = (p) => p.evaluate(() => {
  const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop()
  if (!d) return null
  const vis = (e) => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden'
  const rg = d.querySelector('[role="radiogroup"]')
  const root = d.querySelector('[class*="@container"]')
  const frame = d.querySelector('[data-preview-frame]')
  const cap = d.querySelector('[data-preview-caption]') || [...d.querySelectorAll('p')].find((p) => /size/.test(p.textContent) && p.textContent.length < 40)
  const r = (e) => { if (!e) return null; const b = e.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) } }
  return {
    title: (document.getElementById(d.getAttribute('aria-labelledby') || '') || {}).textContent || null,
    rg: rg ? { vis: vis(rg), name: rg.getAttribute('aria-label'), radios: [...rg.querySelectorAll('[role="radio"]')].map((b) => ({ t: b.textContent.trim(), on: b.getAttribute('aria-checked'), tab: b.tabIndex, h: Math.round(b.getBoundingClientRect().height) })) } : null,
    rootW: root ? root.offsetWidth : null, frame: r(frame || (root && root.parentElement)), caption: cap && vis(cap) ? cap.textContent.trim() : null,
    left: r(root && root.querySelector('[data-sf-left]')), cards: r(root && root.querySelector('[data-sf-cards]')),
    aside: /What changed/.test(d.textContent), sideways: d.scrollWidth > d.clientWidth + 1, vw: innerWidth,
  }
})
// D3 must never paint over the preview's sticky bar (z-10 like the pill; the bar holds Approve and Close): scroll the dialog
// until the pill sits under the bar, then the bar must take the hit at the pill's centre (the map wrapper is isolate)
async function underBar(p) {
  const s = await p.evaluate(() => {
    const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop()
    const pill = d && d.querySelector('[data-sf-directions]')
    const bar = d && [...d.querySelectorAll('*')].find((e) => getComputedStyle(e).position === 'sticky' && !e.closest('[class*="@container"]'))
    let sc = pill && pill.parentElement
    while (sc && sc !== document.body && !(/auto|scroll/.test(getComputedStyle(sc).overflowY) && sc.scrollHeight > sc.clientHeight + 1)) sc = sc.parentElement
    if (!pill || !bar || !sc || sc === document.body) return { pill: !!pill, bar: !!bar, scroller: !!sc && sc !== document.body }
    sc.scrollTop += pill.getBoundingClientRect().top - (bar.getBoundingClientRect().top + 2)
    return { pill: true, bar: true, scroller: true }
  })
  if (!s.scroller) return s
  await p.waitForTimeout(300)
  return p.evaluate(() => {
    const d = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].pop()
    const pill = d.querySelector('[data-sf-directions]')
    const bar = [...d.querySelectorAll('*')].find((e) => getComputedStyle(e).position === 'sticky' && !e.closest('[class*="@container"]'))
    const pr = pill.getBoundingClientRect(), br = bar.getBoundingClientRect(), x = pr.x + pr.width / 2, y = pr.y + pr.height / 2
    const hit = document.elementFromPoint(x, y)
    return { under: y > br.top && y < br.bottom, inBar: !!hit && bar.contains(hit), hit: hit ? (hit.closest('[data-sf-directions]') ? 'the pill' : hit.tagName) : null }
  })
}
const pick = async (p, t) => { await p.locator('[role="radiogroup"] [role="radio"]', { hasText: new RegExp('^' + t + '$') }).first().click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(700) }
const SIZES = [['Phone', 430], ['Tablet', 820], ['Laptop', 1280]]

// F. Laptop 1440: the header button, the switch, the three frames, keyboard, Esc
{
  const { ctx, p, st } = await builder(1440)
  const h = await p.evaluate(() => { const bs = [...document.querySelectorAll('button')]; const vb = bs.find((b) => b.textContent.trim() === 'View site file'); return { vb: !!vb, afterActivity: !!(vb && vb.previousElementSibling && vb.previousElementSibling.hasAttribute('data-activity-open')), old: bs.some((b) => b.textContent.trim() === 'View drivers page') } })
  ok(h.vb && h.afterActivity && !h.old, '1440: the header button reads View site file, right after Activity (no View drivers page)', h)
  await openPreview(p)
  let v = await preview(p)
  ok(!!v && v.title === 'Preview · Site file', '1440: the preview is titled Preview · Site file', v && v.title)
  ok(!!v && !!v.rg && v.rg.vis && v.rg.name === 'Preview size' && v.rg.radios.map((x) => x.t).join() === 'Phone,Tablet,Laptop', '1440: a radiogroup "Preview size" with Phone, Tablet, Laptop', v && v.rg)
  ok(!!v && !!v.rg && v.rg.radios.map((x) => x.on + '/' + x.tab).join() === 'true/0,false/-1,false/-1' && v.rg.radios.every((x) => near(x.h, 36)), '1440: Phone is checked first, roving tabindex, 36px tall', v && v.rg && v.rg.radios)
  for (const [name, W] of SIZES) {
    await pick(p, name)
    v = await preview(p)
    ok(!!v && v.rootW === W && near(v.frame && v.frame.w, W + 2) && v.caption === `${name} size` && !v.sideways, `1440: ${name}, the page is laid out ${W}px wide, frame at 100%, caption "${name} size"`, v && { rootW: v.rootW, frame: v.frame && v.frame.w, caption: v.caption })
    if (name === 'Laptop') {
      ok(!!v && v.left && v.cards && v.left.x < v.cards.x && near(v.left.y, v.cards.y), '1440: the Laptop frame shows the two columns (L2)', v && [v.left, v.cards])
      await p.screenshot({ path: `${out}/F_laptop_1440.png` })
    }
    if (name === 'Tablet') ok(!!v && v.left && v.cards && v.left.y + v.left.h <= v.cards.y, '1440: the Tablet frame shows one column', v && [v.left, v.cards])
  }
  await pick(p, 'Phone')
  await p.locator('[role="radio"][aria-checked="true"]').first().focus().catch(() => {})
  await p.keyboard.press('ArrowLeft'); await p.waitForTimeout(500)
  const k1 = await p.evaluate(() => { const a = document.activeElement; return { focus: a && a !== document.body ? a.textContent.trim().slice(0, 40) : 'body', on: a && a.getAttribute('aria-checked') } })
  await p.keyboard.press('ArrowRight'); await p.waitForTimeout(500)
  const k2 = await p.evaluate(() => { const a = document.activeElement; return { focus: a && a !== document.body ? a.textContent.trim().slice(0, 40) : 'body', on: a && a.getAttribute('aria-checked') } })
  ok(k1.focus === 'Laptop' && k1.on === 'true' && k2.focus === 'Phone' && k2.on === 'true', '1440: arrow keys move and select (Left from Phone wraps to Laptop, Right back to Phone)', [k1, k2])
  await p.keyboard.press('Escape'); await p.waitForTimeout(500)
  const c = await p.evaluate(() => ({ open: !!document.querySelector('[role="dialog"][aria-modal="true"]'), focus: document.activeElement && document.activeElement !== document.body ? document.activeElement.textContent.trim().slice(0, 40) : 'body' }))
  ok(!c.open && c.focus === 'View site file', '1440: Esc closes and focus returns to View site file', c)
  // the Activity modal's Other activity item follows the new name
  await p.locator('[data-activity-open]').first().click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(1500)
  const other = await p.evaluate(() => { const o = document.querySelector('[data-version-item="other"]'); return o ? o.textContent.replace(/\s+/g, ' ').trim() : null })
  ok(!!other && other.includes('Site file links · ') && !other.includes('Driver links'), '1440: Activity, the Other activity item reads "Site file links · N"', other)
  ok(st.bad.length === 0 && st.errors.length === 0, '1440: guard, no functions call (no real code opened), no page error', [st.bad, st.errors])
  await ctx.close()
}
// G. Laptop 1024: the Laptop frame is laid out at 1280 and shrunk to fit, with the scale in the caption
{
  const { ctx, p } = await builder(1024)
  await openPreview(p); await pick(p, 'Laptop')
  const v = await preview(p)
  const pct = v && v.frame ? Math.round((v.frame.w / 1282) * 100) : null
  const m = v && v.caption && v.caption.match(/^Laptop size, shown at (\d+)%$/)
  ok(!!v && v.rootW === 1280 && !!m && near(Number(m[1]), pct) && pct < 100 && v.frame.x + v.frame.w <= v.vw && !v.sideways, '1024: Laptop is laid out at 1280px, scaled to fit, caption "Laptop size, shown at N%" (N measured)', v && { rootW: v.rootW, caption: v.caption, pct, frame: v.frame })
  await p.screenshot({ path: `${out}/G_laptop_1024.png` })
  await ctx.close()
}
// H. The version review keeps today's frame (no switch, 430px, the What changed aside)
{
  const { ctx, p } = await builder(1440, PB_PENDING)
  await p.locator('button', { hasText: /^Review version \d+$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1500)
  const v = await preview(p)
  ok(!!v && /^Review version \d+ · read only$/.test(v.title || '') && !v.rg && near(v.rootW, 430, 2) && v.aside, '1440 review: guard, no size switch, the 430px frame and What changed, as today', v && { title: v.title, rg: !!v.rg, rootW: v.rootW, aside: v.aside })
  ok(!!v && v.caption === 'Phone size', '1440 review: its caption reads "Phone size"', v && v.caption)
  const ub = await underBar(p)
  ok(ub.under && ub.inBar, '1440 review: scrolled under the sticky bar, the Directions pill stays BEHIND it (the bar, Approve and Close, take the click)', ub)
  await ctx.close()
}
// I. Phone 390: the button, and no switch (the preview is the page at full width, as today)
{
  const { ctx, p } = await builder(390)
  const bh = await p.evaluate(() => { const b = [...document.querySelectorAll('button')].find((x) => x.textContent.trim() === 'View site file'); return b ? Math.round(b.getBoundingClientRect().height) : 0 })
  ok(bh >= 44, '390: View site file is 44px tall', bh)
  await openPreview(p)
  const v = await preview(p)
  ok(!!v && v.title === 'Preview · Site file', '390: the preview opens, titled Preview · Site file', v && v.title)
  ok(!!v && (!v.rg || !v.rg.vis) && !v.caption && v.rootW === 390 && !v.sideways, '390: no size switch, no caption, the page at full width', v && { rg: v.rg, caption: v.caption, rootW: v.rootW })
  const ub = await underBar(p)
  ok(ub.under && ub.inBar, '390: scrolled under the sticky bar, the Directions pill stays BEHIND it (Close takes the click)', ub)
  await ctx.close()
}

await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
