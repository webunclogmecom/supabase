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

const NAV = ['Visit Calendar', 'DERM Tracker', 'HR App', 'Admin Review', 'Client App', 'Stamp Studio', 'Picture Planner']
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
const FIELD = { who: 'Mark Test', group: 'field', hello: ', Mark', r: reply(59, 'field', { pp_forms: 'yes' }) }
const CASES = [
  { name: 'admin, edit everywhere', ...ADMIN, tiles: ALL, hello: ', Fred', role: 'Admin', card: false },
  { name: 'office, edit everywhere', who: 'Diego Test', group: 'office', r: reply(28, 'office', every('edit')), tiles: ALL, hello: ', Diego', role: 'Office', card: false },
  { name: 'office, HR App none', who: 'Aaron Test', group: 'office', r: reply(26, 'office', { ...every('edit'), hr: 'none' }), tiles: ALL.filter((t) => t !== 'HR App'), hello: ', Aaron', role: 'Office', card: true },
  { name: 'field, assigned forms', ...FIELD, tiles: control ? ALL : ['Picture Planner', 'Field Portal', 'DUMP Schedule'], role: 'Field', card: true, text: 'Your assigned forms' },
  { name: 'field, no forms switch', who: 'Grecia Test', group: 'field', hello: ', Grecia', r: reply(1, 'field', {}), tiles: control ? ALL : ['Field Portal', 'DUMP Schedule'], role: 'Field', card: true },
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
  await page.route('**/storage/v1/**', (r) => {
    if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } })
    seen.upload = new URL(r.request().url()).pathname
    r.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ Key: 'employee-photos/x.jpg', Id: 'x', signedURL: '/object/sign/employee-photos/x.jpg?token=canned' }) })
  })
  await page.route('**/rest/v1/**', (r) => {
    const u = r.request().url(), one = /vnd\.pgrst\.object/.test(r.request().headers().accept ?? '')
    if (/rpc\/set_employee_photo/.test(u)) {
      seen.photoCall = r.request().postDataJSON()
      return r.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' })
    }
    if (/rpc\/portal_search/.test(u)) {
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
        clients: [{ id: 450, code: '290-PER', name: 'Canned Client', status: 'ACTIVE' }],
        visits: [{ id: 9072, client_code: '290-PER', client_name: 'Canned Client', visit_date: '2026-12-01', start_at: null, is_all_day: true, service: 'Pumping', truck: 'Moises', driver: 'Grecia', kind: 'next' }],
        requests: [{ id: 91, client_code: '290-PER', client_name: 'Canned Client', service: '22 - Service Call - Labor', age_days: 3, call_required: false }],
        people: [{ id: 2, full_name: 'Fred Zerpa', access_level: 'admin', color_hex: '#3F6212' }],
      }) })
    }
    if (/rpc\/portal_waiting/.test(u)) {
      if (c.waitingFails) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.group === 'field' ? {} : { call_first: 1, time_on_site: 6, photos_unsorted: 8, city_emails: 0, stamp_sheets: 0, unopened_emails: 9 }) })
    }
    if (/rpc\/get_my_access/.test(u)) {
      if (c.fail) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.r?.employee_id ? { ...c.r, me: { full_name: c.who, color_hex: '#14B8A6', photo_path: null } } : c.r) })
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

  // The Calendar module: opens from its tile, keeps its own label and look, draws no second theme or sign-out control,
  // the page is its only scroller, and leaving it gives the look back.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    await page.locator('main a[href="/calendar"]').click()
    await page.waitForFunction(() => document.documentElement.dataset.module === 'calendar', null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(2500)
    const path = new URL(page.url()).pathname
    if (path !== '/calendar') fails.push(`landed on ${path}`)
    const got = await page.evaluate(() => {
      const scrollers = [...document.querySelectorAll('main *')].filter((el) => {
        const s = getComputedStyle(el), r = el.getBoundingClientRect()
        return /auto|scroll/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 1 && r.height > 0
      }).map((el) => el.className.toString().slice(0, 50))
      return {
        module: document.documentElement.dataset.module, look: document.documentElement.getAttribute('data-hw-app'),
        darkSheet: document.getElementById('theme-dark-app')?.getAttribute('href') ?? '',
        title: document.title, mainSignOut: [...document.querySelectorAll('main button')].filter((b) => /^sign out$/i.test(b.textContent.trim())).length,
        themes: [...document.querySelectorAll('main [aria-label*="dark" i], main [aria-label*="light" i]')].length,
        scrollers, overflow: document.documentElement.scrollWidth > window.innerWidth,
      }
    })
    if (got.module !== 'calendar') fails.push(`data-module "${got.module}"`)
    if (got.look !== 'calendar') fails.push(`data-hw-app "${got.look}"`)
    if (process.env.DARK && !/dark-calendar/.test(got.darkSheet)) fails.push(`dark sheet "${got.darkSheet}"`)
    if (got.title !== 'Visit Calendar · UnclogMe') fails.push(`title "${got.title}"`)
    if (got.mainSignOut) fails.push('a second Sign out in the page')
    if (got.themes) fails.push('a second theme switch in the page')
    if (got.scrollers.length) fails.push('an inner scroller: ' + got.scrollers[0])
    if (got.overflow) fails.push('sideways scroll')
    const labels = Object.entries(seen.labels).filter(([k]) => /calendar/.test(k))
    if (!labels.length) fails.push('the module asked for no calendar data')
    for (const [k, v] of labels) if ([...v].join(',') !== 'visit-calendar') fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'calendar module')
    if (w >= 1024) {
      await page.locator('nav[aria-label="Apps"] a[data-tile="HR App"]').click()
      await page.waitForTimeout(1500)
      const back = await page.evaluate(() => [document.documentElement.dataset.module ?? '', document.documentElement.getAttribute('data-hw-app'), document.getElementById('theme-dark-app')?.getAttribute('href') ?? ''])
      if (back[0]) fails.push(`still data-module "${back[0]}" after leaving`)
      if (back[1] !== 'hr') fails.push(`data-hw-app "${back[1]}" after leaving`)
      if (process.env.DARK && !/dark-hr/.test(back[2])) fails.push(`dark sheet "${back[2]}" after leaving`)
    }
    report(w, 'Calendar opens, labels its own', fails)
    await ctx.close()
  }

  // A person with no Calendar access who has the address: the Calendar's own card, and no calendar data asked for.
  {
    const { ctx, page, seen } = await signedIn(FIELD, w, h, PORTAL + 'calendar')
    const fails = []
    const text = await page.evaluate(() => document.body.innerText)
    if (!/access/i.test(text)) fails.push('no refusal on screen')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    await shot(page, w, 'calendar no access')
    report(w, 'no Calendar access, address', fails)
    await ctx.close()
  }

  // The DERM Tracker module: opens from its tile, keeps its own label and look, draws no second theme or sign-out control,
  // its links stay under /derm, and leaving it gives the look back.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    await page.locator('main a[href="/derm"]').click()
    await page.waitForFunction(() => document.documentElement.dataset.module === 'derm', null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(2500)
    const path = new URL(page.url()).pathname
    if (path !== '/derm') fails.push(`landed on ${path}`)
    const got = await page.evaluate(() => ({
      module: document.documentElement.dataset.module, look: document.documentElement.getAttribute('data-hw-app'),
      darkSheet: document.getElementById('theme-dark-app')?.getAttribute('href') ?? '',
      title: document.title, mainSignOut: [...document.querySelectorAll('main button')].filter((b) => /^sign out$/i.test(b.textContent.trim())).length,
      themes: [...document.querySelectorAll('main [aria-label*="dark" i], main [aria-label*="light" i]')].length,
      overflow: document.documentElement.scrollWidth > window.innerWidth,
      links: [...document.querySelectorAll('a[href^="/derm"]')].map((a) => a.getAttribute('href')),
    }))
    if (got.module !== 'derm') fails.push(`data-module "${got.module}"`)
    if (got.look !== 'derm') fails.push(`data-hw-app "${got.look}"`)
    if (process.env.DARK && !/dark-derm/.test(got.darkSheet)) fails.push(`dark sheet "${got.darkSheet}"`)
    if (!/DERM Tracker/.test(got.title)) fails.push(`title "${got.title}"`)
    if (got.mainSignOut) fails.push('a second Sign out in the page')
    if (got.themes) fails.push('a second theme switch in the page')
    if (got.overflow) fails.push('sideways scroll')
    for (const want of ['/derm/manifests', '/derm/manifests/health', '/derm/upload', '/derm/monthly']) if (!got.links.includes(want)) fails.push('no link to ' + want)
    const own = Object.entries(seen.labels).filter(([k]) => !/get_my_access|portal_waiting|portal_search/.test(k))
    if (!own.length) fails.push('the module asked for no data')
    for (const [k, v] of own) if (![...v].every((x) => x === 'derm-tracker')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'derm module')
    if (w >= 1280) {
      await page.locator('nav[aria-label="Apps"] a[data-tile="HR App"]').click()
      await page.waitForTimeout(1500)
      const back = await page.evaluate(() => [document.documentElement.dataset.module ?? '', document.documentElement.getAttribute('data-hw-app')])
      if (back[0]) fails.push(`still data-module "${back[0]}" after leaving`)
      if (back[1] !== 'hr') fails.push(`data-hw-app "${back[1]}" after leaving`)
    }
    report(w, 'DERM opens, labels its own', fails)
    await ctx.close()
  }

  // A person with no DERM access who has the address: its own card, and no DERM data asked for.
  {
    const { ctx, page, seen } = await signedIn(FIELD, w, h, PORTAL + 'derm')
    const fails = []
    await page.waitForTimeout(1500)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You do not have access to DERM Tracker/.test(text)) fails.push('no refusal on screen')
    if (/Completed visits/.test(text)) fails.push('the visits page showed')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    await shot(page, w, 'derm no access')
    report(w, 'no DERM access, address', fails)
    await ctx.close()
  }

  // The one bar: the bell and the theme at the top right, each app's title in the bar and not again in the page.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    const bar = w >= 768 ? 'header.shell-header' : 'div.relative.z-50'
    if (!(await page.locator(`${bar} button[aria-label^="Notifications, 4 waiting"]`).count())) fails.push('no bell with 4 waiting')
    if (w >= 768 && !(await page.locator(`${bar} [role="group"][aria-label="Light or dark"]`).count())) fails.push('no theme switch in the bar')
    if (await page.locator('nav[aria-label="Apps"] [role="group"][aria-label="Light or dark"]').count()) fails.push('the theme is still in the sidebar')
    await page.locator(`${bar} button[aria-label^="Notifications"]`).click()
    await page.waitForTimeout(400)
    const items = (await page.getByRole('menuitem').allInnerTexts()).map((x) => x.replace(/\s+/g, ' ').trim())
    if (items.length !== 4) fails.push(`bell rows ${items.join('|')}`)
    if (!items.some((x) => /1 client to phone/.test(x))) fails.push('no call-first row')
    await shot(page, w, 'bell open')
    await page.keyboard.press('Escape')
    if (w >= 768) {
      const title = await page.locator('header.shell-header').innerText()
      if (!/Home/.test(title)) fails.push(`home title "${title.slice(0, 40)}"`)
      await page.locator('main a[href="/calendar"]').click()
      await page.waitForFunction(() => document.documentElement.dataset.module === 'calendar', null, { timeout: 30000 }).catch(() => {})
      await page.waitForTimeout(2000)
      const t2 = await page.locator('header.shell-header').innerText()
      if (!/Visit Calendar/.test(t2) || !/to schedule/.test(t2)) fails.push(`calendar bar "${t2.slice(0, 60)}"`)
      const m = await page.evaluate(() => { const r = document.querySelector('main'); return { own: /to schedule/.test(r.innerText.slice(0, 200)), width: document.documentElement.scrollWidth - innerWidth } })
      if (m.own) fails.push('the Calendar still has its own row')
      if (m.width > 0 && w >= 1024) fails.push('sideways scroll')
      await shot(page, w, 'one bar calendar')
    }
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, 'one bar, bell, theme', fails)
    await ctx.close()
  }
  // A failed bell read says so, and never reads as nothing waiting.
  {
    const { ctx, page } = await signedIn({ ...ADMIN, waitingFails: true }, w, h)
    const fails = []
    const bar = w >= 768 ? 'header.shell-header' : 'div.relative.z-50'
    await page.waitForTimeout(2500)
    await page.locator(`${bar} button[aria-label^="Notifications"]`).click()
    await page.waitForTimeout(400)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/Couldn't load this/.test(text)) fails.push('no failure message')
    if (/Nothing waiting/.test(text)) fails.push('a failed read said nothing is waiting')
    report(w, 'bell read fails', fails)
    await ctx.close()
  }

  // Below 1280 the real sidebar opens as a full-height drawer, and picking an app closes it.
  for (const dw of w < 1280 ? [w, 900] : []) {
    const { ctx, page, seen } = await signedIn(ADMIN, dw, h)
    const fails = []
    await page.getByRole('button', { name: /open menu/i }).click()
    await page.waitForTimeout(600)
    const d = await page.evaluate(() => {
      const n = document.querySelector('nav[aria-label="Apps drawer"]'), box = n?.closest('[role="dialog"]')?.getBoundingClientRect()
      return box ? { left: Math.round(box.left), top: Math.round(box.top), w: Math.round(box.width), h: Math.round(box.height), vh: innerHeight, brand: /UnclogMe/.test(n.innerText), tiles: n.querySelectorAll('a[data-tile]').length, account: !!n.querySelector('button[aria-label="Account menu"]') } : null
    })
    if (!d) fails.push('no drawer')
    else {
      if (d.left !== 0 || d.top !== 0) fails.push(`drawer at ${d.left},${d.top}`)
      if (d.h !== d.vh) fails.push(`drawer ${d.h} high in ${d.vh}`)
      if (!d.brand || !d.tiles || !d.account) fails.push('the drawer is not the whole sidebar')
    }
    await shot(page, dw, 'sidebar drawer')
    await page.locator('nav[aria-label="Apps drawer"] a[data-tile="HR App"]').click()
    await page.waitForTimeout(1500)
    if (await page.locator('nav[aria-label="Apps drawer"]').count()) fails.push('the drawer stayed open')
    if (!/^\/hr/.test(new URL(page.url()).pathname)) fails.push(`went to ${new URL(page.url()).pathname}`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(dw, 'sidebar opens as a drawer', fails)
    await ctx.close()
  }

  // Search everything: Ctrl K from any page, each kind of result goes to the right place, nothing for someone with no such app.
  if (w >= 768) {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    await page.keyboard.press('Control+k')
    await page.waitForTimeout(400)
    await page.getByPlaceholder(/client code or name/i).fill('290')
    await page.waitForTimeout(1200)
    const rows = (await page.getByRole('option').allInnerTexts()).map((x) => x.replace(/\s+/g, ' ').trim())
    if (rows.length !== 4) fails.push(`${rows.length} results: ${rows.join('|')}`)
    if (!rows.some((x) => /Next visit: Tue, Dec 1, Pumping/.test(x))) fails.push('no next visit row')
    const label = [...(seen.labels['rpc/portal_search'] ?? [])].join(',')
    if (label !== 'ops-portal') fails.push(`search labelled "${label}"`)
    await shot(page, w, 'search open')
    await page.getByRole('option', { name: /Next visit/ }).click()
    await page.waitForFunction(() => document.documentElement.dataset.module === 'calendar', null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(1500)
    if (new URL(page.url()).pathname !== '/calendar') fails.push(`visit went to ${new URL(page.url()).pathname}`)
    if (new URL(page.url()).search) fails.push(`the address kept ${new URL(page.url()).search}`)
    await page.locator('button[aria-label="Search everything"]').click()
    await page.waitForTimeout(400)
    await page.getByPlaceholder(/client code or name/i).fill('fred')
    await page.waitForTimeout(1200)
    await page.getByRole('option', { name: /Fred Zerpa/ }).click()
    await page.waitForTimeout(1500)
    if (new URL(page.url()).pathname !== '/hr/employees/2') fails.push(`person went to ${new URL(page.url()).pathname}`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, 'search everything', fails)
    await ctx.close()
    const f = await signedIn(FIELD, w, h)
    const n = await f.page.locator('button[aria-label="Search everything"]').count()
    report(w, 'no search for field', n ? ['field sees the search box'] : [])
    await f.ctx.close()
  }

  // Profile, typed by address, for someone who can open the HR App: straight to their own record (Fred, 2026-11-05).
  {
    const { ctx, page } = await signedIn(ADMIN, w, h, PORTAL + 'profile')
    await page.waitForTimeout(1500)
    const path = new URL(page.url()).pathname
    report(w, 'profile by address, admin', path === '/hr/employees/' + ADMIN.r.employee_id ? [] : [`went to ${path}`])
    await ctx.close()
  }

  // The small Profile page, for someone HR would refuse: their own details, their apps, their own photo.
  for (const [c, apps] of [[FIELD, 3]]) {
    const { ctx, page, seen } = await signedIn(c, w, h, PORTAL + 'profile')
    const fails = []
    const got = await page.evaluate(() => {
      const m = document.querySelector('main')
      const sections = [...m.querySelectorAll('section')]
      return { name: m.querySelector('h1')?.textContent ?? '', text: m.innerText, apps: sections[2]?.querySelectorAll('a').length ?? 0, hr: /Open my HR record/.test(m.innerText), overflow: document.documentElement.scrollWidth > innerWidth, camera: !!m.querySelector('button[aria-label="Change your photo"]'), title: document.title }
    })
    if (got.name !== c.who) fails.push(`name "${got.name}"`)
    if (!got.text.includes(c.who.toLowerCase().replace(/ /g, '.') + '@unclogme.com')) fails.push('no email')
    if (got.apps !== apps) fails.push(`${got.apps} apps, want ${apps}`)
    if (got.hr) fails.push('an HR button on the small page')
    if (!got.camera) fails.push('no camera button')
    if (got.overflow) fails.push('sideways scroll')
    if (got.title !== 'Profile · Ops Portal · UnclogMe') fails.push(`title "${got.title}"`)
    if (/Hourly|Bonus|\$/.test(got.text)) fails.push('pay on the page')
    await shot(page, w, `profile ${c.group}`)
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64')
    await page.setInputFiles('main input[type=file]', { name: 'me.png', mimeType: 'image/png', buffer: png })
    await page.waitForTimeout(1500)
    if (seen.photoCall?.p_employee_id !== c.r.employee_id) fails.push(`photo call ${JSON.stringify(seen.photoCall)}`)
    if (!String(seen.photoCall?.p_path).startsWith(c.r.employee_id + '/')) fails.push(`photo path ${seen.photoCall?.p_path}`)
    if (!/Photo updated/.test(await page.evaluate(() => document.querySelector('main').innerText))) fails.push('no "Photo updated"')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, `profile, ${c.group}`, fails)
    await ctx.close()
  }

  // The account menu: Profile and Sign out. Profile is the person's HR record; with no HR access, the small page.
  for (const c of [ADMIN, FIELD]) {
    const { ctx, page, seen } = await signedIn(c, w, h)
    const fails = []
    if (w < 1280) await page.getByRole('button', { name: /open menu/i }).click()
    await page.getByRole('button', { name: 'Account menu' }).click()
    const items = (await page.getByRole('menuitem').allInnerTexts()).map((x) => x.trim())
    const want = ['Profile', 'Sign out']
    if (JSON.stringify(items) !== JSON.stringify(want)) fails.push(`menu ${items.join('|')}`)
    await shot(page, w, `account menu ${c.group}`)
    await page.getByRole('menuitem', { name: 'Profile' }).click()
    await page.waitForTimeout(1500)
    const wantPath = c === ADMIN ? '/hr/employees/' + c.r.employee_id : '/profile'
    if (new URL(page.url()).pathname !== wantPath) fails.push(`Profile went to ${new URL(page.url()).pathname}, want ${wantPath}`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, `account menu, ${c.group}`, fails)
    await ctx.close()
  }

  // The collapse button: icons only, every app still reachable, theme and sign-out still there, remembered after a reload.
  if (w >= 1280) {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    const size = () => page.evaluate(() => {
      const nav = document.querySelector('nav[aria-label="Apps"]'), main = document.querySelector('main')
      return { nav: Math.round(nav.getBoundingClientRect().width), main: Math.round(main.getBoundingClientRect().width), tiles: nav.querySelectorAll('a[data-tile]').length, overflow: nav.scrollWidth > nav.clientWidth + 1 }
    })
    const open = await size()
    if (open.nav !== 228) fails.push(`open width ${open.nav}`)
    // In the top bar, not on the sidebar (Fred, 2026-11-06).
    if (!(await page.locator('header.shell-header button[aria-label="Collapse the sidebar"]').count())) fails.push('the collapse button is not in the top bar')
    if (await page.locator('nav[aria-label="Apps"] button[aria-label$="the sidebar"]').count()) fails.push('the collapse button is still on the sidebar')
    await page.getByRole('button', { name: 'Collapse the sidebar' }).click()
    const shut = await size()
    if (shut.nav !== 64) fails.push(`collapsed width ${shut.nav}`)
    if (shut.main !== open.main + 164) fails.push(`main ${open.main} to ${shut.main}`)
    if (shut.tiles !== open.tiles) fails.push(`${shut.tiles} of ${open.tiles} apps left`)
    if (shut.overflow) fails.push('the icons do not fit')
    for (const name of ['Account menu']) if (!(await page.locator(`nav[aria-label="Apps"] button[aria-label="${name}"]`).count())) fails.push(`no ${name}`)
    await shot(page, w, 'sidebar collapsed')
    await page.reload(); await page.waitForTimeout(2500)
    const after = await size()
    if (after.nav !== 64) fails.push(`after a reload ${after.nav}`)
    await page.getByRole('button', { name: 'Expand the sidebar' }).click()
    if ((await size()).nav !== 228) fails.push('did not expand')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    report(w, 'sidebar collapses, remembered', fails)
    await ctx.close()
  }

  // Sign out: asks Supabase once, reloads, and comes back to the login with nothing left on screen.
  {
    const { ctx, page, seen } = await signedIn(ADMIN, w, h)
    const fails = []
    const before = seen.navs
    if (w < 1280) await page.getByRole('button', { name: /open menu/i }).click()
    if (await page.getByRole('button', { name: /^sign out$/i }).count()) fails.push('a sign-out button outside the account menu')
    await page.getByRole('button', { name: 'Account menu' }).click()
    await page.getByRole('menuitem', { name: /^sign out$/i }).click()
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
