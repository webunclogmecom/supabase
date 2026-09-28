// LIVE Picture Planner form page /forms/<id>: the "Property record" tab (2026-09-28). Real replies for form 715 and
// the property's newest form on 112-YA property 1164, read in SQL as Fred's claims, then edited per scenario (the
// five rows are forced to "blank" so the test does not depend on what 1164 holds today). Sign-in faked; every call
// stubbed; the accept is RECORDED and answered here, so nothing is written anywhere. Never prints the lock box code.
// Spec: Building Apps/Picture Planner/docs/specs/2026-09-28-intake-accept-tab-design.md
//   node scripts/page-builder/tests/accept_tab.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
with n as (select intake_id from client.v_intake_submissions where property_id = 1164 and state = 'submitted' order by submitted_at desc limit 1)
select client.get_intake(715) as i715, client.get_intake_compare(715) as c715, (select intake_id from n) as newest,
       client.get_intake((select intake_id from n)) as inew, client.get_intake_compare((select intake_id from n)) as cnew,
       (select jsonb_agg(to_jsonb(s) order by s.submitted_at desc) from client.v_intake_submissions s where s.property_id = 1164 and s.state = 'submitted') as subs,
       public.fn_page_approver_names() as names;`)
const row = Array.isArray(r) ? r[r.length - 1] : null
if (!row || !row.c715 || !('can_accept' in row.c715)) { console.log('FAIL the migration is not applied (get_intake_compare has no can_accept) :: ' + JSON.stringify(r).slice(0, 200)); process.exit(1) }
const clone = (x) => JSON.parse(JSON.stringify(x))
const KEYS = ['access_entry.lock_box_code', 'access_hours.schedule', 'grease_trap.capacity_gallons', 'grease_trap.manhole_count', 'grease_trap.sample_ports']
const NAMES = ['Lock box code', 'When we can come', 'Grease trap gallons', 'Manholes', 'Sample ports']
const F = Object.fromEntries(row.c715.fields.map((f) => [f.key, f]))
if (!KEYS.every((k) => F[k] && F[k].theirs != null) || String(row.newest) === '715') { console.log('FAIL fixture: form 715 must answer all five, and a newer submitted form must exist on 1164'); process.exit(1) }
const LOCK = String(F[KEYS[0]].theirs), HOURS = F[KEYS[1]].theirs, GAL = F[KEYS[2]].theirs, NEW = Number(row.newest)
let pass = 0, fail = 0
const mask = (v) => JSON.stringify(v === undefined ? null : v).split(LOCK).join('<lock>')
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + mask(v).slice(0, 400)}`) }
const canon = (v) => Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v
const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b))
// the week, written the way the spec says the screen writes it (an independent copy of the rule)
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], DN = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const t12 = (s) => { const [h, m] = s.split(':').map(Number); return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}` }
const dayLine = (s, i) => { const d = s && s[DAYS[i]]; return !d ? `${DN[i]} No hours` : `${DN[i]} ${d.open === d.close ? 'Any time' : t12(d.open) + ' to ' + t12(d.close)}` }
const summary = (s) => { const out = []; for (let i = 0; i < 7;) { const d = s[DAYS[i]]; if (!d) { i++; continue } let j = i; while (j < 6 && s[DAYS[j + 1]] && s[DAYS[j + 1]].open === d.open && s[DAYS[j + 1]].close === d.close) j++; out.push(`${i === j ? DN[i] : DN[i] + ' to ' + DN[j]} ${d.open === d.close ? 'any time' : t12(d.open) + ' to ' + t12(d.close)}`); i = j + 1 } return out.join(', ') }
// replies
const blank = () => { const c = clone(row.c715); c.can_accept = true; c.accept_blocker = null; for (const f of c.fields) if (KEYS.includes(f.key)) { f.ours = null; f.state = 'blank' } return c }
const saved = () => { const c = blank(); for (const f of c.fields) if (KEYS.includes(f.key)) { f.ours = f.theirs; f.state = 'same' } return c }
const I715 = clone(row.i715); I715.accepted = []
const INEW = clone(row.inew); INEW.accepted = []
const CNEW = clone(row.cnew); CNEW.can_accept = true; CNEW.accept_blocker = null
const withAccepts = () => { const i = clone(I715); const at = new Date().toISOString(); i.accepted = KEYS.map((k) => ({ question_key: k, target_column: F[k].column, old_value: null, new_value: F[k].theirs, actor: 'fred@ayache.com', accepted_at: at })); return i }
const DATA = (c715, i715 = I715, after = null) => ({ intake: { 715: i715, [NEW]: INEW }, cmp: { 715: c715, [NEW]: CNEW }, subs: row.subs, after })
const STALE = { code: '22023', message: 'The property record changed since you opened this form. Reload to see it.', details: 'blocker=stale in client.accept_intake_answers: access_entry.lock_box_code', hint: null }
const RO = `Only ${row.names} can save these answers to the property record.`
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './accept_shots'; fs.mkdirSync(out, { recursive: true })
const subHits = []
async function open(w, id, data, mode = 'ok') {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { calls: [], bodies: [], errors: [], data, mode }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {}
    const send = (s, v) => x.fulfill({ status: s, contentType: 'application/json', body: JSON.stringify(v) })
    if (n === 'accept_intake_answers') {
      st.bodies.push(b)
      if (st.mode === 'stale') return send(400, STALE)
      if (st.mode === '500') return send(500, { message: 'boom' })
      if (st.data.after) st.data = { ...st.data, ...st.data.after, after: null }
      return send(200, { ok: true, intake_id: b.p_intake_id, accepted: b.p_keys, by: 'fred@ayache.com' })
    }
    if (n === 'get_intake' && st.data.intake[b.p_intake_id]) return send(200, st.data.intake[b.p_intake_id])
    if (n === 'get_intake_compare' && st.data.cmp[b.p_intake_id]) return send(200, st.data.cmp[b.p_intake_id])
    if (n === 'v_intake_submissions') return send(200, st.data.subs)
    return x.fulfill({ status: 404, contentType: 'application/json', body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + '/forms/' + id)
  await p.waitForFunction(() => /answered|Waiting for the collector|Cancelled/.test(document.body.textContent), null, { timeout: 30000 }).catch(() => {})
  await p.waitForTimeout(2500)
  return { ctx, p, st }
}
const count = (st, n) => st.calls.filter((c) => c === n).length
const T = (p) => p.evaluate(() => document.body.textContent.replace(/\s+/g, ' '))
const tabs = (p) => p.evaluate(() => [...document.querySelectorAll('[role="tab"]')].map((t) => ({ name: t.textContent.trim(), sel: t.getAttribute('aria-selected') })))
const clickTab = async (p, name) => { await p.getByRole('tab', { name }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(400) }
const openRecord = async (p) => { await clickTab(p, 'Property record'); await p.waitForFunction(() => document.querySelectorAll('[data-accept-row]').length === 5, null, { timeout: 15000 }).catch(() => {}); await p.waitForTimeout(400) }
const rows = (p) => p.evaluate(() => [...document.querySelectorAll('[data-accept-row]')].map((el) => { const cb = el.querySelector('[role="checkbox"]'); const rc = cb && cb.getBoundingClientRect(); const tx = (s) => ((el.querySelector(s) || {}).textContent || '').replace(/\s+/g, ' ').trim(); return { key: el.getAttribute('data-accept-row'), all: el.textContent.replace(/\s+/g, ' ').trim(), prop: tx('[data-side="property"]'), form: tx('[data-side="form"]'), cb: cb ? cb.getAttribute('aria-checked') : null, h: rc ? Math.round(rc.height) : 0, w: rc ? Math.round(rc.width) : 0 } }))
const tick = (p, k) => p.locator(`[data-accept-row="${k}"] [role="checkbox"]`).click({ timeout: 5000 }).catch(() => {})
const saveBtn = (p) => p.getByRole('button', { name: /^Save \d+ changes? to the property$/ })
const label = async (loc) => ((await loc.textContent({ timeout: 3000 }).catch(() => '')) || '').trim()
const openConfirm = async (p) => { await saveBtn(p).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(400) }
const confirmSave = async (p) => { await p.getByRole('button', { name: /^Save \d+ changes?$/ }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(2500) }
const sideways = (p) => p.evaluate(() => document.documentElement.scrollWidth > innerWidth)
const alertText = async (p) => ((await p.locator('[role="alert"]').first().textContent({ timeout: 3000 }).catch(() => '')) || '')

// A. Tabs, five blank rows, counts, the confirm, the save and after it: phone and laptop
for (const w of [390, 1280]) {
  const { ctx, p, st } = await open(w, 715, DATA(blank(), I715, { intake: { 715: withAccepts(), [NEW]: INEW }, cmp: { 715: saved(), [NEW]: CNEW } }))
  const t0 = await tabs(p)
  ok(t0.length === 2 && t0[0].name === 'Answers' && t0[1].name === 'Property record' && t0[0].sel === 'true' && t0[1].sel === 'false', `${w}: two tabs, Answers first and selected`, t0)
  const ta = await T(p)
  ok(ta.includes('Access & entry') && !ta.includes('Add to the property record'), `${w}: Answers shows the section cards, not the Property record card`)
  ok(count(st, 'get_intake_compare') === 0 && count(st, 'accept_intake_answers') === 0, `${w}: the Answers tab reads no compare and writes nothing`, [...new Set(st.calls)])
  await openRecord(p)
  const t1 = await tabs(p)
  ok(t1.length === 2 && t1[1].sel === 'true' && t1[0].sel === 'false', `${w}: Property record is selected after a click`, t1)
  const tr = await T(p)
  ok(tr.includes('Add to the property record') && !tr.includes('Lift station'), `${w}: the card replaces the section cards`)
  const R = await rows(p)
  ok(R.length === 5 && R.map((x) => x.key).join() === KEYS.join() && NAMES.every((nm, i) => R[i].all.startsWith(nm)), `${w}: five rows in the spec's order`, R.map((x) => x.key))
  ok(R.filter((x) => x.all.includes('Also goes to Jobber')).map((x) => x.key).join() === [KEYS[0], KEYS[2]].join(), `${w}: "Also goes to Jobber" only under the lock box code and the gallons`)
  ok(R.length === 5 && R.every((x) => x.prop.includes('Not on file') && x.cb === 'true'), `${w}: blank rows read Not on file and come ticked`, R.map((x) => [x.key, x.cb]))
  ok(R.length === 5 && R[0].form.includes(LOCK) && R[2].form.includes(String(GAL)) && DAYS.every((d, i) => R[1].form.includes(dayLine(HOURS, i))), `${w}: the form side shows the form's values and the week Mon to Sun`, R[1] && R[1].form)
  ok(R.length === 5 && (w < 768 ? R.every((x) => x.h >= 44 && x.w >= 44) : R.every((x) => x.h >= 32 && x.h <= 40)), `${w}: tick size (44px on a phone, the laptop size from 768px)`, R.map((x) => [x.h, x.w]))
  const hb = await p.evaluate(() => { const r = document.querySelector('[data-accept-row="access_hours.schedule"]'); if (!r) return null; const f = r.querySelector('[data-side="form"]'); const cb = r.querySelector('[role="checkbox"]'); const fr = f.getBoundingClientRect(); const right = Math.max(fr.right, ...[...f.querySelectorAll('*')].map((e) => e.getBoundingClientRect().right)); return { h: Math.round(fr.height), right: Math.round(right), formRight: Math.round(fr.right), cbLeft: cb ? Math.round(cb.getBoundingClientRect().left) : null } })
  ok(hb && hb.h >= 100 && hb.right <= hb.formRight + 1 && (w < 768 || hb.cbLeft === null || hb.right <= hb.cbLeft), `${w}: the week stacks Mon to Sun inside the form column`, hb)
  if (w < 768) { const tp = await p.evaluate(() => [...document.querySelectorAll('[data-accept-row]')].map((r) => { const c = r.querySelector('[role="checkbox"]'); if (!c) return null; const a = r.getBoundingClientRect(), b = c.getBoundingClientRect(); return [Math.round(b.top - a.top), Math.round(a.right - b.right)] })); ok(tp.length === 5 && tp.every((x) => x && x[0] <= 20 && x[1] <= 20), `${w}: each tick sits at the top right of its row`, tp) }
  ok(!(await sideways(p)), `${w}: no sideways scroll`)
  ok(await label(saveBtn(p)) === 'Save 5 changes to the property', `${w}: Save counts the five pre-ticked rows`)
  await tick(p, KEYS[3]); await tick(p, KEYS[4])
  ok(await label(saveBtn(p)) === 'Save 3 changes to the property', `${w}: two unticked gives Save 3`)
  await tick(p, KEYS[0]); await tick(p, KEYS[1]); await tick(p, KEYS[2])
  ok(await saveBtn(p).isDisabled({ timeout: 3000 }).catch(() => false), `${w}: nothing ticked, Save is disabled`)
  await tick(p, KEYS[0])
  ok(await label(saveBtn(p)) === 'Save 1 change to the property', `${w}: one ticked reads Save 1 change`)
  await tick(p, KEYS[1]); await tick(p, KEYS[2])
  await p.screenshot({ path: `${out}/A_rows_${w}.png`, fullPage: true })
  await openConfirm(p)
  const tc = await T(p)
  ok(tc.includes('Save 3 changes to the property?'), `${w}: the confirm names the count`)
  ok(tc.includes(`Lock box code: Not on file → ${LOCK}`) && tc.includes(`Grease trap gallons: Not on file → ${GAL}`), `${w}: the confirm lists old → new`)
  ok(tc.includes(`When we can come: replaced (${summary(HOURS)})`), `${w}: the confirm sums up the week`, [summary(HOURS), (tc.match(/When we can come: replaced \([^)]*\)/) || [])[0]])
  ok(tc.includes('The lock box code and the gallons also go to Jobber, within about 2 minutes.'), `${w}: one Jobber sentence for both`)
  ok(count(st, 'accept_intake_answers') === 0, `${w}: opening the confirm sends nothing`)
  ok(!(await sideways(p)), `${w}: no sideways scroll with the confirm open`)
  await p.screenshot({ path: `${out}/A_confirm_${w}.png`, fullPage: true })
  await p.getByRole('button', { name: /^Cancel$/ }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(300)
  ok(!(await T(p)).includes('Save 3 changes to the property?') && await label(saveBtn(p)) === 'Save 3 changes to the property', `${w}: Cancel closes the confirm and keeps the ticks`)
  await openConfirm(p)
  const c0 = count(st, 'get_intake_compare'), i0 = count(st, 'get_intake')
  await confirmSave(p)
  ok(st.bodies.length === 1 && same(st.bodies[0], { p_intake_id: 715, p_keys: [KEYS[0], KEYS[1], KEYS[2]], p_expected: { [KEYS[0]]: null, [KEYS[1]]: null, [KEYS[2]]: null } }), `${w}: the save sends the ticked keys in row order and what the screen showed`, st.bodies)
  const ts = await T(p)
  ok((await p.locator('[role="status"]', { hasText: 'Saved to the property.' }).count()) === 1, `${w}: the green line says Saved to the property.`)
  ok(!/Jobber (has|now has|got)/.test(ts), `${w}: nothing claims Jobber has the value`)
  ok(count(st, 'get_intake_compare') > c0 && count(st, 'get_intake') > i0, `${w}: the compare and the form are read again`)
  const R2 = await rows(p)
  ok(R2.length === 5 && R2.every((x) => x.all.includes('Already the same') && x.cb === null), `${w}: after the save all five read Already the same, no ticks`, R2.map((x) => [x.key, x.cb]))
  ok(ts.includes('Accepted into the property'), `${w}: the Accepted into the property block is on this tab`)
  ok(!(await sideways(p)), `${w}: no sideways scroll after the save`)
  await p.screenshot({ path: `${out}/A_saved_${w}.png`, fullPage: true })
  await clickTab(p, 'Answers')
  const tb = await T(p)
  ok(tb.includes('Access & entry') && !tb.includes('Accepted into the property') && !tb.includes('Add to the property record'), `${w}: back on Answers, no card and no Accepted block`)
  ok(st.errors.length === 0, `${w}: no page errors`, st.errors)
  ok([...new Set(st.calls)].every((c) => ['get_intake', 'get_intake_compare', 'v_intake_submissions', 'accept_intake_answers'].includes(c)), `${w}: no other call`, [...new Set(st.calls)])
  await ctx.close()
}

// B. The row states and a differing lock box code: laptop and phone
const mix = () => { const c = blank(); const f = Object.fromEntries(c.fields.map((x) => [x.key, x]))
  Object.assign(f[KEYS[0]], { ours: 'OLD-LB-1', state: 'differs' })
  Object.assign(f[KEYS[2]], { theirs: null, state: 'unanswered' })
  Object.assign(f[KEYS[3]], { ours: f[KEYS[3]].theirs, state: 'same' })
  Object.assign(f[KEYS[4]], { state: 'not_shown' })
  return c }
for (const w of [1280, 390]) {
  const { ctx, p, st } = await open(w, 715, DATA(mix()))
  await openRecord(p)
  const by = Object.fromEntries((await rows(p)).map((x) => [x.key, x]))
  ok(by[KEYS[0]] && by[KEYS[0]].prop.includes('OLD-LB-1') && by[KEYS[0]].form.includes(LOCK) && by[KEYS[0]].cb === 'false', `${w}: differs shows both values and comes unticked`)
  ok(by[KEYS[1]] && by[KEYS[1]].cb === 'true', `${w}: blank comes ticked`)
  ok(by[KEYS[2]] && by[KEYS[2]].form.includes('Not on the form') && by[KEYS[2]].cb === null, `${w}: unanswered reads Not on the form, no tick`)
  ok(by[KEYS[3]] && by[KEYS[3]].all.includes('Already the same') && by[KEYS[3]].cb === null, `${w}: same reads Already the same, no tick`)
  ok(by[KEYS[4]] && by[KEYS[4]].form.includes('Not on the form') && by[KEYS[4]].cb === null, `${w}: not shown reads Not on the form, no tick`)
  ok(await label(saveBtn(p)) === 'Save 1 change to the property', `${w}: only the blank row counts at first`)
  await tick(p, KEYS[0])
  ok(await label(saveBtn(p)) === 'Save 2 changes to the property', `${w}: ticking the differing lock box gives Save 2`)
  ok(!(await sideways(p)), `${w}: no sideways scroll`)
  await p.screenshot({ path: `${out}/B_states_${w}.png`, fullPage: true })
  await openConfirm(p)
  const tc = await T(p)
  ok(tc.includes(`Lock box code: OLD-LB-1 → ${LOCK}`) && tc.includes('The lock box code also goes to Jobber, within about 2 minutes.') && !tc.includes('the gallons also go'), `${w}: the confirm shows our old code and the lock box sentence only`)
  await confirmSave(p)
  ok(st.bodies.length === 1 && same(st.bodies[0], { p_intake_id: 715, p_keys: [KEYS[0], KEYS[1]], p_expected: { [KEYS[0]]: 'OLD-LB-1', [KEYS[1]]: null } }), `${w}: p_expected carries the value the screen showed`, st.bodies)
  await ctx.close()
}

// C. A day the form drops is red; a question the form did not ask; the gallons sentence alone
{
  const c = blank(); c.fields = c.fields.filter((x) => x.key !== KEYS[4])
  const h = c.fields.find((x) => x.key === KEYS[1]); const di = DAYS.findIndex((d) => !HOURS[d])
  h.ours = { ...clone(HOURS), [DAYS[di]]: { open: '08:00', close: '12:00' } }; h.state = 'differs'
  const { ctx, p } = await open(1280, 715, DATA(c))
  await openRecord(p)
  const by = Object.fromEntries((await rows(p)).map((x) => [x.key, x]))
  ok(di >= 0 && by[KEYS[1]] && by[KEYS[1]].prop.includes(`${DN[di]} 8:00 AM to 12:00 PM`) && by[KEYS[1]].form.includes(`${DN[di]} No hours`) && by[KEYS[1]].cb === 'false', 'hours: the day the form lacks shows on both sides, unticked', by[KEYS[1]])
  const reds = await p.evaluate(() => { const s = document.querySelector('[data-accept-row="access_hours.schedule"] [data-side="form"]'); if (!s) return []; const lineOf = (e) => { let x = e; while (x && x !== s && !/Mon|Tue|Wed|Thu|Fri|Sat|Sun/.test(x.textContent)) x = x.parentElement; return ((x || e).textContent || '').replace(/\s+/g, ' ').trim() }; return [...s.querySelectorAll('*')].filter((e) => !e.children.length && /No hours/.test(e.textContent)).map((e) => ({ line: lineOf(e), color: getComputedStyle(e).color })) })
  ok(reds.some((x) => x.line.includes(DN[di]) && x.color === 'rgb(185, 28, 28)'), `hours: ${DN[di]} No hours is red on the form side`, reds)
  ok(reds.filter((x) => !x.line.includes(DN[di])).every((x) => x.color !== 'rgb(185, 28, 28)'), 'hours: a day neither side has is not red', reds)
  ok(by[KEYS[4]] && by[KEYS[4]].form.includes('Not on the form') && by[KEYS[4]].cb === null, 'a question the form did not ask reads Not on the form')
  await tick(p, KEYS[0]); await tick(p, KEYS[3])  // only the gallons stay ticked
  await openConfirm(p)
  const tc = await T(p)
  ok(tc.includes('Save 1 change to the property?') && tc.includes('The gallons also go to Jobber, within about 2 minutes.') && !tc.includes('The lock box code'), 'gallons alone: its own Jobber sentence', (tc.match(/The [a-z ]+ also go(es)? to Jobber[^.]*\./) || [])[0])
  await p.screenshot({ path: `${out}/C_hours_1280.png`, fullPage: true })
  await ctx.close()
}

// D. The stale refusal: the sentence, a Reload button, and it never vanishes on its own
{
  const { ctx, p, st } = await open(1280, 715, DATA(blank()), 'stale')
  await openRecord(p)
  await tick(p, KEYS[3])  // one row unticked, so "Reload ticks the blank rows again" can fail
  await openConfirm(p); await confirmSave(p)
  ok((await alertText(p)).includes(STALE.message), 'stale: the sentence is shown')
  ok(await p.getByRole('button', { name: /^Reload$/ }).isVisible().catch(() => false), 'stale: with a Reload button')
  ok((await p.locator('[role="status"]', { hasText: 'Saved to the property.' }).count()) === 0, 'stale: no Saved line')
  await p.waitForTimeout(6000)
  ok((await alertText(p)).includes(STALE.message), 'stale: still there 6 seconds later')
  await p.screenshot({ path: `${out}/D_stale_1280.png`, fullPage: true })
  const c0 = count(st, 'get_intake_compare')
  await p.getByRole('button', { name: /^Reload$/ }).click({ timeout: 5000 }).catch(() => {}); await p.waitForTimeout(1500)
  ok(count(st, 'get_intake_compare') > c0 && !(await alertText(p)).includes(STALE.message), 'stale: Reload reads the compare again and clears the error')
  const R = await rows(p)
  ok(R.length === 5 && R.every((x) => x.cb === 'true'), 'stale: Reload ticks the blank rows again', R.map((x) => x.cb))
  await ctx.close()
}

// E. Anything else: the plain sentence
{
  const { ctx, p } = await open(390, 715, DATA(blank()), '500')
  await openRecord(p)
  await openConfirm(p); await confirmSave(p)
  ok((await alertText(p)).includes('The changes could not be saved. Nothing was changed. Try again.'), 'other error (390): the plain sentence')
  await ctx.close()
}

// F. A staff login that is not a page approver: read-only
{
  const c = blank(); c.can_accept = false; c.accept_blocker = RO
  const { ctx, p, st } = await open(390, 715, DATA(c))
  await openRecord(p)
  const R = await rows(p)
  ok(R.length === 5 && R.every((x) => x.cb === null), 'read-only (390): five rows, no ticks', R.map((x) => x.cb))
  ok((await saveBtn(p).count()) === 0 && (await T(p)).includes(RO), 'read-only (390): no Save, the approvers sentence instead', RO)
  ok(R.length === 5 && R.every((x) => x.prop.includes('Not on file')), 'read-only (390): the values still show')
  ok(count(st, 'accept_intake_answers') === 0, 'read-only (390): nothing sent')
  await p.screenshot({ path: `${out}/F_readonly_390.png`, fullPage: true })
  await ctx.close()
}

// G. No tab bar on a form that is not submitted, or was cancelled
{
  const aw = clone(I715); aw.submitted_at = null; aw.state = 'awaiting'; aw.status = null
  const ca = clone(I715); ca.state = 'cancelled'
  for (const [nm, i] of [['awaiting', aw], ['cancelled', ca]]) {
    const { ctx, p } = await open(1280, 715, DATA(blank(), i))
    ok((await tabs(p)).length === 0 && !(await T(p)).includes('Add to the property record'), `${nm}: no tab bar`)
    await ctx.close()
  }
}

// H. The form picker: every submitted form of the property, newest first; the newer one named; picking opens it
{
  const { ctx, p } = await open(1280, 715, DATA(blank()))
  await openRecord(p)
  const opts = await p.evaluate(() => { const s = document.querySelector('select[data-accept-picker]'); return s ? [...s.options].map((o) => ({ v: o.value, t: o.textContent.replace(/\s+/g, ' ').trim(), s: o.selected })) : [] })
  const ids = (row.subs || []).map((s) => String(s.intake_id))
  ok(opts.length > 1 && opts.map((o) => o.v).join() === ids.join() && opts.every((o) => /·\s(Complete|Incomplete)$/.test(o.t)), 'picker: every submitted form, newest first, "date · status"', opts)
  ok((opts.find((o) => o.s) || {}).v === '715', 'picker: this form is selected')
  const newer = opts.length ? `A newer form exists: ${opts[0].t}.` : 'none'
  ok((await T(p)).includes(newer), 'picker: the newer form is named under it', newer)
  await p.locator('select[data-accept-picker]').selectOption(String(NEW)).catch(() => {}); await p.waitForTimeout(2500)
  const u = new URL(p.url())
  ok(u.pathname === `/forms/${NEW}` && /record/.test(decodeURIComponent(u.search)), 'picker: picking the newer form opens it on its Property record tab', u.pathname + u.search)
  ok((await tabs(p)).some((t) => t.name === 'Property record' && t.sel === 'true') && (await rows(p)).length === 5 && !(await T(p)).includes('A newer form exists'), "picker: the newer form's rows show, with no newer-form line")
  await ctx.close()
}

await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
