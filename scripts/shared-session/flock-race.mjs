// flock-race.mjs: does Lovable's tracker (/~flock.js) send the tokens of an auth redirect?
//
//   node flock-race.mjs [--inject] [app:path:type ...]
//
// Loads each app at a path carrying a FAKE auth fragment (marker FLOCKFAKE: nothing here can sign
// anyone in or out) in an isolated Chrome with the automation flag hidden, because the tracker skips
// browsers that report navigator.webdriver. Records every POST to /~api/analytics and whether its body
// carries the fake tokens. PASS = the tracker still reports the page view AND no token leaves.
//   --inject   splice the canonical guard in as the first <head> script of the live page first, to prove
//              the guard on the real app and the real tracker BEFORE any app ships it.
// Also reports that the fragment is still in the URL after the tracker fired: the guard must leave the
// URL alone, because auth-js and each app's recovery detection read it.
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const args = process.argv.slice(2)
const inject = args.includes('--inject')
const src = fs.readFileSync(new URL('./analytics-token-guard.js', import.meta.url), 'utf8')
const GUARD = src.slice(src.indexOf('(function () {')).split('\n').map((l) => l.trim()).filter(Boolean).join(' ')
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const AT = `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ sub: '00000000-0000-4000-8000-00000000f10c', exp, aud: 'authenticated', marker: 'FLOCKFAKE' })}.FLOCKFAKEsig`
const frag = (type) => `#access_token=${AT}&expires_at=${exp}&expires_in=3600&refresh_token=FLOCKFAKErefresh&provider_token=FLOCKFAKEgoogle&token_type=bearer${type ? '&type=' + type : ''}`
const DEFAULT = ['hub:/:', 'hub:/reset-password:recovery', 'admin:/:', 'clients:/reset-password:recovery', 'stamp:/:', 'derm:/:recovery', 'calendar:/:', 'hr:/employees:', 'planner:/reset-password:recovery']
const cases = (args.filter((a) => !a.startsWith('--')).length ? args.filter((a) => !a.startsWith('--')) : DEFAULT)
  .map((s) => { const [app, path, type] = s.split(':'); return { host: `${app}.unclogme.app`, path, type } })
const browser = await chromium.launch({ executablePath: process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true, args: ['--disable-blink-features=AutomationControlled'] })
let bad = 0
for (const c of cases) {
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  if (inject) {
    await page.route(`https://${c.host}${c.path}*`, async (route) => {
      if (route.request().resourceType() !== 'document') return route.continue()
      const r = await route.fetch(); let html = await r.text()
      html = html.replace(/<head([^>]*)>/i, (m) => `${m}<script>${GUARD}</script>`)
      route.fulfill({ response: r, body: html, headers: { ...r.headers(), 'content-length': String(Buffer.byteLength(html)) } })
    })
  }
  const posts = []
  page.on('request', (r) => { if (r.url().includes('/~api/analytics')) { const b = r.postData() || ''; posts.push({ leak: b.includes('FLOCKFAKE'), redacted: b.includes('=redacted') }) } })
  const webdriver = await page.evaluate(() => navigator.webdriver).catch(() => '?')
  await page.goto(`https://${c.host}${c.path}${frag(c.type)}`, { waitUntil: 'domcontentloaded' })
  let hashAt700 = null
  await page.waitForTimeout(700); hashAt700 = await page.evaluate(() => location.hash.includes('access_token')).catch(() => null)
  await page.waitForTimeout(3300)
  const guarded = await page.evaluate(() => !!window.__unclogmeAnalyticsGuard).catch(() => null)
  await ctx.close()
  const leaked = posts.some((p) => p.leak), sentView = posts.length > 0
  const ok = sentView && !leaked
  if (!ok) bad++
  console.log(`${(c.host + c.path + (c.type ? ' (' + c.type + ')' : '')).padEnd(46)} ${ok ? 'PASS' : 'FAIL'}  tracker posts=${posts.length} leaked=${leaked} redacted=${posts.some((p) => p.redacted)} guard=${guarded} fragment-still-in-URL-at-700ms=${hashAt700} webdriver=${webdriver}`)
}
await browser.close()
process.exit(bad ? 1 : 0)
