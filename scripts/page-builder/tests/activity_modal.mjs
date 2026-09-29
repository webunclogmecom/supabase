// LIVE Page Builder /property/1164: ACTIVITY C (Fred, 2026-09-28). The Activity card is gone; an Activity button right
// before "View site file" opens a modal: versions (one Live), the chosen version's made/checked/replaced lines, what
// changed since the version before (the review's own diff, the changed days in week order), and the activity around it; full screen with list then
// detail on a phone. Real replies: get_page_builder / forms / get_property_activity and get_page_versions (migration
// 2026-09-28_1122) read as Fred's claims. Sign-in faked; every call stubbed; nothing written. Codes are masked in the output.
//   node scripts/page-builder/tests/activity_modal.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_property_activity(1164) as act, client.get_page_versions(1164) as versions;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !Array.isArray(row.act) || !Array.isArray(row.versions)) { console.log('FAIL fixture (is migration 2026-09-28_1122, client.get_page_versions, applied?) :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it opens with the driver link code
const VERSIONS = row.versions
console.log(`get_page_versions stub: ${VERSIONS.length} versions of 1164, read as Fred`)
const clone = (x) => JSON.parse(JSON.stringify(x))
const LIVE = VERSIONS.find((v) => v.status === 'live')
if (!LIVE || VERSIONS.length < 3) { console.log('FAIL fixture: 1164 needs a live version and at least 3 versions'); process.exit(1) }
const SECRETS = [...new Set([row.pb.property?.source?.lock_box_key, row.pb.link?.public_id, ...VERSIONS.flatMap((v) => ['lock_box_code', 'gate_code', 'key_tag'].map((k) => v.content?.facts?.[k]))]
  .filter((s) => s != null && String(s).trim().length >= 3).map(String))]
const mask = (s) => SECRETS.reduce((t, x) => t.split(x).join('<code>'), String(s))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(JSON.stringify(v)).slice(0, 400)}`) }
// an independent copy of the review's "What changed" rule (the builder's function; the modal must reuse it)
const LA = { key_tag: 'Key tag', gt_systems: 'Grease trap systems', gallons: 'Gallons', manholes: 'Manholes', cleanouts: 'Cleanouts', sample_ports: 'Sample ports', lift_stations: 'Lift stations', water_tanks: 'Water tanks', water_tank_capacity: 'Water tank capacity', gate: 'Gate', gate_code: 'Gate code', how_access: 'How to get in', lock_box_code: 'Lock box code', key_instruction: 'Key instructions', alarm: 'Alarm', alarm_instruction: 'Alarm instructions', equipment_where: 'Where the equipment is', access_point: 'Access point', obstacles: 'Obstacles' }
const lab = (k) => LA[k] ?? k.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())
const show = (v) => (v == null || v === '' ? '(empty)' : v === true ? 'Yes' : v === false ? 'No' : String(v))
const canon = (v) => (v == null ? 'null' : Array.isArray(v) ? `[${v.map(canon).join(',')}]` : typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}` : JSON.stringify(v))
const eq = (a, b) => canon(a ?? null) === canon(b ?? null)
const mapOf = (m) => { if (!m || typeof m !== 'object') return null; const { rev, ...n } = m; const pins = n.pins && typeof n.pins === 'object' ? n.pins : {}; const ar = Array.isArray(n.arrows) ? n.arrows : []; return !pins.gt && !pins.truck && !ar.length ? null : n }
// the changed days in week order since the Site file build (Fred, 2026-09-28: "Fine, days in week order"); any other key after them
const WEEK = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], dayRank = (d) => (WEEK.includes(d) ? WEEK.indexOf(d) : WEEK.length)
function diff(nw, old) {
  const out = [], a = nw?.facts ?? {}, b = old?.facts ?? {}
  for (const k of new Set([...Object.keys(b), ...Object.keys(a)])) if (!eq(a[k] === '' ? null : a[k], b[k] === '' ? null : b[k])) out.push(`${lab(k)}: ${show(b[k])} -> ${show(a[k])}`)
  const ha = nw?.hours ?? {}, hb = old?.hours ?? {}, hd = [...new Set([...Object.keys(hb), ...Object.keys(ha)])].filter((d) => !eq(ha[d], hb[d])).sort((x, y) => dayRank(x) - dayRank(y))
  if (hd.length) out.push(`Hours changed: ${hd.join(', ')}`)
  if ((nw?.notes ?? '') !== (old?.notes ?? '')) out.push('Notes changed')
  if (!eq(nw?.contacts, old?.contacts)) out.push('Contacts changed')
  const ids = (c) => new Set((c?.photos ?? []).map((p) => String(p.photo_id))), ia = ids(nw), ib = ids(old)
  const add = [...ia].filter((x) => !ib.has(x)).length, rem = [...ib].filter((x) => !ia.has(x)).length
  if (add) out.push(`${add} photo${add > 1 ? 's' : ''} added`)
  if (rem) out.push(`${rem} photo${rem > 1 ? 's' : ''} removed`)
  if (!eq(mapOf(nw?.site_map), mapOf(old?.site_map))) out.push('Site map changed')
  return out
}
const ET = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true })
const fmt = (t) => ET.format(new Date(t))
const byNum = (n) => VERSIONS.find((v) => v.version === n)
const prevLiveOf = (v) => VERSIONS.filter((x) => x.version < v.version && x.approved_at).sort((a, b) => b.version - a.version)[0] || null
const OTHER = row.act.filter((e) => e.kind === 'driver_link_created' || e.kind === 'driver_link_replaced')
const around = (v) => { const t = (x) => Date.parse(x), ev = row.act.filter((e) => e.kind !== 'page_submitted' && e.kind !== 'page_approved'), pl = prevLiveOf(v)
  const before = ev.filter((e) => (!pl || t(e.at) >= t(pl.approved_at)) && (!v.approved_at || t(e.at) < t(v.approved_at)))
  const live = v.approved_at ? ev.filter((e) => t(e.at) >= t(v.approved_at) && (!v.replaced_at || t(e.at) < t(v.replaced_at))) : []
  return { before, live } }
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './activity_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, versions = VERSIONS, act = row.act, failing = []) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], errors: [], failing: new Set(failing) }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })  // Maps is aborted on purpose (no paid tiles)
  const replies = { get_page_builder: row.pb, get_page_builder_forms: row.forms, get_property_activity: act, get_page_versions: versions }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    if (st.failing.has(n)) return x.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom","code":"XX000"}' })
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(3500)
  return { ctx, p, st }
}
const count = (st, n) => st.calls.filter((c) => c === n).length
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
const header = (p) => p.evaluate(() => {
  const vb = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'View site file')
  const ab = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Activity')
  const box = (e) => (e ? e.getBoundingClientRect().toJSON() : null)
  return { vb: box(vb), ab: box(ab), adjacent: !!(vb && ab && vb.previousElementSibling === ab), hook: !!(ab && ab.hasAttribute('data-activity-open')) }
})
const oldCard = (p) => p.evaluate(() => /Who asked for site survey forms, who filled them/.test(document.body.textContent) || [...document.querySelectorAll('main h2, main h3, section > h2')].some((h) => h.textContent.trim() === 'Activity' && !h.closest('[role="dialog"]')))
const openModal = async (p) => { await p.locator('button', { hasText: /^Activity$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForFunction(() => { const d = document.querySelector('[data-activity-dialog]'); return !!d && (!!d.querySelector('[data-version-item]') || /could not be loaded|Nothing has happened/.test(d.textContent)) }, null, { timeout: 8000 }).catch(() => {}); await p.waitForTimeout(600) }
const dialog = (p) => p.evaluate(() => {
  const d = document.querySelector('[role="dialog"][aria-modal="true"]')
  if (!d) return null
  const title = document.getElementById(d.getAttribute('aria-labelledby') || '')
  const vis = (e) => !!e && e.offsetParent !== null && getComputedStyle(e).visibility !== 'hidden'
  const txt = (e) => (e ? [...e.childNodes].map((c) => c.textContent).join(' ').replace(/\s+/g, ' ').trim() : '')
  const det = d.querySelector('[data-version-detail]')
  const nav = d.querySelector('nav[aria-label="Versions"]')
  const rows = det ? Object.fromEntries([...det.querySelectorAll('[data-row]')].map((x) => [x.getAttribute('data-row'), x.textContent.replace(/\s+/g, ' ').trim()])) : {}
  const labels = det ? [...det.querySelectorAll('p')].map((x) => x.textContent.trim()).filter((t) => /^(What changed since version \d+|First version|Before it went live|While it is live|While it was live|So far|Since version \d+ went live)$/i.test(t)) : []
  const events = (k) => { const g = det && det.querySelector(`[data-events="${k}"]`); return g ? [...g.querySelectorAll('li')].map((li) => ({ text: li.textContent.replace(/\s+/g, ' ').trim(), links: [...li.querySelectorAll('a')].map((a) => [a.textContent.trim(), a.getAttribute('href')]) })) : null }
  const back = d.querySelector('[data-activity-back]')
  const b = d.getBoundingClientRect()
  return { title: title ? title.textContent.trim() : null, focusIsTitle: !!title && document.activeElement === title, rect: { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) },
    items: [...d.querySelectorAll('[data-version-item]')].map((x) => ({ v: x.getAttribute('data-version-item'), badge: (x.querySelector('[data-badge]') || {}).getAttribute ? x.querySelector('[data-badge]').getAttribute('data-badge') : null, text: x.textContent.replace(/\s+/g, ' ').trim(), cur: x.getAttribute('aria-current'), h: Math.round(x.getBoundingClientRect().height) })),
    liveBadges: d.querySelectorAll('[data-version-item] [data-badge="live"]').length,
    detail: det ? det.getAttribute('data-version-detail') : null, heading: det && det.querySelector('h3') ? txt(det.querySelector('h3')) : '', rows, labels,
    changes: det && det.querySelector('[data-changes]') ? [...det.querySelectorAll('[data-changes] li')].map((li) => li.textContent.trim()) : null,
    before: events('before'), live: events('live'), navVisible: vis(nav), detailVisible: vis(det), back: back ? { vis: vis(back), h: Math.round(back.getBoundingClientRect().height) } : null,
    close: (() => { const c = d.querySelector('[data-activity-close]') || [...d.querySelectorAll('button')].find((x) => x.getAttribute('aria-label') === 'Close'); return c ? Math.round(c.getBoundingClientRect().height) : 0 })(),
    overflowX: d.scrollWidth > d.clientWidth + 1, htmlLocked: document.documentElement.style.overflow === 'hidden', text: d.textContent.replace(/\s+/g, ' ') }
})
const afterClose = (p) => p.evaluate(() => ({ open: !!document.querySelector('[role="dialog"][aria-modal="true"]'), focus: !document.activeElement || document.activeElement === document.body ? 'body' : document.activeElement.textContent.trim().slice(0, 40), focusHook: !!(document.activeElement && document.activeElement.hasAttribute('data-activity-open')), inert: document.querySelectorAll('[inert]').length, overflow: document.documentElement.style.overflow }))
const choose = async (p, v) => { await p.locator(`[data-version-item="${v}"]`).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(400) }
const expectRows = (v) => {
  const made = `${v.submitted_by_name || 'someone'}, ${fmt(v.submitted_at)}`
  const checked = v.approved_at ? `${v.approved_by_name || 'someone'}${v.self_approved ? ' (developer approval)' : ''}, ${fmt(v.approved_at)}` : v.status === 'waiting' ? 'Not checked yet' : 'Never approved'
  const pl = prevLiveOf(v)
  return { made, checked, replaced: v.approved_at ? (pl ? `Version ${pl.version}` : 'Nothing, it was the first live version') : undefined, 'replaced-by': v.status === 'replaced' ? `Version ${v.replaced_by_version} on ${fmt(v.replaced_at)}` : undefined }
}
const detailOk = (D, v) => { const e = expectRows(v); return Object.entries(e).every(([k, want]) => (want === undefined ? !(k in D.rows) : D.rows[k] === want)) }
const changesOk = (D, v) => { const prev = byNum(v.version - 1); if (!prev) return D.labels.includes('First version') && D.changes === null; const want = diff(v.content, prev.content); return D.labels.includes(`What changed since version ${prev.version}`) && (want.length ? JSON.stringify(D.changes) === JSON.stringify(want) : D.changes === null && D.text.includes(`No differences from version ${prev.version}.`)) }

// A. Laptop 1440: button, no call before opening, no old card, the modal
{
  const { ctx, p, st } = await open(1440)
  const h = await header(p)
  ok(h.adjacent && h.hook, '1440: an Activity button sits immediately before View site file', h)
  ok(h.ab && h.vb && Math.abs((h.ab.y + h.ab.height / 2) - (h.vb.y + h.vb.height / 2)) <= 2 && h.ab.x + h.ab.width <= h.vb.x, '1440: on the same line, to its left', [h.ab, h.vb])
  ok(h.ab && h.ab.height >= 34 && h.ab.height <= 40, '1440: the laptop size (36px)', h.ab && h.ab.height)
  ok(count(st, 'get_property_activity') === 0 && count(st, 'get_page_versions') === 0, '1440: no activity or versions call before the modal opens', [...new Set(st.calls)])
  ok(!(await oldCard(p)), '1440: the old Activity card is gone from the builder')
  await openModal(p)
  const D = await dialog(p)
  ok(!!D && D.title === 'Activity', '1440: a role=dialog aria-modal layer titled Activity opens', D && D.title)
  ok(!!D && D.focusIsTitle, '1440: focus is on the title')
  ok(!!D && D.htmlLocked, '1440: the page behind does not scroll (html overflow hidden)')
  ok(count(st, 'get_property_activity') === 1 && count(st, 'get_page_versions') === 1, '1440: opening reads get_page_versions and get_property_activity once each', [count(st, 'get_page_versions'), count(st, 'get_property_activity')])
  ok(!!D && Math.abs(D.rect.w - 940) <= 2, '1440: the modal is about 940px wide', D && D.rect)
  const vs = D ? D.items.filter((x) => x.v !== 'other').map((x) => x.v) : []
  ok(vs.join() === VERSIONS.map((v) => String(v.version)).join(), '1440: versions newest first', vs)
  ok(!!D && D.liveBadges === 1 && D.items.find((x) => x.v === String(LIVE.version))?.badge === 'live', '1440: exactly one Live badge, on the live version', D && D.items.map((x) => [x.v, x.badge]))
  ok(!!D && D.items.filter((x) => x.v !== 'other' && x.v !== String(LIVE.version)).every((x) => x.badge === 'replaced'), '1440: the older versions read Replaced', D && D.items.map((x) => [x.v, x.badge]))
  ok(!!D && D.items.some((x) => x.v === 'other' && x.text.includes(`Site file links · ${OTHER.length}`)), '1440: an Other activity item with the site file link count', D && D.items.map((x) => x.text))
  ok(!!D && D.detail === String(LIVE.version) && D.items.find((x) => x.v === String(LIVE.version))?.cur === 'true', '1440: the live version is shown first', D && D.detail)
  ok(!!D && detailOk(D, LIVE), '1440: Made by, Checked by (developer approval when the same person) and Replaced lines', [D && D.rows, expectRows(LIVE)])
  ok(!!D && changesOk(D, LIVE), `1440: What changed since version ${LIVE.version - 1}, the review's own lines`, [D && D.labels, D && D.changes, diff(LIVE.content, byNum(LIVE.version - 1)?.content)])
  // the week order, derived from the stubbed versions: only a live version with 2 or more changed days stored out of week order can tell the two orders apart
  const prevL = byNum(LIVE.version - 1), hrs = (c) => c?.hours ?? {}, hDiff = (d) => !eq(hrs(LIVE.content)[d], hrs(prevL?.content)[d])
  const wkDays = prevL ? WEEK.filter(hDiff) : [], rawDays = prevL ? [...new Set([...Object.keys(hrs(prevL.content)), ...Object.keys(hrs(LIVE.content))])].filter(hDiff) : []
  const wkLine = `Hours changed: ${wkDays.join(', ')}`, wkUsable = wkDays.length > 1 && rawDays.join() !== wkDays.join()
  ok(wkUsable && !!D && (D.changes || []).includes(wkLine), wkUsable ? '1440: What changed lists the changed days in week order (mon to sun)' : 'fixture: the live version needs 2 or more changed days stored out of week order', { shown: D && (D.changes || []).find((x) => x.startsWith('Hours changed')), want: wkLine, stored: rawDays.join(', ') })
  const aL = around(LIVE)
  ok(!!D && D.labels.includes('Before it went live') && D.labels.includes('While it is live'), '1440: the activity is grouped Before it went live / While it is live', D && D.labels)
  ok(!!D && D.before && D.live && D.before.length === aL.before.length && D.live.length === aL.live.length && aL.before.every((e, i) => D.before[i].text.includes(e.text)) && aL.live.every((e, i) => D.live[i].text.includes(e.text)), '1440: each event sits in the right group, newest first', [D && D.before && D.before.map((x) => x.text), D && D.live && D.live.map((x) => x.text)])
  const fe = aL.before.find((e) => e.intake_id != null)
  ok(!fe || (D && D.before && D.before.some((x) => x.links.some(([t, href]) => t === `Open form #${fe.intake_id}` && /\/forms\/\d+$/.test(href || '') && href.endsWith('/' + fe.intake_id)))), '1440: a form event links "Open form #N" to /forms/N', D && D.before && D.before.map((x) => x.links))
  ok(!!D && !D.overflowX && !(await sideways(p)), '1440: no sideways scroll')
  await p.screenshot({ path: `${out}/A_open_1440.png` })
  const older = VERSIONS.find((v) => v.status === 'replaced' && byNum(v.version - 1))
  if (older) {
    await choose(p, older.version)
    const D2 = await dialog(p)
    ok(!!D2 && D2.detail === String(older.version) && detailOk(D2, older), `1440: choosing version ${older.version} switches the detail (Replaced by version ${older.replaced_by_version} on ...)`, [D2 && D2.detail, D2 && D2.rows, expectRows(older)])
    ok(!!D2 && changesOk(D2, older) && D2.labels.includes('While it was live'), `1440: its What changed since version ${older.version - 1} and While it was live`, [D2 && D2.labels, D2 && D2.changes])
  } else ok(false, '1440: fixture needs a replaced version with a version before it')
  const first = VERSIONS[VERSIONS.length - 1]
  await choose(p, first.version)
  const D3 = await dialog(p)
  ok(!!D3 && D3.detail === String(first.version) && changesOk(D3, first), `1440: version ${first.version} reads First version`, D3 && D3.labels)
  await choose(p, 'other')
  const D4 = await dialog(p)
  ok(!!D4 && D4.detail === 'other' && OTHER.every((e) => D4.text.includes(e.text)), '1440: Other activity lists the driver link events', D4 && D4.detail)
  await p.keyboard.press('Escape'); await p.waitForTimeout(500)
  const c = await afterClose(p)
  ok(!c.open && c.focusHook && c.inert === 0 && c.overflow === '', '1440: Esc closes, focus is back on Activity, nothing left inert, the page scrolls again', c)
  // the shared layer must leave FullView (the preview) working as before
  await p.locator('button', { hasText: /^View site file$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(700)
  const pv = await p.evaluate(() => { const d = document.querySelector('[role="dialog"][aria-modal="true"]'); return { open: !!d, title: d ? (document.getElementById(d.getAttribute('aria-labelledby') || '') || {}).textContent : null, locked: document.documentElement.style.overflow === 'hidden' } })
  await p.keyboard.press('Escape'); await p.waitForTimeout(500)
  const pc = await afterClose(p)
  ok(pv.open && /Preview/.test(pv.title || '') && pv.locked && !pc.open && pc.focus === 'View site file' && pc.inert === 0, '1440: the site file preview still opens, locks, closes on Esc and returns focus', [pv, pc])
  ok(st.errors.length === 0, '1440: no page errors', st.errors)
  ok([...new Set(st.calls)].every((n) => ['get_page_builder', 'get_page_builder_forms', 'get_property_activity', 'get_page_versions'].includes(n)), '1440: no other call', [...new Set(st.calls)])
  await ctx.close()
}

// B. A version waiting for approval: still one Live, the live one shown first, the waiting one reads Not checked yet
{
  const W4 = clone(LIVE); Object.assign(W4, { page_id: 999998, version: VERSIONS[0].version + 1, status: 'waiting', approved_at: null, approved_by_name: null, self_approved: false, replaced_by_version: null, replaced_at: null, submitted_at: new Date().toISOString() })
  W4.content.facts = { ...W4.content.facts, manholes: (Number(LIVE.content.facts?.manholes) || 0) + 1 }
  const VW = [W4, ...clone(VERSIONS)]
  const { ctx, p } = await open(1440, VW)
  await openModal(p)
  const D = await dialog(p)
  ok(!!D && D.items[0] && D.items[0].v === String(W4.version) && D.items[0].badge === 'waiting' && D.items[0].text.includes('Waiting for approval'), 'waiting: the new version is first, marked Waiting for approval', D && D.items.map((x) => [x.v, x.badge]))
  ok(!!D && D.liveBadges === 1 && D.detail === String(LIVE.version), 'waiting: still exactly one Live, and the live version is shown first', D && [D.liveBadges, D.detail])
  await choose(p, W4.version)
  const D2 = await dialog(p)
  ok(!!D2 && D2.rows.checked === 'Not checked yet' && !('replaced' in D2.rows) && (D2.changes || []).includes(`Manholes: ${show(LIVE.content.facts?.manholes)} -> ${W4.content.facts.manholes}`), 'waiting: Not checked yet, and what changed since the live version', D2 && [D2.rows, D2.changes])
  await ctx.close()
}

// C. Errors and the empty property
{
  const { ctx, p, st } = await open(1440, VERSIONS, row.act, ['get_property_activity'])
  await openModal(p)
  const D = await dialog(p)
  ok(!!D && D.text.includes('The activity could not be loaded.') && /Try again/.test(D.text), 'error: the plain sentence with Try again', D && D.text.slice(0, 200))
  st.failing.clear()
  await p.locator('[role="dialog"] button', { hasText: /^Try again$/ }).first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1200)
  const D2 = await dialog(p)
  ok(!!D2 && D2.items.length === VERSIONS.length + 1, 'error: Try again loads the versions', D2 && D2.items.length)
  await ctx.close()
}
{
  const { ctx, p } = await open(390, [], [])
  await openModal(p)
  const D = await dialog(p)
  ok(!!D && D.text.includes('Nothing has happened on this property yet.'), 'empty (390): the empty sentence', D && D.text.slice(0, 200))
  await ctx.close()
}

// D. Phone 390: button before View site file and 44px; full screen; list first; a version opens in place; Back
{
  const { ctx, p, st } = await open(390)
  const h = await header(p)
  ok(h.adjacent && h.hook, '390: the Activity button sits immediately before View site file', h)
  ok(h.ab && h.ab.height >= 44, '390: 44px tall', h.ab && h.ab.height)
  ok(count(st, 'get_property_activity') === 0 && count(st, 'get_page_versions') === 0, '390: no activity or versions call before it opens', [...new Set(st.calls)])
  ok(!(await oldCard(p)), '390: the old Activity card is gone')
  await openModal(p)
  const D = await dialog(p)
  ok(!!D && D.rect.x === 0 && D.rect.y === 0 && D.rect.w === 390 && Math.abs(D.rect.h - 844) <= 1, '390: the modal fills the screen', D && D.rect)
  ok(!!D && D.focusIsTitle, '390: focus is on the title')
  ok(!!D && D.navVisible && !D.detailVisible, '390: the list shows first, the detail is hidden', D && [D.navVisible, D.detailVisible])
  ok(!!D && D.close >= 44 && D.items.length && D.items.every((x) => x.h >= 44), '390: the close button and every item are 44px or taller', D && [D.close, D.items.map((x) => x.h)])
  await p.screenshot({ path: `${out}/D_list_390.png` })
  const older = VERSIONS.find((v) => v.status === 'replaced') || VERSIONS[1]
  await choose(p, older.version)
  const D2 = await dialog(p)
  ok(!!D2 && D2.detailVisible && !D2.navVisible && D2.detail === String(older.version), `390: choosing version ${older.version} opens its detail in place of the list`, D2 && [D2.navVisible, D2.detailVisible, D2.detail])
  ok(!!D2 && D2.back && D2.back.vis && D2.back.h >= 44 && D2.text.includes('Back to versions'), '390: with a 44px Back to versions button', D2 && D2.back)
  ok(!!D2 && !D2.overflowX && !(await sideways(p)), '390: no sideways scroll')
  await p.screenshot({ path: `${out}/D_detail_390.png` })
  await p.locator('[data-activity-back]').first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(400)
  const D3 = await dialog(p)
  ok(!!D3 && D3.navVisible && !D3.detailVisible, '390: Back to versions shows the list again', D3 && [D3.navVisible, D3.detailVisible])
  await p.locator('[data-activity-close]').first().click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(500)
  const c = await afterClose(p)
  ok(!c.open && c.focusHook && c.inert === 0, '390: Close closes and returns focus to Activity', c)
  ok(st.errors.length === 0, '390: no page errors', st.errors)
  await ctx.close()
}

await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
