// map-test.mjs : the collector form's pin maps, on the REAL host (planner.unclogme.app), before anything is deployed.
// intake.html is served from the local build and the load reply gets maps_key (+ property lat/lng if missing)
// injected; the key is the Planner's own browser key, read from its public bundle and never printed.
//   node scripts/intake-collector/map-test.mjs <[TEST] intake id> <outdir> [no-referrer|strict-origin] [real|none|bad]
// Loads and pins only (localStorage); it never submits, so the intake stays usable. Refuses a non-[TEST] intake.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [intakeId, out = './mapshots', policy = 'no-referrer', keyMode = 'real'] = process.argv.slice(2)
fs.mkdirSync(out, { recursive: true })
const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
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
let html = fs.readFileSync(new URL('./intake.html', import.meta.url), 'utf8')
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
  // a render from another answer keeps the same live map (no reload of tiles)
  const same = await p.evaluate(() => { const m1 = document.querySelector('.q .map'); window.__m = m1; return !!m1 })
  await p.locator('.q', { hasText: 'Is there a closed gate?' }).getByRole('button', { name: 'No' }).click()
  await p.waitForTimeout(600)
  ok(`${name}: another answer keeps the same map node`, same && await p.evaluate(() => document.querySelector('.q .map') === window.__m))
  const g = reqs.filter((r) => /google|gstatic/.test(new URL(r.url).host))
  ok(`${name}: no Google request carries the code`, g.length > 0 && !g.some((r) => (r.url + r.body + r.ref).includes(TOKEN)), `${g.length} google requests`)
  await p.evaluate(() => localStorage.clear())
  await ctx.close()
}
await b.close()
console.log(`policy ${policy}, key ...${KEY.slice(-4)}`)
console.log(res.join('\n'))
console.log(res.some((r) => r.startsWith('FAIL')) ? 'SOME FAILED' : 'ALL PASS')
