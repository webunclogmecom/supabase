// video-claims-live.mjs: every instruction in the Collector training video, run on the LIVE form: real link, server, Google, Field login, uploads.
// WRITES: SUBMITS the form on the test client 112-YA, with photos. Make the form in the Client App, assigned to Fred Driver (employee 59).
// A form must have every question asked (Select all); the lock box code is skipped when it is on file. Never prints a token, code or email.
//   node scripts/intake-collector/tests/video-claims-live.mjs <intake id> <outdir>
// 66 of 66 on 2026-11-04 (form 1129). Then read the shots beside the film: a text check cannot see what the screen shows.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const require = createRequire(import.meta.url)
const { chromium } = require('C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ID = Number(process.argv[2]), OUT = process.argv[3]; fs.mkdirSync(OUT, { recursive: true })
const DEMO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/video-projects/zoho-training/intake-collector-video/assets/demo/'
const [row] = await sql(`select i.token, i.submitted_at, p.client_id, p.latitude lat, p.longitude lng, (select email from public.employees where id=59) email from public.property_intakes i join public.properties p on p.id=i.property_id where i.id=${ID}`)
if (!row || row.client_id !== 381 || row.submitted_at) throw new Error('needs an open form on 112-YA')
const TOKEN = row.token, HOME = { lat: +row.lat, lng: +row.lng }, GEO = { lat: 25.80712, lng: -80.20635 }
let pass = 0, fail = 0; const fails = []
const clean = (v) => String(v ?? '').replaceAll(TOKEN, '<token>').replaceAll(row.email, '<email>')
const ok = (c, name, v) => { c ? pass++ : (fail++, fails.push(name)); console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + clean(JSON.stringify(v)).slice(0, 400)}`) }
const info = (name, v) => console.log(`INFO ${name} :: ${clean(JSON.stringify(v)).slice(0, 700)}`)
const step = async (name, fn) => { try { await fn() } catch (e) { ok(false, name + ' threw', String(e.message).split('\n')[0]) } }

const KEY = env.SUPABASE_SERVICE_ROLE_KEY
const gl = await (await fetch('https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/admin/generate_link', { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'content-type': 'application/json' }, body: JSON.stringify({ type: 'magiclink', email: row.email, redirect_to: 'https://planner.unclogme.app/forms' }) })).json()
const LINK = gl.action_link || gl.properties?.action_link
if (!LINK) throw new Error('no link minted')

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false, args: ['--window-position=-2400,0'] })
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2, locale: 'en-US', timezoneId: 'America/New_York', geolocation: { latitude: GEO.lat, longitude: GEO.lng, accuracy: 8 }, permissions: ['geolocation'] })
// the live bytes, fetched fresh; only two identifiers changed, so the test can read the map and pin objects the page itself makes
await ctx.route('https://planner.unclogme.app/intake.html', async (r) => {
  const res = await r.fetch(); let h = await res.text()
  for (const [a, b] of [['var map=new google.maps.Map(box,', 'var map=(window.__m=window.__m||{})[q.key]=new google.maps.Map(box,'], ['var mk=new google.maps.Marker(', 'var mk=(window.__ks=window.__ks||{})[q.key]=new google.maps.Marker(']]) { if (h.split(a).length !== 2) throw new Error('anchor ' + a); h = h.replace(a, b) }
  globalThis.__live = { hybrid: h.includes("mapTypeId:'hybrid'"), cooperative: h.includes("gestureHandling:'cooperative'") }
  await r.fulfill({ response: res, body: h })
})
const p = await ctx.newPage()
const errs = []; p.on('pageerror', (e) => errs.push(String(e).slice(0, 200)))
const net = []; p.on('request', (r) => net.push(r.url()))
const pause = (ms) => p.waitForTimeout(ms)
let n = 0; const shot = async (name) => { await pause(250); await p.screenshot({ path: `${OUT}/${String(++n).padStart(2, '0')}_${name}.png` }) }
const bodyText = () => p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))
const cdp = await ctx.newCDPSession(p)
const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map((t, i) => ({ x: t[0], y: t[1], id: i })) })
const swipe = async (from, to, steps = 12, dwell = 0) => { await touch('touchStart', from); if (dwell) await pause(dwell); for (let s = 1; s <= steps; s++) { await touch('touchMove', from.map((f, i) => [f[0] + (to[i][0] - f[0]) * s / steps, f[1] + (to[i][1] - f[1]) * s / steps])); await pause(30) } await touch('touchEnd', []) }

// ------------------------------------------------ real login, Apps Hub (lines 40)
await step('login', async () => {
  await p.goto(LINK); await p.waitForURL(/planner\.unclogme\.app/, { timeout: 30000 }); await pause(3500)
  ok(/planner\.unclogme\.app\/forms/.test(p.url()), 'Field login lands on Forms', p.url().replace(/#.*/, ''))
  await shot('forms_list')
})
await step('forms list', async () => {
  const t = await bodyText(); info('forms page text', t.slice(0, 500))
  const access = await p.evaluate(async () => document.cookie.includes('auth-token'))
  ok(access, 'shared session cookie written')
  ok(/650 Northwest 33rd Street/.test(t), 'line 41: the assigned form is listed')
  const cards = await p.locator('a[href*="/forms/"], [href*="/forms/"]').count(); info('form links on the list', cards)
  ok(cards >= 1, 'at least one form card')
  const open = p.getByRole('button', { name: /Open form/i }).first()
  ok(await open.isVisible().catch(() => false), 'line 10: Open form on the waiting card')
})
// a form that is not theirs
await step('other form refused', async () => {
  const [o] = await sql(`select max(i.id) id from public.property_intakes i where i.submitted_at is not null and i.cancelled_at is null and not exists (select 1 from ops.calendar_task_assignees a where a.task_id=i.calendar_task_id and a.employee_id=59)`)
  await p.goto('https://planner.unclogme.app/forms/' + o.id); await pause(3000)
  const t = await bodyText(); info('other form page', t.slice(0, 300))
  ok(!/Lock box code|Gate code/i.test(t), 'line 41: another form is not readable')
  await shot('forms_other_refused')
  await p.goto('https://planner.unclogme.app/forms'); await pause(2500)
})
await step('open form', async () => {
  await p.getByRole('button', { name: /Open form/i }).first().click(); await p.waitForURL(/intake(\.html)?#code=/, { timeout: 20000 })
  await p.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0, null, { timeout: 30000 })
  ok(/intake\.html#code=/.test(p.url()), 'line 10: REAL press of Open form opens this form')
  await p.goto('about:blank'); await p.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN); await p.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0, null, { timeout: 30000 })
})
const Q = (k) => p.locator(`[data-q="${k}"]`).first(), F = (f) => p.locator(`[data-f="${f}"]`).first()
const go = async (loc, off = 80) => { await loc.evaluate((e, off) => window.scrollTo(0, e.getBoundingClientRect().top + scrollY - off), off); await pause(250) }
const A = (k) => p.evaluate((k) => A[k] ?? null, k)
const K = 'site_map.truck_parking', GT = 'site_map.gt_location', GT2 = 'grease_trap.t2.location'
const cnt = () => p.textContent('#cnt')

// ------------------------------------------------ the top of the form (lines 7, 54, 8)
await step('top', async () => {
  const t = await bodyText()
  ok(/site survey/i.test(t.slice(0, 300)), 'line 54: the top says site survey', t.slice(0, 120))
  ok(/650 Northwest 33rd Street/.test(await p.textContent('#ttl')), 'line 8: the address at the top', await p.textContent('#ttl'))
  ok((await p.inputValue('#who')) === 'Fred Driver', 'line 8: their name already there', await p.inputValue('#who'))
  await shot('form_top')
})
// the link alone, with no sign-in, as in Jobber (line 7)
await step('no login', async () => {
  const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const q = await c2.newPage(); const rq = []; q.on('request', (r) => rq.push(r.url()))
  const res = await q.goto('https://planner.unclogme.app/intake#code=' + TOKEN); await q.waitForFunction(() => document.querySelectorAll('.q').length > 0, null, { timeout: 30000 })
  ok(/intake\.html#code=/.test(q.url()) && !/login|sign/i.test(q.url()), 'line 7: the Jobber link opens with no login', res.status())
  ok(!rq.some((u) => /\/auth\/v1|\/rest\/v1/.test(u)), 'line 7: no sign-in or database call')
  await c2.close()
})

// ------------------------------------------------ the map (lines 11-17)
const pinPx = (key, ll) => p.evaluate(([key, ll]) => { const m = window.__m[key], b = m.getDiv().getBoundingClientRect(), z = m.getZoom(), W = 256 * 2 ** z, c = m.getCenter(); const w = (la, ln) => { const s = Math.sin(la * Math.PI / 180); return [(ln + 180) / 360 * W, (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * W] }; const a = w(ll.lat, ll.lng), o = w(c.lat(), c.lng()); return [b.left + b.width / 2 + a[0] - o[0], b.top + b.height / 2 + a[1] - o[1]] }, [key, ll])
await step('map opens', async () => {
  await go(Q(K)); await p.waitForFunction((k) => window.__m[k] && window.__m[k].getCenter(), K, { timeout: 30000 }); await pause(3500)
  const s = await p.evaluate((k) => { const m = window.__m[k], c = m.getCenter(); return { type: m.getMapTypeId(), lat: c.lat(), lng: c.lng(), zoom: m.getZoom(), inst: document.querySelector(`[data-q="${k}"] .pin`).textContent, box: document.querySelector(`[data-f="${k}:addr"]`).value } }, K)
  info('map at open', s)
  ok(Math.abs(s.lat - HOME.lat) < 0.002 && Math.abs(s.lng - HOME.lng) < 0.002, 'line 11: map opens on the address')
  ok(s.type === 'hybrid' || s.type === 'satellite', 'line 11: satellite view', s.type)
  ok(globalThis.__live.cooperative, 'line 14: the live page asks for cooperative gestures', globalThis.__live)
  await shot('map_open')
})
await step('tap', async () => {
  const m = await Q(K).locator('.map').boundingBox()
  await p.touchscreen.tap(m.x + m.width * 0.4, m.y + m.height * 0.55); await pause(1200)
  const a = await A(K); ok(a && a.lat && !a.accuracy_m, 'line 12: a tap drops the pin', a)
  await shot('map_tapped')
  info('pin line', await Q(K).locator('.pin').textContent())
})
await step('finger drag', async () => {
  const a = await A(K), [x, y] = await pinPx(K, a)
  // the marker's hit area sits above its anchor point: grab it about 15px up
  await swipe([[x, y - 15]], [[x + 70, y - 55]], 14, 120); await pause(1400)
  const b = await A(K); const moved = b && (Math.abs(b.lat - a.lat) > 1e-5 || Math.abs(b.lng - a.lng) > 1e-5)
  ok(moved, 'line 13: a REAL finger drag moves the pin', { before: a, after: b })
  await shot('map_dragged')
})
await step('one finger', async () => {
  await go(Q(K)); const m = await Q(K).locator('.map').boundingBox()
  const c0 = await p.evaluate((k) => { const c = window.__m[k].getCenter(); return [c.lat(), c.lng()] }, K), y0 = await p.evaluate(() => scrollY), pin0 = await A(K)
  const x = m.x + m.width - 22, y = m.y + m.height * 0.75
  await swipe([[x, y]], [[x, y - 160]], 14); await pause(900)
  const c1 = await p.evaluate((k) => { const c = window.__m[k].getCenter(); return [c.lat(), c.lng()] }, K), y1 = await p.evaluate(() => scrollY), pin1 = await A(K)
  ok(Math.abs(y1 - y0) > 40, 'line 14: one finger on the map scrolls the page', { y0, y1 })
  ok(Math.abs(c1[0] - c0[0]) < 1e-7 && Math.abs(c1[1] - c0[1]) < 1e-7, 'line 14: one finger does not move the map')
  ok(JSON.stringify(pin0) === JSON.stringify(pin1), 'line 14: one finger leaves the pin')
})
await step('two fingers', async () => {
  await go(Q(K)); const m = await Q(K).locator('.map').boundingBox()
  const c0 = await p.evaluate((k) => { const c = window.__m[k].getCenter(); return [c.lat(), c.lng()] }, K), z0 = await p.evaluate((k) => window.__m[k].getZoom(), K), y0 = await p.evaluate(() => scrollY)
  const X = m.x + m.width / 2, Y = m.y + m.height / 2
  await swipe([[X - 40, Y], [X + 40, Y]], [[X - 40 + 60, Y + 50], [X + 40 + 60, Y + 50]], 14); await pause(1500)
  const c1 = await p.evaluate((k) => { const c = window.__m[k].getCenter(); return [c.lat(), c.lng()] }, K)
  ok(Math.abs(c1[0] - c0[0]) > 1e-6 || Math.abs(c1[1] - c0[1]) > 1e-6, 'line 14: two fingers move the map', { c0, c1 })
  await swipe([[X - 30, Y], [X + 30, Y]], [[X - 90, Y], [X + 90, Y]], 14); await pause(1500)
  const z1 = await p.evaluate((k) => window.__m[k].getZoom(), K)
  ok(z1 > z0, 'line 14: two fingers zoom the map', { z0, z1 })
  await shot('map_two_fingers')
})
await step('gps', async () => {
  await go(Q(K)); const b0 = await F(K + ':gps').boundingBox(); info('pin button size', b0)
  await F(K + ':gps').click(); await pause(3500)
  const a = await A(K); ok(a && Math.abs(a.lat - GEO.lat) < 0.0002 && Math.abs(a.lng - GEO.lng) < 0.0002, 'line 15: the pin button puts the pin where you are', a)
  info('after gps', (await Q(K).textContent()).replace(/\s+/g, ' ').slice(0, 260))
  await shot('map_gps')
})
await step('gps denied', async () => {
  const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const q = await c2.newPage(); await q.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN); await q.waitForSelector(`[data-f="${K}:gps"]`); await q.locator(`[data-f="${K}:gps"]`).click(); await q.waitForTimeout(2500)
  info('gps refused says', (await q.locator(`[data-q="${K}"]`).textContent()).replace(/\s+/g, ' ').slice(0, 260))
  await q.locator(`[data-q="${K}"]`).screenshot({ path: `${OUT}/gps_denied.png` }); await c2.close()
})
await step('address box', async () => {
  await go(Q(K)); const box = F(K + ':addr')
  info('box starts with', await box.inputValue())
  await box.click(); await box.fill(''); await p.keyboard.type('1745 Cleveland Road Miami Beach', { delay: 25 }); await pause(2500)
  const rows = await Q(K).locator('.alist [role=option]').allTextContents(); info('suggestions', rows.slice(0, 5))
  ok(rows.length > 0, 'line 16: typing shows a list')
  await shot('map_address_list')
  await Q(K).locator('.alist [role=option]').first().click(); await pause(3500)
  const a = await A(K), c = await p.evaluate((k) => { const c = window.__m[k].getCenter(); return [c.lat(), c.lng()] }, K)
  ok(a && Math.abs(a.lat - 25.8) < 0.2 && Math.abs(c[0] - a.lat) < 0.002, 'line 16: picking moves the map, and the pin goes with it', { a, c })
  await shot('map_address_done')
  // back to the property: the rest of the form stays honest
  await box.click(); await box.fill(''); await p.keyboard.type('650 Northwest 33rd Street Miami', { delay: 25 }); await pause(2500); await Q(K).locator('.alist [role=option]').first().click(); await pause(2500)
})

// ------------------------------------------------ gate and photos (lines 18-25)
const photo = async (k, file) => { const n0 = await p.evaluate((k) => (Array.isArray(A[k]) ? A[k].length : 0), k); await Q(k).locator('input[type=file]:not([capture])').first().setInputFiles(DEMO + file + '.png'); await p.waitForFunction(([k, n]) => busy === 0 && Array.isArray(A[k]) && A[k].length === n + 1, [k, n0], { timeout: 90000 }) }
const GA = 'access_entry.gate', GC = 'access_entry.gate_code', GP = 'access_entry.gate_photos'
await step('gate', async () => {
  await go(Q(GA)); const before = await p.locator('.q').count(); ok(!(await Q(GC).isVisible().catch(() => false)), 'line 18: the code question is not there yet')
  await F(GA + '=yes').click(); await pause(500); const after = await p.locator('.q').count()
  ok(after > before && await Q(GC).isVisible() && await Q(GP).isVisible(), 'line 18-19: Yes opens the code and the photo', { before, after })
  await F(GC).fill('1234'); await shot('gate_yes')
})
await step('photo buttons', async () => {
  const cam = await Q(GP).locator('input[type=file][capture]').first().evaluate((e) => ({ capture: e.getAttribute('capture'), accept: e.accept, multiple: e.multiple }))
  const pick = await Q(GP).locator('input[type=file]:not([capture])').first().evaluate((e) => ({ accept: e.accept, multiple: e.multiple }))
  ok(cam.capture === 'environment', 'line 22: Take a photo opens the back camera', cam); info('Choose photos input', pick)
  info('photo card', (await Q(GP).textContent()).replace(/\s+/g, ' ').slice(0, 200))
  await photo(GP, 'gate'); await pause(500); await go(Q(GP)); await shot('photo_uploaded')
  ok(await Q(GP).locator('textarea.pcm').first().isVisible(), 'line 23: a line box under the photo', await Q(GP).locator('textarea.pcm').first().getAttribute('placeholder'))
  const up = await sql(`select count(*)::int c from public.photo_links where entity_type='property_intake' and entity_id=${ID} and deleted_at is null`); ok(up[0].c === 1, 'real photo reached the database', up[0])
})
await step('remove', async () => {
  await F(GP + ':rm:0').click(); await pause(400); await shot('photo_remove_ask')
  ok(await F(GP + ':rmyes:0').isVisible(), 'line 25: the trash asks, Remove', await F(GP + ':rmyes:0').textContent())
  await F(GP + ':rmyes:0').click(); await pause(1200)
  ok((await p.evaluate((k) => (A[k] || []).length, GP)) === 0, 'line 25: Remove takes it away')
  await photo(GP, 'gate'); await Q(GP).locator('textarea.pcm').first().fill('Front gate, from the street'); await pause(300); await shot('photo_with_line')
})

// ------------------------------------------------ where + getting in (lines 20, 21, 53, 26, 27)
const EW = 'access_entry.equipment_where', WO = 'access_entry.where_outside', AP = 'access_entry.access_point', APH = 'access_entry.access_photos'
await step('where', async () => {
  await go(Q(EW)); info('equipment options', await Q(EW).locator('button').allTextContents())
  await F(EW + '=Outside').click(); await pause(400)
  ok(await Q(WO).isVisible(), 'line 20: then where, exactly', await Q(WO).locator('button').allTextContents())
  await F(WO + '=Back').click(); await pause(400); await go(Q(AP))
  info('access question', (await Q(AP).locator('label').first().textContent()).trim()); info('access options', await Q(AP).locator('button').allTextContents())
  await F(AP + '=Back door').click(); await pause(300)
  await photo(APH, 'door'); await Q(APH).locator('textarea.pcm').first().fill('Back door, by the dumpster'); await shot('where_photo')
})
const HA = 'access_entry.how_access', LC = 'access_entry.lock_box_code', LP = 'access_entry.lock_box_photos', AL = 'access_entry.alarm', OB = 'access_entry.obstacles'
await step('getting in', async () => {
  await go(Q(HA)); const opts = await Q(HA).locator('button').allTextContents(); info('how options', opts)
  ok(['Lock box', 'Key', 'Someone lets us in'].every((x) => opts.includes(x)), 'line 26: the three ways')
  for (const o of opts) { await F(HA + '=' + o).click(); await pause(450); const keys = await p.evaluate(() => { const a = [...document.querySelectorAll('[data-q]')].map((e) => e.getAttribute('data-q')); const i = a.indexOf('access_entry.how_access'), j = a.indexOf('access_entry.alarm'); return a.slice(i + 1, j) }); info('after ' + o, keys) }
  await F(HA + '=Lock box').click(); await pause(450); if (await Q(LC).isVisible().catch(() => false)) await F(LC).fill('1234'); else info('lock box code', 'not asked: already on file for this property'); await photo(LP, 'lockbox'); await Q(LP).locator('textarea.pcm').first().fill('Lock box on the pipe, next to the door'); await go(Q(HA)); await shot('getin')
  await go(Q(AL)); info('alarm options', await Q(AL).locator('button').allTextContents()); await F(AL + '=yes').click(); await pause(400); info('alarm yes opens', await p.evaluate(() => [...document.querySelectorAll('[data-q^="access_entry.alarm"]')].map((e) => e.querySelector('label')?.textContent.trim().slice(0, 50)))); await F(AL + '=no').click(); await pause(300)
  await F(OB).fill('Low branches by the gate.'); await pause(300); await shot('alarm_obstacles')
})

// ------------------------------------------------ hours and counts (lines 28-33)
const HS = 'access_hours.schedule'
await step('hours', async () => {
  await go(Q(HS)); await F(HS + ':mon').click(); await pause(300); await F(HS + ':tue').click(); await pause(300)
  await F(HS + ':mon:o').fill('06:00'); await F(HS + ':mon:c').fill('14:00'); await pause(300); await F(HS + ':tue:o').fill('06:00'); await F(HS + ':tue:c').fill('14:00'); await pause(300)
  const a = await A(HS); ok(a && JSON.stringify(a).includes('06:00'), 'line 28: days then times', a); await shot('hours')
})
const SY = 'grease_trap.systems_count', CO = 'grease_trap.cleanouts_count', MH = 'grease_trap.manhole_count', SP = 'grease_trap.sample_ports'
await step('counts', async () => {
  await go(Q(SY)); await F(SY + ':+').click(); await pause(350); await F(SY + ':+').click(); await pause(450)
  ok((await A(SY)) == 2, 'line 29: plus plus is two', await A(SY))
  await F(SY + ':-').click(); await pause(350); ok((await A(SY)) == 1, 'line 29: minus takes one off', await A(SY)); await F(SY + ':+').click(); await pause(450)
  await shot('counts'); await F(CO + ':+').click(); await pause(250); await F(MH + ':+').click(); await pause(250); await F(MH + ':+').click(); await pause(250)
  const qs = await p.evaluate(() => [...document.querySelectorAll('[data-q]')].map((e) => e.getAttribute('data-q')).filter((k) => /^grease_trap|gt_location/.test(k))); info('trap questions at 2', qs)
  await photo('grease_trap.photos', 'manholes'); await photo('grease_trap.capacity_photos', 'plate'); await Q('grease_trap.capacity_photos').locator('textarea.pcm').first().fill('The plate on the first trap')
})
await step('trap pins', async () => {
  ok(await Q(GT).locator('.map').isVisible() && await Q(GT2).locator('.map').isVisible(), 'line 30: one map for each of the 2 traps')
  await go(Q(GT)); await p.waitForFunction((k) => window.__m[k], GT, { timeout: 15000 }); await pause(3000)
  const inst = (await Q(GT).locator('.pin').textContent()).trim(); info('trap pin instruction', inst); await shot('gt_pin_before')
  let m = await Q(GT).locator('.map').boundingBox(); await p.touchscreen.tap(m.x + m.width * 0.35, m.y + m.height * 0.4); await pause(1200)
  const a = await A(GT); ok(a && a.lat, 'line 30: tap drops a trap pin', a); await shot('gt_pin_1')
  const [x, y] = await pinPx(GT, a); await swipe([[x, y - 15]], [[x + 50, y - 40]], 14, 120); await pause(1400); const b = await A(GT)
  ok(b && (Math.abs(b.lat - a.lat) > 1e-5 || Math.abs(b.lng - a.lng) > 1e-5), 'line 30: works just like the truck (finger drag)', { a, b })
  await go(Q(GT2)); await p.waitForFunction((k) => window.__m[k], GT2, { timeout: 15000 }); await pause(3000); m = await Q(GT2).locator('.map').boundingBox(); await p.touchscreen.tap(m.x + m.width * 0.6, m.y + m.height * 0.6); await pause(1200)
  const c = await A(GT2); ok(c && c.lat, 'line 30: second trap gets its own pin', c); await shot('gt_pin_2')
})
const SF = 'grease_trap.size_from', MD = 'grease_trap.model', SF2 = 'grease_trap.t2.size_from', ME2 = 'grease_trap.t2.capacity_measure'
await step('size', async () => {
  await go(Q(SF)); const o = await Q(SF).locator('button').allTextContents(); info('size options', o)
  ok(o.some((x) => /model/i.test(x)) && o.some((x) => /measure/i.test(x)), 'line 31: model or measurements')
  await F(SF + '=Model on the plate').click(); await pause(400); await F(MD).fill('GB-75'); await pause(500); await shot('size_model')
  await go(Q(SF2)); await F(SF2 + '=Measurements').click(); await pause(400); await F(ME2).fill('48 x 24 x 36 inches'); await pause(500); await go(Q(SF2)); await shot('size_measure')
})
const LS = 'lift_station.count', WT = 'water_tank.count'
await step('lift', async () => {
  await go(Q(LS)); info('counter before', await cnt())
  await F(LS + ':-').click(); await pause(350); ok((await A(LS)) === 0, 'line 33: minus from empty answers zero', await A(LS))
  await F(WT + ':-').click(); await pause(350); ok((await A(WT)) === 0, 'line 33: same for water tanks', await A(WT)); await shot('lift_zero')
  await F(LS + ':+').click(); await pause(450); const q1 = await p.evaluate(() => [...document.querySelectorAll('[data-q^="lift_station."]')].map((e) => e.getAttribute('data-q'))); ok(q1.some((k) => /photo/.test(k)), 'line 33: one lift station asks for photos', q1); await shot('lift_one')
  await F(LS + ':-').click(); await pause(450)
  await F(WT + ':+').click(); await pause(450); const q2 = await p.evaluate(() => [...document.querySelectorAll('[data-q^="water_tank."]')].map((e) => e.getAttribute('data-q'))); ok(q2.some((k) => /photo/.test(k)), 'line 33: one water tank asks for photos', q2); await F(WT + ':-').click(); await pause(450)
  info('counter after', await cnt())
})

// ------------------------------------------------ progress and no signal (line 34)
await step('progress + draft', async () => {
  info('bottom bar', (await p.textContent('#foot')).replace(/\s+/g, ' ').slice(0, 100)); const c0 = await cnt()
  ok(/\d+ of \d+/.test(c0), 'line 34: the bottom shows how far', c0)
  await ctx.setOffline(true); await pause(1200)
  // Since Supabase 980d75b4 the banner shows in the bottom bar when the signal drops. Look at the drawn element: body.textContent would match the page's own script.
  ok(await p.evaluate(() => [...document.querySelectorAll('body *')].some((e) => !e.children.length && /No signal right now/.test(e.textContent) && !['SCRIPT', 'STYLE'].includes(e.tagName) && e.getBoundingClientRect().height > 0)), 'line 34: the banner shows when the signal drops'); await shot('offline')
  await go(Q(AL)); await F(AL + '=yes').click(); await pause(350); await F(AL + '=no').click(); await pause(350)
  await Q('grease_trap.photos').locator('input[type=file]:not([capture])').first().setInputFiles(DEMO + 'plate.png'); await pause(2500)
  info('photo with no signal says', (await Q('grease_trap.photos').textContent()).replace(/\s+/g, ' ').slice(0, 260))
  ok(/signal/i.test((await Q('grease_trap.photos').textContent())), 'line 34: a photo needs signal, and it says so')
  await go(Q('grease_trap.photos')); await shot('offline_photo')
  await ctx.setOffline(false); await pause(1500)
  await p.reload(); await p.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0, null, { timeout: 30000 }); await pause(1500)
  const a = await A(GA), g = await A(GP), c1 = await cnt()
  ok(a === 'yes' || a === true, 'line 34: answers still there after closing the page', a); ok(Array.isArray(g) && g.length === 1, 'photos still there after reload', g && g.length); info('counter after reload', c1)
  await go(Q(GP)); await shot('after_reload')
})

// ------------------------------------------------ submit (lines 35-37)
await step('submit', async () => {
  const GPH = 'grease_trap.photos'
  ok(!(await Q(GPH).locator('textarea.pcm').first().inputValue()), 'set-up: a photo with no line')
  await p.click('#send'); await pause(900)
  const s = (await p.textContent('#fmsg').catch(() => '')) || ''; info('first Submit says', s.replace(/\s+/g, ' ').slice(0, 200)); await shot('submit_missing_line')
  const show = p.getByRole('button', { name: 'Show me' }); ok(await show.isVisible(), 'line 35: Show me appears'); await show.click(); await pause(1000)
  const top = await Q(GPH).locator('textarea.pcm').first().evaluate((e) => e.getBoundingClientRect().top); ok(top > 0 && top < 844, 'line 35: Show me takes you to the photo', top); await shot('submit_show_me')
  await Q(GPH).locator('textarea.pcm').first().fill('The two manholes, behind the kitchen'); await pause(300)
  await p.click('#send'); await pause(900); const s2 = (await p.textContent('#fmsg')).replace(/\s+/g, ' '); info('second Submit says', s2.slice(0, 240)); await shot('submit_blank')
  ok(await p.getByRole('button', { name: 'Keep answering' }).isVisible() && await p.getByRole('button', { name: 'Submit anyway' }).isVisible(), 'line 36: answer them, or send it anyway')
  ok(/cannot be changed/.test(s2), 'line 37: says it cannot be changed', s2.slice(0, 120))
  await p.getByRole('button', { name: 'Keep answering' }).click(); await pause(500); info('still blank after Keep answering', await cnt())
  await p.click('#cnt').catch(() => {}); await pause(700); await shot('jump_to_blank')
  await F(SP + ':-').click(); await pause(400); info('counter', await cnt())
  await p.click('#send'); await pause(1200); const s3 = await p.getByRole('button', { name: 'Submit anyway' }).isVisible().catch(() => false); info('Submit anyway asked again', s3); if (s3) await p.getByRole('button', { name: 'Submit anyway' }).click(); await p.waitForFunction(() => /Thank you|Sent\.|Could not/i.test(document.getElementById('main').textContent), null, { timeout: 30000 }); await pause(800)
  info('thanks page', (await p.textContent('main')).replace(/\s+/g, ' ').slice(0, 200)); await shot('thanks')
  const [db] = await sql(`select submitted_at is not null s, collector, to_char(submitted_at at time zone 'America/New_York','HH24:MI:SS') at_et from public.property_intakes where id=${ID}`); ok(db.s && db.collector === 'Fred Driver', 'Submit really sent it', db)
  await p.goto('https://planner.unclogme.app/intake#code=' + TOKEN); await pause(3000); const t = await p.textContent('main'); ok(/Already submitted/.test(t), 'line 37: the link cannot be changed after', t.replace(/\s+/g, ' ').slice(0, 120)); await shot('already_submitted')
})

// ------------------------------------------------ what they see after (lines 40-42)
await step('forms after', async () => {
  await p.goto('https://planner.unclogme.app/forms'); await pause(3000); await shot('forms_after')
  ok(!(await p.getByRole('button', { name: /Open form/i }).first().isVisible().catch(() => false)), 'a sent form has no Open form')
  await p.goto('https://planner.unclogme.app/forms/' + ID); await pause(3500); const t = await bodyText(); info('form page', t.slice(0, 500)); await shot('form_answers')
  ok(/Front gate, from the street/.test(t), 'line 41: their answers and photo lines are there')
  for (let y = 0; y < 9000; y += 500) { await p.evaluate((y) => scrollTo(0, y), y); await pause(250) } await pause(1500); const imgs = await p.evaluate(() => [...document.images].filter((i) => !/google|gstatic/.test(i.src) && i.complete && i.naturalWidth > 50).length); ok(imgs >= 4, 'line 41: the photos show', imgs)
  const edit = await p.evaluate(() => [...document.querySelectorAll('input:not([type=hidden]),textarea,select')].filter((e) => e.offsetWidth > 0).length); info('editable fields on the form page', edit)
  const btns = await p.evaluate(() => [...document.querySelectorAll('button,a[role=button]')].filter((e) => e.offsetWidth > 0).map((e) => (e.getAttribute('aria-label') || e.textContent).trim().slice(0, 30))); info('buttons on the form page', btns)
  ok(!btns.some((b) => /cancel form|save|edit/i.test(b)), 'line 42: nothing to change'); ok(btns.some((b) => /share/i.test(b)), 'line 42: Share is there')
  await p.goto('https://planner.unclogme.app/'); await pause(3000); info('Field person at the Planner home', { url: p.url().replace(/#.*/, ''), t: (await bodyText()).slice(0, 160) })
})
await step('hub', async () => {
  await p.goto('https://hub.unclogme.app/'); await pause(4500); const t = await bodyText(); info('hub text', t.slice(0, 700)); await p.evaluate(() => scrollTo(0, 0)); await shot('hub')
  ok(/Picture Planner/.test(t), 'line 40-41: Hub shows Picture Planner'); ok(/Field Portal/.test(t), 'line 45: Hub shows Field Portal'); ok(/DUMP|Dump/.test(t), 'line 45: Hub shows DUMP')
})
info('page errors', errs)
await browser.close()
console.log(`\n${pass} passed, ${fail} failed`); if (fails.length) console.log('FAILED:\n - ' + fails.join('\n - '))
