// Home by role (2026-11-16, Trello #210): the tiles left Home. Each person now sees the Home of their group (data-home: field,
// office or admin), its parts (data-home-part) by what they can open, and the apps outside the portal; the app blocks get in
// through the menu. The bell and the Home's "Needs you" read one list of ten rows; portal_home and portal_my_work are answered
// here, portal_my_work only through the database's one door (POST, content-profile ops).
// Stage D (2026-11-14): the Stamp case also opens one sheet from a Manifests row's three dots (the new stamping screen),
// and the refusal by address is checked on a sheet's own address.
// Stage C step 2 (2026-11-14): the Manifests case (two list doors, the Upload button, Health, the sheet list door for Stamp
// people, the bell's sheet row on "Needs someone", derm-tracker labels, no stamp read), and the DERM case reaches Upload by
// the page's button, not a tab.
// live-portal-tiles.mjs: THE STANDING CHECK of the Ops Portal, signed in, for each kind of person: the menu by function,
// Clients inside and Finances, as live since the Clients publish of 2026-11-15 about 5:40 AM ET
// (plan: Building Apps/Ops Portal/docs/specs/2026-11-12-redesign-by-function.md, section 3 and Stage A).
// Signs in with a fake session and answers every Supabase call locally: data, storage, sign-in, the server function the
// Monthly report calls (refused, as a made-up token would be) and the live socket (closed here). Nothing reaches Supabase.
// PASS = each person sees exactly their Home (its kind, its parts, the apps outside) and exactly their menu (ids, words,
// headings, in order), one lit item,
// the page's name or its tabs in the bar, no link above a refusal, no sideways scroll, and the sign-in needed no reload;
// every page has a way in from the menu; each app opens, labels its own requests, and a sign-out starts clean.
// PORTAL=http://localhost:8080/ runs it before a publish. SHOTS=<dir> keeps a picture of each case.
// CONTROL=1 expects a Field person to see an Admin's Home and menu: every field case must then FAIL, or this check cannot fail.
// CONTROL=menu hides the new menu from this check (it takes the menu's new names off the page, as on the old build): every
// case that reads or uses the menu must then FAIL, and the run must still reach its last line.
// ONLY=<words> runs the cases whose name holds those words, to look at one again. The last line then says it was not a whole run.
// CONTROL=finances expects the Finances group for a person whose Client App is at None: that case must then FAIL, or this check
// cannot see the group (Finances, Fred 2026-11-14: "btw also build the finance tab on the sidebar", opened by the Client App
// setting).
// ** Two changes of 2026-11-14 are in this check (written in mockups/2026-11-14-clients-screens/F/): (1) the Client App's move
// (Clients is a page inside, its tile opens /clients); (2) Finances (marked "Finances" below).
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const PORTAL = process.env.PORTAL || 'https://ops.unclogme.app/'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')

// The apps outside the portal at the bottom of Home, each in a new tab: Sales App and Review Assist need an app open.
const OUT_ALL = ['Field Portal', 'DUMP Schedule', 'Sales App', 'Review Assist']
const OUT_FEW = ['Field Portal', 'DUMP Schedule']
// The menu by function, in the plan's order: id, word, heading, address. My forms leaves the portal (a new tab).
const MENU = [
  ['home', 'Home', null, '/'], ['calendar', 'Calendar', 'Work', '/calendar'], ['clients', 'Clients', 'Work', '/clients'],
  ['reviews', 'Reviews', 'Work', '/review'], ['site-files', 'Site files', 'Work', '/planner'], ['my-forms', 'My forms', 'Work', 'https://planner.unclogme.app'],
  ['manifests', 'Manifests', 'Compliance', '/derm/manifests'], ['address-sheets', 'Address sheets', 'Compliance', '/stamp'],
  // #216 DV1 (2026-11-24): DERM visits left the menu; its list is the Visits tab of Manifests (/derm sends there)
  ['monthly-report', 'Monthly report', 'Compliance', '/derm/monthly'],
  ['gdo-lookup', 'GDO lookup', 'Compliance', '/derm/gdo-lookup'], // Trello #242, 2026-11-24
  ['pumped-water', 'Pumped water', 'Metrics', '/review/water'], ['pumped-grease', 'Pumped grease', 'Metrics', '/review/grease'],
  // Finances, under Metrics, opened by the Client App setting.
  ['invoices', 'Invoices', 'Finances', '/finances/invoices'], ['quotes', 'Quotes', 'Finances', '/finances/quotes'], ['payments', 'Payments', 'Finances', '/finances/payments'],
  ['people', 'People', 'Team', '/hr'], ['access', 'Access', 'Team', '/hr/access'],
]
const FINANCES = ['invoices', 'quotes', 'payments']
const OFFICE_MENU = ['home', 'calendar', 'clients', 'reviews', 'site-files', 'manifests', 'monthly-report', 'gdo-lookup', 'pumped-water', 'pumped-grease', ...FINANCES, 'people']
const ADMIN_MENU = [...OFFICE_MENU, 'access']
const TOP = ['hr', 'admin_review', 'client_app', 'visit_calendar', 'derm_tracker', 'stamp_studio', 'picture_planner']
const SUBS = { hr_pay: 'hr', hr_bonus: 'hr', pp_approve: 'picture_planner', pp_forms: 'picture_planner' }
function reply(id, group, levels, modes = {}) {
  const apps = [...TOP, ...Object.keys(SUBS)].map((a) => ({ app: a, parent: SUBS[a] ?? null, mode: modes[a] ?? 'on', level: levels[a] ?? (SUBS[a] ? 'no' : 'none') }))
  return { employee_id: id, group, apps }
}
const every = (lvl) => Object.fromEntries(TOP.map((a) => [a, lvl]))
const control = Boolean(process.env.CONTROL) && process.env.CONTROL !== 'menu' && process.env.CONTROL !== 'finances'
const noMenu = process.env.CONTROL === 'menu'
const financesControl = process.env.CONTROL === 'finances'
const ONLY = process.env.ONLY
const ADMIN = { who: 'Fred Zerpa', group: 'admin', r: reply(2, 'admin', { ...every('edit'), pp_forms: 'yes' }), menu: ADMIN_MENU }
const OFFICE = { who: 'Diego Test', group: 'office', r: reply(28, 'office', every('edit')), menu: OFFICE_MENU }
const FIELD = { who: 'Mark Test', group: 'field', hello: ', Mark', r: reply(59, 'field', { pp_forms: 'yes' }), menu: ['home', 'my-forms'] }
const STAMP_ONLY = { who: 'Stamp Test', group: 'office', r: reply(31, 'office', { stamp_studio: 'edit' }), menu: ['home', 'address-sheets'] }
const less = (list, ...gone) => list.filter((x) => !gone.includes(x))
// The rows of "Who sees what" (plan, section 3.3) that a browser can tell apart. walk: the bar is read on one page of each area.
const CASES = [
  { name: 'admin, edit everywhere', ...ADMIN, out: OUT_ALL, hello: ', Fred', role: 'Admin', card: false, walk: true },
  { name: 'office, edit everywhere', ...OFFICE, out: OUT_ALL, hello: ', Diego', role: 'Office', card: false, walk: true },
  { name: 'office, view everywhere', who: 'Vera Test', group: 'office', r: reply(32, 'office', every('view')), menu: OFFICE_MENU, out: OUT_ALL, hello: ', Vera', role: 'Office', card: false, walk: true },
  { name: 'office, HR App none', who: 'Aaron Test', group: 'office', r: reply(26, 'office', { ...every('edit'), hr: 'none' }), menu: less(OFFICE_MENU, 'people'), out: OUT_ALL, hello: ', Aaron', role: 'Office', card: true, walk: true },
  { name: 'office, Admin Review none', who: 'Nora Test', group: 'office', r: reply(33, 'office', { ...every('edit'), admin_review: 'none' }), menu: less(OFFICE_MENU, 'reviews', 'pumped-water', 'pumped-grease'), out: OUT_ALL, hello: ', Nora', role: 'Office', card: true, walk: true },
  { name: 'office, DERM Tracker none', who: 'Dana Test', group: 'office', r: reply(34, 'office', { ...every('edit'), derm_tracker: 'none' }), menu: ['home', 'calendar', 'clients', 'reviews', 'site-files', 'address-sheets', 'pumped-water', 'pumped-grease', ...FINANCES, 'people'], out: OUT_ALL, hello: ', Dana', role: 'Office', card: true, walk: true },
  { name: 'office, Stamp Studio none', who: 'Sam Test', group: 'office', r: reply(35, 'office', { ...every('edit'), stamp_studio: 'none' }), menu: OFFICE_MENU, out: OUT_ALL, hello: ', Sam', role: 'Office', card: true, walk: true },
  // Finances follows the Client App setting: no Clients, no Finances heading at None (CONTROL=finances expects them: FAIL).
  { name: 'office, Client App none', who: 'Cleo Test', group: 'office', r: reply(38, 'office', { ...every('edit'), client_app: 'none' }), menu: financesControl ? OFFICE_MENU : less(OFFICE_MENU, 'clients', ...FINANCES), out: OUT_ALL, hello: ', Cleo', role: 'Office', card: true, walk: true },
  { name: 'one app, the Client App at View', who: 'Vic Test', group: 'office', r: reply(39, 'office', { client_app: 'view' }), menu: ['home', 'clients', ...FINANCES], out: OUT_ALL, hello: ', Vic', role: 'Office', card: true, walk: true },
  { name: 'one app, the Visit Calendar', who: 'Cal Test', group: 'office', r: reply(36, 'office', { visit_calendar: 'edit' }), menu: ['home', 'calendar'], out: OUT_ALL, hello: ', Cal', role: 'Office', card: true, walk: true },
  { name: 'no app at all', who: 'Nobody Test', group: 'office', r: reply(37, 'office', {}), menu: control ? ADMIN_MENU : ['home'], out: control ? OUT_ALL : OUT_FEW, hello: ', Nobody', role: 'Office', card: true, walk: true },
  { name: 'field, assigned forms', ...FIELD, menu: control ? ADMIN_MENU : FIELD.menu, out: control ? OUT_ALL : OUT_FEW, kind: control ? 'admin' : 'field', role: 'Field', card: true, text: 'Canned Bistro', walk: true },
  { name: 'field, no forms switch', who: 'Grecia Test', group: 'field', hello: ', Grecia', r: reply(1, 'field', {}), menu: control ? ADMIN_MENU : ['home'], out: control ? OUT_ALL : OUT_FEW, kind: control ? 'admin' : 'field', role: 'Field', card: true, walk: true },
  { name: 'access check fails', who: 'Fred Zerpa', group: 'admin', fail: true, text: "We couldn't load your apps" },
  { name: 'not staff', who: 'Some Stranger', group: 'field', r: { employee_id: null, group: null, apps: [] }, text: 'is not an UnclogMe staff account', login: true },
]
// What a person's settings open, worked out here on its own, not from the app's code. Every setting is switched on.
const level = (c, a) => c.r?.apps?.find((x) => x.app === a)?.level
const can = (c, a) => ['view', 'edit'].includes(level(c, a))
const opensAny = (c) => TOP.some((a) => can(c, a))
const formsOnly = (c) => !can(c, 'picture_planner') && level(c, 'pp_forms') === 'yes'
const mailOf = (who) => who.toLowerCase().replace(/ /g, '.') + '@unclogme.com'
const PEOPLE = [{ id: 2, full_name: 'Fred Zerpa', email: mailOf('Fred Zerpa'), status: 'ACTIVE', access_level: 'admin', role: null, color_hex: '#3F6212', photo_path: null, phone: null, start_date: null, payroll_week_start_day: 5 }]
// As the database answers a person with no app open (public.fn_request_gate, measured 2026-11-09).
const REFUSED = { status: 403, contentType: 'application/json', body: '{"code":"42501","message":"You do not have access to any UnclogMe app."}' }
// Every row the bell and the Home can hold (Trello #210): ten, each above 0.
const TEN = { late_today: 1, requests_open: 2, call_first: 2, manifests_need_someone: 3, stamp_sheets: 6, city_emails: 5, photos_unsorted: 4, unopened_emails: 8, site_files: 7, time_on_site: 3, reviews_pending: 9 }
// The Home's reads, made up: one truck today, a week, the Business band for an admin (each part by the app that holds it, as
// the database decides), and a driver's day with one stop, a truck with a tank reading and, with the forms switch, one form.
const DAY = new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
const plusDays = (n) => new Date(Date.parse(DAY + 'T12:00:00Z') + n * 864e5).toISOString().slice(0, 10)
function cannedHome(c) {
  const out = { date: DAY, prev_start: plusDays(-40) }
  if (can(c, 'visit_calendar')) Object.assign(out, {
    today: { visits: 12, done: 3, left: 9, late: 2, skipped: 0 },
    trucks: [{ name: 'Moises', color: '#1E40AF', visits: 6, done: 0, left: 6, first_at: new Date(Date.now() + 3 * 36e5).toISOString(), crew: [{ name: 'Canned Driver', color: '#0EA5E9' }] }],
    week: [0, 1, 2, 3, 4, 5, 6].map((i) => ({ date: plusDays(i), visits: 7 - i })),
  })
  if (c.group === 'admin') out.business = {
    ...(can(c, 'client_app') ? { invoices: { count: 10, total: 1000, prev_count: 8, prev_total: 900 }, past_due: { amount: 500, clients: 2, top: [{ id: 450, code: '000-ZZ', amount: 300 }] } } : {}),
    ...(can(c, 'admin_review') ? { pumped: { gallons: 1200, prev_gallons: 1000, trucks: [{ name: 'Moises', visits: 5, measured: 5 }, { name: 'Cloggy', visits: 3, measured: 0 }] } } : {}),
  }
  return out
}
const cannedMine = (c) => ({
  date: DAY, done_7d: 4,
  stops: [{ id: 9072, at: null, all_day: true, status: 'scheduled', late: false, code: '000-ZZ', client: 'Canned Diner', address: '1 Test St', city: 'Miami', zone: 'MID', lat: 25.8, lng: -80.2, work: 'Pumping', manholes: 2, trap: 1000, derm: true, open_from: '21:00', open_to: '06:00', truck: 'Moises', site_file: 'canned-site-file' }],
  truck: { name: 'Moises', tanks: [{ contents: 'sludge', percent: 40, gallons: 1500, at: new Date().toISOString() }] },
  forms: level(c, 'pp_forms') === 'yes' ? [{ id: 77, code: '000-ZZ', client: 'Canned Bistro', expires_at: null }] : [],
})
const kindOf = (c) => c.kind ?? (c.group === 'field' ? 'field' : c.group === 'admin' ? 'admin' : 'office')
// The parts of the Home a person sees, worked out here from their settings, not from the app's code.
function partsFor(c) {
  if (kindOf(c) === 'field') return ['next', 'stops', 'truck', 'forms', 'week', 'outside']
  const p = []
  if (c.group === 'admin' && opensAny(c)) p.push('business', ...(can(c, 'client_app') ? ['invoices', 'past-due'] : []), ...(can(c, 'admin_review') ? ['pumped'] : []), ...(can(c, 'visit_calendar') ? ['team'] : []))
  if (opensAny(c)) p.push('needs')
  if (can(c, 'visit_calendar')) p.push('today', 'week')
  return [...p, 'outside']
}

const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })

async function signedIn(c, w, h, goto = PORTAL) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } })
  // clock: the bar's clock is wider at some hours than at others, so a case that measures the bar sets the hour first.
  if (c.clock) await ctx.clock.install({ time: new Date(c.clock) })
  const page = await ctx.newPage()
  if (process.env.DARK) await page.addInitScript(() => localStorage.setItem('unclogme.theme', 'dark')) // DARK=1 with SHOTS=<dir> to look at dark mode
  // CONTROL=menu: the sidebar and the drawer lose their new name as soon as they are drawn, so nothing here can find the menu.
  if (noMenu) await page.addInitScript(() => new MutationObserver(() => { for (const n of document.querySelectorAll('nav[aria-label^="Main menu"]')) n.setAttribute('aria-label', 'hidden from the check') }).observe(document, { childList: true, subtree: true }))
  const now = c.clock ? new Date(c.clock).getTime() : Date.now()
  const exp = Math.floor(now / 1000) + 3600, sub = '00000000-0000-4000-8000-000000000' + String(c.r?.employee_id ?? 2).padStart(3, '0')
  const mail = mailOf(c.who)
  const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub, email: mail, role: 'authenticated', aud: 'authenticated', exp, aal: 'aal1' })}.${Buffer.alloc(32, 7).toString('base64url')}`
  const user = { id: sub, aud: 'authenticated', role: 'authenticated', email: mail, email_confirmed_at: '2026-01-01T00:00:00Z', app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {} }
  const seen = { navs: 0, signOut: [], stray: new Set(), labels: {}, errors: [], loggedIn: false, fn: [], sockets: 0 }
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) seen.navs++ })
  page.on('pageerror', (e) => seen.errors.push(String(e).slice(0, 160)))
  page.on('request', (q) => {
    const u = q.url(); if (!/supabase\.co/.test(u)) return
    if (!/wbasvhvvismukaqdnouk/.test(u)) seen.stray.add(new URL(u).host)
    const m = u.match(/\/rest\/v1\/(rpc\/[a-z_]+|[a-z_]+)/); if (m) (seen.labels[m[1]] ??= new Set()).add(q.headers()['x-app-source'] ?? 'NONE')
  })
  // The live socket is closed here, before any case opens a page that asks for one: it never reaches the real backend.
  await page.routeWebSocket(/supabase\.co/, (ws) => { seen.sockets++; ws.close() })
  // A server function is refused, as the real gateway refuses a made-up token. The Monthly report calls lwt-monthly twice when
  // it opens: answered with {} that page crashes for a reason that is not the menu's, answered with a refusal it stands.
  await page.route('**/functions/v1/**', (r) => { seen.fn.push(new URL(r.request().url()).pathname.split('/').pop()); r.fulfill({ status: 401, contentType: 'application/json', body: '{"code":401,"message":"Invalid JWT"}' }) })
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
        clients: [{ id: 450, code: '000-ZZ', name: 'Canned Diner', status: 'ACTIVE' }],
        visits: [{ id: 9072, client_code: '000-ZZ', client_name: 'Canned Diner', visit_date: '2026-12-01', start_at: null, is_all_day: true, service: 'Pumping', truck: 'Moises', driver: 'Grecia', kind: 'next' }],
        requests: [{ id: 91, client_code: '000-ZZ', client_name: 'Canned Diner', service: '22 - Service Call - Labor', age_days: 3, call_required: false }],
        people: [{ id: 2, full_name: 'Fred Zerpa', access_level: 'admin', color_hex: '#3F6212' }],
      }) })
    }
    // Finances, Payments: an empty list and no month, in the shapes the page reads (anything else it says it could not load).
    if (/rpc\/list_payments/.test(u)) return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ total: 0, money_in: 0, money_out: 0, fees: 0, limit: 25, offset: 0, payments: [] }) })
    if (/rpc\/payment_months/.test(u)) return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ from: '2025-10-01', to: '2026-11-14', months: [] }) })
    if (/rpc\/portal_waiting/.test(u)) {
      seen.waitingAsked = true
      if (c.waitingFails) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      if (!opensAny(c)) return r.fulfill(REFUSED)
      // The first reply keeps three keys at 0 or missing, as before. Bell rows: call first, time on site, photos = three
      // (requests left the bell in round B, unopened emails on 2026-11-18: Fred, "The bell doesn't need a notification for
      // unopened emails"). c.waiting gives another one.
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.waiting ?? { call_first: 1, requests_open: 3, time_on_site: 6, photos_unsorted: 8, city_emails: 0, stamp_sheets: 0, unopened_emails: 9 }) })
    }
    if (/rpc\/portal_home/.test(u)) {
      seen.homeAsked = true
      if (!opensAny(c)) return r.fulfill(REFUSED)
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(cannedHome(c)) })
    }
    // The database's one door for a person with no app open: POST, schema ops. Anything else would be refused.
    if (/rpc\/portal_my_work/.test(u)) {
      seen.mineAsked = true
      if (r.request().method() !== 'POST' || r.request().headers()['content-profile'] !== 'ops') { seen.mineOffDoor = true; return r.fulfill(REFUSED) }
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(cannedMine(c)) })
    }
    if (/rpc\/get_my_access/.test(u)) {
      if (c.fail) return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"canned failure"}' })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(c.r?.employee_id ? { ...c.r, me: { full_name: c.who, color_hex: '#14B8A6', photo_path: null } } : c.r) })
    }
    if (/\/employees/.test(u)) {
      if (!opensAny(c)) return r.fulfill(REFUSED)
      if (one) return r.fulfill({ status: 200, contentType: 'application/vnd.pgrst.object+json', body: JSON.stringify({ full_name: c.who, color_hex: '#14B8A6' }) })
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ ...PEOPLE[0], full_name: c.who }]) })
    }
    // Stage D: one made-up ticket, #000001, so the Manifests list has a row whose three dots open its address sheet, and
    // the stamping screen has a sheet to read. Every name here is invented.
    if (c.sheet) {
      const name = (u.match(/\/rest\/v1\/([^?]+)/) ?? [])[1]
      ;(seen.stampAsked ??= []).push({ name, label: r.request().headers()['x-app-source'] ?? 'NONE', keyed: Boolean(r.request().headers()['x-stamp-key']) })
      const J = (b) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(b) })
      if (name === 'derm_manifests') return J([{ id: 990001, white_manifest_number: '000001', yellow_ticket_number: null, derm_manifest_url: null, derm_address_url: null, derm_manifest_extra_urls: null, derm_address_extra_urls: null, dump_ticket_date: '2026-11-02', service_date: '2026-11-01', disposal_facility_id: null, created_at: '2026-11-02T12:00:00Z', deleted_at: null, derm_address_no: null }])
      if (name === 'rpc/manifest_row_states') return J({ 990001: { key: '990001', manifest_ids: [990001], needs: false, worst: 'ok', test: false, papers: { s: 'ok', code: 'ok', t: 'Papers on file' }, stamps: { s: 'ok', code: 'ok', t: 'Stamped' }, city: { s: 'na', code: 'none', t: 'No city program' }, sheets: [{ folder: 'ticket-000001', number: '000001', state: 'completed', placed: 1, total: 1 }] } })
      if (name === 'v_stamp_sheets') return J([{ dump_folder: 'ticket-000001', white_manifest_number: '000001', service_date: '2026-11-01', dump_date: '2026-11-02', page_count: 1, page_image_urls: ['https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/990001/address_1.jpg'], total_rows: 0, matched_rows: 0, placed_rows: 0, completed: true, completed_at: '2026-11-02T15:00:00Z', is_generated: false, filled_by_ai: null, ai_placed_rows: null, skipped: false, missing_scan: null }])
      if (name === 'rpc/stamp_sheet_facts') { seen.facts = (seen.facts ?? 0) + 1; return J({ completed: true, completed_at: '2026-11-02T15:00:00Z', completed_by: 'someone', reopened_at: null, reopened_by: null, copies: null }) }
      if (name === 'rpc/fn_sheet_publishable_detail') return J({ blocker: null, message: null })
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

let bad = 0, lines = 0
const report = (w, name, fails, note = '') => { lines++; if (fails.length) bad++; console.log(`${String(w).padEnd(5)} ${name.padEnd(38)} ${fails.length ? 'FAIL  ' + fails.join('; ') : 'PASS' + (note ? '  ' + note : '')}`) }
const shot = async (page, w, name) => { if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/${w}-${name.replace(/[^a-z]+/gi, '-')}.png` }).catch(() => {}) }
// One case in its own sign-in. Whatever goes wrong inside is a FAIL line, never the end of the run: on the old build a
// menu item that is not there must fail its case and let the next one start.
async function block(w, h, name, c, goto, fn) {
  if (ONLY && !name.includes(ONLY)) return
  const fails = []; let s, note
  try { s = await signedIn(c, w, h, goto); note = await fn({ ...s, fails }) } catch (e) { fails.push('stopped: ' + String(e).split('\n')[0].slice(0, 150)) }
  await s?.ctx.close().catch(() => {})
  report(w, name, fails, note)
}
// A click that reports instead of waiting 30 seconds for something that is not there.
const tap = async (target, fails, what) => {
  if (!(await target.count())) { fails.push('nothing to click: ' + what); return false }
  return target.first().click({ timeout: 8000 }).then(() => true, (e) => { fails.push(`${what} could not be clicked: ${String(e).split('\n')[0].slice(0, 90)}`); return false })
}
const at = (page) => new URL(page.url()).pathname
const arrive = (page, path, ms = 15000) => page.waitForFunction((p) => location.pathname === p, path, { timeout: ms }).then(() => true, () => false)
const SIDE = 'nav[aria-label="Main menu"]', DRAWER = 'nav[aria-label="Main menu drawer"]', BAR = 'header.shell-header > div.flex-1'
// The menu a person has on screen: the sidebar from 1280, the drawer below it (opened here when it is shut).
async function menuNav(page, w, fails) {
  if (w >= 1280) return SIDE
  const open = page.locator(`[role="dialog"][data-state="open"] ${DRAWER}`)
  if (!(await open.count())) {
    // A drawer that is still sliding shut after the last pick is not an open one: wait for it to go, then open it again.
    await page.locator(DRAWER).waitFor({ state: 'detached', timeout: 3000 }).catch(() => {})
    if (await tap(page.getByRole('button', { name: /open menu/i }), fails, 'the menu button')) await open.waitFor({ timeout: 5000 }).catch(() => {})
    await page.waitForTimeout(450)
  }
  return DRAWER
}
const shutMenu = async (page, w) => { if (w < 1280 && (await page.locator(DRAWER).count())) { await page.keyboard.press('Escape'); await page.locator(DRAWER).waitFor({ state: 'detached', timeout: 5000 }).catch(() => {}) } }
// Picking an item in the drawer closes it: the pick is done when it has gone.
const pick = async (page, w, id, fails) => {
  const done = await tap(page.locator(`${await menuNav(page, w, fails)} a[data-menu="${id}"]`), fails, `the menu item "${id}"`)
  if (done && w < 1280) await page.locator(DRAWER).waitFor({ state: 'detached', timeout: 4000 }).catch(() => {})
  return done
}
// Every item of the menu, as drawn: its heading is the text above its group (Home has none).
async function readMenu(page, w, fails) {
  const nav = await menuNav(page, w, fails)
  return page.evaluate((sel) => {
    const n = document.querySelector(sel)
    return n ? [...n.querySelectorAll('a[data-menu]')].map((a) => ({ id: a.dataset.menu, word: a.textContent.trim(), heading: a.parentElement.previousElementSibling?.textContent.trim() || null, href: a.getAttribute('href'), tab: a.getAttribute('target') || '', lit: a.getAttribute('aria-current') === 'page', routerMark: a.hasAttribute('data-status'), icons: a.querySelectorAll('svg').length })) : null
  }, nav)
}
// The exact menu: ids, words, headings and addresses in order, an icon on each, the outside mark and a new tab only on what leaves.
function menuFails(got, ids) {
  if (!got) return ['no menu on screen']
  const want = MENU.filter(([id]) => ids.includes(id)), out = []
  if (JSON.stringify(got.map((i) => [i.id, i.word, i.heading, i.href])) !== JSON.stringify(want)) out.push(`menu ${got.map((i) => i.id + (i.heading ? ' under ' + i.heading : '')).join(' | ') || 'empty'}`)
  for (const i of got) {
    const outside = /^https:/.test(i.href ?? '')
    if (outside ? i.tab !== '_blank' || i.icons !== 2 : i.tab || i.icons !== 1) out.push(`${i.id} opens "${i.tab}" with ${i.icons} icons`)
    if (i.routerMark) out.push(`${i.id} carries the router's own mark`)
  }
  return out
}
// Exactly one item is lit, or none: only a[data-menu] is counted (the brand link is not a menu item).
const litFails = (got, id) => { const lit = (got ?? []).filter((i) => i.lit).map((i) => i.id); return JSON.stringify(lit) === JSON.stringify(id ? [id] : []) ? [] : [`lit ${lit.join(',') || 'nothing'}, want ${id ?? 'nothing'}`] }
// The bar (from 768) or, on a phone, the band a page keeps for its tabs.
const readBar = (page, wide) => page.evaluate(([wide, BAR]) => {
  const slot = document.querySelector(BAR), vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 }
  const band = [...document.querySelectorAll('main header.border-b > nav a, main nav[aria-label="Picture Planner"] a')].filter(vis)
  return { text: wide && slot ? slot.innerText.replace(/\s+/g, ' ').trim() : '', links: (wide ? [...(slot?.querySelectorAll('a') ?? [])] : band).map((a) => a.getAttribute('href')), body: document.body.innerText, sideways: document.documentElement.scrollWidth - window.innerWidth }
}, [wide, BAR])
// One page of each area: what the bar holds for a person who can open it, and the lit item.
const AREAS = [
  { at: 'calendar', app: 'visit_calendar', name: 'Visit Calendar', title: 'Calendar', lit: 'calendar' },
  { at: 'derm/manifests/visits', app: 'derm_tracker', name: 'DERM Tracker', links: ['/derm/manifests', '/derm/manifests/visits', '/derm/manifests/health'], lit: 'manifests' },
  // Stage C step 2: Upload is the page's orange button, not a link of the bar
  { at: 'derm/manifests', app: 'derm_tracker', name: 'DERM Tracker', links: ['/derm/manifests', '/derm/manifests/visits', '/derm/manifests/health'], lit: 'manifests' },
  { at: 'review', app: 'admin_review', name: 'Admin Review', title: 'Reviews', lit: 'reviews' },
  { at: 'planner', app: 'picture_planner', name: 'Picture Planner', links: ['/planner', '/planner/forms'], lit: 'site-files' },
  { at: 'hr/employees', app: 'hr', name: 'HR App', title: 'People', lit: 'people' },
  { at: 'stamp', app: 'stamp_studio', name: 'Stamp Studio', title: 'Address sheets', lit: 'manifests' },
  // Finances: its pages are the Client App setting's, so a refusal names the Client App.
  { at: 'finances/payments', app: 'client_app', name: 'Client App', title: 'Payments', lit: 'payments' },
]
const OLD_NAMES = /Visit Calendar|DERM Tracker|Stamp Studio|Admin Review|Picture Planner|HR App/
function wantOn(c, area) {
  const forms = area.at === 'planner' && formsOnly(c)
  // The lit item follows the address and the person's menu, a refusal or not: someone with the DERM Tracker and no Stamp
  // Studio who types the sheet list's address gets the refusal with Manifests lit (the sheet pages light Manifests).
  const lit = c.menu.includes(area.lit) ? area.lit : area.at === 'stamp' && c.menu.includes('address-sheets') ? 'address-sheets' : null
  if (!can(c, area.app) && !forms) return { path: '/' + area.at, refusal: `You do not have access to ${area.name}`, links: [], lit }
  if (forms) return { path: '/planner/forms', links: ['/planner/forms'], lit: null }
  const links = area.links ? [...area.links, ...(area.at.startsWith('derm/manifests') && can(c, 'stamp_studio') ? ['/stamp'] : [])] : []
  return { path: '/' + area.at, title: area.title, links, lit }
}
async function walk(page, w, c, fails) {
  const wide = w >= 768
  for (const area of AREAS) {
    const want = wantOn(c, area), where = '/' + area.at
    await page.goto(PORTAL + area.at, { waitUntil: 'domcontentloaded' })
    await page.waitForFunction(([want, wide, BAR]) => {
      if (want.refusal) return document.body.innerText.includes(want.refusal)
      const box = document.querySelector(wide ? BAR : 'main'); if (!box) return false
      if (want.links.length) return want.links.every((h) => box.querySelector(`a[href="${h}"]`))
      return wide ? box.innerText.includes(want.title) : box.innerText.length > 20
    }, [want, wide, BAR], { timeout: 9000 }).catch(() => {})
    await page.waitForTimeout(350)
    const got = await readBar(page, wide)
    if (at(page) !== want.path) fails.push(`${where} is at ${at(page)}`)
    if (want.refusal ? !got.body.includes(want.refusal) : /You do not have access to/.test(got.body)) fails.push(`${where} ${want.refusal ? 'shows no refusal' : 'refuses'}`)
    if (JSON.stringify(got.links) !== JSON.stringify(want.links)) fails.push(`${where} ${wide ? 'bar' : 'band'} links ${got.links.join(' ') || 'none'}`)
    if (wide && want.title && !got.text.startsWith(want.title)) fails.push(`${where} bar says "${got.text.slice(0, 40)}"`)
    if (wide && OLD_NAMES.test(got.text)) fails.push(`${where} bar still names an app: "${got.text.slice(0, 40)}"`)
    if (got.sideways > 0) fails.push(`${where} scrolls sideways by ${got.sideways} px`)
    if (w >= 1280) fails.push(...litFails(await readMenu(page, w, fails), want.lit).map((x) => `${where} ${x}`))
  }
}

for (const [w, h] of [[1440, 900], [375, 812]]) {
  for (const c of CASES) {
    if (ONLY && !c.name.includes(ONLY)) continue
    let fails = [], ctx
    try {
      const s = await signedIn(c, w, h); ctx = s.ctx
      const { page, seen, navsBefore } = s
      const got = await page.evaluate(() => {
        const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' }
        const main = document.querySelector('main')
        const nav = document.querySelector('nav[aria-label="Main menu"]')
        return {
          home: main?.querySelector('[data-home]')?.getAttribute('data-home') ?? null,
          parts: main ? [...main.querySelectorAll('[data-home-part]')].map((e) => e.getAttribute('data-home-part')) : [],
          outside: main ? [...main.querySelectorAll('[data-home-part="outside"] a')].filter(vis).map((a) => [a.textContent.trim(), a.getAttribute('target') || '', a.getAttribute('href')]) : [],
          money: /\$\d/.test(main?.innerText ?? ''),
          sidebar: Boolean(nav && vis(nav)),
          h1: document.querySelector('main h1, h1')?.textContent?.trim() ?? '',
          text: document.body.innerText,
          overflow: document.documentElement.scrollWidth > window.innerWidth,
          loginShown: Boolean(document.querySelector('input[type=email]')),
          bells: [...document.querySelectorAll('button[aria-label^="Notifications"]')].filter(vis).length,
          search: [...document.querySelectorAll('button[aria-label="Search everything"]')].filter(vis).length,
        }
      })
      // The bell asks only for someone the database lets read: a person with no app open gets no bell and no refused request; everyone else gets one.
      if (c.out && !opensAny(c)) {
        if (seen.waitingAsked) fails.push('the bell asked portal_waiting, which the database refuses a person with no app open')
        if (got.bells) fails.push('a bell for a person with no app open')
      } else if (c.out && !got.bells) fails.push('no bell')
      if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
      if (seen.navs !== navsBefore) fails.push('the sign-in reloaded the page')
      if (got.overflow) fails.push('sideways scroll')
      if (c.out) {
        // The Home of their group, with the parts their settings open, and money for an admin only (Fred: no money for the office).
        if (got.home !== kindOf(c)) fails.push(`the ${got.home} Home`)
        if (JSON.stringify(got.parts) !== JSON.stringify(partsFor(c))) fails.push(`parts ${got.parts.join('|')}`)
        if (got.money !== partsFor(c).includes('invoices')) fails.push(got.money ? 'money on a Home that is not an admin\'s' : 'no money on the admin\'s Home')
        // A driver's Home reads only their own day; an office or admin Home reads portal_home only when the database lets them.
        if (kindOf(c) === 'field') {
          if (!seen.mineAsked) fails.push('the driver Home did not read portal_my_work')
          if (seen.homeAsked) fails.push('the driver Home asked portal_home')
          if (seen.mineOffDoor) fails.push('portal_my_work asked outside its door (POST, schema ops)')
        } else if (Boolean(seen.homeAsked) !== opensAny(c)) fails.push(seen.homeAsked ? 'asked portal_home, which the database refuses a person with no app open' : 'portal_home was not read')
        // The apps outside the portal, each in a new tab to its own host.
        if (JSON.stringify(got.outside.map(([n]) => n)) !== JSON.stringify(c.out)) fails.push(`outside ${got.outside.map(([n]) => n).join('|')}`)
        for (const [name, target, href] of got.outside) if (target !== '_blank' || !/^https:/.test(href)) fails.push(`${name} opens "${target} ${href}" in the same tab`)
        if (c.hello ? !got.h1.includes(c.hello) : got.h1.includes(',')) fails.push(`greeting "${got.h1}"`)
        if (/\bfailed|undefined|null\b/i.test(got.h1)) fails.push(`greeting "${got.h1}"`)
        if (Boolean(/Need another app\?/.test(got.text)) !== c.card) fails.push('Need another app card')
        if (w >= 768 && !got.text.includes(c.role)) fails.push(`role ${c.role} missing`)
        if (w < 1280 && got.sidebar) fails.push('the sidebar is drawn below 1280')
        // Search is in the bar from 768, and only for a person who can open the Client App, the Visit Calendar or the HR App.
        if (w >= 768 && Boolean(got.search) !== (can(c, 'client_app') || can(c, 'visit_calendar') || can(c, 'hr'))) fails.push(`${got.search} search boxes`)
        // The menu, asserted on its own: in the sidebar from 1280, in the drawer below it. On Home, Home is the lit item.
        const menu = await readMenu(page, w, fails), wrong = menuFails(menu, c.menu)
        fails.push(...wrong, ...litFails(menu, 'home'))
        await shutMenu(page, w)
        // With the wrong menu on screen the pages are not walked: every one would only wait and fail again.
        if (c.walk && !wrong.length) await walk(page, w, c, fails)
      }
      if (c.text && !got.text.includes(c.text)) fails.push(`missing "${c.text}"`)
      if (c.group !== 'field' && got.text.includes('Your assigned forms')) fails.push('assigned-forms wording for someone with the Planner')
      if (c.login && !got.loginShown) fails.push('not back on the login')
      if (c.login && !seen.signOut.includes('local')) fails.push(`sign-out scope ${seen.signOut}`)
      if (c.fail && (got.loginShown || seen.signOut.length)) fails.push('a failed check signed the person out')
      if (c.out && seen.errors.length) fails.push('page error: ' + seen.errors[0])
      await shot(page, w, c.name)
    } catch (e) { fails.push('stopped: ' + String(e).split('\n')[0].slice(0, 150)) }
    report(w, c.name, fails)
    await ctx?.close().catch(() => {})
  }

  // The HR module: opens from its tile, labels its own requests, and the shell keeps its own label. Its two links are menu
  // items now: the page's own heading says Employees, and Access is in an admin's menu (in the drawer on a phone). An office
  // person's menu has no Access: that is the exact menu of the office cases above.
  await block(w, h, 'HR opens, labels hr-app', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    await pick(page, w, 'people', fails)
    await page.waitForTimeout(2500)
    if (at(page) !== '/hr/employees') fails.push(`landed on ${at(page)}`)
    const heading = await page.evaluate(() => document.querySelector('main h1')?.textContent.trim() ?? '')
    if (!/Employees/.test(heading)) fails.push(`the page's own heading says "${heading}"`)
    const menu = await readMenu(page, w, fails)
    if (!menu?.some((i) => i.id === 'access' && i.word === 'Access')) fails.push('no Access item in the menu for an admin')
    fails.push(...litFails(menu, 'people'))
    await shutMenu(page, w)
    const label = (k) => [...(seen.labels[k] ?? [])].join(',')
    if (label('rpc/get_pay_summary') !== 'hr-app') fails.push(`get_pay_summary labelled "${label('rpc/get_pay_summary')}"`)
    if (!label('rpc/get_my_access').includes('ops-portal')) fails.push(`the shell's get_my_access labelled "${label('rpc/get_my_access')}"`)
    if (label('rpc/get_my_access') !== 'ops-portal') fails.push(`a module asks get_my_access itself: "${label('rpc/get_my_access')}"`)
    const bar = await readBar(page, w >= 768)
    if (w >= 768 && bar.text !== 'People') fails.push(`bar "${bar.text.slice(0, 40)}"`)
    if (bar.links.length) fails.push('links in the bar or a band in the page')
    if (w < 768 && (await page.locator('main a[href="/hr/access"]').count())) fails.push('the page still links to Access on a phone')
    if (bar.sideways > 0) fails.push('sideways scroll')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'hr module')
  })

  // A person with no HR access who has the address: refused on screen, and the module asks the database nothing.
  await block(w, h, 'no HR access, direct address', FIELD, PORTAL + 'hr/employees', async ({ page, seen, fails }) => {
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You do not have access to HR App/.test(text)) fails.push('no refusal on screen')
    if (seen.labels['rpc/get_pay_summary']) fails.push('the module called get_pay_summary')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })

  // The Calendar module: opens from its tile, keeps its own label, has no theme of its own, draws no second theme or sign-out control,
  // the page is its only scroller, and leaving it gives the look back.
  await block(w, h, 'Calendar opens, labels its own', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    await pick(page, w, 'calendar', fails)
    await page.waitForFunction(() => location.pathname.startsWith('/calendar'), null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(2500)
    if (at(page) !== '/calendar') fails.push(`landed on ${at(page)}`)
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
    if (got.module) fails.push(`an app set its own theme: data-module "${got.module}"`)
    if (got.look) fails.push(`an app loaded a hosted theme: data-hw-app "${got.look}"`)
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
      await pick(page, w, 'people', fails)
      await page.waitForTimeout(1500)
      const back = await page.evaluate(() => [document.documentElement.dataset.module ?? '', document.documentElement.getAttribute('data-hw-app'), document.getElementById('theme-dark-app')?.getAttribute('href') ?? ''])
      if (back[0]) fails.push(`still data-module "${back[0]}" after leaving`)
      if (back[1]) fails.push(`data-hw-app "${back[1]}" after leaving`)
    }
  })

  // A person with no Calendar access who has the address: the Calendar's own card, and no calendar data asked for.
  await block(w, h, 'no Calendar access, address', FIELD, PORTAL + 'calendar', async ({ page, seen, fails }) => {
    const text = await page.evaluate(() => document.body.innerText)
    if (!/access/i.test(text)) fails.push('no refusal on screen')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    await shot(page, w, 'calendar no access')
  })

  // The DERM Tracker module: opens from its tile, keeps its own label, has no theme of its own, draws no second theme or sign-out control.
  // #216 DV1 (2026-11-24): the old DERM visits address /derm lands on the Visits tab of Manifests. From the Manifests item
  // the bar (the page's band on a phone) holds the doors to Visits, Health and the sheet list. Leaving it gives the look back.
  await block(w, h, 'DERM opens, labels its own', ADMIN, PORTAL + 'derm', async ({ page, seen, fails }) => {
    await page.waitForFunction(() => location.pathname.startsWith('/derm/manifests/visits'), null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(2500)
    if (at(page) !== '/derm/manifests/visits') fails.push(`/derm landed on ${at(page)}`)
    const got = await page.evaluate(() => ({
      module: document.documentElement.dataset.module, look: document.documentElement.getAttribute('data-hw-app'),
      darkSheet: document.getElementById('theme-dark-app')?.getAttribute('href') ?? '',
      title: document.title, mainSignOut: [...document.querySelectorAll('main button')].filter((b) => /^sign out$/i.test(b.textContent.trim())).length,
      themes: [...document.querySelectorAll('main [aria-label*="dark" i], main [aria-label*="light" i]')].length,
      overflow: document.documentElement.scrollWidth > window.innerWidth,
    }))
    if (got.module) fails.push(`an app set its own theme: data-module "${got.module}"`)
    if (got.look) fails.push(`an app loaded a hosted theme: data-hw-app "${got.look}"`)
    if (!/DERM Tracker/.test(got.title)) fails.push(`title "${got.title}"`)
    if (got.mainSignOut) fails.push('a second Sign out in the page')
    if (got.themes) fails.push('a second theme switch in the page')
    if (got.overflow) fails.push('sideways scroll')
    const visits = await readBar(page, w >= 768)
    if (!visits.links.includes('/derm/manifests/visits')) fails.push('the Visits tab is not in the bar on the Visits page')
    const own = Object.entries(seen.labels).filter(([k]) => !/get_my_access|portal_waiting|portal_home|portal_search/.test(k))
    if (!own.length) fails.push('the module asked for no data')
    for (const [k, v] of own) if (![...v].every((x) => x === 'derm-tracker')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'derm module')
    await pick(page, w, 'manifests', fails)
    await arrive(page, '/derm/manifests', 8000); await page.waitForTimeout(1200)
    const tabs = await readBar(page, w >= 768)
    // Stage C step 2: Upload left the bar for the page's orange "Upload manifest" button (the Manifests case below).
    for (const want of ['/derm/manifests/visits', '/derm/manifests/health', '/stamp']) if (!tabs.links.includes(want)) fails.push(`from the Manifests item, no link to ${want}`)
    if (tabs.links.includes('/derm/upload')) fails.push('the bar still has an Upload tab')
    if (tabs.sideways > 0) fails.push('sideways scroll on Manifests')
    await shot(page, w, 'manifests tabs')
    // The same row on the other two Manifests pages: Health by its tab, Upload by the page's button.
    for (const next of ['/derm/manifests/health', '/derm/upload']) {
      if (next === '/derm/upload') {
        await page.goto(PORTAL.replace(/\/$/, '') + '/derm/manifests'); await arrive(page, '/derm/manifests', 8000); await page.waitForTimeout(1200)
        // A full load of the merged portal (Clients in it) can take longer than 1.2 s to draw the page on a phone: wait for
        // the button itself (it must still appear, and is still clicked), never a longer fixed pause.
        await page.locator('main a[data-upload-button]').first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {})
        await tap(page.locator('main a[data-upload-button]'), fails, 'the Upload manifest button')
      } else await tap(page.locator(`${w >= 768 ? BAR : 'main header.border-b'} a[href="${next}"]`), fails, `the tab to ${next}`)
      if (!(await arrive(page, next, 8000))) { fails.push(`the door to ${next} landed on ${at(page)}`); continue }
      await page.waitForTimeout(900)
      const row = await readBar(page, w >= 768)
      if (JSON.stringify(row.links) !== JSON.stringify(tabs.links)) fails.push(`${next} holds ${row.links.join(' ') || 'no links'}`)
      if (row.sideways > 0) fails.push(`sideways scroll on ${next}`)
    }
    if (w >= 1280) {
      await pick(page, w, 'people', fails)
      await page.waitForTimeout(1500)
      const back = await page.evaluate(() => [document.documentElement.dataset.module ?? '', document.documentElement.getAttribute('data-hw-app')])
      if (back[0]) fails.push(`still data-module "${back[0]}" after leaving`)
      if (back[1]) fails.push(`data-hw-app "${back[1]}" after leaving`)
    }
  })

  // Stage C step 2, the Manifests page (plan, Stage C, the pinned checks): its two list doors (the Manifests tab and the
  // "Needs someone" box), the orange Upload button, the door to Health, the door to the sheet list for a person with Stamp
  // Studio only, the bell's sheet row opening Manifests on "Needs someone" for a person with the DERM Tracker, the DERM reads
  // labelled derm-tracker, and no stamp read at all (the page asks for none; a person without Stamp Studio causes none).
  // The made-up ticket #000001 of the Stage D case gives the list one row.
  for (const [who, c] of [['admin', { ...ADMIN, sheet: true, waiting: TEN }], ['no Stamp', { ...OFFICE, who: 'Derm Only', r: reply(33, 'office', { ...every('edit'), stamp_studio: 'none' }), sheet: true, waiting: TEN }]]) {
    await block(w, h, `Manifests doors, ${who}`, c, PORTAL + 'derm/manifests', async ({ page, seen, fails }) => {
      await page.waitForSelector('[data-needs-box]', { timeout: 20000 }).catch(() => {})
      await page.waitForTimeout(1500)
      const stamp = can(c, 'stamp_studio')
      const got = await page.evaluate(() => ({
        upload: document.querySelector('main a[data-upload-button]')?.getAttribute('href') ?? null,
        uploadBg: document.querySelector('main a[data-upload-button]') ? getComputedStyle(document.querySelector('main a[data-upload-button]')).backgroundColor : null,
        needsBox: Boolean(document.querySelector('[data-needs-box] [role=checkbox]')),
        links: [...document.querySelectorAll('header.shell-header a[href], main header.border-b a[href]')].map((a) => a.getAttribute('href')),
        overflow: document.documentElement.scrollWidth > window.innerWidth,
      }))
      if (got.upload !== '/derm/upload') fails.push('no "Upload manifest" button to /derm/upload')
      if (got.uploadBg !== 'rgb(241, 71, 20)') fails.push(`the Upload button is ${got.uploadBg}, not the orange`)
      if (!got.needsBox) fails.push('no "Needs someone" box')
      if (!got.links.includes('/derm/manifests')) fails.push('no Manifests tab')
      if (!got.links.includes('/derm/manifests/health')) fails.push('no door to Health')
      if (got.links.includes('/derm/upload')) fails.push('an Upload tab in the bar')
      if (got.links.includes('/stamp') !== stamp) fails.push(stamp ? 'no door to the sheet list for a person with Stamp Studio' : 'a door to the sheet list for a person without Stamp Studio')
      if (got.overflow) fails.push('sideways scroll')
      // the reads of the page: DERM's labelled derm-tracker, and no stamp view asked
      const asked = (seen.stampAsked ?? []).filter((x) => !/get_my_access|portal_waiting|portal_home|portal_search|employees/.test(x.name))
      for (const want of ['derm_manifests', 'rpc/manifest_row_states', 'rpc/archived_manifest_rows']) if (!asked.some((x) => x.name === want)) fails.push(`the page did not ask ${want}`)
      const wrong = asked.filter((x) => !/^(v_stamp|page_slots|rpc\/stamp_sheet_facts)/.test(x.name) && x.label !== 'derm-tracker')
      if (wrong.length) fails.push('not labelled derm-tracker: ' + [...new Set(wrong.map((x) => x.name + ' ' + x.label))].join(', '))
      if (asked.some((x) => /^v_stamp/.test(x.name))) fails.push('the Manifests page asked a stamp view')
      // the bell: "6 sheets not completed" opens Manifests on "Needs someone", in the same tab
      if (w >= 768) {
        await tap(page.locator('header button[aria-label^="Notifications"]'), fails, 'the bell')
        await page.waitForTimeout(600)
        const row = await page.evaluate(() => { const a = [...document.querySelectorAll('[role=menu] a')].find((x) => /sheets not completed/.test(x.textContent)); return a ? { href: a.getAttribute('href'), target: a.getAttribute('target') } : null })
        if (!row) fails.push('no sheet row in the bell')
        else if (row.href !== '/derm/manifests?needs=true' || row.target) fails.push(`the bell's sheet row opens "${row.target ?? ''} ${row.href}"`)
        await page.keyboard.press('Escape')
      }
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
      if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
      await shot(page, w, `manifests doors ${who}`)
    })
  }
  // A person with Stamp Studio and no DERM Tracker: the bell's sheet row keeps the sheet list (decision 11).
  if (w >= 768) await block(w, h, 'Manifests bell, Stamp only', { ...STAMP_ONLY, waiting: TEN }, PORTAL, async ({ page, fails }) => {
    await tap(page.locator('header button[aria-label^="Notifications"]'), fails, 'the bell')
    await page.waitForTimeout(600)
    const row = await page.evaluate(() => { const a = [...document.querySelectorAll('[role=menu] a')].find((x) => /sheets not completed/.test(x.textContent)); return a ? a.getAttribute('href') : null })
    if (row !== '/stamp') fails.push(`the bell's sheet row opens ${row}`)
  })

  // Stamp Studio: opens from its tile in the same tab, keeps its own label and look, sends its key (checked, never printed),
  // draws no second theme or sign-out control, and leaving it gives the look back. The bar names the page, not the app.
  await block(w, h, 'Stamp opens, labels its own', { ...ADMIN, sheet: true }, PORTAL, async ({ ctx, page, seen, fails }) => {
    let keyed = 0, unkeyed = 0
    page.on('request', (q) => { if (!/\/rest\/v1\/v_stamp/.test(q.url())) return; if (q.headers()['x-stamp-key']) keyed++; else unkeyed++ })
    const before = ctx.pages().length
    // the sheet list's door is on Manifests (an admin's menu has no Address sheets item)
    if (await pick(page, w, 'manifests', fails)) { await arrive(page, '/derm/manifests'); await page.waitForTimeout(1500) }
    await tap(page.locator('a[href="/stamp"]').locator('visible=true'), fails, 'the sheet list door on Manifests')
    await page.waitForFunction(() => location.pathname.startsWith('/stamp'), null, { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(2500)
    if (ctx.pages().length !== before) fails.push('opened a new tab')
    if (at(page) !== '/stamp') fails.push(`landed on ${at(page)}`)
    const got = await page.evaluate(() => ({
      module: document.documentElement.dataset.module, look: document.documentElement.getAttribute('data-hw-app'),
      darkSheet: document.getElementById('theme-dark-app')?.getAttribute('href') ?? '',
      title: document.title, mainSignOut: [...document.querySelectorAll('main button')].filter((b) => /^sign out$/i.test(b.textContent.trim())).length,
      themes: [...document.querySelectorAll('main [aria-label*="dark" i], main [aria-label*="light" i]')].length,
      overflow: document.documentElement.scrollWidth > window.innerWidth, tall: document.documentElement.scrollHeight > window.innerHeight,
      heading: /DERM Address Sheets/.test(document.body.innerText),
    }))
    if (got.module) fails.push(`an app set its own theme: data-module "${got.module}"`)
    if (got.look) fails.push(`an app loaded a hosted theme: data-hw-app "${got.look}"`)
    if (!/Stamp Studio/.test(got.title)) fails.push(`title "${got.title}"`)
    if (!got.heading) fails.push('the list did not show')
    if (got.mainSignOut) fails.push('a second Sign out in the page')
    if (got.themes) fails.push('a second theme switch in the page')
    if (got.overflow) fails.push('sideways scroll')
    if (got.tall) fails.push('the page is taller than the window')
    const bar = await readBar(page, w >= 768)
    if (w >= 768 && bar.text !== 'Address sheets') fails.push(`bar "${bar.text.slice(0, 40)}"`)
    if (bar.links.length) fails.push('tabs on the sheet list')
    const own = Object.entries(seen.labels).filter(([k]) => /v_stamp/.test(k))
    if (!own.length) fails.push('the module asked for no data')
    for (const [k, v] of own) if (![...v].every((x) => x === 'derm-stamp-studio')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (!keyed || unkeyed) fails.push(`stamp key on ${keyed} reads, missing on ${unkeyed}`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'stamp module')
    // Stage D: one sheet opened from a Manifests row's three dots, in the same tab: the stamping screen, its reads and the
    // facts call labelled derm-stamp-studio with the key (checked, never printed), nothing sideways.
    if (w >= 768) {
      seen.stampAsked = []
      await page.goto(PORTAL.replace(/\/$/, '') + '/derm/manifests', { waitUntil: 'domcontentloaded' })
      const dots = page.locator('button[aria-label^="More actions for"]').first()
      await dots.waitFor({ timeout: 20000 }).catch(() => {})
      const tabs = ctx.pages().length
      if (await tap(dots, fails, 'the row\'s three dots')) {
        await page.locator('[data-row-menu] [data-item="sheet"]').first().waitFor({ timeout: 5000 }).catch(() => {})
        await tap(page.locator('[data-row-menu] [data-item="sheet"]').first(), fails, 'Open the address sheet')
        await page.waitForSelector('[data-stamp-screen]', { timeout: 20000 }).catch(() => {})
        await page.waitForTimeout(2500)
        if (ctx.pages().length !== tabs) fails.push('the sheet opened in a new tab')
        if (at(page) !== '/stamp/000001') fails.push(`the sheet landed on ${at(page)}`)
        if (!(await page.locator('[data-stamp-screen]').count())) fails.push('no stamping screen')
        const sa = seen.stampAsked.filter((x) => /^(v_stamp|page_slots|v_page_printed_rules|rpc\/stamp_sheet_facts|rpc\/fn_sheet_publishable_detail)/.test(x.name))
        for (const want of ['v_stamp_sheets', 'rpc/stamp_sheet_facts']) if (!sa.some((x) => x.name === want)) fails.push(`the screen did not ask ${want}`)
        const wrong = sa.filter((x) => x.label !== 'derm-stamp-studio' || !x.keyed)
        if (wrong.length) fails.push('not Stamp\'s label and key: ' + [...new Set(wrong.map((x) => x.name + ' ' + x.label + (x.keyed ? '' : ' no key')))].join(', '))
        const side = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)
        if (side) fails.push('the stamping screen scrolls sideways')
        await shot(page, w, 'stamp sheet')
        // its X goes back where the person came from (the Manifests list), with nothing changed: no question
        await tap(page.locator('[data-close]'), fails, 'the X of the stamping screen')
        await page.locator('[data-stamp-screen]').waitFor({ state: 'detached', timeout: 8000 }).catch(() => fails.push('the X did not close the screen'))
        if (at(page) !== '/derm/manifests') fails.push(`the X went to ${at(page)}`)
      }
    }
    if (w >= 1280) {
      await pick(page, w, 'people', fails)
      await page.waitForTimeout(1500)
      const back = await page.evaluate(() => [document.documentElement.dataset.module ?? '', document.documentElement.getAttribute('data-hw-app')])
      if (back[0]) fails.push(`still data-module "${back[0]}" after leaving`)
      if (back[1]) fails.push(`data-hw-app "${back[1]}" after leaving`)
    }
  })

  // A person with no Stamp access who has the address: the refusal, and the page never mounts, so no sheet is asked for.
  await block(w, h, 'no Stamp access, address', FIELD, PORTAL + 'stamp/000001', async ({ page, seen, fails }) => {
    await page.waitForTimeout(1500)
    if (await page.locator('[data-stamp-screen]').count()) fails.push('the stamping screen mounted')
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You do not have access to Stamp Studio/.test(text)) fails.push('no refusal on screen')
    if (/DERM Address Sheets/.test(text)) fails.push('the list showed')
    if (Object.keys(seen.labels).some((k) => /v_stamp/.test(k))) fails.push('sheets were asked for')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    await shot(page, w, 'stamp no access')
  })

  // A person with no DERM access who has the address: its own card, and no DERM data asked for.
  await block(w, h, 'no DERM access, address', FIELD, PORTAL + 'derm', async ({ page, seen, fails }) => {
    await page.waitForTimeout(1500)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You do not have access to DERM Tracker/.test(text)) fails.push('no refusal on screen')
    if (/Completed visits/.test(text)) fails.push('the visits page showed')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    await shot(page, w, 'derm no access')
  })

  // No tabs for a refused person: nothing in the bar or in the page links on to another refusal.
  for (const [addr, app, tree] of [['derm/manifests', 'DERM Tracker', '/derm'], ['review', 'Admin Review', '/review']]) {
    await block(w, h, `no tabs for a refused person, /${addr}`, FIELD, PORTAL + addr, async ({ page, seen, fails }) => {
      await page.waitForTimeout(1500)
      const got = await page.evaluate(([BAR, tree]) => ({ text: document.body.innerText, bar: document.querySelectorAll(`${BAR} a`).length, onward: [...document.querySelectorAll(`a[href^="${tree}"]`)].map((a) => a.getAttribute('href')) }), [BAR, tree])
      if (!got.text.includes(`You do not have access to ${app}`)) fails.push('no refusal on screen')
      if (got.bar) fails.push(`${got.bar} links in the bar`)
      if (got.onward.length) fails.push(`links on to ${got.onward.join(' ')}`)
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    })
  }

  // Reviews, opened from the menu (the check used to open four apps only, so a broken Reviews page could not fail it):
  // its own label, the page's name in the bar with no link, and no sideways scroll on its three pages, a phone included.
  await block(w, h, 'Reviews opens from the menu', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    for (const [id, path, word] of [['reviews', '/review', 'Reviews'], ['pumped-water', '/review/water', 'Pumped water'], ['pumped-grease', '/review/grease', 'Pumped grease']]) {
      await pick(page, w, id, fails)
      if (!(await arrive(page, path))) { fails.push(`${id} landed on ${at(page)}`); continue }
      await page.waitForTimeout(2000)
      const bar = await readBar(page, w >= 768)
      if (w >= 768 && bar.text !== word) fails.push(`${path} bar "${bar.text.slice(0, 40)}"`)
      if (bar.links.length) fails.push(`${path} holds links in the bar or a band`)
      if (bar.sideways > 0) fails.push(`${path} scrolls sideways by ${bar.sideways} px`)
      if (/This page didn't load|You do not have access/.test(bar.body)) fails.push(`${path} did not open`)
    }
    if (!/Admin Review/.test(await page.title())) fails.push(`title "${await page.title()}"`)
    const own = Object.entries(seen.labels).filter(([k]) => !/get_my_access|portal_waiting|portal_home|portal_search/.test(k))
    if (!own.length) fails.push('the module asked for no data')
    for (const [k, v] of own) if (![...v].every((x) => x === 'admin-review')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'reviews module')
  })

  // Finances, opened from the menu: each page's name in the bar with no link, no sideways scroll, a phone included; its reads
  // are the Client App's (label client-app); its title names the Client App, whose setting opens it.
  await block(w, h, 'Finances opens from the menu', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    for (const [id, path, word] of [['invoices', '/finances/invoices', 'Invoices'], ['quotes', '/finances/quotes', 'Quotes'], ['payments', '/finances/payments', 'Payments']]) {
      await pick(page, w, id, fails)
      if (!(await arrive(page, path))) { fails.push(`${id} landed on ${at(page)}`); continue }
      await page.waitForTimeout(2000)
      const bar = await readBar(page, w >= 768)
      if (w >= 768 && bar.text !== word) fails.push(`${path} bar "${bar.text.slice(0, 40)}"`)
      if (bar.links.length) fails.push(`${path} holds links in the bar or a band`)
      if (bar.sideways > 0) fails.push(`${path} scrolls sideways by ${bar.sideways} px`)
      if (/This page didn't load|You do not have access|Couldn't load/.test(bar.body)) fails.push(`${path} did not open`)
      if (!(await page.title()).startsWith(`${word} · Client App`)) fails.push(`${path} title "${await page.title()}"`)
    }
    const own = Object.entries(seen.labels).filter(([k]) => /list_payments|payment_months|invoices|quotes/.test(k))
    if (!own.some(([k]) => /list_payments/.test(k))) fails.push('the Payments page asked for no payments')
    for (const [k, v] of own) if (![...v].every((x) => x === 'client-app')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'finances module')
  })
  // A person with no Client App who has the address: the refusal, and no payment asked for.
  await block(w, h, 'no Client App, Finances address', { ...OFFICE, r: reply(38, 'office', { ...every('edit'), client_app: 'none' }) }, PORTAL + 'finances/payments', async ({ page, seen, fails }) => {
    await page.waitForTimeout(1500)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/You do not have access to Client App/.test(text)) fails.push('no refusal on screen')
    if (seen.labels['rpc/list_payments']) fails.push('payments were asked for')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })

  // Site files, opened from the menu: its own label, its two tabs kept (in the bar, or in the page on a phone), and Forms opens.
  await block(w, h, 'Site files opens from the menu', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    await pick(page, w, 'site-files', fails)
    if (!(await arrive(page, '/planner'))) fails.push(`landed on ${at(page)}`)
    await page.waitForTimeout(2000)
    const bar = await readBar(page, w >= 768)
    if (JSON.stringify(bar.links) !== JSON.stringify(['/planner', '/planner/forms'])) fails.push(`tabs ${bar.links.join(' ') || 'none'}`)
    if (w >= 768 && OLD_NAMES.test(bar.text)) fails.push(`bar still names the app: "${bar.text.slice(0, 40)}"`)
    if (bar.sideways > 0) fails.push(`scrolls sideways by ${bar.sideways} px`)
    if (!/Picture Planner/.test(await page.title())) fails.push(`title "${await page.title()}"`)
    const own = Object.entries(seen.labels).filter(([k]) => !/get_my_access|portal_waiting|portal_home|portal_search/.test(k))
    if (!own.length) fails.push('the module asked for no data')
    for (const [k, v] of own) if (![...v].every((x) => x === 'picture-planner')) fails.push(`${k} labelled "${[...v].join(',')}"`)
    await tap(page.locator(`${w >= 768 ? BAR : 'main'} a[href="/planner/forms"]`), fails, 'the Forms tab')
    if (!(await arrive(page, '/planner/forms', 8000))) fails.push(`Forms landed on ${at(page)}`)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
    await shot(page, w, 'site files module')
  })

  // The one bar: the bell and the theme at the top right, each page's name in the bar and not again in the page.
  await block(w, h, 'one bar, bell, theme', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    const bar = w >= 768 ? 'header.shell-header' : 'div.relative.z-50'
    // The bell's number and its rows are live data, so the check asks that they agree rather than pinning a count.
    const label = (await page.locator(`${bar} button[aria-label^="Notifications"]`).first().getAttribute('aria-label').catch(() => null)) ?? ''
    const waiting = Number((label.match(/^Notifications, (\d+) waiting/) ?? [])[1] ?? NaN)
    if (!(waiting > 0)) fails.push(`no bell with a waiting count ("${label}")`)
    if (w >= 768 && !(await page.locator(`${bar} [role="group"][aria-label="Light or dark"]`).count())) fails.push('no theme switch in the bar')
    if (!(await page.locator(SIDE).count()) && w >= 1280) fails.push('no sidebar to look in')
    if (await page.locator(`${SIDE} [role="group"][aria-label="Light or dark"]`).count()) fails.push('the theme is still in the sidebar')
    await tap(page.locator(`${bar} button[aria-label^="Notifications"]`), fails, 'the bell')
    await page.waitForTimeout(400)
    const items = (await page.getByRole('menuitem').allInnerTexts()).map((x) => x.replace(/\s+/g, ' ').trim())
    if (items.length !== waiting) fails.push(`bell says ${waiting} waiting, shows ${items.length} rows: ${items.join('|')}`)
    // Since round B (2026-11-18, Fred: "Notified items, and drop the rest from the bell too") the bell has no requests row;
    // the call-first requests are their own row, as Slack posts them.
    if (!items.some((x) => /^1 client to call before scheduling/.test(x))) fails.push('no call-first row')
    if (items.some((x) => /visit requests to schedule/.test(x))) fails.push('the bell still has the requests row')
    await shot(page, w, 'bell open')
    await page.keyboard.press('Escape')
    if (w >= 768) {
      const title = await page.locator('header.shell-header').innerText()
      if (!/Home/.test(title)) fails.push(`home title "${title.slice(0, 40)}"`)
      await pick(page, w, 'calendar', fails)
      await page.waitForFunction(() => location.pathname.startsWith('/calendar'), null, { timeout: 30000 }).catch(() => {})
      await page.waitForTimeout(2000)
      const t2 = await page.locator('header.shell-header').innerText()
      if (!/Calendar/.test(t2) || /Visit Calendar/.test(t2) || !/to schedule/.test(t2)) fails.push(`calendar bar "${t2.slice(0, 60)}"`)
      const m = await page.evaluate(() => { const r = document.querySelector('main'); return { own: /to schedule/.test(r.innerText.slice(0, 200)), width: document.documentElement.scrollWidth - innerWidth } })
      if (m.own) fails.push('the Calendar still has its own row')
      if (m.width > 0 && w >= 1024) fails.push('sideways scroll')
      await shot(page, w, 'one bar calendar')
    }
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })
  // Every row the bell can hold. Since Yan's review round B (2026-11-18, Fred: "Notified items, and drop the rest from the
  // bell too") that is what Slack #apps-notifications posts: nine rows (`BELL_ROWS`); late visits, requests, manifests that
  // need someone and reviews stay on the Home only, so TEN's values for them must NOT show here. The number on the bell is
  // the number of rows, each row carries one icon and its own second line, and opens its list already filtered.
  await block(w, h, 'bell, every row', { ...ADMIN, waiting: { ...TEN, gdo_pending: 2, intake_back: 4 } }, PORTAL, async ({ page, seen, fails }) => {
    const bar = w >= 768 ? 'header.shell-header' : 'div.relative.z-50', bell = page.locator(`${bar} button[aria-label^="Notifications"]`)
    // Stage C step 2: for a person with the DERM Tracker the sheets row opens Manifests on "Needs someone" (its href carries
    // ?needs=true; the landing is checked by path)
    const want = [['/calendar?tbs=true', 'Call them, then schedule in To Be Scheduled'], ['/derm/manifests?needs=true', 'Address sheets still to stamp'],
      // no emails row since 2026-11-18 (Fred: "The bell doesn't need a notification for unopened emails"); the Home keeps it
      ['/review', "Sent from the visit's review"], ['/review', 'Not sorted into before and after yet'],
      ['/derm/manifests/visits?f=gdo', 'File them from the visit, as in the Slack alert'], ['/planner', 'New versions waiting for your yes'],
      ['/planner', 'Approve a Site file version made from it'], ['/calendar', "The truck's GPS has not confirmed how long it stayed"]]
    const label = (await bell.first().getAttribute('aria-label').catch(() => null)) ?? 'no bell'
    if (label !== `Notifications, ${want.length} waiting`) fails.push(`the bell says "${label}"`)
    if (!(await tap(bell, fails, 'the bell'))) return
    await page.waitForTimeout(400)
    const rows = await page.evaluate(() => [...document.querySelectorAll('[role="menuitem"]')].map((a) => ({ href: a.getAttribute('href'), tab: a.getAttribute('target') || '', icon: a.querySelectorAll('svg').length, square: a.firstElementChild?.textContent.trim() ?? '', lines: [...a.querySelectorAll('span.block')].map((s) => s.textContent.trim()) })))
    if (rows.length !== want.length) fails.push(`${rows.length} rows`)
    rows.forEach((r, i) => {
      const [href, where] = want[i] ?? []
      if (r.href !== href || r.tab) fails.push(`row ${i + 1} opens "${r.tab} ${r.href}", want ${href}`)
      if (r.lines[1] !== where) fails.push(`row ${i + 1} second line "${r.lines[1]}", want "${where}"`)
      if (r.icon !== 1 || r.square) fails.push(`row ${i + 1} shows "${r.square}" and ${r.icon} icons, want one icon and no letters`)
    })
    await shot(page, w, 'bell ten rows')
    for (let i = 0; i < want.length; i++) {
      // Back to Home first (the brand link), so a row that does nothing cannot pass on the page the row before it opened.
      if (at(page) !== '/') { await tap(page.locator('a[aria-label="Home"]').locator('visible=true'), fails, 'the brand link'); await arrive(page, '/', 8000); await page.waitForTimeout(400) }
      // The list is still open from the read above the first time round. (A click on the bell in the instant after Escape
      // is undone as the focus comes back to it, so the list is opened by its state, never closed and opened in one breath.)
      if ((await bell.first().getAttribute('data-state').catch(() => null)) !== 'open' && !(await tap(bell, fails, 'the bell'))) break
      await page.getByRole('menuitem').first().waitFor({ timeout: 4000 }).catch(() => {})
      if (!(await tap(page.getByRole('menuitem').nth(i), fails, `bell row ${i + 1}`))) { await page.keyboard.press('Escape'); await page.waitForTimeout(400); continue }
      if (!(await arrive(page, want[i][0].split('?')[0], 10000))) fails.push(`row ${i + 1} landed on ${at(page)}, want ${want[i][0]}`)
      await page.waitForTimeout(400)
      // On a phone the requests row opens the To Be Scheduled sheet on purpose: shut it before going back to Home.
      // The sheet opens once the Calendar has mounted, which on the live site can take longer than the 400 ms above.
      if (w < 768 && want[i][0].includes('tbs=true')) await page.locator('[role="dialog"][data-state="open"]').first().waitFor({ timeout: 5000 }).catch(() => {})
      if (w < 768 && want[i][0].includes('tbs=true') && !(await page.locator('[role="dialog"][data-state="open"]').count())) fails.push('the requests row did not open To Be Scheduled on a phone')
      if (w < 768 && (await page.locator('[role="dialog"][data-state="open"]').count())) {
        await page.keyboard.press('Escape')
        await page.locator('[role="dialog"][data-state="open"]').first().waitFor({ state: 'detached', timeout: 4000 }).catch(() => {})
      }
    }
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })
  // A failed bell read says so, and never reads as nothing waiting.
  await block(w, h, 'bell read fails', { ...ADMIN, waitingFails: true }, PORTAL, async ({ page, fails }) => {
    const bar = w >= 768 ? 'header.shell-header' : 'div.relative.z-50'
    await page.waitForTimeout(2500)
    await tap(page.locator(`${bar} button[aria-label^="Notifications"]`), fails, 'the bell')
    await page.waitForTimeout(400)
    const text = await page.evaluate(() => document.body.innerText)
    if (!/Couldn't load this/.test(text)) fails.push('no failure message')
    if (/Nothing waiting/.test(text)) fails.push('a failed read said nothing is waiting')
  })

  // Below 1280 the real sidebar opens as a full-height drawer, and picking an item closes it. Also at 1024, from the bar's menu button.
  for (const dw of w < 1280 ? [w, 900, 1024] : []) {
    await block(dw, h, 'the menu opens as a drawer', ADMIN, PORTAL, async ({ page, seen, fails }) => {
      await tap(page.getByRole('button', { name: /open menu/i }), fails, 'the menu button')
      await page.waitForTimeout(600)
      const d = await page.evaluate((DRAWER) => {
        const n = document.querySelector(DRAWER), box = n?.closest('[role="dialog"]')?.getBoundingClientRect()
        return box ? { left: Math.round(box.left), top: Math.round(box.top), w: Math.round(box.width), h: Math.round(box.height), vh: innerHeight, brand: /UnclogMe/.test(n.innerText), items: n.querySelectorAll('a[data-menu]').length, account: !!n.querySelector('button[aria-label="Account menu"]'), title: n.closest('[role="dialog"]').getAttribute('aria-labelledby') ? document.getElementById(n.closest('[role="dialog"]').getAttribute('aria-labelledby'))?.textContent.trim() : '' } : null
      }, DRAWER)
      if (!d) fails.push('no drawer')
      else {
        if (d.left !== 0 || d.top !== 0) fails.push(`drawer at ${d.left},${d.top}`)
        if (d.h !== d.vh) fails.push(`drawer ${d.h} high in ${d.vh}`)
        if (!d.brand || d.items !== ADMIN_MENU.length || !d.account) fails.push(`the drawer is not the whole menu: ${d.items} items`)
        if (d.title !== 'Menu') fails.push(`the drawer is named "${d.title}"`)
      }
      fails.push(...menuFails(await readMenu(page, dw, fails), ADMIN_MENU))
      await shot(page, dw, 'menu drawer')
      await tap(page.locator(`${DRAWER} a[data-menu="people"]`), fails, 'People in the drawer')
      await page.waitForTimeout(1500)
      if (await page.locator(DRAWER).count()) fails.push('the drawer stayed open')
      if (!/^\/hr/.test(at(page))) fails.push(`went to ${at(page)}`)
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    })
  }

  // Search everything: Ctrl K from any page, each kind of result goes to the right place and carries the menu's word, nothing for someone with no such app.
  if (w >= 768) {
    await block(w, h, 'search everything', ADMIN, PORTAL, async ({ page, seen, fails }) => {
      await page.keyboard.press('Control+k')
      await page.waitForTimeout(400)
      await page.getByPlaceholder(/client code or name|invoice or quote number/i).fill('canned')
      await page.waitForTimeout(1200)
      const rows = (await page.getByRole('option').allInnerTexts()).map((x) => x.replace(/\s+/g, ' ').trim())
      if (rows.length !== 4) fails.push(`${rows.length} results: ${rows.join('|')}`)
      if (!rows.some((x) => /Next visit: Tue, Dec 1, Pumping/.test(x))) fails.push('no next visit row')
      if (!rows.some((x) => /Canned Diner Clients$/.test(x))) fails.push('the client row does not say Clients')
      if (!rows.some((x) => /People, Admin$/.test(x))) fails.push('the person row does not say People')
      if (rows.some((x) => /Client App|HR App|Visit Calendar/.test(x))) fails.push('a result still names an app')
      if ((await page.locator('[role="option"] svg').count()) !== 3) fails.push('the client, visit and request rows do not each carry an icon')
      const label = [...(seen.labels['rpc/portal_search'] ?? [])].join(',')
      if (label !== 'ops-portal') fails.push(`search labelled "${label}"`)
      await shot(page, w, 'search open')
      await tap(page.getByRole('option', { name: /Next visit/ }), fails, 'the visit result')
      await page.waitForFunction(() => location.pathname.startsWith('/calendar'), null, { timeout: 30000 }).catch(() => {})
      await page.waitForTimeout(1500)
      if (at(page) !== '/calendar') fails.push(`visit went to ${at(page)}`)
      if (new URL(page.url()).search) fails.push(`the address kept ${new URL(page.url()).search}`)
      await tap(page.locator('button[aria-label="Search everything"]'), fails, 'the search box')
      await page.waitForTimeout(400)
      await page.getByPlaceholder(/client code or name|invoice or quote number/i).fill('fred')
      await page.waitForTimeout(1200)
      await tap(page.getByRole('option', { name: /Fred Zerpa/ }), fails, 'the person result')
      await page.waitForTimeout(1500)
      if (at(page) !== '/hr/employees/2') fails.push(`person went to ${at(page)}`)
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    })
    await block(w, h, 'no search for field', FIELD, PORTAL, async ({ page, fails }) => {
      if (await page.locator('button[aria-label="Search everything"]').count()) fails.push('field sees the search box')
    })
  }

  // The lit item: exactly one menu item carries aria-current="page", worked out from the address alone, and none carries the
  // router's own mark. The two record pages are opened by address (their lists are empty here): only the menu is read there.
  await block(w, h, 'one lit item on each address', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    // The eight addresses the plan names, at every width. With the sidebar on screen, the rest of its "Lit on" column too.
    const NAMED = [['', 'home'], ['review/water', 'pumped-water'], ['derm/manifests/health', 'manifests'], ['derm/manifests?q=830714', 'manifests'], ['hr/access', 'access'], ['stamp', 'manifests'], ['derm/visits/1', null], ['visits/1', null], ['review/visit/1', 'reviews']]
    const REST = [['calendar', 'calendar'], ['review', 'reviews'], ['review/shift/1', 'reviews'], ['planner', 'site-files'], ['planner/forms', 'site-files'], ['planner/forms/1', 'site-files'], ['planner/property/1', 'site-files'], ['derm/manifests', 'manifests'], ['derm/upload', 'manifests'], ['stamp/1', 'manifests'], ['derm', 'manifests'], ['derm/manifests/visits', 'manifests'], ['derm/manifests/842363', 'manifests'], ['derm/monthly', 'monthly-report'], ['derm/gdo-lookup', 'gdo-lookup'], ['review/grease', 'pumped-grease'], ['finances/invoices', 'invoices'], ['finances/quotes', 'quotes'], ['finances/payments', 'payments'], ['finances', 'invoices'], ['hr/employees', 'people'], ['hr/employees/2', 'people']]
    for (const [addr, id] of w >= 1280 ? [...NAMED, ...REST] : NAMED) {
      await page.goto(PORTAL + addr, { waitUntil: 'domcontentloaded' })
      await page.locator('main').waitFor({ timeout: 15000 }).catch(() => {})
      await page.waitForTimeout(900)
      const menu = await readMenu(page, w, fails)
      fails.push(...litFails(menu, id).map((x) => `/${addr} ${x}`))
      if (menu?.some((i) => i.routerMark)) fails.push(`/${addr} a menu link carries the router's own mark`)
      await shutMenu(page, w)
    }
    if (seen.stray.size) fails.push('stray backend ' + [...seen.stray])
  })
  // None on Profile, opened as a Field person (anyone the HR App lets in is sent on to their own record, where People is lit).
  await block(w, h, 'no lit item on Profile, field', FIELD, PORTAL + 'profile', async ({ page, fails }) => {
    if (at(page) !== '/profile') fails.push(`at ${at(page)}`)
    const menu = await readMenu(page, w, fails)
    // "Nothing lit" only counts on a menu that is there: with no menu on screen this case would pass on nothing.
    if (!menu?.length) fails.push('no menu on screen')
    fails.push(...litFails(menu, null))
  })

  // Every page has a way in: each page address with no record id is reached from the menu in two clicks at most. This is the
  // only test of the doors that are tabs or links of the bar (Health, Upload, Forms, Address sheets).
  await block(w, h, 'every page has a way in', ADMIN, PORTAL + 'profile', async ({ page, seen, fails }) => {
    const WAYS = [['/', 'home'], ['/calendar', 'calendar'], ['/derm/manifests', 'manifests'], ['/derm/manifests/visits', 'manifests', true], ['/derm/manifests/health', 'manifests', true], ['/derm/monthly', 'monthly-report'], ['/derm/gdo-lookup', 'gdo-lookup'], ['/derm/upload', 'manifests', true], ['/hr/access', 'access'], ['/hr/employees', 'people'], ['/planner', 'site-files'], ['/planner/forms', 'site-files', true], ['/review', 'reviews'], ['/review/grease', 'pumped-grease'], ['/review/water', 'pumped-water'], ['/stamp', 'manifests', true], ['/finances/invoices', 'invoices'], ['/finances/quotes', 'quotes'], ['/finances/payments', 'payments']]
    let reached = 0
    for (const [path, id, second] of WAYS) {
      const first = MENU.find(([m]) => m === id)[3]
      if (!(await pick(page, w, id, fails))) continue
      await page.waitForFunction((p) => location.pathname.startsWith(p), first, { timeout: 10000 }).catch(() => {})
      // Stage C step 2: Upload is reached by the page's orange button, at every width
      if (second) { await page.waitForTimeout(600); await tap(page.locator(`${w >= 768 && path !== '/derm/upload' ? BAR : 'main'} a[href="${path}"]`).first(), fails, `the link to ${path}`) }
      if (await arrive(page, path, 8000)) reached++; else fails.push(`${path} not reached: at ${at(page)}`)
      await page.waitForTimeout(250)
    }
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    return `${reached} of ${WAYS.length} from the menu; /profile is the next line`
  })
  await block(w, h, 'a way in: Profile, field', FIELD, PORTAL, async ({ page, fails }) => {
    if (w < 1280) await tap(page.getByRole('button', { name: /open menu/i }), fails, 'the menu button')
    await tap(page.getByRole('button', { name: 'Account menu' }), fails, 'the account menu')
    await tap(page.getByRole('menuitem', { name: 'Profile' }), fails, 'Profile')
    if (!(await arrive(page, '/profile', 8000))) fails.push(`Profile went to ${at(page)}`)
  })

  // Profile, typed by address, for someone who can open the HR App: straight to their own record (Fred, 2026-11-05).
  await block(w, h, 'profile by address, admin', ADMIN, PORTAL + 'profile', async ({ page, fails }) => {
    await page.waitForTimeout(1500)
    if (at(page) !== '/hr/employees/' + ADMIN.r.employee_id) fails.push(`went to ${at(page)}`)
  })

  // The small Profile page, for someone HR would refuse: their own details, their apps, their own photo. Unchanged in Stage A.
  for (const [c, apps] of [[FIELD, 3]]) {
    await block(w, h, `profile, ${c.group}`, c, PORTAL + 'profile', async ({ page, seen, fails }) => {
      const got = await page.evaluate(() => {
        const m = document.querySelector('main')
        const sections = [...m.querySelectorAll('section')]
        return { name: m.querySelector('h1')?.textContent ?? '', text: m.innerText, apps: sections[2]?.querySelectorAll('a').length ?? 0, hr: /Open my HR record/.test(m.innerText), overflow: document.documentElement.scrollWidth > innerWidth, camera: !!m.querySelector('button[aria-label="Change your photo"]'), title: document.title }
      })
      if (got.name !== c.who) fails.push(`name "${got.name}"`)
      if (!got.text.includes(mailOf(c.who))) fails.push('no email')
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
    })
  }

  // The account menu: Profile and Sign out. Profile is the person's HR record; with no HR access, the small page.
  for (const c of [ADMIN, FIELD]) {
    await block(w, h, `account menu, ${c.group}`, c, PORTAL, async ({ page, seen, fails }) => {
      if (w < 1280) await tap(page.getByRole('button', { name: /open menu/i }), fails, 'the menu button')
      await tap(page.getByRole('button', { name: 'Account menu' }), fails, 'the account menu')
      const items = (await page.getByRole('menuitem').allInnerTexts()).map((x) => x.trim())
      const want = ['Profile', 'Sign out']
      if (JSON.stringify(items) !== JSON.stringify(want)) fails.push(`menu ${items.join('|')}`)
      await shot(page, w, `account menu ${c.group}`)
      await tap(page.getByRole('menuitem', { name: 'Profile' }), fails, 'Profile')
      await page.waitForTimeout(1500)
      const wantPath = c === ADMIN ? '/hr/employees/' + c.r.employee_id : '/profile'
      if (at(page) !== wantPath) fails.push(`Profile went to ${at(page)}, want ${wantPath}`)
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    })
  }

  // The collapse button: icons only, every item still reachable with its word as the hover title, the account menu still
  // there, remembered after a reload.
  if (w >= 1280) {
    await block(w, h, 'sidebar collapses, remembered', ADMIN, PORTAL, async ({ page, seen, fails }) => {
      const size = () => page.evaluate((SIDE) => {
        const nav = document.querySelector(SIDE), main = document.querySelector('main')
        const items = [...nav.querySelectorAll('a[data-menu]')]
        return { nav: Math.round(nav.getBoundingClientRect().width), main: Math.round(main.getBoundingClientRect().width), items: items.length, titled: items.filter((a) => a.title && a.title === a.textContent.trim()).length, overflow: nav.scrollWidth > nav.clientWidth + 1 }
      }, SIDE)
      const open = await size()
      if (open.nav !== 228) fails.push(`open width ${open.nav}`)
      if (open.items !== ADMIN_MENU.length) fails.push(`${open.items} items in the open sidebar`)
      // In the top bar, not on the sidebar (Fred, 2026-11-06).
      if (!(await page.locator('header.shell-header button[aria-label="Collapse the sidebar"]').count())) fails.push('the collapse button is not in the top bar')
      if (await page.locator(`${SIDE} button[aria-label$="the sidebar"]`).count()) fails.push('the collapse button is still on the sidebar')
      await tap(page.getByRole('button', { name: 'Collapse the sidebar' }), fails, 'the collapse button')
      const shut = await size()
      if (shut.nav !== 64) fails.push(`collapsed width ${shut.nav}`)
      if (shut.main !== open.main + 164) fails.push(`main ${open.main} to ${shut.main}`)
      if (shut.items !== open.items) fails.push(`${shut.items} of ${open.items} items left`)
      if (shut.titled !== shut.items) fails.push(`${shut.titled} of ${shut.items} icons carry their word as the hover title`)
      if (shut.overflow) fails.push('the icons do not fit')
      for (const name of ['Account menu']) if (!(await page.locator(`${SIDE} button[aria-label="${name}"]`).count())) fails.push(`no ${name}`)
      fails.push(...litFails(await readMenu(page, w, fails), 'home'))
      await shot(page, w, 'sidebar collapsed')
      await page.reload(); await page.waitForTimeout(2500)
      const after = await size()
      if (after.nav !== 64) fails.push(`after a reload ${after.nav}`)
      await tap(page.getByRole('button', { name: 'Expand the sidebar' }), fails, 'the expand button')
      if ((await size()).nav !== 228) fails.push('did not expand')
      if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
    })
  }

  // Sign out: asks Supabase once, reloads, and comes back to the login with nothing left on screen.
  await block(w, h, 'sign out starts clean', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    const before = seen.navs
    if (w < 1280) await tap(page.getByRole('button', { name: /open menu/i }), fails, 'the menu button')
    if (await page.getByRole('button', { name: /^sign out$/i }).count()) fails.push('a sign-out button outside the account menu')
    await tap(page.getByRole('button', { name: 'Account menu' }), fails, 'the account menu')
    await tap(page.getByRole('menuitem', { name: /^sign out$/i }), fails, 'Sign out')
    // A wait for the login itself: it comes back in 2 to 3 s on a dev server, so a fixed wait failed by chance.
    await page.locator('input[type=email]').waitFor({ timeout: 15000 }).catch(() => {})
    if (seen.signOut.length < 1) fails.push('Supabase was not asked to sign out')
    if (seen.navs === before) fails.push('the page did not start clean')
    if (!(await page.locator('input[type=email]').count())) fails.push('not on the login')
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })
}

// The widths between the two above. 1280 with the sidebar open is the bar's worst width; at 1024 the menu is the drawer,
// opened from the bar's own menu button.
for (const [w, h] of [[1280, 900], [1024, 768]]) {
  await block(w, h, 'admin, the menu and the bar', ADMIN, PORTAL, async ({ page, seen, fails }) => {
    const menu = await readMenu(page, w, fails)
    fails.push(...menuFails(menu, ADMIN_MENU), ...litFails(menu, 'home'))
    await shutMenu(page, w)
    await walk(page, w, ADMIN, fails)
    if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  })
}

// The bar fits: on the Manifests pages at 1280 with the sidebar open the four links are whole and the row does not scroll
// sideways. The clock is set to a wide text first (10:59 AM on a Wednesday in November), or this could pass at 1 AM and say
// nothing about 11 AM. The Monthly report is opened too: it stands on the refused function call, and the call stayed here.
await block(1280, 900, 'the Manifests row fits beside a wide clock', { ...ADMIN, clock: '2026-11-25T15:59:00Z' }, PORTAL + 'derm/manifests', async ({ page, seen, fails }) => {
  await page.waitForTimeout(800)
  const m = await page.evaluate(([BAR, SIDE]) => {
    const slot = document.querySelector(BAR), nav = slot?.querySelector('nav')
    const clock = [...document.querySelectorAll('header.shell-header > span')].map((s) => s.textContent.trim()).find((t) => / ET$/.test(t)) ?? ''
    if (!slot || !nav) return { clock }
    // innerText, not textContent: below 1536 the word "Manifest" after "Upload" is in the page but not drawn.
    const box = slot.getBoundingClientRect(), links = [...nav.querySelectorAll('a')].map((a) => { const r = a.getBoundingClientRect(); return { word: a.innerText.replace(/\s+/g, ' ').trim(), left: r.left, right: r.right } })
    return { clock, slot: Math.round(box.width * 10) / 10, needs: nav.scrollWidth, has: nav.clientWidth, words: links.map((l) => l.word), cut: links.filter((l) => l.left < box.left - 0.5 || l.right > box.right + 0.5).map((l) => l.word), side: Math.round(document.querySelector(SIDE)?.getBoundingClientRect().width ?? 0) }
  }, [BAR, SIDE])
  if (m.clock !== 'Wed, Nov 25, 10:59 AM ET') fails.push(`the clock shows "${m.clock}", not the wide text`)
  if (m.side !== 228) fails.push(`the sidebar is ${m.side} px wide, not open`)
  // Stage C step 2: Upload is the page's button, no longer a tab of this row
  // #216 DV1 (2026-11-24): the Visits tab (the old DERM visits list) sits after Manifests
  if (JSON.stringify(m.words) !== JSON.stringify(['Manifests', 'Visits', 'Health', 'Address sheets'])) fails.push(`the row holds ${(m.words ?? []).join(' | ') || 'nothing'}`)
  if (m.needs > m.has) fails.push(`the row needs ${m.needs} px and has ${m.has}: it scrolls sideways`)
  if (m.cut?.length) fails.push(`cut at the edge: ${m.cut.join(', ')}`)
  await shot(page, 1280, 'manifests row wide clock')
  await page.goto(PORTAL + 'derm/monthly', { waitUntil: 'domcontentloaded' }); await page.waitForTimeout(2500)
  const monthly = await readBar(page, true)
  if (monthly.text !== 'Monthly report') fails.push(`Monthly bar "${monthly.text.slice(0, 40)}"`)
  if (/This page didn't load/.test(monthly.body)) fails.push('the Monthly report crashed')
  if (!seen.fn.includes('lwt-monthly')) fails.push('the Monthly report did not call its function, so the made-up answer was not tried')
  if (seen.errors.length) fails.push('page error: ' + seen.errors[0])
  return `row ${m.needs} px in ${m.slot} px; ${seen.fn.length} function calls and ${seen.sockets} live sockets answered here`
})

// The tab you are on is marked: on each page with tabs, exactly one link of the bar's row has a fill of its own, it is that
// page's tab, and its words are darker than the others'. Until 2026-11-12 the fill was the white of a second-rank button on
// the white bar, so no tab was marked on any of these pages, and nothing checked it. The menu lights one item for all the
// tabs of a page, so the tab is the only sign of which one a person is on. Its control is the code before the fix: with
// the two Header files of that commit put back, all five lines fail ("marked: none").
// Stage C step 2: /derm/upload has no tab of its own any more (the page's button replaced it), so none is marked there.
for (const [addr, word] of [['derm/manifests', 'Manifests'], ['derm/manifests/health', 'Health'], ['derm/upload', null], ['planner', 'Page Builder'], ['planner/forms', 'Forms']]) {
  await block(1280, 900, `the tab you are on is marked, /${addr}`, ADMIN, PORTAL + addr, async ({ page, fails }) => {
    await page.waitForSelector(BAR + ' nav a', { timeout: 15000 }).catch(() => {})
    await page.waitForTimeout(800)
    const m = await page.evaluate((BAR) => {
      const nav = document.querySelector(BAR)?.querySelector('nav')
      if (!nav) return null
      // A fill that is still fading in reads as its start value: finish it before reading.
      nav.querySelectorAll('a').forEach((a) => a.getAnimations().forEach((x) => x.finish()))
      return { bar: getComputedStyle(document.querySelector('header.shell-header')).backgroundColor, links: [...nav.querySelectorAll('a')].map((a) => { const s = getComputedStyle(a); return { word: a.innerText.replace(/\s+/g, ' ').trim(), fill: s.backgroundColor, ink: s.color } }) }
    }, BAR)
    if (!m) { fails.push('no row of tabs in the bar'); return }
    const marked = m.links.filter((l) => l.fill !== m.bar && l.fill !== 'rgba(0, 0, 0, 0)' && l.fill !== 'transparent')
    if (word === null) { if (marked.length) fails.push(`marked: ${marked.map((l) => l.word).join(' | ')}; wanted none (Upload is a button now)`) }
    else if (marked.length !== 1 || marked[0].word !== word) fails.push(`marked: ${marked.map((l) => l.word).join(' | ') || 'none'}; wanted ${word} alone, of ${m.links.map((l) => l.word).join(' | ')}`)
    else if (m.links.some((l) => l.word !== word && l.ink === marked[0].ink)) fails.push(`the marked tab's words are the same ink as the others (${marked[0].ink})`)
    return `${word}: fill ${marked[0]?.fill ?? 'none'} on a ${m.bar} bar`
  })
}

// A short window: at 1280 by 620 the list is longer than its room, so it scrolls inside the sidebar. Every item can be
// scrolled into view and the account menu stays in view.
await block(1280, 620, 'the menu on a short window', ADMIN, PORTAL, async ({ page, fails }) => {
  const m = await page.evaluate(async (SIDE) => {
    const nav = document.querySelector(SIDE), list = nav?.querySelector('.overflow-y-auto'); if (!list) return null
    const items = [...nav.querySelectorAll('a[data-menu]')], out = []
    const inside = (a) => { const r = a.getBoundingClientRect(), b = list.getBoundingClientRect(); return r.top >= b.top - 0.5 && r.bottom <= b.bottom + 0.5 }
    const under = items.filter((a) => !inside(a)).map((a) => a.dataset.menu)
    for (const a of items) { a.scrollIntoView({ block: 'nearest' }); await new Promise((r) => requestAnimationFrame(r)); if (!inside(a)) out.push(a.dataset.menu) }
    const acc = nav.querySelector('button[aria-label="Account menu"]')?.getBoundingClientRect()
    return { items: items.length, needs: list.scrollHeight, has: list.clientHeight, under, out, account: Boolean(acc && acc.top >= 0 && acc.bottom <= innerHeight), page: document.documentElement.scrollHeight - innerHeight }
  }, SIDE)
  if (!m) { fails.push('no menu list'); return }
  if (m.items !== ADMIN_MENU.length) fails.push(`${m.items} items`)
  if (m.needs <= m.has) fails.push(`the list fits (${m.needs} in ${m.has}), so this window is not short enough to test anything`)
  if (m.out.length) fails.push(`cannot be scrolled into view: ${m.out.join(', ')}`)
  if (!m.account) fails.push('the account menu is not in view')
  return `list ${m.needs} px in ${m.has} px; under the fold at first: ${m.under.join(', ') || 'nothing'}`
})

// The menu scroller (Fred, 2026-11-15, SB4: "go with SB4 and all defaults"): the list carries the one named style
// .nav-scroll (a slim pill, no arrows), and its edges fade only where there is more: the bottom at the top of the list, both
// halfway, the top at the end. In the dark look the list puts the bar colour back to auto, or the pill is not drawn.
// Control: the code before e3450a6 (no class, no edge marks) fails every line here.
await block(1280, 620, 'the menu scroller fades only where there is more', ADMIN, PORTAL, async ({ page, fails }) => {
  const edge = (y) => page.evaluate(async ([SIDE, y]) => {
    const list = document.querySelector(SIDE)?.querySelector('.overflow-y-auto'); if (!list) return null
    if (y !== null) { list.scrollTop = y === 'end' ? list.scrollHeight : y; await new Promise((r) => setTimeout(r, 150)) }
    const cs = getComputedStyle(list)
    return { cls: list.classList.contains('nav-scroll'), above: list.hasAttribute('data-more-above'), below: list.hasAttribute('data-more-below'),
      mask: /gradient/.test(cs.maskImage || cs.webkitMaskImage || ''), max: list.scrollHeight - list.clientHeight }
  }, [SIDE, y])
  const top = await edge(null)
  if (!top) { fails.push('no menu list'); return }
  if (!top.cls) fails.push('the list has no .nav-scroll style')
  if (!top.mask) fails.push('no fade drawn on the list')
  if (!(top.below && !top.above)) fails.push(`at the top: above ${top.above}, below ${top.below}`)
  const mid = await edge(Math.round(top.max / 2))
  if (!(mid?.above && mid?.below)) fails.push(`halfway: above ${mid?.above}, below ${mid?.below}`)
  const end = await edge('end')
  if (!(end?.above && !end?.below)) fails.push(`at the end: above ${end?.above}, below ${end?.below}`)
  const dark = await page.evaluate((SIDE) => { document.documentElement.classList.add('dark'); return getComputedStyle(document.querySelector(SIDE).querySelector('.overflow-y-auto')).scrollbarColor }, SIDE)
  if (dark !== 'auto') fails.push(`dark look: the bar colour is ${dark}, so the pill is not drawn`)
  return `${top.max} px to scroll; edges top/halfway/end as they should`
})

// A person with Stamp Studio and no DERM Tracker (nobody today): Address sheets is their item, lit on the sheet list.
await block(1440, 900, 'Stamp Studio without the DERM Tracker', STAMP_ONLY, PORTAL, async ({ page, fails }) => {
  fails.push(...menuFails(await readMenu(page, 1440, fails), STAMP_ONLY.menu))
  await pick(page, 1440, 'address-sheets', fails)
  if (!(await arrive(page, '/stamp', 8000))) fails.push(`landed on ${at(page)}`)
  await page.waitForTimeout(1200)
  fails.push(...litFails(await readMenu(page, 1440, fails), 'address-sheets'))
  const bar = await readBar(page, true)
  if (bar.text !== 'Address sheets') fails.push(`bar "${bar.text.slice(0, 40)}"`)
})

await browser.close()
console.log((bad ? `${bad} FAILED of ${lines}` : `ALL PASS, ${lines} lines`) + (ONLY ? `  (not a whole run: ONLY=${ONLY})` : ''))
process.exit(bad ? 1 : 0)
