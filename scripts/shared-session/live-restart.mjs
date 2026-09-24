// live-restart.mjs: the Remember-me restart test against the REAL deployed apps, with no credentials.
//
//   node live-restart.mjs [app ...]        default: all eight
//
// For each app, in a fresh browser that never held a real session, it recreates the exact state a
// user is in after quitting the browser with Remember me UNTICKED:
//   - the shared Remember-me choice cookie says "false" (it is a 400-day cookie, so it survives);
//   - the session cookie is GONE (it was a session cookie);
//   - this origin's localStorage still holds a session copy (what the old modules left behind).
// The planted session is a harmless fake: its tokens carry the marker PLANTED and are not valid
// anywhere. Planting happens on an intercepted blank page, so no app code runs while it is set up.
// Then it loads the real app and records every request to /auth/v1/. If the module hands the planted
// session to supabase-js, supabase-js uses it (a /user call with the planted bearer, or a refresh with
// the planted refresh token). A correct module returns nothing, so no planted token leaves the page.
//
// Three cases per app:
//   OFF      remember=false, localStorage copy, no cookie -> MUST NOT use the planted session (the fix)
//   ON       remember=true,  localStorage copy, no cookie -> the control: the module is allowed (by
//            design) to fall back to this origin's copy, so the planted token MUST be seen. If it is
//            not, this app never touches auth on load and the OFF result proves nothing.
//   COOKIE   remember=false, planted SESSION cookie on .unclogme.app -> MUST be used (SSO still reads
//            the shared cookie).
// Exit 1 if any OFF or COOKIE case fails, or any control is blind.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')

const APPS = { hub: 'hub.unclogme.app', admin: 'admin.unclogme.app', clients: 'clients.unclogme.app', stamp: 'stamp.unclogme.app',
  derm: 'derm.unclogme.app', calendar: 'calendar.unclogme.app', hr: 'hr.unclogme.app', planner: 'planner.unclogme.app' }
const KEY = 'sb-wbasvhvvismukaqdnouk-auth-token'
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3000
const AT = `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ sub: '00000000-0000-4000-8000-00000000abcd', email: 'planted@unclogme.com', exp, aud: 'authenticated', role: 'authenticated', planted: 'PLANTED' })}.PLANTEDsig`
const SESSION = JSON.stringify({ access_token: AT, token_type: 'bearer', expires_in: 3000, expires_at: exp, refresh_token: 'PLANTEDrefresh' })
const USER = JSON.stringify({ user: { id: '00000000-0000-4000-8000-00000000abcd', email: 'planted@unclogme.com', aud: 'authenticated', role: 'authenticated' } })

async function runCase(browser, host, kind) {
  const ctx = await browser.newContext()
  const now = Math.floor(Date.now() / 1000)
  await ctx.addCookies([{ name: 'unclogme-remember-me', value: kind === 'ON' ? 'true' : 'false', domain: '.unclogme.app', path: '/', expires: now + 400 * 86400, secure: true, sameSite: 'Lax' }])
  if (kind === 'COOKIE') await ctx.addCookies([{ name: KEY, value: encodeURIComponent(SESSION), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }]) // session cookie
  const page = await ctx.newPage()
  // plant on a blank page served for this origin: no app code runs
  await page.route(`https://${host}/__plant`, (r) => r.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>plant</title>' }))
  await page.goto(`https://${host}/__plant`)
  await page.evaluate(([k, s, u, kind]) => {
    localStorage.setItem('unclogme-remember-me', kind === 'ON' ? 'true' : 'false')
    if (kind !== 'COOKIE') { localStorage.setItem(k, s); localStorage.setItem(k + '-user', u) }
  }, [KEY, SESSION, USER, kind])
  const hits = []
  page.on('request', (req) => {
    const u = req.url()
    if (!u.includes('.supabase.co/auth/v1/')) return
    const auth = req.headers()['authorization'] || '', body = req.postData() || ''
    hits.push({ path: new URL(u).pathname + (new URL(u).search || ''), planted: auth.includes('PLANTED') || body.includes('PLANTED') })
  })
  await page.goto(`https://${host}/`, { waitUntil: 'domcontentloaded' })
  await page.waitForTimeout(6000)
  const after = await page.evaluate((k) => ({ ls: localStorage.getItem(k) !== null, ss: sessionStorage.getItem(k) !== null }), KEY)
  await ctx.close()
  return { used: hits.some((h) => h.planted), hits: hits.map((h) => `${h.path}${h.planted ? ' [PLANTED]' : ''}`), after }
}

const want = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(APPS)
const browser = await chromium.launch({ executablePath: process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
for (const app of want) {
  const host = APPS[app]
  const off = await runCase(browser, host, 'OFF'), on = await runCase(browser, host, 'ON'), ck = await runCase(browser, host, 'COOKIE')
  const blind = !on.used
  const offOk = !off.used, ckOk = ck.used
  if (blind || !offOk || !ckOk) bad++
  console.log(`${app.padEnd(9)} OFF ${offOk ? 'PASS (planted session NOT used)' : 'FAIL (planted session USED after "restart")'}${off.after.ls ? ', localStorage copy still there' : ', localStorage copy gone'}`)
  console.log(`${''.padEnd(9)} ON  ${blind ? 'BLIND (the control never used the planted session: no auth call on load)' : 'control ok (planted session used, as designed)'}`)
  console.log(`${''.padEnd(9)} COOKIE ${ckOk ? 'PASS (shared cookie read)' : 'FAIL (shared cookie ignored)'}`)
  if (process.env.VERBOSE) console.log('   ', JSON.stringify({ off: off.hits, on: on.hits, cookie: ck.hits }))
}
await browser.close()
process.exit(bad ? 1 : 0)
