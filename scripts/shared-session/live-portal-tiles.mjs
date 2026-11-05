// live-portal-tiles.mjs: the Ops Portal, signed in, for each kind of person. Canned replies, no password.
// Signs in with a fake session and answers every Supabase call locally, as live-hub-tiles.mjs does for the Hub.
// PASS = each case shows exactly its tiles in order, the right sidebar, no sideways scroll, and the sign-in needed no
// reload; the HR module opens, labels its requests hr-app (the shell's stay ops-portal), refuses a person with no HR
// access, and a sign-out starts clean.
// PORTAL=http://localhost:8080/ runs it before a publish. SHOTS=<dir> keeps a picture of each case.
// CONTROL=1 expects Field to see an Admin's tiles: every field case must then FAIL, or this check cannot fail.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PORTAL = process.env.PORTAL || 'https://ops.unclogme.app/'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')

const NAV = ['HR App', 'Visit Calendar', 'DERM Tracker', 'Admin Review', 'Client App', 'Stamp Studio', 'Picture Planner']
const ALL = [...NAV, 'Field Portal', 'DUMP Schedule', 'Sales App', 'Review Assist']
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const SUBS = { hr_pay: 'hr', hr_bonus: 'hr', pp_approve: 'picture_planner', pp_forms: 'picture_planner' }
function reply(id, group, levels, modes = {}) {
  const apps = [...TOP, ...Object.keys(SUBS)].map((a) => ({ app: a, parent: SUBS[a] ?? null, mode: modes[a] ?? 'on', level: levels[a] ?? (SUBS[a] ? 'no' : 'none') }))
  return { employee_id: id, group, apps }
}
const every = (lvl) => Object.fromEntries(TOP.map((a) => [a, lvl]))
const control = Boolean(process.env.CONTROL)
const ADMIN = { who: 'Fred Zerpa', group: 'admin', r: reply(2, 'admin', { ...every('edit'), pp_forms: 'yes' }) }
const FIELD = { who: 'Mark Test', group: 'field', r: reply(59, 'field', { pp_forms: 'yes' }) }
const CASES = [
  { name: 'admin, edit everywhere', ...ADMIN, tiles: ALL, hello: ', Fred', role: 'Admin', card: false },
  { name: 'office, edit everywhere', who: 'Diego Test', group: 'office', r: reply(28, 'office', every('edit')), tiles: ALL, hello: ', Diego', role: 'Office', card: false },
  { name: 'office, HR App none', who: 'Aaron Test', group: 'office', r: reply(26, 'office', { ...every('edit'), hr: 'none' }), tiles: ALL.filter((t) => t !== 'HR App'), hello: ', Aaron', role: 'Office', card: true },
  { name: 'field, assigned forms', ...FIELD, tiles: control ? ALL : ['Picture Planner', 'Field Portal', 'DUMP Schedule'], role: 'Field', card: true, text: 'Your assigned forms' },
  { name: 'field, no forms switch', who: 'Grecia Test', group: 'field', r: reply(1, 'field', {}), tiles: control ? ALL : ['Field Portal', 'DUMP Schedule'], role: 'Field', card: true },
  { name: 'access check fails', who: 'Fred Zerpa', group: 'admin', fail: true, text: "We couldn't load your apps" },
  { name: 'not staff', who: 'Some Stranger', group: 'field', r: { employee_id: null, group: null, apps: [] }, text: 'is not an UnclogMe staff account', login: true },
]
const PEOPLE = [{ id: 2, full_name: 'Fred Zerpa', email: 'fred.zerpa@unclogme.com', status: 'ACTIVE', access_level: 'admin', role: null, color_hex: '#3F6212', photo_path: null, phone: null, start_date: null, payroll_week_start_day: 5 }]

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })

async function signedIn(c, w, h, goto = PORTAL) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } }); const page = await ctx.newPage()
  if (process.env.DARK) await page.addInitScript(() => localStorage.setItem('unclogme.theme', 'dark')) // DARK=1 with SHOTS=<dir> to look at dark mode
  const exp =Math.floor(Date.now() / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000' + String(c.r?.employee_id ?? 2).padStart(3, '0')
  const mail = c.who.toLowerCase().replace(/ /g, '.') + '@unclogme.com'
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  const seen = { navs: 0, signOut: [], stray: new Set(), labels: {}, errors: [], loggedIn: false }
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) seen.navs++ })
  page.on('pageerror', (e) => seen.errors.push(String(e).slice(0, 160)))
  page.on('request', (q) => {
    const u = q.url(); if (!/supabase\.co/.test(u)) return
    if (!/wbasvhvvismukaqdnouk/.test(u)) seen.stray.add(new URL(u).host)
    const m = u.match(/\/rest\/v1\/(rpc\/[a-z_]+|[a-z_]+)/); if (m) (seen.labels[m[1]] ??= new Set()).add(q.headers()['x-app-source'] ?? 'NONE')
  })
  await page.route('**/auth/v1/.well-known/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"keys":[]}' }))
  await page.route('**/auth/v1/token**', (r) => { seen.loggedIn = true; r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'canned', user }) }) })
  await page.route('**/auth/v1/user**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await page.route('**/auth/v1/logout**', (r) => { seen.signOut.push(new URL(r.request().url()).searchParams.get('scope')); r.fulfill({ status: 204, body: '' }) })
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url(), one = /vnd\.pgrst\.object/.test(r.request().headers().accept ?? '')
    if (/rpc\/get_my_access/.test(u)) {
      if (c.fail) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.r) })
    }
    if (/\/employees/.test(u)) {
      if (c.group === 'field') return r.fulfill({ status: 403, contentType: 'application/json', body: '{"code":"42501","message":"You do not have access to any UnclogMe app."}' })
      if (one) return r.fulfill({ status: 200, contentType: 'application/vnd.pgrst.object+json', body: JSON.stringify({ full_name: c.who, color_hex: '#14B8A6' }) })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ ...PEOPLE[0], full_name: c.who }]) })
    }
    r.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
  })
  await page.goto(goto); await page.waitForSelector('input[type=email]', { timeout: 30000 })
  const navsBefore = seen.navs
  await page.locator('input[type=email]').fill(mail)
  await page.locator('input[type=password]').fill('canned-not-a-password')
  await page.getByRole('button', { name: /^sign in$/i }).click()
  await page.waitForTimeout(2500)
  return { ctx, page, seen, navsBefore }
}

let bad = 0
const report = (w, name, fails) => { if (fails.length) bad++; console.log(`${String(w).padEnd(5)} ${name.padEnd(30)} ${fails.length ? 'FAIL  ' + fails.join('; ') : 'PASS'}`) }
const shot = async (page, w, name) => { if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/${w}-${name.replace(/[^a-z]+/gi, '-')}.png` }) }

for (const [w, h] of [[1440, 900], [375, 812]]) {
  for (const c of CASES) {
    const { ctx, page, seen, navsBefore } = await signedIn(c, w, h)
    const got = await page.evaluate(() => {
      const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' }
      const main = document.querySelector('main')
      const nav = document.querySelector('nav[aria-label="Apps"]')
      return {
        tiles: main ? [...main.querySelectorAll('a[href] b')].filter(vis).map((e) => e.textContent.trim()) : [],
        navItems: nav && vis(nav) ? [...nav.querySelectorAll('a[data-tile]')].map((a) => a.dataset.tile) : null,
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
        const wantNav = c.tiles.filter((t) => NAV.includes(t))
        if (JSON.stringify(got.navItems) !== JSON.stringify(wantNav)) fails.push(`sidebar ${got.navItems}`)
        if (!got.text.includes(c.role)) fails.push(`role ${c.role} missing`)
      } else if (got.navItems) fails.push('sidebar drawn on a phone')
    }
    if (c.text && !got.text.includes(c.text)) fails.push(`missing "${c.text}"`)
    if (c.group !== 'field' && got.text.includes('Your assigned forms')) fails.push('assigned-forms wording for someone with the Planner')
    if (c.login && !got.loginShown) fails.push('not back on the login')
    if (c.login && !seen.signOut.includes('local')) fails.push(`sign-out scope ${seen.signOut}`)
    if (c.fail && (got.loginShown || seen.signOut.length)) fails.push('a failed check signed the person out')
    await shot(page, w, c.name)
    report(w, c.name, fails)
    await ctx.close()
  }

  // The HR module: opens from its tile, labels its own requests, and the shell keeps its own label.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    await page.locator('main a[href="/hr"]').click()
    await page.waitForTimeout(2500)
    const path = new URL(page.url()).pathname
    if (path !== '/hr/employees') fails.push(`landed on ${path}`)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/Employees/.test(text)) fails.push('no Employees nav')
    if (!/Access/.test(text)) fails.push('no Access nav for an admin')
    const label = (k) => [...(seen.labels[k] ?? [])].join(',')
    if (label('rpc/get_pay_summary') !== 'hr-app') fails.push(`get_pay_summary labelled "${label('rpc/get_pay_summary')}"`)
    if (!label('rpc/get_my_access').includes('ops-portal')) fails.push(`the shell's get_my_access labelled "${label('rpc/get_my_access')}"`)
    if (!label('rpc/get_my_access').includes('hr-app')) fails.push(`the module's get_my_access labelled "${label('rpc/get_my_access')}"`)
    if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)) fails.push('sideways scroll')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'hr module')
    report(w, 'HR opens, labels hr-app', fails)
    await ctx.close()
  }

  // A person with no HR access who has the address: refused on screen, and the module asks the database nothing.
  {
    const { ctx, page, seen } = await signedIn(FIELD, w, h, PORTAL + 'hr/employees')
    const fails = []
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You don't have access to the HR App/.test(text)) fails.push('no refusal on screen')
    if (seen.labels['rpc/get_pay_summary']) fails.push('the module called get_pay_summary')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, 'no HR access, direct address', fails)
    await ctx.close()
  }

  // Sign out: asks Supabase once, reloads, and comes back to the login with nothing left on screen.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    const before = seen.navs
    if (w < 768) await page.getByRole('button', { name: /open menu/i }).click()
    await page.getByRole('button', { name: /^sign out$/i }).click()
    await page.waitForTimeout(2500)
    if (seen.signOut.length < 1) fails.push('Supabase was not asked to sign out')
    if (seen.navs === before) fails.push('the page did not start clean')
    if (!(await page.locator('input[type=email]').count())) fails.push('not on the login')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, 'sign out starts clean', fails)
    await ctx.close()
  }
}
await browser.close()
console.log(bad ? `${bad} FAILED` : 'ALL PASS')
process.exit(bad ? 1 : 0)
