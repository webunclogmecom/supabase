// form-map.mjs : the collector form's pin maps, on the REAL host (planner.unclogme.app), before anything is deployed.
// intake.html is served from the local build and the load reply gets maps_key (+ property lat/lng if missing)
// injected; the key is the Planner's own browser key, read from its public bundle and never printed.
//   node scripts/intake-collector/tests/form-map.mjs <[TEST] intake id> <outdir> [no-referrer|strict-origin] [real|none|bad]
// Loads and pins only (localStorage); it never submits, so the intake stays usable. Refuses a non-[TEST] intake.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [intakeId, out = './mapshots', policy = 'no-referrer', keyMode = 'real'] = process.argv.slice(2)
fs.mkdirSync(out, { recursive: true })
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const [row] = await sql(`select i.token, i.requested_by, p.latitude, p.longitude from public.property_intakes i join public.properties p on p.id=i.property_id where i.id = ${Number(intakeId)}`)
if (!row || !/^\[TEST\]/.test(row.requested_by)) throw new Error('not a [TEST] intake')
const TOKEN = row.token
const H = 'https://planner.unclogme.app'
let KEY = null
{ const html0 = await (await fetch(H + '/')).text(); const seen = new Set()
  const walk = async (n) => { if (KEY || seen.has(n)) return; seen.add(n); const s = await (await fetch(H + '/' + n)).text(); const m = s.match(/AIza[0-9A-Za-z_-]{35}/); if (m) { KEY = m[0]; return } for (const x of s.matchAll(/["'`]\.?\/?((?:assets\/)?[A-Za-z0-9_.-]+\.js)["'`]/g)) await walk(x[1].startsWith('assets/') ? x[1] : 'assets/' + x[1]) }
  for (const n of new Set([...html0.matchAll(/assets\/[A-Za-z0-9_.-]+\.js/g)].map((m) => m[0]))) await walk(n) }
if (!KEY) throw new Error('no key in the Planner bundle')
// INTAKE_HTML=<file> serves another build (a control, e.g. a mutant whose pick does not place the pin)
let html = fs.readFileSync(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url), 'utf8')
// a second, FAR address (112-YA property 162, Miami Beach, about 7 km away): a pick must MOVE the pin there, so a pin
// that simply stayed near property 1164 cannot pass
const [far] = await sql(`select latitude, longitude from public.properties where id = 162`)
if (policy !== 'no-referrer') html = html.replace('<meta name="referrer" content="no-referrer">', `<meta name="referrer" content="${policy}">`)
const PAGE = H + '/intake.html'
const res = []
const ok = (n, c, x = '') => res.push(`${c ? 'PASS' : 'FAIL'}  ${n}${x ? '  ' + String(x).replaceAll(TOKEN, '<token>') : ''}`)
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
for (const [name, w, h] of [['phone360', 360, 740], ['phone390', 390, 844], ['tablet768', 768, 1024], ['desktop1280', 1280, 900]]) {
  const mobile = w < 700
  const ctx = await b.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, geolocation: { latitude: 25.80941, longitude: -80.20511, accuracy: 7 }, permissions: ['geolocation'] })
  const p = await ctx.newPage()
  const reqs = []
  p.on('request', (r) => reqs.push({ url: r.url(), body: r.postData() || '', ref: r.headers().referer || '' }))
  await p.route(PAGE, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html }))
  let slowDetails = false; const placePaths = new Set()
  await p.route('**/places.googleapis.com/**', async (r) => { const u = new URL(r.request().url()); placePaths.add(u.pathname.split('/').pop()); if (slowDetails && /GetPlace/i.test(u.pathname)) await new Promise((res) => setTimeout(res, 3000)); return r.continue() })
  await p.route('**/functions/v1/intake-submit', async (r) => {
    const body = r.request().postData() || ''
    if (r.request().method() !== 'POST' || !/"op":"load"/.test(body)) return r.continue()
    const f = await r.fetch(); const j = await f.json()
    if (j.property) { j.property.lat = j.property.lat ?? Number(row.latitude); j.property.lng = j.property.lng ?? Number(row.longitude) }
    j.maps_key = keyMode === 'none' ? null : keyMode === 'bad' ? 'not-a-real-key' : KEY
    return r.fulfill({ status: f.status(), headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' }, body: JSON.stringify(j) })
  })
  await p.goto(PAGE + '#code=' + TOKEN)
  await p.waitForFunction(() => document.getElementById('sub').textContent !== 'Loading...', null, { timeout: 20000 })
  const card = p.locator('.q', { hasText: 'Truck parking spot' })
  await card.scrollIntoViewIfNeeded()
  if (keyMode !== 'real') {
    await p.waitForTimeout(8000)
    const fb = await p.evaluate(() => ({ maps: document.querySelectorAll('.q .map').length, hint: document.querySelector('.q .pin') && document.querySelector('.q .pin').textContent }))
    ok(`${name}: ${keyMode} key falls back to Use my location only`, fb.maps === 0 && /Stand next to it/.test(fb.hint || ''), JSON.stringify(fb))
    await card.getByRole('button', { name: /Use my location/ }).click()
    await p.waitForTimeout(3000)
    const a0 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
    ok(`${name}: Use my location still pins`, a0 && a0.accuracy_m === 7, JSON.stringify(a0))
    await card.screenshot({ path: `${out}/${name}_card_${keyMode}.png` })
    await p.evaluate(() => localStorage.clear()); await ctx.close(); continue
  }
  await p.waitForFunction(() => { const m = document.querySelector('.q .map:not(.wait)'); return m && [...m.querySelectorAll('img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length >= 4 }, null, { timeout: 25000 }).catch(() => {})
  await p.waitForTimeout(1500)
  const st = await p.evaluate(() => { const m = document.querySelector('.q .map'); return { has: !!m, wait: m && m.classList.contains('wait'), tiles: m ? [...m.querySelectorAll('img')].filter((i) => /googleapis|gstatic/.test(i.src) && i.complete && i.naturalWidth > 0).length : 0, err: !!document.querySelector('.gm-err-container, .gm-err-message'), overflowX: document.documentElement.scrollWidth > innerWidth } })
  ok(`${name}: the map renders with satellite tiles`, st.has && !st.wait && st.tiles >= 4 && !st.err, JSON.stringify(st))
  ok(`${name}: no sideways scroll`, !st.overflowX)
  await card.screenshot({ path: `${out}/${name}_card_empty.png` })
  // tap the map a little right of centre: the pin lands there and the answer is saved
  const box = await card.locator('.map').boundingBox()
  const tx = box.x + box.width * 0.65, ty = box.y + box.height * 0.4
  if (mobile) await p.touchscreen.tap(tx, ty); else await p.mouse.click(tx, ty)
  await p.waitForTimeout(1200)
  const a1 = await p.evaluate((k) => { try { return JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'] || null } catch (e) { return null } }, 'intake-draft-' + TOKEN)
  const t1 = await card.locator('.pin').textContent()
  ok(`${name}: a tap on the map sets the pin and saves it`, a1 && Number.isFinite(a1.lat) && Number.isFinite(a1.lng) && a1.accuracy_m === undefined && /^Pinned at/.test(t1), JSON.stringify(a1) + ' | ' + t1)
  ok(`${name}: the tapped pin is near the property`, a1 && Math.abs(a1.lat - Number(row.latitude)) < 0.002 && Math.abs(a1.lng - Number(row.longitude)) < 0.002)
  await card.screenshot({ path: `${out}/${name}_card_pinned.png` })
  // Use my location moves the pin to the GPS fix
  await card.getByRole('button', { name: /Use my location/ }).click()
  await p.waitForFunction((k) => { try { const v = JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking']; return v && Math.abs(v.lat - 25.80941) < 1e-6 } catch (e) { return false } }, 'intake-draft-' + TOKEN, { timeout: 25000 }).catch(() => {})
  const a2 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
  ok(`${name}: Use my location moves the pin to the GPS fix`, a2 && Math.abs(a2.lat - 25.80941) < 1e-6 && a2.accuracy_m === 7, JSON.stringify(a2))
  // A pin placed by hand while Use my location is still searching wins: the late GPS answer is dropped
  // (the collector may be standing far from the parking spot). The fix is held back and fired after the tap.
  await p.evaluate(() => { window.__late = []; navigator.geolocation.watchPosition = (cb) => { window.__late.push(cb); return 4242 }; navigator.geolocation.clearWatch = () => {} })
  await card.getByRole('button', { name: /Use my location/ }).click()
  await p.waitForTimeout(300)
  const box2 = await card.locator('.map').boundingBox()
  const rx = box2.x + box2.width * 0.3, ry = box2.y + box2.height * 0.6
  if (mobile) await p.touchscreen.tap(rx, ry); else await p.mouse.click(rx, ry)
  await p.waitForTimeout(800)
  const a3 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
  const late = await p.evaluate(() => { window.__late.forEach((cb) => cb({ coords: { latitude: 25.7, longitude: -80.3, accuracy: 5 } })); return window.__late.length })
  await p.waitForTimeout(800)
  const a4 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
  const t4 = await card.textContent()
  ok(`${name}: a GPS answer arriving after a hand-placed pin does not move it`, late === 1 && a3 && a3.accuracy_m === undefined && a4 && a4.lat === a3.lat && a4.lng === a3.lng && !/Finding your spot/.test(t4), JSON.stringify({ late, a3, a4 }))
  // Type an address to move the map (2026-09-27). ADDRESS_SEARCH=blocked while the key does not allow Places API (New):
  // then the box must say so in words and the map must keep working; otherwise a suggestion must move the pin there.
  const box3 = card.locator('.asr input')
  ok(`${name}: the address box is above the map`, await box3.isVisible().catch(() => false))
  await box3.fill('650 NW 33rd St Miami'); await p.waitForTimeout(3500)
  const sug = await card.locator('.asug').count(), hint3 = (await card.locator('.ahint').textContent().catch(() => '')) || ''
  if (process.env.ADDRESS_SEARCH === 'blocked') {
    ok(`${name}: a refused search says so in words`, sug === 0 && /Address search is not available right now\. Move the map by hand\./.test(hint3), hint3)
    await box3.fill(''); await p.waitForTimeout(300)
  } else {
    ok(`${name}: typing an address offers suggestions`, sug >= 1 && sug <= 5, JSON.stringify({ sug, hint3 }))
    if (sug) {
      await card.locator('.asug').first().click(); await p.waitForTimeout(3500)
      const a5 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
      const h5 = (await card.locator('.ahint').textContent()) || ''
      ok(`${name}: picking it puts the pin at that address (then it can be dragged)`, a5 && Math.abs(a5.lat - Number(row.latitude)) < 0.002 && Math.abs(a5.lng - Number(row.longitude)) < 0.002 && a5.accuracy_m === undefined && /Pin placed at that address/.test(h5), JSON.stringify({ a5, h5 }))
    }
    // The far address, picked with Enter, while a "Use my location" search is still running: the pin must MOVE to the
    // address (not stay near 1164), and the late GPS answer must not pull it back (the collector may be far away).
    const before = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
    await p.evaluate(() => { window.__late = []; navigator.geolocation.watchPosition = (cb) => { window.__late.push(cb); return 4343 }; navigator.geolocation.clearWatch = () => {} })
    await card.getByRole('button', { name: /Use my location/ }).click(); await p.waitForTimeout(300)
    await box3.fill('1745 Cleveland Road Miami Beach'); await p.waitForTimeout(3500)
    const sugFar = await card.locator('.asug').count()
    await box3.press('Enter'); await p.waitForTimeout(3500)
    const a6 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
    const late2 = await p.evaluate(() => { window.__late.forEach((cb) => cb({ coords: { latitude: 25.7, longitude: -80.3, accuracy: 5 } })); return window.__late.length })
    await p.waitForTimeout(800)
    const a7 = await p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
    const h7 = (await card.locator('.ahint').textContent()) || '', t7 = await card.textContent()
    const moved = before && a6 && (Math.abs(a6.lat - before.lat) > 0.02 || Math.abs(a6.lng - before.lng) > 0.02)
    const atFar = a6 && Math.abs(a6.lat - Number(far.latitude)) < 0.003 && Math.abs(a6.lng - Number(far.longitude)) < 0.003
    ok(`${name}: Enter picks the first suggestion and MOVES the pin to a far address`, sugFar >= 1 && moved && atFar && a6.accuracy_m === undefined && /Pin placed at that address/.test(h7), JSON.stringify({ sugFar, before, a6, h7 }))
    ok(`${name}: a GPS answer arriving after an address pick does not move the pin`, late2 === 1 && a7 && a6 && a7.lat === a6.lat && a7.lng === a6.lng && !/Finding your spot/.test(t7), JSON.stringify({ late2, a6, a7 }))
    const pin = () => p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}')['site_map.truck_parking'], 'intake-draft-' + TOKEN)
    const near = (a, lat, lng, d) => a && Math.abs(a.lat - Number(lat)) < d && Math.abs(a.lng - Number(lng)) < d
    // (a) typing while a GPS fix redraws the list: the box keeps the focus and the text (the phone keyboard stays)
    await p.evaluate(() => { window.__late = []; navigator.geolocation.watchPosition = (cb) => { window.__late.push(cb); return 4444 }; navigator.geolocation.clearWatch = () => {} })
    await card.getByRole('button', { name: /Use my location/ }).click(); await p.waitForTimeout(400)
    await box3.fill(''); await box3.focus(); await p.keyboard.type('Cle', { delay: 40 })
    await p.evaluate(() => window.__late.forEach((cb) => cb({ coords: { latitude: 25.7, longitude: -80.3, accuracy: 60 } })))
    await p.waitForTimeout(700)
    const foc = await p.evaluate(() => { const a = document.activeElement; return { f: a && a.getAttribute && a.getAttribute('data-f'), v: a && a.value } })
    ok(`${name}: a redraw while typing keeps the focus and the text in the address box`, foc.f && /:addr$/.test(foc.f) && foc.v === 'Cle', JSON.stringify(foc))
    await p.evaluate(() => window.__late.forEach((cb) => cb({ coords: { latitude: 25.7, longitude: -80.3, accuracy: 5 } })))   // the GPS finishes: pin at 25.7, -80.3
    await p.waitForTimeout(800)
    // (b) Escape closes the list and nothing reopens it
    await box3.fill('1745 Cleveland Road Miami Beach'); await p.waitForTimeout(3500)
    const openB = await card.locator('.asug').count()
    await box3.press('Escape'); await p.waitForTimeout(1200)
    ok(`${name}: Escape closes the suggestions`, openB >= 1 && (await card.locator('.asug').count()) === 0, JSON.stringify({ openB }))
    // (c) Enter before any suggestion came back takes the first answer for THAT text
    await box3.fill('650 NW 33rd St Miami'); await box3.press('Enter'); await p.waitForTimeout(4500)
    const c1 = await pin()
    ok(`${name}: Enter pressed before the list appears still places the pin at that address`, near(c1, row.latitude, row.longitude, 0.002) && c1.accuracy_m === undefined, JSON.stringify(c1))
    // (d) Enter with an older list still on screen uses the NEW text, never the old list
    await box3.fill('650 NW 33rd St Miami'); await p.waitForTimeout(3500)
    await box3.fill('1745 Cleveland Road Miami Beach'); await box3.press('Enter'); await p.waitForTimeout(4500)
    const d1 = await pin()
    ok(`${name}: Enter uses the text in the box, not a list left from earlier text`, near(d1, far.latitude, far.longitude, 0.003), JSON.stringify(d1))
    // (e) a slow lookup: Submit waits for it, and a pin tapped meanwhile wins over the late answer
    slowDetails = true
    await box3.fill('650 NW 33rd St Miami'); await p.waitForTimeout(3500)
    await card.locator('.asug').first().click(); await p.waitForTimeout(300)
    const held = await p.evaluate(() => { const b = document.getElementById('send'); return { dis: b.disabled, t: b.textContent } })
    ok(`${name}: Submit waits while an address lookup is running`, held.dis && /Locating/.test(held.t), JSON.stringify(held))
    await card.locator('.map').scrollIntoViewIfNeeded(); await p.waitForTimeout(700)   // the open list pushes the map below the screen
    const mb = await card.locator('.map').boundingBox()
    // away from the pin icon, which sits on the centre (a tap on the icon is not a map tap)
    if (mobile) await p.touchscreen.tap(mb.x + mb.width * 0.3, mb.y + mb.height * 0.35); else await p.mouse.click(mb.x + mb.width * 0.3, mb.y + mb.height * 0.35)
    await p.waitForTimeout(900); const tapped = await pin()
    await p.waitForTimeout(3500); slowDetails = false
    const e1 = await pin(), h8 = (await card.locator('.ahint').textContent()) || ''
    const sendAfter = await p.evaluate(() => { const b = document.getElementById('send'); return { dis: b.disabled, t: b.textContent } })
    ok(`${name}: a pin tapped during a slow lookup stays where it was tapped`, tapped && e1 && !(tapped.lat === d1.lat && tapped.lng === d1.lng) && e1.lat === tapped.lat && e1.lng === tapped.lng && near(e1, far.latitude, far.longitude, 0.003) && !/Pin placed at that address/.test(h8), JSON.stringify({ tapped, e1, h8 }))
    ok(`${name}: Submit is free again after the lookup was cancelled`, !sendAfter.dis && /Submit/.test(sendAfter.t), JSON.stringify(sendAfter))
    if (name === 'phone360') res.push(`INFO  Places calls seen: ${[...placePaths].join(', ')}`)
    await box3.fill(''); await p.waitForTimeout(500)
    ok(`${name}: clearing the box clears the suggestions and the line`, (await card.locator('.asug').count()) === 0 && !((await card.locator('.ahint').textContent()) || '').trim())
  }
  // a render from another answer keeps the same live map (no reload of tiles)
  const same = await p.evaluate(() => { const m1 = document.querySelector('.q .map'); window.__m = m1; return !!m1 })
  await p.locator('.q', { hasText: 'Is there a closed gate?' }).getByRole('button', { name: 'No' }).click()
  await p.waitForTimeout(600)
  ok(`${name}: another answer keeps the same map node`, same && await p.evaluate(() => document.querySelector('.q .map') === window.__m))
  const g = reqs.filter((r) => /google|gstatic/.test(new URL(r.url).host))
  ok(`${name}: no Google request carries the code`, g.length > 0 && !g.some((r) => (r.url + r.body + r.ref).includes(TOKEN)), `${g.length} google requests`)
  if (process.env.ADDRESS_SEARCH !== 'blocked') {
    const pl = g.filter((r) => /places\.googleapis\.com/.test(new URL(r.url).host))
    ok(`${name}: the address search really reached Places API (New), without the code`, pl.length > 0 && !pl.some((r) => (r.url + r.body + r.ref).includes(TOKEN)), `${pl.length} places requests`)
  }
  await p.evaluate(() => localStorage.clear())
  await ctx.close()
}
await b.close()
console.log(`policy ${policy}, key ...${KEY.slice(-4)}`)
console.log(res.join('\n'))
if (res.some((r) => r.startsWith('FAIL'))) { console.log('SOME FAILED'); process.exitCode = 1 } else console.log('ALL PASS')
