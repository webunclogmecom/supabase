// live-portal-tiles.mjs: the Ops Portal's shell, signed in, for each kind of person. Canned replies, no password.
// Signs in with a fake session and answers every Supabase call locally, as live-hub-tiles.mjs does for the Hub.
// PASS = each case shows exactly its tiles in order, the right sidebar, no sideways scroll, and the sign-in needed no
// reload. PORTAL=http://localhost:8080/ runs it before a publish. SHOTS=<dir> keeps a picture of each case.
// CONTROL=1 expects Field to see an Admin's tiles: every field case must then FAIL, or this check cannot fail.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PORTAL = process.env.PORTAL || 'https://ops.unclogme.app/'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')

const LATER = ['Visit Calendar', 'HR App', 'DERM Tracker', 'Admin Review', 'Client App', 'Stamp Studio', 'Picture Planner']
const ALL = [...LATER, 'Field Portal', 'DUMP Schedule', 'Sales App', 'Review Assist']
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const SUBS = { hr_pay: 'hr', hr_bonus: 'hr', pp_approve: 'picture_planner', pp_forms: 'picture_planner' }
function reply(id, group, levels, modes = {}) {
  const apps = [...TOP, ...Object.keys(SUBS)].map((a) => ({ app: a, parent: SUBS[a] ?? null, mode: modes[a] ?? 'on', level: levels[a] ?? (SUBS[a] ? 'no' : 'none') }))
  return { employee_id: id, group, apps }
}
const every = (lvl) => Object.fromEntries(TOP.map((a) => [a, lvl]))
const control = Boolean(process.env.CONTROL)
const CASES = [
  { name: 'admin, edit everywhere', who: 'Fred Zerpa', group: 'admin', r: reply(2, 'admin', { ...every('edit'), pp_forms: 'yes' }), tiles: ALL, hello: ', Fred', role: 'Admin', card: false },
  { name: 'office, edit everywhere', who: 'Diego Test', group: 'office', r: reply(28, 'office', every('edit')), tiles: ALL, hello: ', Diego', role: 'Office', card: false },
  { name: 'office, HR App none', who: 'Aaron Test', group: 'office', r: reply(26, 'office', { ...every('edit'), hr: 'none' }), tiles: ALL.filter((t) => t !== 'HR App'), hello: ', Aaron', role: 'Office', card: true },
  { name: 'field, assigned forms', who: 'Mark Test', group: 'field', r: reply(59, 'field', { pp_forms: 'yes' }), tiles: control ? ALL : ['Picture Planner', 'Field Portal', 'DUMP Schedule'], role: 'Field', card: true, text: 'Your assigned forms' },
  { name: 'field, no forms switch', who: 'Grecia Test', group: 'field', r: reply(1, 'field', {}), tiles: control ? ALL : ['Field Portal', 'DUMP Schedule'], role: 'Field', card: true },
  { name: 'access check fails', who: 'Fred Zerpa', group: 'admin', fail: true, text: "We couldn't load your apps" },
  { name: 'not staff', who: 'Some Stranger', group: 'field', r: { employee_id: null, group: null, apps: [] }, text: 'is not an UnclogMe staff account', login: true },
]

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let bad = 0
for (const [w, h] of [[1440, 900], [375, 812]]) for (const c of CASES) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } }); const page = await ctx.newPage()
  const exp = Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000' + String(c.r?.employee_id ?? 2).padStart(3, '0')
  const mail = c.who.toLowerCase().replace(/ /g, '.') + '@unclogme.com'
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  const seen = { navs: 0, signOut: [], stray: new Set() }
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) seen.navs++ })
  page.on('request', (q) => { const u = q.url(); if (/supabase\.co/.test(u) && !/wbasvhvvismukaqdnouk/.test(u)) seen.stray.add(new URL(u).host) })
  await page.route('**/auth/v1/.well-known/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"keys":[]}' }))
  await page.route('**/auth/v1/token**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }) }))
  await page.route('**/auth/v1/user**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await page.route('**/auth/v1/logout**', (r) => { seen.signOut.push(new URL(r.request().url()).searchParams.get('scope')); r.fulfill({ status: 204, body: '' }) })
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url()
    if (/rpc\/get_my_access/.test(u)) {
      if (c.fail) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.r) })
    }
    if (/\/employees/.test(u)) {
      if (c.group === 'field') return r.fulfill({ status: 403, contentType: 'application/json', body: '{"code":"42501","message":"You do not have access to any UnclogMe app."}' })
      return r.fulfill({ status: 200, contentType: 'application/vnd.pgrst.object+json', body: JSON.stringify({ full_name: c.who, color_hex: '#14B8A6' }) })
    }
    r.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
  })
  await page.goto(PORTAL); await page.waitForSelector('input[type=email]', { timeout: 30000 })
  const navsBefore = seen.navs
  await page.locator('input[type=email]').fill(mail)
  await page.locator('input[type=password]').fill('canned-not-a-password')
  await page.getByRole('button', { name: /^sign in$/i }).click()
  await page.waitForTimeout(2500)
  const got = await page.evaluate(() => {
    const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' }
    const main = document.querySelector('main')
    const nav = document.querySelector('nav[aria-label="Apps"]')
    return {
      tiles: main ? [...main.querySelectorAll('a[href] b')].filter(vis).map((e) => e.textContent.trim()) : [],
      navItems: nav && vis(nav) ? [...nav.querySelectorAll('a[target=_blank]')].map((a) => a.textContent.trim()) : null,
      h1: document.querySelector('main h1, h1')?.textContent?.trim() ?? '',
      text: document.body.innerText,
      overflow: document.documentElement.scrollWidth > window.innerWidth,
      loginShown: Boolean(document.querySelector('input[type=email]')),
    }
  })
  const fails = []
  if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
  if (seen.navs !== navsBefore) fails.push('the sign-in reloaded the page')
  if (got.overflow) fails.push('sideways scroll')
  if (c.tiles) {
    if (JSON.stringify(got.tiles) !== JSON.stringify(c.tiles)) fails.push(`tiles ${got.tiles.join('|')}`)
    if (c.hello ? !got.h1.includes(c.hello) : got.h1.includes(',')) fails.push(`greeting "${got.h1}"`)
    if (/\bfailed|undefined|null\b/i.test(got.h1)) fails.push(`greeting "${got.h1}"`)
    if (Boolean(/Need another app\?/.test(got.text)) !== c.card) fails.push('Need another app card')
    if (w >= 768) {
      const wantNav = c.tiles.filter((t) => LATER.includes(t))
      if (JSON.stringify(got.navItems?.map((n) => n.replace(/^[A-Z]{2}/, ''))) !== JSON.stringify(wantNav)) fails.push(`sidebar ${got.navItems}`)
      if (!got.text.includes(c.role)) fails.push(`role ${c.role} missing`)
    } else if (got.navItems) fails.push('sidebar drawn on a phone')
  }
  if (c.text && !got.text.includes(c.text)) fails.push(`missing "${c.text}"`)
  if (c.group !== 'field' && got.text.includes('Your assigned forms')) fails.push('assigned-forms wording for someone with the Planner')
  if (c.login && !got.loginShown) fails.push('not back on the login')
  if (c.login && !seen.signOut.includes('local')) fails.push(`sign-out scope ${seen.signOut}`)
  if (c.fail && (got.loginShown || seen.signOut.length)) fails.push('a failed check signed the person out')
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/${w}-${c.name.replace(/[^a-z]+/gi, '-')}.png` })
  if (fails.length) bad++
  console.log(`${String(w).padEnd(5)} ${c.name.padEnd(26)} ${fails.length ? 'FAIL  ' + fails.join('; ') : 'PASS'}`)
  await ctx.close()
}
await browser.close()
console.log(bad ? `${bad} FAILED` : 'ALL PASS')
process.exit(bad ? 1 : 0)
