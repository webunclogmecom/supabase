// fill-live.mjs : the collector's half of the FULL-FLOW test (client-intake-flow.md 11.7). Fills the LIVE collector page
// for an open intake on the test client 112-YA, as a phone user, with every question answered, and SUBMITS it.
//   node scripts/intake-collector/tests/fill-live.mjs <intake id> <outdir>
// The intake normally comes from the Client App (Edit property -> Intake Form -> No, schedule it -> Select all ->
// Create link), so the office half is exercised too; a [TEST] fixture from mk-test-intake.sql also works.
// Reads the token from the DB and never prints it. Refuses anything but an OPEN intake on a 112-YA property.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const [id, out = './fill-live'] = [Number(process.argv[2]), process.argv[3]]
fs.mkdirSync(out, { recursive: true })
const [row] = await sql(`select i.token, i.property_id, i.submitted_at, i.cancelled_at, p.client_id from public.property_intakes i join public.properties p on p.id = i.property_id where i.id = ${id}`)
if (!row || row.client_id !== 381 || row.submitted_at || row.cancelled_at) throw new Error('needs an OPEN intake on a 112-YA property (client 381)')
const TOKEN = row.token
const [pr] = await sql(`select address from public.properties where id = ${row.property_id}`)
const ADDR = pr.address   // the truck pin goes to the property's own address first, then a tap adjusts it
const log = []
const say = (m) => { log.push(m); console.log(m.replaceAll(TOKEN, '<token>')) }
// a real, tiny image (the same 1x1 PNG e2e.mjs uploads); the photo path is what is tested, not the picture
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
const IMG = [{ name: 'a.png', mimeType: 'image/png', buffer: PNG }, { name: 'b.png', mimeType: 'image/png', buffer: PNG }]
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, geolocation: { latitude: 25.80712, longitude: -80.20635, accuracy: 6 }, permissions: ['geolocation'] })
const page = await ctx.newPage()
const errs = []; page.on('pageerror', (e) => errs.push(String(e)))
const reqs = []; page.on('request', (r) => reqs.push({ url: r.url(), body: r.postData() || '', ref: r.headers().referer || '' }))
await page.goto('https://planner.unclogme.app/intake#code=' + TOKEN)   // the exact link the Client App hands out (308 to /intake.html)
await page.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0, null, { timeout: 30000 })
say('opened: ' + (await page.locator('h1').first().textContent()) + ' | ' + page.url().replace(/#.*/, '#code=<token>'))
const settle = async (ms = 400) => { await page.waitForTimeout(ms); await page.waitForFunction(() => typeof busy === 'undefined' || busy === 0, null, { timeout: 60000 }) }
const card = async (key) => {
  const i = await page.evaluate((k) => { const req = new Set(F.requested); const ks = []; F.form.sections.forEach((s) => s.questions.forEach((q) => { if (req.has(q.key) && visible(q)) ks.push(q.key) })); return ks.indexOf(k) }, key)
  if (i < 0) throw new Error('question not shown: ' + key)
  const loc = page.locator('.q').nth(i)
  if ((await loc.getAttribute('data-q')) !== key) throw new Error('card mismatch ' + key)
  await loc.scrollIntoViewIfNeeded(); return loc
}
const click = async (k, t) => { await (await card(k)).getByRole('button', { name: t, exact: true }).click(); await settle() }
const text = async (k, v) => { const l = (await card(k)).locator('textarea, input[type=text]').first(); await l.fill(v); await l.press('Tab'); await settle() }
const num = async (k, v) => { const l = (await card(k)).locator('input[type=number]'); await l.fill(String(v)); await l.press('Tab'); await settle() }
// question list version 3 (2026-09-30): every photo needs its explanation, typed in the box drawn under it
const photo = async (k, f) => { const before = await page.evaluate((k) => (Array.isArray(A[k]) ? A[k].length : 0), k); await (await card(k)).locator('input[type=file]:not([capture])').setInputFiles(f); await page.waitForFunction(([k, n]) => busy === 0 && Array.isArray(A[k]) && A[k].length === n + 1, [k, before], { timeout: 60000 }); await (await card(k)).locator('textarea.pcm').nth(before).fill('[TEST] ' + k.split('.').pop() + ', photo ' + (before + 1)); say('photo attached and explained on ' + k) }
const tapMap = async (k, fx, fy) => { const c = await card(k); await c.locator('.map').scrollIntoViewIfNeeded(); await page.waitForTimeout(800); const m = await c.locator('.map').boundingBox(); await page.touchscreen.tap(m.x + m.width * fx, m.y + m.height * fy); await settle(1200) }
const pin = (k) => page.evaluate((k) => A[k] || null, k)

// Site map: the truck spot by address, then a tap to adjust it (the collector may be far from the spot)
const truck = await card('site_map.truck_parking')
await page.waitForFunction(() => !!document.querySelector('.q .asr input'), null, { timeout: 30000 })
await truck.locator('.asr input').fill(ADDR); await page.waitForTimeout(3500)
await truck.locator('.asug').first().click(); await settle(3500)
say('truck pin after the address pick: ' + JSON.stringify(await pin('site_map.truck_parking')) + ' | ' + (await truck.locator('.ahint').textContent()))
await tapMap('site_map.truck_parking', 0.62, 0.62)
say('truck pin after the adjusting tap: ' + JSON.stringify(await pin('site_map.truck_parking')))
// Access and entry
await click('access_entry.gate', 'Yes'); await text('access_entry.gate_code', '4821'); await photo('access_entry.gate_photos', IMG[0])
await click('access_entry.equipment_where', 'Outside'); await click('access_entry.where_outside', 'Back')
await click('access_entry.access_point', 'Side entrance'); await photo('access_entry.access_photos', IMG[1])
await click('access_entry.how_access', 'Lock box'); await text('access_entry.lock_box_code', '7390'); await photo('access_entry.lock_box_photos', IMG[0])
await click('access_entry.alarm', 'No')
await text('access_entry.obstacles', '[TEST] Low tree branch over the driveway. Park on the right side.')
// When we can come: Monday 21:00 to 05:00, then Tuesday to Friday copy Monday's hours
{ const h = await card('access_hours.schedule')
  await h.getByRole('button', { name: 'Mon', exact: true }).click(); await settle()
  await (await card('access_hours.schedule')).getByLabel('Mon opens', { exact: true }).fill('21:00'); await settle()
  await (await card('access_hours.schedule')).getByLabel('Mon closes', { exact: true }).fill('05:00'); await settle()
  for (const d of ['Tue', 'Wed', 'Thu', 'Fri']) { await (await card('access_hours.schedule')).getByRole('button', { name: d, exact: true }).click(); await settle() } }
say('hours: ' + JSON.stringify(await page.evaluate(() => A['access_hours.schedule'])))
// Grease trap
await num('grease_trap.systems_count', 1)
await tapMap('site_map.gt_location', 0.4, 0.45)
say('GT pin: ' + JSON.stringify(await pin('site_map.gt_location')))
await num('grease_trap.cleanouts_count', 2); await num('grease_trap.manhole_count', 1); await photo('grease_trap.photos', IMG[1])
await photo('grease_trap.capacity_photos', IMG[0]); await text('grease_trap.capacity_gallons', '1,000 gal'); await num('grease_trap.sample_ports', 1)
await num('lift_station.count', 0); await num('water_tank.count', 0)
say('counter: ' + (await page.textContent('#cnt')))
await page.screenshot({ path: out + '/collector_filled_top.png' })
await (await card('site_map.gt_location')).screenshot({ path: out + '/collector_gt_pin.png' })
await (await card('access_hours.schedule')).screenshot({ path: out + '/collector_hours.png' })
// Submit
await page.fill('#who', '[TEST] Full flow collector')
await page.click('#send')
const any = page.getByRole('button', { name: 'Submit anyway', exact: true })
if (await any.isVisible({ timeout: 2000 }).catch(() => false)) { say('Submit anyway shown: ' + (await page.textContent('#fmsg')).trim()); await any.click() }
await page.waitForFunction(() => /Thank you|Could not|refused|not valid/i.test(document.getElementById('main').textContent), null, { timeout: 30000 })
say('after submit: ' + (await page.textContent('main')).replace(/\s+/g, ' ').slice(0, 140))
await page.screenshot({ path: out + '/collector_thanks.png' })
const g = reqs.filter((r) => /google|gstatic/.test(new URL(r.url).host))
say(`google requests ${g.length}, carrying the code: ${g.filter((r) => (r.url + r.body + r.ref).includes(TOKEN)).length}; page errors: ${errs.length}`)
await b.close()
fs.writeFileSync(out + '/collector_log.txt', log.join('\n').replaceAll(TOKEN, '<token>'))
const [db] = await sql(`select submitted_at is not null s, collector, (select count(*) from public.photo_links l where l.entity_type='property_intake' and l.entity_id=${id} and l.deleted_at is null) photos, (select intake_status from client.v_property_intake v where v.intake_id=${id}) status from public.property_intakes where id=${id}`)
const pass = db && db.s && db.collector === '[TEST] Full flow collector' && Number(db.photos) === 5 && db.status === 'Complete' && errs.length === 0
console.log(`DB: ${JSON.stringify(db)}`)
console.log(pass ? 'ALL PASS' : 'SOME FAILED'); if (!pass) process.exitCode = 1
