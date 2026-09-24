// live-hr-login.mjs: the HR sign-in screen's three login fixes, on the LIVE app, with no credentials.
// Every request to /auth/v1/authorize and /auth/v1/token is intercepted and never reaches Supabase;
// no password is ever typed (the password case removes `required` and submits an EMPTY field, and the
// token endpoint is answered locally with a canned "invalid login" error).
//   G = "Continue with Google" asks Google to show the account chooser (prompt=select_account)
//   S = "Sign in" submits the email/password form: a password grant is requested, Google is NOT started,
//       and the canned rejection shows the plain sentence, not a raw error
//   F = "Forgot password?" is a real link to the Apps Hub
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const URL0 = 'https://hr.unclogme.app/employees'
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
const say = (n, ok, d) => { if (!ok) bad++; console.log(`hr ${n.padEnd(34)} ${ok ? 'PASS' : 'FAIL'}  ${d}`) }
async function fresh() {
  const ctx = await browser.newContext(); const page = await ctx.newPage(); const seen = { authorize: [], token: [] }
  await page.route('**/auth/v1/authorize**', (r) => { seen.authorize.push(r.request().url()); r.abort() })
  await page.route('**/auth/v1/token**', (r) => { seen.token.push(r.request().url()); r.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials', error: 'invalid_grant', error_description: 'Invalid login credentials' }) }) })
  await page.goto(URL0); await page.waitForTimeout(4000)
  return { ctx, page, seen }
}
{ // G
  const { ctx, page, seen } = await fresh()
  await page.getByRole('button', { name: /continue with google/i }).click().catch(() => {})
  await page.waitForTimeout(2500)
  const u = seen.authorize[0] ? new URL(seen.authorize[0]) : null
  say('G Google shows the account chooser', !!u && u.searchParams.get('prompt') === 'select_account', u ? `prompt=${u.searchParams.get('prompt')}` : 'no authorize request')
  await ctx.close()
}
{ // S
  const { ctx, page, seen } = await fresh()
  const email = page.locator('input[type=email], input[name=email], input[autocomplete=email]').first()
  await email.fill('hr-login-check@unclogme.com')
  await page.evaluate(() => document.querySelectorAll('input').forEach((i) => i.removeAttribute('required')))
  await page.getByRole('button', { name: /^sign in$/i }).click().catch(() => {})
  await page.waitForTimeout(3000)
  const text = await page.evaluate(() => document.body.innerText)
  const grant = seen.token.some((t) => t.includes('grant_type=password'))
  say('S Sign in requests a password grant', grant && seen.authorize.length === 0, `password-grant=${grant} google-started=${seen.authorize.length > 0}`)
  say('S rejection is a plain sentence', /That email and password do not match/.test(text) && !/invalid_credentials|invalid_grant/i.test(text), (text.match(/That email[^.]*\.|Sign-in is not available[^.]*\./) || ['(no sentence)'])[0])
  await ctx.close()
}
{ // F
  const { ctx, page } = await fresh()
  const a = await page.evaluate(() => { const l = [...document.querySelectorAll('a')].find((x) => /forgot password/i.test(x.textContent)); return l ? { href: l.href, title: l.title } : null })
  say('F Forgot password links to the Hub', !!a && /^https:\/\/hub\.unclogme\.app\/?$/.test(a.href), a ? `href=${a.href} title="${a.title}"` : 'no link')
  await ctx.close()
}
await browser.close()
process.exit(bad ? 1 : 0)
