// LIVE Page Builder /property/1164: RESTORE A VERSION (Fred, 2026-09-29: "i want like a go back way ... without removing
// the version 4"; his picks: copy as new version, same approval, open as a draft first, button R2). The Activity modal's
// version detail gets "Restore this version" on Replaced versions only; it loads that version into the builder as the draft
// ("Restored from version N. Check it, then Submit for approval." with Undo), and Submit sends p_restored_from_version.
// Real replies: get_page_builder / forms / get_property_activity / get_page_versions read as Fred's claims (before the
// page_restore migration the versions carry no source: the test then fills it from property_pages, read as postgres).
// Sign-in faked; every call stubbed; submit_property_page is answered by the stub, nothing is written. Codes are masked.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-29-restore-version-design.md
//   node scripts/page-builder/tests/restore_version.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_property_activity(1164) as act, client.get_page_versions(1164) as versions,
       (select json_agg(json_build_object('version', pg.version, 'source', pg.source) order by pg.version) from public.property_pages pg where pg.property_id = 1164) as sources;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.pb || !row.pb.live || !Array.isArray(row.versions) || !Array.isArray(row.sources)) { console.log('FAIL fixture: no 1164 reply :: ' + ((r && r.message) || Object.keys(row || {}))); process.exit(1) }  // never the raw reply: it holds the link code
const clone = (x) => JSON.parse(JSON.stringify(x))
const PB = row.pb, T = PB.property.source
const FILLED = row.versions.some((v) => !('source' in v))
const VERSIONS = row.versions.map((v) => ({ restored_from_version: null, ...v, source: 'source' in v ? v.source : (row.sources.find((s) => s.version === v.version) || {}).source ?? null }))
console.log(`get_page_versions stub: ${VERSIONS.length} versions of 1164, read as Fred${FILLED ? ' (no source yet: the page_restore migration is not applied; filled from property_pages)' : ''}`)
// every value that looks like a code, in every reply, is masked wherever this script prints
const SECRETS = new Set()
const collect = (v, k = '') => { if (v && typeof v === 'object') { for (const [kk, vv] of Object.entries(v)) collect(vv, kk) } else if (v != null && /code|key_tag|public_id|lock_box|token/i.test(k) && String(v).trim().length >= 3) SECRETS.add(String(v)) }
collect(PB); collect(VERSIONS); collect(row.forms)
const mask = (s) => [...SECRETS].reduce((t, x) => t.split(x).join('<code>'), String(s))
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(JSON.stringify(v)).slice(0, 400)}`) }
const near = (a, b, t = 1) => a != null && b != null && Math.abs(a - b) <= t
// independent copies of the builder's rules (the spec, written apart from the build)
const LA = { key_tag: 'Key tag', gt_systems: 'Grease trap systems', gallons: 'Gallons', manholes: 'Manholes', cleanouts: 'Cleanouts', sample_ports: 'Sample ports', lift_stations: 'Lift stations', water_tanks: 'Water tanks', water_tank_capacity: 'Water tank capacity', gate: 'Gate', gate_code: 'Gate code', how_access: 'How to get in', lock_box_code: 'Lock box code', key_instruction: 'Key instructions', alarm: 'Alarm', alarm_instruction: 'Alarm instructions', equipment_where: 'Where the equipment is', access_point: 'Access point', obstacles: 'Obstacles' }
const lab = (k) => LA[k] ?? k.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())
const show = (v) => (v == null || v === '' ? '(empty)' : v === true ? 'Yes' : v === false ? 'No' : String(v))
const canon = (v) => (v == null ? 'null' : Array.isArray(v) ? `[${v.map(canon).join(',')}]` : typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}` : JSON.stringify(v))
const eq = (a, b) => canon(a ?? null) === canon(b ?? null)
const mapOf = (m) => { if (!m || typeof m !== 'object') return null; const { rev, ...n } = m; const pins = n.pins && typeof n.pins === 'object' ? n.pins : {}; const ar = Array.isArray(n.arrows) ? n.arrows : []; return !pins.gt && !pins.truck && !ar.length ? null : n }
const WEEK = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], dayRank = (d) => (WEEK.includes(d) ? WEEK.indexOf(d) : WEEK.length)
function diff(nw, old) {  // the review's "What changed" lines
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
const photosOf = (c) => (c?.photos ?? []).map((ph) => `${ph.photo_id}|${ph.section}|${ph.note ?? ''}|${canon(ph.marks ?? [])}`)
const sameContent = (sent, stored) => !!sent && diff(sent, stored).length === 0 && photosOf(sent).join() === photosOf(stored).join() && (sent.include_map !== false) === (stored?.include_map !== false)
// the "Changed in the Client App's property data" rule (the builder's own list and order)
const hrs = (e) => { const t = {}; if (!e || typeof e !== 'object') return t; const put = (k, v) => { const d = String(k).toLowerCase().slice(0, 3); if (!WEEK.includes(d) || !v) return; let o, c; if (Array.isArray(v)) [o, c] = v; else if (typeof v === 'object') { o = v.open ?? v.from ?? v.start; c = v.close ?? v.to ?? v.end } if (!o || !c) return; const f = (s) => { const m = /^(\d{1,2}):(\d{2})/.exec(s); return m ? m[1].padStart(2, '0') + ':' + m[2] : s }; t[d] = { open: f(o), close: f(c) } }; Array.isArray(e) ? e.forEach((x) => x?.day && put(String(x.day), x)) : Object.entries(e).forEach(([k, v]) => put(k, v)); return t }
const sameHrs = (a, b) => WEEK.every((d) => (a[d]?.open ?? '') === (b[d]?.open ?? '') && (a[d]?.close ?? '') === (b[d]?.close ?? ''))
const jo = (v) => (v == null || (typeof v === 'string' && !v.trim()) ? 'empty' : String(v))
const NOTICE = [['lock_box_key', 'Lock box code'], ['gallons', 'Grease trap gallons'], ['manholes', 'Manholes'], ['sample_ports', 'Sample ports'], ['access_schedule', 'Access hours'], ['access_notes', 'Access notes']]
const noticeLabels = (a, b) => NOTICE.filter(([k]) => { const x = a?.[k], y = b?.[k]; if (k === 'access_schedule') return !sameHrs(hrs(x), hrs(y)); if (k === 'gallons' || k === 'manholes' || k === 'sample_ports') { const p = jo(x), q = jo(y); return p === 'empty' || q === 'empty' ? p !== q : Number(p) !== Number(q) } return jo(x) !== jo(y) }).map(([, l]) => l)
// a photo's marks turned by its rotation since the version was made (the page's own rule)
const turn = (marks, deg) => { const n = ((Math.round(deg / 90) % 4) + 4) % 4; if (!n) return marks; const rt = (x, y) => { let a = x, b = y; for (let i = 0; i < n; i++) [a, b] = [1 - b, a]; return [a, b] }; return marks.map((m) => { if (m.kind === 'arrow') { const [x1, y1] = rt(m.x1, m.y1), [x2, y2] = rt(m.x2, m.y2); return { ...m, x1, y1, x2, y2 } } if (m.kind === 'ring' || m.kind === 'rect') { const p = rt(m.x, m.y), q = rt(m.x + m.w, m.y + m.h); return { ...m, x: Math.min(p[0], q[0]), y: Math.min(p[1], q[1]), w: Math.abs(p[0] - q[0]), h: Math.abs(p[1] - q[1]) } } const [x, y] = rt(m.x, m.y); return { ...m, x, y } }) }
const hasMap = (c) => !!mapOf(c?.site_map)

// the fixture's versions, derived (never typed in)
const LIVE = VERSIONS.find((v) => v.status === 'live')
const REPL = VERSIONS.filter((v) => v.status === 'replaced')
const FROM = [...REPL].sort((a, b) => a.version - b.version).find((v) => hasMap(v.content) && noticeLabels(v.source, T).length > 0 && diff(v.content, LIVE?.content).length > 0)
const NOMAP = REPL.find((v) => !hasMap(v.content))
if (!LIVE || !FROM || !NOMAP) { console.log('FAIL fixture: 1164 needs a live version, a replaced version with a map whose property data differs from today, and a replaced version with no map', JSON.stringify({ live: !!LIVE, from: !!FROM, nomap: !!NOMAP })); process.exit(1) }
const WANT_NOTICE = noticeLabels(FROM.source, T)
console.log(`fixture: live v${LIVE.version}, restore v${FROM.version} (map, ${WANT_NOTICE.length} property data lines differ), empty map v${NOMAP.version}, newest ${PB.newest_version}`)
const BASE = { pb: PB, forms: row.forms, act: row.act, versions: VERSIONS }
// D: version FROM with a photo that is gone (owned false) and marks on a photo rotated 90 degrees since
const GONE = 990001, M = [{ id: 'rv-c', kind: 'circle', x: 0.2, y: 0.3, number: 1, color: 'red' }, { id: 'rv-a', kind: 'arrow', x1: 0.1, y1: 0.1, x2: 0.5, y2: 0.4, color: 'red' }]
const D = clone(BASE)
const DF = D.versions.find((v) => v.version === FROM.version)
const ROT = (DF.content.photos || []).map((ph) => String(ph.photo_id)).find((id) => (D.pb.referenced || []).some((x) => String(x.photo_id) === id))
for (const ph of DF.content.photos) if (String(ph.photo_id) === ROT) { ph.marks = clone(M); ph.rot = 0 }
DF.content.photos.push({ photo_id: GONE, section: 'access', note: null, marks: [], rot: 0 })
for (const x of [...(D.pb.pool || []), ...(D.pb.referenced || [])]) if (String(x.photo_id) === ROT) x.rotation_deg = 90
D.pb.referenced.push({ photo_id: GONE, owned: false })
const D_WANT = clone(DF.content); D_WANT.photos = D_WANT.photos.filter((ph) => ph.photo_id !== GONE).map((ph) => (String(ph.photo_id) === ROT ? { ...ph, marks: turn(M, 90) } : ph))
// W: a version waiting for approval and an older one never approved
const W = clone(BASE), top = VERSIONS[0].version
const S1 = { ...clone(LIVE), page_id: 999996, version: top + 1, status: 'superseded', approved_at: null, approved_by_name: null, self_approved: false, replaced_by_version: top + 2, replaced_at: new Date().toISOString(), restored_from_version: null }
const W2 = { ...clone(LIVE), page_id: 999997, version: top + 2, status: 'waiting', approved_at: null, approved_by_name: null, self_approved: false, replaced_by_version: null, replaced_at: null, restored_from_version: null }
W.versions = [W2, S1, ...W.versions]
// G: after approval: a restored copy of FROM is Live, the old Live is replaced by it
const G = clone(BASE), now = new Date().toISOString()
const V5 = { ...clone(FROM), page_id: 999998, version: top + 1, status: 'live', submitted_at: now, approved_at: now, restored_from_version: FROM.version, replaced_by_version: null, replaced_at: null, self_approved: true }
G.versions = [V5, ...G.versions.map((v) => (v.version === LIVE.version ? { ...v, status: 'replaced', replaced_by_version: V5.version, replaced_at: now } : v))]

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './restore_version_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, data = BASE, opts = {}) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  // the builder's Google map, captured when the Maps loader calls window.__initAccessMap (scenario F loads the real map)
  if (opts.maps) await ctx.addInitScript(() => { window.__maps = []; let cb; Object.defineProperty(window, '__initAccessMap', { configurable: true, get() { return cb }, set(f) { cb = function () { const M = window.google.maps.Map; if (!M.__cap) { M.__cap = 1; const al = M.prototype.addListener; M.prototype.addListener = function () { if (!window.__maps.includes(this)) window.__maps.push(this); return al.apply(this, arguments) } } return f.apply(this, arguments) } } }) })
  const p = await ctx.newPage()
  const st = { calls: [], submits: [], errors: [] }
  p.on('pageerror', (e) => { if (!/Google Maps/.test(String(e))) st.errors.push(String(e)) })  // Maps is aborted on purpose (no paid tiles)
  const replies = { get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: data.act, get_page_versions: data.versions }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => { const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    if (n === 'submit_property_page') { let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {} st.submits.push(b); return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, page_id: 999999, version: (data.pb.newest_version || 0) + 1 }) }) }
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' }) })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route(SB + '/functions/v1/**', (x) => x.abort())  // never a real code
  if (!opts.maps) await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  await p.route('https://places.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/property/1164')
  await ready(p)
  return { ctx, p, st }
}
const ready = async (p) => { await p.waitForFunction(() => [...document.querySelectorAll('h3')].some((h) => h.textContent === 'Contacts'), null, { timeout: 30000 }).catch(() => {}); await p.waitForTimeout(3000) }
const openModal = async (p) => { await p.locator('[data-activity-open]').first().click({ timeout: 5000 }).catch(() => {}); await p.waitForFunction(() => !!document.querySelector('[data-activity-dialog] [data-version-item]'), null, { timeout: 8000 }).catch(() => {}); await p.waitForTimeout(500) }
const choose = async (p, v) => { await p.locator(`[data-version-item="${v}"]`).first().click({ timeout: 4000 }).catch(() => {}); await p.waitForTimeout(400) }
const click = async (p, sel) => { await p.locator(sel).first().click({ timeout: 3000 }).catch(() => {}); await p.waitForTimeout(700) }
const clickText = async (p, re) => { await p.locator('button', { hasText: re }).first().click({ timeout: 3000 }).catch(() => {}); await p.waitForTimeout(700) }
const pane = (p) => p.evaluate(() => {
  const d = document.querySelector('[data-activity-dialog] [data-version-detail]')
  if (!d) return null
  const vis = (e) => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden'
  const rc = (e) => { if (!e) return null; const b = e.getBoundingClientRect(); return { x: Math.round(b.x), w: Math.round(b.width), h: Math.round(b.height), r: Math.round(b.right), cy: Math.round(b.y + b.height / 2) } }
  const t = (e) => (e ? e.textContent.replace(/\s+/g, ' ').trim() : null)
  const h3 = d.querySelector('h3'), b = d.querySelector('[data-restore-version]'), hint = d.querySelector('[data-restore-hint]'), cf = d.querySelector('[data-restore-confirm]')
  const ps = cf ? [...cf.querySelectorAll('p')] : []
  return { v: d.getAttribute('data-version-detail'), paneRight: Math.round(d.getBoundingClientRect().left + d.clientLeft + d.clientWidth - parseFloat(getComputedStyle(d).paddingRight)),
    btn: b && vis(b) ? { text: t(b), rect: rc(b), described: b.getAttribute('aria-describedby'), rowHasH3: !!(b.parentElement && h3 && b.parentElement.contains(h3)) } : null, h3: rc(h3),
    hint: hint ? { id: hint.id, text: t(hint) } : null,
    confirm: cf ? { title: t(ps[0]), lines: ps.slice(1).map(t), buttons: [...cf.querySelectorAll('button')].map((x) => ({ t: t(x), h: Math.round(x.getBoundingClientRect().height) })), focus: document.activeElement && cf.contains(document.activeElement) ? t(document.activeElement) : null } : null,
    restoredRow: t(d.querySelector('[data-row="restored-from"]')), focusOnBtn: !!(b && document.activeElement === b) }
})
const item = (p, v) => p.evaluate((v) => { const e = document.querySelector(`[data-version-item="${v}"]`); return e ? e.textContent.replace(/\s+/g, ' ').trim() : null }, String(v))
const builder = (p) => p.evaluate(() => {
  const t = (e) => (e ? e.textContent.replace(/\s+/g, ' ').trim() : null)
  const bn = document.querySelector('[data-restore-banner]')
  let bt = null; if (bn) { const c = bn.cloneNode(true); c.querySelectorAll('button').forEach((x) => x.remove()); bt = c.textContent.replace(/\s+/g, ' ').trim() }
  const nh = [...document.querySelectorAll('p.font-semibold')].find((x) => x.textContent.startsWith("Changed in the Client App's property data since"))
  const ph = document.querySelector('[data-restore-photos]')
  const sub = [...document.querySelectorAll('button')].find((x) => x.textContent.trim() === 'Submit for approval')
  const body = document.body.textContent
  return { banner: bn ? { text: bt, role: bn.getAttribute('role'), buttons: [...bn.querySelectorAll('button')].map((x) => ({ t: t(x), h: Math.round(x.getBoundingClientRect().height) })) } : null,
    oldBar: /Restored your draft from/.test(body), header: [...document.querySelectorAll('header p')].map(t).find((x) => /^(Editing|New page)/.test(x || '')) || null,
    notice: nh ? { heading: t(nh), labels: [...nh.parentElement.querySelectorAll('li')].map((li) => li.textContent.split(':')[0].trim()) } : null,
    photos: ph ? { text: t(ph.querySelector('p')), button: t(ph.querySelector('button')) } : null,
    submitDisabled: sub ? sub.disabled : null, holdPhotos: body.includes('Leave out the photos that are no longer on this property first.'),
    holdNotice: body.includes("Check what changed in the Client App's property data first."), modalOpen: !!document.querySelector('[data-activity-dialog]'),
    notes: (document.getElementById('pp-shared-access-notes') || {}).value ?? null, focusActivity: !!(document.activeElement && document.activeElement.hasAttribute('data-activity-open')),
    sideways: document.documentElement.scrollWidth > innerWidth }
})
const draft = (p) => p.evaluate(() => { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith('pp-draft:')) { try { return JSON.parse(localStorage.getItem(k)) } catch { return 'bad' } } } return null })
const typeNotes = async (p, s) => { await p.locator('#pp-shared-access-notes').click({ timeout: 4000 }).catch(() => {}); await p.keyboard.press('End'); await p.keyboard.type(s); await p.waitForTimeout(1800) }
const submit = async (p) => { await clickText(p, /^Submit for approval$/); await clickText(p, /^Submit$/); await p.waitForTimeout(1500) }
const restore = async (p, v) => { await openModal(p); await choose(p, v); await click(p, '[data-restore-version]') }
const BANNER_NOW = (n) => `Restored from version ${n}. Check it, then Submit for approval.`
const HEADER = (n) => `Editing a copy of version ${n}. Version ${LIVE.version} stays Live until this copy is approved.`
const HINT = `Opens it as your draft. Version ${LIVE.version} stays Live until the copy is approved. Nothing is deleted.`
const NOTICE_H = (n) => `Changed in the Client App's property data since version ${n} was made:`

// A. Laptop 1440, real data: the button, restore with no draft, the banner, the notice, Undo, Keep my draft, Submit
{
  const { ctx, p, st } = await open(1440)
  await openModal(p)
  let P = await pane(p)
  ok(!!P && P.v === String(LIVE.version) && !P.btn, '1440: guard, the Live version shows no Restore button', P && { v: P.v, btn: P.btn })
  const has = []
  for (const v of REPL) { await choose(p, v.version); const Q = await pane(p); has.push([v.version, !!(Q && Q.btn && Q.btn.text === 'Restore this version')]) }
  ok(has.length > 0 && has.every(([, b]) => b), '1440: every Replaced version has a "Restore this version" button', has)
  await choose(p, FROM.version)
  P = await pane(p)
  ok(!!P && !!P.btn && P.btn.rowHasH3 && near(P.btn.rect.cy, P.h3.cy, 4) && P.btn.rect.x > P.h3.x && near(P.btn.rect.r, P.paneRight, 2), `1440: R2, the button sits in version ${FROM.version}'s title row, right-aligned`, P && { btn: P.btn, h3: P.h3, paneRight: P.paneRight })
  ok(!!P && !!P.btn && P.btn.rect.h >= 34 && P.btn.rect.h <= 40, '1440: the button is 36px on a laptop', P && P.btn && P.btn.rect.h)
  ok(!!P && !!P.hint && P.hint.text === HINT && !!P.btn && P.btn.described === P.hint.id, '1440: the hint under the lines names the Live version, and describes the button', P && [P.hint, P.btn && P.btn.described])
  await p.screenshot({ path: `${out}/A_detail_1440.png` })
  await click(p, '[data-restore-version]')
  let B = await builder(p)
  ok(!B.modalOpen && B.focusActivity && !(await pane(p)), '1440: with no draft and a map, Restore restores at once (no confirm); the modal closes and focus is back on Activity', { modal: B.modalOpen, focus: B.focusActivity })
  ok(!!B.banner && B.banner.role === 'status' && B.banner.text === BANNER_NOW(FROM.version) && B.banner.buttons.map((x) => x.t).join() === 'Undo,Discard', `1440: the banner reads "${BANNER_NOW(FROM.version)}" with Undo and Discard`, B.banner)
  ok(B.header === HEADER(FROM.version), '1440: the header says it is a copy and which version stays Live', B.header)
  let Dr = await draft(p)
  ok(!!Dr && Dr.restored_from_version === FROM.version && Dr.base_version === PB.newest_version && Dr.restored_source === true && eq(Dr.source, FROM.source), `1440: the browser draft is saved at once with restored_from_version ${FROM.version}, base_version ${PB.newest_version} (the newest, never ${FROM.version}) and version ${FROM.version}'s property data`, Dr && { restored_from_version: Dr.restored_from_version, base_version: Dr.base_version, restored_source: Dr.restored_source, source_is_versions: eq(Dr.source, FROM.source) })
  ok(!!Dr && sameContent(Dr.content, FROM.content), `1440: the builder holds version ${FROM.version}'s content (no What changed line, the same photos, sections, notes and marks)`, Dr && { changes: diff(Dr.content, FROM.content), photos: photosOf(Dr.content).length })
  ok(!!B.notice && B.notice.heading === NOTICE_H(FROM.version) && B.notice.labels.join() === WANT_NOTICE.join(), `1440: the notice compares with version ${FROM.version}'s own property data ("since version ${FROM.version} was made")`, B.notice && { heading: B.notice.heading, labels: B.notice.labels, want: WANT_NOTICE })
  ok(B.submitDisabled === true && B.holdNotice, '1440: Submit waits for the notice', { disabled: B.submitDisabled, footer: B.holdNotice })
  await p.screenshot({ path: `${out}/A_restored_1440.png` })
  await click(p, '[data-restore-undo]')
  B = await builder(p); Dr = await draft(p)
  // the autosave writes 1 s after a change: wait it out, then reload (a stale autosave baseline saves a draft equal to Live)
  await p.waitForTimeout(1500); const Dr2 = await draft(p)
  await p.reload(); await ready(p); const R2 = await builder(p)
  ok(!B.banner && B.header === `Editing the live version (v${LIVE.version})` && Dr === null && !B.notice && B.focusActivity && Dr2 === null && !R2.banner && !R2.oldBar && R2.header === B.header, '1440: Undo puts the live version back (no banner, the live header line, no browser draft, no notice), focus on Activity; after the autosave delay and a reload still no draft and no bar', { banner: B.banner, header: B.header, draft: !!Dr, notice: !!B.notice, focus: B.focusActivity, draft_later: !!Dr2, reload: { banner: R2.banner, oldBar: R2.oldBar, header: R2.header } })
  await restore(p, FROM.version)
  await clickText(p, /^Keep my draft$/)
  B = await builder(p); Dr = await draft(p)
  ok(!!Dr && Dr.restored_from_version === FROM.version && Dr.restored_source === false && !B.notice && B.submitDisabled === false, '1440: after Keep my draft the draft still carries the restore, and Submit is enabled', Dr && { restored_from_version: Dr.restored_from_version, restored_source: Dr.restored_source, notice: !!B.notice, disabled: B.submitDisabled })
  await submit(p)
  const s = st.submits[st.submits.length - 1]
  ok(!!s && s.p_restored_from_version === FROM.version && s.p_expected_version === PB.newest_version && eq(s.p_expected_source, T) && sameContent(s.p_content, FROM.content), `1440: Submit sends p_restored_from_version ${FROM.version} with version ${FROM.version}'s content, p_expected_version ${PB.newest_version} and today's property data`, s && { keys: Object.keys(s), restored: s.p_restored_from_version, expected_version: s.p_expected_version, source_is_today: eq(s.p_expected_source, T), changes: diff(s.p_content, FROM.content) })
  B = await builder(p); Dr = await draft(p)
  ok(!!s && Dr === null && !B.banner, '1440: after Submit the browser draft and the banner are gone', { draft: !!Dr, banner: B.banner })
  ok(st.errors.length === 0, '1440: no page errors', st.errors)
  ok([...new Set(st.calls)].every((n) => ['get_page_builder', 'get_page_builder_forms', 'get_property_activity', 'get_page_versions', 'submit_property_page'].includes(n)) && !st.calls.includes('approve_property_page'), '1440: guard, only the builder reads and the stubbed submit, never approve', [...new Set(st.calls)])
  await ctx.close()
}

// B. 1440: with a draft, Restore asks first; Cancel; Restore; Undo brings the typed draft back
{
  const { ctx, p } = await open(1440)
  const MARK = ' restore-check'
  await typeNotes(p, MARK)
  const typed = (await builder(p)).notes
  await restore(p, FROM.version)
  let P = await pane(p), B = await builder(p)
  ok(!!P && !!P.confirm && P.confirm.title === `Restore version ${FROM.version}?` && P.confirm.lines.join('|') === 'Your current draft will be replaced. Undo brings it back.' && (P.confirm.buttons || []).map((x) => x.t).join() === `Cancel,Restore version ${FROM.version}` && !B.banner, '1440: with a draft, Restore opens the confirm under the lines instead of restoring', P && P.confirm)
  ok(!!P && !!P.confirm && P.confirm.focus === 'Cancel', '1440: focus is on Cancel', P && P.confirm && P.confirm.focus)
  await p.screenshot({ path: `${out}/B_confirm_1440.png` })
  await click(p, '[data-restore-cancel]')
  P = await pane(p); B = await builder(p)
  ok(!!P && !P.confirm && P.focusOnBtn && B.notes === typed && !B.banner, '1440: Cancel closes the confirm, focus returns to the Restore button, the draft is untouched', P && { confirm: !!P.confirm, focus: P.focusOnBtn, notes_kept: B.notes === typed })
  await click(p, '[data-restore-version]')
  await click(p, '[data-restore-go]')
  B = await builder(p)
  ok(!!B.banner && B.banner.text === BANNER_NOW(FROM.version) && B.notes === (FROM.content.notes ?? ''), `1440: Restore version ${FROM.version} replaces the draft (banner, version ${FROM.version}'s notes)`, { banner: B.banner, notes_are_versions: B.notes === (FROM.content.notes ?? '') })
  const seen = !!B.banner
  await click(p, '[data-restore-undo]')
  B = await builder(p); const Dr = await draft(p)
  ok(seen && !B.banner && B.notes === typed && !!Dr && Dr.content && Dr.content.notes === typed && !Dr.restored_from_version, '1440: Undo brings the typed draft back, on the page and in the browser draft, without the restore marker', { restored_first: seen, banner: B.banner, notes_back: B.notes === typed, stored_back: !!(Dr && Dr.content && Dr.content.notes === typed), marker: Dr && Dr.restored_from_version })
  await ctx.close()
}

// C. 1440: a version with no site map asks first even with no draft, and says so
{
  const { ctx, p } = await open(1440)
  await restore(p, NOMAP.version)
  const P = await pane(p)
  ok(!!P && !!P.confirm && P.confirm.title === `Restore version ${NOMAP.version}?` && P.confirm.lines.join('|') === `Version ${NOMAP.version} has no site map, so this copy has no pins or arrows. Once it is approved, the site file shows none.`, `1440: version ${NOMAP.version} has no site map: the confirm says so (no draft line)`, P && P.confirm)
  await click(p, '[data-restore-go]')
  const B = await builder(p), Dr = await draft(p)
  ok(!!B.banner && !!Dr && Dr.restored_from_version === NOMAP.version && !hasMap(Dr.content), `1440: restored, the draft of version ${NOMAP.version} has no site map`, Dr && { banner: !!B.banner, restored_from_version: Dr.restored_from_version, map: Dr.content && Dr.content.site_map })
  await ctx.close()
}

// D. 1440, edited stub: a photo of the version is gone, and a marked photo was rotated 90 degrees since
{
  const { ctx, p, st } = await open(1440, D)
  await restore(p, FROM.version)
  await clickText(p, /^Keep my draft$/)
  let B = await builder(p)
  ok(!!B.photos && B.photos.text === `1 photo from version ${FROM.version} is no longer on this property. The page cannot be submitted with it.` && B.photos.button === 'Leave it out', '1440: a restored photo that is no longer on the property is named in one sentence with "Leave it out"', B.photos)
  ok(B.submitDisabled === true && B.holdPhotos, '1440: Submit waits while that photo is in the draft', { disabled: B.submitDisabled, footer: B.holdPhotos })
  const Dr = await draft(p), dph = Dr && Dr.content && (Dr.content.photos || []).find((ph) => String(ph.photo_id) === ROT)
  ok(!!dph && eq(dph.marks, turn(M, 90)), `1440: the marks on photo ${ROT} follow its current rotation (made at 0, now 90)`, dph && dph.marks)
  await p.screenshot({ path: `${out}/D_photos_1440.png` })
  await click(p, '[data-restore-leave-out]')
  B = await builder(p)
  ok(!B.photos && !B.holdPhotos && B.submitDisabled === false, '1440: Leave it out removes it: the sentence goes and Submit is enabled', { photos: B.photos, footer: B.holdPhotos, disabled: B.submitDisabled })
  await submit(p)
  const s = st.submits[st.submits.length - 1]
  ok(!!s && !!s.p_content && photosOf(s.p_content).join() === photosOf(D_WANT).join(), `1440: the submitted content has the other photos, the rotated marks, and not the gone photo ${GONE}`, s && s.p_content && { sent: (s.p_content.photos || []).map((ph) => ph.photo_id) })
  await ctx.close()
}

// E. 1440: a reload keeps the restore; Discard ends it; Submit after a reload still sends it
{
  const { ctx, p, st } = await open(1440)
  await restore(p, FROM.version)
  await p.reload(); await ready(p)
  let B = await builder(p)
  ok(!!B.banner && new RegExp(`^Restored from version ${FROM.version}\\. Your draft from .+ was brought back\\.$`).test(B.banner.text || '') && B.banner.buttons.map((x) => x.t).join() === 'Discard' && !B.oldBar, `1440 after a reload: the bar reads "Restored from version ${FROM.version}. Your draft from <date> was brought back." with Discard only`, B.banner)
  ok(B.header === HEADER(FROM.version), '1440 after a reload: the header still says it is a copy', B.header)
  ok(!!B.notice && B.notice.heading === NOTICE_H(FROM.version), `1440 after a reload: the notice still reads "since version ${FROM.version} was made"`, B.notice && B.notice.heading)
  const seen = !!B.banner
  await click(p, '[data-restore-discard]')
  B = await builder(p)
  const Dd = await draft(p)
  await p.waitForTimeout(1500); const Dd2 = await draft(p)
  await p.reload(); await ready(p); const R3 = await builder(p)
  ok(seen && !B.banner && B.header === `Editing the live version (v${LIVE.version})` && Dd === null && Dd2 === null && !R3.banner && !R3.oldBar && R3.header === B.header, '1440 after a reload: Discard ends the restore (the live header line, no banner, no browser draft); after the autosave delay and a reload still no draft and no bar', { restored_first: seen, banner: B.banner, header: B.header, draft_later: !!Dd2, reload: { banner: R3.banner, oldBar: R3.oldBar, header: R3.header } })
  await restore(p, FROM.version)
  await p.reload(); await ready(p)
  await clickText(p, /^Keep my draft$/)
  await submit(p)
  const s = st.submits[st.submits.length - 1]
  ok(!!s && s.p_restored_from_version === FROM.version && sameContent(s.p_content, FROM.content), `1440 after a reload: Submit still sends p_restored_from_version ${FROM.version}`, s && { restored: s.p_restored_from_version, changes: diff(s.p_content, FROM.content) })
  await ctx.close()
}

// F. 1440: a plain Submit sends p_restored_from_version null (and the serialisation guard)
{
  const { ctx, p, st } = await open(1440)
  await typeNotes(p, ' plain-check')
  const Dr = await draft(p)
  ok(!!Dr && diff(Dr.content, LIVE.content).join() === 'Notes changed' && photosOf(Dr.content).join() === photosOf(LIVE.content).join(), '1440: guard, the builder saves the live version as stored plus the typed notes (the comparison every restore check relies on)', Dr && { changes: diff(Dr.content, LIVE.content) })
  await submit(p)
  const s = st.submits[st.submits.length - 1]
  ok(!!s && 'p_restored_from_version' in s && s.p_restored_from_version === null, '1440: a plain Submit sends p_restored_from_version null', s && { keys: Object.keys(s) })
  await ctx.close()
}

// W. 1440: no button on a version waiting for approval or never approved
{
  const { ctx, p } = await open(1440, W)
  await openModal(p)
  await choose(p, W2.version); const Pw = await pane(p)
  await choose(p, S1.version); const Ps = await pane(p)
  ok(!!Pw && Pw.v === String(W2.version) && !Pw.btn, '1440: guard, no Restore button on the version waiting for approval', Pw && { v: Pw.v, btn: Pw.btn })
  ok(!!Ps && Ps.v === String(S1.version) && !Ps.btn, '1440: guard, no Restore button on a Not approved version', Ps && { v: Ps.v, btn: Ps.btn })
  await ctx.close()
}

// G. 1440: after approval, the restored version is Live and says where it came from
{
  const { ctx, p } = await open(1440, G)
  await openModal(p)
  const it = await item(p, V5.version)
  ok(!!it && it.includes(`Restored from version ${FROM.version}`), `1440: the restored version reads "Restored from version ${FROM.version}" in the list`, it)
  const P5 = await pane(p)
  ok(!!P5 && P5.v === String(V5.version) && P5.restoredRow === `Version ${FROM.version}`, `1440: its detail has the row "Restored from: Version ${FROM.version}"`, P5 && { v: P5.v, row: P5.restoredRow })
  ok(!!P5 && !P5.btn, '1440: guard, the restored Live version has no Restore button', P5 && P5.btn)
  await choose(p, LIVE.version)
  const P4 = await pane(p)
  ok(!!P4 && !!P4.btn, `1440: version ${LIVE.version}, now replaced by it, can be restored in turn`, P4 && { v: P4.v, btn: !!P4.btn })
  await p.screenshot({ path: `${out}/G_after_1440.png` })
  await ctx.close()
}

// P. Phone 390: the button in the detail, 44px targets, no sideways scroll
{
  const { ctx, p, st } = await open(390)
  await typeNotes(p, ' phone-check')
  await openModal(p)
  await choose(p, FROM.version)
  let P = await pane(p)
  ok(!!P && !!P.btn && P.btn.rect.h >= 44 && P.btn.rowHasH3 && near(P.btn.rect.r, P.paneRight, 2), '390: the Restore button is 44px, in the title row, right-aligned', P && { btn: P.btn, paneRight: P.paneRight })
  ok(!(await builder(p)).sideways, '390: no sideways scroll')
  await p.screenshot({ path: `${out}/P_detail_390.png` })
  await click(p, '[data-restore-version]')
  P = await pane(p)
  ok(!!P && !!P.confirm && P.confirm.buttons.length === 2 && P.confirm.buttons.every((x) => x.h >= 44), '390: the confirm\'s Cancel and Restore buttons are 44px', P && P.confirm && P.confirm.buttons)
  await click(p, '[data-restore-go]')
  const B = await builder(p)
  ok(!B.modalOpen && !!B.banner && B.banner.buttons.length === 2 && B.banner.buttons.every((x) => x.h >= 44), '390: the modal closes and the banner\'s Undo and Discard are 44px', B.banner)
  await p.screenshot({ path: `${out}/P_banner_390.png` })
  ok(st.errors.length === 0, '390: no page errors', st.errors)
  await ctx.close()
}

// F. 1440, edited stub, the REAL map (T2, 2026-09-29): restoring a version whose pins sit 9.2 km away fits the map to them
// and shows the pin warning; the banner's Undo, and on a second restore its Discard, fit back to the live version's pins (or
// the property, when it has none). Each of those two counts only when the restore had moved the view off them first.
{
  const BUILDER_MAP = `(window.__maps || []).find((m) => { const w = m.getDiv().closest('.space-y-2'); return w && /GT Location/.test(w.textContent) })`
  const inView = (p, pts, ms = 10000) => p.waitForFunction(([pts, pick]) => { const m = eval(pick); const b = m && m.getBounds(); return !!b && pts.every((x) => b.contains(x)) }, [pts, BUILDER_MAP], { timeout: ms, polling: 250 }).then(() => true, () => false)
  const mapView = (p) => p.evaluate((pick) => { const m = eval(pick); if (!m || !m.getBounds()) return null; const c = m.getCenter(); return { lat: c.lat(), lng: c.lng(), zoom: m.getZoom() } }, BUILDER_MAP)
  const L0 = Number(PB.property.lat), G0 = Number(PB.property.lng), rnd = (x) => Math.round(x * 1e6) / 1e6
  const FARMAP = { pins: { gt: { lat: rnd(L0 - 0.056468), lng: rnd(G0 - 0.067718) }, truck: { lat: rnd(L0 - 0.056464), lng: rnd(G0 - 0.067539) } }, arrows: [] }
  const F = clone(BASE); F.versions.find((v) => v.version === FROM.version).content.site_map = clone(FARMAP)
  const lm = LIVE.content && LIVE.content.site_map
  const livePts = lm ? [lm.pins && lm.pins.gt, lm.pins && lm.pins.truck, ...(lm.arrows || []).flatMap((a) => a.points || [])].filter(Boolean) : []
  const back = livePts.length ? livePts : [{ lat: L0, lng: G0 }]
  const { ctx, p } = await open(1440, F, { maps: true })
  ok(await inView(p, back), "1440 map: guard, the live version's pins (or the property) are in view when the builder opens", await mapView(p))
  await restore(p, FROM.version)
  ok(await inView(p, [FARMAP.pins.gt, FARMAP.pins.truck]), `1440 map: restoring version ${FROM.version} (its pins 9.2 km away, edited stub) fits the map to them`, await mapView(p))
  const w = await p.evaluate(() => { const u = document.querySelector('[data-pin-warning]'); return u ? u.textContent.replace(/\s+/g, ' ').trim() : null })
  ok(!!w && /^The GT Location and Truck Parking pins are about \d+\.\d km from this property's address\. Check the map is on the right property\.$/.test(w), '1440 map: the restored far pins are warned about under the map', w)
  await p.screenshot({ path: `${out}/F_map_1440.png` }).catch(() => {})
  const away1 = !(await inView(p, back, 1000))
  await click(p, '[data-restore-undo]')
  ok(away1 && await inView(p, back), "1440 map: the banner's Undo fits the map back to the live version's pins (the restore had moved the view off them)", { moved_first: away1, view: await mapView(p) })
  await restore(p, FROM.version)
  const away2 = (await inView(p, [FARMAP.pins.gt, FARMAP.pins.truck])) && !(await inView(p, back, 1000))
  await click(p, '[data-restore-discard]')
  ok(away2 && await inView(p, back), "1440 map: the banner's Discard fits the map back to the live version's pins (the restore had moved the view off them)", { moved_first: away2, view: await mapView(p) })
  await ctx.close()
}

await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
