// LIVE intake-submit v20 on [TEST] forms (112-YA property 1164): the assignee's name on load (one assignee: the name;
// two or none: nothing) and the 3-photo limit on "Photos of the alarm" (a 4th is refused 429, a question with no limit
// still takes more). Needs the version 2 question list (fn_intake_form_current) and the calendar_task_id column.
// Writes ONLY [TEST] rows: four property_intakes ('[TEST] schedule-assign check'), their upload slots, five 1x1 PNG
// photos and links under those forms. It links up to three of them for a moment to existing calendar tasks OF 112-YA
// ONLY (properties 162 and 1164, client 381; read-only for the tasks: never a real crew's task), then unlinks and
// CANCELS all four (soft). A name case with no such 112-YA task is a SKIP line (the stub covers the code); the
// zero-assignee case is required. Never prints a token or a link.
//   node scripts/intake-collector/tests/cap-and-assignee-live.mjs            the full check (after both migrations)
//   node scripts/intake-collector/tests/cap-and-assignee-live.mjs --smoke    right after the v20 deploy (question list 1 or 2):
//        ONE [TEST] form, load (200, every key the live page reads, no assignee_name), one gate photo attached, cancelled
//   node scripts/intake-collector/tests/cap-and-assignee-live.mjs --linked   READ ONLY, after the session's live 112-YA run:
//        every open 112-YA form linked to a one-assignee task loads that person's stored name
import fs from 'node:fs'
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const EP = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit'
const TAG = '[TEST] schedule-assign check'
let pass = 0, fail = 0
let skip = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v) ?? v).slice(0, 300)}`) }
const skipped = (name, why) => { skip++; console.log(`SKIP ${name} :: ${why}`) }
const SMOKE = process.argv.includes('--smoke'), LINKED = process.argv.includes('--linked')
const KEYS = ['intake_id', 'expires_at', 'requested', 'form', 'property', 'photo_cap', 'maps_key']
const OF_112YA = `(t.property_id in (162, 1164) or t.client_id = (select client_id from public.properties where id = 162))`

const [pre] = await sql(`select (public.fn_intake_form_current() ->> 'version') as v,
  exists (select 1 from pg_attribute where attrelid = 'public.property_intakes'::regclass and attname = 'calendar_task_id' and not attisdropped) as col`)
if (pre?.col !== true || (!SMOKE && pre?.v !== '2')) { console.log('FAIL precondition: calendar_task_id (migration 1) and, except with --smoke, question list version 2 (migration 2)', pre); process.exit(1) }

if (LINKED) { // read only: the session's own live run made a real task with one assignee on 112-YA and linked its form
  const rows = await sql(`select i.id, i.token, e.full_name from public.property_intakes i
      join ops.calendar_tasks t on t.id = i.calendar_task_id join ops.calendar_task_assignees a on a.task_id = t.id join public.employees e on e.id = a.employee_id
     where ${OF_112YA} and i.submitted_at is null and i.cancelled_at is null and i.expires_at > now()
       and (select count(*) from ops.calendar_task_assignees b where b.task_id = t.id) = 1`)
  if (!Array.isArray(rows) || !rows.length) { console.log('FAIL fixture: no open 112-YA form linked to a one-assignee task (run the live Schedule intake first)'); process.exit(1) }
  for (const r of rows) {
    const res = await fetch(EP, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: r.token, op: 'load' }) })
    const j = await res.json().catch(() => ({}))
    ok(res.status === 200 && j.assignee_name === r.full_name, `load: form ${r.id} (a real 112-YA task, one assignee) reads that person's stored name`, { status: res.status, got: j.assignee_name })
  }
  console.log(`\n${pass} passed, ${fail} failed  (read only)`)
  process.exit(fail ? 1 : 0)
}

// existing tasks OF 112-YA ONLY, none linked to a form: one, two and zero assignees
const [tk] = SMOKE ? [{}] : await sql(`with n as (select t.id, (select count(*) from ops.calendar_task_assignees a where a.task_id = t.id) c
    from ops.calendar_tasks t where ${OF_112YA} and not exists (select 1 from public.property_intakes i where i.calendar_task_id = t.id))
  select (select id from n where c = 1 order by id limit 1) as one, (select id from n where c = 2 order by id limit 1) as two,
         (select id from n where c = 0 order by id limit 1) as zero,
         (select e.full_name from ops.calendar_task_assignees a join public.employees e on e.id = a.employee_id
           where a.task_id = (select id from n where c = 1 order by id limit 1)) as one_name`)
if (!SMOKE && !tk?.zero) { console.log('FAIL fixture: no unlinked 112-YA task with zero assignees (task 220 on 2026-09-29)', tk); process.exit(1) }

const made = await sql(`insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  select 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (select array_agg(question_key) from client.v_intake_questions))), '${TAG}'
    from (select public.fn_intake_form_current() s) x, generate_series(1, ${SMOKE ? 1 : 4})
  returning id`)
const ids = (Array.isArray(made) ? made : []).map((r) => Number(r.id))
if (ids.length !== (SMOKE ? 1 : 4)) { console.log('FAIL fixture: could not make the [TEST] forms', made); process.exit(1) }
const [A, B, C, D] = SMOKE ? [null, null, null, ids[0]] : ids
try {
  const link = [[A, tk.one], [B, tk.two], [C, tk.zero]].filter(([id, t]) => id && t)
  if (link.length) await sql(`update public.property_intakes set calendar_task_id = case id ${link.map(([id, t]) => `when ${id} then ${t}`).join(' ')} end
             where id in (${link.map(([id]) => id).join(',')}) and requested_by = '${TAG}'`)
  const tokens = Object.fromEntries((await sql(`select id, token from public.property_intakes where id in (${ids.join(',')})`)).map((r) => [Number(r.id), r.token]))
  const api = async (id, b) => { const r = await fetch(EP, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: tokens[id], ...b }) }); return { status: r.status, json: await r.json() } }

  // the name on load
  const ld = await api(D, { op: 'load' })
  ok(ld.status === 200 && ld.json.ok === true && !('assignee_name' in ld.json), 'load: no task: no assignee_name', Object.keys(ld.json))
  ok(KEYS.every((k) => k in ld.json), 'load: every key the live page reads is still there', Object.keys(ld.json))
  if (!SMOKE) {
    if (tk.one) { const la = await api(A, { op: 'load' }); ok(la.status === 200 && la.json.assignee_name === tk.one_name, `load: a form linked to a one-assignee 112-YA task reads that person's stored name`, la.json.assignee_name) }
    else skipped('load: one assignee', 'no unlinked 112-YA task has exactly one assignee (the stub covers it; after the live run, --linked checks it on the real task)')
    for (const [id, t, what] of [[B, tk.two, 'two assignees'], [C, tk.zero, 'no assignee']]) {
      if (!t) { skipped(`load: ${what}`, `no unlinked 112-YA task with ${what} (the stub covers it)`); continue }
      const r = await api(id, { op: 'load' })
      ok(r.status === 200 && r.json.ok === true && !('assignee_name' in r.json), `load: ${what}: no assignee_name`, Object.keys(r.json))
    }
    ok(ld.json.form?.version === 2 && JSON.stringify(ld.json.form).includes('"max_photos":3'), 'load: the form is version 2 with the alarm photo limit', ld.json.form?.version)
  }

  // the 3-photo limit, on form D
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
  const attach = async (role) => {
    const up = await api(D, { op: 'upload', content_type: 'image/png' })
    if (up.status !== 200) return up
    const put = await fetch(up.json.signed_url, { method: 'PUT', headers: { 'content-type': 'image/png' }, body: png })
    if (!put.ok) return { status: put.status, json: { message: 'PUT failed' } }
    return api(D, { op: 'attach', path: up.json.path, role })
  }
  if (!SMOKE) {
    const got = []
    for (let n = 1; n <= 4; n++) got.push(await attach('access_entry.alarm_photos'))
    ok(got.slice(0, 3).every((r) => r.status === 200 && r.json.ok === true), 'attach: three alarm photos are taken', got.slice(0, 3).map((r) => r.status))
    ok(got[3].status === 429 && got[3].json.message === 'This question takes at most 3 photos.', 'attach: a 4th alarm photo is refused 429 "This question takes at most 3 photos."', got[3])
  }
  const gate = await attach('access_entry.gate_photos')
  ok(gate.status === 200 && gate.json.ok === true, 'attach: a question with no limit still takes a photo', gate)
  const [cnt] = await sql(`select count(*) filter (where role = 'access_entry.alarm_photos') as alarm, count(*) as total
    from public.photo_links where entity_type = 'property_intake' and entity_id = ${D} and deleted_at is null`)
  ok(SMOKE ? Number(cnt.total) === 1 : Number(cnt.alarm) === 3 && Number(cnt.total) === 4, SMOKE ? 'db: the form holds the one gate photo' : 'db: form D holds 3 alarm photos and 4 photos in all', cnt)
} finally {
  const done = await sql(`update public.property_intakes set calendar_task_id = null, cancelled_at = coalesce(cancelled_at, now())
    where id in (${ids.join(',')}) and requested_by = '${TAG}' and submitted_at is null returning id`)
  const [left] = await sql(`select count(*) filter (where calendar_task_id is not null) as linked, count(*) filter (where cancelled_at is null) as open
    from public.property_intakes where requested_by = '${TAG}'`)
  ok(Array.isArray(done) && done.length === ids.length && Number(left.linked) === 0 && Number(left.open) === 0, `cleanup: the ${ids.length} [TEST] form(s) are unlinked and cancelled`, left)
}
console.log(`\n${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ''}  (forms ${ids.join(', ')})`)
process.exit(fail ? 1 : 0)
