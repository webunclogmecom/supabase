// live-reset.mjs: is each app's new-password screen safe on a shared sign-in?
//   node live-reset.mjs [app ...]            cases that need no session (E, N, F)
//   node live-reset.mjs --real <app> <link>  P + M with a real recovery link (admin generate_link;
//                                            it is opened, NEVER submitted: no password is typed)
// E = expired-link URL: no new-password form, the "expired or was already used" sentence, error params gone
// N = the landing page with nothing in the URL: no new-password form
// F = type=recovery + a FAKE token for another user: no new-password form
// P = a real recovery link: the form shows AND names the account
// M = P's session still signed in, then a type=recovery URL for ANOTHER user: no form, P's user still signed in
// "new-password form" = two or more password inputs (a sign-in form has one).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PATH = { hub: '/reset-password', clients: '/reset-password', planner: '/reset-password', admin: '/', stamp: '/', derm: '/', calendar: '/' }
const args = process.argv.slice(2)
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const FAKE = `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ sub: '00000000-0000-4000-8000-0000000fa4e0', exp, aud: 'authenticated', email: 'someone-else@unclogme.com' })}.RESETFAKEsig`
const fakeFrag = `#access_token=${FAKE}&expires_at=${exp}&expires_in=3600&refresh_token=RESETFAKErefresh&token_type=bearer&type=recovery`
const EXPIRED = '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired'
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
async function look(page) {
  await page.waitForTimeout(5000)
  return page.evaluate(() => ({ pw: document.querySelectorAll('input[type=password]').length, text: document.body.innerText.replace(/\s+/g, ' ').slice(0, 400), url: location.href }))
}
function report(name, ok, s) { if (!ok) bad++; console.log(`${name.padEnd(22)} ${ok ? 'PASS' : 'FAIL'}  pw=${s.pw}  url=${s.url.slice(0, 90)}  text="${s.text.slice(0, 160)}"`) }
if (args[0] === '--real') {
  const [, app, link] = args
  const ctx = await browser.newContext(); const page = await ctx.newPage()
  await page.route('**/auth/v1/user', (r) => r.request().method() === 'PUT' ? r.abort() : r.continue())   // belt and braces: no password write can leave
  await page.goto(link)
  const p = await look(page)
  const email = (p.text.match(/Setting a new password for ([^\s]+)/) || [])[1]
  report(`${app} P real link`, p.pw >= 2 && !!email, p)
  // a real load, not a same-document hash jump (goto to the same path with a new # never reloads)
  await page.goto('about:blank')
  await page.goto(`https://${app}.unclogme.app${PATH[app]}${fakeFrag}`)
  const m = await look(page)
  const still = await page.evaluate(() => document.cookie.includes('sb-wbasvhvvismukaqdnouk-auth-token'))
  report(`${app} M other user's link`, m.pw < 2 && still, { ...m, text: `session-cookie-kept=${still} | ` + m.text })
  await ctx.close()
} else {
  for (const app of (args.length ? args : Object.keys(PATH))) {
    for (const [name, frag, test] of [
      ['E expired', EXPIRED, (s) => s.pw < 2 && /expired or was already used/i.test(s.text) && !s.url.includes('error')],
      ['N nothing', '', (s) => s.pw < 2],
      ['F fake recovery', fakeFrag, (s) => s.pw < 2],
    ]) {
      const ctx = await browser.newContext(); const page = await ctx.newPage()
      await page.goto(`https://${app}.unclogme.app${PATH[app]}${frag}`)
      report(`${app} ${name}`, test(await look(page)), await look(page))
      await ctx.close()
    }
  }
}
await browser.close()
process.exit(bad ? 1 : 0)
