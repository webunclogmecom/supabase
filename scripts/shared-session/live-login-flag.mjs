// live-login-flag.mjs: does each app's REAL login screen record the Remember me choice where the shared
// module reads it? No credentials: the Google redirect is blocked before it leaves the app.
//
//   node live-login-flag.mjs [app ...]      default: all eight
//
// For each app, twice (box unticked, box ticked), in a fresh isolated Chrome with no session:
//   open the app (signed out, so the login shows), set the "Remember me" box, click "Continue with
//   Google", abort the request to /auth/v1/authorize, then read the cookies the page wrote.
// PASS when the shared choice cookie `unclogme-remember-me` on .unclogme.app says exactly what the box
// said, as a SESSION cookie when unticked and a persistent one when ticked. That is only true if the
// login calls the canonical setRememberMe before signInWithOAuth.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const APPS = { hub: 'hub.unclogme.app', admin: 'admin.unclogme.app', clients: 'clients.unclogme.app', stamp: 'stamp.unclogme.app',
  derm: 'derm.unclogme.app', calendar: 'calendar.unclogme.app', hr: 'hr.unclogme.app', planner: 'planner.unclogme.app' }

async function run(browser, host, want) {
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  let authorize = false
  await page.route('**/auth/v1/authorize**', (r) => { authorize = true; r.abort() })
  await page.route('https://accounts.google.com/**', (r) => r.abort())
  await page.goto(`https://${host}/`, { waitUntil: 'domcontentloaded' })
  const google = page.getByRole('button', { name: /continue with google/i })
  await google.waitFor({ timeout: 20000 })
  // the box, whatever it is built from: a native input or a Radix button, found through its label
  const box = page.getByLabel(/remember me/i).first()
  let checked = null
  for (let i = 0; i < 3; i++) {
    checked = await box.evaluate((el) => el.matches('input') ? el.checked : el.getAttribute('aria-checked') === 'true' || el.getAttribute('data-state') === 'checked').catch(() => null)
    if (checked === null || checked === want) break
    await page.getByText(/^remember me$/i).first().click().catch(() => box.click({ force: true }))
    await page.waitForTimeout(200)
  }
  await google.click()
  for (let i = 0; i < 30 && !authorize; i++) await page.waitForTimeout(200)
  await page.waitForTimeout(500)
  const flag = (await ctx.cookies()).filter((c) => c.name === 'unclogme-remember-me')
  await ctx.close()
  const c = flag[0]
  const ok = checked === want && flag.length === 1 && c.domain === '.unclogme.app' && c.value === String(want)
    && (want ? c.expires > Date.now() / 1000 + 300 * 86400 : c.expires === -1)
  return { ok, detail: `box=${checked} redirect=${authorize} cookie=${c ? `${c.value} ${c.domain} ${c.expires === -1 ? 'session' : Math.round((c.expires - Date.now() / 1000) / 86400) + 'd'}` : 'none'}` }
}

const want = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(APPS)
const browser = await chromium.launch({ executablePath: process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
for (const app of want) {
  for (const remember of [false, true]) {
    let r
    try { r = await run(browser, APPS[app], remember) } catch (e) { r = { ok: false, detail: 'error: ' + e.message.split('\n')[0] } }
    if (!r.ok) bad++
    console.log(`${app.padEnd(9)} ${remember ? 'ticked  ' : 'unticked'} ${r.ok ? 'PASS' : 'FAIL'}  ${r.detail}`)
  }
}
await browser.close()
process.exit(bad ? 1 : 0)
