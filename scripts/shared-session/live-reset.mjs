// live-reset.mjs: is each app's new-password screen safe on a shared sign-in?
//   node live-reset.mjs [app ...]            cases that need no session (E, W, N, F)
//   node live-reset.mjs --real <app> <link>  P + M with a real recovery link (admin generate_link;
//                                            it is opened, NEVER submitted: no password is typed)
// app "hub-invite" = the Hub's invite page (/reset-password/invite, links of type=invite, 2026-10-26).
// E = expired-link URL: no new-password form, the expired sentence, error params gone
// W = withdrawn-link URL (user_banned): no new-password form, error params gone (invite page: its sentence)
// N = the landing page with nothing in the URL: no new-password form
// F = a FAKE token of the page's link type for another user: no new-password form
// P = a real link: the form shows AND names the account (invite page: its heading, and it landed on the page)
// M = P's session still signed in, then a link URL for ANOTHER user: no form, P's user still signed in
// "new-password form" = two or more password inputs (a sign-in form has one).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PATH = { hub: '/reset-password', 'hub-invite': '/reset-password/invite', clients: '/reset-password', planner: '/reset-password', admin: '/', stamp: '/', derm: '/', calendar: '/' }
const host = (app) => app.split('-')[0]
const invite = (app) => app.endsWith('-invite')
const INVITE_GONE = /This invite link no longer works/i
const args = process.argv.slice(2)
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const FAKE = `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ sub: '00000000-0000-4000-8000-0000000fa4e0', exp, aud: 'authenticated', email: 'someone-else@unclogme.com' })}.RESETFAKEsig`
const fakeFrag = (app) => `#access_token=${FAKE}&expires_at=${exp}&expires_in=3600&refresh_token=RESETFAKErefresh&token_type=bearer&type=${invite(app) ? 'invite' : 'recovery'}`
const EXPIRED = '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired'
const WITHDRAWN = '#error=access_denied&error_code=user_banned&error_description=User+is+banned'
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
async function look(page) {
  await page.waitForTimeout(5000)
  return page.evaluate(() => ({ pw: document.querySelectorAll('input[type=password]').length, text: document.body.innerText.replace(/\s+/g, ' ').slice(0, 400), url: location.href }))
}
function report(name, ok, s) { if (!ok) bad++; console.log(`${name.padEnd(26)} ${ok ? 'PASS' : 'FAIL'}  pw=${s.pw}  url=${s.url.slice(0, 90)}  text="${s.text.slice(0, 160)}"`) }
if (args[0] === '--real') {
  const [, app, link] = args
  const ctx = await browser.newContext(); const page = await ctx.newPage()
  await page.route('**/auth/v1/user', (r) => r.request().method() === 'PUT' ? r.abort() : r.continue())   // belt and braces: no password write can leave
  let apikey = null   // the app's own key, read off its requests, for the cleanup below
  page.on('request', (rq) => { const h = rq.headers().apikey; if (h && rq.url().includes('wbasvhvvismukaqdnouk')) apikey = h })
  await page.goto(link)
  const p = await look(page)
  const email = (p.text.match(/Setting a new password for ([^\s]+)/) || [])[1]
  const landed = new URL(p.url).pathname
  console.log(`landing path: ${landed}`)
  const pageOk = !invite(app) || (landed === PATH[app] && /Welcome\. Choose your password\./.test(p.text))
  report(`${app} P real link`, p.pw >= 2 && !!email && pageOk, p)
  // a real load, not a same-document hash jump (goto to the same path with a new # never reloads)
  await page.goto('about:blank')
  await page.goto(`https://${host(app)}.unclogme.app${PATH[app]}${fakeFrag(app)}`)
  const m = await look(page)
  const still = await page.evaluate(() => document.cookie.includes('sb-wbasvhvvismukaqdnouk-auth-token'))
  report(`${app} M other user's link`, m.pw < 2 && still, { ...m, text: `session-cookie-kept=${still} | ` + m.text })
  // end the session this run created (scope=local: only this one, never the account's other sign-ins)
  const out = !apikey ? 'skipped: no app key seen' : await page.evaluate(async (key) => {
    const c = document.cookie.split('; ').find((x) => x.startsWith('sb-wbasvhvvismukaqdnouk-auth-token'))
    if (!c) return 'no session cookie'
    let v = decodeURIComponent(c.slice(c.indexOf('=') + 1))
    if (v.startsWith('base64-')) v = atob(v.slice(7).replace(/-/g, '+').replace(/_/g, '/'))
    const tok = JSON.parse(v).access_token
    const r = await fetch('https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/logout?scope=local', { method: 'POST', headers: { Authorization: `Bearer ${tok}`, apikey: key } })
    return `logout ${r.status}`
  }, apikey).catch((e) => `logout failed: ${e.message}`)
  console.log(`session cleanup: ${out}`)
  await ctx.close()
} else {
  for (const app of (args.length ? args : Object.keys(PATH))) {
    const gone = (s) => s.pw < 2 && !s.url.includes('error')
    for (const [name, frag, test] of [
      ['E expired', EXPIRED, (s) => gone(s) && (invite(app) ? INVITE_GONE : /expired or was already used/i).test(s.text)],
      ['W withdrawn', WITHDRAWN, (s) => gone(s) && (!invite(app) || INVITE_GONE.test(s.text))],
      ['N nothing', '', (s) => s.pw < 2 && (!invite(app) || /Open this page from the invite link in your email/i.test(s.text))],
      ['F fake link', fakeFrag(app), (s) => s.pw < 2],
    ]) {
      const ctx = await browser.newContext(); const page = await ctx.newPage()
      await page.goto(`https://${host(app)}.unclogme.app${PATH[app]}${frag}`)
      const s = await look(page)
      report(`${app} ${name}`, test(s), s)
      await ctx.close()
    }
  }
}
await browser.close()
process.exit(bad ? 1 : 0)
