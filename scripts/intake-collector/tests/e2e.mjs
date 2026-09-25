// End-to-end test of intake.html against the REAL intake-submit, from the planner origin.
// node collector-test.mjs <intake_id> [--live]   (--live = load the page from planner.unclogme.app instead of the local file)
// Never prints the token. Submits the [TEST] intake, so run it only on a [TEST] fixture.
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [intakeId, mode] = process.argv.slice(2)
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
async function sql(q) {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })
  return r.json()
}
const [row] = await sql(`select token, requested_by from public.property_intakes where id = ${Number(intakeId)}`)
if (!row || !/^\[TEST\]/.test(row.requested_by)) throw new Error('not a [TEST] intake')
const token = row.token
const PAGE = 'https://planner.unclogme.app/intake.html'
const html = fs.readFileSync(fileURLToPath(new URL('../intake.html', import.meta.url)), 'utf8')
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const results = []
const ok = (name, cond, extra = '') => { results.push(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`) }

async function open(fragment) {
  const ctx = await browser.newContext({ geolocation: { latitude: 25.80941, longitude: -80.20511, accuracy: 7 }, permissions: ['geolocation'], viewport: { width: 390, height: 844 } })
  const page = await ctx.newPage()
  const reqs = []
  page.on('request', (r) => reqs.push(r.url()))
  if (mode !== '--live') await page.route(PAGE, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html }))
  await page.goto(PAGE + fragment)
  return { ctx, page, reqs }
}

// 1. no token / garbage token: a plain sentence, no form
for (const [label, frag] of [['no token', ''], ['garbage token', '#code=abc']]) {
  const { ctx, page } = await open(frag)
  await page.waitForTimeout(2500)
  const t = await page.textContent('main')
  ok(`${label} shows "This link is not valid."`, /This link is not valid\./.test(t), JSON.stringify(t.slice(0, 60)))
  await ctx.close()
}

// 2. the real [TEST] link
const { ctx, page, reqs } = mode === '--live' ? await (async () => { const o = await open(''); await o.page.goto('https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit?t=' + token); ok('the office link redirects to the live page', o.page.url().startsWith(PAGE + '#code='), o.page.url().split('#')[0]); return o })() : await open('#code=' + token)
await page.waitForFunction(() => document.getElementById('sub').textContent !== 'Loading...', null, { timeout: 15000 })
ok('header shows the property address', /650 Northwest 33rd Street/.test(await page.textContent('#ttl')), await page.textContent('#ttl'))
const labels0 = await page.$$eval('.q>label', (ls) => ls.map((l) => l.textContent))
ok('initial questions render (15 top-level, follow-ups hidden)', labels0.length === 15, String(labels0.length))
ok('a follow-up is hidden before its parent is answered', !labels0.includes('What is the gate code or key?'))
// answer the gate: Yes -> the two gate follow-ups appear
const gateQ = page.locator('.q', { hasText: 'Is there a closed gate?' })
await gateQ.getByRole('button', { name: 'Yes' }).click()
const labels1 = await page.$$eval('.q>label', (ls) => ls.map((l) => l.textContent))
ok('Yes on the gate shows its two follow-ups', labels1.includes('What is the gate code or key?') && labels1.includes('Photos of the gate or entrance'), String(labels1.length))
await page.locator('.q', { hasText: 'What is the gate code or key?' }).locator('textarea, input').first().fill('[TEST] 1234')
await page.locator('.q', { hasText: 'What is the gate code or key?' }).locator('textarea, input').first().blur()
// a number that opens the grease-trap follow-ups
const sys = page.locator('.q', { hasText: 'How many grease trap systems?' }).locator('input')
await sys.fill('1'); await sys.dispatchEvent('change')
await page.waitForFunction(() => [...document.querySelectorAll('.q>label')].some((l) => /Grease trap location/.test(l.textContent)), null, { timeout: 5000 }).catch(() => {})
const labels2 = await page.$$eval('.q>label', (ls) => ls.map((l) => l.textContent))
ok('systems_count 1 shows the grease trap follow-ups', labels2.some((l) => /Grease trap location/.test(l)) && labels2.some((l) => /Total capacity in gallons/.test(l)))
// a photo on the gate photos question (1x1 PNG)
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
await page.locator('.q', { hasText: 'Photos of the gate or entrance' }).locator('input[type=file]').setInputFiles({ name: 'gate.png', mimeType: 'image/png', buffer: png })
await page.waitForFunction(() => !/uploading/.test(document.getElementById('cnt').textContent), null, { timeout: 30000 })
const photoNote = await page.locator('.q', { hasText: 'Photos of the gate or entrance' }).locator('.note').textContent()
const errBoxes = await page.$$eval('.err', (e) => e.map((x) => x.textContent))
ok('the photo uploads and attaches', /1 photo attached/.test(photoNote), photoNote + (errBoxes.length ? ' | ' + errBoxes.join(' | ') : ''))
// GPS pin on truck parking
await page.locator('.q', { hasText: 'Truck parking spot' }).getByRole('button', { name: 'Use my location' }).click()
await page.waitForTimeout(1500)
const pin = await page.locator('.q', { hasText: 'Truck parking spot' }).locator('.pin').textContent()
ok('Use my location pins the truck spot', /Pinned at 25\.80941/.test(pin), pin)
// submit without a name is refused in words, then with a name
await page.click('#send')
ok('submit without a name asks for it', (await page.$$eval('.err', (e) => e.map((x) => x.textContent))).some((t) => /Put your name/.test(t)))
await page.fill('#who', '[TEST] collector')
await page.click('#send')
// a partial form asks first (in the page), because a submitted form cannot be changed
const cf = page.getByRole('button', { name: 'Submit anyway' })
ok('a partial submit asks "Submit anyway" first', await cf.isVisible().catch(() => false), (await page.textContent('#fmsg')).slice(0, 90))
await cf.click()
await page.waitForFunction(() => /Thank you|Could not|refused|not valid/i.test(document.getElementById('main').textContent), null, { timeout: 20000 })
const done = await page.textContent('main')
ok('submit lands on the thank-you screen', /Thank you/.test(done), JSON.stringify(done.slice(0, 120)))
// architecture: the page talks only to intake-submit and storage uploads, never to PostgREST or Auth
const bad = reqs.filter((u) => /supabase\.co\/(rest|auth)\/v1\//.test(u))
const other = [...new Set(reqs.map((u) => new URL(u).host))]
ok('zero requests to /rest/v1 or /auth/v1', bad.length === 0, 'hosts: ' + other.join(', '))
await ctx.close()

// 3. the same link after submit: "Already submitted"
{ const { ctx: c2, page: p2 } = await open('#code=' + token)
  await p2.waitForTimeout(3000)
  ok('reopening after submit says Already submitted', /Already submitted/.test(await p2.textContent('main')))
  await c2.close() }
await browser.close()

// 4. what the database holds
const [db] = await sql(`select submitted_at is not null as submitted, collector, answers ? 'access_entry.gate' as has_gate, answers ? 'access_entry.gate_code' as has_code,
  answers ? 'site_map.truck_parking' as has_pin, jsonb_typeof(answers->'access_entry.gate_photos') as photos_kind,
  (select count(*) from public.photo_links l where l.entity_type = 'property_intake' and l.entity_id = ${Number(intakeId)} and l.deleted_at is null) as links
  from public.property_intakes where id = ${Number(intakeId)}`)
ok('DB: submitted, collector, gate + code + pin stored, one photo link', db.submitted && db.collector === '[TEST] collector' && db.has_gate && db.has_code && db.has_pin && Number(db.links) === 1, JSON.stringify(db))
console.log(results.join('\n'))
console.log(results.every((r) => r.startsWith('PASS')) ? 'ALL PASS' : 'FAILURES')
