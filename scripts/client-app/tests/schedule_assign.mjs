// LIVE Client App (clients.unclogme.app), the Schedule intake dialog on 112-YA (client 381), 2026-09-29:
// "Assign to" (Fred picked A1: a one-line select, the 9 active staff, Technicians then Office, required, nobody
// preselected), the task made through save-calendar-task after the link, the refusal rule (cancel the link only on a
// definite refusal: a code on the design's list with no jobber_task, or rolled_back true), the unknown outcome ("Could not confirm the task. Check the Calendar before sending the link."),
// and the gallons on-file skip lifted. Sign-in faked (a FAKE token); PostgREST GETs forwarded READ-ONLY with the
// service key (never printed; a view the service key cannot read, v_client_billing, answers []); schedule_property_intake, cancel_intake and save-calendar-task answered by stubs;
// every other write refused. Nothing is written anywhere. Prints no link code.
//   node scripts/client-app/tests/schedule_assign.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const H = 'https://clients.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co', KEY = env.SUPABASE_SERVICE_ROLE_KEY
const out = process.argv[2] || './schedule_assign_shots'; fs.mkdirSync(out, { recursive: true })

// ---- expectations read from the database, never hard-coded ----
const [facts] = await sql(`select
  (select json_agg(json_build_object('id', id, 'name', full_name, 'tech', role = 'Technician') order by (role <> 'Technician'), full_name) from public.employees where status = 'ACTIVE') as staff,
  (select json_agg(json_build_object('key', question_key, 'label', label) order by section_order, question_order) from client.v_intake_questions) as qs,
  (select grease_capacity_gallons from client.properties where id = 162) as gal162`)
if (!facts.gal162) { console.log('FAIL fixture: 112-YA property 162 must hold a grease trap size (the on-file case)'); process.exit(1) }
// The service key cannot read these two client views, so the page is served them from a Management API read (postgres).
const [local] = await sql(`select
  (select json_agg(q order by q.section_order, q.question_order) from client.v_intake_questions q) as q,
  (select json_agg(s order by s.requested_at desc) from client.v_intake_submissions s where s.property_id in (select id from public.properties where client_id = 381)) as s`)
const LOCAL = { v_intake_questions: local.q || [], v_intake_submissions: local.s || [] }
const pgFilter = (rows, u) => {
  let out = rows
  for (const [k, v] of u.searchParams) {
    if (['select', 'order', 'limit', 'offset'].includes(k)) continue
    const m = /^(not\.)?(eq|neq|is|in)\.(.*)$/.exec(v)
    if (!m) continue
    const [, neg, op, val] = m
    const t = (r) => { const x = r[k]; if (op === 'eq') return String(x) === val; if (op === 'neq') return String(x) !== val; if (op === 'is') return val === 'null' ? x == null : String(x) === val; return val.replace(/^\(|\)$/g, '').split(',').includes(String(x)) }
    out = out.filter((r) => (neg ? !t(r) : t(r)))
  }
  return out
}
const STAFF = facts.staff, TECH = STAFF.filter((e) => e.tech).map((e) => e.name), OFFICE = STAFF.filter((e) => !e.tech).map((e) => e.name)
const GAL_LABEL = facts.qs.find((q) => q.key === 'grease_trap.capacity_gallons')?.label
const PICK = STAFF.find((e) => e.name === 'Grecia') || STAFF[0]
const TODAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York' }).format(new Date())
const DAY = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(TODAY + 'T12:00:00Z'))
const URL_STUB = 'https://planner.unclogme.app/intake#code=STUBCODE000000000000'
const PREFIX = 'Open this link on site to fill in the site survey form:'
const UNKNOWN = 'Could not confirm the task. Check the Calendar before sending the link.'
const CANCEL_FAILED = 'No task was made, and the link could not be cancelled. Cancel it in the Picture Planner, under Forms.'

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.${Buffer.from("fake-signature-not-real-32bytes!").toString("base64url")}`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v) ?? v).slice(0, 400)}`) }
const subHits = []

// one opened dialog per scenario; `task` is how the stubbed save-calendar-task answers
async function open(w, sc = {}) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const st = { seq: [], schedule: null, task: null, cancel: null, errors: [], writes: [], pageLoad: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  const cors = {}   // Playwright answers the CORS side of a fulfilled request itself; adding headers here breaks the page (measured)
  if (process.env.CHUNK_SUB) {
    const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||'))
    await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) })
  }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(user) }))
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', headers: cors, body: '{}' }))
  await p.route(SB + '/realtime/**', (x) => x.abort())
  await p.route(SB + '/functions/v1/**', async (x) => {
    const r = x.request(), path = new URL(r.url()).pathname
    if (r.method() === 'OPTIONS') return x.fulfill({ status: 200, headers: { ...cors, 'access-control-allow-methods': 'POST, OPTIONS' }, body: 'ok' })
    if (path !== '/functions/v1/save-calendar-task') {
      // Two calls the client page makes on load, both already in the pre-publish bundle (index-Cf7hgV4A, clients._id-D730fa7w):
      // the app's startup emergency-session check and the contacts read-through refresh (save-client-contact {action:"refresh"}).
      // Neither is a dialog write; they are aborted as before and kept out of `writes`. Any other function call still counts.
      let b = null; try { b = r.postDataJSON() } catch {}
      if (path === '/functions/v1/emergency-session' || (path === '/functions/v1/save-client-contact' && b?.action === 'refresh')) { st.pageLoad.push(path); return x.abort() }
      st.writes.push('fn ' + path); return x.abort()
    }
    st.seq.push('task'); try { st.task = r.postDataJSON() } catch { st.task = 'unreadable' }
    const t = sc.task || { status: 200, body: { ok: true, op: 'create', task_id: 901, jobber_task: 'GID', task_date: TODAY, all_day: true, intake_id: 999, intake_linked: true } }
    if (t.abort) return x.abort()
    return x.fulfill({ status: t.status, headers: cors, contentType: t.text ? 'text/plain' : 'application/json', body: t.text ?? JSON.stringify(t.body) })
  })
  await p.route(SB + '/rest/v1/**', async (x) => {
    const r = x.request(), m = r.method(), u = new URL(r.url()), n = u.pathname.split('/').pop()
    if (m === 'OPTIONS') return x.fulfill({ status: 204, headers: cors })
    if (m === 'GET' && n === 'employees' && sc.staffFails) return x.fulfill({ status: 500, headers: cors, contentType: 'application/json', body: '{"message":"stubbed failure"}' })
    if (m === 'GET' && LOCAL[n]) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(pgFilter(LOCAL[n], u)) })
    if (m === 'GET' || m === 'HEAD') {
      const h = { ...r.headers(), apikey: KEY, authorization: 'Bearer ' + KEY }
      try { const res = await fetch(r.url(), { method: m, headers: h }); if (res.status === 401 || res.status === 403) return x.fulfill({ status: 200, headers: cors, contentType: 'application/json', body: '[]' }); const body = Buffer.from(await res.arrayBuffer()); return x.fulfill({ status: res.status, headers: Object.fromEntries([...res.headers].filter(([k]) => !/^(content-encoding|content-length|transfer-encoding)$/i.test(k))), body }) } catch (e) { st.errors.push('fwd ' + e.message); return x.abort() }
    }
    if (m === 'POST' && n === 'schedule_property_intake') { st.seq.push('schedule'); st.schedule = r.postDataJSON(); return x.fulfill({ status: 200, headers: cors, contentType: 'application/json', body: JSON.stringify({ ok: true, intake_id: 999, url: URL_STUB, expires_at: '2026-11-28T16:00:00+00:00', requested: st.schedule?.p_requested ?? [], dropped: [], added: [], form_version: 2, note: null }) }) }
    if (m === 'POST' && n === 'cancel_intake') { st.seq.push('cancel'); st.cancel = r.postDataJSON(); const c = sc.cancel || { status: 200, body: { ok: true, intake_id: 999, cancelled_at: new Date().toISOString() } }; return x.fulfill({ status: c.status, headers: cors, contentType: 'application/json', body: JSON.stringify(c.body) }) }
    st.writes.push(m + ' ' + n)
    return x.fulfill({ status: 404, headers: cors, contentType: 'application/json', body: '{"message":"stubbed"}' })
  })
  await p.goto(H + '/clients/381')
  await p.getByRole('button', { name: 'Edit property' }).first().waitFor({ timeout: 30000 })
  await p.waitForTimeout(1200)
  await p.getByRole('button', { name: 'Edit property' }).first().click()
  await p.getByRole('button', { name: 'Intake Form' }).click()
  return { ctx, p, st, phone }
}
const dlg = (p) => p.locator('[role=dialog]').last()
const dlgText = async (p) => (await dlg(p).innerText().catch(() => '')).replace(/\s+/g, ' ')
async function toSchedule(p) {
  await p.getByRole('button', { name: 'No, schedule it' }).click()
  await p.getByText('Schedule intake').first().waitFor({ timeout: 15000 })
  await p.waitForFunction(() => /questions selected/.test(document.querySelector('[role=dialog]')?.innerText || ''), null, { timeout: 20000 }).catch(() => {})
  await p.waitForTimeout(1000)
}
async function pick(p, name) {
  await dlg(p).getByRole('combobox').first().click({ timeout: 5000 })
  await p.getByRole('option', { name, exact: true }).click({ timeout: 5000 })
  await p.waitForTimeout(300)
}
const create = async (p) => { await dlg(p).getByRole('button', { name: /Create link/ }).click({ timeout: 5000 }); await p.waitForTimeout(2500) }
const safe = async (name, fn) => { try { await fn() } catch (e) { ok(false, name, e.message.split('\n')[0]) } }

// the property the dialog is for, and the title the task must carry (the header address rule, rule 2r (3))
async function titleFor(propertyId) {
  const [row] = await sql(`select address, city from client.properties where id = ${Number(propertyId)}`)
  const a = (row?.address || '').trim(), c = (row?.city || '').trim()
  const g = a ? (c !== '' && a.toLowerCase().includes(c.toLowerCase()) ? a : [a, c].filter(Boolean).join(', ')) : c
  return g ? `Intake form: ${g}` : 'Intake form'
}

for (const w of [1280, 390]) {
  // A. the field, the list, required
  await safe(`${w}: A`, async () => {
    const { ctx, p, st } = await open(w)
    await toSchedule(p)
    const t = await dlgText(p)
    ok(/Assign to/.test(t) && /We make a task for this person in Jobber and in the Calendar\./.test(t), `${w}: [new] "Assign to" and its help line are in the Schedule intake dialog`, t.slice(0, 200))
    const order = await dlg(p).evaluate((d) => { const txt = d.innerText; return [txt.indexOf('Assign to'), txt.search(/questions selected/)] })
    ok(order[0] >= 0 && order[0] < order[1], `${w}: [new] it sits above the questions`, order)
    ok(/Nobody yet/.test(t) && /Required/.test(t), `${w}: [new] nobody is picked and it reads Required`, t.slice(0, 300))
    ok(await dlg(p).getByRole('button', { name: /Create link/ }).isDisabled(), `${w}: [new] Create link is disabled until a person is picked`)
    await dlg(p).getByRole('combobox').first().click({ timeout: 5000 }).catch(() => {})
    const opts = await p.getByRole('option').allInnerTexts().catch(() => [])
    const labels = await p.locator('[role=listbox] [role=group]').evaluateAll((gs) => gs.map((g) => (g.firstElementChild?.textContent || '').trim())).catch(() => [])
    ok(JSON.stringify(opts.map((o) => o.trim())) === JSON.stringify([...TECH, ...OFFICE]), `${w}: [new] the 9 active staff, Technicians then Office, by name`, opts)
    ok(JSON.stringify(labels) === JSON.stringify(['Technicians', 'Office']), `${w}: [new] two groups, "Technicians" then "Office"`, labels)
    await p.screenshot({ path: `${out}/A_open_${w}.png` })
    await p.keyboard.press('Escape'); await p.waitForTimeout(300)
    await pick(p, PICK.name).catch(() => {})
    const t2 = await dlgText(p)
    ok(t2.includes(PICK.name) && /1 person/.test(t2) && !(await dlg(p).getByRole('button', { name: /Create link/ }).isDisabled()), `${w}: [new] after a pick: the name shows, "1 person", Create link enabled`, t2.slice(0, 300))
    await dlg(p).screenshot({ path: `${out}/A_picked_${w}.png` })
    ok(st.errors.length === 0, `${w}: [guard] no page errors`, st.errors)
    if (w < 768) ok(await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth) <= 0, `${w}: [guard] no sideways scroll`)
    await ctx.close()
  })

  // B. success: the order, the exact task body, Link ready with the task line, no cancel
  await safe(`${w}: B`, async () => {
    const { ctx, p, st } = await open(w)
    await toSchedule(p); await pick(p, PICK.name); await create(p)
    const title = await titleFor(st.schedule?.p_property_id)
    ok(st.schedule?.p_property_id === 162, `${w}: [guard] the first Edit property on 112-YA is property 162`, st.schedule?.p_property_id)
    ok(JSON.stringify(st.seq) === '["schedule","task"]', `${w}: [new] the link first, then the task, nothing else`, st.seq)
    ok(st.schedule && JSON.stringify(Object.keys(st.schedule).sort()) === '["p_property_id","p_requested"]', `${w}: [guard] schedule_property_intake still gets exactly two arguments`, st.schedule && Object.keys(st.schedule))
    const want = { op: 'create', app: 'client-app', intake_id: 999, title, instructions: `${PREFIX}\n${URL_STUB}`, client_id: 381,
      property_id: st.schedule?.p_property_id, assignee_ids: [PICK.id], task_date: TODAY, all_day: true }
    const got = st.task && typeof st.task === 'object' ? Object.fromEntries(Object.keys(want).map((k) => [k, st.task[k]])) : st.task
    ok(JSON.stringify(got) === JSON.stringify(want) && st.task && Object.keys(st.task).length === Object.keys(want).length, `${w}: [new] the task body is exactly the design's`, { got: st.task, want: { ...want, instructions: '(prefix + link)' } })
    const t = await dlgText(p)
    ok(/Link ready/.test(t) && t.includes(`Task made for ${PICK.name}, ${DAY}, all day: ${title}.`) && t.includes('It is in Jobber and in the Calendar, with this link in its notes.'),
      `${w}: [new] Link ready says the task was made, for whom, the day, the title`, t.slice(0, 400))
    ok(st.cancel === null, `${w}: [new] the link is not cancelled`)
    ok(GAL_LABEL && t.length > 0, `${w}: [guard] the gallons question label was read from the database`, GAL_LABEL)
    ok((st.schedule?.p_requested || []).includes('grease_trap.capacity_gallons'), `${w}: [new] gallons are asked again although ${facts.gal162} gal are on file`, st.schedule?.p_requested)
    ok(st.writes.length === 0 && st.errors.length === 0, `${w}: [guard] no other write, no page errors`, { writes: st.writes, errors: st.errors })
    await dlg(p).screenshot({ path: `${out}/B_ready_${w}.png` })
    await ctx.close()
  })
  if (w < 768) continue

  // C. the gallons tile line (held value asked again)
  await safe(`${w}: C`, async () => {
    const { ctx, p } = await open(w)
    await toSchedule(p)
    const t = await dlgText(p)
    ok(t.includes(`${GAL_LABEL}: ${facts.gal162} gal on file, asked again next to the capacity plate photo.`) && !t.includes(`${GAL_LABEL}: ${facts.gal162} gal, already on file`),
      `${w}: [new] the gallons note says it is asked again`, (t.match(/[^.]*gal(, already)? on file[^.]*\./g) || []).slice(0, 3))
    await ctx.close()
  })

  // D. definite refusals: the link is cancelled and the reason shown; the pick is kept
  for (const [name, task] of [
    ['refused before Jobber (400)', { status: 400, body: { ok: false, code: 'assignee_unlinked', message: 'These employees have no linked Jobber user. Nothing was saved.' } }],
    ['rolled back (502, rolled_back true)', { status: 502, body: { ok: false, code: 'jobber_unverified', jobber_task: 'GID', rolled_back: true, message: 'Jobber did not confirm the change, so nothing was saved here.' } }],
    ['refused by Jobber (502 jobber_rejected)', { status: 502, body: { ok: false, code: 'jobber_rejected', jobber_errors: ['Title is too long'], message: 'Jobber refused to create the task, so nothing was saved here: Title is too long' } }],
  ]) {
    await safe(`${w}: D ${name}`, async () => {
      const { ctx, p, st } = await open(w, { task })
      await toSchedule(p); await pick(p, PICK.name); await create(p)
      const t = await dlgText(p)
      ok(JSON.stringify(st.seq) === '["schedule","task","cancel"]' && st.cancel?.p_intake_id === 999, `${w}: [new] ${name}: the link is cancelled`, { seq: st.seq, cancel: st.cancel })
      ok(t.includes(`No task was made, so the link was cancelled. ${task.body.message}`) && !/Link ready/.test(t) && /Schedule intake/.test(t) && t.includes(PICK.name),
        `${w}: [new] ${name}: the reason shows on the checklist, the pick kept, no Link ready`, t.slice(-400))
      await ctx.close()
    })
  }
  await safe(`${w}: D cancel fails`, async () => {
    const { ctx, p, st } = await open(w, { task: { status: 400, body: { ok: false, code: 'invalid_input', message: 'x' } }, cancel: { status: 400, body: { code: '22023', message: 'This form changed a moment ago.' } } })
    await toSchedule(p); await pick(p, PICK.name); await create(p)
    const t = await dlgText(p)
    ok(t.includes(CANCEL_FAILED) && !/Link ready/.test(t), `${w}: [new] a refused task whose cancel fails says so, no Link ready`, t.slice(-300))
    await ctx.close()
  })

  // E. unknown outcomes: never cancel, never "Link ready", the link and the check sentence
  for (const [name, task] of [
    ['rolled_back false (502)', { status: 502, body: { ok: false, code: 'jobber_unverified', jobber_task: 'GID', rolled_back: false, message: 'ORPHANED' } }],
    // a listed code is a refusal only with no jobber_task: Jobber made the task, recording it failed and the delete was not
    // confirmed (save-calendar-task index.ts, the rpcErr branch: mapRpcError 22023/23502/22P02 = 400 invalid_input)
    ['listed code with a jobber_task (400 invalid_input, rolled_back false)', { status: 400, body: { ok: false, code: 'invalid_input', jobber_task: 'GID', rolled_back: false, message: 'The Jobber task was created but our copy could not be recorded: x' } }],
    ['unexpected with no jobber_task (500)', { status: 500, body: { ok: false, code: 'unexpected', message: 'Something went wrong and nothing was saved.' } }],
    ['jobber_unknown with no jobber_task (502, maybe_created)', { status: 502, body: { ok: false, code: 'jobber_unknown', maybe_created: true, message: 'Jobber did not answer clearly, so we cannot tell whether the task was created. Nothing was saved here. Check Jobber before trying again.' } }],
    ['intake_already_linked (409, the form already has a task)', { status: 409, body: { ok: false, code: 'intake_already_linked', message: 'Site survey form 999 already has a task. Nothing was saved.' } }],
    ['a reply that is not JSON (504)', { status: 504, text: 'upstream request timeout' }],
    ['no reply (network)', { abort: true }],
  ]) {
    await safe(`${w}: E ${name}`, async () => {
      const { ctx, p, st } = await open(w, { task })
      await toSchedule(p); await pick(p, PICK.name); await create(p)
      const t = await dlgText(p)
      const link = await dlg(p).locator('input[readonly]').first().inputValue().catch(() => null)
      ok(st.cancel === null && JSON.stringify(st.seq) === '["schedule","task"]', `${w}: [new] ${name}: the link is kept`, st.seq)
      const heading = ((await dlg(p).getByRole('heading').first().innerText().catch(() => '')) || '').trim()
      ok(t.includes(UNKNOWN) && heading === 'Check the Calendar' && !/Link ready/.test(t) && link === URL_STUB && /Copy link/.test(t),
        `${w}: [new] ${name}: "${UNKNOWN}" with the link and Copy link, never Link ready`, t.slice(0, 300))
      if (name.startsWith('rolled_back')) await dlg(p).screenshot({ path: `${out}/E_unknown_${w}.png` })
      await ctx.close()
    })
  }

  // F. the staff list cannot load: say so, Create link stays off
  await safe(`${w}: F`, async () => {
    const { ctx, p } = await open(w, { staffFails: true })
    await toSchedule(p)
    const t = await dlgText(p)
    ok(t.includes("We couldn't load the staff list. Close this and try again.") && await dlg(p).getByRole('button', { name: /Create link/ }).isDisabled(), `${w}: [new] no staff list: the sentence, and no Create link`, t.slice(0, 300))
    await ctx.close()
  })

  // G. "Yes, fill it now" makes no task and shows no Assign to
  await safe(`${w}: G`, async () => {
    const { ctx, p, st } = await open(w)
    ok(!/Assign to/.test(await dlgText(p)), `${w}: [guard] the choice dialog has no Assign to`)
    await ctx.route('https://planner.unclogme.app/**', (x) => x.fulfill({ status: 200, contentType: 'text/html', body: '<p>stub</p>' }))
    const popup = ctx.waitForEvent('page', { timeout: 8000 }).catch(() => null)
    await p.getByRole('button', { name: 'Yes, fill it now' }).click()
    await popup; await p.waitForTimeout(2500)
    ok(st.seq.includes('schedule') && !st.seq.includes('task'), `${w}: [guard] Yes, fill it now: a link, no task`, st.seq)
    await ctx.close()
  })
}
await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
