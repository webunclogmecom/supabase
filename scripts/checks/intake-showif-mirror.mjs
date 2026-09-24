// intake-showif-mirror.mjs — the intake show_if grammar lives in THREE places. Do they agree?
//
//   1. public.fn_intake_applicable           (SQL: decides what counts toward Complete)
//   2. visible() in supabase/functions/intake-submit/form-page.ts   (what the collector is shown)
//   3. vs() in the LIVE Client App bundle     (the Schedule dialog's parent-key parser)
//
// Run:  cd Supabase && node scripts/checks/intake-showif-mirror.mjs
// Exits 1 on any disagreement. Change the grammar in all three, reader first, writer second
// (docs/reference/client-intake-system.md, rule 13), then run this.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const ENV = Object.fromEntries(fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .map((l) => l.match(/^([A-Z_]+)=(.*)$/)).filter(Boolean).map((m) => [m[1], m[2].replace(/^"|"$/g, '')]))
const sql = async (query) => {
  const r = await fetch(`https://api.supabase.com/v1/projects/${ENV.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + ENV.SUPABASE_PAT, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) })
  const j = await r.json(); if (!r.ok) throw new Error(JSON.stringify(j)); return j
}
let bad = 0
const fail = (m) => { bad++; console.log('  DISAGREE ' + m) }

// ---- 1. the live tree and SQL
const tree = (await sql('select public.fn_intake_form_current() t'))[0].t
const qs = tree.sections.flatMap((s) => s.questions).filter((q) => q && typeof q === 'object')

// ---- 2. the form's own functions, taken verbatim from form-page.ts
const page = fs.readFileSync(path.join(ROOT, 'supabase/functions/intake-submit/form-page.ts'), 'utf8')
const a = page.indexOf('var HHMM='), b = page.indexOf('function setA(')
if (a < 0 || b < 0) throw new Error('form-page.ts no longer has the expected visible() block: update this check')
let A = {}
const F = { form: tree }
const form = new Function('getA', 'getF', page.slice(a, b)
  .replace(/\bA\[/g, 'getA()[').replace(/\bF&&F\.form&&F\.form\.sections/g, 'getF()&&getF().form&&getF().form.sections')
  + ';return {visible, cond}')(() => A, () => F)

// ---- 3. the dialog's parent-key parser, from the live bundle
const B = 'https://clients.unclogme.app'
const seen = new Set(), q = []
const add = (s) => { for (const m of s.matchAll(/\/assets\/[A-Za-z0-9_.\-]+\.js/g)) if (!seen.has(m[0])) { seen.add(m[0]); q.push(m[0]) } }
for (const r of ['/', '/clients/381']) add(await (await fetch(B + r)).text())
let dialogVs = null
while (q.length && !dialogVs) {
  const t = await (await fetch(B + q.shift())).text(); add(t)
  const i = t.indexOf('only if: ')
  if (i < 0) continue
  // the parser is the function just before the one that renders "only if:"
  const fStart = t.lastIndexOf('function ', t.lastIndexOf('function ', i) - 1)
  const fEnd = t.lastIndexOf('function ', i)
  const src = t.slice(fStart, fEnd)
  const name = src.match(/^function ([A-Za-z_$][\w$]*)\(/)?.[1]
  if (name) dialogVs = new Function(src + `;return ${name}`)()
}
if (!dialogVs) throw new Error('could not find the dialog show_if parser in the live Client App bundle: update this check')

// ---- A. every condition in the tree: all three read the same parent key (SQL's own parser, not a copy)
const sqlParents = Object.fromEntries((await sql(`select q ->> 'key' k, public.fn_intake_parent_key(t.t, q ->> 'key') p
    from (select public.fn_intake_form_current() t) t, jsonb_array_elements(t.t -> 'sections') s, jsonb_array_elements(s -> 'questions') q
   where q ? 'show_if'`)).map((r) => [r.k, r.p]))
for (const qq of qs.filter((x) => x.show_if)) {
  const sqlParent = sqlParents[qq.key]
  const formParent = form.cond(qq.show_if)?.k
  const dialogParent = dialogVs(qq.show_if)
  if (!(sqlParent === formParent && formParent === dialogParent)) fail(`${qq.key}: sql=${sqlParent} form=${formParent} dialog=${dialogParent}`)
  if (!qs.some((x) => x.key === sqlParent)) fail(`${qq.key}: its parent ${sqlParent} is not a question in the tree`)
}

// ---- B. visibility: the form and SQL decide the same thing, every question, every scenario
const S = [
  {}, { 'access_entry.gate': 'yes' }, { 'access_entry.gate': 'no', 'access_entry.gate_code': '1' },
  { 'access_entry.how_access': 'Lock box' }, { 'access_entry.how_access': 'Key', 'access_entry.lock_box_code': '9' },
  { 'access_entry.equipment_where': 'Inside', 'access_entry.where_inside': 'Other' },
  { 'access_entry.equipment_where': 'Outside', 'access_entry.where_inside': 'Other' },
  { 'access_entry.access_point': 'Other' }, { 'grease_trap.capacity_gallons': 1000 }, { 'grease_trap.capacity_gallons': '' },
  { 'lift_station.count': 0, 'water_tank.count': 0 }, { 'lift_station.count': 2, 'water_tank.count': 1 },
  { 'lift_station.count': 'abc' }, { 'access_entry.alarm': 'yes' },
  // round 4: the JS trim() set must be blank / a number the same way in SQL and in the form
  { 'lift_station.count': '\u00a02', 'water_tank.count': '\u30001\u2028' }, { 'grease_trap.capacity_gallons': '\u00a0' },
  { 'lift_station.count': '\u200b2' }, { 'grease_trap.systems_count': 0 }, { 'grease_trap.systems_count': 1 },
  { 'grease_trap.systems_count': 1, 'grease_trap.capacity_gallons': '\t' },
]
const wrap = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, { value: v }]))
const values = S.map((ans, si) => `(${si}, '${JSON.stringify(wrap(ans)).replace(/'/g, "''")}'::jsonb)`).join(',')
const rows = await sql(`with t as (select public.fn_intake_form_current() t), s(si, ans) as (values ${values})
  select s.si, q ->> 'key' as key, public.fn_intake_applicable(t.t, s.ans, q ->> 'key') as v
    from t, s, jsonb_array_elements(t.t -> 'sections') sec, jsonb_array_elements(sec -> 'questions') q`)
let cells = 0
for (const r of rows) {
  A = S[r.si]; cells++
  const js = form.visible(qs.find((x) => x.key === r.key))
  if (js !== r.v) fail(`scenario ${r.si} ${r.key}: form=${js} sql=${r.v}`)
}

// ---- positive control: the harness must be able to tell shown from hidden
A = { 'lift_station.count': 2 }
const on = form.visible(qs.find((x) => x.key === 'lift_station.photos'))
A = { 'lift_station.count': 0 }
const off = form.visible(qs.find((x) => x.key === 'lift_station.photos'))
if (!(on === true && off === false)) { bad++; console.log('  CONTROL FAILED: the form did not flip lift_station.photos on the count') }

console.log(`${qs.filter((x) => x.show_if).length} conditions parsed three ways, ${cells} visibility cells compared: ${bad ? bad + ' DISAGREE' : 'all agree'}`)
process.exit(bad ? 1 : 0)
