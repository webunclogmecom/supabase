// v6-live.mjs <intake id> : question list version 6 on the LIVE collector form and the REAL server (2026-10-23, Fred: "if
// there are more Grease Traps then it should ask for each of them like the measurements or the brand of each"). Three
// traps are counted, each trap's questions appear (and trap 4's do not), trap 1 gets typed Gallons, trap 2 a model, trap 3
// measurements, trap 2 a pin; the form is submitted; then the AI lookups land and the Property record tab's compare OFFERS
// the TOTAL of the three traps (read as Fred). Nothing is ever saved to the property. Refuses anything but an OPEN version 6
// intake whose requested_by starts with "[TEST]" on property 1164 or 162 (the test client 112-YA). Reads the token from
// the DB and never prints it. SUBMITS the intake; remove it with the per-id recipe of Building Apps/docs/client-intake-flow.md
// 11.3 step 5 (the lookup rows stay: reference data about a real model and those measurements).
//   node scripts/intake-collector/tests/v6-live.mjs <intake id>
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const id = Number(process.argv[2]), MODEL = 'Schier GB-75', MEASURE = '24 x 24 x 30 inches', TYPED = '1,000'
const [row] = await sql(`select token, property_id, requested_by, submitted_at, cancelled_at, form_snapshot ->> 'version' as v from public.property_intakes where id = ${id}`)
if (!row || !/^\[TEST\]/.test(row.requested_by || '') || ![1164, 162].includes(Number(row.property_id)) || row.submitted_at || row.cancelled_at || row.v !== '6') throw new Error('needs an OPEN version 6 [TEST] intake on 1164 or 162')
const TOKEN = row.token
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v)).replaceAll(TOKEN, '<token>').slice(0, 500)}`) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true,
  geolocation: { latitude: 25.80941, longitude: -80.20511, accuracy: 5 }, permissions: ['geolocation'] })
const page = await ctx.newPage()
const errors = []; page.on('pageerror', (e) => errors.push(String(e)))
await page.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN)
await page.waitForSelector('[data-q="grease_trap.systems_count"]', { timeout: 30000 })
const shown = (k) => page.locator(`[data-q="${k}"]`).isVisible().catch(() => false)
ok(!(await shown('grease_trap.t2.size_from')), 'before a trap is counted, trap 2 is hidden')
const plus = page.locator('[data-q="grease_trap.systems_count"]').getByRole('button', { name: 'One more' })
for (let i = 0; i < 3; i++) { await plus.click(); await page.waitForTimeout(250) }
for (const n of [2, 3]) {
  ok(await shown(`grease_trap.t${n}.location`) && await shown(`grease_trap.t${n}.size_from`) && await shown(`grease_trap.t${n}.capacity_gallons`), `three traps: trap ${n} location, size choice and gallons show`)
}
ok(!(await shown('grease_trap.t4.size_from')) && !(await shown('grease_trap.t4.location')), 'three traps: trap 4 stays hidden')
const c2 = page.locator('[data-q="grease_trap.t2.size_from"]')
ok((await c2.textContent()).includes('Grease trap 2: how can you give us its size?'), 'trap 2 is named in its question')
ok((await page.locator('[data-q="site_map.gt_location"]').textContent()).includes('Grease trap location'), 'trap 1 keeps its label')
const g1 = page.locator('[data-f="grease_trap.capacity_gallons"]').first()
await g1.fill(TYPED); await g1.dispatchEvent('input')
await c2.getByRole('button', { name: 'Model on the plate' }).click(); await page.waitForTimeout(250)
ok(await shown('grease_trap.t2.model') && !(await shown('grease_trap.t2.capacity_measure')), 'trap 2 Model on the plate: its model box only')
const m2 = page.locator('[data-f="grease_trap.t2.model"]').first(); await m2.fill(MODEL); await m2.dispatchEvent('input')
await page.locator('[data-q="grease_trap.t3.size_from"]').getByRole('button', { name: 'Measurements' }).click(); await page.waitForTimeout(250)
ok(await shown('grease_trap.t3.capacity_measure') && !(await shown('grease_trap.t3.model')), 'trap 3 Measurements: its measurements box only')
const m3 = page.locator('[data-f="grease_trap.t3.capacity_measure"]').first(); await m3.fill(MEASURE); await m3.dispatchEvent('input')
await page.locator('[data-f="grease_trap.t2.location:gps"]').click()
await page.waitForFunction(() => /Pinned at 25\.80941/.test(document.querySelector('[data-q="grease_trap.t2.location"]')?.textContent || ''), null, { timeout: 25000 }).catch(() => {})
ok(/Pinned at 25\.80941/.test(await page.locator('[data-q="grease_trap.t2.location"]').textContent()), 'trap 2 location: Use my location pins it')
ok(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), '390 wide: no sideways scroll')
await page.locator('[data-q="grease_trap.t2.location"]').scrollIntoViewIfNeeded(); await page.screenshot({ path: (process.env.OUT || '.') + `/v6_live_${id}_trap2.png` }).catch(() => {})
await page.locator('[data-q="grease_trap.t3.size_from"]').scrollIntoViewIfNeeded(); await page.screenshot({ path: (process.env.OUT || '.') + `/v6_live_${id}_trap3.png` }).catch(() => {})
await page.fill('#who', '[TEST] v6 live')
await page.click('#send')
const cf = page.getByRole('button', { name: 'Submit anyway' })
if (await cf.isVisible().catch(() => false)) await cf.click()
await page.waitForFunction(() => /Thank you|Could not|refused|not valid/i.test(document.getElementById('main').textContent), null, { timeout: 20000 }).catch(() => {})
ok(/Thank you/.test(await page.textContent('main')), 'submitted: the thank-you screen')
ok(errors.length === 0, 'no page errors', errors)
await browser.close()
const [s] = await sql(`select submitted_at is not null as done, answers -> 'grease_trap.systems_count' ->> 'value' as n, answers -> 'grease_trap.capacity_gallons' ->> 'value' as g1,
  answers -> 'grease_trap.t2.model' ->> 'value' as m2, answers -> 'grease_trap.t3.capacity_measure' ->> 'value' as m3, answers -> 'grease_trap.t2.location' -> 'value' -> 'lat' as lat2 from public.property_intakes where id = ${id}`)
ok(s && s.done && String(s.n) === '3' && s.g1 === TYPED && s.m2 === MODEL && s.m3 === MEASURE && Number(s.lat2) > 25.8, 'the stored answers: 3 traps, trap 1 gallons, trap 2 model and pin, trap 3 measurements', s)
// the trigger asked for the lookups at submit (a model already looked up is reused; the measurements take up to a minute)
let L = []
for (let i = 0; i < 18 && !(L.length === 2 && L.every((x) => x.status && x.status !== 'error')); i++) {
  await new Promise((r) => setTimeout(r, 10000))
  L = await sql(`select g.kind, g.status, g.gallons from public.fn_intake_size_inputs(${id}) x join public.grease_trap_size_lookups g on g.kind = x.kind and g.input_key = x.input_key`)
}
ok(L.length === 2 && L.every((x) => ['found', 'not_found'].includes(x.status)), 'both AI lookups (trap 2 model, trap 3 measurements) answered on their own after the submit', L)
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_intake(${id}) -> 'size_lookups' as sl, (select f from jsonb_array_elements(client.get_intake_compare(${id}) -> 'fields') f where f ->> 'key' = 'grease_trap.capacity_gallons') as g;`)
const x = r[r.length - 1]
ok(x.sl && x.sl.length === 2 && x.sl.some((l) => l.key === 'grease_trap.t2.model') && x.sl.some((l) => l.key === 'grease_trap.t3.capacity_measure'), 'get_intake shows each lookup under its own trap', x.sl)
const found = L.every((l) => l.status === 'found')
const total = found ? 1000 + L.reduce((a, l) => a + l.gallons, 0) : null
ok(x.g && x.g.offer && x.g.offer.kind === 'traps' && x.g.offer.traps.length === 3 && (found ? x.g.theirs === total : x.g.state === 'not_savable'),
  found ? `the Property record tab offers the total of the three traps (${total})` : 'a trap without a number: no total offered', x.g)
const [acc] = await sql(`select count(*)::int as n from public.property_intake_accepts where intake_id = ${id}`)
ok(acc.n === 0, 'nothing was saved to the property')
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
