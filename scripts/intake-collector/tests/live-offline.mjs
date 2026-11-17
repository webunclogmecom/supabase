// live-offline.mjs : #220 against the REAL intake-submit (Trello tc1P0loq, Fred 2026-11-17: "if they try to submit the form it
// shows an error like with the internet issue and the form stays with the data"). Two photos are picked, the phone goes
// offline, Submit shows the error and keeps everything; back online, Submit sends the photos and the form, and the database
// holds exactly the two photos (none sent twice). Run it only on a [TEST] intake (scripts/intake-collector/tests/mk-test-intake.sql).
//   node scripts/intake-collector/tests/live-offline.mjs <intake_id> [--live]   (--live = the page from planner.unclogme.app)
// Never prints the token. Clean up after with cleanup.mjs <id>.
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [intakeId, mode] = process.argv.slice(2)
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const [row] = await sql(`select token, requested_by, submitted_at from public.property_intakes where id = ${Number(intakeId)}`)
if (!row || !/^\[TEST\]/.test(row.requested_by) || row.submitted_at) throw new Error('not an unsubmitted [TEST] intake')
const PAGE = 'https://planner.unclogme.app/intake.html'
const html = fs.readFileSync(fileURLToPath(new URL('../intake.html', import.meta.url)), 'utf8')
const NOCONN = 'No connection. Nothing is lost: your answers and photos are saved on this phone. Try again when you have signal.'
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
let pass = 0, fail = 0
const ok = (c, n, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${v === undefined ? '' : '  ' + JSON.stringify(v).slice(0, 240)}`) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
try {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const page = await ctx.newPage()
  if (mode !== '--live') await page.route(PAGE, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html }))
  await page.goto(PAGE + '#code=' + row.token)
  await page.waitForSelector('[data-q="access_entry.access_point"]', { timeout: 20000 })
  ok(true, mode === '--live' ? 'the LIVE page loads' : 'the local build loads at the real address')
  await page.locator('[data-q="access_entry.access_point"] button').first().click()
  const AP = 'access_entry.access_photos'
  await page.locator(`[data-q="${AP}"] input[type=file]:not([capture])`).setInputFiles([{ name: 'a.png', mimeType: 'image/png', buffer: png }, { name: 'b.png', mimeType: 'image/png', buffer: png }])
  await page.waitForFunction(() => busy === 0, null, { timeout: 15000 })
  for (const t of await page.locator(`[data-q="${AP}"] textarea.pcm`).all()) await t.fill('[TEST] offline check')
  await page.fill('#who', '[TEST] offline check')
  const [{ links: before }] = await sql(`select count(*)::int as links from public.photo_links where entity_type = 'property_intake' and entity_id = ${Number(intakeId)} and deleted_at is null`)
  ok(before === 0, 'two photos picked: none has reached the database', before)
  const submit = async () => {
    await page.click('#send'); await page.waitForTimeout(400)
    const go = page.locator('.cf .go', { hasText: 'Submit anyway' }); if (await go.count()) await go.click()
    await page.waitForFunction(() => !SENDING, null, { timeout: 60000 }).catch(() => {}); await page.waitForTimeout(500)
  }
  await ctx.setOffline(true)
  await submit()
  const msgs = await page.evaluate(() => [...document.querySelectorAll('.err span')].map((e) => e.textContent))
  ok(msgs.includes(NOCONN), 'offline: Submit says nothing is lost', msgs)
  const states = await page.$$eval(`[data-q="${AP}"] .st`, (es) => es.map((e) => e.textContent))
  ok(states.length === 2 && states.every((t) => t === 'Saved on this phone'), 'offline: both photos still on the phone', states)
  await ctx.setOffline(false)
  await submit()
  const done = await page.evaluate(() => (document.querySelector('.big h2') || {}).textContent)
  ok(done === 'Thank you', 'back online: Submit sends everything', done)
  const [db] = await sql(`select i.submitted_at is not null as submitted, i.collector,
      (select count(*)::int from public.photo_links l where l.entity_type = 'property_intake' and l.entity_id = i.id and l.deleted_at is null) as links,
      (select count(*)::int from public.property_intake_uploads u where u.intake_id = i.id) as slots
    from public.property_intakes i where i.id = ${Number(intakeId)}`)
  ok(db && db.submitted && db.links === 2 && db.slots === 2, 'the database holds the form and exactly two photos, two upload slots (none sent twice)', db)
} catch (e) { ok(false, 'threw', String(e)) } finally { await browser.close() }
console.log(`\nlive-offline: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
