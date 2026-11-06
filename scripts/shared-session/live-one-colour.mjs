// live-one-colour.mjs: Fred's test, as a standing check (2026-11-06). His words: "If I want that to be changed from gray
// to blue, I need you to all the apps that has been merged to the secondary color to also be blue."
// On each app's page in the Ops Portal it changes the primary and the secondary colour ONCE, in the one shared place, and
// counts the buttons. PASS = every orange main button turned blue and every second-rank button turned purple, in every app.
// Before the one-app work this was 0 of 7. Canned replies, no password, nothing reaches Supabase.
// PORTAL=http://localhost:8080/ runs it before a publish. CONTROL=1 makes no change: every page must then FAIL, or this
// check cannot fail.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PORTAL = process.env.PORTAL || 'https://ops.unclogme.app/'
const control = Boolean(process.env.CONTROL)
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const access = { employee_id: 2, group: 'admin', me: { full_name: 'Test Person', color_hex: '#f14714', photo_path: null }, apps: TOP.map((a) => ({ app: a, parent: null, mode: 'on', level: 'edit' })) }
const PAGES = [['HR', 'hr/employees'], ['Calendar', 'calendar'], ['DERM', 'derm'], ['DERM upload', 'derm/upload'], ['Stamp', 'stamp']]

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const page = await ctx.newPage()
const exp = Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000002', mail = 'someone@unclogme.com'
const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.from('x'.repeat(32)).toString('base64url')}`
const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email' }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' }
const json = (r, body, status = 200) => r.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
await page.route('**/auth/v1/.well-known/**', (r) => json(r, { keys: [] }))
await page.route('**/auth/v1/token**', (r) => json(r, { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }))
await page.route('**/auth/v1/user**', (r) => json(r, user))
await page.route('**/functions/v1/**', (r) => json(r, {}))
await page.route('**/storage/v1/**', (r) => json(r, {}))
await page.route('**/rest/v1/**', (r) => {
  const u = r.request().url()
  if (/rpc\/get_my_access/.test(u)) return json(r, access)
  if (/rpc\/portal_waiting/.test(u)) return json(r, {})
  return json(r, (r.request().headers().accept || '').includes('vnd.pgrst.object') ? {} : [])
})
await page.goto(PORTAL); await page.waitForSelector('input[type=email]', { timeout: 30000 })
await page.locator('input[type=email]').fill(mail); await page.locator('input[type=password]').fill('canned-not-a-password')
await page.getByRole('button', { name: /^sign in$/i }).click()
await page.waitForTimeout(2000)

const count = () => page.evaluate(() => {
  const rgb = (c) => { const m = String(c).match(/(\d+(?:\.\d+)?)[ ,]+(\d+(?:\.\d+)?)[ ,]+(\d+(?:\.\d+)?)/); return m ? m.slice(1, 4).map(Number) : null }
  const near = (a, b) => a && Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]) < 30
  const res = { orange: 0, blue: 0, white: 0, purple: 0 }
  const paint = document.createElement('div'); document.body.appendChild(paint)
  const solid = (c) => { paint.style.backgroundColor = ''; paint.style.backgroundColor = c; return rgb(getComputedStyle(paint).backgroundColor) }
  // A select is a field you fill in, like an input, so it stays with the card colour.
  for (const e of document.querySelectorAll('main button:not([role=combobox])')) {
    const r = e.getBoundingClientRect(); if (r.width < 8 || r.height < 8) continue
    const cs = getComputedStyle(e); if (/^rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor)) continue
    const bg = rgb(cs.backgroundColor) ?? solid(cs.backgroundColor)
    if (near(bg, [241, 71, 20])) res.orange++
    else if (near(bg, [37, 99, 235])) res.blue++
    else if (near(bg, [124, 58, 237])) res.purple++
    else if (bg && bg[0] === 255 && bg[1] === 255 && bg[2] === 255 && parseFloat(cs.borderTopWidth) > 0) res.white++
  }
  paint.remove()
  return res
})
let bad = 0
for (const [name, addr] of PAGES) {
  await page.goto(PORTAL + addr, { waitUntil: 'domcontentloaded' }); await page.waitForTimeout(5000)
  const before = await count()
  if (!control) await page.addStyleTag({ content: ':root { --primary: #2563eb; --secondary: #7c3aed; }' })
  await page.waitForTimeout(400)
  const after = await count()
  const fails = []
  // A page with no button to look at proves nothing, so it fails rather than passes.
  if (before.orange + before.white === 0) fails.push('no main or second-rank button found')
  if (after.orange) fails.push(`${after.orange} of ${before.orange} main buttons stayed orange`)
  if (after.blue < before.orange) fails.push(`${after.blue} of ${before.orange} main buttons turned blue`)
  if (after.white) fails.push(`${after.white} of ${before.white} second-rank buttons stayed white`)
  if (after.purple < before.white) fails.push(`${after.purple} of ${before.white} second-rank buttons turned purple`)
  if (fails.length) bad++
  console.log(`${name.padEnd(12)} main ${before.orange} to blue ${after.blue}, second ${before.white} to purple ${after.purple}  ${fails.length ? 'FAIL  ' + fails.join('; ') : 'PASS'}`)
}
await browser.close()
console.log(bad ? `${bad} FAILED` : 'all follow')
process.exitCode = control ? (bad === PAGES.length ? 0 : 1) : bad ? 1 : 0
