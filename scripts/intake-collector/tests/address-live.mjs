// address-live.mjs : the collector's address box end to end on the LIVE page, through to the database.
// Opens planner.unclogme.app/intake.html#code=<token> exactly as a collector would (the real load reply, the real
// Maps key from the edge secret, the page's own no-referrer policy), types a far address (112-YA property 162) in the
// "Truck parking spot" box, picks the first suggestion, submits, and reads the stored pin back from property_intakes.
//   node scripts/intake-collector/tests/address-live.mjs <[TEST] intake id>
// SUBMITS the intake (it uses up the fixture). Refuses a non-[TEST] intake. Never prints the token.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const id = Number(process.argv[2])
const [row] = await sql(`select token, requested_by, submitted_at from public.property_intakes where id = ${id}`)
if (!row || !/^\[TEST\]/.test(row.requested_by) || row.submitted_at) throw new Error('needs an open [TEST] intake')
const [far] = await sql(`select latitude, longitude from public.properties where id = 162`)
const TOKEN = row.token
const res = []
const ok = (n, c, x = '') => res.push(`${c ? 'PASS' : 'FAIL'}  ${n}${x ? '  ' + String(x).replaceAll(TOKEN, '<token>') : ''}`)
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true })
const page = await ctx.newPage()
const reqs = []
page.on('request', (r) => reqs.push({ url: r.url(), body: r.postData() || '', ref: r.headers().referer || '' }))
await page.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN)
await page.waitForFunction(() => document.getElementById('sub').textContent !== 'Loading...', null, { timeout: 20000 })
const card = page.locator('.q', { hasText: 'Truck parking spot' })
await card.scrollIntoViewIfNeeded()
await page.waitForFunction(() => !!document.querySelector('.q .asr input'), null, { timeout: 25000 }).catch(() => {})
const box = card.locator('.asr input')
ok('the live page shows the address box above the map', await box.isVisible().catch(() => false))
await box.fill('1745 Cleveland Road Miami Beach'); await page.waitForTimeout(4000)
const n = await card.locator('.asug').count()
ok('Google answers with suggestions on the live page', n >= 1 && n <= 5, n)
await card.locator('.asug').first().click(); await page.waitForTimeout(4000)
const hint = (await card.locator('.ahint').textContent()) || ''
const pinTxt = (await card.locator('.pin').textContent()) || ''
ok('the pin is placed at the address', /Pin placed at that address/.test(hint) && /^Pinned at 25\.86/.test(pinTxt), `${hint} | ${pinTxt}`)
await page.fill('#who', '[TEST] collector (address box)')
await page.click('#send')
await page.getByRole('button', { name: 'Submit anyway' }).click().catch(() => {})
await page.waitForFunction(() => /Thank you|Could not|refused|not valid/i.test(document.getElementById('main').textContent), null, { timeout: 20000 })
ok('submit lands on the thank-you screen', /Thank you/.test(await page.textContent('main')))
const g = reqs.filter((r) => /google|gstatic/.test(new URL(r.url).host))
const pl = g.filter((r) => /places\.googleapis\.com/.test(new URL(r.url).host))
ok('no Google request carries the code (Places calls included)', pl.length > 0 && !g.some((r) => (r.url + r.body + r.ref).includes(TOKEN)), `${g.length} google, ${pl.length} places`)
await b.close()
const [db] = await sql(`select submitted_at is not null as submitted, answers->'site_map.truck_parking' as pin from public.property_intakes where id = ${id}`)
const p = db && db.pin && (db.pin.value || db.pin)   // answers are stored as {value: ...}
ok('DB: the submitted pin is the picked address, with no GPS accuracy', db && db.submitted && p && Math.abs(p.lat - Number(far.latitude)) < 0.003 && Math.abs(p.lng - Number(far.longitude)) < 0.003 && p.accuracy_m === undefined, JSON.stringify(db))
console.log(res.join('\n'))
if (res.some((r) => r.startsWith('FAIL'))) { console.log('SOME FAILED'); process.exitCode = 1 } else console.log('ALL PASS')
