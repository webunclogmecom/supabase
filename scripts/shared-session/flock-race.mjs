// flock-race.mjs: does Lovable's page tracker send the tokens of an auth redirect, or what a person types?
// Both trackers are watched: /~flock.js (until 2026-11-12..14; posted location.href, fragment included, to
// /~api/analytics, which our guard scrubs) and /__l5e/events.<hash>.js (since; posts to /__l5e/trackevents with
// fetch and sendBeacon and redacts on its own, measured 2026-11-14 in mockups/2026-11-14-l5e/measure.mjs).
// Since 2026-11-14 about 05:20 ET "Visitor analytics" is OFF in all nine apps (Fred): the expected state is
// that NO request goes to either tracker's endpoint or script during the whole run (tracker=NONE).
//
//   node flock-race.mjs [--inject] [app:path:type ...]
//
// Loads each app with FAKE auth values (marker FLOCKFAKE: nothing here can sign anyone in or out) in the
// fragment AND the query, in an isolated Chrome with the automation flag hidden (~flock.js skips a browser
// that reports navigator.webdriver; __l5e only flags it). Types a FAKE email and password into any visible
// login field (never submitted), sets a new fake hash (the old tracker posted again on it), and fires pagehide
// (__l5e flushes by sendBeacon; a real navigation away hides that request from every instrument). Every POST
// to /~api/analytics or /__l5e/ is read through a context route, the one instrument that sees a sendBeacon
// body (gunzipped when gzip). PASS = (no request at all to /__l5e/, /~flock.js or /~api/analytics, OR a
// tracker reported THIS page: a body names its path) AND no fake value is in any tracker body or URL AND the
// served guard is byte-identical. A tracker that loads but reports nothing FAILS. Not checked: the Referer header, which
// carries the query (never the fragment) on every same-origin request, the page load itself included.
//   --inject   splice the canonical guard in as the first <head> script of the live page first, to prove
//              the guard on the real app and the real tracker BEFORE any app ships it (~flock.js only: the
//              guard acts on /~api/analytics alone).
// Also reports whether the fragment is still in the URL after 700 ms: the guard must leave the URL alone,
// because auth-js and each app's recovery detection read it.
// CONTROL, every run, must be CAUGHT or the run FAILS: hub loaded with a page script that echoes location.href
// (the fake tokens) to BOTH endpoints, with the browser's own sendBeacon (to /__l5e/) and fetch (to
// /~api/analytics) taken before our guard wraps them. Its tracker requests are answered locally, never sent.
import fs from 'node:fs'
import zlib from 'node:zlib'
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
const QUERY = '?code=FLOCKFAKEcode&token_hash=FLOCKFAKEhash'
const EMAIL = 'input[type=email], input[autocomplete~=email], input[autocomplete~=username], input[name*=email i], input[id*=email i], input[placeholder*=email i]'
const DEFAULT = ['hub:/:', 'hub:/reset-password:recovery', 'admin:/:', 'clients:/reset-password:recovery', 'stamp:/:', 'derm:/:recovery', 'calendar:/:', 'hr:/employees:', 'planner:/reset-password:recovery', 'ops:/:']
const cases = (args.filter((a) => !a.startsWith('--')).length ? args.filter((a) => !a.startsWith('--')) : DEFAULT)
  .map((s) => { const [app, path, type] = s.split(':'); return { host: `${app}.unclogme.app`, path, type } })
const endpoint = (u) => u.pathname.startsWith('/__l5e/') ? 'l5e' : u.pathname.startsWith('/~api/analytics') || u.pathname.startsWith('/~flock') ? 'flock' : null
const text = (b) => (b && b[0] === 0x1f && b[1] === 0x8b ? zlib.gunzipSync(b) : b || Buffer.alloc(0)).toString('utf8')
const ECHO = () => {
  const beacon = navigator.sendBeacon.bind(navigator), post = window.fetch.bind(window)
  addEventListener('load', () => setTimeout(() => {
    beacon('/__l5e/trackevents', new Blob([JSON.stringify({ echo: location.href })], { type: 'application/json' }))
    post('/~api/analytics', { method: 'POST', body: JSON.stringify({ echo: location.href }) })
  }, 300))
}
const browser = await chromium.launch({ executablePath: process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true, args: ['--disable-blink-features=AutomationControlled'] })

async function load(c, control) {
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  if (control) await ctx.addInitScript(ECHO)
  if (inject && !control) {
    await page.route(`https://${c.host}${c.path}*`, async (route) => {
      if (route.request().resourceType() !== 'document') return route.continue()
      const r = await route.fetch(); let html = await r.text()
      html = html.replace(/<head([^>]*)>/i, (m) => `${m}<script>${GUARD}</script>`)
      route.fulfill({ response: r, body: html, headers: { ...r.headers(), 'content-length': String(Buffer.byteLength(html)) } })
    })
  }
  const posts = [], seen = []
  await ctx.route((u) => endpoint(u) !== null, (route) => {
    const r = route.request()
    seen.push(endpoint(new URL(r.url())))
    if (r.method() !== 'POST') return route.continue()
    posts.push({ to: endpoint(new URL(r.url())), url: r.url(), body: text(r.postDataBuffer()) })
    return control ? route.fulfill({ status: 204 }) : route.continue()
  })
  const webdriver = await page.evaluate(() => navigator.webdriver).catch(() => '?')
  await page.goto(`https://${c.host}${c.path}${QUERY}${frag(c.type)}`, { waitUntil: 'domcontentloaded' })
  await page.waitForTimeout(700)
  const hashAt700 = await page.evaluate(() => location.hash.includes('access_token')).catch(() => null)
  const typed = []
  if (!control) {
    await page.locator(`${EMAIL}, input[type=password]`).filter({ visible: true }).first().waitFor({ timeout: 4000 }).catch(() => {})
    for (const [sel, value] of [[EMAIL, 'FLOCKFAKEmail@example.com'], ['input[type=password]', 'FLOCKFAKEpw1!']]) {
      const el = page.locator(sel).filter({ visible: true }).first()
      if (await el.count().catch(() => 0)) { await el.click().catch(() => {}); await page.keyboard.type(value, { delay: 8 }); typed.push(sel === EMAIL ? 'email' : 'password') }
    }
    await page.evaluate(() => { location.hash = '#access_token=FLOCKFAKEhashchange&refresh_token=FLOCKFAKEhashchange&type=recovery' }).catch(() => {})
  }
  await page.waitForTimeout(1500)
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false }))).catch(() => {})
  await page.waitForTimeout(1000)
  const guarded = await page.evaluate(() => !!window.__unclogmeAnalyticsGuard).catch(() => null)
  await ctx.close()
  const leakTo = [...new Set(posts.filter((p) => (p.url + p.body).includes('FLOCKFAKE')).map((p) => p.to))]
  const sentView = posts.some((p) => p.body.includes(`"${c.path}"`) || p.body.includes(`\\"${c.path}\\"`))
  return { posts, leakTo, sentView, hashAt700, guarded, webdriver, typed, requests: seen.length, trackers: [...new Set(seen)] }
}

let bad = 0
for (const c of cases) {
  const r = await load(c, false)
  // what the server actually sends: the inline guard must be byte-identical to the tested artifact
  let served = 'n/a (--inject)'
  if (!inject) {
    const html = await (await fetch(`https://${c.host}${c.path}?cb=${Date.now()}`)).text()
    const inl = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).filter((s) => s.includes('__unclogmeAnalyticsGuard'))
    served = inl.length === 0 ? 'MISSING' : inl.length > 1 ? `DUPLICATED x${inl.length}` : inl[0].trim() === GUARD ? 'byte-identical' : 'DIFFERS'
  }
  const ok = (r.requests === 0 || r.sentView) && !r.leakTo.length && (inject || served === 'byte-identical')
  if (!ok) bad++
  console.log(`${(c.host + c.path + (c.type ? ' (' + c.type + ')' : '')).padEnd(46)} ${ok ? 'PASS' : 'FAIL'}  tracker=${r.trackers.join('+') || 'NONE (no request to either endpoint)'} requests=${r.requests} posts=${r.posts.length} page-view-sent=${r.sentView} leaked=${r.leakTo.length ? r.leakTo.join('+') : false} typed=${r.typed.join('+') || 'none'} redacted=${r.posts.some((p) => p.body.includes('=redacted'))} guard=${r.guarded} served-inline=${served} fragment-still-in-URL-at-700ms=${r.hashAt700} webdriver=${r.webdriver}`)
}
const ctl = await load({ host: 'hub.unclogme.app', path: '/', type: '' }, true)
const caught = ['l5e', 'flock'].every((t) => ctl.leakTo.includes(t))
if (!caught) bad++
console.log(`${'CONTROL hub/ echoes the fake URL to both'.padEnd(46)} ${caught ? 'CAUGHT (as it must)' : 'NOT CAUGHT: this check cannot see a leak, FAIL'}  leaked=${ctl.leakTo.join('+') || 'none'} posts=${ctl.posts.length}`)
await browser.close()
process.exit(bad ? 1 : 0)
