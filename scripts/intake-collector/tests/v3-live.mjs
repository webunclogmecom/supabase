// v3-live.mjs <intake id> : the REAL intake-submit (v22) on a [TEST] intake, through its API only (no browser): Remove and,
// on a question list version 3 form, the explanation required on every photo. Refuses anything but an OPEN intake whose
// requested_by starts with "[TEST]" on property 1164 or 162 (the test client 112-YA). Reads the token from the DB and never
// prints it (nor a signed upload URL). SUBMITS the intake at the end; remove it with the per-id recipe of Building Apps/docs/client-intake-flow.md 11.3 step 5 (never cleanup.mjs while 167 is kept).
//   node scripts/intake-collector/tests/v3-live.mjs <intake id>
// On a version 2 form it checks Remove (the link soft-deleted, the file KEPT: soft delete only) and that a photo without a
// comment still submits (v1/v2 unchanged): 8 checks. On a version 3 form also the new slots on the real server (a photo
// attached to each lift station and water tank question, then fn_intake_missing, read only, with both counts at 1: only
// the control panel photo is missing among them, then none), the refusal in words (nothing written), then the submit with
// the explanation and its caption: 11 checks. CONTROL: run on v21 (before the v22 deploy) the four remove checks FAIL.
import fs from 'node:fs'
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const id = Number(process.argv[2])
const [row] = await sql(`select token, property_id, requested_by, submitted_at, cancelled_at, form_snapshot ->> 'version' as v, (form_snapshot -> 'photo_note_required') = 'true'::jsonb as req from public.property_intakes where id = ${id}`)
if (!row || !/^\[TEST\]/.test(row.requested_by || '') || ![1164, 162].includes(Number(row.property_id)) || row.submitted_at || row.cancelled_at) throw new Error('needs an OPEN [TEST] intake on 1164 or 162')
const TOKEN = row.token, V3 = row.v === '3'
if (V3 !== (row.req === true)) throw new Error('the snapshot version and photo_note_required disagree: ' + row.v + ' / ' + row.req)
const EP = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit'
const api = async (b) => { const r = await fetch(EP, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: TOKEN, ...b }) }); return { status: r.status, json: await r.json() } }
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v)).replaceAll(TOKEN, '<token>').slice(0, 400)}`) }
const KEY = 'access_entry.access_photos'
async function photo(role = KEY) {
  const u = await api({ op: 'upload', content_type: 'image/png' })
  if (!u.json.ok) throw new Error('upload refused: ' + u.json.message)
  const put = await fetch(u.json.signed_url, { method: 'PUT', headers: { 'content-type': 'image/png' }, body: PNG })
  if (!put.ok) throw new Error('PUT ' + put.status)
  const a = await api({ op: 'attach', path: u.json.path, role })
  if (!a.json.ok) throw new Error('attach refused: ' + a.json.message)
  return u.json.path
}
const links = async () => sql(`select l.id, p.storage_path, l.deleted_at is not null as removed, l.deleted_reason, l.caption, exists (select 1 from storage.objects o where o.bucket_id = 'intake-photos' and o.name = substr(p.storage_path, 15)) as file
  from public.photo_links l join public.photos p on p.id = l.photo_id where l.entity_type = 'property_intake' and l.entity_id = ${id} order by l.id`)
const at = (ls, path) => ls.find((l) => l.storage_path === 'intake-photos/' + path)

const load = await api({ op: 'load' })
ok(load.status === 200 && load.json.ok && (load.json.form.photo_note_required === true) === V3, `load: the form is version ${row.v}${V3 ? ' and asks for an explanation on every photo' : ' (no explanation required)'}`, { status: load.status, v: load.json.form && load.json.form.version })
const A = await photo(), B = await photo()
let rm = await api({ op: 'remove', path: B })
let ls = await links()
ok(rm.status === 200 && rm.json.ok && rm.json.removed === true, 'remove answers {ok, removed: true}', rm)
ok(at(ls, B) && at(ls, B).removed && at(ls, B).deleted_reason === 'Removed on the site survey form by the collector, before submit' && at(ls, B).file, 'the removed photo: its link soft-deleted with the reason, its file kept (soft delete only)', at(ls, B))
ok(at(ls, A) && !at(ls, A).removed && at(ls, A).file, 'the other photo is untouched', at(ls, A))
rm = await api({ op: 'remove', path: B })
ok(rm.status === 200 && rm.json.ok && rm.json.removed === false, 'a second remove answers removed: false', rm)
if (V3) {
  // the new version 3 slots on the real server: v22 attaches to them (the snapshot's keys, max_photos), and
  // fn_intake_missing (read only) with both counts at 1 wants the control panel photo and nothing else among them. These
  // photos are attached but never claimed by the submits below (a lost attach reply, exempt from the explanation rule).
  const NEW = ['lift_station.access_photos', 'lift_station.control_panel_photos', 'lift_station.photos', 'water_tank.capacity_photos', 'water_tank.photos']
  const got = {}; for (const k of NEW.filter((k) => k !== 'lift_station.control_panel_photos')) got[k] = { value: [await photo(k)] }
  const base = { 'lift_station.count': { value: 1 }, 'water_tank.count': { value: 1 }, ...got }
  const miss = async (a) => { const [m] = await sql(`select array(select k from unnest(public.fn_intake_missing(form_snapshot, requested, '${JSON.stringify(a)}'::jsonb)) k where k in (${NEW.map((k) => `'${k}'`).join(', ')})) as m from public.property_intakes where id = ${id}`); return m && m.m }
  const m1 = await miss(base)
  ok(JSON.stringify(m1) === '["lift_station.control_panel_photos"]', 'version 3: the access, lift station, capacity and water tank photos attach on the real server; with both counts at 1 only the control panel photo is missing among the five', m1)
  const cp = await photo('lift_station.control_panel_photos')
  const m2 = await miss({ ...base, 'lift_station.control_panel_photos': { value: [cp] } })
  ok(Array.isArray(m2) && m2.length === 0, 'version 3: with the control panel photo attached too, none of the five is missing', m2)
  const r1 = await api({ op: 'submit', collector: '[TEST] v3 live', answers: { [KEY]: [A, B] }, notes: {} })
  const [s1] = await sql(`select submitted_at is null as open from public.property_intakes where id = ${id}`)
  ok(r1.status === 400 && r1.json.message === '1 photo has no explanation: "Access & entry: Photos of the access point" (1). Write what each photo shows in the box under it.' && s1.open, 'version 3: a photo without an explanation is refused in words, naming its question, and the form stays open', { r1, s1 })
}
const r2 = await api({ op: 'submit', collector: '[TEST] v3 live', answers: { [KEY]: [A, B] }, notes: V3 ? { [A]: '[TEST] the side door' } : {} })
const [s2] = await sql(`select submitted_at is not null as done, answers -> '${KEY}' as a from public.property_intakes where id = ${id}`)
ls = await links()
ok(r2.status === 200 && r2.json.ok && s2.done && JSON.stringify(s2.a) === JSON.stringify({ value: [A] }), 'submit: the form is locked and the answer holds only the photo still on the form', { r2: r2.status, a: s2.a })
ok(at(ls, A).caption === (V3 ? '[TEST] the side door' : null), V3 ? 'the explanation is the photo\'s caption' : 'version 2: no comment, no caption (as v21)', at(ls, A))
const r3 = await api({ op: 'remove', path: A })
ls = await links()
ok(r3.status === 409 && !at(ls, A).removed && at(ls, A).file, 'a remove after submit answers 409 and touches nothing', r3)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
