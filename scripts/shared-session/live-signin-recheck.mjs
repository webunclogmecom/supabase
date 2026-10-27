// live-signin-recheck.mjs [app ...]: after a SUCCESSFUL email + password sign-in, does each app's gate check again
// without a refresh? (2026-10-27, Trello VXrmwvS3: the HR App stayed on the form until a reload.)
// Every Supabase call is answered locally: the token grant with a fake session, /auth/v1/user with its user,
// hr.get_my_access with employee_id null (a person who is not staff), any other /rest/v1 call with [], logout 204.
// Nothing reaches Supabase except the public signing keys, and no real password is typed. PASS = after Sign in, with no
// reload, the page asks for the user, the access or the signing keys, or leaves the form. CONTROL=hr removes the HR fix
// from its live chunk (must FAIL).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const APPS = {
  hub: 'https://hub.unclogme.app/', hr: 'https://hr.unclogme.app/employees', admin: 'https://admin.unclogme.app/',
  clients: 'https://clients.unclogme.app/', stamp: 'https://stamp.unclogme.app/', derm: 'https://derm.unclogme.app/',
  calendar: 'https://calendar.unclogme.app/', planner: 'https://planner.unclogme.app/',
}
const pick = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(APPS)
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
let bad = 0
for (const app of pick) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } }); const page = await ctx.newPage()
  const order = []; let navs = 0
  const exp = Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000001', mail = 'signin-check@unclogme.com'
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1', amr: [{ method: "password", timestamp: exp - 3600 }] })}.${Buffer.alloc(32, 7).toString("base64url")}`  // a well-formed (fake) signature: a bare "x" made some apps reject the session before any request
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  await page.route('**/auth/v1/authorize**', (r) => r.abort())
  await page.route('**/auth/v1/token**', (r) => { order.push('token'); r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }) }) })
  await page.route('**/auth/v1/user**', (r) => { order.push('user'); r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }) })
  await page.route('**/auth/v1/logout**', (r) => { order.push('logout'); r.fulfill({ status: 204, body: '' }) })
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url()
    if (/rpc\/get_my_access/.test(u)) { order.push('access'); return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ employee_id: null }) }) }
    order.push('rest'); r.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
  })
  await page.route('**/auth/v1/.well-known/**', (r) => { order.push('jwks'); r.continue() })  // public signing keys: the re-check verifying the session
  await page.route('**/functions/v1/**', (r) => { order.push('fn'); r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }) })
  if (process.env.CONTROL === app && app === 'hr') await page.route(/\/assets\/TopBar-[^/]+\.js/, async (r) => { const res = await r.fetch(); r.fulfill({ response: res, body: (await res.text()).replace('(await r(),null)', 'null') }) })
  await page.goto(APPS[app]); await page.waitForTimeout(5000)
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) navs++ })
  const email = page.locator('input[type=email], input[name=email], input[autocomplete=email], input[autocomplete=username]').first()
  const pw = page.locator('input[type=password]').first()
  if (!(await pw.count())) { console.log(`${app.padEnd(9)} SKIP  no sign-in form at ${APPS[app]}`); await ctx.close(); continue }
  const before = order.length
  await email.fill(mail); await pw.fill('canned-not-a-password')
  const btn = page.getByRole('button', { name: /^(sign in|log in)$/i }).first()
  await btn.click().catch(async () => { await pw.press('Enter') })
  await page.waitForTimeout(5000)
  const after = order.slice(before), text = await page.evaluate(() => document.body.innerText)
  // A re-check = a check request after the token (user, access, or the signing keys a signature check fetches),
  // or the sign-in form gone. The fake session cannot pass a SIGNATURE check (it is not signed), so an app that verifies
  // the signature re-checks and then, correctly, treats the visitor as signed out: that still proves the re-check.
  const t = after.indexOf('token'), checks = after.slice(t + 1).filter((x) => ['user', 'access', 'jwks'].includes(x))
  const formGone = (await page.locator('input[type=password]').count()) === 0
  const staffMsg = /not an UnclogMe staff account/i.test(text)
  const ok = t >= 0 && (checks.length > 0 || formGone)
  if (!ok) bad++
  const where = staffMsg ? 'not-staff message' : formGone ? 'left the form: ' + text.replace(/\s+/g, ' ').slice(0, 60) : 'still on the form'
  console.log(`${app.padEnd(9)} ${ok ? 'PASS' : 'FAIL'}  after Sign in: ${after.join(' > ') || '(nothing)'}; reloads ${navs}; ${where}`)
  await ctx.close()
}
await browser.close()
process.exit(bad ? 1 : 0)
